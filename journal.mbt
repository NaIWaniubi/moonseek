///|
/// Server journal, byte layer. Pure MoonBit — portable to every backend.
///
/// The engine's own WAL (`wal.mbt`) records `Document`s, which is all an
/// embedded user needs. The HTTP service accepts more than that: facets,
/// numeric columns and vectors arrive in the same request, so replaying only
/// the text would silently drop them and a restart would change search results.
/// This journal therefore records the *whole* accepted write.
///
/// Format: magic "MSJ1", then zero or more framed entries:
///   type byte (1 = Put, 2 = Remove) | payload | crc32(type+payload) u32le
/// Put payload: id | field count | (name, text)... | facet count |
///   (name, value count, value...) | num count | (name, double) |
///   vector count | (name, dim, double...)
/// Remove payload: id.
///
/// Crash semantics match the engine WAL: replay stops at the first torn or
/// checksum-failing frame, so a crash can only lose the incomplete tail, and a
/// bad magic is an error rather than a silent truncation.

///|
const JOURNAL_MAGIC : Bytes = b"MSJ1"

///|
const JOURNAL_TYPE_PUT : Int32 = 1

///|
const JOURNAL_TYPE_REMOVE : Int32 = 2

///|
/// One accepted write, in full.
pub(all) struct JournalDoc {
  id : String
  fields : Array[(String, String)]
  facets : Array[(String, Array[String])]
  nums : Array[(String, Double)]
  vectors : Array[(String, Array[Double])]
} derive(Eq, Debug)

///|
pub extend JournalDoc with Eq::{equal, not_equal}

///|
pub extend JournalDoc with @debug.Debug::{to_repr}

///|
/// One durable server mutation.
pub(all) enum JournalEntry {
  Put(JournalDoc)
  Remove(String)
} derive(Eq, Debug)

///|
pub extend JournalEntry with Eq::{equal, not_equal}

///|
pub extend JournalEntry with @debug.Debug::{to_repr}

///|
/// Encode one entry as a framed record (type byte + payload + crc32). The
/// caller supplies the buffer so a batch append can encode several entries into
/// one write.
pub fn journal_append_entry(buf : Array[Byte], entry : JournalEntry) -> Unit {
  let frame : Array[Byte] = []
  match entry {
    Put(doc) => {
      frame.push(JOURNAL_TYPE_PUT.to_byte())
      write_string(frame, doc.id)
      write_varint(frame, doc.fields.length())
      for (name, text) in doc.fields {
        write_string(frame, name)
        write_string(frame, text)
      }
      write_varint(frame, doc.facets.length())
      for (name, values) in doc.facets {
        write_string(frame, name)
        write_varint(frame, values.length())
        for v in values {
          write_string(frame, v)
        }
      }
      write_varint(frame, doc.nums.length())
      for (name, n) in doc.nums {
        write_string(frame, name)
        write_double(frame, n)
      }
      write_varint(frame, doc.vectors.length())
      for (name, vector) in doc.vectors {
        write_string(frame, name)
        write_varint(frame, vector.length())
        for x in vector {
          write_double(frame, x)
        }
      }
    }
    Remove(id) => {
      frame.push(JOURNAL_TYPE_REMOVE.to_byte())
      write_string(frame, id)
    }
  }
  for b in frame {
    buf.push(b)
  }
  write_u32_le(buf, crc32(Bytes::from_array(frame[:])))
}

///|
/// One entry as a self-contained journal fragment: the magic header followed by
/// the framed record.
///
/// Concatenating fragments yields a valid journal image — `journal_decode`
/// skips a repeated header — which is what lets several independently arriving
/// writes share a single `write` and a single fsync instead of each paying for
/// its own. The fragment is complete on its own, so a batch torn by a crash
/// still replays its whole prefix.
pub fn journal_frame(entry : JournalEntry) -> Bytes {
  let buf : Array[Byte] = []
  for b in JOURNAL_MAGIC.iter() {
    buf.push(b)
  }
  journal_append_entry(buf, entry)
  Bytes::from_array(buf[:])
}

///|
/// Encode entries as a complete journal image (header + frames).
pub fn journal_encode(entries : Array[JournalEntry]) -> Bytes {
  let buf : Array[Byte] = []
  if entries.is_empty() {
    return Bytes::from_array(buf[:])
  }
  for b in JOURNAL_MAGIC.iter() {
    buf.push(b)
  }
  for entry in entries {
    journal_append_entry(buf, entry)
  }
  Bytes::from_array(buf[:])
}

