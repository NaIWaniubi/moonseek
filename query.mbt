///|
/// A parsed query node.
pub(all) enum Query {
  /// Match a single analyzed term in a field (None = all fields).
  Term(String, String?)
  /// Match a phrase (analyzed terms). The Int32 is the maximum allowed gap
  /// between neighbouring terms: 0 means the terms must be consecutive and in
  /// order (an exact phrase), N > 0 allows up to N extra tokens between any
  /// two of them (a "loose phrase", Lucene's slop). Length is fixed at parse
  /// time so the evaluator never re-parses.
  Phrase(Array[String], String?, Int32)
  /// Match any term starting with the prefix.
  Prefix(String, String?)
  And(Query, Query)
  Or(Query, Query)
  /// Left AND NOT right.
  Not(Query, Query)
  /// Matches every live document.
  MatchAll
  /// Matches every live document that has content in `field`. Produced by
  /// `field:*`; unlike MatchAll it never leaks documents lacking the field.
  MatchField(String)
} derive(Eq, Debug)

///|
pub extend Query with Eq::{equal, not_equal}

///|
pub extend Query with @debug.Debug::{to_repr}

///|
/// Query syntax errors.
pub(all) suberror QueryError {
  EmptyQuery
  UnterminatedPhrase
  UnexpectedToken(String)
  UnknownField(String)
} derive(Eq, Debug)

///|
pub extend QueryError with Eq::{equal, not_equal}

///|
pub extend QueryError with @debug.Debug::{to_repr}

///|
pub extend QueryError with Show::{to_string, output}

///|
pub impl Show for QueryError with fn output(self : QueryError, logger) {
  match self {
    EmptyQuery => logger.write_string("empty query")
    UnterminatedPhrase => logger.write_string("unterminated phrase")
    UnexpectedToken(msg) => logger.write_string("unexpected token: " + msg)
    UnknownField(name) => logger.write_string("unknown field: " + name)
  }
}

///|
/// One search hit.
pub(all) struct Hit {
  id : String
  score : Double
} derive(Eq, Debug)

///|
pub extend Hit with Eq::{equal, not_equal}

///|
pub extend Hit with @debug.Debug::{to_repr}

///|
/// Tokenize a query string into raw pieces: words, quoted phrases,
/// operators (AND OR NOT), parentheses, and field prefixes.
enum QToken {
  Word(String)
  PhraseText(String)
  /// A quoted phrase followed by `~N`: (text, slop).
  PhraseSlop(String, Int32)
  LParen
  RParen
  AndOp
  OrOp
  NotOp
} derive(Eq, Debug)

///|
pub extend QToken with Eq::{equal, not_equal}

///|
pub extend QToken with @debug.Debug::{to_repr}

///|
fn lex_query(input : String) -> Array[QToken] raise QueryError {
  let tokens : Array[QToken] = []
  let chars = input.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c.is_whitespace() {
      i += 1
    } else if c == '(' {
      tokens.push(LParen)
      i += 1
    } else if c == ')' {
      tokens.push(RParen)
      i += 1
    } else if c == '"' {
      i += 1
      let buf : Array[Char] = []
      let mut closed = false
      while i < chars.length() {
        if chars[i] == '"' {
          closed = true
          i += 1
          break
        }
        buf.push(chars[i])
        i += 1
      }
      if !closed {
        raise QueryError::UnterminatedPhrase
      }
      let phrase_text = String::from_array(buf[:])
      // `"a b"~2` — the slop suffix belongs to the phrase, so consume it here
      // rather than leaving a stray Word("~2") for the parser to choke on.
      let mut slop = 0
      if i < chars.length() && chars[i] == '~' {
        let mut j = i + 1
        let digits : Array[Char] = []
        while j < chars.length() && chars[j].is_ascii_digit() {
          digits.push(chars[j])
          j += 1
        }
        if !digits.is_empty() {
          slop = @string.parse_int(String::from_array(digits[:])) catch {
            _ => 0
          }
          i = j
        }
      }
      if slop > 0 {
        tokens.push(PhraseSlop(phrase_text, slop))
      } else {
        tokens.push(PhraseText(phrase_text))
      }
    } else {
      let buf : Array[Char] = []
      while i < chars.length() &&
            !chars[i].is_whitespace() &&
            chars[i] != '(' &&
            chars[i] != ')' &&
            chars[i] != '"' {
        buf.push(chars[i])
        i += 1
      }
      let word = String::from_array(buf[:])
      match word {
        "AND" => tokens.push(AndOp)
        "OR" => tokens.push(OrOp)
        "NOT" => tokens.push(NotOp)
        _ => tokens.push(Word(word))
      }
    }
  }
  tokens
}

