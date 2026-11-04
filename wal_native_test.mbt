///|
/// Native-only tests for the durable file layer: open_or_create,
/// add_durable + checkpoint, and crash recovery from a torn WAL tail.

///|
fn durable_schema() -> Array[@moonseek.FieldSchema] {
  [{ name: "title", weight: 3.0, }, { name: "body", weight: 1.0, }]
}

///|
fn durable_doc(id : String, text : String) -> @moonseek.Document {
  { id, fields: [("title", text), ("body", text)], }
}

///|
fn durable_ids(hits : Array[@moonseek.Hit]) -> Array[String] {
  let ids = hits.map(fn(h) { h.id })
  ids.sort()
  ids
}

///|
async test "durable: open_or_create on empty directory" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(seg.doc_count(), 0)
  assert_eq(seg.segment_count(), 0)
  seg.add(durable_doc("a", "in memory only"))
  assert_eq(durable_ids(seg.search("memory")), ["a"])
}

///|
async test "durable: add_durable survives reopen without checkpoint" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "moonbit language"))
  seg.add_durable(dir, durable_doc("b", "rust language"))
  assert_true(seg.delete_durable(dir, "a"))
  // Simulate a crash: drop the in-memory state entirely and reopen.
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 1)
  assert_eq(durable_ids(reopened.search("language")), ["b"])
  assert_eq(reopened.search("moonbit").length(), 0)
}

///|
async test "durable: checkpoint then reopen reads snapshot" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "moonbit"))
  seg.add_durable(dir, durable_doc("b", "全文搜索"))
  seg.checkpoint(dir)
  // After checkpoint the WAL is cleared; state lives in segments.msk.
  let entries = @fs.readdir(dir)
  assert_true(entries.contains("segments.msk"))
  assert_true(!entries.contains("segments.msk.tmp"))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 2)
  assert_eq(durable_ids(reopened.search("moonbit")), ["a"])
  assert_eq(durable_ids(reopened.search("搜索")), ["b"])
}

///|
async test "durable: wal replay on top of checkpoint" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "moonbit"))
  seg.checkpoint(dir)
  seg.add_durable(dir, durable_doc("b", "rust"))
  seg.add_durable(dir, durable_doc("c", "python"))
  assert_true(seg.delete_durable(dir, "a"))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 2)
  assert_eq(durable_ids(reopened.search("*", limit=0)), ["b", "c"])
}

///|
async test "durable: torn wal tail replays only complete entries" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "first entry"))
  seg.add_durable(dir, durable_doc("b", "second entry"))
  // Simulate a crash mid-append: truncate the last entry's frame.
  let wal_path = dir + "/wal.log"
  let data = @fs.read_file(wal_path).binary()
  assert_true(data.length() > 10)
  let torn = data.clamped_view(end=data.length() - 7).to_owned()
  @fs.write_file(wal_path, torn)
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 1)
  assert_eq(durable_ids(reopened.search("first")), ["a"])
  assert_eq(reopened.search("second").length(), 0)
}

///|
async test "durable: corrupt wal crc stops replay at that entry" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "first entry"))
  seg.add_durable(dir, durable_doc("b", "second entry"))
  let wal_path = dir + "/wal.log"
  let data = @fs.read_file(wal_path).binary()
  let buf = data.to_array()
  // Flip a byte inside the second entry's payload (after the first frame).
  let first_frame = @moonseek.wal_encode([
    @moonseek.WalEntry::Add(durable_doc("a", "first entry")),
  ])
  let corrupt_at = first_frame.length() + 6
  buf[corrupt_at] = (buf[corrupt_at].to_int() ^ 0xFF).to_byte()
  @fs.write_file(wal_path, Bytes::from_array(buf[:]))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 1)
  assert_eq(durable_ids(reopened.search("first")), ["a"])
}

///|
async test "durable: corrupt snapshot is rejected" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.write_file(dir + "/segments.msk", b"not a snapshot at all")
  let result = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema()) catch {
    e => {
      assert_true(e is @moonseek.StoreError::CorruptIndex(_))
      return ()
    }
  }
  let _ = result
  fail("corrupt snapshot should raise")
}

///|
async test "durable: updates across checkpoint keep newest version" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "old zebra"))
  seg.checkpoint(dir)
  seg.add_durable(dir, durable_doc("a", "new walrus"))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 1)
  assert_eq(reopened.search("zebra").length(), 0)
  assert_eq(durable_ids(reopened.search("walrus")), ["a"])
  assert_eq(reopened.get_document("a"), Some(durable_doc("a", "new walrus")))
}

///|
async test "durable: checkpoint is atomic and repeatable" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  seg.add_durable(dir, durable_doc("a", "alpha"))
  seg.checkpoint(dir)
  seg.checkpoint(dir)
  let entries = @fs.readdir(dir)
  assert_true(entries.contains("segments.msk"))
  assert_true(!entries.contains("segments.msk.tmp"))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(reopened.doc_count(), 1)
  assert_eq(durable_ids(reopened.search("alpha")), ["a"])
}

///|
async test "durable: empty wal file is tolerated" {
  let dir = @fs.tmpdir(prefix="moonseek-wal-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.write_file(dir + "/wal.log", b"")
  let seg = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(seg.doc_count(), 0)
  seg.add_durable(dir, durable_doc("a", "after empty wal"))
  let reopened = @moonseek.SegmentedIndex::open_or_create(dir, durable_schema())
  assert_eq(durable_ids(reopened.search("empty")), ["a"])
}
