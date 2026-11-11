///|
/// A token emitted by the analyzer: the normalized term plus its position
/// in the token stream (used for phrase queries).
pub(all) struct Token {
  term : String
  position : Int32
} derive(Eq, Debug)

///|
pub extend Token with Eq::{equal, not_equal}

///|
pub extend Token with @debug.Debug::{to_repr}

///|

///|
/// Interned two-character terms. CJK bigrams repeat heavily inside any real
/// corpus, so building the same two-char string on every occurrence is pure
/// allocation churn; this keeps one instance per distinct pair. Capped so a
/// long-running process with diverse text cannot grow it without bound.
let bigram_cache : @hashmap.HashMap[Int32, String] = @hashmap.HashMap([])

///|
const BIGRAM_CACHE_CAP : Int32 = 65536

///|
/// Pack two code units into one key (BMP only; astral chars pass through
/// uninterned below).
fn bigram_key(a : Char, b : Char) -> Int32 {
  ((a.to_int() & 0xFFFF) << 16) | (b.to_int() & 0xFFFF)
}

///|
/// The interned two-character term for a pair, or a fresh string when the
/// pair is outside the BMP or the cache is at its cap.
fn intern_bigram(a : Char, b : Char) -> String {
  if a.to_int() > 0xFFFF || b.to_int() > 0xFFFF {
    return a.to_string() + b.to_string()
  }
  let key = bigram_key(a, b)
  match bigram_cache.get(key) {
    Some(s) => s
    None => {
      let s = a.to_string() + b.to_string()
      if bigram_cache.length() < BIGRAM_CACHE_CAP {
        bigram_cache.set(key, s)
      }
      s
    }
  }
}

///|
/// Default English stop words (Lucene's classic set).
let default_stop_words : Array[String] = [
  "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into",
  "is", "it", "no", "not", "of", "on", "or", "such", "that", "the", "their", "then",
  "there", "these", "they", "this", "to", "was", "will", "with",
]

///|
/// Text analyzer configuration.
pub(all) struct Analyzer {
  /// Lowercase ASCII letters (non-ASCII letters are kept as-is).
  lowercase : Bool
  /// Drop default English stop words.
  remove_stop_words : Bool
  /// Emit overlapping bigrams for CJK runs (Lucene CJKAnalyzer strategy),
  /// so Chinese text is searchable without a dictionary.
  cjk_bigram : Bool
} derive(Eq, Debug)

///|
pub extend Analyzer with Eq::{equal, not_equal}

///|
pub extend Analyzer with @debug.Debug::{to_repr}

///|
pub fn Analyzer::default() -> Analyzer {
  { lowercase: true, remove_stop_words: true, cjk_bigram: true, }
}

///|
/// CJK Unified Ideographs + Extension A + compatibility ideographs,
/// plus kana and hangul syllables. Enough for dictionary-free search.
fn is_cjk(c : Char) -> Bool {
  let n = c.to_int()
  (n >= 0x3400 && n <= 0x4DBF) ||
  (n >= 0x4E00 && n <= 0x9FFF) ||
  (n >= 0xF900 && n <= 0xFAFF) ||
  (n >= 0x3040 && n <= 0x30FF) ||
  (n >= 0xAC00 && n <= 0xD7AF)
}

///|
fn is_word_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() ||
  c.is_ascii_digit() ||
  (c.to_int() >= 0x80 && !c.is_whitespace() && !is_cjk(c) && !is_punct(c))
}

///|
fn is_punct(c : Char) -> Bool {
  let n = c.to_int()
  // ASCII punctuation ranges + common CJK punctuation.
  (n >= 0x21 && n <= 0x2F) ||
  (n >= 0x3A && n <= 0x40) ||
  (n >= 0x5B && n <= 0x60) ||
  (n >= 0x7B && n <= 0x7E) ||
  (n >= 0x3000 && n <= 0x303F) ||
  (n >= 0xFF00 && n <= 0xFF0F) ||
  (n >= 0xFF1A && n <= 0xFF20) ||
  (n >= 0xFF3B && n <= 0xFF40) ||
  (n >= 0xFF5B && n <= 0xFF65)
}

///|
fn normalize_char(c : Char, lowercase : Bool) -> Char {
  if lowercase {
    c.to_ascii_lowercase()
  } else {
    c
  }
}

///|
/// Analyze text into a stream of tokens. Latin words are split on
/// non-word characters; CJK runs become overlapping bigrams (single
/// characters are emitted for runs of length 1).
pub fn Analyzer::analyze(self : Analyzer, text : String) -> Array[Token] {
  let tokens : Array[Token] = []
  let chars = text.to_array()
  let stop : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  if self.remove_stop_words {
    for w in default_stop_words {
      stop.set(w, ())
    }
  }
  let mut i = 0
  let mut position = 0
  while i < chars.length() {
    let c = chars[i]
    if is_cjk(c) {
      // Collect the whole CJK run, then emit bigrams.
      let start = i
      while i < chars.length() && is_cjk(chars[i]) {
        i += 1
      }
      let run_len = i - start
      if run_len == 1 {
        tokens.push({ term: chars[start].to_string(), position, })
        position += 1
      } else if self.cjk_bigram {
        let mut j = start
        while j + 1 < i {
          tokens.push({ term: intern_bigram(chars[j], chars[j + 1]), position, })
          position += 1
          j += 1
        }
      } else {
        let mut j = start
        while j < i {
          tokens.push({ term: chars[j].to_string(), position, })
          position += 1
          j += 1
        }
      }
    } else if is_word_char(c) {
      let start = i
      let buf : Array[Char] = []
      while i < chars.length() && is_word_char(chars[i]) {
        buf.push(normalize_char(chars[i], self.lowercase))
        i += 1
      }
      let term = String::from_array(buf[:])
      if term.length() > 0 && !(self.remove_stop_words && stop.contains(term)) {
        tokens.push({ term, position, })
        position += 1
      }
      let _ = start
    } else {
      i += 1
    }
  }
  tokens
}

///|
/// Convenience: analyze with the default analyzer.
pub fn tokenize(text : String) -> Array[Token] {
  Analyzer::default().analyze(text)
}

///|
pub impl Default for Analyzer with fn default() -> Analyzer {
  { lowercase: true, remove_stop_words: true, cjk_bigram: true, }
}
