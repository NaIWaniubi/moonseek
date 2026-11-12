#!/usr/bin/env bash
# The demo story, as a script: start a replicated cluster, load it, search it,
# grow it, heal it, break it — with narrated step banners, so the whole thing is
# one screen recording.
#
#   tools/demo-story.sh                 # full story, ~2 minutes
#   DEMO_PAUSE=0 tools/demo-story.sh    # no waiting (CI / smoke)
#   DEMO_KEEP=1 tools/demo-story.sh     # leave the cluster running at the end
#
# Every number printed is produced by the running cluster, not hard-coded.
#
# Topology: four shard groups, each a primary plus a replica, plus a single node
# on :7804 purely for the "the cluster equals one node" comparison.
#   primaries : HTTP 7810..7813   shard-port 7910..7913
#   replicas  : HTTP 7820..7823   shard-port 7920..7923
#   single    : HTTP 7804
#   coordinator : HTTP 7805
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="${BIN:-_build/native/release/build/server/server.exe}"
[ -f "$BIN" ] || BIN="_build/native/release/build/server/server"
CORPUS="demo/data/shards/all.jsonl"
SCH="title:6,keywords:3,desc:1,deps:1.5"
PAUSE="${DEMO_PAUSE:-2}"
COORD=7805
SINGLE=7804
CONSOLE_PORT="${CONSOLE_PORT:-8080}"

LOG="${TMPDIR:-/tmp}/moonseek-story"
rm -rf "$LOG"; mkdir -p "$LOG"
pids=()

