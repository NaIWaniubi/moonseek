///|
/// Build a small index with one English/Chinese document for highlight tests.
fn hl_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "d1",
    fields: [
      ("title", "MoonBit programming language"),
      ("body", "MoonBit is a fast language for WebAssembly"),
    ],
  })
  idx
}

///|
fn spans_eq(
  actual : Array[@moonseek.HighlightSpan],
  expected : Array[(Int32, Int32)],
) -> Bool {
  if actual.length() != expected.length() {
    return false
  }
  for i in 0..<expected.length() {
    if actual[i].start != expected[i].0 || actual[i].end != expected[i].1 {
      return false
    }
  }
  true
}

///|
test "query_terms collects term phrase and prefix, dedups" {
  let q = @moonseek.parse_query("moonbit OR rust AND moonbit prog*")
  let terms = @moonseek.query_terms(q)
  // Order is unspecified; compare as sets.
  assert_eq(terms.length(), 3)
  assert_true(terms.contains("moonbit"))
  assert_true(terms.contains("rust"))
  assert_true(terms.contains("prog"))
}

///|
test "query_terms collects phrase words" {
  let q = @moonseek.parse_query("\"systems language\"")
  let terms = @moonseek.query_terms(q)
  assert_eq(terms.length(), 2)
  assert_true(terms.contains("systems"))
  assert_true(terms.contains("language"))
}

///|
test "query_terms ignores Not right branch" {
  let q = @moonseek.parse_query("language NOT rust")
  let terms = @moonseek.query_terms(q)
  assert_eq(terms, ["language"])
}

///|
test "query_terms leading NOT and MatchAll yield nothing" {
  let q1 = @moonseek.parse_query("NOT language")
  assert_eq(@moonseek.query_terms(q1).length(), 0)
  let q2 = @moonseek.parse_query("*")
  assert_eq(@moonseek.query_terms(q2).length(), 0)
}

///|
test "highlight spans case-insensitive, all occurrences" {
  let idx = hl_index()
  let spans = idx.highlight_spans("d1", "title", "moonbit")
  assert_true(spans_eq(spans, [(0, 7)]))
  let body = idx.highlight_spans("d1", "body", "MOONBIT")
  assert_true(spans_eq(body, [(0, 7)]))
}

///|
test "highlight spans respect word boundaries" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "search searching research searches")], })
  // Whole-token match: only the standalone word, not substrings.
  let spans = idx.highlight_spans("a", "body", "search")
  assert_true(spans_eq(spans, [(0, 6)]))
}

///|
test "highlight inserts tags and escapes HTML" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({
    id: "a",
    fields: [("body", "a <script>alert(1)</script> & \"quote\" 'x'")],
  })
  let out = idx.highlight("a", "body", "script")
  // The word appears twice (open + close tag text), both highlighted; markup escaped.
  assert_eq(
    out, "a &lt;<mark>script</mark>&gt;alert(1)&lt;/<mark>script</mark>&gt; &amp; &quot;quote&quot; &#39;x&#39;",
  )
}

///|
test "highlight with custom tags" {
  let idx = hl_index()
  let out = idx.highlight("d1", "title", "moonbit", pre_tag="[", post_tag="]")
  assert_eq(out, "[MoonBit] programming language")
}

///|
test "highlight no match returns escaped original" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "x < y & z")], })
  let out = idx.highlight("a", "body", "absent")
  assert_eq(out, "x &lt; y &amp; z")
}

///|
test "chinese bigram spans merge overlapping" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "搜索引擎")], })
  // Query analyzes to bigrams 搜索/索引/引擎 -> [0,2),[1,3),[2,4) merge to [0,4).
  let spans = idx.highlight_spans("a", "body", "搜索引擎")
  assert_true(spans_eq(spans, [(0, 4)]))
  let out = idx.highlight("a", "body", "搜索引擎")
  assert_eq(out, "<mark>搜索引擎</mark>")
}

///|
test "chinese bigrams in longer text" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "全文搜索引擎很棒")], })
  // 全文搜索引擎很棒 = 8 chars; 搜索/索引/引擎 cover [2,6).
  let spans = idx.highlight_spans("a", "body", "搜索引擎")
  assert_true(spans_eq(spans, [(2, 6)]))
  let out = idx.highlight("a", "body", "搜索引擎")
  assert_eq(out, "全文<mark>搜索引擎</mark>很棒")
}

