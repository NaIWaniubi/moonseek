///|
/// Write-ahead log, native file layer. Requires `targets: native` in
/// moon.pkg (uses moonbitlang/async/fs).
///
/// Durability protocol:
/// - `add_durable` / `delete_durable`: append one CRC-framed entry to
///   `dir/wal.log` with data fsync, THEN apply it in memory. A crash
///   between the two leaves the entry in the WAL; recovery replays it.
/// - `checkpoint`: serialize the whole index to `segments.msk.tmp`,
///   fsync, atomically rename over `segments.msk`, then truncate the
///   WAL. A crash before the rename leaves the old snapshot + full WAL
///   (replayed on open); a crash after the rename but before truncation
///   replays already-checkpointed entries, which is idempotent because
///   Add replaces by id and Delete is a tombstone.
/// - `open_or_create`: load `segments.msk` if present (corrupt snapshot
///   is an error, never silently dropped), then replay `wal.log` on top.
///   A torn WAL tail replays only the complete prefix.

///|
/// Open the index stored in `dir`, or create a fresh one. Replays the
/// WAL on top of the last checkpoint. The directory is created if missing.
pub async fn SegmentedIndex::open_or_create(
  dir : String,
  schema : Array[FieldSchema],
) -> SegmentedIndex raise StoreError {
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  let snapshot_path = dir + "/segments.msk"
  let has_snapshot = @fs.exists(snapshot_path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  let seg = if has_snapshot {
    let data = @fs.read_file(snapshot_path) catch {
      e => raise StoreError::IoError(e.to_string())
    }
    SegmentedIndex::from_bytes(data.binary()) catch {
      e => raise StoreError::CorruptIndex(@debug.to_string(e))
    }
  } else {
    SegmentedIndex::new(schema)
  }
  let wal_path = dir + "/wal.log"
  let has_wal = @fs.exists(wal_path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  if has_wal {
    let data = @fs.read_file(wal_path) catch {
      e => raise StoreError::IoError(e.to_string())
    }
    let entries = wal_decode(data.binary()) catch {
      e => raise StoreError::CorruptIndex(@debug.to_string(e))
    }
    // Schema guard BEFORE any replay: an Add referencing a field absent
    // from the snapshot schema would abort() deep inside Index::add
    // (uncatchable, process dies on open). Fail as a catchable
    // StoreError instead so callers can quarantine the directory.
    let known : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
    for field in schema {
      known.set(field.name, ())
    }
    for entry in entries {
      match entry {
        Add(doc) =>
          for (name, _) in doc.fields {
            if !known.contains(name) {
              raise StoreError::CorruptIndex(
                "wal references unknown field: " + name,
              )
            }
          }
        Delete(_) => ()
      }
    }
    for entry in entries {
      match entry {
        Add(doc) => seg.add(doc)
        Delete(id) => ignore(seg.delete(id))
      }
    }
  }
  seg
}

///|
/// Atomically persist the full index state and clear the WAL.
/// Write temp + fsync + rename, then truncate the log.
pub async fn SegmentedIndex::checkpoint(
  self : SegmentedIndex,
  dir : String,
) -> Unit raise StoreError {
  let image = self.to_bytes()
  let tmp = dir + "/segments.msk.tmp"
  let dest = dir + "/segments.msk"
  try {
    @fs.write_file(tmp, image, sync=Data)
    @fs.rename(tmp, dest)
    // Order guarantee between the rename and the WAL truncation is what
    // makes the crash window below safe: without syncing the directory
    // entry, a power loss can persist the truncate before the rename,
    // leaving "old snapshot + empty WAL" — every write since the last
    // checkpoint lost even though checkpoint() returned. Sync the
    // directory now so the rename is durable BEFORE the WAL is emptied.
    // Windows: FlushFileBuffers needs write access on the directory
    // handle; POSIX: fsync on a ReadOnly fd is enough. Without this
    // (wasm/js), skip — those targets have no durability contract here.
    sync_directory(dir)
    // The snapshot now covers everything; the WAL may be discarded.
    // A crash between the dir sync and truncate is safe: replaying the
    // WAL on top of the new snapshot is idempotent.
    @fs.write_file(dir + "/wal.log", b"", sync=Data)
  } catch {
    e => raise StoreError::IoError(e.to_string())
  }
}

///|
// fsync the directory entry itself so a rename inside `dir` is durable
// before subsequent writes. Windows: FlushFileBuffers rejects a
// GENERIC_READ directory handle (Access denied), so open WriteOnly —
// O_WRONLY on a directory succeeds there and OpenExisting carries no
// truncate semantics. POSIX: opening a directory write-only fails with
// EISDIR, so ReadOnly is used; fsync on that fd is exactly the
// directory-entry durability primitive. A failure surfaces to the caller
// as StoreError rather than silently skipping the ordering guarantee.
#cfg(all(target="native", platform="windows"))
async fn sync_directory(dir : String) -> Unit {
  let f = @fs.open(dir, mode=WriteOnly)
  defer f.close()
  f.sync(only_data=false)
}

///|
#cfg(all(target="native", not(platform="windows")))
async fn sync_directory(dir : String) -> Unit {
  let f = @fs.open(dir, mode=ReadOnly)
  defer f.close()
  f.sync(only_data=false)
}

///|
/// Append an Add entry to `dir/wal.log` (fsync) and then apply it in
/// memory. `dir` must be the same directory passed to `open_or_create`.
pub async fn SegmentedIndex::add_durable(
  self : SegmentedIndex,
  dir : String,
  doc : Document,
) -> Unit raise StoreError {
  append_wal_entry(dir, Add(doc))
  self.add(doc)
}

///|
/// Append a Delete entry to `dir/wal.log` (fsync) and then apply it in
/// memory. Returns true if the id existed (same semantics as `delete`).
pub async fn SegmentedIndex::delete_durable(
  self : SegmentedIndex,
  dir : String,
  id : String,
) -> Bool raise StoreError {
  append_wal_entry(dir, Delete(id))
  self.delete(id)
}

///|
async fn append_wal_entry(
  dir : String,
  entry : WalEntry,
) -> Unit raise StoreError {
  let buf : Array[Byte] = []
  // Each append batch carries the header so a fresh file is self-
  // describing; wal_decode skips repeated headers.
  for b in WAL_MAGIC.iter() {
    buf.push(b)
  }
  wal_encode_entry(buf, entry)
  // create_mode=OpenOrCreate is essential: write_file defaults to
  // CreateOrTruncate, which would wipe the log on every append even
  // with append=true (truncation happens at open time).
  @fs.write_file(
    dir + "/wal.log",
    Bytes::from_array(buf[:]),
    create_mode=OpenOrCreate,
    append=true,
    sync=Data,
  ) catch {
    e => raise StoreError::IoError(e.to_string())
  }
}
