#!/usr/bin/env bash
# End-to-end rebalance test: grow a running cluster from 3 shards to 4 without
# reindexing, and check that the prediction, the move and the result all agree.
#
# The claims, in the order they build on each other:
#   1. A 3-shard coordinator serves the right answer before anything moves.
#   2. `GET /_plan?shards=4` predicts exactly how many documents must move.
#   3. `POST /_rebalance?from=3` moves exactly that many — no more, no fewer.
#   4. No document is lost or duplicated: the four shards hold the whole corpus.
#   5. The cluster still equals a single node afterwards.
#   6. `/_plan?shards=4` then reports nothing left to move, and re-running the
#      rebalance is a no-op. This is the check that a partial or repeated run
#      cannot silently double-move documents.
#
# Usage: tools/test-rebalance.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-rebalance.sh <server-binary> [workspace]}"
ROOT="${2:-.}"
SCH="title:6,keywords:3,desc:1,deps:1.5"
CORPUS="$ROOT/demo/data/shards"
LOG="${TMPDIR:-/tmp}/moonseek-rebalance-logs"

rm -rf "$LOG"; mkdir -p "$LOG"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "== starting 4 shards, a single node, and a 3-group coordinator =="
for k in 0 1 2 3; do
  "$BIN" --addr "127.0.0.1:$((7820 + k))" --shard-port "127.0.0.1:$((7920 + k))" \
    --schema "$SCH" > "$LOG/shard-$k.log" 2>&1 &
  pids+=($!)
done
"$BIN" --addr 127.0.0.1:7804 --schema "$SCH" > "$LOG/single.log" 2>&1 &
single_pid=$!
pids+=($single_pid)
"$BIN" --addr 127.0.0.1:7805 --schema "$SCH" \
  --shards "127.0.0.1:7920,127.0.0.1:7921,127.0.0.1:7922" \
  > "$LOG/coord3.log" 2>&1 &
coord_pid=$!
pids+=($coord_pid)

ready=0
for _ in $(seq 1 60); do
  if curl -sf -m 2 http://127.0.0.1:7805/_stats > /dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || { echo "FAIL: coordinator never became ready"; cat "$LOG"/*.log; exit 1; }

echo "== writing 3000 documents through the 3-shard coordinator =="
curl -s -o /dev/null -m 180 -X POST http://127.0.0.1:7804/index/bulk \
  --data-binary "@$CORPUS/all.jsonl"
reply=$(curl -s -m 180 -X POST http://127.0.0.1:7805/index/bulk \
  --data-binary "@$CORPUS/all.jsonl")
echo "write: $reply"
written=$(echo "$reply" | json 'd["indexed"]')
if [ "$written" != "3000" ]; then
  echo "FAIL: coordinator indexed $written of 3000"
  exit 1
fi
echo "ok: 3000 documents written through the coordinator"

# ---- claim 1 and 2: the current answer, and the prediction -----------------
echo "== claim 1: the 3-shard cluster equals a single node =="
python3 "$(dirname "$0")/check-distributed-aggs.py" \
  http://127.0.0.1:7805 http://127.0.0.1:7804 \
  '/search?q=parser&limit=10&dfs=true&facets=domain&agg=versions:stats' || exit 1

echo "== claim 2: the plan predicts the move =="
plan=$(curl -s -m 120 "http://127.0.0.1:7805/_plan?shards=4")
echo "plan: $plan"
eval "$(echo "$plan" | json '"predicted=%d ids=%d ring_pct=%s" % (d["ring"]["moved"], d["ids"], round(d["ring"]["moved_pct"],1))')"
after_dist=$(echo "$plan" | json '"%s" % (d["ring"]["after"],)')
echo "predicted: $predicted of $ids ids move ($ring_pct%)"
if [ "$predicted" -lt 600 ] || [ "$predicted" -gt 900 ]; then
  echo "FAIL: predicted $predicted moves, expected about 750 (25% of 3000)"
  exit 1
fi

# ---- switch the coordinator to four groups ---------------------------------
echo "== restarting the coordinator with the fourth group =="
kill -9 "$coord_pid" 2>/dev/null || true
sleep 1
"$BIN" --addr 127.0.0.1:7805 --schema "$SCH" \
  --shards "127.0.0.1:7920,127.0.0.1:7921,127.0.0.1:7922,127.0.0.1:7923" \
  > "$LOG/coord4.log" 2>&1 &