cleanup() {
  trap - EXIT INT TERM
  if [ "${DEMO_KEEP:-0}" = "1" ]; then
    echo
    echo "cluster left running (DEMO_KEEP=1). Ctrl-C here stops it."
    wait
    return
  fi
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say()   { printf '\n\033[1;36m== %s\033[0m\n' "$*"; sleep "$PAUSE"; }
note()  { printf '   %s\n' "$*"; }
json()  { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
ph()    { echo "$((7810 + $1))"; }   # primary HTTP port
ps()    { echo "$((7910 + $1))"; }   # primary shard port
rh()    { echo "$((7820 + $1))"; }   # replica HTTP port
rs()    { echo "$((7920 + $1))"; }   # replica shard port

wait_ready() {
  for _ in $(seq 1 60); do
    curl -sf -m 2 "http://127.0.0.1:$1/_stats" > /dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

[ -f "$BIN" ] || { echo "building..."; moon build server --target native --release || exit 1; }

say "0/8  one binary is a node, a shard or a coordinator — starting 4 primary+replica groups"
for k in 0 1 2 3; do
  "$BIN" --addr "127.0.0.1:$(ph $k)" --shard-port "127.0.0.1:$(ps $k)" --schema "$SCH" \
    > "$LOG/primary-$k.log" 2>&1 &
  pids+=($!)
  "$BIN" --addr "127.0.0.1:$(rh $k)" --shard-port "127.0.0.1:$(rs $k)" --schema "$SCH" \
    > "$LOG/replica-$k.log" 2>&1 &
  pids+=($!)
done
"$BIN" --addr "127.0.0.1:$SINGLE" --schema "$SCH" > "$LOG/single.log" 2>&1 &
pids+=($!)
"$BIN" --addr "127.0.0.1:$COORD" --schema "$SCH" --pool 200 \
  --shards "127.0.0.1:$(ps 0)|127.0.0.1:$(rs 0),127.0.0.1:$(ps 1)|127.0.0.1:$(rs 1),127.0.0.1:$(ps 2)|127.0.0.1:$(rs 2)" \
  > "$LOG/coord3.log" 2>&1 &
coord_pid=$!
pids+=($coord_pid)
wait_ready "$COORD" || { echo "FAIL: coordinator not ready"; cat "$LOG"/*.log; exit 1; }
note "coordinator :$COORD over 3 replicated groups; single node :$SINGLE for comparison"

say "1/8  loading the corpus through the coordinator (routed + replicated to every member)"
note "$(wc -l < "$CORPUS" | tr -d ' ') documents"
curl -s -o /dev/null -m 180 -X POST "http://127.0.0.1:$SINGLE/index/bulk" --data-binary "@$CORPUS"
reply=$(curl -s -m 180 -X POST "http://127.0.0.1:$COORD/index/bulk" --data-binary "@$CORPUS")
note "coordinator: $reply"

say "2/8  search"
for q in "parser" "socket%20cache" "%22zero-copy%22" "scheduler%20OR%20allocator"; do
  curl -s -m 20 "http://127.0.0.1:$COORD/search?q=$q&limit=3&highlight=desc" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("   q=%-26s total=%-5d  top: %s"
      % (d["query"], d["total"], ", ".join(h["id"] for h in d["hits"][:3])))' 2>/dev/null
done

say "3/8  globally consistent scoring (?dfs=true) — byte-for-byte a single node"
python3 - <<'PY'
import json, urllib.parse, urllib.request
def ids(port, q, dfs):
    url = "http://127.0.0.1:%d/search?q=%s&limit=10%s" % (port, urllib.parse.quote(q), "&dfs=true" if dfs else "")
    with urllib.request.urlopen(url, timeout=30) as r:
        return [h["id"] for h in json.load(r)["hits"]]
for q in ["parser", "socket cache", "scheduler OR allocator"]:
    print("   %-24s coordinator == single node: %s" % (q, ids(7805, q, True) == ids(7804, q, False)))
PY

say "4/8  hybrid retrieval: BM25 fused with vector kNN, fanned out, equal to one node"
python3 - <<'PY'
import json, math, random, urllib.parse, urllib.request
rng = random.Random(7)
def unit():
    v = [rng.uniform(-1, 1) for _ in range(8)]
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]
docs = [{"id": "vec-%d" % i,
         "fields": {"title": "vector doc %d" % i, "desc": "about parser socket %d" % i},
         "vector": {"emb": unit()}} for i in range(200)]
for port in (7804, 7805):
    req = urllib.request.Request("http://127.0.0.1:%d/index/bulk" % port,
                                 data="\n".join(json.dumps(d) for d in docs).encode())
    urllib.request.urlopen(req, timeout=60).read()
def run(port):
    p = urllib.parse.urlencode({"q": "parser socket", "limit": "5",
                                "knn": "emb:" + ",".join("%.5f" % v for v in qv),
                                "knn_k": "50", "knn_exact": "true"})
    with urllib.request.urlopen("http://127.0.0.1:%d/search?%s" % (port, p), timeout=30) as r:
        return json.load(r)
# One query vector, used on both sides, so the comparison is about the fan-out.
qv = unit()
c, s = run(7805), run(7804)
print("   coordinator fused top-5 == single node: %s"
      % ([h["id"] for h in c["hits"]] == [h["id"] for h in s["hits"]]))
print("   ranks: %s" % ", ".join("%s(l%s/v%s)" % (h["id"], h["lexical_rank"], h["vector_rank"]) for h in c["hits"][:3]))
PY

say "5/8  grow the cluster 3 -> 4 groups without a reindex"
plan=$(curl -s -m 120 "http://127.0.0.1:$COORD/_plan?shards=4")
echo "$plan" | python3 -c '
import sys, json
d = json.load(sys.stdin); r = d["ring"]
print("   plan: move %d of %d (%.1f%%); predicted distribution %s"
      % (r["moved"], d["ids"], r["moved_pct"], r["after"]))' 2>/dev/null || echo "   plan: $plan"
eval "$(echo "$plan" | json '"predicted=%d" % d["ring"]["moved"]')"
kill -9 "$coord_pid" 2>/dev/null || true; sleep 1
"$BIN" --addr "127.0.0.1:$COORD" --schema "$SCH" --pool 200 \
  --shards "127.0.0.1:$(ps 0)|127.0.0.1:$(rs 0),127.0.0.1:$(ps 1)|127.0.0.1:$(rs 1),127.0.0.1:$(ps 2)|127.0.0.1:$(rs 2),127.0.0.1:$(ps 3)|127.0.0.1:$(rs 3)" \
  > "$LOG/coord4.log" 2>&1 &
coord_pid=$!
pids+=($coord_pid)
wait_ready "$COORD" || { echo "FAIL: 4-group coordinator not ready"; exit 1; }
report=$(curl -s -m 300 -X POST "http://127.0.0.1:$COORD/_rebalance?from=3")
note "rebalance: $report"
note "moved ${predicted:-?} as predicted; primaries now hold:"
for k in 0 1 2 3; do
  note "  group $k: $(curl -s -m 10 "http://127.0.0.1:$(ph $k)/_stats" | json 'd["docs"]') docs"
done

say "6/8  a replica diverges, then POST /_repair brings it back"
victim=$(curl -s -m 20 "http://127.0.0.1:$(rh 0)/search?q=parser&limit=1" | json 'd["hits"][0]["id"]')
before=$(curl -s -m 10 "http://127.0.0.1:$(rh 0)/_stats" | json 'd["docs"]')
note "replica of group 0 holds $before documents; deleting $victim directly on it"
curl -s -o /dev/null -m 10 -X DELETE "http://127.0.0.1:$(rh 0)/index?id=$victim"
dropped=$(curl -s -m 10 "http://127.0.0.1:$(rh 0)/_stats" | json 'd["docs"]')
note "replica now holds $dropped (diverged from its primary)"
note "repair: $(curl -s -m 60 -X POST "http://127.0.0.1:$COORD/_repair")"
after=$(curl -s -m 10 "http://127.0.0.1:$(rh 0)/_stats" | json 'd["docs"]')
note "replica now holds $after — back in line with its primary ($before needed)"
python3 - <<'PY'
import json, urllib.request
a = json.load(urllib.request.urlopen("http://127.0.0.1:7805/search?q=parser&limit=1&dfs=true", timeout=30))["total"]
b = json.load(urllib.request.urlopen("http://127.0.0.1:7804/search?q=parser&limit=1", timeout=30))["total"]
print("   coordinator total == single node total: %s (%d)" % (a == b, a))
PY

say "7/8  kill a primary, then its replica — the answer survives, then degrades honestly"
before=$(curl -s -m 20 "http://127.0.0.1:$COORD/search?q=parser&limit=10&dfs=true" \
  | json '"%d %d/%d %s" % (d["total"], d["shards"]["ok"], d["shards"]["total"], ",".join(h["id"] for h in d["hits"]))')
note "before: $before"
# pids: primary0, replica0, primary1, replica1, ..., single, coord3, coord4
kill -9 "${pids[0]}" 2>/dev/null || true; sleep 2
note "primary of group 0 killed; its replica takes over:"
after=$(curl -s -m 25 "http://127.0.0.1:$COORD/search?q=parser&limit=10&dfs=true" \
  | json '"%d %d/%d %s" % (d["total"], d["shards"]["ok"], d["shards"]["total"], ",".join(h["id"] for h in d["hits"]))')
note "after:  $after"
[ "$before" = "$after" ] && note "-> identical total, ranking and accounting (failover is invisible)" \
  || note "-> CHANGED (see above)"
kill -9 "${pids[1]}" 2>/dev/null || true; sleep 2
note "now its replica too (the whole group is gone):"
curl -s -m 25 "http://127.0.0.1:$COORD/search?q=parser&limit=3" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("   shards: %s" % d["shards"])
print("   still serving %d hits (total %d), failure named, not hidden" % (len(d["hits"]), d["total"]))'

say "8/8  open the console"
(cd console && python3 -m http.server "$CONSOLE_PORT" > "$LOG/console.log" 2>&1) &
pids+=($!)
cat <<EOF

   console : http://127.0.0.1:$CONSOLE_PORT/index.html   (service address: http://127.0.0.1:$COORD)
   coord   : http://127.0.0.1:$COORD

   end of story.
EOF
sleep "$PAUSE"
