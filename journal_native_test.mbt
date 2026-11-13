///|
/// Tests for the server journal's native file layer: append/replay, checkpoint
/// truncation, idempotent replay, and the crash cases that decide whether a
/// restart loses data.

///|
async fn jdir(name : String) -> String {
  let base = @fs.tmpdir(prefix="moonseek-journal-")
  let dir = base + "/" + name
  @fs.mkdir(dir, recursive=true, allow_exist=true)
  dir
}

///|
fn jdoc(id : String) -> @moonseek.JournalDoc {
  {
    id,
    fields: [("title", "moonbit"), ("body", "search engine")],
    facets: [("topic", ["search"])],
    nums: [("stars", 7.0)],
    vectors: [("emb", [0.1, 0.2])],
  }
}

///|
async test "journal: records appended to disk replay in order" {
  let dir = jdir("order")
  @moonseek.journal_append(dir, Put(jdoc("a"))) catch {
    e => fail(e.to_string())
  }
  @moonseek.journal_append(dir, Remove("a")) catch {
    e => fail(e.to_string())
  }
  @moonseek.journal_append(dir, Put(jdoc("b"))) catch {
    e => fail(e.to_string())
  }
  let entries = @moonseek.journal_replay(dir) catch { e => fail(e.to_string()) }
  assert_eq(entries, [Put(jdoc("a")), Remove("a"), Put(jdoc("b"))])
}

///|
async test "journal: a missing journal replays as empty, not an error" {
  let dir = jdir("missing")
  let entries = @moonseek.journal_replay(dir) catch { e => fail(e.to_string()) }
  assert_eq(entries, ([] : Array[@moonseek.JournalEntry]))
}

///|
async test "journal: checkpoint writes the snapshot and truncates the log" {
  let dir = jdir("checkpoint")
  let index = @moonseek.Index::new([{ name: "title", weight: 1.0, }])
  index.add({ id: "a", fields: [("title", "moonbit")], })
  @moonseek.journal_append(dir, Put(jdoc("a"))) catch {
    e => fail(e.to_string())
  }
  @moonseek.journal_append(dir, Put(jdoc("b"))) catch {
    e => fail(e.to_string())
  }
  @moonseek.journal_checkpoint(dir, index) catch {
    e => fail(e.to_string())
  }
  // The log is empty and the snapshot is there.
  assert_eq(
    @moonseek.journal_replay(dir) catch {
      _ => []
    },
    ([] : Array[@moonseek.JournalEntry]),
  )
  assert_true(@moonseek.journal_has_snapshot(dir) catch { _ => false })
  let restored = @moonseek.journal_load_snapshot(dir) catch {
    e => fail(e.to_string())
  }
  assert_eq(restored.doc_count(), 1)
}

///|
async test "journal: replay after a checkpoint is idempotent" {
  let dir = jdir("idempotent")
  let index = @moonseek.Index::new([{ name: "title", weight: 1.0, }])
  index.add({ id: "a", fields: [("title", "moonbit")], })
  @moonseek.journal_append(dir, Put(jdoc("a"))) catch {
    e => fail(e.to_string())
  }
  @moonseek.journal_checkpoint(dir, index) catch {
    e => fail(e.to_string())
  }
  // Simulate a crash *after* the rename but *before* the truncation: the
  // record is in both places, so replay must reapply it harmlessly.
  @moonseek.journal_append(dir, Put(jdoc("a"))) catch {
    e => fail(e.to_string())
  }
  let entries = @moonseek.journal_replay(dir) catch { e => fail(e.to_string()) }
  assert_eq(entries, [Put(jdoc("a"))])
  // Applying it again replaces by id rather than duplicating.
  for entry in entries {
    match entry {
      Put(doc) =>
        // The index's schema declares only `title`, so replay maps the journal
        // record onto the declared fields (the server does this in
        // `apply_entry`); unknown ones would abort `add`.
        index.add({
          id: doc.id,
          fields: doc.fields.filter(fn(p) { p.0 == "title" }),
        })
      Remove(id) => ignore(index.delete(id))
    }
  }
  assert_eq(index.doc_count(), 1)
}

///|
async test "journal: a torn tail loses only the incomplete record" {
  let dir = jdir("torn")
  @moonseek.journal_append(dir, Put(jdoc("a"))) catch {
    e => fail(e.to_string())
  }
  let before = @fs.read_file(dir + "/journal.log") catch {
    e => fail(e.to_string())
  }
  let good_len = before.binary().length()
  @moonseek.journal_append(dir, Put(jdoc("b"))) catch {
    e => fail(e.to_string())
  }
  // Truncate the file mid-way through the second record.
  let whole = @fs.read_file(dir + "/journal.log") catch {
    e => fail(e.to_string())
  }
  let raw = whole.binary()
  let cut = raw.to_array()[0:good_len + 5]
  @fs.write_file(dir + "/journal.log", Bytes::from_array(cut)) catch {
    e => fail(e.to_string())
  }
  let entries = @moonseek.journal_replay(dir) catch { e => fail(e.to_string()) }
  assert_eq(entries, [Put(jdoc("a"))])
}
