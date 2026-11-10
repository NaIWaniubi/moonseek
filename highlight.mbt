///|
/// A half-open character range [start, end) in a stored field's original text.
/// Offsets count Unicode codepoints: neither bytes nor UTF-16 code units.
pub struct HighlightSpan {
  start : Int32
  end : Int32
} derive(Eq, Debug)

///|
pub extend HighlightSpan with Eq::{equal, not_equal}

///|
pub extend HighlightSpan with @debug.Debug::{to_repr}

///|
/// One query leaf that drives highlighting, keeping phrase adjacency and
/// prefix expansion semantics (which a flat term list would lose).
priv enum HighlightNode {
  HTerm(String)
  HPhrase(Array[String])
  HPrefix(String)
}

///|
/// Walk the positive side of a query AST into highlight leaves. The right
/// branch of Not and MatchAll contribute nothing: only positive matches
/// are highlighted.
fn collect_highlight_nodes(query : Query) -> Array[HighlightNode] {
  let out : Array[HighlightNode] = []
  fn walk(node : Query) -> Unit {
    match node {
      Term(term, _) => out.push(HTerm(term))
      Phrase(terms, _) => out.push(HPhrase(terms))
      Prefix(prefix, _) => out.push(HPrefix(prefix))
      And(left, right) | Or(left, right) => {
        walk(left)
        walk(right)
      }
      Not(left, _) => walk(left)
      MatchAll | MatchField(_) => ()
    }
  }
  walk(query)
  out
}

///|
/// Collect the highlightable terms of a query AST: every Term and Phrase
/// word, plus the prefix itself for Prefix nodes. The right branch of Not
/// and MatchAll contribute nothing (only positive matches are highlighted).
/// Results are deduplicated in first-occurrence order.
pub fn query_terms(query : Query) -> Array[String] {
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  let out : Array[String] = []
  for node in collect_highlight_nodes(query) {
    let terms = match node {
      HTerm(term) => [term]
      HPhrase(terms) => terms
      HPrefix(prefix) => [prefix]
    }
    for term in terms {
      if !seen.contains(term) {
        seen.set(term, ())
        out.push(term)
      }
    }
  }
  out
}

///|
/// An analyzed token together with its half-open codepoint range in the
/// original text. The public analyzer only records stream positions, so
/// highlighting re-scans the source with this offset-aware variant.
priv struct OffsetToken {
  term : String
  start : Int32
  end : Int32
}

///|
/// Mirror of Analyzer::analyze that also records source offsets. It reuses
/// the exact char predicates, normalization and stop-word list of token.mbt
/// so the emitted terms are identical to the indexed ones; only the span
/// bookkeeping is added. Offsets index the codepoint array of the text.
fn analyze_with_offsets(
  analyzer : Analyzer,
  text : String,
) -> Array[OffsetToken] {
  let tokens : Array[OffsetToken] = []
  let chars = text.to_array()
  let stop : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  if analyzer.remove_stop_words {
    for w in default_stop_words {
      stop.set(w, ())
    }
  }
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if is_cjk(c) {
      let start = i
      while i < chars.length() && is_cjk(chars[i]) {
        i += 1
      }
      let run_len = i - start
      if run_len == 1 {
        tokens.push({ term: chars[start].to_string(), start, end: start + 1, })
      } else if analyzer.cjk_bigram {
        let mut j = start
        while j + 1 < i {
          tokens.push({
            term: chars[j].to_string() + chars[j + 1].to_string(),
            start: j,
            end: j + 2,
          })
          j += 1
        }
      } else {
        let mut j = start
        while j < i {
          tokens.push({ term: chars[j].to_string(), start: j, end: j + 1, })
          j += 1
        }
      }
    } else if is_word_char(c) {
      let start = i
      let buf : Array[Char] = []
      while i < chars.length() && is_word_char(chars[i]) {
        buf.push(normalize_char(chars[i], analyzer.lowercase))
        i += 1
      }
      let term = String::from_array(buf[:])
      if term.length() > 0 &&
        !(analyzer.remove_stop_words && stop.contains(term)) {
        tokens.push({ term, start, end: i, })
      }
    } else {
      i += 1
    }
  }
  tokens
}

///|
/// Sort spans by start (ties by end) and merge overlapping ranges.
/// Adjacent-but-disjoint ranges are kept separate: merging is overlap-only,
/// matching the highlight_spans contract.
fn merge_spans(spans : Array[HighlightSpan]) -> Array[HighlightSpan] {
  spans.sort_by(fn(a, b) {
    let cmp = a.start.compare(b.start)
    if cmp == 0 {
      a.end.compare(b.end)
    } else {
      cmp
    }
  })
  let merged : Array[HighlightSpan] = []
  for span in spans {
    if merged.length() > 0 {
      let last = merged[merged.length() - 1]
      if span.start < last.end {
        // Overlap: extend the last merged span in place. HighlightSpan's
        // end field is immutable from outside the package, but merge_spans
        // is the owner of freshly built spans, so rebuild the tail entry.
        if span.end > last.end {
          merged[merged.length() - 1] = { start: last.start, end: span.end, }
        }
        continue
      }
    }
    merged.push({ start: span.start, end: span.end, })
  }
  merged
}