///|
/// Recursive-descent parser.
/// Grammar: or_expr := and_expr (OR and_expr)*
///          and_expr := not_expr ((AND)? not_expr)*   (implicit AND)
///          not_expr := primary (NOT primary)*
///          primary := '(' or_expr ')' | phrase | term
priv struct Parser {
  tokens : Array[QToken]
  mut pos : Int32
  analyzer : Analyzer
  fields : Array[String]
}

///|
fn Parser::peek(self : Parser) -> QToken? {
  self.tokens.get(self.pos)
}

///|
fn Parser::parse_or(self : Parser) -> Query raise QueryError {
  let mut left = self.parse_and()
  while self.peek() is Some(OrOp) {
    self.pos += 1
    let right = self.parse_and()
    left = Or(left, right)
  }
  left
}

///|
fn Parser::parse_and(self : Parser) -> Query raise QueryError {
  let mut left = self.parse_not()
  while true {
    match self.peek() {
      Some(AndOp) => {
        self.pos += 1
        let right = self.parse_not()
        left = And(left, right)
      }
      Some(Word(_)) | Some(PhraseText(_)) | Some(LParen) | Some(NotOp) => {
        let right = self.parse_not()
        left = And(left, right)
      }
      _ => break
    }
  }
  left
}

///|
fn Parser::parse_not(self : Parser) -> Query raise QueryError {
  let mut left = self.parse_primary()
  while self.peek() is Some(NotOp) {
    self.pos += 1
    let right = self.parse_primary()
    left = Not(left, right)
  }
  left
}

///|
fn Parser::parse_primary(self : Parser) -> Query raise QueryError {
  match self.peek() {
    Some(LParen) => {
      self.pos += 1
      let inner = self.parse_or()
      match self.peek() {
        Some(RParen) => {
          self.pos += 1
          inner
        }
        _ => raise QueryError::UnexpectedToken("expected ')'")
      }
    }
    Some(PhraseText(text)) => {
      self.pos += 1
      let terms = self.analyzer.analyze(text).map(fn(t) { t.term })
      if terms.is_empty() {
        raise QueryError::EmptyQuery
      }
      Phrase(terms, None, 0)
    }
    Some(PhraseSlop(text, slop)) => {
      self.pos += 1
      let terms = self.analyzer.analyze(text).map(fn(t) { t.term })
      if terms.is_empty() {
        raise QueryError::EmptyQuery
      }
      Phrase(terms, None, slop)
    }
    Some(Word(word)) => {
      self.pos += 1
      // field:"phrase": the lexer stops a Word buffer at the quote, so
      // this form arrives as Word("field:") followed by PhraseText. When
      // the word ends with ':' and a phrase follows, fold both tokens
      // into a field-scoped phrase node instead of falling through to
      // parse_word (which would see an empty value and raise).
      if word.has_suffix(":") &&
        (
          self.peek() is Some(PhraseText(_)) ||
          self.peek() is Some(PhraseSlop(_, _))
        ) {
        let text = match self.peek() {
          Some(PhraseText(t)) => t
          Some(PhraseSlop(t, _)) => t
          _ => ""
        }
        let slop = match self.peek() {
          Some(PhraseSlop(_, s)) => s
          _ => 0
        }
        let f = word[:word.length() - 1].to_owned()
        if !self.fields.contains(f) {
          raise QueryError::UnknownField(f)
        }
        self.pos += 1
        let terms = self.analyzer.analyze(text).map(fn(t) { t.term })
        if terms.is_empty() {
          raise QueryError::EmptyQuery
        }
        return Phrase(terms, Some(f), slop)
      }
      self.parse_word(word)
    }
    Some(NotOp) => {
      // Leading NOT: MatchAll NOT x
      self.pos += 1
      let right = self.parse_primary()
      Not(MatchAll, right)
    }
    _ => raise QueryError::UnexpectedToken("expected term")
  }
}

