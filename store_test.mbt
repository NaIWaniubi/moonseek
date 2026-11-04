///|
async test "save and load roundtrip" {
  let dir = @fs.tmpdir(prefix="moonseek-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/index.msk"
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello world")], })
  idx.add({ id: "b", fields: [("body", "全文搜索")], })
  idx.save(path)
  let loaded = @moonseek.Index::load(path)
  assert_eq(loaded.doc_count(), 2)
  assert_eq(loaded.search("hello")[0].id, "a")
  assert_eq(loaded.search("搜索")[0].id, "b")
}

///|
async test "load_or_create creates then loads" {
  let dir = @fs.tmpdir(prefix="moonseek-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/index.msk"
  let schema : Array[@moonseek.FieldSchema] = [{ name: "body", weight: 1.0, }]
  let fresh = @moonseek.Index::load_or_create(path, schema)
  assert_eq(fresh.doc_count(), 0)
  fresh.add({ id: "x", fields: [("body", "persisted")], })
  fresh.save(path)
  let reopened = @moonseek.Index::load_or_create(path, schema)
  assert_eq(reopened.doc_count(), 1)
  assert_eq(reopened.search("persisted")[0].id, "x")
}

///|
async test "corrupt file is rejected not silently dropped" {
  let dir = @fs.tmpdir(prefix="moonseek-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/index.msk"
  @fs.write_file(path, b"garbage data that is not a snapshot")
  let result = @moonseek.Index::load(path) catch {
    e => {
      assert_true(e is @moonseek.StoreError::CorruptIndex(_))
      return ()
    }
  }
  let _ = result
  fail("corrupt file should raise")
}

///|
async test "save leaves no temp file behind" {
  let dir = @fs.tmpdir(prefix="moonseek-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/index.msk"
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.save(path)
  let entries = @fs.readdir(dir)
  assert_eq(entries.length(), 1)
  assert_true(entries.contains("index.msk"))
}
