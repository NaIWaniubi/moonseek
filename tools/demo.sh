#!/usr/bin/env bash
# One-command demo: build the server if needed, start a three-shard cluster and
# a coordinator, ingest the mooncakes registry corpus, and serve the web
# console. Prints the URLs and stays in the foreground.
#
#   tools/demo.sh                 # build (release) if needed, then run
#   MOONSEEK_SKIP_BUILD=1 tools/demo.sh   # assume the binary is built
#
# Ctrl-C stops every process it started.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="${BIN:-_build/native/release/build/server/server.exe}"
[ -f "$BIN" ] || BIN="_build/native/release/build/server/server"
CORPUS="demo/data/shards/all.jsonl"
SCH="title:6,keywords:3,desc:1,deps:1.5"

CONSOLE_PORT="${CONSOLE_PORT:-8080}"
COORD_PORT="${COORD_PORT:-7805}"
SHARD_BASE="${SHARD_BASE:-7801}"
SHARDPORT_BASE="${SHARDPORT_BASE:-7901}"
SHARDS=3

LOG="${TMPDIR:-/tmp}/moonseek-demo"
rm -rf "$LOG"; mkdir -p "$LOG"

pids=()
cleanup() {
  trap - EXIT INT TERM
  echo
  echo "stopping ${#pids[@]} process(es)..."
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup EXIT INT TERM

if [ "${MOONSEEK_SKIP_BUILD:-0}" != "1" ] && [ ! -f "$BIN" ]; then
  echo "== building the server (release) =="
  moon build server --target native --release || {
    echo "FAIL: build failed"; exit 1; }
fi
[ -f "$BIN" ] || { echo "FAIL: server binary not found at $BIN"; exit 1; }

echo "== starting $SHARDS shard groups (each a primary + a replica) + coordinator =="
SHARD_ADDRS=""
for k in $(seq 0 $((SHARDS - 1))); do
  paddr="127.0.0.1:$((SHARD_BASE + k))"
  psport="127.0.0.1:$((SHARDPORT_BASE + k))"
  raddr="127.0.0.1:$((SHARD_BASE + 50 + k))"
  rsport="127.0.0.1:$((SHARDPORT_BASE + 50 + k))"
  "$BIN" --addr "$paddr" --shard-port "$psport" --schema "$SCH" \
    > "$LOG/primary-$k.log" 2>&1 &
  pids+=($!)
  "$BIN" --addr "$raddr" --shard-port "$rsport" --schema "$SCH" \
    > "$LOG/replica-$k.log" 2>&1 &
  pids+=($!)
  SHARD_ADDRS="${SHARD_ADDRS:+$SHARD_ADDRS,}$psport|$rsport"
done
"$BIN" --addr "127.0.0.1:$COORD_PORT" --schema "$SCH" --pool 200 \
  --shards "$SHARD_ADDRS" > "$LOG/coord.log" 2>&1 &
pids+=($!)

printf "waiting for the coordinator"
ready=0
for _ in $(seq 1 60); do
  if curl -sf -m 2 "http://127.0.0.1:$COORD_PORT/_stats" > /dev/null 2>&1; then
    ready=1; break
  fi
  printf "."; sleep 0.5
done
echo
if [ "$ready" -ne 1 ]; then
  echo "FAIL: the coordinator never became ready"; cat "$LOG"/coord.log; exit 1
fi

echo "== ingesting $(wc -l < "$CORPUS" | tr -d ' ') documents through the coordinator =="
code=$(curl -s -o "$LOG/ingest.json" -w '%{http_code}' -m 300 \
  -X POST "http://127.0.0.1:$COORD_PORT/index/bulk" --data-binary "@$CORPUS")
[ "$code" = "200" ] || { echo "FAIL: ingest returned $code"; cat "$LOG/ingest.json"; exit 1; }
cat "$LOG/ingest.json"; echo

echo "== serving the console on :$CONSOLE_PORT =="
(cd console && python3 -m http.server "$CONSOLE_PORT" > "$LOG/console.log" 2>&1) &
pids+=($!)

cat <<EOF

  cluster coordinator : http://127.0.0.1:$COORD_PORT
  console (open this) : http://127.0.0.1:$CONSOLE_PORT/index.html
  try                 : curl "http://127.0.0.1:$COORD_PORT/search?q=parser&limit=5&dfs=true"
  placement / plan    : curl "http://127.0.0.1:$COORD_PORT/_ring"
                        curl "http://127.0.0.1:$COORD_PORT/_plan?shards=4"

  In the console, leave the service address as http://127.0.0.1:$COORD_PORT and click connect.
  Press Ctrl-C to stop everything.

EOF

wait