///|
fn Parser::parse_word(self : Parser, word : String) -> Query raise QueryError {
  // field:value or field:"phrase" — the phrase case arrives as Word("field:")
  // followed by PhraseText; handle the plain field:term and field:* forms here.
  let (field, value) = match word.find(":") {
    Some(idx) => {
      let f = word[:idx].to_owned()
      let v = word[idx + 1:].to_owned()
      if !self.fields.contains(f) {
        raise QueryError::UnknownField(f)
      }
      (Some(f), v)
    }
    None => (None, word)
  }
  if value == "*" {
    return match field {
      Some(f) => MatchField(f)
      None => MatchAll
    }
  }
  if value.has_suffix("*") {
    let prefix = value[:value.length() - 1].to_owned()
    let analyzed = self.analyzer.analyze(prefix)
    let normalized = if analyzed.is_empty() { prefix } else { analyzed[0].term }
    return Prefix(normalized, field)
  }
  let terms = self.analyzer.analyze(value)
  match terms.length() {
    0 => raise QueryError::EmptyQuery
    1 => Term(terms[0].term, field)
    _ =>
      // A bare word that analyzes to multiple tokens (e.g. CJK) is a phrase.
      Phrase(terms.map(fn(t) { t.term }), field, 0)
  }
}

///|
/// Parse a query string against the index's schema.
pub fn parse_query(
  input : String,
  analyzer~ : Analyzer = Analyzer::default(),
  fields~ : Array[String] = [],
) -> Query raise QueryError {
  let tokens = lex_query(input)
  if tokens.is_empty() {
    raise QueryError::EmptyQuery
  }
  let parser : Parser = { tokens, pos: 0, analyzer, fields, }
  let query = parser.parse_or()
  if parser.pos != tokens.length() {
    raise QueryError::UnexpectedToken("trailing tokens")
  }
  query
}

///|
/// The (field, term) pairs a query would score, for a cluster coordinator that
/// has to gather corpus-wide `df` before scoring.
///
/// Shape mirrors the evaluator: a bare term expands to one pair per declared
/// field, `field:term` to one, and a phrase to its first term, because that is
/// the term the evaluator scores it as. Prefix queries return None: their term
/// set is whatever the local dictionary happens to contain, so two shards would
/// gather statistics for different terms and neither result would be right.
/// Callers that need global statistics must reject or rewrite prefix queries
/// rather than silently produce a mixed ranking.
pub fn scoring_terms(index : Index, query : Query) -> Array[(String, String)]? {
  let out : Array[(String, String)] = []
  match collect_scoring_terms(index, query, out) {
    true => Some(out)
    false => None
  }
}

///|
fn collect_scoring_terms(
  index : Index,
  node : Query,
  out : Array[(String, String)],
) -> Bool {
  match node {
    Term(term, field) => {
      match field {
        Some(f) => out.push((f, term))
        None =>
          for f in index.field_names() {
            out.push((f, term))
          }
      }
      true
    }
    Phrase(terms, field, _) =>
      if terms.is_empty() {
        true
      } else {
        match field {
          Some(f) => out.push((f, terms[0]))
          None =>
            for f in index.field_names() {
              out.push((f, terms[0]))
            }
        }
        true
      }
    Prefix(_, _) => false
    And(left, right) | Or(left, right) =>
      collect_scoring_terms(index, left, out) &&
      collect_scoring_terms(index, right, out)
    Not(left, _) => collect_scoring_terms(index, left, out)
    MatchAll | MatchField(_) => true
  }
}

