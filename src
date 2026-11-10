///|
/// Binary codec primitives: varint integers, length-prefixed UTF-8 strings,
/// doubles, and CRC-32 (IEEE 802.3, same polynomial as zlib).
/// Little-endian fixed-width where noted. All pure MoonBit, portable to
/// every backend including wasm-gc and js.

///|
/// Append an unsigned varint (LEB128) to the buffer.
/// Every byte except the last has the continuation bit (0x80) set.
pub fn write_varint(buf : Array[Byte], value : Int32) -> Unit {
  let mut v = value
  while v >= 0x80 {
    buf.push(((v & 0x7F) | 0x80).to_byte())
    v = v >> 7
  }
  buf.push(v.to_byte())
}

///|
/// Cursor over a byte slice for decoding.
pub struct Reader {
  data : Bytes
  mut pos : Int32
}

///|
pub fn Reader::new(data : Bytes) -> Reader {
  { data, pos: 0, }
}

///|
pub fn Reader::remaining(self : Reader) -> Int32 {
  self.data.length() - self.pos
}

///|
/// Decoding errors (truncated or malformed data).
pub(all) suberror CodecError {
  UnexpectedEof
  VarintOverflow
  InvalidUtf8
  BadMagic
  BadVersion(Int32)
  CrcMismatch(UInt32, UInt32)
} derive(Eq, Debug)

///|
pub extend CodecError with Eq::{equal, not_equal}

///|
pub extend CodecError with @debug.Debug::{to_repr}

///|
pub fn Reader::read_byte(self : Reader) -> Byte raise CodecError {
  match self.data.get(self.pos) {
    Some(b) => {
      self.pos += 1
      b
    }
    None => raise CodecError::UnexpectedEof
  }
}

///|
pub fn Reader::read_varint(self : Reader) -> Int32 raise CodecError {
  let mut result = 0
  let mut shift = 0
  while true {
    let b = self.read_byte().to_int()
    result = result | ((b & 0x7F) << shift)
    if b < 0x80 {
      break result
    }
    shift += 7
    if shift >= 63 {
      raise CodecError::VarintOverflow
    }
  } nobreak {
    result
  }
}

///|
pub fn write_string(buf : Array[Byte], s : String) -> Unit {
  let bytes = @utf8.encode(s)
  write_varint(buf, bytes.length())
  for b in bytes.iter() {
    buf.push(b)
  }
}

///|
pub fn Reader::read_string(self : Reader) -> String raise CodecError {
  let len = self.read_varint()
  if len > self.remaining() {
    raise CodecError::UnexpectedEof
  }
  let view = match self.data.get_view(start=self.pos, end=self.pos + len) {
    Some(v) => v
    None => raise CodecError::UnexpectedEof
  }
  self.pos += len
  // Validate UTF-8 with the strict decoder.
  let s = @utf8.decode(view) catch { _ => raise CodecError::InvalidUtf8 }
  s
}

///|
pub fn write_double(buf : Array[Byte], value : Double) -> Unit {
  let bits = value.reinterpret_as_uint64()
  for i in 0..<8 {
    buf.push(((bits >> (i * 8)) & 0xFFUL).to_int().to_byte())
  }
}

///|
pub fn Reader::read_double(self : Reader) -> Double raise CodecError {
  let mut bits : UInt64 = 0UL
  for i in 0..<8 {
    let b = self.read_byte().to_uint64()
    bits = bits | (b << (i * 8))
  }
  bits.reinterpret_as_double()
}

///|
let crc32_table : FixedArray[UInt32] = {
  let table = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut c = i.reinterpret_as_uint()
    for _ in 0..<8 {
      c = if (c & 1U) == 1U { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
    table[i] = c
  }
  table
}

///|
/// CRC-32 (IEEE) of a byte slice.
pub fn crc32(data : Bytes) -> UInt32 {
  let mut crc = 0xFFFFFFFFU
  for b in data.iter() {
    let idx = ((crc ^ b.to_int().reinterpret_as_uint()) & 0xFFU).reinterpret_as_int()
    crc = crc32_table[idx] ^ (crc >> 8)
  }
  crc ^ 0xFFFFFFFFU
}

///|
/// Append a little-endian uint32 (used for the trailing checksum).
pub fn write_u32_le(buf : Array[Byte], value : UInt32) -> Unit {
  for i in 0..<4 {
    buf.push(((value >> (i * 8)) & 0xFFU).to_byte())
  }
}

///|
pub fn Reader::read_u32_le(self : Reader) -> UInt32 raise CodecError {
  let mut result = 0U
  for i in 0..<4 {
    let b = self.read_byte().to_int().reinterpret_as_uint()
    result = result | (b << (i * 8))
  }
  result
}
