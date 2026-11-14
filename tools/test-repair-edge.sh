#!/usr/bin/env bash
# Edge cases the repair path gets wrong when it conflates "empty" with "gone".
#
# `_repair` reads the primary's id list and uses it as the authority for what a
# replica should hold. Two states look identical to that code — a primary with
# zero live documents, and a primary or replica that is not answering — and the
# difference is exactly the difference between a correct cluster and a silently
# wrong one:
#
#   1. An **empty primary is still authoritative**. When every document a group
#      owned has been deleted, a replica holding an old copy is serving a
#      document the cluster no longer has. Repair must remove it. Skipping the
#      group because the primary reported no ids leaves a ghost that failover
#      will happily answer with.
#
#   2. An **unreachable member must be named**. A repair that cannot reach a
#      replica applies nothing to it, so reporting `ok:true` with no failures
#      tells the operator the group is in sync when it was never inspected.
#
# Usage: tools/test-repair-edge.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-repair-edge.sh <server-binary> [workspace]}"
SCH="title:6,keywords:3,desc:1,deps:1.5"
LOG="${TMPDIR:-/tmp}/moonseek-repair-edge-logs"

rm -rf "$LOG"; mkdir -p "$LOG"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

# Group 0: primary on shard port 7930, replica on 7931. HTTP 7830 / 7831.
COORD=7832
PRIMARY_SHARD=127.0.0.1:7930
REPLICA_SHARD=127.0.0.1:7931

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
docs_of() { curl -s -m 10 "http://127.0.0.1:$1/_stats" | json 'd["docs"]'; }
fail() { echo "FAIL: $*"; exit 1; }

echo "== starting one primary, one replica, one coordinator =="
"$BIN" --addr 127.0.0.1:7830 --shard-port "$PRIMARY_SHARD" --schema "$SCH" \
  > "$LOG/primary.log" 2>&1 &
pids+=($!)
"$BIN" --addr 127.0.0.1:7831 --shard-port "$REPLICA_SHARD" --schema "$SCH" \
  > "$LOG/replica.log" 2>&1 &
replica_pid=$!
pids+=($replica_pid)
"$BIN" --addr "127.0.0.1:$COORD" --schema "$SCH" --pool 200 \
  --shards "$PRIMARY_SHARD|$REPLICA_SHARD" > "$LOG/coord.log" 2>&1 &
pids+=($!)

for _ in $(seq 1 60); do
  curl -sf -m 2 "http://127.0.0.1:$COORD/_stats" > /dev/null 2>&1 && break
  sleep 0.5
done
curl -sf -m 2 "http://127.0.0.1:$COORD/_stats" > /dev/null 2>&1 \
  || { echo "FAIL: coordinator never became ready"; cat "$LOG"/*.log; exit 1; }

doc() { echo "{\"id\":\"$1\",\"fields\":{\"title\":\"$2\",\"keywords\":\"$2\",\"desc\":\"$2\",\"deps\":\"\"}}"; }

echo "== claim 1: a replica copy survives an empty primary until repair removes it =="
curl -fsS -m 10 -X POST "http://127.0.0.1:$COORD/index" -d "$(doc a1 alpha)" > /dev/null \
  || fail "write through coordinator failed"
[ "$(docs_of 7830)" = "1" ] || fail "primary should hold 1 document"
[ "$(docs_of 7831)" = "1" ] || fail "replica should have replicated 1 document"

# Delete it, so the group's primary legitimately holds zero documents.
curl -fsS -m 10 -X DELETE "http://127.0.0.1:$COORD/index?id=a1" > /dev/null \
  || fail "delete through coordinator failed"
[ "$(docs_of 7830)" = "0" ] || fail "primary should be empty after the delete"
[ "$(docs_of 7831)" = "0" ] || fail "replica should have replicated the delete"

# Now the state a real cluster reaches after a partial failure: the replica was
# unreachable for the delete, or was seeded by hand. It holds a document its
# primary no longer has, and the primary is empty.
curl -fsS -m 10 -X POST http://127.0.0.1:7831/index -d "$(doc ghost/1 ghost)" > /dev/null \
  || fail "ghost write to the replica failed"
[ "$(docs_of 7831)" = "1" ] || fail "replica should hold the ghost"
[ "$(docs_of 7830)" = "0" ] || fail "primary should still be empty"

repaired=$(curl -fsS -m 30 -X POST "http://127.0.0.1:$COORD/_repair")
echo "repair with an empty primary: $repaired"
echo "$repaired" | grep -q '"ok":true' || fail "repair reported a failure it should not have"

# The empty primary is authoritative: the replica must go back to zero.
if [ "$(docs_of 7831)" != "0" ]; then
  fail "an empty primary let the replica keep a ghost document (repair skipped the group)"
fi
echo "ok: an empty primary still drove the replica's extra document out"

echo "== claim 2: repair names a member it could not reach =="
curl -fsS -m 10 -X POST "http://127.0.0.1:$COORD/index" -d "$(doc b1 beta)" > /dev/null \
  || fail "write before the outage failed"

kill "$replica_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf -m 1 http://127.0.0.1:7831/_stats > /dev/null 2>&1 || break
  sleep 0.25
done

# A write while the replica is down is already honestly ok=false; that is a
# different claim, tested in test-replication.sh. Here the question is whether
# _repair admits it never reached the member.
curl -fsS -m 10 -X POST "http://127.0.0.1:$COORD/index" -d "$(doc b2 gamma)" > /dev/null 2>&1 || true

repaired=$(curl -fsS -m 30 -X POST "http://127.0.0.1:$COORD/_repair")
echo "repair with a dead replica: $repaired"
echo "$repaired" | grep -q '"ok":false' \
  || fail "repair reported ok while a member was unreachable: $repaired"
echo "$repaired" | grep -q "$REPLICA_SHARD" \
  || fail "repair did not name the unreachable member: $repaired"
echo "ok: an unreachable member is reported, not counted as repaired"

echo "ALL REPAIR EDGE CHECKS PASSED"