///|
test "single chinese char query highlights unigram" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  // A length-1 CJK run emits a unigram token (the analyzer only bigrams
  // runs of length >= 2), so the single-char term matches exactly.
  idx.add({ id: "a", fields: [("body", "猫 cat")], })
  let spans = idx.highlight_spans("a", "body", "猫")
  assert_true(spans_eq(spans, [(0, 1)]))
  assert_eq(idx.highlight("a", "body", "猫"), "<mark>猫</mark> cat")
}

///|
test "single char query does not highlight inside bigram runs" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "猫和狗")], })
  // Search itself finds nothing here (only bigrams 猫和/和狗 are indexed),
  // so highlighting must stay consistent: no spans, escaped original.
  assert_eq(idx.search("猫").length(), 0)
  assert_eq(idx.highlight_spans("a", "body", "猫").length(), 0)
  assert_eq(idx.highlight("a", "body", "猫"), "猫和狗")
}

///|
test "phrase query highlights only adjacent run" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({
    id: "a",
    fields: [("body", "language systems and systems language")],
  })
  let spans = idx.highlight_spans("a", "body", "\"systems language\"")
  // Only the second occurrence is the phrase in order: chars [21, 37).
  assert_true(spans_eq(spans, [(21, 37)]))
}

///|
test "prefix query highlights matching whole words" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "prog program progress stop")], })
  let spans = idx.highlight_spans("a", "body", "prog*")
  assert_true(spans_eq(spans, [(0, 4), (5, 12), (13, 21)]))
  let out = idx.highlight("a", "body", "prog*")
  assert_eq(
    out, "<mark>prog</mark> <mark>program</mark> <mark>progress</mark> stop",
  )
}

///|
test "snippet picks densest window with ellipsis" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  // Two clusters of the term; the denser cluster (10 x's) is later in the text.
  let text = "alpha beta gamma x x x x x delta epsilon zeta eta theta x x x x x x x x x x end"
  idx.add({ id: "a", fields: [("body", text)], })
  let out = idx.snippet("a", "body", "x", max_chars=20)
  assert_true(out.has_prefix("…"))
  assert_true(out.has_suffix("…"))
  assert_true(out.contains("<mark>x</mark>"))
  // The denser cluster (10 x's) must beat the earlier cluster (5 x's).
  let count = out.split("<mark>").to_array().length() - 1
  assert_eq(count, 10)
}

///|
test "snippet no match takes head without leading ellipsis" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "abcdefghij klmnop")], })
  let out = idx.snippet("a", "body", "absent", max_chars=5)
  assert_eq(out, "abcde…")
}

///|
test "snippet short text returns whole without ellipsis" {
  let idx = hl_index()
  let out = idx.snippet("d1", "title", "moonbit", max_chars=150)
  assert_eq(out, "<mark>MoonBit</mark> programming language")
}

///|
test "snippet escapes HTML outside tags" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "<b>hello</b> world")], })
  let out = idx.snippet("a", "body", "hello", max_chars=150)
  assert_eq(out, "&lt;b&gt;<mark>hello</mark>&lt;/b&gt; world")
}

///|
test "highlight unknown document raises" {
  let idx = hl_index()
  let result = idx.highlight_spans("missing", "body", "moonbit") catch {
    e => {
      assert_true(e is @moonseek.QueryError::UnknownField(_))
      return ()
    }
  }
  let _ = result
  fail("unknown document should raise")
}

///|
test "highlight unknown field raises" {
  let idx = hl_index()
  let result = idx.highlight("d1", "nope", "moonbit") catch {
    e => {
      assert_true(e is @moonseek.QueryError::UnknownField(_))
      return ()
    }
  }
  let _ = result
  fail("unknown field should raise")
}

///|
test "highlight empty query raises" {
  let idx = hl_index()
  let result = idx.snippet("d1", "body", "") catch {
    e => {
      assert_true(e is @moonseek.QueryError::EmptyQuery)
      return ()
    }
  }
  let _ = result
  fail("empty query should raise")
}

///|
test "highlight deleted document raises" {
  let idx = hl_index()
  let _ = idx.delete("d1")
  let result = idx.highlight("d1", "body", "moonbit") catch {
    e => {
      assert_true(e is @moonseek.QueryError::UnknownField(_))
      return ()
    }
  }
  let _ = result
  fail("deleted document should raise")
}