///|
/// Decode a journal image, replaying every complete entry. Stops silently at a
/// torn or corrupt tail; raises only if the leading header is not a journal.
pub fn journal_decode(data : Bytes) -> Array[JournalEntry] raise CodecError {
  let entries : Array[JournalEntry] = []
  if data.length() < JOURNAL_MAGIC.length() {
    if is_journal_prefix(data) {
      return []
    }
    raise CodecError::BadMagic
  }
  let magic = match data.get_view(end=JOURNAL_MAGIC.length()) {
    Some(m) => m
    None => raise CodecError::UnexpectedEof
  }
  if magic != JOURNAL_MAGIC {
    raise CodecError::BadMagic
  }
  let reader = Reader::new(data)
  reader.pos = JOURNAL_MAGIC.length()
  while reader.remaining() > 0 {
    if journal_starts_with_magic_at(data, reader.pos) {
      reader.pos += JOURNAL_MAGIC.length()
      continue
    }
    if journal_is_prefix_at(data, reader.pos) {
      break
    }
    let frame_start = reader.pos
    let entry = match journal_read_entry(reader) {
      Some(e) => e
      None => break
    }
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
fn journal_starts_with_magic_at(data : Bytes, pos : Int32) -> Bool {
  match data.get_view(start=pos, end=pos + JOURNAL_MAGIC.length()) {
    Some(v) => v == JOURNAL_MAGIC
    None => false
  }
}

///|
fn journal_is_prefix_at(data : Bytes, pos : Int32) -> Bool {
  let rest = data.length() - pos
  if rest <= 0 || rest >= JOURNAL_MAGIC.length() {
    return false
  }
  for i in 0..<rest {
    match (data.get(pos + i), JOURNAL_MAGIC.get(i)) {
      (Some(a), Some(b)) if a == b => ()
      _ => return false
    }
  }
  true
}

///|
fn is_journal_prefix(data : Bytes) -> Bool {
  for i in 0..<data.length() {
    match (data.get(i), JOURNAL_MAGIC.get(i)) {
      (Some(a), Some(b)) if a == b => ()
      _ => return false
    }
  }
  true
}

///|
fn journal_read_entry(reader : Reader) -> JournalEntry? {
  let type_byte = reader.read_byte() catch { _ => return None }
  match type_byte.to_int() {
    JOURNAL_TYPE_PUT => {
      let id = reader.read_string() catch { _ => return None }
      let field_count = reader.read_varint() catch { _ => return None }
      let fields : Array[(String, String)] = []
      for _ in 0..<field_count {
        let name = reader.read_string() catch { _ => return None }
        let text = reader.read_string() catch { _ => return None }
        fields.push((name, text))
      }
      let facet_count = reader.read_varint() catch { _ => return None }
      let facets : Array[(String, Array[String])] = []
      for _ in 0..<facet_count {
        let name = reader.read_string() catch { _ => return None }
        let value_count = reader.read_varint() catch { _ => return None }
        let values : Array[String] = []
        for _ in 0..<value_count {
          values.push(reader.read_string() catch { _ => return None })
        }
        facets.push((name, values))
      }
      let num_count = reader.read_varint() catch { _ => return None }
      let nums : Array[(String, Double)] = []
      for _ in 0..<num_count {
        let name = reader.read_string() catch { _ => return None }
        let n = reader.read_double() catch { _ => return None }
        nums.push((name, n))
      }
      let vec_count = reader.read_varint() catch { _ => return None }
      let vectors : Array[(String, Array[Double])] = []
      for _ in 0..<vec_count {
        let name = reader.read_string() catch { _ => return None }
        let dim = reader.read_varint() catch { _ => return None }
        let vector : Array[Double] = []
        for _ in 0..<dim {
          vector.push(reader.read_double() catch { _ => return None })
        }
        vectors.push((name, vector))
      }
      Some(Put({ id, fields, facets, nums, vectors, }))
    }
    JOURNAL_TYPE_REMOVE => {
      let id = reader.read_string() catch { _ => return None }
      Some(Remove(id))
    }
    _ => None
  }
}
