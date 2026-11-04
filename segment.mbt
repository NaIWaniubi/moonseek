///|
/// Segmented index: a stack of immutable segments plus one active
/// in-memory segment. Each segment is a full `Index` (already
/// serializable via MSK2), so freezing is just moving a reference.
/// Pure MoonBit — usable on native, wasm-gc and js alike.
///
/// Ordering contract: `segments` is oldest-first, `active` is newest.
/// The same external id may appear in several segments (update = append
/// a new version); the newest segment holding a live version wins.

///|
const SEGMENT_MAGIC : Bytes = b"MSKS"

///|
const SEGMENT_VERSION : Int32 = 1

///|
/// A multi-segment full-text index.
pub struct SegmentedIndex {
  schema : Array[FieldSchema]
  analyzer : Analyzer
  bm25 : Bm25Params
  /// Immutable segments, oldest first.
  mut segments : Array[Index]
  /// The writable segment; never serialized as immutable until frozen.
  mut active : Index
  /// Live-doc threshold at which the active segment is frozen.
  segment_max_docs : Int32
}

///|
/// Create an empty segmented index. `segment_max_docs` is clamped to >= 1.
pub fn SegmentedIndex::new(
  schema : Array[FieldSchema],
  segment_max_docs~ : Int32 = 1000,
) -> SegmentedIndex {
  let analyzer = Analyzer::default()
  let bm25 = Bm25Params::default()
  {
    schema,
    analyzer,
    bm25,
    segments: [],
    active: Index::new(schema, analyzer~, bm25~),
    segment_max_docs: if segment_max_docs < 1 {
      1
    } else {
      segment_max_docs
    },
  }
}

///|
fn SegmentedIndex::new_active(self : SegmentedIndex) -> Index {
  Index::new(self.schema, analyzer=self.analyzer, bm25=self.bm25)
}

///|
/// Add or replace a document in the active segment. Freezes the active
/// segment once it reaches `segment_max_docs` live documents.
/// Re-adding an id tombstones its older versions in frozen segments so
/// that position-based readers (get_document) agree with search's
/// newest-wins resolution even before a merge compacts the stack.
pub fn SegmentedIndex::add(self : SegmentedIndex, doc : Document) -> Unit {
  for segment in self.segments {
    ignore(segment.delete(doc.id))
  }
  self.active.add(doc)
  if self.active.doc_count() >= self.segment_max_docs {
    self.flush()
  }
}

///|
/// Mark a document deleted in every segment (all versions of the id).
/// Returns true if the id existed, matching `Index::delete` semantics
/// (an already-deleted id still "exists" as a tombstone).
pub fn SegmentedIndex::delete(self : SegmentedIndex, id : String) -> Bool {
  let mut found = false
  for segment in self.segments {
    if segment.delete(id) {
      found = true
    }
  }
  if self.active.delete(id) {
    found = true
  }
  found
}

///|
/// Freeze the active segment into the immutable stack (no-op if empty).
pub fn SegmentedIndex::flush(self : SegmentedIndex) -> Unit {
  if self.active.doc_ids.length() == 0 {
    return
  }
  self.segments.push(self.active)
  self.active = self.new_active()
}

///|
/// Number of segments: frozen (immutable) ones plus the active segment
/// if it holds any documents. An empty active segment is not counted.
pub fn SegmentedIndex::segment_count(self : SegmentedIndex) -> Int32 {
  let extra = if self.active.doc_ids.length() > 0 { 1 } else { 0 }
  self.segments.length() + extra
}

///|
/// Number of distinct live documents (newest version per id wins).
pub fn SegmentedIndex::doc_count(self : SegmentedIndex) -> Int32 {
  self.live_docs().length()
}

///|
/// The newest live version of every document, oldest-first scan order.
/// A later segment overwrites an earlier one; deleted versions never win.
fn SegmentedIndex::live_docs(
  self : SegmentedIndex,
) -> @hashmap.HashMap[String, Document] {
  let latest : @hashmap.HashMap[String, Document] = @hashmap.HashMap([])
  for segment in self.segments {
    for num in 0..<segment.doc_ids.length() {
      if segment.deleted.contains(num) {
        continue
      }
      let id = segment.doc_ids[num]
      match segment.get_document(id) {
        Some(doc) => latest.set(id, doc)
        None => ()
      }
    }
  }
  for num in 0..<self.active.doc_ids.length() {
    if self.active.deleted.contains(num) {
      continue
    }
    let id = self.active.doc_ids[num]
    match self.active.get_document(id) {
      Some(doc) => latest.set(id, doc)
      None => ()
    }
  }
  latest
}

