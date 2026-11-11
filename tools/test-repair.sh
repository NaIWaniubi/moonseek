#!/usr/bin/env bash
# End-to-end repair test: a member that missed writes is brought back in line
# with its group's primary, in both directions.
#
# The scenario is the one operators actually hit: a replica is down while the
# cluster takes writes, then comes back. The claims:
#
#   1. A write while a member is down is honestly reported as not fully
#      acknowledged (ok=false, members_ok < members) — not a success.
#   2. The member that was down holds nothing after it starts.
#   3. `POST /_repair` copies the missing documents to it.
#   4. After repair every member holds exactly its primary's document count, and
#      the cluster's answers stop depending on which member answers.
#   5. Repair also removes documents a member holds that its primary does not:
#      the primary is authoritative, and a replica that answers with extra
#      documents reports a different total, which is the state failover must not
#      be in.
#
# Usage: tools/test-repair.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-repair.sh <server-binary> [workspace]}"
ROOT="${2:-.}"
SCH="title:6,keywords:3,desc:1,deps:1.5"
CORPUS="$ROOT/demo/data/shards"
LOG="${TMPDIR:-/tmp}/moonseek-repair-logs"

rm -rf "$LOG"; mkdir -p "$LOG"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
docs_of() { curl -s -m 10 "http://127.0.0.1:$1/_stats" | json 'd["docs"]'; }

echo "== starting 3 primaries and 2 of 3 replicas =="
# HTTP 7810..7815, shard ports 7910..7915. Group k is primary k plus replica k.
primary_pids=()
for k in 0 1 2; do
  "$BIN" --addr "127.0.0.1:$((7810 + k))" --shard-port "127.0.0.1:$((7910 + k))" \
    --schema "$SCH" > "$LOG/primary-$k.log" 2>&1 &
  primary_pids+=($!)
  pids+=($!)
done
for k in 0 1; do
  "$BIN" --addr "127.0.0.1:$((7813 + k))" --shard-port "127.0.0.1:$((7913 + k))" \
    --schema "$SCH" > "$LOG/replica-$k.log" 2>&1 &
  pids+=($!)
done
"$BIN" --addr 127.0.0.1:7805 --schema "$SCH" --pool 200 \
  --shards "127.0.0.1:7910|127.0.0.1:7913,127.0.0.1:7911|127.0.0.1:7914,127.0.0.1:7912|127.0.0.1:7915" \
  > "$LOG/coord.log" 2>&1 &
pids+=($!)

ready=0
for _ in $(seq 1 60); do
  if curl -sf -m 2 http://127.0.0.1:7805/_stats > /dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || { echo "FAIL: coordinator never became ready"; cat "$LOG"/*.log; exit 1; }

# ---- claim 1: a write to a group with a dead member is not called a success -
echo "== claim 1: a partially acknowledged write is reported as not ok =="
reply=$(curl -s -m 180 -X POST http://127.0.0.1:7805/index/bulk \
  --data-binary "@$CORPUS/all.jsonl")
echo "write: $reply"
eval "$(echo "$reply" | json '"indexed=%d failed=%d members_ok=%d members=%d" % (d["indexed"], d["failed"], d["members_ok"], d["members"])')"
if [ "$indexed" != "3000" ]; then
  echo "FAIL: indexed $indexed of 3000"
  exit 1
fi
if [ "$members_ok" != "5" ] || [ "$members" != "6" ]; then
  echo "FAIL: expected 5 of 6 members to acknowledge, got $members_ok of $members"
  exit 1
fi
echo "ok: 5 of 6 members acknowledged, and the reply says so"

# ---- claim 2: the missing replica holds nothing ----------------------------
echo "== claim 2: the member that was down holds nothing =="
"$BIN" --addr 127.0.0.1:7815 --shard-port 127.0.0.1:7915 \
  --schema "$SCH" > "$LOG/replica-2.log" 2>&1 &
