///|
/// Server journal, native file layer. Requires `targets: native` in
/// moon.pkg (uses moonbitlang/async/fs).
///
/// Protocol, identical in shape to the engine WAL's:
/// - `append` writes one framed record with data fsync, then the caller
///   applies it in memory. A crash between the two leaves the record in the
///   journal; replay applies it.
/// - `checkpoint` serializes the whole index to `index.msk.tmp`, fsyncs,
///   atomically renames over `index.msk`, then truncates the journal.
/// - `replay` reads the journal through the CRC framing, stopping at a torn
///   tail, so a crash mid-write can only lose the incomplete record.
///
/// The journal file is `dir/journal.log`; the snapshot is `dir/index.msk`.

///|
const JOURNAL_FILE : String = "/journal.log"

///|
const JOURNAL_SNAPSHOT : String = "/index.msk"

///|
/// Append one record to `dir/journal.log` with a data fsync. Returns only
/// after the record is durable, so a caller may then apply it in memory.
pub async fn journal_append(
  dir : String,
  entry : JournalEntry,
) -> Unit raise StoreError {
  let buf : Array[Byte] = []
  for b in JOURNAL_MAGIC.iter() {
    buf.push(b)
  }
  journal_append_entry(buf, entry)
  // create_mode=OpenOrCreate, not the write_file default: the default
  // truncates on open, which would wipe the log even with append=true.
  @fs.write_file(
    dir + JOURNAL_FILE,
    Bytes::from_array(buf[:]),
    create_mode=OpenOrCreate,
    append=true,
    sync=Data,
  ) catch {
    e => raise StoreError::IoError(e.to_string())
  }
}

///|
/// Append several records in one write with one data fsync. Each record keeps
/// its own CRC frame, so a batch torn by a crash still replays its complete
/// prefix — batching does not weaken the guarantee, it only shares the fsync.
/// That matters for bulk ingest: one fsync per document costs about 2.6× the
/// throughput of one per batch on this machine.
pub async fn journal_append_many(
  dir : String,
  entries : Array[JournalEntry],
) -> Unit raise StoreError {
  if entries.is_empty() {
    return ()
  }
  let buf : Array[Byte] = []
  for b in JOURNAL_MAGIC.iter() {
    buf.push(b)
  }
  for entry in entries {
    journal_append_entry(buf, entry)
  }
  @fs.write_file(
    dir + JOURNAL_FILE,
    Bytes::from_array(buf[:]),
    create_mode=OpenOrCreate,
    append=true,
    sync=Data,
  ) catch {
    e => raise StoreError::IoError(e.to_string())
  }
}

///|
/// Every record in `dir/journal.log`, in order. A missing journal is an empty
/// log, not an error. A torn tail replays only the complete prefix; a file
/// that is not a journal at all raises.
pub async fn journal_replay(
  dir : String,
) -> Array[JournalEntry] raise StoreError {
  let path = dir + JOURNAL_FILE
  let exists = @fs.exists(path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  if !exists {
    return []
  }
  let data = @fs.read_file(path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  journal_decode(data.binary()) catch {
    e => raise StoreError::CorruptIndex(@debug.to_string(e))
  }
}

///|
/// Write the index to `dir/index.msk` atomically and truncate the journal.
/// A crash before the rename leaves the old snapshot plus the whole journal
/// (replayed on open); a crash after the rename but before the truncation
/// replays already-checkpointed records, which is idempotent because a Put
/// replaces by id and Remove is a tombstone. An empty journal is left alone
/// rather than recreated, so the next append still writes its header.
pub async fn journal_checkpoint(
  dir : String,
  index : Index,
) -> Unit raise StoreError {
  let path = dir + JOURNAL_SNAPSHOT
  let tmp = path + ".tmp"
  @fs.write_file(tmp, index.to_bytes(), sync=Data) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  @fs.rename(tmp, path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  // Truncate after the rename: a crash here only causes a redundant replay.
  @fs.write_file(
    dir + JOURNAL_FILE,
    Bytes::from_array([]),
    create_mode=CreateOrTruncate,
    sync=Data,
  ) catch {
    e => raise StoreError::IoError(e.to_string())
  }
}

///|
/// True when `dir` holds a checkpoint, so a caller can decide whether to
/// create an empty index or load the stored one.
pub async fn journal_has_snapshot(dir : String) -> Bool raise StoreError {
  @fs.exists(dir + JOURNAL_SNAPSHOT) catch {
    e => raise StoreError::IoError(e.to_string())
  }
}

///|
/// The stored snapshot, for replay to start from. Raises when it is absent or
/// corrupt — a corrupt snapshot must never be silently replaced by an empty
/// index, which the next checkpoint would make permanent.
pub async fn journal_load_snapshot(dir : String) -> Index raise StoreError {
  let path = dir + JOURNAL_SNAPSHOT
  let data = @fs.read_file(path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  Index::from_bytes(data.binary()) catch {
    e => raise StoreError::CorruptIndex(@debug.to_string(e))
  }
}