///|
/// Compute highlight spans of `query` over the stored original text of one
/// field. Latin terms match whole analyzed tokens (case handling follows the
/// index analyzer); CJK bigram terms map back to their exact source ranges;
/// phrases highlight the full adjacent run; prefixes highlight every whole
/// token starting with the prefix. Overlapping ranges are merged and the
/// result is sorted by start.
/// Raises UnknownField for an unknown/deleted document or a field the
/// document does not carry; query syntax errors propagate from parse_query.
pub fn Index::highlight_spans(
  self : Index,
  id : String,
  field : String,
  query : String,
) -> Array[HighlightSpan] raise QueryError {
  let text = match self.get_field(id, field) {
    Some(t) => t
    None => raise QueryError::UnknownField(field)
  }
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let nodes = collect_highlight_nodes(parsed)
  let tokens = analyze_with_offsets(self.analyzer, text)
  let spans : Array[HighlightSpan] = []
  for node in nodes {
    match node {
      HTerm(term) =>
        for token in tokens {
          if token.term == term {
            spans.push({ start: token.start, end: token.end, })
          }
        }
      HPrefix(prefix) =>
        for token in tokens {
          if token.term.has_prefix(prefix) {
            spans.push({ start: token.start, end: token.end, })
          }
        }
      HPhrase(terms) => {
        if terms.is_empty() {
          continue
        }
        if terms.length() == 1 {
          for token in tokens {
            if token.term == terms[0] {
              spans.push({ start: token.start, end: token.end, })
            }
          }
          continue
        }
        let mut i = 0
        while i + terms.length() <= tokens.length() {
          let mut matched = true
          for k in 0..<terms.length() {
            if tokens[i + k].term != terms[k] {
              matched = false
              break
            }
          }
          if matched {
            spans.push({
              start: tokens[i].start,
              end: tokens[i + terms.length() - 1].end,
            })
          }
          i += 1
        }
      }
    }
  }
  merge_spans(spans)
}

///|
/// Escape the five XML/HTML special characters of one source character.
fn write_html_char(sb : StringBuilder, c : Char) -> Unit {
  match c {
    '&' => sb.write_string("&amp;")
    '<' => sb.write_string("&lt;")
    '>' => sb.write_string("&gt;")
    '"' => sb.write_string("&quot;")
    '\'' => sb.write_string("&#39;")
    _ => sb.write_char(c)
  }
}

///|
/// Render chars[start..end) with highlight tags around the given merged,
/// sorted spans. Source text is HTML-escaped; tags are emitted verbatim.
/// Spans must lie inside [start, end).
fn render_marked(
  chars : Array[Char],
  start : Int32,
  end : Int32,
  spans : Array[HighlightSpan],
  pre_tag : String,
  post_tag : String,
) -> String {
  let sb = StringBuilder::StringBuilder()
  let mut pos = start
  let mut si = 0
  while pos < end {
    while si < spans.length() && spans[si].end <= pos {
      si += 1
    }
    if si < spans.length() && spans[si].start <= pos {
      let span = spans[si]
      sb.write_string(pre_tag)
      let stop = span.end.min(end)
      while pos < stop {
        write_html_char(sb, chars[pos])
        pos += 1
      }
      sb.write_string(post_tag)
      si += 1
    } else {
      let next = if si < spans.length() {
        spans[si].start.min(end)
      } else {
        end
      }
      while pos < next {
        write_html_char(sb, chars[pos])
        pos += 1
      }
    }
  }
  sb.to_string()
}

///|
/// Return the stored field text with `pre_tag`/`post_tag` around every
/// highlight span. The source text is HTML-escaped (& < > " '); the tags
/// themselves are not escaped. With no matches the escaped original is
/// returned unchanged.
pub fn Index::highlight(
  self : Index,
  id : String,
  field : String,
  query : String,
  pre_tag~ : String = "<mark>",
  post_tag~ : String = "</mark>",
) -> String raise QueryError {
  let text = match self.get_field(id, field) {
    Some(t) => t
    None => raise QueryError::UnknownField(field)
  }
  let spans = self.highlight_spans(id, field, query)
  let chars = text.to_array()
  render_marked(chars, 0, chars.length(), spans, pre_tag, post_tag)
}

///|
/// Count how many of the merged spans overlap [start, end).
fn count_overlapping(
  spans : Array[HighlightSpan],
  start : Int32,
  end : Int32,
) -> Int32 {
  let mut count = 0
  for span in spans {
    if span.start < end && span.end > start {
      count += 1
    }
  }
  count
}

///|
/// Extract a snippet of at most `max_chars` source characters: the window
/// containing the most highlight spans (ties: earliest window), with the
/// same tags and HTML escaping as highlight. Ellipses "…" mark truncation
/// on either side. With no highlights the first `max_chars` characters are
/// returned. `max_chars <= 0` yields an empty string.
pub fn Index::snippet(
  self : Index,
  id : String,
  field : String,
  query : String,
  max_chars~ : Int32 = 150,
  pre_tag~ : String = "<mark>",
  post_tag~ : String = "</mark>",
) -> String raise QueryError {
  let text = match self.get_field(id, field) {
    Some(t) => t
    None => raise QueryError::UnknownField(field)
  }
  let spans = self.highlight_spans(id, field, query)
  let chars = text.to_array()
  let total = chars.length()
  let width = max_chars.min(total)
  if width <= 0 {
    return ""
  }
  let mut best_start = 0
  if !spans.is_empty() && total > width {
    let mut best_score = -1
    let mut s = 0
    while s <= total - width {
      let score = count_overlapping(spans, s, s + width)
      if score > best_score {
        best_score = score
        best_start = s
      }
      s += 1
    }
  }
  let end = best_start + width
  let sb = StringBuilder::StringBuilder()
  if best_start > 0 {
    sb.write_string("…")
  }
  sb.write_string(
    render_marked(chars, best_start, end, spans, pre_tag, post_tag),
  )
  if end < total {
    sb.write_string("…")
  }
  sb.to_string()
}