///|
test "overlapping spans from OR merge" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "abcd")], })
  // Two prefix queries whose matches overlap on the same word.
  let spans = idx.highlight_spans("a", "body", "ab* OR abc*")
  assert_true(spans_eq(spans, [(0, 4)]))
}

///|
test "mixed chinese english offsets" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello 世界 world")], })
  // 世界 is chars [6,8).
  let spans = idx.highlight_spans("a", "body", "世界")
  assert_true(spans_eq(spans, [(6, 8)]))
  assert_eq(
    idx.highlight("a", "body", "世界"),
    "hello <mark>世界</mark> world",
  )
}

///|
test "non-BMP chars keep codepoint offsets" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  // Emoji is one codepoint (two UTF-16 units); offsets must count codepoints.
  idx.add({ id: "a", fields: [("body", "😀 target")], })
  let spans = idx.highlight_spans("a", "body", "target")
  assert_true(spans_eq(spans, [(2, 8)]))
  assert_eq(idx.highlight("a", "body", "target"), "😀 <mark>target</mark>")
}

///|
test "field-scoped query highlights across fields by term" {
  let idx = hl_index()
  // Query restricted to title still supplies the term to highlight in body.
  let out = idx.highlight("d1", "body", "title:moonbit")
  assert_eq(out, "<mark>MoonBit</mark> is a fast language for WebAssembly")
}

///|
test "highlight spans sorted, adjacent bigrams kept separate" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "搜索引擎搜索")], })
  let spans = idx.highlight_spans("a", "body", "搜索 OR 引擎")
  // 搜索 matches [0,2) and [4,6); 引擎 matches [2,4). Adjacent but not
  // overlapping: merging is overlap-only, so all three survive, sorted.
  assert_true(spans_eq(spans, [(0, 2), (2, 4), (4, 6)]))
  for i in 0..<spans.length() {
    assert_true(spans[i].start < spans[i].end)
    if i > 0 {
      assert_true(spans[i - 1].end <= spans[i].start)
    }
  }
}

///|
test "highlight respects lowercase=false analyzer" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }], analyzer={
    lowercase: false,
    remove_stop_words: true,
    cjk_bigram: true,
  })
  idx.add({ id: "a", fields: [("body", "Hello hello")], })
  // Terms keep their case: query Hello matches only the capitalized token.
  let spans = idx.highlight_spans("a", "body", "Hello")
  assert_true(spans_eq(spans, [(0, 5)]))
  assert_eq(idx.highlight("a", "body", "Hello"), "<mark>Hello</mark> hello")
  let lower = idx.highlight_spans("a", "body", "hello")
  assert_true(spans_eq(lower, [(6, 11)]))
}

///|
test "highlight with cjk_bigram=false analyzer" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }], analyzer={
    lowercase: true,
    remove_stop_words: true,
    cjk_bigram: false,
  })
  idx.add({ id: "a", fields: [("body", "搜索引擎")], })
  // Unigram analyzer: query 搜索 analyzes to [搜, 索], matched as a phrase.
  let spans = idx.highlight_spans("a", "body", "搜索")
  assert_true(spans_eq(spans, [(0, 2)]))
  assert_eq(idx.highlight("a", "body", "搜索"), "<mark>搜索</mark>引擎")
}

///|
test "highlight empty field text returns empty" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "")], })
  assert_eq(idx.highlight_spans("a", "body", "anything").length(), 0)
  assert_eq(idx.highlight("a", "body", "anything"), "")
  assert_eq(idx.snippet("a", "body", "anything"), "")
}

///|
test "snippet max_chars zero yields empty string" {
  let idx = hl_index()
  assert_eq(idx.snippet("d1", "body", "moonbit", max_chars=0), "")
}

///|
test "snippet window trims partial spans at edges" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "aaaa target bbbb")], })
  // All windows overlapping the span tie on density (1); the earliest
  // wins: [0,10) cuts the span mid-word, and the tag closes at the window
  // edge — never left dangling.
  let out = idx.snippet("a", "body", "target", max_chars=10)
  assert_eq(out, "aaaa <mark>targe</mark>…")
  // Balanced tags: every pre_tag has a matching post_tag.
  let opens = out.split("<mark>").to_array().length() - 1
  let closes = out.split("</mark>").to_array().length() - 1
  assert_eq(opens, closes)
}
