///|
/// Tests for the write-ahead log byte codec: roundtrip, crash-tail
/// truncation, and strict rejection of malformed headers.

///|
fn wal_doc(id : String, text : String) -> @moonseek.Document {
  { id, fields: [("title", text), ("body", text)], }
}

///|
fn wal_sample_entries() -> Array[@moonseek.WalEntry] {
  [
    Add(wal_doc("a", "moonbit language")),
    Add(wal_doc("b", "全文搜索引擎")),
    Delete("a"),
    Add(wal_doc("a", "moonbit returns")),
    Delete("missing"),
  ]
}

///|
test "wal: encode decode roundtrip" {
  let entries = wal_sample_entries()
  let data = @moonseek.wal_encode(entries)
  assert_true(data.length() > 4)
  let decoded = @moonseek.wal_decode(data)
  assert_eq(decoded, entries)
}

///|
test "wal: empty log decodes to empty array" {
  let decoded = @moonseek.wal_decode(b"")
  assert_eq(decoded.length(), 0)
  assert_eq(@moonseek.wal_encode([]), b"")
}

///|
test "wal: header-only log decodes to empty array" {
  let decoded = @moonseek.wal_decode(b"MWL1")
  assert_eq(decoded.length(), 0)
}

///|
test "wal: torn header tail is ignored" {
  let entries = wal_sample_entries()
  let data = @moonseek.wal_encode(entries)
  // Append a partial magic, as if the process died mid-header write.
  let buf = data.to_array()
  buf.push(b'M')
  buf.push(b'W')
  let decoded = @moonseek.wal_decode(Bytes::from_array(buf[:]))
  assert_eq(decoded, entries)
}

///|
test "wal: truncated final entry is dropped" {
  let entries = wal_sample_entries()
  let data = @moonseek.wal_encode(entries)
  // Encode just the first two entries to find where the third begins.
  let prefix = @moonseek.wal_encode(entries[:2].to_owned())
  // Cut inside the third entry: header + a few payload bytes, no CRC.
  let buf = data.to_array()
  let torn = buf[:prefix.length() + 6].to_owned()
  let decoded = @moonseek.wal_decode(Bytes::from_array(torn))
  assert_eq(decoded, entries[:2].to_owned())
}

///|
test "wal: bad crc tail stops replay" {
  let entries = wal_sample_entries()
  let data = @moonseek.wal_encode(entries)
  let buf = data.to_array()
  // Flip a payload byte of the third entry (Delete("a")).
  let prefix = @moonseek.wal_encode(entries[:2].to_owned())
  let corrupt_at = prefix.length() + 5
  buf[corrupt_at] = (buf[corrupt_at].to_int() ^ 0xFF).to_byte()
  let decoded = @moonseek.wal_decode(Bytes::from_array(buf[:]))
  assert_eq(decoded, entries[:2].to_owned())
}

///|
test "wal: bad crc in middle stops replay, later entries not trusted" {
  let entries = wal_sample_entries()
  let data = @moonseek.wal_encode(entries)
  let buf = data.to_array()
  // Corrupt the very first entry: nothing may be replayed.
  buf[5] = (buf[5].to_int() ^ 0xFF).to_byte()
  let decoded = @moonseek.wal_decode(Bytes::from_array(buf[:]))
  assert_eq(decoded.length(), 0)
}

///|
test "wal: corrupt magic is rejected" {
  // Same length as the magic but different bytes: not a torn write.
  let result = @moonseek.wal_decode(b"MWL\x02") catch {
    e => {
      assert_true(e is @moonseek.CodecError::BadMagic)
      return ()
    }
  }
  let _ = result
  fail("corrupt magic should raise")
}

///|
test "wal: torn magic prefix is ignored" {
  // A header write torn mid-magic decodes to nothing, not an error.
  assert_eq(@moonseek.wal_decode(b"MW").length(), 0)
  assert_eq(@moonseek.wal_decode(b"M").length(), 0)
}

///|
test "wal: concatenated append batches decode in order" {
  let batch1 : Array[@moonseek.WalEntry] = [
    Add(wal_doc("a", "first")),
    Delete("b"),
  ]
  let batch2 : Array[@moonseek.WalEntry] = [Add(wal_doc("c", "second"))]
  // Simulate two separate file appends, each carrying its own header.
  let buf = @moonseek.wal_encode(batch1).to_array()
  for b in @moonseek.wal_encode(batch2).iter() {
    buf.push(b)
  }
  let decoded = @moonseek.wal_decode(Bytes::from_array(buf[:]))
  let expected = batch1.copy()
  for e in batch2 {
    expected.push(e)
  }
  assert_eq(decoded, expected)
}

///|
test "wal: bad magic is rejected" {
  let result = @moonseek.wal_decode(b"XXXX") catch {
    e => {
      assert_true(e is @moonseek.CodecError::BadMagic)
      return ()
    }
  }
  let _ = result
  fail("bad magic should raise")
}

///|
test "wal: unknown entry type is rejected" {
  // Valid header, then an entry with type byte 0x7F.
  let buf : Array[Byte] = [b'M', b'W', b'L', b'1', 0x7F]
  let result = @moonseek.wal_decode(Bytes::from_array(buf[:])) catch {
    e => {
      assert_true(e is @moonseek.CodecError::BadVersion(127))
      return ()
    }
  }
  let _ = result
  fail("unknown entry type should raise")
}

///|
test "wal: document fields survive roundtrip exactly" {
  let doc : @moonseek.Document = {
    id: "unicode-🚀",
    fields: [
      ("title", "全文搜索 \"quoted\" text"),
      ("body", "line\nbreak\ttab"),
      ("empty", ""),
    ],
  }
  let entries : Array[@moonseek.WalEntry] = [Add(doc), Delete("unicode-🚀")]
  let decoded = @moonseek.wal_decode(@moonseek.wal_encode(entries))
  assert_eq(decoded, entries)
}

///|
test "wal: replay into segmented index matches direct writes" {
  let entries = wal_sample_entries()
  let schema : Array[@moonseek.FieldSchema] = [
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ]
  let replayed = @moonseek.SegmentedIndex::new(schema, segment_max_docs=2)
  let decoded = @moonseek.wal_decode(@moonseek.wal_encode(entries))
  for entry in decoded {
    match entry {
      Add(doc) => replayed.add(doc)
      Delete(id) => ignore(replayed.delete(id))
    }
  }
  let direct = @moonseek.SegmentedIndex::new(schema, segment_max_docs=2)
  for entry in entries {
    match entry {
      Add(doc) => direct.add(doc)
      Delete(id) => ignore(direct.delete(id))
    }
  }
  assert_eq(replayed.doc_count(), direct.doc_count())
  assert_eq(replayed.doc_count(), 2)
  let ids = replayed.search("moonbit", limit=0).map(fn(h) { h.id })
  assert_eq(ids, ["a"])
}

///|
test "wal: encoding is deterministic" {
  let entries = wal_sample_entries()
  assert_eq(@moonseek.wal_encode(entries), @moonseek.wal_encode(entries))
}