replica2_pid=$!
pids+=($replica2_pid)
for _ in $(seq 1 40); do
  curl -sf -m 2 http://127.0.0.1:7815/_stats > /dev/null 2>&1 && break
  sleep 0.5
done
vacant=$(docs_of 7815)
primary2=$(docs_of 7812)
echo "replica 2 holds $vacant, primary 2 holds $primary2"
if [ "$vacant" != "0" ]; then
  echo "FAIL: the late replica holds $vacant documents, expected 0"
  exit 1
fi
if [ "$primary2" -le 0 ]; then
  echo "FAIL: primary 2 holds nothing, so the test proves nothing"
  exit 1
fi
echo "ok: the late replica is empty while its primary has $primary2"

# ---- claim 3 and 4: repair copies the gap and the members agree ------------
echo "== claim 3: repair copies what the member missed =="
report=$(curl -s -m 300 -X POST http://127.0.0.1:7805/_repair)
echo "repair: $report"
eval "$(echo "$report" | json '"moved=%d replicated=%d deferred=%d ok=%s" % (d["moved"], d["replicated"], d["deferred"], d["ok"])')"
if [ "$ok" != "True" ]; then
  echo "FAIL: repair reported failures: $report"
  exit 1
fi
if [ "$moved" != "$primary2" ]; then
  echo "FAIL: repair copied $moved documents, expected $primary2"
  exit 1
fi
echo "ok: repair copied $moved documents, exactly the gap"

echo "== claim 4: every member now holds its primary's count =="
for k in 0 1 2; do
  p=$(docs_of "$((7810 + k))")
  r=$(docs_of "$((7813 + k))")
  echo "  group $k: primary $p, replica $r"
  if [ "$p" != "$r" ]; then
    echo "FAIL: group $k disagrees ($p vs $r)"
    exit 1
  fi
done
echo "ok: all three groups agree"

# ---- claim 5: repair removes what the primary does not have ---------------
echo "== claim 5: a member holding an extra document loses it =="
ghost=$(curl -s -m 10 -X POST http://127.0.0.1:7815/index -d \
  '{"id":"ghost/1","fields":{"title":"ghost","keywords":"ghost","desc":"ghost","deps":""}}')
echo "wrote a document directly to the replica: $ghost"
if [ "$(docs_of 7815)" = "$(docs_of 7812)" ]; then
  echo "FAIL: the direct write to the replica did not land"
  exit 1
fi
repair2=$(curl -s -m 300 -X POST http://127.0.0.1:7805/_repair)
echo "repair: $repair2"
eval "$(echo "$repair2" | json '"removed=%d moved=%d ok=%s" % (d["deferred"], d["moved"], d["ok"])')"
if [ "$removed" -lt 1 ]; then
  echo "FAIL: repair did not remove the extra document"
  exit 1
fi
if [ "$(docs_of 7815)" != "$(docs_of 7812)" ]; then
  echo "FAIL: still disagreeing after repair"
  exit 1
fi
echo "ok: the extra document was removed and the group agrees again"

# The cluster's answers must not depend on which member answers: kill the
# primary of the repaired group and check the answer is unchanged.
echo "== the repaired replica answers as the primary would =="
before=$(curl -s -m 20 "http://127.0.0.1:7805/search?q=parser&limit=10&dfs=true" \
  | json '"%d|" % (d["total"],) + ",".join(h["id"] for h in d["hits"])')
kill -9 "${primary_pids[2]}" 2>/dev/null || true
sleep 2
after=$(curl -s -m 25 "http://127.0.0.1:7805/search?q=parser&limit=10&dfs=true" \
  | json '"%d|" % (d["total"],) + ",".join(h["id"] for h in d["hits"])')
if [ "$before" != "$after" ]; then
  echo "FAIL: losing the repaired group's primary changed the answer"
  echo "  before: $before"
  echo "  after:  $after"
  exit 1
fi
echo "ok: identical answer after the repaired replica took over"

echo "ALL REPAIR CHECKS PASSED"
