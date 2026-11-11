#!/usr/bin/env bash
# End-to-end write-replication test.
#
# Three shard groups, each a primary plus a replica. Every document is written
# **through the coordinator** and must be applied by every member of the group
# that owns it, so that killing a primary loses no data.
#
# The claim this asserts, and the reason it is a separate script from
# test-cluster.sh: a replica is only a replica if the write path reaches it.
# Before replication existed, the failover test had to seed the replica by hand,
# so "failover works" only meant "the coordinator can read from two places".
#
# Usage: tools/test-replication.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-replication.sh <server-binary> [workspace]}"
ROOT="${2:-.}"
SCH="title:6,keywords:3,desc:1,deps:1.5"
CORPUS="$ROOT/demo/data/shards"
LOG="${TMPDIR:-/tmp}/moonseek-repl-logs"

rm -rf "$LOG"; mkdir -p "$LOG"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "== starting 3 primaries + 3 replicas + coordinator =="
# HTTP ports 7810..7815, shard ports 7910..7915.
for k in 0 1 2; do
  "$BIN" --addr "127.0.0.1:$((7810 + k))" --shard-port "127.0.0.1:$((7910 + k))" \
    --schema "$SCH" > "$LOG/primary-$k.log" 2>&1 &
  pids+=($!)
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
if [ "$ready" -ne 1 ]; then
  echo "FAIL: coordinator never became ready"
  cat "$LOG"/*.log
  exit 1
fi

total_docs=$(wc -l < "$CORPUS/all.jsonl")
echo "corpus: $total_docs documents"

# ---- claim 1: a write through the coordinator reaches every group member ----
echo "== claim 1: bulk write through the coordinator is applied by every member =="
reply=$(curl -s -m 180 -X POST http://127.0.0.1:7805/index/bulk \
  --data-binary "@$CORPUS/all.jsonl")
echo "reply: $reply"
eval "$(echo "$reply" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("indexed=%d failed=%d members_ok=%d members=%d" % (
    d["indexed"], d["failed"], d["members_ok"], d["members"]))
' 2>/dev/null)"
if [ "$indexed" != "$total_docs" ] || [ "$failed" != "0" ]; then
  echo "FAIL: indexed=$indexed failed=$failed, expected $total_docs and 0"
  exit 1
fi
if [ "$members_ok" != "$members" ] || [ "$members" != "6" ]; then
  echo "FAIL: members_ok=$members_ok of $members, expected 6 of 6"
  exit 1
fi
echo "ok: $indexed documents applied by $members_ok of $members members"

# Every member must hold a third of the corpus. A replica holding zero is the
# failure this test exists for: it would answer every future query with nothing.
echo "== claim 2: each member holds its shard's share =="
for port in 7810 7811 7812 7813 7814 7815; do
  docs=$(curl -s -m 10 "http://127.0.0.1:$port/_stats" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["docs"])' 2>/dev/null)
  echo "  $port holds $docs documents"
  if [ -z "$docs" ] || [ "$docs" -eq 0 ]; then
    echo "FAIL: $port holds no documents after a replicated write"
    exit 1
  fi
done

# ---- claim 3: killing a primary changes nothing -----------------------------
echo "== claim 3: killing a primary does not change the answer =="
before=$(curl -s -m 20 "http://127.0.0.1:7805/search?q=parser&limit=10&dfs=true" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["total"],d["shards"]["ok"],d["shards"]["failed"],",".join(h["id"] for h in d["hits"]))')
echo "before: $before"

# pids were appended primary-0, replica-0, primary-1, replica-1, primary-2,
# replica-2, coordinator — so primary 0 is index 0.
kill -9 "${pids[0]}" 2>/dev/null || true
sleep 2

after=$(curl -s -m 25 "http://127.0.0.1:7805/search?q=parser&limit=10&dfs=true" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["total"],d["shards"]["ok"],d["shards"]["failed"],",".join(h["id"] for h in d["hits"]))')
echo "after:  $after"
if [ "$before" != "$after" ]; then
  echo "FAIL: losing a primary changed the answer"
  echo "  before: $before"
  echo "  after:  $after"
  exit 1
fi
echo "ok: identical total, ranking and shard accounting after the primary died"

# ---- claim 4: a dead primary is still reported when its replica dies too ----
echo "== claim 4: losing a whole group is reported =="
kill -9 "${pids[1]}" 2>/dev/null || true
sleep 2
degraded=$(curl -s -m 25 "http://127.0.0.1:7805/search?q=parser&limit=10" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["total"],d["shards"]["ok"],d["shards"]["failed"])' 2>/dev/null)
echo "after losing the whole group: $degraded"
ok=$(echo "$degraded" | awk '{print $2}')
failed=$(echo "$degraded" | awk '{print $3}')
if [ "$ok" = "2" ] && [ "$failed" = "1" ]; then
  echo "ok: partial answer reported exactly (ok=2 failed=1)"
else
  echo "FAIL: unexpected accounting ok=$ok failed=$failed"
  exit 1
fi

echo "ALL REPLICATION CHECKS PASSED"