///|
/// Retrieve the newest live version of a document by external id.
pub fn SegmentedIndex::get_document(
  self : SegmentedIndex,
  id : String,
) -> Document? {
  match self.active.get_document(id) {
    Some(doc) => return Some(doc)
    None => ()
  }
  let mut i = self.segments.length() - 1
  while i >= 0 {
    match self.segments[i].get_document(id) {
      Some(doc) => return Some(doc)
      None => i -= 1
    }
  }
  None
}

///|
/// Retrieve one stored field's text from the newest live version.
pub fn SegmentedIndex::get_field(
  self : SegmentedIndex,
  id : String,
  field : String,
) -> String? {
  match self.get_document(id) {
    Some(doc) => {
      for (name, text) in doc.fields {
        if name == field {
          return Some(text)
        }
      }
      None
    }
    None => None
  }
}

///|
/// Search every segment and merge the hits.
///
/// Newest-wins resolution: each segment is queried normally, then every
/// hit is resolved against the newest live version of its id. A hit for
/// a deleted id is dropped; a hit for a stale version is re-scored by
/// evaluating the same parsed query against a one-document index built
/// from the newest version. This guarantees update semantics identical
/// to a single index: terms that only existed in the old version stop
/// matching, and scores always reflect the newest content.
///
/// Scoring across segments: each segment computes BM25 with its own
/// local IDF/avgdl, so raw scores are NOT directly comparable. We
/// normalize per segment by dividing each hit score by that segment's
/// maximum score for the query (max-score normalization to [0, 1]).
/// This is the standard federated-search approximation: it preserves
/// within-segment ranking exactly and makes cross-segment ordering
/// depend on relative, not absolute, relevance. Ties (including all
/// MatchAll hits, which score 1.0 everywhere) are broken by document
/// id, ascending, for determinism.
pub fn SegmentedIndex::search(
  self : SegmentedIndex,
  query : String,
  limit~ : Int32 = 10,
) -> Array[Hit] raise QueryError {
  let fields = self.schema.map(fn(f) { f.name })
  let parsed = parse_query(query, analyzer=self.analyzer, fields~)
  let latest = self.live_docs()
  let merged : @hashmap.HashMap[String, Double] = @hashmap.HashMap([])
  // Oldest first; newer segments overwrite older versions of the same id.
  for segment in self.segments {
    self.collect_hits(segment, parsed, latest, merged)
  }
  self.collect_hits(self.active, parsed, latest, merged)
  let hits : Array[Hit] = []
  for (id, score) in merged.iter() {
    hits.push({ id, score, })
  }
  hits.sort_by(fn(a, b) {
    let cmp = b.score.compare(a.score)
    if cmp == 0 {
      a.id.lexical_compare(b.id)
    } else {
      cmp
    }
  })
  if limit > 0 && hits.length() > limit {
    hits[:limit].to_owned()
  } else {
    hits
  }
}

///|
fn SegmentedIndex::collect_hits(
  self : SegmentedIndex,
  segment : Index,
  parsed : Query,
  latest : @hashmap.HashMap[String, Document],
  merged : @hashmap.HashMap[String, Double],
) -> Unit {
  let scored = segment.eval(parsed)
  if scored.is_empty() {
    return
  }
  let mut max_score = 0.0
  for (_, score) in scored.iter() {
    if score > max_score {
      max_score = score
    }
  }
  let scale = if max_score > 0.0 { max_score } else { 1.0 }
  for (num, score) in scored.iter() {
    let id = segment.doc_ids[num]
    match latest.get(id) {
      None => () // deleted: drop the hit entirely
      Some(doc) => {
        // If this segment holds the newest version, its score is final.
        // Otherwise re-score the newest version in isolation so stale
        // terms cannot leak through an old segment's postings.
        let final_score = if segment.get_document(id) == Some(doc) {
          score
        } else {
          let probe = Index::new(
            self.schema,
            analyzer=self.analyzer,
            bm25=self.bm25,
          )
          probe.add(doc)
          match probe.eval(parsed).get(0) {
            Some(s) => s
            None => continue
          }
        }
        merged.set(id, final_score / scale)
      }
    }
  }
}

