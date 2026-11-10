///|
/// Crash-safe file persistence for an index (native only).
/// Protocol: write the snapshot to `index.msk.tmp`, fsync it, then
/// atomically rename over `index.msk`. A crash at any point leaves either
/// the old complete snapshot or no snapshot — never a torn one. The
/// snapshot's own CRC catches any corruption that slips through.

///|
/// Errors from the store layer.
pub(all) suberror StoreError {
  IoError(String)
  CorruptIndex(String)
} derive(Eq, Debug)

///|
pub extend StoreError with Eq::{equal, not_equal}

///|
pub extend StoreError with @debug.Debug::{to_repr}

///|
pub extend StoreError with Show::{to_string, output}

///|
pub impl Show for StoreError with fn output(self : StoreError, logger) {
  match self {
    IoError(msg) => logger.write_string("io error: " + msg)
    CorruptIndex(msg) => logger.write_string("corrupt index: " + msg)
  }
}

///|
/// Save the index to `path` atomically (write temp + fsync + rename).
pub async fn Index::save(self : Index, path : String) -> Unit raise StoreError {
  let image = self.to_bytes()
  let tmp = path + ".tmp"
  try {
    @fs.write_file(tmp, image, sync=Data)
    @fs.rename(tmp, path)
  } catch {
    e => raise StoreError::IoError(e.to_string())
  }
}

///|
/// Load an index from `path`. Raises if the file is missing or corrupt.
pub async fn Index::load(path : String) -> Index raise StoreError {
  let data = @fs.read_file(path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  Index::from_bytes(data.binary()) catch {
    e => raise StoreError::CorruptIndex(@debug.to_string(e))
  }
}

///|
/// Load an index from `path`, or create a fresh one if the file does not
/// exist. A corrupt file is still an error (never silently discarded).
/// Existence is judged with `@fs.exists`, not `@fs.can_read`: a file that
/// exists but is unreadable (permissions, exclusive lock, AV scan) must
/// surface as an error, because silently creating a fresh in-memory index
/// would let the next save() atomically overwrite and destroy it.
pub async fn Index::load_or_create(
  path : String,
  schema : Array[FieldSchema],
) -> Index raise StoreError {
  let exists = @fs.exists(path) catch {
    e => raise StoreError::IoError(e.to_string())
  }
  if exists {
    Index::load(path)
  } else {
    Index::new(schema)
  }
}
