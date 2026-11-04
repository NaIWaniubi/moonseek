///|
/// A parsed query node.
pub(all) enum Query {
  /// Match a single analyzed term in a field (None = all fields).
  Term(String, String?)
  /// Match an exact phrase (consecutive analyzed terms).
  Phrase(Array[String], String?)
  /// Match any term starting with the prefix.
  Prefix(String, String?)
  And(Query, Query)
  Or(Query, Query)
  /// Left AND NOT right.
  Not(Query, Query)
  /// Matches every live document.
  MatchAll
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
      tokens.push(PhraseText(String::from_array(buf[:])))
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
      Phrase(terms, None)
    }
    Some(Word(word)) => {
      self.pos += 1
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
    return MatchAll
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
      Phrase(terms.map(fn(t) { t.term }), field)
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
/// Evaluate a query into a map of internal doc number -> score.
fn Index::eval(self : Index, query : Query) -> @hashmap.HashMap[Int32, Double] {
  match query {
    MatchAll => {
      let result : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
      for num in 0..<self.doc_ids.length() {
        if !self.deleted.contains(num) {
          result.set(num, 1.0)
        }
      }
      result
    }
    Term(term, field) => self.eval_term(term, field)
    Phrase(terms, field) => self.eval_phrase(terms, field)
    Prefix(prefix, field) => self.eval_prefix(prefix, field)
    And(left, right) => {
      let l = self.eval(left)
      let r = self.eval(right)
      let result : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
      for (doc, score) in l.iter() {
        match r.get(doc) {
          Some(rs) => result.set(doc, score + rs)
          None => ()
        }
      }
      result
    }
    Or(left, right) => {
      let result = self.eval(left)
      for (doc, score) in self.eval(right).iter() {
        result.set(doc, result.get_or_default(doc, 0.0) + score)
      }
      result
    }
    Not(left, right) => {
      let result = self.eval(left)
      for (doc, _) in self.eval(right).iter() {
        result.remove(doc)
      }
      result
    }
  }
}

///|
fn Index::field_names(self : Index) -> Array[String] {
  self.schema.map(fn(f) { f.name })
}

///|
fn Index::eval_term(
  self : Index,
  term : String,
  field : String?,
) -> @hashmap.HashMap[Int32, Double] {
  let result : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  for f in fields {
    for posting in self.postings_of(f, term) {
      if !self.deleted.contains(posting.doc) {
        let score = self.bm25_score(f, term, posting)
        result.set(posting.doc, result.get_or_default(posting.doc, 0.0) + score)
      }
    }
  }
  result
}

///|
fn Index::eval_prefix(
  self : Index,
  prefix : String,
  field : String?,
) -> @hashmap.HashMap[Int32, Double] {
  let result : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  for f in fields {
    for term in self.terms_of(f) {
      if term.has_prefix(prefix) {
        for (doc, score) in self.eval_term(term, Some(f)).iter() {
          result.set(doc, result.get_or_default(doc, 0.0) + score)
        }
      }
    }
  }
  result
}

///|
fn Index::eval_phrase(
  self : Index,
  terms : Array[String],
  field : String?,
) -> @hashmap.HashMap[Int32, Double] {
  let result : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
  if terms.is_empty() {
    return result
  }
  if terms.length() == 1 {
    return self.eval_term(terms[0], field)
  }
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  for f in fields {
    // Candidate docs: intersection of all term posting lists.
    let first = self.postings_of(f, terms[0])
    for posting in first {
      if self.deleted.contains(posting.doc) {
        continue
      }
      let mut phrase_count = 0
      for start_pos in posting.positions {
        let mut matched = true
        for k in 1..<terms.length() {
          let next = self.postings_of(f, terms[k])
          let mut found = false
          for p in next {
            if p.doc == posting.doc {
              if p.positions.contains(start_pos + k) {
                found = true
              }
              break
            }
          }
          if !found {
            matched = false
            break
          }
        }
        if matched {
          phrase_count += 1
        }
      }
      if phrase_count > 0 {
        // Score the phrase as if it were a term with the phrase frequency.
        let pseudo : Posting = {
          doc: posting.doc,
          freq: phrase_count,
          positions: [],
        }
        let score = self.bm25_score(f, terms[0], pseudo)
        result.set(posting.doc, result.get_or_default(posting.doc, 0.0) + score)
      }
    }
  }
  result
}

///|
/// Search the index. `limit` caps the number of hits (0 = unlimited).
/// Results are sorted by descending score, ties broken by document id.
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
  let scored = self.eval(parsed)
  let hits : Array[Hit] = []
  for (doc, score) in scored.iter() {
    hits.push({ id: self.doc_ids[doc], score, })
  }
  hits.sort_by(fn(a, b) {
    let cmp = b.score.compare(a.score)
    if cmp == 0 {
      a.id.compare(b.id)
    } else {
      cmp
    }
  })
  if limit > 0 && hits.length() > limit {
    hits[:limit].to_owned()
  } else {
    hits
  }
}