///|
/// Tiered merge policy. Segments are bucketed by size class
/// (floor(log2(live docs))). While the total segment count exceeds
/// `max_segments`, the most populated tier is collapsed into a single
/// rebuilt segment; ties go to the smallest tier so tiny segments are
/// swept up first (classic tiered/"log-structured" behavior). The
/// active segment participates so a merge also folds in recent writes.
/// Rebuild replays the newest live version of every document through
/// `Index::add`, which drops deleted docs and reassigns doc numbers.
pub fn SegmentedIndex::merge(
  self : SegmentedIndex,
  max_segments~ : Int32 = 4,
) -> Unit {
  let cap = if max_segments < 1 { 1 } else { max_segments }
  while self.segment_count() > cap {
    // Collect all segments (immutable + active) with their size class.
    let all : Array[Index] = []
    for segment in self.segments {
      all.push(segment)
    }
    if self.active.doc_ids.length() > 0 {
      all.push(self.active)
    }
    // Bucket by floor(log2(live docs)); empty segments land in class 0.
    let tiers : Array[Array[Int32]] = []
    for i in 0..<all.length() {
      let size = all[i].doc_count()
      let mut cls = 0
      let mut s = size
      while s > 1 {
        s = s / 2
        cls += 1
      }
      while tiers.length() <= cls {
        tiers.push([])
      }
      tiers[cls].push(i)
    }
    // Pick the fullest tier; tie-break toward the smaller class index.
    let mut best_cls = 0
    let mut best_len = 0
    for cls in 0..<tiers.length() {
      if tiers[cls].length() > best_len {
        best_len = tiers[cls].length()
        best_cls = cls
      }
    }
    if best_len < 2 {
      // No tier has 2+ segments: sizes are all distinct powers of two.
      // Merge the two smallest segments to make progress.
      let order : Array[Int32] = []
      for i in 0..<all.length() {
        order.push(i)
      }
      order.sort_by(fn(a, b) { all[a].doc_count().compare(all[b].doc_count()) })
      self.collapse(all, [order[0], order[1]])
    } else {
      self.collapse(all, tiers[best_cls])
    }
  }
}

///|
/// Rebuild the given segments (indices into `all`, oldest-first order
/// preserved) into one segment and rewrite the segment stack.
fn SegmentedIndex::collapse(
  self : SegmentedIndex,
  all : Array[Index],
  chosen : Array[Int32],
) -> Unit {
  let picked : @hashmap.HashMap[Int32, Unit] = @hashmap.HashMap([])
  for i in chosen {
    picked.set(i, ())
  }
  // Replay oldest-first so the newest version of each id wins.
  let latest : @hashmap.HashMap[String, Document] = @hashmap.HashMap([])
  for i in 0..<all.length() {
    if !picked.contains(i) {
      continue
    }
    let segment = all[i]
    for num in 0..<segment.doc_ids.length() {
      if segment.deleted.contains(num) {
        continue
      }
      let id = segment.doc_ids[num]
      match segment.get_document(id) {
        Some(doc) => latest.set(id, doc)
        None => ()
      }
    }
  }
  let rebuilt = self.new_active()
  // Deterministic order: sort ids so merges are reproducible.
  let ids : Array[String] = []
  for (id, _) in latest.iter() {
    ids.push(id)
  }
  ids.sort()
  for id in ids {
    rebuilt.add(latest[id])
  }
  // Rebuild the stack. The merged segment is inserted at the position
  // of the newest chosen segment. Any id it carries whose newest live
  // version lives in an UNTOUCHED segment (older OR newer — tier
  // selection is size-based, not recency-based) is tombstoned inside
  // the rebuild, so the untouched version keeps winning no matter where
  // the rebuild lands (regression-tested). If the active segment was
  // chosen it is folded into the rebuild and a fresh empty active
  // segment replaces it.
  let mut insert_at = 0
  for i in 0..<all.length() {
    if picked.contains(i) {
      insert_at = i
    }
  }
  let active_included = self.active.doc_ids.length() > 0
  for i in 0..<all.length() {
    if picked.contains(i) {
      continue
    }
    let untouched = all[i]
    for num in 0..<untouched.doc_ids.length() {
      if untouched.deleted.contains(num) {
        continue
      }
      let id = untouched.doc_ids[num]
      if latest.contains(id) {
        ignore(rebuilt.delete(id))
      }
    }
  }
  let new_segments : Array[Index] = []
  for i in 0..<all.length() {
    let is_active = active_included && i == all.length() - 1
    if picked.contains(i) {
      if i == insert_at {
        new_segments.push(rebuilt)
      }
      continue
    }
    if !is_active {
      new_segments.push(all[i])
    }
  }
  self.segments = new_segments
  if active_included && picked.contains(all.length() - 1) {
    self.active = self.new_active()
  }
}

