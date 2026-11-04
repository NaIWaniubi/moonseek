///|
/// Property: snapshot roundtrip preserves search results for any corpus.
test "property: snapshot roundtrip preserves hits" {
  @quickcheck.check(
    (words : Array[String]) => {
      let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
      let mut i = 0
      for w in words {
        idx.add({ id: "d\{i}", fields: [("body", w)], })
        i += 1
      }
      let restored = @moonseek.Index::from_bytes(idx.to_bytes()) catch {
        _ => return false
      }
      if restored.doc_count() != idx.doc_count() {
        return false
      }
      // Every indexed word must still find its document.
      i = 0
      for w in words {
        let tokens = @moonseek.tokenize(w)
        if tokens.length() > 0 {
          let hits = restored.search(tokens[0].term, limit=0) catch {
            _ => return false
          }
          let mut found = false
          for h in hits {
            if h.id == "d\{i}" {
              found = true
            }
          }
          if !found {
            return false
          }
        }
        i += 1
      }
      true
    },
    count=100,
  )
}

///|
/// Property: varint roundtrip for any non-negative integer.
test "property: varint roundtrip" {
  @quickcheck.check(
    (values : Array[Int32]) => {
      let buf : Array[Byte] = []
      let positives : Array[Int32] = []
      for v in values {
        // Map to non-negative range; -Int32::MIN overflows, so use lsr.
        let p = v.reinterpret_as_uint().reinterpret_as_int() & 0x7FFFFFFF
        positives.push(p)
        @moonseek.write_varint(buf, p)
      }
      let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
      for p in positives {
        let decoded = reader.read_varint() catch { _ => return false }
        if decoded != p {
          return false
        }
      }
      reader.remaining() == 0
    },
    count=200,
  )
}

///|
/// Property: tokenizer positions are always contiguous from 0.
test "property: token positions contiguous" {
  @quickcheck.check(
    (text : String) => {
      let tokens = @moonseek.tokenize(text)
      let mut expected = 0
      for t in tokens {
        if t.position != expected {
          return false
        }
        expected += 1
      }
      true
    },
    count=200,
  )
}

///|
/// Property: deleting then searching never returns the deleted id.
test "property: delete excludes from results" {
  @quickcheck.check(
    (words : Array[String]) => {
      guard words.length() > 0 else { return true }
      let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
      let mut i = 0
      for w in words {
        idx.add({ id: "d\{i}", fields: [("body", w)], })
        i += 1
      }
      let _ = idx.delete("d0")
      let hits = idx.search("*", limit=0) catch { _ => return false }
      for h in hits {
        if h.id == "d0" {
          return false
        }
      }
      hits.length() == words.length() - 1
    },
    count=100,
  )
}
