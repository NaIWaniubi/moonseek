#!/usr/bin/env bash
# End-to-end cluster test for CI: start three shards and a coordinator, index a
# corpus, and assert the claims the cluster makes.
#
#   1. `?dfs=true` reproduces a single node's ranking exactly.
#   2. Killing a shard produces a partial answer with explicit shard accounting,
#      not a failure and not a silent shortfall.
#   3. The coordinator's placement agrees with the offline splitter that wrote
#      the shard files.
#   4. Adding a shard would move about a quarter of the documents under the ring
#      and about three quarters under modulo.
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
# A second coordinator with the same shard map. The coordinator holds no state,
# so two of them are interchangeable; what they need is the same map, which is
# passed in rather than agreed automatically.
"$BIN" --addr 127.0.0.1:7806 --schema "$SCH" --pool 200 \
  --shards "127.0.0.1:7901,127.0.0.1:7902,127.0.0.1:7903" > "$LOG/coord2.log" 2>&1 &
coord2_pid=$!
pids+=($coord2_pid)

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

# ---- claim 3: placement agrees with the offline splitter ------------------
echo "== claim 3: coordinator placement agrees with the offline splitter =="
ring=$(curl -s -m 5 http://127.0.0.1:7805/_ring)
echo "ring: $ring"
mode=$(echo "$ring" | python3 -c 'import sys,json;print(json.load(sys.stdin)["mode"])' 2>/dev/null)
[ "$mode" = "ring" ] || { echo "FAIL: coordinator mode is '$mode', expected ring"; exit 1; }

# manifest.json names one document the splitter filed on each shard. The
# coordinator must put each of them back on that same shard; if it did not, a
# write routed through the coordinator would land on a shard that does not hold
# the document the splitter gave it.
if [ -f "$CORPUS/manifest.json" ]; then
  for k in 0 1 2; do
    id=$(python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print(m['sample'][$k])" "$CORPUS/manifest.json")
    [ -n "$id" ] && [ "$id" != "None" ] || continue
    got=$(curl -s -m 5 "http://127.0.0.1:7805/_placement?id=$id" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["shard"])' 2>/dev/null)
    if [ "$got" = "$k" ]; then
      echo "ok: $id -> shard $got"
    else
      echo "FAIL: splitter put $id on shard $k, coordinator says $got"
      exit 1
    fi
  done
else
  echo "FAIL: $CORPUS/manifest.json missing (regenerate the corpus)"
  exit 1
fi

# ---- claim 4: the ring reshuffles less than modulo ------------------------
echo "== claim 4: a rebalance plan moves less under the ring than under modulo =="
plan=$(curl -s -m 60 "http://127.0.0.1:7805/_plan?shards=4")
echo "plan: $plan"
eval "$(echo "$plan" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("ids=%d ring_pct=%s mod_pct=%s ring_moved=%d mod_moved=%d" % (
    d["ids"], round(d["ring"]["moved_pct"], 1), round(d["modulo"]["moved_pct"], 1),
    d["ring"]["moved"], d["modulo"]["moved"]))
' 2>/dev/null)"
echo "over $ids ids: ring would move $ring_moved ($ring_pct%), modulo $mod_moved ($mod_pct%)"
python3 - "$ids" "$ring_pct" "$mod_pct" <<'PY' || exit 1
import sys
ids, ring, mod = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
if ids < 3000:
    print("FAIL: plan covered only %d ids" % ids); sys.exit(1)
if not (20.0 <= ring <= 30.0):
    print("FAIL: ring moved %s%%, expected about 25%%" % ring); sys.exit(1)
if not (65.0 <= mod <= 85.0):
    print("FAIL: modulo moved %s%%, expected about 75%%" % mod); sys.exit(1)
print("ok: ring %s%% vs modulo %s%% (ideal 25%%)" % (ring, mod))
PY

# ---- claim 5: distributed facets and aggregations equal a single node ------
echo "== claim 5: distributed facets and aggregations equal a single node =="
AGG_SUFFIX='/search?q=parser&limit=5&dfs=true&facets=domain,license&agg=domain:terms:50&agg=versions:stats&agg=versions:histogram:10&agg=versions:percentiles'
python3 "$(dirname "$0")/check-distributed-aggs.py" \
  http://127.0.0.1:7805 http://127.0.0.1:7804 "$AGG_SUFFIX" || exit 1
# The same check under a filter, because a facet that ignores the filter is the
# classic way a search UI ends up contradicting itself.
FILTERED='/search?q=parser&limit=5&dfs=true&facets=domain&filter=license:MIT&agg=versions:stats'
python3 "$(dirname "$0")/check-distributed-aggs.py" \
  http://127.0.0.1:7805 http://127.0.0.1:7804 "$FILTERED" || exit 1
# And with an aggregation over a query that matches nothing: an empty result set
# has to aggregate to zero on both sides rather than to an error on one.
python3 "$(dirname "$0")/check-distributed-aggs.py" \
  http://127.0.0.1:7805 http://127.0.0.1:7804 \
  '/search?q=zzzznomatch&limit=5&facets=domain&agg=versions:stats&agg=versions:percentiles' || exit 1

