///|
test "varint roundtrip" {
  let values = [0, 1, 127, 128, 255, 256, 16383, 16384, 1000000, 2147483647]
  let buf : Array[Byte] = []
  for v in values {
    @moonseek.write_varint(buf, v)
  }
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  for v in values {
    assert_eq(reader.read_varint(), v)
  }
  assert_eq(reader.remaining(), 0)
}

///|
test "string roundtrip with unicode" {
  let strings = [
    "", "hello", "全文搜索引擎", "emoji 🚀 test", "line\nbreak",
  ]
  let buf : Array[Byte] = []
  for s in strings {
    @moonseek.write_string(buf, s)
  }
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  for s in strings {
    assert_eq(reader.read_string(), s)
  }
  assert_eq(reader.remaining(), 0)
}

///|
test "double roundtrip" {
  let values = [0.0, 1.0, -1.5, 3.141592653589793, 1.0e-300, 1.0e300]
  let buf : Array[Byte] = []
  for v in values {
    @moonseek.write_double(buf, v)
  }
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  for v in values {
    assert_eq(reader.read_double(), v)
  }
}

///|
test "crc32 known vectors" {
  // Standard CRC-32/ISO-HDLC check values.
  assert_eq(@moonseek.crc32(b""), 0U)
  assert_eq(@moonseek.crc32(b"123456789"), 0xCBF43926U)
  assert_eq(
    @moonseek.crc32(b"The quick brown fox jumps over the lazy dog"),
    0x414FA339U,
  )
}

///|
test "u32 little endian roundtrip" {
  let buf : Array[Byte] = []
  @moonseek.write_u32_le(buf, 0xDEADBEEFU)
  assert_eq(buf.length(), 4)
  assert_eq(buf[0], 0xEF)
  assert_eq(buf[3], 0xDE)
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  assert_eq(reader.read_u32_le(), 0xDEADBEEFU)
}

///|
test "truncated input raises" {
  let reader = @moonseek.Reader::new(b"\x80")
  let result = reader.read_varint() catch {
    e => {
      assert_true(e is @moonseek.CodecError::UnexpectedEof)
      return ()
    }
  }
  let _ = result
  fail("should have raised")
}
