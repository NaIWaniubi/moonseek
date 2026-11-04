///|
/// A whitespace-delimited span of the raw query, with codepoint offsets into
/// the original string so a correction can be spliced in without disturbing
/// the surrounding text.
priv struct SuggestSpan {
  start : Int32
  end : Int32
  text : String
}

///|
/// Split a query into whitespace-delimited spans. Quoted regions are kept
/// intact as a single span so phrase content is never corrected.
fn suggest_spans(input : String) -> Array[SuggestSpan] {
  let chars = input.to_array()
  let spans : Array[SuggestSpan] = []
  let mut i = 0
  while i < chars.length() {
    if chars[i].is_whitespace() {
      i += 1
      continue
    }
    let start = i
    if chars[i] == '"' {
      // Consume through the closing quote (or end of input if unterminated).
      i += 1
      while i < chars.length() && chars[i] != '"' {
        i += 1
      }
      if i < chars.length() {
        i += 1
      }
    } else {
      while i < chars.length() && !chars[i].is_whitespace() {
        i += 1
      }
    }
    spans.push({ start, end: i, text: String::from_array(chars[start:i]), })
  }
  spans
}

///|
/// Total document frequency of a term across all fields, used to prefer
/// common words as correction candidates.
fn Index::suggest_freq(self : Index, term : String) -> Int32 {
  let mut total = 0
  for field in self.field_names() {
    total += self.doc_freq(field, term)
  }
  total
}

///|
/// Pick the best correction for an analyzed term: smallest edit distance
/// first, then highest document frequency (common words are more likely the
/// user's intent), then lexicographic order for determinism.
fn Index::suggest_best(self : Index, term : String, bound : Int32) -> String? {
  let candidates = self.fuzzy_terms(term, max_distance=bound)
  let mut best : FuzzyMatch? = None
  let mut best_freq = -1
  for m in candidates {
    // Exact matches (distance 0) are not corrections.
    if m.distance == 0 {
      continue
    }
    let freq = self.suggest_freq(m.term)
    let better = match best {
      None => true
      Some(b) =>
        m.distance < b.distance ||
        (
          m.distance == b.distance &&
          (freq > best_freq || (freq == best_freq && m.term < b.term))
        )
    }
    if better {
      best = Some(m)
      best_freq = freq
    }
  }
  best.map(fn(m) { m.term })
}

///|
/// Did-you-mean spelling correction. For each bare word in the query that is
/// absent from the dictionary but has a close match, return the query with
/// the first such word corrected; all other text is preserved verbatim.
/// Field-scoped terms (field:term), quoted phrases, operators (AND/OR/NOT),
/// prefixes (foo*), and parentheses are left untouched. Candidates are ranked
/// by document frequency so common words win over rare ones. Returns None
/// when nothing is correctable. `max_distance` is clamped to [0, 2].
pub fn Index::suggest(
  self : Index,
  query : String,
  max_distance~ : Int32 = 2,
) -> String? {
  let bound = clamp_max_distance(max_distance)
  if bound == 0 {
    return None
  }
  let chars = query.to_array()
  for span in suggest_spans(query) {
    let text = span.text
    // Skip quoted phrases, field-scoped terms, operators, prefixes, and
    // parenthesized groups — only bare words are eligible for correction.
    if text.has_prefix("\"") ||
      text.find(":") is Some(_) ||
      text.has_suffix("*") ||
      text.find("(") is Some(_) ||
      text.find(")") is Some(_) ||
      text == "AND" ||
      text == "OR" ||
      text == "NOT" {
      continue
    }
    let tokens = self.analyzer.analyze(text)
    // Only correct spans that analyze to exactly one term; multi-token
    // spans (e.g. CJK runs) are left as-is.
    if tokens.length() != 1 {
      continue
    }
    let term = tokens[0].term
    // Already a dictionary word: nothing to correct.
    if self.suggest_freq(term) > 0 {
      continue
    }
    match self.suggest_best(term, bound) {
      Some(replacement) => {
        let prefix = String::from_array(chars[:span.start])
        let suffix = String::from_array(chars[span.end:])
        return Some(prefix + replacement + suffix)
      }
      None => continue
    }
  }
  None
}
