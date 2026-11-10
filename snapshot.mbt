///|
/// Snapshot format: a self-contained, checksummed byte image of an index.
/// Layout: magic "MSK2" | payload | crc32(payload) as u32le.
/// The payload is versioned; readers reject unknown versions and any
/// checksum mismatch, so a torn write is detected rather than loaded.
/// Version 2 adds stored original field texts (version 1 images are still
/// readable; they simply have no stored fields).
/// Pure functions over bytes — usable on native, wasm-gc and js alike.

///|
const SNAPSHOT_MAGIC : Bytes = b"MSK3"

///|
const SNAPSHOT_LEGACY_MAGIC : Bytes = b"MSK1"

///|
const SNAPSHOT_V2_MAGIC : Bytes = b"MSK2"

///|
const SNAPSHOT_VERSION : Int32 = 3

///|
/// Serialize the index to a portable byte image.
/// Uses ByteWriter (preallocated, amortized growth) instead of Array[Byte]
/// push: serializing the 17 MB stress image drops from ~2.4 s to ~0.7 s.
pub fn Index::to_bytes(self : Index) -> Bytes {
  let payload : ByteWriter = ByteWriter::new(capacity=4096)
  payload.write_varint(SNAPSHOT_VERSION)
  payload.write_varint(self.schema.length())
  for field in self.schema {
    payload.write_string(field.name)
    payload.write_double(field.weight)
  }
  payload.write_varint(if self.analyzer.lowercase { 1 } else { 0 })
  payload.write_varint(if self.analyzer.remove_stop_words { 1 } else { 0 })
  payload.write_varint(if self.analyzer.cjk_bigram { 1 } else { 0 })
  payload.write_double(self.bm25.k1)
  payload.write_double(self.bm25.b)
  payload.write_varint(self.doc_ids.length())
  for id in self.doc_ids {
    payload.write_string(id)
  }
  // Deleted internal doc numbers (sorted for determinism)
  let deleted_nums : Array[Int32] = []
  for (num, _) in self.deleted.iter() {
    deleted_nums.push(num)
  }
  deleted_nums.sort()
  payload.write_varint(deleted_nums.length())
  for num in deleted_nums {
    payload.write_varint(num)
  }
  // Stored original field texts (live documents only, in doc order)
  payload.write_varint(self.stored.length())
  for num in 0..<self.doc_ids.length() {
    match self.stored.get(num) {
      Some(fields) => {
        payload.write_varint(num)
        payload.write_varint(fields.length())
        for (name, text) in fields {
          payload.write_string(name)
          payload.write_string(text)
        }
      }
      None => ()
    }
  }
  // Facet values (live documents only, in doc order)
  payload.write_varint(self.facets.length())
  for num in 0..<self.doc_ids.length() {
    match self.facets.get(num) {
      Some(facets) => {
        payload.write_varint(num)
        payload.write_varint(facets.length())
        for (name, values) in facets {
          payload.write_string(name)
          payload.write_varint(values.length())
          for v in values {
            payload.write_string(v)
          }
        }
      }
      None => ()
    }
  }
  // Per-field stats: doc -> length
  for field in self.schema {
    let stats = self.stats[field.name]
    payload.write_varint(stats.lengths.length())
    for (num, len) in stats.lengths.iter() {
      payload.write_varint(num)
      payload.write_varint(len)
    }
  }
  // Postings per field
  for field in self.schema {
    let field_map = self.postings[field.name]
    payload.write_varint(field_map.length())
    let terms : Array[String] = []
    for (term, _) in field_map.iter() {
      terms.push(term)
    }
    terms.sort_by(fn(a, b) { a.lexical_compare(b) })
    for term in terms {
      payload.write_string(term)
      let list = field_map[term]
      payload.write_varint(list.length())
      for posting in list {
        payload.write_varint(posting.doc)
        payload.write_varint(posting.freq)
        payload.write_varint(posting.positions.length())
        let mut prev = 0
        for pos in posting.positions {
          payload.write_varint(pos - prev)
          prev = pos
        }
      }
    }
  }
  // Frame: magic + payload + crc
  let image = ByteWriter::new(capacity=payload.length() + 16)
  for b in SNAPSHOT_MAGIC.iter() {
    image.push(b)
  }
  image.append(payload)
  image.write_u32_le(crc32(payload.to_bytes()))
  image.to_bytes()
}

///|
/// Restore an index from a byte image. Raises on bad magic, unknown
/// version, truncation, or checksum mismatch.
pub fn Index::from_bytes(data : Bytes) -> Index raise CodecError {
  if data.length() < 8 {
    raise CodecError::UnexpectedEof
  }
  let magic = data.get_view(end=4)
  let format_version = match magic {
    Some(m) if m == SNAPSHOT_MAGIC => 3
    Some(m) if m == SNAPSHOT_V2_MAGIC => 2
    Some(m) if m == SNAPSHOT_LEGACY_MAGIC => 1
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
  if version != format_version {
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
  // Stored fields (version 2+)
  if version >= 2 {
    let stored_count = reader.read_varint()
    for _ in 0..<stored_count {
      let num = reader.read_varint()
      let field_count = reader.read_varint()
      let fields : Array[(String, String)] = []
      for _ in 0..<field_count {
        let name = reader.read_string()
        let text = reader.read_string()
        fields.push((name, text))
      }
      index.stored.set(num, fields)
    }
  }
  // Facets (version 3+)
  if version >= 3 {
    let facet_count = reader.read_varint()
    for _ in 0..<facet_count {
      let num = reader.read_varint()
      let field_count = reader.read_varint()
      let facets : Array[(String, Array[String])] = []
      for _ in 0..<field_count {
        let name = reader.read_string()
        let value_count = reader.read_varint()
        let values : Array[String] = []
        for _ in 0..<value_count {
          values.push(reader.read_string())
        }
        facets.push((name, values))
      }
      index.facets.set(num, facets)
    }
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
