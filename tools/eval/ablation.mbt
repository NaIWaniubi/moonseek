///|
/// Ablation configurations: the same corpus and queries under different
/// scoring rules, so the report can attribute quality to specific mechanisms
/// instead of asserting "BM25 is good".
///
/// Each configuration is expressed purely through the index's public knobs
/// (field weights and declared fields). No configuration reaches into the
/// evaluator, so what the benchmark measures is what a user could ship.

///|
/// A named retrieval configuration.
pub(all) struct Config {
  name : String
  schema : Array[@moonseek.FieldSchema]
  /// Restrict every query to this field ("" = all fields).
  field : String
  /// Description of what the configuration isolates, for the report table.
  isolates : String
}

///|
/// The configurations under test.
pub fn configs() -> Array[Config] {
  [
    // Reference: what the shipped demo uses.
    {
      name: "bm25-weighted",
      schema: @reglib.registry_schema(),
      field: "",
      isolates: "the shipped configuration: BM25 over 4 fields, title 6x, keywords 3x, deps 1.5x",
    },
    // Odd weights all round: does the weighting carry the quality?
    {
      name: "bm25-uniform",
      schema: [
        { name: "title", weight: 1.0 },
        { name: "keywords", weight: 1.0 },
        { name: "desc", weight: 1.0 },
        { name: "deps", weight: 1.0 },
      ],
      field: "",
      isolates: "field weights: does the title/keyword boost earn its place?",
    },
    // Description only: what a naive single-field index would return.
    {
      name: "desc-only",
      schema: [{ name: "desc", weight: 1.0 }],
      field: "",
      isolates: "indexing only prose: how much do names and keywords matter?",
    },
    // Name only: the "just grep the package list" baseline.
    {
      name: "title-only",
      schema: [{ name: "title", weight: 1.0 }],
      field: "",
      isolates: "the substring-search-the-names baseline every registry UI ships",
    },
    // Name + keywords: a metadata-only index, no prose.
    {
      name: "metadata-only",
      schema: [
        { name: "title", weight: 6.0 },
        { name: "keywords", weight: 3.0 },
      ],
      field: "",
      isolates: "is indexing prose (the expensive part) worth anything?",
    },
    // BM25 with length normalization disabled: b = 0 means tf saturation only.
    {
      name: "no-length-norm",
      schema: @reglib.registry_schema(),
      field: "",
      isolates: "BM25 length normalization (b = 0): does document length matter here?",
    },
  ]
}

///|
/// Build an index for one configuration. The b == 0 case is applied by
/// constructing the index with modified BM25 parameters, everything else
/// through the schema alone.
pub fn build_for(config : Config, docs : Array[Json]) -> @moonseek.Index {
  let bm25 : @moonseek.Bm25Params = if config.name == "no-length-norm" {
    { k1: 1.2, b: 0.0 }
  } else {
    @moonseek.Bm25Params::default()
  }
  let (index, _) = @reglib.build_registry_index(
    docs,
    schema=config.schema,
    bm25~,
  )
  index
}
