#!/usr/bin/env bash
# End-to-end cluster test for CI: start three shards and a coordinator, index a
# corpus, and assert the two claims the cluster makes.
#
#   1. `?dfs=true` reproduces a single node's ranking exactly.
#   2. Killing a shard produces a partial answer with explicit shard accounting,
#      not a failure and not a silent shortfall.
#
# Usage: tools/test-cluster.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-cluster.sh <server-binary> [workspace]}"
ROOT="${2:-.}"
SCH="title:6,keywords:3,desc:1,deps:1.5"
CORPUS="$ROOT/demo/data/shards"
LOG="${TMPDIR:-/tmp}/moonseek-cluster-logs"

rm -rf "$LOG"; mkdir -p "$LOG"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "== starting 3 shards + single node + coordinator =="
for k in 0 1 2; do
  "$BIN" --addr "127.0.0.1:$((7801 + k))" --shard-port "127.0.0.1:$((7901 + k))" \
    --schema "$SCH" > "$LOG/shard-$k.log" 2>&1 &
  pids+=($!)
done
"$BIN" --addr 127.0.0.1:7804 --schema "$SCH" > "$LOG/single.log" 2>&1 &
pids+=($!)
"$BIN" --addr 127.0.0.1:7805 --schema "$SCH" --pool 200 \
  --shards "127.0.0.1:7901,127.0.0.1:7902,127.0.0.1:7903" > "$LOG/coord.log" 2>&1 &
pids+=($!)

# Wait for readiness rather than sleeping a fixed amount.
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

echo "== indexing =="
for k in 0 1 2; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 120 \
    -X POST "http://127.0.0.1:$((7801 + k))/index/bulk" \
    --data-binary "@$CORPUS/shard-$k.jsonl")
  [ "$code" = "200" ] || { echo "FAIL: shard $k ingest returned $code"; exit 1; }
done
curl -s -o /dev/null -m 180 -X POST http://127.0.0.1:7804/index/bulk \
  --data-binary "@$CORPUS/all.jsonl"

# ---- claim 1: dfs reproduces the single node exactly -----------------------
echo "== claim 1: dfs ranking equals a single node =="
# One query per line: splitting on whitespace would break the multi-word
# queries, which are the ones that exercise the boolean merge across shards.
QUERIES='parser
compiler%20AND%20gc
%22zero-copy%22
scheduler%20OR%20allocator
tensor
socket%20cache
lexer%20parser%20graph'
fail=0
while IFS= read -r q; do
  [ -n "$q" ] || continue
  coord=$(curl -s -m 20 "http://127.0.0.1:7805/search?q=$q&limit=10&dfs=true" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(",".join(h["id"] for h in d["hits"]));print(d["dfs"])' 2>/dev/null)
  single=$(curl -s -m 20 "http://127.0.0.1:7804/search?q=$q&limit=10" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(",".join(h["id"] for h in d["hits"]))' 2>/dev/null)
  ci=$(echo "$coord" | head -1); dfs=$(echo "$coord" | tail -1)
  if [ "$ci" != "$single" ]; then
    echo "FAIL: $q ranking differs"
    echo "  coord:  $ci"
    echo "  single: $single"
    fail=1
  elif [ "$dfs" != "True" ]; then
    echo "FAIL: $q did not report dfs=true"
    fail=1
  else
    echo "ok: $q identical (${#ci} chars of ids)"
  fi
done <<EOF
$QUERIES
EOF
[ "$fail" -eq 0 ] || exit 1

# ---- claim 2: killing a shard yields a partial answer with accounting ------
echo "== claim 2: shard failure is reported, not hidden =="
before=$(curl -s -m 20 "http://127.0.0.1:7805/search?q=parser&limit=10" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["total"],d["shards"]["ok"])')
echo "before: total=$before"

# Kill shard 1 by the PID recorded at startup. Matching on command-line
# arguments is unreliable across platforms (and the coordinator's own command
# line contains every shard address, so a loose match kills the wrong process).
kill -9 "${pids[1]}" 2>/dev/null || true

sleep 2

after=$(curl -s -m 25 "http://127.0.0.1:7805/search?q=parser&limit=10" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["total"],d["shards"]["ok"],d["shards"]["failed"])' 2>/dev/null)
echo "after:  total=$after"
total=$(echo "$after" | awk '{print $1}')
ok=$(echo "$after" | awk '{print $2}')
failed=$(echo "$after" | awk '{print $3}')
if [ -z "$ok" ]; then
  echo "FAIL: coordinator stopped answering after a shard died"
  exit 1
fi
if [ "$ok" = "2" ] && [ "$failed" = "1" ]; then
  echo "ok: partial answer reported exactly (ok=2 failed=1)"
  if [ "$total" -ge "2376" ]; then
    echo "FAIL: total did not drop after losing a shard (total=$total)"
    exit 1
  fi
  echo "ok: total dropped to $total, so the answer is visibly partial"
else
  echo "FAIL: unexpected shard accounting ok=$ok failed=$failed"
  exit 1
fi

health=$(curl -s -m 5 http://127.0.0.1:7805/healthz)
case "$health" in
  *'"status":"ok"'*) echo "ok: coordinator still healthy" ;;
  *) echo "FAIL: coordinator healthz: $health"; exit 1 ;;
esac

echo "ALL CLUSTER CHECKS PASSED"
