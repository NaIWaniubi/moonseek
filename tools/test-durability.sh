#!/usr/bin/env bash
# Restart-durability end-to-end test.
#
# The claim this checks: a write acknowledged by the server survives a restart.
# Before --data-dir existed the server only *loaded* a snapshot and never wrote
# one, so a restart silently lost everything ingested since then.
#
# Usage: tools/test-durability.sh <server-binary> [workspace]
set -u

BIN=${1:?usage: test-durability.sh <server-binary> [workspace]}
WS=${2:-.}
PORT=${PORT:-7840}
ADDR="127.0.0.1:$PORT"
DATA=$(mktemp -d "${TMPDIR:-/tmp}/moonseek-durable-XXXXXX")
LOG="$DATA/log"
SCHEMA="title:6,body:1"

pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

cleanup() {
  if [ -n "${PID:-}" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi
}
trap cleanup EXIT

start_server() {
  "$BIN" --addr "$ADDR" --data-dir "$DATA" --schema "$SCHEMA" > "$LOG" 2>&1 &
  PID=$!
  for _ in $(seq 1 100); do
    if curl -fsS "http://$ADDR/healthz" > /dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  echo "server did not start; log:"; cat "$LOG"; return 1
}

stop_server() {
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
}

json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],""))' "$1"; }
hits_total() { curl -fsS "http://$ADDR/search?q=$1&limit=0" | json_field total; }

echo "== first boot: write three documents, then restart =="
start_server || fail "initial start"
for i in 1 2 3; do
  curl -fsS -X POST "http://$ADDR/index" \
    -d "{\"id\":\"d$i\",\"fields\":{\"title\":\"moonbit search $i\",\"body\":\"durable document $i\"}}" \
    | grep -q '"ok":true' || fail "write d$i rejected"
done
# facet + numeric + vector on one document, so replay is tested on all of them
curl -fsS -X POST "http://$ADDR/index" \
  -d '{"id":"dv","fields":{"title":"vector doc","body":"embedding"},"facets":{"topic":["search"]},"nums":{"stars":9},"vector":{"emb":[0.1,0.2,0.3]}}' \
  | grep -q '"ok":true' || fail "write dv rejected"
BEFORE=$(hits_total moonbit)
[ "$BEFORE" = "3" ] || fail "expected 3 hits before restart, got $BEFORE"
pass "4 documents accepted, 3 match 'moonbit' before restart"

stop_server
[ -f "$DATA/journal.log" ] || fail "no journal.log was written"
pass "journal.log exists ($(wc -c < "$DATA/journal.log" | tr -d ' ') bytes)"

start_server || fail "restart"
AFTER=$(hits_total moonbit)
[ "$AFTER" = "3" ] || fail "after restart expected 3 hits, got $AFTER"
pass "restart replayed the journal: 3 hits still match"

TITLE=$(hits_total vector)
[ "$TITLE" = "1" ] || fail "dv title lost after replay (expected 1 hit for 'vector', got $TITLE)"
pass "replayed document keeps its text (title still matches)"

# The vector came back too: kNN over the restored index must find dv.
KNN=$(curl -fsS "http://$ADDR/search?q=embedding&knn=emb:0.1,0.2,0.3&knn_k=3&limit=3")
echo "$KNN" | grep -q '"dv"' || fail "kNN did not return the replayed vector: $KNN"
pass "replayed vector is searchable (kNN returns dv)"

# And the numeric column survived: a stats aggregate runs over it.
NUM=$(curl -fsS "http://$ADDR/search?q=embedding&agg=stars:stats&limit=1")
echo "$NUM" | grep -q '"aggs"' || fail "numeric aggregate failed: $NUM"
echo "$NUM" | grep -q '9' || fail "numeric value 9 lost after replay: $NUM"
pass "replayed numeric column is aggregatable (stars=9 survived)"

echo "== checkpoint: snapshot written, journal truncated =="
CK=$(curl -fsS -X POST "http://$ADDR/_checkpoint")
echo "$CK" | grep -q '"ok":true' || fail "checkpoint failed: $CK"
[ -f "$DATA/index.msk" ] || fail "checkpoint wrote no index.msk"
[ "$(wc -c < "$DATA/journal.log" | tr -d ' ')" = "0" ] || fail "journal not truncated"
pass "index.msk written, journal truncated to 0 bytes"

stop_server
start_server || fail "restart after checkpoint"
AFTER2=$(hits_total moonbit)
[ "$AFTER2" = "3" ] || fail "after checkpoint restart expected 3 hits, got $AFTER2"
pass "restart from the checkpoint still has 3 hits"

echo "== a delete is durable too =="
curl -fsS -X DELETE "http://$ADDR/index?id=d1" | grep -q '"deleted":true' || fail "delete failed"
DEL_BEFORE=$(hits_total moonbit)
[ "$DEL_BEFORE" = "2" ] || fail "expected 2 hits after delete, got $DEL_BEFORE"
stop_server
start_server || fail "restart after delete"
DEL_AFTER=$(hits_total moonbit)
[ "$DEL_AFTER" = "2" ] || fail "delete was not durable: expected 2, got $DEL_AFTER"
pass "deletion survives a restart"

echo "== in-memory mode is still allowed, and says so =="
stop_server
"$BIN" --addr "127.0.0.1:$((PORT + 1))" --schema "$SCHEMA" > "$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$((PORT + 1))/healthz" > /dev/null 2>&1 && break
  sleep 0.1
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$((PORT + 1))/_checkpoint")
[ "$CODE" = "400" ] || fail "in-memory checkpoint should be 400, got $CODE"
pass "no --data-dir: checkpoint reports 400 instead of pretending"

echo "ALL DURABILITY CHECKS PASSED"