# ---- claim 6: a sorted query matches a single node -------------------------
echo "== claim 6: sorted queries match a single node =="
python3 - "$(dirname "$0")" <<'PY' || exit 1
import json
import sys
import urllib.parse
import urllib.request

# (by, order) pairs. `num:` reads the corpus's `versions` numeric field, and is
# the one that needs the shards to ship the value: a coordinator that merged on
# ids while claiming to sort by a field would return the same *set* in an order
# that looks plausible.
SORTS = [("score", "desc"), ("score", "asc"), ("id", "asc"), ("id", "desc"),
         ("num:versions", "asc"), ("num:versions", "desc")]
QUERIES = ["parser", "socket cache", "tensor"]

failures = []


def fetch(port, query, by, order):
    # A score sort compares scores, so it needs the two-phase global statistics
    # or the coordinator ranks with per-shard numbers and honestly returns a
    # different order (that difference is what claim 1 measures). A sort by id or
    # by a numeric field does not read the score at all, so it is compared in the
    # default mode: its correctness must not depend on the scoring statistics.
    extra = "&dfs=true" if by == "score" else ""
    url = ("http://127.0.0.1:%d/search?q=%s&limit=10&sort=%s&order=%s%s"
           % (port, urllib.parse.quote(query), urllib.parse.quote(by), order,
              extra))
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


for query in QUERIES:
    for by, order in SORTS:
        coord = fetch(7805, query, by, order)
        single = fetch(7804, query, by, order)
        if coord.get("sort") != by or coord.get("order") != order:
            failures.append("%s/%s: coordinator reported sort=%s order=%s"
                            % (query, by, coord.get("sort"), coord.get("order")))
            continue
        if coord.get("total") != single.get("total"):
            failures.append("%s %s %s: total %s != %s"
                            % (query, by, order, coord.get("total"),
                               single.get("total")))
        ci = [h["id"] for h in coord["hits"]]
        si = [h["id"] for h in single["hits"]]
        if ci != si:
            failures.append("%s %s %s: coord %s | single %s"
                            % (query, by, order, ci, si))
        else:
            print("  ok: %-14s %s %s -> %s" % (query, by, order,
                                               ", ".join(ci[:3]) + " ..."))

if failures:
    for failure in failures:
        print("FAIL: %s" % failure)
    sys.exit(1)
print("SORTED QUERIES MATCH THE SINGLE NODE")
PY

# A sort the service does not understand must be refused, not silently replaced
# by score order: the parameter is documented, so accepting and ignoring it is
# worse than rejecting it.
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10   "http://127.0.0.1:7805/search?q=parser&sort=year")
if [ "$code" = "400" ]; then
  echo "ok: an unknown sort is a 400"
else
  echo "FAIL: unknown sort returned $code, expected 400"
  exit 1
fi

# ---- claim 7: two coordinators are interchangeable -------------------------
echo "== claim 7: a second coordinator answers identically, and survives the first =="
for _ in $(seq 1 40); do
  curl -sf -m 2 http://127.0.0.1:7806/_stats > /dev/null 2>&1 && break
  sleep 0.5
done
python3 - <<'PY' || exit 1
import json
import sys
import urllib.parse
import urllib.request

QUERIES = ["parser", "socket cache", "scheduler OR allocator"]


def ids(port, query):
    url = ("http://127.0.0.1:%d/search?q=%s&limit=10&dfs=true"
           % (port, urllib.parse.quote(query)))
    with urllib.request.urlopen(url, timeout=30) as response:
        body = json.load(response)
    return body["total"], [h["id"] for h in body["hits"]]


for query in QUERIES:
    a = ids(7805, query)
    b = ids(7806, query)
    if a != b:
        print("FAIL: %s: coordinator 7805 %s, 7806 %s" % (query, a, b))
        sys.exit(1)
    print("  ok: %-24s both coordinators agree (%d hits, total %d)"
          % (query, len(a[1]), a[0]))
print("TWO COORDINATORS ARE INTERCHANGEABLE")
PY

kill -9 "$coord2_pid" 2>/dev/null || true
sleep 1
still=$(curl -s -m 20 "http://127.0.0.1:7805/search?q=parser&limit=5&dfs=true" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["total"])' 2>/dev/null)
if [ -z "$still" ]; then
  echo "FAIL: the surviving coordinator stopped answering after its peer died"
  exit 1
fi
echo "ok: the peer died and the survivor still answers (total $still)"

# ---- claim 2: killing a shard yields a partial answer with accounting ------
echo "== claim 2: shard failure is reported, not hidden =="
before=$(curl -s -m 20 "http://127.0.0.1:7805/search?q=parser&limit=10" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["total"],d["shards"]["ok"])')
before_total=$(echo "$before" | awk '{print $1}')
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
  # The total must actually shrink. A number that is a lower bound presented as
  # an exact count, or a total that ignores the dead shard, both look fine until
  # the answer is wrong. Comparing against the pre-kill total rather than a
  # hard-coded threshold keeps this valid when the corpus changes.
  if [ -n "$total" ] && [ "$total" -lt "$before_total" ]; then
    echo "ok: total dropped $before_total -> $total, so the answer is visibly partial"
  else
    echo "FAIL: total did not drop after losing a shard (before=$before_total after=$total)"
    exit 1
  fi
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
