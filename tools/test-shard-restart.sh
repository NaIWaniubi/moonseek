#!/usr/bin/env bash
# A shard restart must not be visible through a pooled connection.
#
# Connection reuse makes the coordinator hold idle sockets, and every one of
# them is invalid the moment a shard restarts. The failure this test exists to
# catch is the quiet one: the coordinator's first request after the restart
# lands on a dead socket, and if that is reported as "the shard did not answer"
# the cluster serves a partial result for a shard that is in fact healthy again.
# The pool has to retry on a fresh connection instead.
#
# The check is deliberately on the *first* request after the restart, before any
# other traffic has had a chance to replace the stale socket.
#
# Usage: tools/test-shard-restart.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-shard-restart.sh <server-binary> [workspace]}"
SCH="title:6,keywords:3,desc:1,deps:1"
LOG="${TMPDIR:-/tmp}/moonseek-shard-restart-logs"
SHARD_HTTP=7870
SHARD_PORT=7970
COORD=7871

rm -rf "$LOG"; mkdir -p "$LOG"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
fail() { echo "FAIL: $*"; exit 1; }

# `/healthz` answers on the HTTP port, which the process binds in a task group
# alongside the shard listener. On a slow runner the HTTP server can be up while
# the shard protocol port is not listening yet, and then indexing succeeds (it
# goes over HTTP) while the coordinator's fan-out has nothing to connect to. Wait
# for the protocol port, not just for health.
wait_shard_port() {
  local i
  for i in $(seq 1 200); do
    if (exec 3<>/dev/tcp/127.0.0.1/$SHARD_PORT) 2>/dev/null; then
      exec 3<&- 2>/dev/null
      return 0
    fi
    sleep 0.2
  done
  echo "FAIL: shard protocol port $SHARD_PORT never accepted a connection"
  cat "$LOG/shard.log"
  return 1
}

start_shard() {
  "$BIN" --addr "127.0.0.1:$SHARD_HTTP" --shard-port "127.0.0.1:$SHARD_PORT" \
    --schema "$SCH" > "$LOG/shard.log" 2>&1 &
  shard_pid=$!
  pids+=($shard_pid)
  for _ in $(seq 1 80); do
    curl -sf -m 2 "http://127.0.0.1:$SHARD_HTTP/healthz" > /dev/null 2>&1 && break
    sleep 0.25
  done
  curl -sf -m 2 "http://127.0.0.1:$SHARD_HTTP/healthz" > /dev/null 2>&1 || {
    echo "FAIL: shard never became ready"; cat "$LOG/shard.log"; return 1
  }
  wait_shard_port
}

index_docs() {
  local i
  for i in 1 2 3; do
    curl -fsS -m 10 -X POST "http://127.0.0.1:$SHARD_HTTP/index" -d \
      "{\"id\":\"p$i\",\"fields\":{\"title\":\"restart probe $i\",\"keywords\":\"probe\",\"desc\":\"d\",\"deps\":\"\"}}" \
      > /dev/null || return 1
  done
  return 0
}

start_shard || exit 1
"$BIN" --addr "127.0.0.1:$COORD" --schema "$SCH" --pool 200 \
  --shards "127.0.0.1:$SHARD_PORT" > "$LOG/coord.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 80); do
  curl -sf -m 2 "http://127.0.0.1:$COORD/healthz" > /dev/null 2>&1 && break
  sleep 0.25
done

index_docs || fail "indexing before the restart failed"

echo "== warm the coordinator's connection pool =="
for _ in $(seq 1 5); do
  curl -s -m 10 "http://127.0.0.1:$COORD/search?q=probe&limit=10" | grep -q '"total":3' \
    || fail "warm-up query did not see 3 documents"
done
echo "ok: pool warmed with 3 documents per query"

echo "== restart the shard under the pool =="
kill "$shard_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf -m 1 "http://127.0.0.1:$SHARD_HTTP/healthz" > /dev/null 2>&1 || break
  sleep 0.25
done
start_shard || exit 1
index_docs || fail "indexing after the restart failed"

echo "== the first query after the restart must not be a partial answer =="
first=$(curl -s -m 20 "http://127.0.0.1:$COORD/search?q=probe&limit=10")
echo "first answer: $first" | head -c 300; echo
total=$(echo "$first" | json 'd["total"]')
shards=$(echo "$first" | json 'str(d["shards"])')
[ "$total" = "3" ] || {
  echo "shard holds: $(curl -s -m 5 "http://127.0.0.1:$SHARD_HTTP/_stats" | json 'd["docs"]')"
  echo "--- shard log ---"; cat "$LOG/shard.log"
  echo "--- coordinator log ---"; cat "$LOG/coord.log"
  fail "first query after restart returned total=$total, expected 3"
}
echo "$shards" | grep -q "'ok': 1" || fail "first query reported a failed shard: $shards"
echo "ok: a stale pooled socket was retried on a fresh connection"

echo "== and the next query is still exact =="
second=$(curl -s -m 20 "http://127.0.0.1:$COORD/search?q=probe&limit=10" | json 'd["total"]')
[ "$second" = "3" ] || fail "second query returned total=$second, expected 3"
echo "ok: subsequent queries are exact"

echo "ALL SHARD RESTART CHECKS PASSED"
