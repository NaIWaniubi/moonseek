# moonseek demo video — shot list

A 2–3 minute screen recording of the whole platform. Everything on screen is
produced by the running cluster; nothing is mocked. One command drives it:

```bash
tools/demo-story.sh          # ~2 min, narrated banners, pauses between steps
DEMO_PAUSE=0 tools/demo-story.sh   # same run, no waiting (rehearsal)
```

Record the terminal (plus one browser window for step 8). On the runner that is
one take; if you want to cut, the step banners (`== 0/8 …`) are natural cut
points.

## Before you record

- Build once so the take starts fast: `moon build server --target native --release`.
- Terminal: dark theme, font ≥ 16 pt, window ~100×30 so nothing wraps.
- Have a browser tab ready; you will open it at the end (the script prints the URL).
- `tools/demo.sh` is the "leave it running" launcher; `demo-story.sh` is the
  performance. Use `demo-story.sh` for the video.

## Shots

| # | on screen | what it proves | ~time |
|---|---|---|---|
| 0 | `== 0/8 … starting 4 primary+replica groups` | one binary is a node, a shard or a coordinator — the same `server` executable nine times | 8 s |
| 1 | ingest reply `{"indexed":3000,"members_ok":6,"members":6}` | every write reaches **all six** members of the owning group, not just the primary | 12 s |
| 2 | four queries (`parser`, `socket cache`, `"zero-copy"`, `scheduler OR allocator`) with totals | real retrieval: ranking, phrases, boolean, snippets | 15 s |
| 3 | `coordinator == single node: True` ×3 | `?dfs=true` scatter-gather reproduces a single node's ranking exactly | 12 s |
| 4 | `coordinator fused top-5 == single node: True` + rank line | hybrid BM25×kNN fanned out and fused by the same code the single node runs | 18 s |
| 5 | `plan: move 814 of 3200 (25.4%)` → `rebalance moved 814` → per-group counts | growing 3→4 groups without reindexing, prediction == execution | 25 s |
| 6 | replica `894 → 893` deleted on one member → `repair moved:1` → `894` | a divergent member is brought back in line | 20 s |
| 7 | kill primary → `identical` ; kill its replica → `ok 3/4, failed 1` | failover is invisible; a real loss is reported, not hidden | 30 s |
| 8 | browser: console at `:8080`, search a term, click a facet | the product a user actually touches | 20 s |

## Narration (English, ~2 min)

> **0.** One MoonBit binary. It can be a node, a shard, or a coordinator — here
> four groups, each a primary and a replica, and one single node for comparison.
>
> **1.** We load three thousand documents **through the coordinator**. It routes
> each to the group that owns it and replicates to every member — six of six
> acknowledged.
>
> **2.** Real queries: a term, an AND, an exact phrase, a boolean OR. Notice the
> totals and the snippets.
>
> **3.** The interesting one: with `dfs=true` the coordinator gathers corpus-wide
> statistics first, and its ranking is **byte-for-byte** a single node's.
>
> **4.** Hybrid retrieval. BM25 fused with a vector kNN search — fanned out
> across shards, merged, and fused by the *same function* the single node uses.
> Identical top-5.
>
> **5.** Now grow it: three groups to four, **without reindexing**. The plan
> predicts 814 of 3200 documents move; the executor moves 814. The four groups
> end at exactly the predicted distribution.
>
> **6.** A replica diverges — we delete a document directly on it. `POST
> /_repair` copies exactly that one back. The member is in line again.
>
> **7.** Kill a primary: the answer is **identical** — its replica took over.
> Kill the replica too and the whole group is gone: the answer is honestly
> partial, the failed shard is named, and the total drops. It degrades; it
> doesn't lie.
>
> **8.** And this is the console a user opens — search, facets, aggregations,
> live index stats.

## Narration (中文，约 2 分钟)

> **0.** 一个 MoonBit 二进制，可以是节点、分片或协调器——这里是四个组，每组一主一备，另加一个单机节点做对比。
>
> **1.** 通过协调器灌入三千篇文档：按归属路由并**复制到每个成员**，6/6 全部确认。
>
> **2.** 真实检索：词项、AND、精确短语、布尔 OR，看 total 与片段。
>
> **3.** 关键一步：开 `dfs=true` 时协调器先取全语料统计，排序与单机**逐字节一致**。
>
> **4.** 混合检索：BM25 与向量 kNN 融合，跨分片扇出，用**同一个**融合函数——top-5 与单机完全相同。
>
> **5.** 扩容：三个组到四个组，**不重建索引**。规划器预测搬 814 篇（3200 中），执行器搬 814 篇，四组最终就是预测的分布。
>
> **6.** 一个副本掉队了——直接在它上面删一篇；`POST /_repair` 精确补回这一篇。
>
> **7.** 杀掉主分片：答案**完全不变**，副本接管。再把副本也杀掉，整组消失：答案诚实地变成部分——失败分片被点名，total 下降。它会降级，但不说谎。
>
> **8.** 最后是用户真正打开的控制台：检索、分面、聚合、实时索引统计。

## Delivery

- Preferred: an MP4 uploaded to the repo's GitHub Releases (or linked), plus a
  GIF of shots 5–7 (the distributed story) for the README.
- If recording is not possible, the **scripts themselves are the demo**: a
  reviewer runs `tools/demo-story.sh` and sees the identical narrated output.