///|
/// Evaluate a query into ascending (doc, score) arrays.
///
/// Posting lists are doc-sorted, so every operator is a linear merge instead
/// of a per-posting hash probe. Measured on the 20k-doc stress corpus, a
/// saturated term query (`df` ≈ all docs) went from ~13 ms to sub-millisecond
/// once the map materialization was removed from the path.
fn Index::eval_sorted(self : Index, query : Query) -> DocScores {
  match query {
    MatchAll => self.all_live_scores(DocScores::empty(), fn(_) { true })
    MatchField(field) =>
      self.all_live_scores(DocScores::empty(), fn(num) {
        self.has_field_content(num, field)
      })
    Term(term, field) => self.eval_term(term, field)
    Phrase(terms, field, slop) => self.eval_phrase(terms, field, slop)
    Prefix(prefix, field) => self.eval_prefix(prefix, field)
    And(left, right) =>
      DocScores::inter(self.eval_sorted(left), self.eval_sorted(right))
    Or(left, right) =>
      DocScores::union(self.eval_sorted(left), self.eval_sorted(right))
    Not(left, right) => {
      let excluded = self.eval_sorted(right)
      match left {
        // A leading NOT parses as Not(MatchAll, x): a pure selector, so the
        // survivors score 0.0 rather than inheriting MatchAll's constant.
        MatchAll => self.all_live_scores(excluded, fn(_) { true })
        MatchField(field) =>
          self.all_live_scores(excluded, fn(num) {
            self.has_field_content(num, field)
          })
        _ => DocScores::diff(self.eval_sorted(left), excluded)
      }
    }
  }
}

///|
/// Evaluate a query into a map of internal doc number -> score.
/// Convenience view of `eval_sorted` for callers that need random access
/// (explain); the search path uses the sorted form directly.
fn Index::eval(self : Index, query : Query) -> @hashmap.HashMap[Int32, Double] {
  let scored = self.eval_sorted(query)
  let result : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
  for i in 0..<scored.docs.length() {
    result.set(scored.docs[i], scored.scores[i])
  }
  result
}

///|
fn Index::field_names(self : Index) -> Array[String] {
  self.schema.map(fn(f) { f.name })
}

///|
/// True if a live document has analyzed content in `field`. A document may
/// declare the schema but omit the field, so presence is judged from the
/// field's stored lengths, not from doc existence.
fn Index::has_field_content(self : Index, num : Int32, field : String) -> Bool {
  match self.stats.get(field) {
    Some(stats) => stats.lengths.contains(num)
    None => false
  }
}

///|
/// One term in one field (or every field), as ascending (doc, score).
/// With no field restriction the per-field results are merged by doc.
fn Index::eval_term(self : Index, term : String, field : String?) -> DocScores {
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  // When the index has no tombstones, every posting is live: hoisting this
  // out of the loop removes one hash probe per posting.
  let any_deleted = !self.deleted.is_empty()
  if fields.length() == 1 {
    // Fast path: one field, one doc-sorted posting list, no merge needed.
    let f = fields[0]
    let ctx = self.bm25_context(f, term)
    let out = DocScores::empty()
    if ctx.valid {
      for posting in self.postings_of(f, term) {
        if !any_deleted || !self.deleted.contains(posting.doc) {
          out.push(posting.doc, ctx.score(posting))
        }
      }
    }
    return out
  }
  let pairs : Array[(Int32, Double)] = []
  for f in fields {
    let ctx = self.bm25_context(f, term)
    if !ctx.valid {
      continue
    }
    for posting in self.postings_of(f, term) {
      if !any_deleted || !self.deleted.contains(posting.doc) {
        pairs.push((posting.doc, ctx.score(posting)))
      }
    }
  }
  DocScores::from_pairs(pairs)
}

///|
/// The prefix and its field when the query is exactly one prefix node, or None
/// for anything else. Used to decide whether a prefix is really a single-term
/// query in disguise.
fn single_prefix_term(q : Query) -> (String, String?)? {
  match q {
    Prefix(prefix, field) => Some((prefix, field))
    _ => None
  }
}

///|
/// The single dictionary term a prefix expands to, or None when it expands to
/// none or to several. Counted across *distinct* terms: an unscoped prefix
/// matches the same term once per field, and that is still one term.
///
/// Stops at the second distinct term, so a broad prefix (`w49*`, over a
/// thousand terms) costs a couple of dictionary probes rather than a full
/// expansion.
fn Index::single_prefix_match(
  self : Index,
  prefix : String,
  field : String?,
) -> String? {
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  let mut found : String? = None
  for f in fields {
    let terms = self.terms_of(f)
    let mut i = lower_bound(terms, prefix)
    while i < terms.length() && terms[i].has_prefix(prefix) {
      let t = terms[i]
      match found {
        None => found = Some(t)
        Some(prev) => if prev != t { return None }
      }
      i += 1
    }
  }
  found
}

