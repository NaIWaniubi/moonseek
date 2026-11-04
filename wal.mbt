///|
/// Write-ahead log, byte layer. Pure MoonBit — portable to every backend.
///
/// Format: magic "MWL1" followed by zero or more framed entries:
///   type byte (1 = Add, 2 = Delete) | payload | crc32(type+payload) u32le
/// Add payload: id string | field count | (name, text) string pairs.
/// Delete payload: id string.
///
/// Crash-recovery semantics: `wal_decode` replays entries in order and
/// stops at the first torn or checksum-failing tail, returning everything
/// before it. A partial write can only ever affect the tail (entries are
/// appended sequentially), so prefix recovery is exactly "replay all
/// complete entries". A malformed *header* (bad magic / unknown version)
/// is an error, not a truncation — the file is not a WAL at all.

///|
const WAL_MAGIC : Bytes = b"MWL1"

///|
const WAL_TYPE_ADD : Int32 = 1

///|
const WAL_TYPE_DELETE : Int32 = 2

///|
/// One durable mutation.
pub(all) enum WalEntry {
  Add(Document)
  Delete(String)
} derive(Eq, Debug)

///|
pub extend WalEntry with Eq::{equal, not_equal}

///|
pub extend WalEntry with @debug.Debug::{to_repr}

///|
/// Encode entries into a WAL image. A non-empty log starts with the
/// "MWL1" header; an empty log is empty bytes (so appending the first
/// entry to a fresh file also writes the header exactly once).
pub fn wal_encode(entries : Array[WalEntry]) -> Bytes {
  let buf : Array[Byte] = []
  if entries.is_empty() {
    return Bytes::from_array(buf[:])
  }
  for b in WAL_MAGIC.iter() {
    buf.push(b)
  }
  for entry in entries {
    wal_encode_entry(buf, entry)
  }
  Bytes::from_array(buf[:])
}

///|
/// Append one framed entry (type byte + payload + crc32) to the buffer.
fn wal_encode_entry(buf : Array[Byte], entry : WalEntry) -> Unit {
  let frame : Array[Byte] = []
  match entry {
    Add(doc) => {
      frame.push(WAL_TYPE_ADD.to_byte())
      write_string(frame, doc.id)
      write_varint(frame, doc.fields.length())
      for (name, text) in doc.fields {
        write_string(frame, name)
        write_string(frame, text)
      }
    }
    Delete(id) => {
      frame.push(WAL_TYPE_DELETE.to_byte())
      write_string(frame, id)
    }
  }
  for b in frame {
    buf.push(b)
  }
  write_u32_le(buf, crc32(Bytes::from_array(frame[:])))
}

///|
/// Decode a WAL image, replaying every complete entry. The "MWL1"
/// header may appear at the start and again after any entry (each
/// append batch to a fresh file carries one); a torn header *tail* is
/// ignored. Stops silently at a torn or corrupt entry tail (crash
/// recovery); raises only if the leading header is not a WAL, a
/// mid-stream header is corrupt, or an entry type is unknown.
pub fn wal_decode(data : Bytes) -> Array[WalEntry] raise CodecError {
  if data.length() < WAL_MAGIC.length() {
    // A shorter-than-magic prefix is a torn header write: nothing to replay.
    if is_wal_prefix(data) {
      return []
    }
    raise CodecError::BadMagic
  }
  let magic = match data.get_view(end=WAL_MAGIC.length()) {
    Some(m) => m
    None => raise CodecError::UnexpectedEof
  }
  if magic != WAL_MAGIC {
    raise CodecError::BadMagic
  }
  let reader = Reader::new(data)
  reader.pos = WAL_MAGIC.length()
  let entries : Array[WalEntry] = []
  while reader.remaining() > 0 {
    // A repeated header starts a new append batch. A complete one is
    // skipped; a torn one at the tail ends replay.
    if starts_with_magic_at(data, reader.pos) {
      reader.pos += WAL_MAGIC.length()
      continue
    }
    if is_wal_prefix_at(data, reader.pos) {
      break
    }
    let frame_start = reader.pos
    let entry = match wal_read_entry(reader) {
      Some(e) => e
      None => break
    }
    // CRC covers type byte + payload; a mismatch means a torn tail.
    let frame = match data.get_view(start=frame_start, end=reader.pos) {
      Some(v) => v.to_owned()
      None => break
    }
    let expected = reader.read_u32_le() catch { _ => break }
    if crc32(frame) != expected {
      break
    }
    entries.push(entry)
  }
  entries
}

///|
/// True if the bytes at `pos` start with the full WAL magic.
fn starts_with_magic_at(data : Bytes, pos : Int32) -> Bool {
  match data.get_view(start=pos, end=pos + WAL_MAGIC.length()) {
    Some(v) => v == WAL_MAGIC
    None => false
  }
}

///|
/// True if `data[pos:]` is a non-empty proper prefix of the WAL magic —
/// i.e. a header write torn before completion.
fn is_wal_prefix_at(data : Bytes, pos : Int32) -> Bool {
  let rest = data.length() - pos
  if rest <= 0 || rest >= WAL_MAGIC.length() {
    return false
  }
  for i in 0..<rest {
    match (data.get(pos + i), WAL_MAGIC.get(i)) {
      (Some(a), Some(b)) if a == b => ()
      _ => return false
    }
  }
  true
}

///|
/// True if `data` is a (possibly empty) prefix of the WAL magic.
fn is_wal_prefix(data : Bytes) -> Bool {
  for i in 0..<data.length() {
    match (data.get(i), WAL_MAGIC.get(i)) {
      (Some(a), Some(b)) if a == b => ()
      _ => return false
    }
  }
  true
}

///|
/// Read one entry's type + payload. Returns None on a torn frame (the
/// caller then stops replay). Raises on an unknown type byte: that is
/// format corruption, not a torn write.
fn wal_read_entry(reader : Reader) -> WalEntry? raise CodecError {
  let type_byte = reader.read_byte() catch { _ => return None }
  match type_byte.to_int() {
    WAL_TYPE_ADD => {
      let id = reader.read_string() catch { _ => return None }
      let field_count = reader.read_varint() catch { _ => return None }
      let fields : Array[(String, String)] = []
      for _ in 0..<field_count {
        let name = reader.read_string() catch { _ => return None }
        let text = reader.read_string() catch { _ => return None }
        fields.push((name, text))
      }
      Some(Add({ id, fields, }))
    }
    WAL_TYPE_DELETE => {
      let id = reader.read_string() catch { _ => return None }
      Some(Delete(id))
    }
    _ => raise CodecError::BadVersion(type_byte.to_int())
  }
}
