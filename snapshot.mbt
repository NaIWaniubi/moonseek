///|
/// Snapshot format: a self-contained, checksummed byte image of an index.
/// Layout: magic "MSK1" | payload | crc32(payload) as u32le.
/// The payload is versioned; readers reject unknown versions and any
/// checksum mismatch, so a torn write is detected rather than loaded.
/// Pure functions over bytes — usable on native, wasm-gc and js alike.

///|
const SNAPSHOT_MAGIC : Bytes = b"MSK1"

///|
const SNAPSHOT_VERSION : Int32 = 1

///|
/// Serialize the index to a portable byte image.
pub fn Index::to_bytes(self : Index) -> Bytes {
  let payload : Array[Byte] = []
  write_varint(payload, SNAPSHOT_VERSION)
  // Schema
  write_varint(payload, self.schema.length())
  for field in self.schema {
    write_string(payload, field.name)
    write_double(payload, field.weight)
  }
  // Analyzer + BM25 config
  write_varint(payload, if self.analyzer.lowercase { 1 } else { 0 })
  write_varint(payload, if self.analyzer.remove_stop_words { 1 } else { 0 })
  write_varint(payload, if self.analyzer.cjk_bigram { 1 } else { 0 })
  write_double(payload, self.bm25.k1)
  write_double(payload, self.bm25.b)
  // Documents (external ids; internal numbers are reassigned in order)
  write_varint(payload, self.doc_ids.length())
  for id in self.doc_ids {
    write_string(payload, id)
  }
  // Deleted internal doc numbers
  write_varint(payload, self.deleted.length())
  for (num, _) in self.deleted.iter() {
    write_varint(payload, num)
  }
  // Per-field stats: doc -> length
  for field in self.schema {
    let stats = self.stats[field.name]
    write_varint(payload, stats.lengths.length())
    for (num, len) in stats.lengths.iter() {
      write_varint(payload, num)
      write_varint(payload, len)
    }
  }
  // Postings per field
  for field in self.schema {
    let field_map = self.postings[field.name]
    write_varint(payload, field_map.length())
    // Sort terms for deterministic output.
    let terms : Array[String] = []
    for (term, _) in field_map.iter() {
      terms.push(term)
    }
    terms.sort()
    for term in terms {
      write_string(payload, term)
      let list = field_map[term]
      write_varint(payload, list.length())
      for posting in list {
        write_varint(payload, posting.doc)
        write_varint(payload, posting.freq)
        write_varint(payload, posting.positions.length())
        // Delta-encode positions for compactness.
        let mut prev = 0
        for pos in posting.positions {
          write_varint(payload, pos - prev)
          prev = pos
        }
      }
    }
  }
  // Frame: magic + payload + crc
  let image : Array[Byte] = []
  for b in SNAPSHOT_MAGIC.iter() {
    image.push(b)
  }
  for b in payload {
    image.push(b)
  }
  let payload_bytes = Bytes::from_array(payload[:])
  write_u32_le(image, crc32(payload_bytes))
  Bytes::from_array(image[:])
}

///|
/// Restore an index from a byte image. Raises on bad magic, unknown
/// version, truncation, or checksum mismatch.
pub fn Index::from_bytes(data : Bytes) -> Index raise CodecError {
  if data.length() < 8 {
    raise CodecError::UnexpectedEof
  }
  let magic = data.get_view(end=4)
  match magic {
    Some(m) if m == SNAPSHOT_MAGIC => ()
    _ => raise CodecError::BadMagic
  }
  let payload_len = data.length() - 8
  let payload = match data.get_view(start=4, end=4 + payload_len) {
    Some(p) => p
    None => raise CodecError::UnexpectedEof
  }
  let crc_reader = Reader::new(data)
  crc_reader.pos = 4 + payload_len
  let expected = crc_reader.read_u32_le()
  let actual = crc32(payload.to_owned())
  if expected != actual {
    raise CodecError::CrcMismatch(expected, actual)
  }
  let reader = Reader::new(payload.to_owned())
  let version = reader.read_varint()
  if version != SNAPSHOT_VERSION {
    raise CodecError::BadVersion(version)
  }
  // Schema
  let schema_len = reader.read_varint()
  let schema : Array[FieldSchema] = []
  for _ in 0..<schema_len {
    let name = reader.read_string()
    let weight = reader.read_double()
    schema.push({ name, weight, })
  }
  let lowercase = reader.read_varint() != 0
  let remove_stop_words = reader.read_varint() != 0
  let cjk_bigram = reader.read_varint() != 0
  let k1 = reader.read_double()
  let b = reader.read_double()
  let index = Index::new(
    schema,
    analyzer={ lowercase, remove_stop_words, cjk_bigram, },
    bm25={ k1, b, },
  )
  // Documents
  let doc_count = reader.read_varint()
  for _ in 0..<doc_count {
    let id = reader.read_string()
    let num = index.doc_ids.length()
    index.doc_ids.push(id)
    index.doc_nums.set(id, num)
  }
  // Deleted
  let deleted_count = reader.read_varint()
  for _ in 0..<deleted_count {
    index.deleted.set(reader.read_varint(), ())
  }
  // Stats
  for field in schema {
    let stats = index.stats[field.name]
    let entries = reader.read_varint()
    for _ in 0..<entries {
      let num = reader.read_varint()
      let len = reader.read_varint()
      stats.lengths.set(num, len)
      stats.total_length += len
    }
  }
  // Postings
  for field in schema {
    let field_map = index.postings[field.name]
    let term_count = reader.read_varint()
    for _ in 0..<term_count {
      let term = reader.read_string()
      let list_len = reader.read_varint()
      let list : Array[Posting] = []
      for _ in 0..<list_len {
        let doc = reader.read_varint()
        let freq = reader.read_varint()
        let pos_count = reader.read_varint()
        let positions : Array[Int32] = []
        let mut prev = 0
        for _ in 0..<pos_count {
          let delta = reader.read_varint()
          let pos = prev + delta
          positions.push(pos)
          prev = pos
        }
        list.push({ doc, freq, positions, })
      }
      field_map.set(term, list)
    }
  }
  if reader.remaining() != 0 {
    raise CodecError::UnexpectedEof
  }
  index
}