///|
/// Prefix expansion: every dictionary term with this prefix, merged by doc.
///
/// The matching terms' posting lists are each doc-sorted, so this is a k-way
/// merge (k = terms under the prefix, usually a handful) rather than
/// concatenate-then-sort: the output falls out in ascending doc order as the
/// lists are consumed, and no intermediate pair array is allocated for the
/// common single-field case.
fn Index::eval_prefix(
  self : Index,
  prefix : String,
  field : String?,
) -> DocScores {
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  let multi = fields.length() > 1
  let out = DocScores::empty()
  let pairs : Array[(Int32, Double)] = []
  let any_deleted = !self.deleted.is_empty()
  for f in fields {
    // terms_of is sorted: binary-search the first term >= prefix, then walk
    // forward while the prefix still matches. O(log n + matches) instead of
    // O(vocabulary) per prefix query.
    let terms = self.terms_of(f)
    let start = lower_bound(terms, prefix)
    let ctxs : Array[Bm25Context] = []
    let lists : Array[Array[Posting]] = []
    let mut i = start
    while i < terms.length() && terms[i].has_prefix(prefix) {
      let ctx = self.bm25_context(f, terms[i])
      if ctx.valid {
        ctxs.push(ctx)
        lists.push(self.postings_of(f, terms[i]))
      }
      i += 1
    }
    if lists.is_empty() {
      continue
    }
    if lists.length() == 1 {
      let ctx = ctxs[0]
      for posting in lists[0] {
        if !any_deleted || !self.deleted.contains(posting.doc) {
          let score = ctx.score(posting)
          if multi {
            pairs.push((posting.doc, score))
          } else {
            out.push(posting.doc, score)
          }
        }
      }
      continue
    }
    // k-way merge over a min-heap of (doc, list). A linear scan for the
    // smallest cursor would be O(k) per document, which is a regression for a
    // broad prefix: `w49*` covers over a thousand dictionary terms. The heap
    // makes it O(log k) per posting instead.
    let heap = DocHeap::new()
    let curs : Array[Int32] = []
    for j in 0..<lists.length() {
      if lists[j].length() > 0 {
        heap.push(lists[j][0].doc, j)
      }
      // Index of the next posting to push for this list; 0 is already queued.
      curs.push(1)
    }
    while !heap.is_empty() {
      let d = heap.peek_doc()
      let mut total = 0.0
      // Every list sitting on this document contributes, then advances.
      while !heap.is_empty() && heap.peek_doc() == d {
        let j = heap.pop_list()
        let consumed = curs[j] - 1
        total += ctxs[j].score(lists[j][consumed])
        let next = curs[j]
        if next < lists[j].length() {
          heap.push(lists[j][next].doc, j)
          curs[j] = next + 1
        }
      }
      if any_deleted && self.deleted.contains(d) {
        continue
      }
      if multi {
        pairs.push((d, total))
      } else {
        out.push(d, total)
      }
    }
  }
  if multi {
    DocScores::from_pairs(pairs)
  } else {
    out
  }
}

