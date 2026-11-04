# Team Board

## ARCH
(see task brief: SegmentedIndex + tiered merge + WAL crash recovery, new files only)

## SPEC
(see task brief)

## BUILD

SLICE 1: segmented index + tiered merge + WAL crash recovery
  files:   segment.mbt, wal.mbt, wal_native.mbt, segment_test.mbt,
           wal_test.mbt, wal_native_test.mbt (all new; no existing source
           file touched; moon.pkg targets entry added by the integrator,
           not by this agent)
  test:    moon test --target native
  output:  RED (pre-implementation, verbatim):
    Error: [4024] segment_test.mbt:27:13
      The type/trait @moonseek.SegmentedIndex is not found.
    Error: [4021] wal_test.mbt:176:13
      Value wal_encode not found in package `moonseek`.
    (compilation failure; baseline before new tests: Total tests: 51, passed: 51, failed: 0)
    RED (native file layer, pre-implementation, verbatim):
    Error: [4015] wal_native_test.mbt:29:13
      Type @NaIWaniubi/moonseek.SegmentedIndex has no method open_or_create.
    RED (first green attempt exposed real bugs, verbatim):
    Total tests: 97, passed: 89, failed: 8.
    [wal_test.mbt:31] FAILED: `<Bytes: [0x4d,0x57,0x4c,0x31]> != <Bytes: []>`
    [wal_test.mbt:44] failed: CodecError.BadVersion (torn header tail)
    [segment_test.mbt:86] FAILED: `1 != 0` (stale-version term leaked)
    RED (native append bug found by durable tests, verbatim):
    test "durable: add_durable survives reopen without checkpoint"
      FAILED: `0 != 1`  (wal.log truncated on every append)
    debug: raw @fs.write_file(append=true) twice -> len=4 not 8
      (CreateOrTruncate default wipes the file at open time)
    RED (merge shadowing bug, regression test vs bug reintroduced in
    isolated copy, verbatim):
    [segment_test.mbt:200] "segment: merge preserves newest-wins across
    untouched segments" failed: segment_test.mbt:224:3-224:77
    FAILED: `Some({id:"a", fields:[("title","version one zebra"),...]})
    != Some({id:"a", fields:[("title","version two walrus"),...]})`
    Total tests: 21, passed: 20, failed: 1.
    (bug: a rebuild of two small segments could shadow a newer version
    of the same id in an untouched bigger segment; fix: tombstone inside
    the rebuild every id that has a live version in ANY untouched segment)
  output:  GREEN (final, verbatim):
    $ moon test --target native segment_test.mbt
    Total tests: 22, passed: 22, failed: 0.
    $ moon test --target native wal_test.mbt
    Total tests: 15, passed: 15, failed: 0.
    $ moon test --target native wal_native_test.mbt
    Total tests: 10, passed: 10, failed: 0.
    $ moon check --target native --deny-warn
    Finished. moon: ran 13 tasks, now up to date
    $ moon test --target native        (whole module)
    Total tests: 180, passed: 180, failed: 0.
    $ moon test --target wasm-gc       (whole module)
    Total tests: 166, passed: 166, failed: 0.
    $ moon test --target js            (whole module)
    Total tests: 166, passed: 166, failed: 0.
    $ moon fmt segment.mbt segment_test.mbt
    Finished. moon: ran 2 tasks, now up to date
  commit:  no-commit by this agent (task forbids it); files were swept into
           parallel commits c87083b / e437ccd by the integrator. Post-commit
           fixes (merge shadowing bug + regression test, get_field accessor
           requested by cmd/segprobe) are in the working tree, uncommitted:
           segment.mbt and segment_test.mbt differ from HEAD f4cc6c4.
  notes:   - Cross-segment scoring: per-segment max-score normalization to
             [0,1] (federated-search approximation; local IDF/avgdl are not
             comparable). Within-segment ranking preserved exactly; ties
             broken by id ascending. Newest-wins: a hit for a stale version
             is re-scored by evaluating the parsed query against a
             one-document probe index built from the newest version, so
             old-version-only terms cannot leak (regression-tested).
           - Merge: tiered policy, size class = floor(log2(live docs));
             while segment_count > max_segments, collapse the most
             populated tier (ties -> smaller class); if every tier has <2
             segments, merge the two smallest. Rebuild replays newest live
             versions via get_document + Index::add (drops tombstones,
             reassigns doc numbers, deterministic id-sorted order). The
             rebuild is inserted at the newest chosen segment's position
             AND every id it carries that also has a live version in any
             untouched segment is tombstoned inside the rebuild — tier
             selection is size-based, not recency-based, so a rebuild of
             two small old segments can contain a stale version of an id
             whose newest version sits in a bigger untouched segment
             (regression test "merge preserves newest-wins across
             untouched segments", proven Red against the unfixed code).
           - WAL recovery: entries are type-byte + payload + crc32 frames;
             decode replays the complete prefix and stops at the first
             torn/corrupt tail. Each append batch carries its own "MWL1"
             header; decode skips repeated headers, ignores a torn header
             tail, raises BadMagic/BadVersion only for a corrupt leading
             header or unknown entry type. Empty log = empty bytes.
           - Durability: add_durable/delete_durable append+fsync BEFORE
             memory apply; checkpoint = write segments.msk.tmp + fsync +
             rename + truncate wal. Crash between rename and truncate
             replays already-checkpointed entries — idempotent because Add
             replaces by id and Delete is a tombstone.
           - PITFALL (real bug, fixed): @fs.write_file(append=true) defaults
             to create_mode=CreateOrTruncate, which truncates the WAL on
             every append. Fixed with create_mode=OpenOrCreate. Verified by
             a raw two-append debug test (len 4 -> 8 after fix).
           - PITFALL: moonbitlang/async fs functions raise generic Error
             even though .mbti shows no raise clause; every call needs an
             explicit catch to convert into StoreError.
           - segment_count() counts frozen segments + non-empty active.
             delete() returns true for tombstoned ids (Index::delete
             semantics: doc_nums keeps the entry); only never-seen ids
             return false.
           - Not guaranteed: cross-segment score comparability is
             approximate by design (max-score normalization); a corpus
             where one segment's top hit is weakly relevant can still
             outrank a strong hit in a big segment. Global-stats BM25
             would fix it but requires touching index.mbt (forbidden).
           - Not guaranteed: merge() is O(total live docs) per collapse
             and doc_count()/search() rebuild the live-doc map each call;
             fine for the contest scale, not for millions of docs.
           - wal_native.mbt + wal_native_test.mbt need moon.pkg targets
             ["native"] (integrator already added them). wasm-gc/js builds
             show 2 pre-existing unused_package warnings for async/fs
             imports because all fs-using files are native-only; not
             introduced by this slice (store.mbt had the same pattern).

SLICE highlight: server-side highlight + snippet extraction
  files:   highlight.mbt, highlight_test.mbt, highlight_wbtest.mbt (new; no
           existing source files touched; pkg.generated.mbti regenerated by
           moon info as required by AGENTS.md)
  test:    moon test --target native highlight_test.mbt highlight_wbtest.mbt
  output:  RED (stubs return empty; tests written first):
    [NaIWaniubi/moonseek] test highlight_test.mbt:32 ("query_terms collects term phrase and prefix, dedups") failed: highlight_test.mbt:36:3-36:31@NaIWaniubi/moonseek FAILED: `0 != 3`
    [NaIWaniubi/moonseek] test highlight_test.mbt:52 ("query_terms ignores Not right branch") failed: highlight_test.mbt:55:55@... FAILED: `[] != ["language"]`
    [NaIWaniubi/moonseek] test highlight_test.mbt:88 ("highlight inserts tags and escapes HTML") failed: ... FAILED: `"" != "a &lt;<mark>script</mark>&gt;..."`
    [NaIWaniubi/moonseek] test highlight_test.mbt:118 ("chinese bigram spans merge overlapping") failed: ... FAILED: `false` is not true
    [NaIWaniubi/moonseek] test highlight_test.mbt:171 ("snippet picks densest window with ellipsis") failed: ... FAILED: `false` is not true
    (all 26 non-trivial highlight tests failed against stubs; 1 trivial empty-result test passed by design)
    Total tests: 124, passed: 93, failed: 31.
    NOTE: 5 of the 31 failures were wal_test.mbt/segment_test.mbt from the
    parallel segment+wal slice (in progress then). Highlight failures: 26.
  output:  GREEN (final, verbatim):
    $ moon test --target native highlight_test.mbt highlight_wbtest.mbt
    Total tests: 34, passed: 34, failed: 0.
    $ moon check --target native --deny-warn .
    Finished. moon: ran 21 tasks, now up to date
    $ moon check --target native        (whole module)
    Finished. moon: ran 27 tasks, now up to date
    $ moon test --target native         (whole module, after parallel WAL fix)
    Total tests: 178, passed: 178, failed: 0.
    $ moon fmt && moon info
    Finished. moon: ran 1 task, now up to date
    Finished. moon: ran 22 tasks, now up to date
    $ moon test --target native         (delivery-time re-run, whole module)
    Total tests: 179, passed: 179, failed: 0.
  commit:  no-commit by this agent (task forbids it); files were swept into
           parallel commit c87083b ("feat: fuzzy search, did-you-mean,
           highlighting, segmented index, WAL"); git diff HEAD on the three
           highlight files is empty (committed content == delivered content)
  notes:   - Token->source mapping: offset-aware analyzer variant
             (analyze_with_offsets) re-scans the stored text reusing
             token.mbt's package-private predicates (is_cjk/is_word_char/
             normalize_char/default_stop_words), so terms are identical to
             indexed ones; a whitebox drift-guard test cross-checks both
             analyzers over 12 texts x 4 configs and verifies each span
             reproduces its term from the source chars.
           - Offsets are Unicode codepoints (String::to_array indices), NOT
             UTF-16 units (String::length) and NOT bytes; non-BMP emoji test
             included. moon fmt rewrote Int->Int32 and param?->param~ to
             match existing project style; semantics unchanged.
           - Latin matching is whole-token (word-boundary), case handling
             follows the index analyzer (default lowercases both sides).
             Phrase queries highlight only adjacent runs; prefixes match
             whole tokens. Merge is overlap-only: adjacent disjoint spans
             stay separate (tested).
           - Unknown/deleted doc or missing field raises
             QueryError::UnknownField(field) — QueryError has no doc-specific
             variant and query.mbt could not be modified; documented in API.
           - Snippet density = number of overlapping merged spans in window;
             ties go to earliest window; tags clamped at window edges (a span
             cut by the window is closed at the edge, never dangling).
           - During development the shared tree intermittently failed to
             build due to parallel slices (fuzzy/suggest/wal); this slice was
             verified green in an isolated module copy throughout, and the
             final whole-module run above is fully green.
           - Delivery-time re-check: highlight tests 34/34 green, root pkg
             --deny-warn clean. Whole-module results fluctuate while the
             parallel segment slice is mid-edit (3 segment_test failures
             observed at one point); none involve highlight files.

SLICE fuzzy: fuzzy query + did-you-mean suggestion
  files:   fuzzy.mbt, suggest.mbt, fuzzy_test.mbt, suggest_test.mbt (new;
           no existing source files touched; pkg.generated.mbti regenerated
           by moon info as required by AGENTS.md)
  test:    moon test --target native fuzzy_test.mbt suggest_test.mbt
  output:  RED (pre-implementation; verbatim excerpts from moon check):
    Error: [4032] fuzzy_test.mbt:33:32
      The type @moonseek.FuzzyMatch is undefined.
    Error: [4021] fuzzy_test.mbt:39:13
      Value levenshtein not found in package `moonseek`.
    Error: [4021] suggest_test.mbt:28:17
      Type @NaIWaniubi/moonseek.Index has no method suggest.
    (74 errors total, all in fuzzy_test.mbt/suggest_test.mbt; 0 warnings in
     my files. The 3 remaining warnings are in highlight.mbt, parallel slice.)
  output:  GREEN (final, verbatim):
    $ moon test --target native fuzzy_test.mbt suggest_test.mbt
    Total tests: 35, passed: 35, failed: 0.
    $ moon check --target native --deny-warn .
    Finished. moon: ran 21 tasks, now up to date
    $ moon check --target native        (whole module)
    Finished. moon: ran 27 tasks, now up to date
    $ moon test --target native         (whole module)
    Total tests: 178, passed: 178, failed: 0.
    $ moon info . && moon fmt fuzzy.mbt fuzzy_test.mbt suggest.mbt suggest_test.mbt
    Finished. moon: ran 19 tasks, now up to date
    Finished. moon: ran 11 tasks, now up to date
    $ moon fmt --check fuzzy.mbt fuzzy_test.mbt suggest.mbt suggest_test.mbt
    Finished. moon: ran 33 tasks, now up to date
  commit:  no-commit (task forbids git commit; HEAD 69074b8)
  notes:   - Distances operate on Unicode codepoints (String::to_array), so
             CJK/astral chars count as 1 edit; String::length (UTF-16 units)
             is deliberately NOT used. levenshtein: single-row DP,
             O(min(m,n)) space; damerau: OSA variant, full matrix.
           - fuzzy_terms uses Damerau-Levenshtein (transposition = 1 edit,
             the common typo model), length-difference prefilter before any
             DP, vocabulary deduped across fields, sorted (distance, term).
             max_distance clamped to [0,2] (Lucene convention).
           - fuzzy_search merges per-doc scores by MAX across variant terms
             (a doc matching several variants is not double-counted);
             sort/limit semantics mirror Index::search exactly. Declared
             `raise QueryError` per task contract; implementation never
             raises, so #warnings("-unused_error_type") suppresses the
             unused-error warning (documented in the API doc comment).
           - suggest ranks candidates by (distance asc, doc_freq desc, term
             asc): closest typo first, common words break distance ties.
             Only bare single-token words are corrected; field:term, quoted
             phrases, AND/OR/NOT, foo*, parens are preserved verbatim; only
             the FIRST correctable word is fixed, spacing kept as-is.
           - Pitfall hit: initial fixtures assumed "serch"->"searching" is
             distance 2; true Damerau distance is 3, so tests were corrected
             to mathematically true vectors (searchx at distance 2) rather
             than weakening the implementation. "engins"->"engine"/"engines"
             are both distance 1; df weighting picks "engines" (tested).
           - During development the shared tree intermittently failed to
             build due to parallel slices (highlight/wal RED phases and
             examples/basic.mbt); verified green in an isolated module copy
             throughout; final whole-module run above is fully green.
