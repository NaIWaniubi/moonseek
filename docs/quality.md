# Retrieval quality on the mooncakes registry

3698 real published packages, 17 queries, labels derived from the corpus itself. Regenerate with `moon run tools/eval --target native --release -- demo/registry.json docs/quality.md`.

## What the labels are

**These are derived judgments, not human assessments.** Each query carries its own relevance rule taken from the data: a keyword query grades every package that declares that exact keyword at 2; a dependency query grades direct dependents at 2 and packages merely sharing the dependency's basename at 1; a name-part query grades packages whose name contains that word at 2. The rules are fixed before any retrieval happens and never look at the retriever's output, so the numbers are comparable *across configurations in this table*. They are not comparable to published BEIR or MS MARCO scores and this report makes no such claim.

## Aggregate

| configuration | NDCG@10 | MRR@10 | Recall@20 | ms/query | what it isolates |
|---|---|---|---|---|---|
| `bm25-weighted` | **0.9045** | 1.0000 | 0.3376 | 0.6471 | the shipped configuration: BM25 over 4 fields, title 6x, keywords 3x, deps 1.5x |
| `bm25-uniform` | **0.8236** | 0.9314 | 0.2902 | 0.7059 | field weights: does the title/keyword boost earn its place? |
| `desc-only` | **0.4771** | 0.5899 | 0.1421 | 0.1765 | indexing only prose: how much do names and keywords matter? |
| `title-only` | **0.4082** | 0.4706 | 0.0953 | 0.0588 | the substring-search-the-names baseline every registry UI ships |
| `metadata-only` | **0.7185** | 0.7941 | 0.3227 | 0.1765 | is indexing prose (the expensive part) worth anything? |
| `no-length-norm` | **0.9142** | 1.0000 | 0.3323 | 0.6471 | BM25 length normalization (b = 0): does document length matter here? |

### Change against the shipped configuration

| configuration | dNDCG@10 | dMRR@10 | dRecall@20 |
|---|---|---|---|
| `bm25-uniform` | -8.9% | -6.9% | -14.0% |
| `desc-only` | -47.2% | -41.0% | -57.9% |
| `title-only` | -54.9% | -52.9% | -71.8% |
| `metadata-only` | -20.6% | -20.6% | -4.4% |
| `no-length-norm` | +1.1% | +0.0% | -1.6% |

## Per query (NDCG@10)

| query | relevance rule | relevant docs | bm25-weighted | bm25-uniform | desc-only | title-only | metadata-only | no-length-norm |
|---|---|---|---|---|---|---|---|---|
| `parser` | keyword `parser` | 230 | 1.0000 | 0.9149 | 0.7421 | 0.8572 | 1.0000 | 0.8900 |
| `wasm` | keyword `wasm` | 238 | 0.9216 | 0.9149 | 0.7827 | 0.6403 | 0.8611 | 1.0000 |
| `json` | keyword `json` | 103 | 0.9306 | 1.0000 | 0.9149 | 0.6118 | 0.7917 | 0.9306 |
| `cli` | keyword `cli` | 171 | 1.0000 | 0.7846 | 0.2470 | 0.6500 | 1.0000 | 0.8482 |
| `http` | keyword `http` | 83 | 0.8263 | 0.8416 | 0.8416 | 0.8630 | 0.7975 | 0.8263 |
| `async` | keyword `async` | 46 | 0.7264 | 0.9306 | 0.5735 | 0.3188 | 0.7264 | 0.7417 |
| `gui` | keyword `gui` | 29 | 0.9052 | 1.0000 | 0.9337 | 0.4690 | 0.9052 | 0.9052 |
| `database` | keyword `database` | 49 | 0.7624 | 0.6785 | 0.2736 | 0.0000 | 1.0000 | 0.8580 |
| `regexp` | keyword `regexp` | 5 | 0.9670 | 0.7227 | 0.3392 | 0.5296 | 0.9747 | 0.9747 |
| `serialization` | keyword `serialization` | 42 | 1.0000 | 1.0000 | 0.6067 | 0.0000 | 1.0000 | 1.0000 |
| `compiler` | keyword `compiler` | 28 | 0.7753 | 0.7273 | 0.1584 | 0.0000 | 0.6000 | 0.8007 |
| `benchmark` | keyword `benchmark` | 12 | 1.0000 | 0.8454 | 0.4288 | 0.0000 | 1.0000 | 1.0000 |
| `moonbitlang/async` | depends on `moonbitlang/async` | 940 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 0.0000 | 1.0000 |
| `moonbitlang/x` | depends on `moonbitlang/x` | 901 | 0.8611 | 0.8611 | 0.1389 | 0.0000 | 0.0000 | 0.8611 |
| `cli/core` | depends on `cli/core` | 78 | 1.0000 | 1.0000 | 0.0000 | 0.0000 | 0.0000 | 1.0000 |
| `moon` | name contains `moon` | 299 | 0.7001 | 0.6699 | 0.1299 | 1.0000 | 0.5583 | 0.9052 |
| `mbt` | name contains `mbt` | 53 | 1.0000 | 0.1100 | 0.0000 | 1.0000 | 1.0000 | 1.0000 |

## Reading the table

- `desc-only` and `title-only` are the baselines that matter: each is what a naive implementation ships. The gap between them and the shipped configuration is the value the index adds.
- `metadata-only` answers a cost question. Prose is the bulk of the index; if dropping it barely moves the numbers, the index is paying for text nobody searches.
- `no-length-norm` sets BM25's `b` to 0. If it ties the shipped configuration, length normalization is not earning its complexity on this corpus - a result worth reporting either way.
- Query latency here is single-run wall clock on one machine. The stress benchmark is the place for latency claims, not this table.
