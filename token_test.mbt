///|
test "latin tokenization lowercases and drops stop words" {
  let tokens = tokenize("The Quick BROWN fox jumps!")
  assert_eq(tokens.length(), 4)
  assert_eq(tokens[0].term, "quick")
  assert_eq(tokens[1].term, "brown")
  assert_eq(tokens[2].term, "fox")
  assert_eq(tokens[3].term, "jumps")
  assert_eq(tokens[3].position, 3)
}

///|
test "cjk bigram tokenization" {
  let tokens = tokenize("全文搜索")
  assert_eq(tokens.length(), 3)
  assert_eq(tokens[0].term, "全文")
  assert_eq(tokens[1].term, "文搜")
  assert_eq(tokens[2].term, "搜索")
  assert_eq(tokens[2].position, 2)
}

///|
test "single cjk char emits unigram" {
  let tokens = tokenize("猫")
  assert_eq(tokens.length(), 1)
  assert_eq(tokens[0].term, "猫")
}

///|
test "mixed chinese english" {
  let tokens = tokenize("MoonBit 搜索引擎 rocks")
  let terms : Array[String] = []
  for t in tokens {
    terms.push(t.term)
  }
  assert_eq(terms, ["moonbit", "搜索", "索引", "引擎", "rocks"])
}

///|
test "punctuation splits words" {
  let tokens = tokenize("hello,world;foo-bar")
  let terms : Array[String] = []
  for t in tokens {
    terms.push(t.term)
  }
  assert_eq(terms, ["hello", "world", "foo", "bar"])
}

///|
test "positions are contiguous across scripts" {
  let tokens = tokenize("hello 世界 world")
  assert_eq(tokens.length(), 3)
  assert_eq(tokens[0], { term: "hello", position: 0, })
  assert_eq(tokens[1], { term: "世界", position: 1, })
  assert_eq(tokens[2], { term: "world", position: 2, })
}

///|
test "analyzer options disable stop words and lowercasing" {
  let analyzer : Analyzer = {
    lowercase: false,
    remove_stop_words: false,
    cjk_bigram: true,
  }
  let tokens = analyzer.analyze("The Fox")
  assert_eq(tokens.length(), 2)
  assert_eq(tokens[0].term, "The")
  assert_eq(tokens[1].term, "Fox")
}

///|
test "empty and whitespace-only input" {
  assert_eq(tokenize("").length(), 0)
  assert_eq(tokenize("   \t\n  ").length(), 0)
  assert_eq(tokenize("，。！").length(), 0)
}
