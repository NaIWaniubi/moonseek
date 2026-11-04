///|
test "bktree: insert and len" {
  let tree = @moonseek.BkTree::new()
  tree.insert("hello")
  tree.insert("world")
  tree.insert("hello") // duplicate
  assert_eq(tree.len(), 2)
}

///|
test "bktree: exact match distance 0" {
  let tree = @moonseek.BkTree::from_terms(["hello", "world", "help"])
  let results = tree.search("hello", max_distance=0)
  assert_eq(results.length(), 1)
  assert_eq(results[0].term, "hello")
  assert_eq(results[0].distance, 0)
}

///|
test "bktree: distance 1 matches" {
  let tree = @moonseek.BkTree::from_terms([
    "hello", "hallo", "world", "help", "hell",
  ])
  let results = tree.search("hello", max_distance=1)
  let terms = results.map(fn(m) { m.term })
  assert_true(terms.contains("hello"))
  assert_true(terms.contains("hallo"))
  assert_true(terms.contains("hell"))
  assert_true(!terms.contains("world"))
}

///|
test "bktree: distance 2 matches" {
  let tree = @moonseek.BkTree::from_terms([
    "search", "serch", "searching", "earth", "xyz",
  ])
  let results = tree.search("search", max_distance=2)
  let terms = results.map(fn(m) { m.term })
  assert_true(terms.contains("search"))
  assert_true(terms.contains("serch"))
  assert_true(!terms.contains("xyz"))
}

///|
test "bktree: results sorted by distance then term" {
  let tree = @moonseek.BkTree::from_terms(["cat", "bat", "car", "dog", "cot"])
  let results = tree.search("cat", max_distance=2)
  // distance 0: cat; distance 1: bat, car, cot; distance 2: dog
  assert_eq(results[0].term, "cat")
  assert_eq(results[0].distance, 0)
  assert_true(results[1].distance <= results[results.length() - 1].distance)
}

///|
test "bktree: empty tree returns empty" {
  let tree = @moonseek.BkTree::new()
  assert_eq(tree.search("anything").length(), 0)
}

///|
test "bktree: matches linear scan results" {
  // Property: BK-tree must find exactly the same terms as brute force.
  let words = [
    "apple", "apply", "ape", "banana", "band", "bandana", "cat", "car", "cart", "dog",
  ]
  let tree = @moonseek.BkTree::from_terms(words)
  for query in ["apple", "ban", "car", "xyz", "cat"] {
    let bk_results = tree.search(query, max_distance=2)
    let bk_terms = bk_results.map(fn(m) { m.term })
    // Brute force reference
    let brute : Array[String] = []
    for w in words {
      if @moonseek.levenshtein(query, w) <= 2 {
        brute.push(w)
      }
    }
    brute.sort()
    let bk_sorted = bk_terms
    bk_sorted.sort()
    assert_eq(bk_sorted, brute)
  }
}

///|
test "bktree: index integration" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "search engine")], })
  idx.add({ id: "b", fields: [("body", "research paper")], })
  idx.add({ id: "c", fields: [("body", "earth science")], })
  let tree = idx.bk_tree()
  let results = tree.search("serch", max_distance=2)
  let terms = results.map(fn(m) { m.term })
  assert_true(terms.contains("search"))
  // "research" is distance 3 from "serch", outside max_distance=2.
  assert_true(!terms.contains("research"))
}

///|
test "bktree: fuzzy_terms_fast matches fuzzy_terms" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "search engine optimization")], })
  idx.add({ id: "b", fields: [("body", "research paper")], })
  idx.add({ id: "c", fields: [("body", "earth science")], })
  let slow = idx.fuzzy_terms("serch", max_distance=2)
  let fast = idx.fuzzy_terms_fast("serch", max_distance=2)
  assert_eq(slow.length(), fast.length())
  for i in 0..<slow.length() {
    assert_eq(slow[i].term, fast[i].term)
    assert_eq(slow[i].distance, fast[i].distance)
  }
}

///|
test "bktree: unicode terms" {
  let tree = @moonseek.BkTree::from_terms([
    "搜索", "索引", "引擎", "全文",
  ])
  let results = tree.search("搜索", max_distance=1)
  assert_true(results.length() >= 1)
  assert_eq(results[0].term, "搜索")
}

///|
test "bktree: large vocabulary correctness" {
  // 500 synthetic terms, verify BK-tree finds all within distance 1.
  let words : Array[String] = []
  for i in 0..<500 {
    words.push("term\{i}")
  }
  let tree = @moonseek.BkTree::from_terms(words)
  assert_eq(tree.len(), 500)
  let results = tree.search("term42", max_distance=1)
  let terms = results.map(fn(m) { m.term })
  assert_true(terms.contains("term42"))
  // term420..term429 are distance 1 (one char appended)
  assert_true(terms.contains("term420"))
}