///|
/// Serialize: magic "MSKS" | payload | crc32(payload) u32le.
/// Payload: version | segment_max_docs | schema | analyzer/bm25 config |
/// immutable segment count | each segment as length-prefixed MSK2 image |
/// active segment as length-prefixed MSK2 image.
pub fn SegmentedIndex::to_bytes(self : SegmentedIndex) -> Bytes {
  let payload : Array[Byte] = []
  write_varint(payload, SEGMENT_VERSION)
  write_varint(payload, self.segment_max_docs)
  write_varint(payload, self.schema.length())
  for field in self.schema {
    write_string(payload, field.name)
    write_double(payload, field.weight)
  }
  write_varint(payload, if self.analyzer.lowercase { 1 } else { 0 })
  write_varint(payload, if self.analyzer.remove_stop_words { 1 } else { 0 })
  write_varint(payload, if self.analyzer.cjk_bigram { 1 } else { 0 })
  write_double(payload, self.bm25.k1)
  write_double(payload, self.bm25.b)
  write_varint(payload, self.segments.length())
  for segment in self.segments {
    let image = segment.to_bytes()
    write_varint(payload, image.length())
    for b in image.iter() {
      payload.push(b)
    }
  }
  let active_image = self.active.to_bytes()
  write_varint(payload, active_image.length())
  for b in active_image.iter() {
    payload.push(b)
  }
  let image : Array[Byte] = []
  for b in SEGMENT_MAGIC.iter() {
    image.push(b)
  }
  for b in payload {
    image.push(b)
  }
  write_u32_le(image, crc32(Bytes::from_array(payload[:])))
  Bytes::from_array(image[:])
}

///|
/// Restore a segmented index from a byte image. Raises on bad magic,
/// unknown version, truncation, or checksum mismatch.
pub fn SegmentedIndex::from_bytes(
  data : Bytes,
) -> SegmentedIndex raise CodecError {
  if data.length() < 8 {
    raise CodecError::UnexpectedEof
  }
  let magic = match data.get_view(end=4) {
    Some(m) => m
    None => raise CodecError::UnexpectedEof
  }
  if magic != SEGMENT_MAGIC {
    raise CodecError::BadMagic
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
  if version != SEGMENT_VERSION {
    raise CodecError::BadVersion(version)
  }
  let segment_max_docs = reader.read_varint()
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
  let analyzer : Analyzer = { lowercase, remove_stop_words, cjk_bigram, }
  let bm25 : Bm25Params = { k1, b, }
  let segment_count = reader.read_varint()
  let segments : Array[Index] = []
  for _ in 0..<segment_count {
    segments.push(read_framed_index(reader))
  }
  let active = read_framed_index(reader)
  if reader.remaining() != 0 {
    raise CodecError::UnexpectedEof
  }
  {
    schema,
    analyzer,
    bm25,
    segments,
    active,
    segment_max_docs: if segment_max_docs < 1 {
      1
    } else {
      segment_max_docs
    },
  }
}

///|
fn read_framed_index(reader : Reader) -> Index raise CodecError {
  let len = reader.read_varint()
  if len > reader.remaining() {
    raise CodecError::UnexpectedEof
  }
  let view = match
    reader.data.get_view(start=reader.pos, end=reader.pos + len) {
    Some(v) => v
    None => raise CodecError::UnexpectedEof
  }
  reader.pos += len
  Index::from_bytes(view.to_owned())
}
