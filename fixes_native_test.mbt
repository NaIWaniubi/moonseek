///|
/// Native-only regression tests added in this round for the durable file
/// layer: load_or_create error semantics, checkpoint idempotency across
/// reopen, and WAL replay of unknown fields. They exercise @fs and the
/// native-only store/segment layer, which are excluded from wasm-gc, so
/// they live in a target-restricted file next to wal_native_test.mbt.

///|
async test "load_or_create errors when the file exists but is unreadable" {
  // A directory at the snapshot path: exists but read_file fails.
  let dir = @fs.tmpdir(prefix="moonseek-lc-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/index.msk"
  @fs.mkdir(path)
  let result = @moonseek.Index::load_or_create(path, [
    { name: "body", weight: 1.0, },
  ]) catch {
    e => {
      assert_true(e is @moonseek.StoreError::IoError(_))
      return ()
    }
  }
  let _ = result
  fail("unreadable file must not be silently recreated")
}

///|
async test "checkpoint makes replay idempotent across reopen" {
  // Full write path: durable adds survive reopen; checkpoint clears the
  // WAL; a reopen after checkpoint replays nothing extra.
  let dir = @fs.tmpdir(prefix="moonseek-ck-")
  defer @fs.rmdir(dir, recursive=true)
  let schema : Array[@moonseek.FieldSchema] = [
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ]
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, schema)
  seg.add_durable(dir, durable_doc("a", "moonbit language"))
  seg.add_durable(dir, durable_doc("b", "rust systems"))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, schema)
  assert_eq(reopened.doc_count(), 2)
  reopened.checkpoint(dir)
  let after_ck = @moonseek.SegmentedIndex::open_or_create(dir, schema)
  assert_eq(after_ck.doc_count(), 2)
  assert_eq(durable_ids(after_ck.search("moonbit")), ["a"])
  // WAL file is empty after checkpoint.
  let wal = @fs.read_file(dir + "/wal.log")
  assert_eq(wal.binary().length(), 0)
}

///|
async test "wal replay with unknown field fails as StoreError not abort" {
  // Build a valid store, then hand-craft a WAL whose Add references a
  // field absent from the snapshot schema. open_or_create must raise a
  // catchable StoreError instead of aborting the process.
  let dir = @fs.tmpdir(prefix="moonseek-uf-")
  defer @fs.rmdir(dir, recursive=true)
  let schema : Array[@moonseek.FieldSchema] = [
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ]
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, schema)
  seg.checkpoint(dir)
  // A WAL Add with an unknown field name.
  let entries : Array[@moonseek.WalEntry] = [
    Add({ id: "x", fields: [("ghost", "content"), ("body", "normal")], }),
  ]
  let image = @moonseek.wal_encode(entries)
  @fs.write_file(dir + "/wal.log", image, create_mode=CreateOrTruncate)
  let result = @moonseek.SegmentedIndex::open_or_create(dir, schema) catch {
    e => {
      assert_true(e is @moonseek.StoreError::CorruptIndex(_))
      return ()
    }
  }
  let _ = result
  fail("unknown field in WAL replay must raise, not abort")
}
