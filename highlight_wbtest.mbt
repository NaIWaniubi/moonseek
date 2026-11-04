///|
/// Drift guard: the offset-aware analyzer must emit exactly the same terms
/// in the same order as Analyzer::analyze, and every recorded span must
/// reproduce its term from the source text.
test "offset analyzer agrees with Analyzer::analyze" {
  let texts = [
    "", "   \t\n ", "The Quick BROWN fox jumps!", "hello,world;foo-bar", "全文搜索引擎很棒",
    "MoonBit 搜索引擎 rocks", "猫", "猫和狗", "hello 世界 world", "😀 target 🎉 mixed 中文case",
    "a\u{1F600}b 搜索引擎 x", "stop the and of it", // all stop words -> no tokens
  ]
  let configs : Array[Analyzer] = [
    Analyzer::default(),
    { lowercase: false, remove_stop_words: false, cjk_bigram: true, },
    { lowercase: true, remove_stop_words: true, cjk_bigram: false, },
    { lowercase: false, remove_stop_words: true, cjk_bigram: false, },
  ]
  for analyzer in configs {
    for text in texts {
      let expected = analyzer.analyze(text)
      let actual = analyze_with_offsets(analyzer, text)
      assert_eq(actual.length(), expected.length())
      let chars = text.to_array()
      for i in 0..<expected.length() {
        assert_eq(actual[i].term, expected[i].term)
        assert_true(actual[i].start >= 0)
        assert_true(actual[i].end <= chars.length())
        assert_true(actual[i].start < actual[i].end)
        // The span must reproduce the term (after the analyzer's ASCII
        // lowercasing) from the original source characters.
        let slice = chars[actual[i].start:actual[i].end]
        let normalized = if analyzer.lowercase {
          slice.map(fn(c) { c.to_ascii_lowercase() })
        } else {
          slice.to_owned()
        }
        assert_eq(String::from_array(normalized[:]), expected[i].term)
      }
    }
  }
}
