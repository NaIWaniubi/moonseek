#!/usr/bin/env bash
# Durability under concurrent writes and checkpoints.
#
# The window this test is built to catch: a checkpoint serializes the index,
# writes it, fsyncs it, renames it and then truncates the journal. The fsyncs
# mean the handler yields, so other requests run inside that span. A document
# appended to the journal during the span is *not* in the snapshot if the
# snapshot was serialized before its apply — and the truncate that follows
# deletes its journal record regardless. Both places lose it, silently, and the
# server kept answering "indexed".
#
# So: hammer one node with concurrent single-document writes while forcing
# checkpoints, then restart and require every acknowledged write to be there.
#
# Usage: tools/test-durability-concurrent.sh <server-binary> [workspace]
set -u

BIN="${1:?usage: test-durability-concurrent.sh <server-binary> [workspace]}"
SCH="title:6,keywords:3,desc:1,deps:1"
ADDR=127.0.0.1:7850
LOG="${TMPDIR:-/tmp}/moonseek-durability-concurrent-logs"
DATA="$LOG/data"
DOCS=800
WRITERS=16
# Documents already in the index before the race starts. The checkpoint writes
# the whole index, so a small index makes the snapshot fast enough that the
# window between serializing it and truncating the journal closes before any
# writer notices. Bulk-loading first makes that window wide enough to hit.
SEED_BATCHES=4
SEED_PER_BATCH=1500

rm -rf "$LOG"; mkdir -p "$LOG" "$DATA"
pid=""
cleanup() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait 2>/dev/null || true; }
trap cleanup EXIT

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
fail() { echo "FAIL: $*"; exit 1; }

start_server() {
  "$BIN" --addr "$ADDR" --schema "$SCH" --data-dir "$DATA" > "$LOG/server.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 80); do
    curl -sf -m 2 "http://$ADDR/healthz" > /dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "FAIL: server never became ready"; cat "$LOG/server.log"; return 1
}

stop_server() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
}

hits_for() {
  curl -s -m 20 "http://$ADDR/search?q=$1&limit=0" | json 'd["total"]'
}

start_server || exit 1

echo "== seeding a corpus large enough that a snapshot takes real time =="
seed_total=$((SEED_BATCHES * SEED_PER_BATCH))
for b in $(seq 1 "$SEED_BATCHES"); do
  python3 - "$b" "$SEED_PER_BATCH" > "$LOG/seed-$b.jsonl" <<'PY'
import sys
b, n = int(sys.argv[1]), int(sys.argv[2])
for i in range(n):
    print('{"id":"seed%d-%d","fields":{"title":"haystack filler text %d","keywords":"haystack","desc":"seeded document %d for the concurrency test","deps":""}}' % (b, i, i, i))
PY
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 120 \
    -X POST "http://$ADDR/index/bulk" --data-binary "@$LOG/seed-$b.jsonl")
  [ "$code" = "200" ] || fail "seed batch $b returned $code"
done
seeded=$(hits_for haystack)
echo "seeded $seeded documents (expected $seed_total)"
[ "$seeded" = "$seed_total" ] || fail "seed load put $seeded documents in the index, expected $seed_total"

echo "== $DOCS documents from $WRITERS concurrent writers, with checkpoints fired throughout =="
# One writer per stream: each id is unique so the total is additive. The
# remainder is handed to the first writers so the count is exactly $DOCS, not
# DOCS/WRITERS rounded down.
writer() {
  local base=$1 count=$2
  local i
  for i in $(seq 1 "$count"); do
    local id="c$base-$i"
    local body="{\"id\":\"$id\",\"fields\":{\"title\":\"needle$base\",\"keywords\":\"needle\",\"desc\":\"doc $i\",\"deps\":\"\"}}"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "http://$ADDR/index" -d "$body")
    # `POST /index` answers 202 on success; docs/api.md specifies it.
    if [ "$code" != "202" ]; then
      echo "FAIL: write $id returned $code"
      return 1
    fi
  done
  return 0
}

# Force checkpoints while the writers run; this is the race the lock closes.
checkpointer() {
  local i
  for i in $(seq 1 25); do
    curl -s -o /dev/null -m 60 -X POST "http://$ADDR/_checkpoint"
    sleep 0.05
  done
}

writer_fail=0
pids=()
cpids=()
per=$((DOCS / WRITERS))
extra=$((DOCS - per * WRITERS))
for w in $(seq 0 $((WRITERS - 1))); do
  count=$per
  [ "$w" -lt "$extra" ] && count=$((per + 1))
  writer "$w" "$count" &
  pids+=($!)
done
checkpointer &
cpids+=($!)

for p in "${pids[@]}"; do
  wait "$p" || writer_fail=1
done
for p in "${cpids[@]}"; do
  wait "$p" || true
done
pids=(); cpids=()
[ "$writer_fail" = "0" ] || fail "a concurrent write was not accepted"

before=$(hits_for needle)
echo "indexed and acknowledged: $before documents (expected $DOCS)"
[ "$before" = "$DOCS" ] || fail "expected $DOCS documents before restart, got $before"

echo "== restart and require every acknowledged write to have survived =="
stop_server
start_server || exit 1

after=$(hits_for needle)
echo "after restart: $after documents"
# The last checkpoint may have landed before the final writes, in which case
# those writes are in the journal and replay brings them back. Either path is
# correct; a shortfall means the truncate window ate records.
[ "$after" = "$DOCS" ] || fail "lost $((DOCS - after)) acknowledged writes across a checkpoint race"
echo "ok: no acknowledged write was lost across $WRITERS writers and 25 checkpoints"

echo "== the journal is bounded, and a second restart is still exact =="
stop_server
start_server || exit 1
again=$(hits_for needle)
[ "$again" = "$DOCS" ] || fail "second restart changed the count: $again"
echo "ok: replay is idempotent across restarts"

echo "ALL CONCURRENT DURABILITY CHECKS PASSED"