coord_pid=$!
pids+=($coord_pid)
ready=0
for _ in $(seq 1 60); do
  if curl -sf -m 2 http://127.0.0.1:7805/_stats > /dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || { echo "FAIL: 4-group coordinator never became ready"; cat "$LOG"/coord4.log; exit 1; }

# ---- claim 3: the move happens and matches the prediction ------------------
echo "== claim 3: the rebalance moves what the plan predicted =="
report=$(curl -s -m 300 -X POST "http://127.0.0.1:7805/_rebalance?from=3")
echo "report: $report"
eval "$(echo "$report" | json '"moved=%d deferred=%d missing=%d ok=%s" % (d["moved"], d["deferred"], d["missing_at_source"], d["ok"])')"
if [ "$ok" != "True" ]; then
  echo "FAIL: rebalance reported failures: $report"
  exit 1
fi
if [ "$moved" != "$predicted" ]; then
  echo "FAIL: moved $moved but the plan predicted $predicted"
  exit 1
fi
if [ "$deferred" != "0" ] || [ "$missing" != "0" ]; then
  echo "FAIL: deferred=$deferred missing_at_source=$missing, expected 0 and 0"
  exit 1
fi
echo "ok: moved exactly $moved documents, as predicted"

# ---- claim 4: nothing lost, nothing duplicated -----------------------------
echo "== claim 4: the four shards hold the corpus exactly once =="
total=0
for k in 0 1 2 3; do
  docs=$(curl -s -m 10 "http://127.0.0.1:$((7820 + k))/_stats" | json 'd["docs"]')
  echo "  shard $k holds $docs"
  total=$((total + docs))
done
if [ "$total" != "3000" ]; then
  echo "FAIL: the shards hold $total documents, expected 3000"
  exit 1
fi
echo "ok: 4 shards hold 3000 documents between them"
# And the distribution should be the one the plan predicted.
eval "$(echo "$after_dist" | python3 -c '
import sys, ast
print("expected=\"%s\"" % ast.literal_eval(sys.stdin.read()))')"
counts="[$(
  first=1
  for k in 0 1 2 3; do
    docs=$(curl -s -m 10 "http://127.0.0.1:$((7820 + k))/_stats" | json 'd["docs"]')
    [ "$first" -eq 1 ] || printf ', '
    first=0
    printf '%s' "$docs"
  done
)]"
echo "  distribution $counts, predicted $expected"
if [ "$counts" != "$expected" ]; then
  echo "FAIL: distribution $counts does not match the predicted $expected"
  exit 1
fi
echo "ok: the distribution matches the plan's prediction"

# ---- claim 5: the migrated cluster still equals a single node --------------
echo "== claim 5: the migrated cluster equals a single node =="
python3 "$(dirname "$0")/check-distributed-aggs.py" \
  http://127.0.0.1:7805 http://127.0.0.1:7804 \
  '/search?q=parser&limit=10&dfs=true&facets=domain&agg=versions:stats' || exit 1
python3 "$(dirname "$0")/check-distributed-aggs.py" \
  http://127.0.0.1:7805 http://127.0.0.1:7804 \
  '/search?q=socket%20cache&limit=10&dfs=true&filter=license:MIT' || exit 1

# ---- claim 6: nothing left to move, and a repeat is a no-op ----------------
echo "== claim 6: nothing left to move, and re-running is a no-op =="
settled=$(curl -s -m 120 "http://127.0.0.1:7805/_plan?shards=4" \
  | json 'd["ring"]["moved"]')
if [ "$settled" != "0" ]; then
  echo "FAIL: after rebalancing, the plan still wants to move $settled documents"
  exit 1
fi
echo "ok: the plan now reports 0 documents to move"
again=$(curl -s -m 300 -X POST "http://127.0.0.1:7805/_rebalance?from=3" \
  | json 'd["moved"]')
echo "second run moved: $again"
if [ "$again" != "0" ]; then
  echo "FAIL: a repeated rebalance moved $again documents"
  exit 1
fi
echo "ok: a repeated rebalance is a no-op"

# And the guard that makes it hard to do the wrong thing on purpose.
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
  "http://127.0.0.1:7805/_rebalance")
if [ "$code" = "400" ]; then
  echo "ok: a rebalance with no ?from= is a 400"
else
  echo "FAIL: rebalance without ?from= returned $code, expected 400"
  exit 1
fi

echo "ALL REBALANCE CHECKS PASSED"
