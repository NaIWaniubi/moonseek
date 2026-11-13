///|
/// Tests for the server journal codec: roundtrip of a full document (text,
/// facets, numbers, vectors), tail truncation recovery, and rejection of a
/// file that is not a journal at all.

///|
fn journal_doc(id : String) -> @moonseek.JournalDoc {
  {
    id,
    fields: [("title", "moonbit"), ("body", "全文搜索引擎")],
    facets: [("topic", ["search", "engine"]), ("lang", ["zh"])],
    nums: [("stars", 42.0), ("score", 0.5)],
    vectors: [("emb", [0.25, -0.5, 1.0])],
  }
}

///|
test "journal: a full document roundtrips through the codec" {
  let entry : @moonseek.JournalEntry = Put(journal_doc("a"))
  let decoded = @moonseek.journal_decode(@moonseek.journal_encode([entry]))
  assert_eq(decoded, [entry])
}

///|
test "journal: every field kind survives, including empty ones" {
  let entries : Array[@moonseek.JournalEntry] = [
    Put(journal_doc("a")),
    Put({ id: "b", fields: [], facets: [], nums: [], vectors: [], }),
    Remove("a"),
  ]
  let decoded = @moonseek.journal_decode(@moonseek.journal_encode(entries))
  assert_eq(decoded, entries)
}

///|
test "journal: a torn tail replays only the complete prefix" {
  let entries : Array[@moonseek.JournalEntry] = [
    Put(journal_doc("a")),
    Put(journal_doc("b")),
  ]
  let full = @moonseek.journal_encode(entries)
  // Cut inside the second frame: the first must survive intact.
  let first_len = @moonseek.journal_encode([entries[0]]).length()
  let cut = Bytes::from_array(full.to_array()[0:first_len + 3])
  let decoded = @moonseek.journal_decode(cut)
  assert_eq(decoded, [entries[0]])
}

///|
test "journal: a flipped byte in a frame drops it rather than misreading it" {
  let entries : Array[@moonseek.JournalEntry] = [Put(journal_doc("a"))]
  let full = @moonseek.journal_encode(entries)
  let raw = full.to_array()
  // Corrupt a payload byte (past the 4-byte header) without touching the CRC.
  let pos = 6
  raw[pos] = (raw[pos].to_int() ^ 0xFF).to_byte()
  let decoded = @moonseek.journal_decode(Bytes::from_array(raw[:]))
  // The frame no longer checks out, so replay stops before it: nothing applies.
  assert_eq(decoded, ([] : Array[@moonseek.JournalEntry]))
}

///|
test "journal: a file that is not a journal is an error, not an empty log" {
  let not_a_journal = Bytes::from_array([b'X', b'Y', b'Z', b'W', b'1'])
  let out = Ok(@moonseek.journal_decode(not_a_journal)) catch { _ => Err(()) }
  assert_true(out is Err(_))
}

///|
test "journal: an empty image decodes to no entries" {
  let decoded = @moonseek.journal_decode(@moonseek.journal_encode([]))
  assert_eq(decoded, ([] : Array[@moonseek.JournalEntry]))
}
