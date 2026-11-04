///|
/// Tests targeting error paths and edge cases for coverage.
test "codec: varint overflow raises" {
  // 10 continuation bytes -> shift exceeds 63
  let bytes : Array[Byte] = [
    0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
  ]
  let data = Bytes::from_array(bytes[:])
  let reader = @moonseek.Reader::new(data)
  let result = reader.read_varint() catch {
    e => {
      assert_true(e is @moonseek.CodecError::VarintOverflow)
      return ()
    }
  }
  let _ = result
  fail("should overflow")
}

///|
test "codec: invalid utf8 raises" {
  let buf : Array[Byte] = []
  @moonseek.write_varint(buf, 2)
  buf.push(0xFF)
  buf.push(0xFE)
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  let result = reader.read_string() catch {
    e => {
      assert_true(e is @moonseek.CodecError::InvalidUtf8)
      return ()
    }
  }
  let _ = result
  fail("should reject invalid utf8")
}

///|
test "codec: string length beyond buffer raises" {
  let buf : Array[Byte] = []
  @moonseek.write_varint(buf, 100) // claims 100 bytes but none follow
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  let result = reader.read_string() catch {
    e => {
      assert_true(e is @moonseek.CodecError::UnexpectedEof)
      return ()
    }
  }
  let _ = result
  fail("should detect truncation")
}

///|
test "snapshot: bad version raises" {
  // Build a valid MSK3 frame but with version 99 in payload
  let payload : Array[Byte] = []
  @moonseek.write_varint(payload, 99)
  let image : Array[Byte] = [0x4D, 0x53, 0x4B, 0x33] // MSK3
  for b in payload {
    image.push(b)
  }
  @moonseek.write_u32_le(image, @moonseek.crc32(Bytes::from_array(payload[:])))
  let result = @moonseek.Index::from_bytes(Bytes::from_array(image[:])) catch {
    e => {
      assert_true(e is @moonseek.CodecError::BadVersion(99))
      return ()
    }
  }
  let _ = result
  fail("should reject bad version")
}

///|
test "snapshot: trailing garbage raises" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  let image = idx.to_bytes()
  // Insert extra bytes before the CRC by rebuilding: take payload, append junk, re-crc
  let payload_view = image.clamped_view(start=4, end=image.length() - 4)
  let extended : Array[Byte] = []
  for b in payload_view.iter() {
    extended.push(b)
  }
  extended.push(0x42)
  let frame : Array[Byte] = [0x4D, 0x53, 0x4B, 0x33]
  for b in extended {
    frame.push(b)
  }
  @moonseek.write_u32_le(frame, @moonseek.crc32(Bytes::from_array(extended[:])))
  let result = @moonseek.Index::from_bytes(Bytes::from_array(frame[:])) catch {
    e => {
      assert_true(e is @moonseek.CodecError::UnexpectedEof)
      return ()
    }
  }
  let _ = result
  fail("should reject trailing bytes")
}

///|
test "index: empty index search and stats" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  assert_eq(idx.doc_count(), 0)
  assert_eq(idx.term_count(), 0)
  assert_eq((try! idx.search("*")).length(), 0)
  assert_eq((try! idx.search("anything")).length(), 0)
  assert_eq(idx.postings_of("body", "x").length(), 0)
  assert_eq(idx.postings_of("nonexistent", "x").length(), 0)
  assert_eq(idx.terms_of("nonexistent").length(), 0)
}

///|
test "query: empty phrase raises" {
  let result = @moonseek.parse_query("\"\"") catch {
    e => {
      assert_true(e is @moonseek.QueryError::EmptyQuery)
      return ()
    }
  }
  let _ = result
  fail("empty phrase should raise")
}

///|
test "query: stop-word-only term raises" {
  let result = @moonseek.parse_query("the") catch {
    e => {
      assert_true(e is @moonseek.QueryError::EmptyQuery)
      return ()
    }
  }
  let _ = result
  fail("stop word should raise")
}

///|
test "query: trailing tokens raise" {
  let result = @moonseek.parse_query("moonbit )") catch {
    e => {
      assert_true(e is @moonseek.QueryError::UnexpectedToken(_))
      return ()
    }
  }
  let _ = result
  fail("trailing paren should raise")
}

///|
test "query: prefix with no matches" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello world")], })
  assert_eq((try! idx.search("zzz*")).length(), 0)
}

///|
test "query: phrase with missing term" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello world")], })
  assert_eq((try! idx.search("\"hello absent\"")).length(), 0)
}

///|
test "query: NOT removes all" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello")], })
  assert_eq((try! idx.search("hello NOT hello")).length(), 0)
}

///|
test "tokenizer: cjk unigram mode" {
  let analyzer : @moonseek.Analyzer = {
    lowercase: true,
    remove_stop_words: true,
    cjk_bigram: false,
  }
  let tokens = analyzer.analyze("全文搜索")
  assert_eq(tokens.length(), 4)
  assert_eq(tokens[0].term, "全")
  assert_eq(tokens[3].term, "索")
}