///|
/// Index of the first element in the lexicographically sorted array that
/// is >= target. Uses `lexical_compare` to match `terms_of`'s ordering
/// (String::compare is shortlex and would break the binary search).
fn lower_bound(terms : Array[String], target : String) -> Int32 {
  let mut lo = 0
  let mut hi = terms.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if terms[mid].lexical_compare(target) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
/// Phrase match: consecutive analyzed terms in one field.
///
/// The rarest term's doc-sorted list drives the walk — only its documents can
/// match — and the other terms are probed with forward-only cursors instead of
/// being enumerated. That is what keeps the cost proportional to the phrase's
/// candidates rather than to the sum of the terms' document frequencies: an
/// earlier version built a `doc -> Posting` map for *every* term on every
/// query, which on a saturated term meant thousands of hash inserts before the
/// first position was compared.
fn Index::eval_phrase(
  self : Index,
  terms : Array[String],
  field : String?,
  slop : Int32,
) -> DocScores {
  let out = DocScores::empty()
  if terms.is_empty() {
    return out
  }
  if terms.length() == 1 {
    return self.eval_term(terms[0], field)
  }
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  // Docs matching the phrase in several fields accumulate their scores, so
  // collect pairs when more than one field is searched.
  let multi = fields.length() > 1
  let any_deleted = !self.deleted.is_empty()
  let pairs : Array[(Int32, Double)] = []
  for f in fields {
    let lists : Array[Array[Posting]] = []
    let mut missing = false
    for term in terms {
      let postings = self.postings_of(f, term)
      if postings.is_empty() {
        missing = true
        break
      }
      lists.push(postings)
    }
    if missing {
      continue
    }
    let ctx = self.bm25_context(f, terms[0])
    if !ctx.valid {
      continue
    }
    let mut driver = 0
    for i in 1..<lists.length() {
      if lists[i].length() < lists[driver].length() {
        driver = i
      }
    }
    let curs : Array[Int32] = []
    for _ in 0..<lists.length() {
      curs.push(0)
    }
    // `aligned[k]` is term k's posting for the document currently under the
    // walk, so the position checks index an array instead of hashing a doc.
    let aligned : Array[Posting] = lists.map(fn(l) { l[0] })
    for driver_posting in lists[driver] {
      let d = driver_posting.doc
      if any_deleted && self.deleted.contains(d) {
        continue
      }
      let mut present = true
      for i in 0..<lists.length() {
        if i == driver {
          aligned[i] = driver_posting
          continue
        }
        let list = lists[i]
        let mut j = curs[i]
        while j < list.length() && list[j].doc < d {
          j += 1
        }
        curs[i] = j
        if j >= list.length() || list[j].doc != d {
          present = false
          break
        }
        aligned[i] = list[j]
      }
      if !present {
        continue
      }
      let phrase_count = if slop == 0 {
        exact_phrase_count(driver_posting, aligned, terms.length())
      } else {
        sloppy_phrase_count(aligned, terms.length(), slop)
      }
      if phrase_count > 0 {
        // Score the phrase as if it were a term with the phrase frequency.
        let pseudo : Posting = { doc: d, freq: phrase_count, positions: [], }
        let score = ctx.score(pseudo)
        if multi {
          pairs.push((d, score))
        } else {
          out.push(d, score)
        }
      }
    }
  }
  if multi {
    DocScores::from_pairs(pairs)
  } else {
    out
  }
}

///|
/// Exact phrase count for one document. `aligned[k]` is term k's posting for
/// that document, so each later term is probed directly. For every start
/// position of the first term, every later term must sit exactly k positions
/// further on.
fn exact_phrase_count(
  first : Posting,
  aligned : Array[Posting],
  n_terms : Int32,
) -> Int32 {
  let mut count = 0
  for start_pos in first.positions {
    let mut matched = true
    for k in 1..<n_terms {
      if !aligned[k].positions.contains(start_pos + k) {
        matched = false
        break
      }
    }
    if matched {
      count += 1
    }
  }
  count
}

///|
/// Sloppy phrase count with a minimum-span walk.
///
/// A naive "for each position of term 0, look for term 1 anywhere within
/// slop" over-counts wildly: one occurrence of the phrase would be reported
/// once per starting position that can reach it, inflating tf and therefore
/// the BM25 score. Instead this walks the sorted position lists in lockstep
/// and only counts a match when the *minimal* window containing all terms in
/// order fits inside the allowed span.
///
/// The allowed span for n terms at slop s is (n - 1) + s: with s = 0 that is
/// exactly consecutive positions, so this is a strict generalization of the
/// exact case. Each term's pointer only moves forward, so per document the
/// walk is linear in total occurrences.
fn sloppy_phrase_count(
  aligned : Array[Posting],
  n_terms : Int32,
  slop : Int32,
) -> Int32 {
  // positions[k][i] are the sorted positions of term k in this document.
  let positions : Array[Array[Int32]] = []
  for k in 0..<n_terms {
    positions.push(aligned[k].positions)
  }
  // Single pass over the first term's positions with a "next position >= x"
  // binary search per later term: for each candidate start this finds the
  // tightest end, which is exactly the minimal window.
  let mut count = 0
  let mut prev_end = -0x7FFFFFFF
  for start in positions[0] {
    let mut end = start
    let mut ok = true
    for k in 1..<n_terms {
      // The k-th term must be strictly after the (k-1)-th and within slop of
      // it, so the window can never be satisfied by re-using an earlier token.
      let lo = end + 1
      match first_at_or_after(positions[k], lo) {
        Some(pos) => {
          if pos - end - 1 > slop {
            ok = false
            break
          }
          end = pos
        }
        None => {
          ok = false
          break
        }
      }
    }
    if ok {
      // A sliding window already counted this occurrence from an earlier
      // start that ended at the same place; do not score it twice.
      if end != prev_end {
        count += 1
        prev_end = end
      }
    }
  }
  count
}

///|
/// Index of the first position >= target in an ascending array, or None.
fn first_at_or_after(positions : Array[Int32], target : Int32) -> Int32? {
  let mut lo = 0
  let mut hi = positions.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if positions[mid] < target {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo < positions.length() {
    Some(positions[lo])
  } else {
    None
  }
}

///|
/// Count the phrase occurrences of a multi-term phrase in one field of one
/// document. This is the same count `eval_phrase` scores with, exposed so
/// `explain` can reproduce the phrase frequency in its details.
fn Index::phrase_count(
  self : Index,
  terms : Array[String],
  field : String,
  num : Int32,
  slop : Int32,
) -> Int32 {
  if terms.length() < 2 {
    return 0
  }
  // `explain` asks about one document, so binary-search it in each doc-sorted
  // list instead of materializing a `doc -> Posting` map per term.
  let aligned : Array[Posting] = []
  for term in terms {
    match posting_at(self.postings_of(field, term), num) {
      Some(p) => aligned.push(p)
      None => return 0
    }
  }
  if slop == 0 {
    exact_phrase_count(aligned[0], aligned, terms.length())
  } else {
    sloppy_phrase_count(aligned, terms.length(), slop)
  }
}

///|
/// The posting for `doc` in a doc-sorted list, by binary search.
fn posting_at(list : Array[Posting], doc : Int32) -> Posting? {
  let mut lo = 0
  let mut hi = list.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if list[mid].doc < doc {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo < list.length() && list[lo].doc == doc {
    Some(list[lo])
  } else {
    None
  }
}

///|
/// Flatten a conjunction of plain terms into query order, or None when the query
/// is anything else (a phrase, a prefix, a disjunction, a negation). The
/// block-max conjunction path only accepts the shape it can evaluate exactly.
fn flatten_and_terms(q : Query) -> Array[(String, String?)]? {
  match q {
    Term(term, field) => Some([(term, field)])
    And(left, right) =>
      match (flatten_and_terms(left), flatten_and_terms(right)) {
        (Some(a), Some(b)) => {
          let out : Array[(String, String?)] = []
          for x in a {
            out.push(x)
          }
          for x in b {
            out.push(x)
          }
          Some(out)
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Flatten a disjunction of plain terms into query order, or None when the query
/// is anything else. The block-max disjunction path only accepts the shape it can
/// evaluate exactly.
fn flatten_or_terms(q : Query) -> Array[(String, String?)]? {
  match q {
    Term(term, field) => Some([(term, field)])
    Or(left, right) =>
      match (flatten_or_terms(left), flatten_or_terms(right)) {
        (Some(a), Some(b)) => {
          let out : Array[(String, String?)] = []
          for x in a {
            out.push(x)
          }
          for x in b {
            out.push(x)
          }
          Some(out)
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Search the index. `limit` caps the number of hits (0 = unlimited).
/// Results are sorted by descending score, ties broken by document id.
///
/// Evaluation produces ascending (doc, score) arrays and selection is a
/// bounded top-K walk over them, so a query never materializes a
/// `doc -> score` map and only the hits that enter the top set are turned
/// into `Hit` values.
pub fn Index::search(
  self : Index,
  query : String,
  limit~ : Int32 = 10,
) -> Array[Hit] raise QueryError {
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  // A bounded query that is a single term, a conjunction of them, or a
  // disjunction whose operands are far apart in document frequency, is where the
  // top-k can be found without scoring every matching document: block-max WAND
  // skips whole doc blocks whose highest possible score cannot reach the current
  // k-th best, a conjunction walks the shortest term's postings instead of
  // enumerating the saturated ones, and a disjunction walks the union when the
  // skipping has something to bite on (`or_walk_pays`). The result is identical
  // to the exact path (see `term_topk_blockmax` / `and_terms_topk` /
  // `or_terms_topk`); every other query shape falls through to it.
  if limit > 0 {
    match flatten_and_terms(parsed) {
      Some(terms) =>
        if terms.length() == 1 {
          return self.term_topk_blockmax(terms[0].1, terms[0].0, limit).hits
        } else if terms.length() >= 2 {
          return self.and_terms_topk(terms, limit).hits
        }
      None =>
        // Not a conjunction: a disjunction of plain terms whose operands span a
        // wide range of document frequencies gets the union walk; a union of
        // comparably dense (or comparably sparse) terms is left to the merge,
        // which the benchmark shows is faster there.
        match flatten_or_terms(parsed) {
          Some(or_terms) =>
            if or_terms.length() >= 2 && self.or_walk_pays(or_terms) {
              return self.or_terms_topk(or_terms, limit).hits
            }
          None =>
            // A prefix that expands to exactly one dictionary term *is* a
            // single-term query, so it gets the same block-max treatment
            // (`seg*` -> `segment`). A prefix matching several terms is a union
            // and stays on the evaluator, which merges their sorted lists.
            match single_prefix_term(parsed) {
              Some((prefix, field)) =>
                match self.single_prefix_match(prefix, field) {
                  Some(only) =>
                    return self.term_topk_blockmax(field, only, limit).hits
                  None => ()
                }
              None => ()
            }
        }
    }
  }
  let scored = self.eval_sorted(parsed)
  self.collect_hits(scored, limit)
}

///|
/// The unbounded evaluation of `search`, without the block-max top-k shortcut.
/// `search` returns the same hits; this exists so a caller can force the
/// full-scan path — the benchmark compares the two, and the tests check that
/// the shortcut is indistinguishable from it.
pub fn Index::search_exact(
  self : Index,
  query : String,
  limit~ : Int32 = 10,
) -> Array[Hit] raise QueryError {
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let scored = self.eval_sorted(parsed)
  self.collect_hits(scored, limit)
}

///|
/// Number of live documents matching a query, without materializing hits.
///
/// `search(query, limit=0)` answers the same question but builds and sorts every
/// `Hit` first. A shard reporting its match count needs the number and nothing
/// else, and paying for the ranking made the cluster's per-query cost an order
/// of magnitude larger than the search itself.
pub fn Index::count(self : Index, query : String) -> Int32 raise QueryError {
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let scored = self.eval_sorted(parsed)
  scored.docs.length()
}

///|
/// A binary min-heap of `(doc, list index)`, used to merge k doc-sorted posting
/// lists. Ordered by document only: two lists holding the same document are
/// both consumed in the same step, so their relative order does not matter.
priv struct DocHeap {
  items : Array[(Int32, Int32)]
}

///|
fn DocHeap::new() -> DocHeap {
  { items: [], }
}

///|
fn DocHeap::is_empty(self : DocHeap) -> Bool {
  self.items.is_empty()
}

///|
/// The smallest document currently queued. Call only on a non-empty heap.
fn DocHeap::peek_doc(self : DocHeap) -> Int32 {
  self.items[0].0
}

///|
fn DocHeap::push(self : DocHeap, doc : Int32, list : Int32) -> Unit {
  self.items.push((doc, list))
  let mut i = self.items.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if self.items[parent].0 <= self.items[i].0 {
      break
    }
    let tmp = self.items[parent]
    self.items[parent] = self.items[i]
    self.items[i] = tmp
    i = parent
  }
}

///|
/// Remove the smallest entry and return its list index. Call only on a
/// non-empty heap.
fn DocHeap::pop_list(self : DocHeap) -> Int32 {
  let top = self.items[0]
  let last = self.items.pop()
  if self.items.is_empty() {
    return top.1
  }
  match last {
    Some(entry) => {
      self.items[0] = entry
      let n = self.items.length()
      let mut i = 0
      while true {
        let left = 2 * i + 1
        let right = left + 1
        let mut smallest = i
        if left < n && self.items[left].0 < self.items[smallest].0 {
          smallest = left
        }
        if right < n && self.items[right].0 < self.items[smallest].0 {
          smallest = right
        }
        if smallest == i {
          break
        }
        let tmp = self.items[i]
        self.items[i] = self.items[smallest]
        self.items[smallest] = tmp
        i = smallest
      }
    }
    None => ()
  }
  top.1
}
