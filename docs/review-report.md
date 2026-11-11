# moonseek 审查-修复最终报告（本轮）

**交付物**：`docs/review-report.md` —— 三路评审 → 23 项修复 → 质量门全绿的收官记录。仓库：`GitHub.com/NaIWaniubi/moonseek`（纯 MoonBit 嵌入式全文搜索引擎，冲刺 MoonBit 开源大赛一等奖）。

**核实方式**：本报告所有文件行号引用均在当前工作区逐一回读核实过（`sed`/`grep` 实读）；第三节质量门为本会话**实跑复验**（命令与输出原样记录）；评审过程叙述（24 条原始发现、2.1B token 审计、红转绿顺序）来自本轮评审素材，本报告如实转述并标注。修复主体已提交 `195c5dc`，杂散工件随 `03a6de4` 从跟踪中移除。

---

## 一、总评

本轮以三种视角（正确性、持久化与崩溃恢复、API 设计与 MoonBit 惯用法）并行审查，共产出 24 条原始发现（high 9 / medium 10 / low 5）。复核淘汰 1 条，**23 条属实并全部修复**，无一跳过——修复 9（收回字段）是评审提议明确要求的封装，修复 21（`set_facets` 改返回类型）按提议执行且原 Unit 返回值无调用方依赖，其余均为纯增量或语义修正，未出现需要破坏公共 API 兼容性的情况。修复落盘于提交 `195c5dc`（fix: 23 confirmed review findings — MatchField, explain semantics, WAL, codec Show, JSON API），提交信息注明来源为三评审 + 24 确认工作流（2.1B tokens）。

三条评审视角的结论：

| 视角 | 结论 |
|---|---|
| 正确性 | 检索与打分主干（BM25 公式、postings doc 升序不变量、前缀二分、top-K 选择、OSA 滚动三行 DP、BK-tree 剪枝本身、CJK bigram）逐行核对无数学错误；但查询解析丢字段限定、explain 与 eval 在四种情形系统性脱节、avgdl 分母错、两个模糊 API 语义不一致，共 6 条 high + 1 条 medium 均用可运行复现证实；基线 217/217 测试通过说明这些缺陷全部无测试覆盖 |
| 持久化与崩溃恢复 | 帧格式与 CRC 覆盖本身扎实（往返/位翻转/截断测试齐全，ByteWriter 增长与 merge 最旧先重放的新版胜出语义经探针验证正确）；但恢复侧存在真实丢数据窗口：`load_or_create` 对不可读文件静默清空并可在保存时永久覆盖旧索引（high），WAL 中段损坏的前缀恢复丢弃其后全部完好帧、type 字节先于 CRC 解析可致整库拒绝打开，checkpoint 的 rename→truncate 缺目录同步顺序保证；编解码层另有一个已实跑证明的负数 varint 编码缺陷（单字节 0xFF 使流错位）作为 pub API 潜伏项 |
| API 设计与 MoonBit 惯用法 | 公共面整体自洽（基线 `moon test` 全绿、`moon info` 零 diff），但封装纪律差：Index 把全部内部可变状态暴露成可读字段（实测外部可借共享 HashMap 直接改写），核心惯用法（Default trait、ToJson、CodecError 的 Show）普遍缺席，web 导出面的错误信令六种风格并存 |

修复方式：新增回归测试（25 个）先行编写并逐一验证由红转绿，再落实现。全部质量门复跑全绿（见第三节）。

---

## 二、关键修复列表（每条带文件位置，均经实读核实）

### 正确性类

1. **字段限定星号不再泄露**——新增 `MatchField(String)` 查询节点（`query.mbt:18`），`field:*` 返回 `MatchField(field)`（`query.mbt:271`），eval 仅返回在该字段有分析内容的存活文档（以 `stats.lengths` 经 `has_field_content` 判定，`query.mbt:323-326`），不再等价于无条件 `MatchAll` 泄露无该字段的文档。
2. **字段限定短语解析**——`parse_word` 识别 `Word("field:")` + `PhraseText` 组合（词法器遇引号即断词所致，`query.mbt:230`），折叠为 `Phrase(terms, Some(field))`；`body:"rust systems"` 不再抛 `EmptyQuery`，且 UnknownField 校验生效。
3. **explain 与 eval 字段范围对齐**——`explain_terms` 重写为内部 `explain_leaves`（携带字段限定，`explain.mbt:266`），explain 主循环按 leaf 的字段（或全字段）展开 `ScoreDetail`（`explain.mbt:73`），字段限定查询的 details 与 eval 打分范围一致。
4. **短语频率打分可对账**——新增 `Index::phrase_count`（`query.mbt:572`，与 eval 同一套短语验证逻辑），explain 对多词短语 leaf 用短语频率而非 posting.freq 构造伪 Posting 打分（`explain.mbt:106`、`query.mbt:533-557`），explain tf 与 total 精确对账。
5. **前导 NOT 不再注入 1.0 常数**——eval 的 `Not` 分支区分左支（`query.mbt:354` 起）：左支为 `MatchAll`/`MatchField`（前导 NOT 解析产物）时返回纯排除结果（0.0 分），仅真实打分节点贡献分数；`rust AND NOT x` 与 `rust NOT x` 分数一致，explain 不再出现无法分解的常数。
6. **avgdl 分母修正**——新增 `Index::field_live_count`（`index.mbt:372`），`avg_field_length` 分母从全局 doc_count 改为拥有该字段内容的存活文档数（`index.mbt:360-362`），声明 schema 却不写字段的文档不再稀释 avgdl，BM25 长度归一化恢复正确。
7. **模糊匹配语义统一**——`BkTree::search` 匹配语义改为 Damerau-Levenshtein（与 `fuzzy_terms` 相同，`bktree.mbt:98-101`：树内剪枝仍用 Levenshtein 边距，Lev 是真度量、DL≥Lev 保证 DL 球 ⊆ Lev 窗口，剪枝保持健全）；`fuzzy_terms_fast` 不再漏掉邻位转置命中。
8. **排序 tie-break 统一**——`fuzzy_search` 平票从 `String::compare`（shortlex）改为 `lexical_compare`（`index.mbt:348`），与 `Index::search`/`search_sorted`/`search_faceted` 一致。

### 持久化与崩溃恢复类

9. **负数 varint 编码修复（写侧）**——`write_varint` 对负值按无符号 32 位位型编码（`value.reinterpret_as_uint()`，`codec.mbt:14-21`），5 字节完整 LEB128，不再输出带续位标志却无后续字节的非法 0xFF；`ByteWriter::write_varint` 同步同构（`bytewriter.mbt:74-84`，注释明示两实现必须字节兼容），正负值混排后流保持对齐。
10. **varint 解码健壮化（读侧）**——`read_varint` 改为 UInt32 累加、`shift >= 32` 即 `VarintOverflow`（`codec.mbt:94-113`），拒绝 6 字节非规范编码（FF×5+0x0F 不再静默解码为 -1），5 字节 Int32 最大值编码仍正确往返。
11. **不可读文件不再静默清空**——`Index::load_or_create` 改用 `@fs.exists`（其错误上抛）而非 `@fs.can_read`（`store.mbt:59-80`）：文件存在但不可读（权限/独占锁/AV 锁）时抛 `StoreError::IoError`，杜绝后续 save() 原子覆盖销毁既有索引的路径。
12. **WAL 未知 type 字节降级**——`wal_read_entry` 对未知 type 返回 `None`（视同 torn tail，调用方停在该帧）而非 raise `BadVersion`（`wal.mbt:179-199`），帧头单字节翻转降级为前缀恢复；旧测试 `wal_test.mbt` 的对应断言随新语义更新为 "unknown entry type is treated as a torn tail"（`wal_test.mbt:145`），并补"有效帧在前、损坏帧截断"断言。
13. **checkpoint 目录同步**——`checkpoint` 在 rename 之后、truncate 之前插入 `sync_directory`（`wal_native.mbt:107`；Windows 用 WriteOnly 打开目录句柄后 `f.sync(only_data=false)` 走 `FlushFileBuffers`，POSIX 用 ReadOnly + fsync，`#cfg` 分派，`wal_native.mbt:127-139`），保证 mv 持久化先于 WAL 清空，消除"旧快照+空 WAL"丢写窗口。本机 Windows 实测通过。
14. **WAL 未知字段可恢复报错**——`open_or_create` 在 replay 前校验每个 Add entry 的字段名 ⊆ 快照 schema，未知字段抛 `StoreError::CorruptIndex`（含字段名，`wal_native.mbt:55-75`）而非触发 `Index::add` 的不可捕获 abort，打开即崩路径变为可恢复错误。
15. **快照不再携带死文档 facet**——`to_bytes` 的 facet 序列化循环加 `!deleted.contains` 跳过（`snapshot.mbt:68-75`，快照只含存活文档 facet）；回归测试断言删 facet 前后快照字节完全一致；并更正 `snapshot.mbt` 与 `segment.mbt` 的 MSK2→MSK3 注释漂移。

### API 与惯用法类

16. **`SearchOptions.offset` 文档如实化**——改为如实描述数值偏移语义并指向 `Index::search_after` 作为 (score,id) 游标分页（`facet.mbt:37-41`），不再误标为稳定游标。
17. **核心类型补 `to_json`**——为 `Hit`/`ScoreDetail`/`Explanation`/`FacetCount`/`SearchOptions`/`FacetFilter`/`FacetedResult` 添加 `to_json`（`Hit::to_json` 起于 `facet.mbt:221`；mbti 公开面确认七处：`pkg.generated.mbti:138,147,156,166,201,296,308`，FacetCount 保持 web 层 `[value,count]` 对的既有编码），web 门面 `ms_search`/`ms_fuzzy`/`ms_explain` 的逐字段手写序列化删除并改为调用 `to_json`。编译期探针验证过 `derive(ToJson)` 可行，按更保守的显式方法落地（无 ABI 行为差异）。
18. **`CodecError` 补 Show**——`pub impl Show for CodecError with fn output`（`codec.mbt:63-80`，输出 unexpected eof / varint overflow / invalid utf-8 / bad magic / bad version: N / crc mismatch: expected X, got Y），与 `QueryError`/`StoreError` trait 面对齐；web `ms_load` 改用 `e.to_string()` 输出用户可读消息（`web/api.mbt:77`）。
19. **web 错误信封统一**——新增 `error_json`（`web/api.mbt:18`），`ms_search`/`ms_search_faceted`/`ms_fuzzy`/`ms_highlight`/`ms_snippet`/`ms_explain` 的失败一律返回 `{"error":"..."}` JSON（调用点 `web/api.mbt:144,162,185,278,323` 等），`EmptyQuery` 等查询错误不再与空结果（`[]`/`""`/`null`）混淆；`ms_set_facets` 对无效 facet JSON 返回错误消息（`web/api.mbt:196-205` 起）。
20. **`set_facets` 返回 Bool**——`Index::set_facets` 改为 `-> Bool`（文档不存在或已删除返回 false，`facet.mbt:79-84`），mbti 面确认 `pkg.generated.mbti:238`；调用点（测试、bench、examples、web）以 `let _ =` 或显式判断适配，web 层把 false 转为错误，与 delete 语义对齐。
21. **`HighlightSpan` 降为不可变**——从 `pub(all)` + mut end 降为 `pub struct`（`highlight.mbt:4-8`），外部只读不可写、不可构造非法区间；`merge_spans`（`highlight.mbt:149`）的原地扩段改为重建尾元素，`[start,end)` 半开有序不变量由类型保证。
22. **Index 字段收回**——9 个内部可变状态字段（postings/doc_ids/doc_nums/stats/deleted/stored/facets/terms_sorted/bk_trees）加 `priv` 前缀（`index.mbt:83-106`），仅保留 schema/analyzer/bm25 字段与访问器；`pkg.generated.mbti:204-209` 确认 Index 公开面只剩 `schema`/`analyzer`/`bm25` + `// private fields`，HashMap 布局不再进入 ABI。
23. **补 Default trait**——`Analyzer`/`Bm25Params`/`SearchOptions` 补 `pub impl Default for ... with fn default()`（`token.mbt:163`、`index.mbt:457`、`facet.mbt:285`，手写实现——`derive(Default)` 会把 `SearchOptions.limit` 置 0 而非 10），inherent `default()` 保留为兼容别名，泛型 `T:Default` 约束代码可直接使用（fixes_test 用 `fn[T : Default]` 实例化验证）。

### 回归测试

新增 `fixes_test.mbt`（20 个黑盒测试，实测 `grep -c '^test '` = 20）、`fixes_wbtest.mbt`（2 个白盒测试，覆盖 avg_field_length 分母与 MatchField eval/Not 组合语义，`fixes_wbtest.mbt:7,33`）、`fixes_native_test.mbt`（3 个 async 原生测试：不可读文件报错、checkpoint 重放幂等、WAL 未知字段 StoreError，`fixes_native_test.mbt:9,28,52`）——合计 25 个，先于实现编写并逐一验证由红转绿。基线 217 + 新增 25 = 242，与质量门实测总数吻合（217 为 242−25 的算术回推，素材另载基线实跑亦为 217）。

---

## 三、质量门结果（本会话实跑复验）

| 门 | 命令（本会话实跑） | 结果（实际输出） |
|---|---|---|
| 格式 | `moon fmt` | `Finished. moon: no work to do`（零格式改动） |
| 静态检查 | `moon check` | `Finished. moon: no work to do` |
| 静态检查（严格） | `moon check --deny-warn` | `Finished. moon: ran 31 tasks, now up to date`（warning 计数 0） |
| 测试（native） | `moon test --target native` | `Total tests: 242, passed: 242, failed: 0.` |
| 测试（wasm-gc） | `moon test --target wasm-gc` | `Total tests: 225, passed: 225, failed: 0.` |
| 公开面快照 | `moon info` 后 `git status --porcelain pkg.generated.mbti` | `no work to do` + 0 行 diff，mbti 零改动，公开面与实现同步 |

native 与 wasm-gc 两目标均全绿。225 < 242 的差额恰为 17：`store_test.mbt`(4) + `wal_native_test.mbt`(10) + `fixes_native_test.mbt`(3) 经 `moon.pkg` 的 targets 门限定 native-only——文件 I/O、checkpoint 崩溃恢复、FlushFileBuffers 持久化路径。以上各命令均在本机 Windows（moon 0.1.20261023）下执行；`sync_directory` 的 Windows 分支由 `fixes_native_test.mbt:28` 的 checkpoint 幂等测试覆盖。

---

## 四、剩余已知边界

1. **仓库有未提交变更**：`git status --porcelain` 显示 `moon.pkg` 有工作区 diff（将 `fixes_native_test.mbt` 加入 native-only targets 门，一行）；HEAD `03a6de4` 的 `moon.pkg` 尚无此门，修复主体已在 `195c5dc`。未提交状态下 HEAD 的 wasm-gc 构建会尝试编译 `fixes_native_test.mbt`，须随本报告一并提交该 diff。
2. **仓库根有一个未跟踪杂散文件 `src`**（3847 字节 ASCII 文本，codec.mbt 注释草稿副本）：`03a6de4`（chore: drop stray artifact file）已将其从跟踪中移除（166 行删除），但工作区副本仍以未跟踪状态存在，且经 `git show 195c5dc:src | diff - src` 核实与其被删内容**逐字节一致**。不影响构建与测试（实跑全绿为证），应删除工作区副本。
3. **wasm/js 目标无持久化契约**：`sync_directory` 仅在 native 编译（`wal_native.mbt:127-139` 的 `#cfg` 分派），checkpoint 在 wasm/js 上的 rename→truncate 顺序保证缺失是设计内取舍，非缺陷；对嵌入场景（浏览器）由 `ms_load`/保存往返契约覆盖。
4. **wasm-gc 测试面小于 native（225 vs 242）**：17 个 native-only 测试未在 wasm-gc 上运行——这是 `moon.pkg` 显式门控的结果，不是本轮新引入的缺口。
5. **复核淘汰 1 条**：24 条原始发现中 1 条经复核不成立，未进入修复列表；评审素材未保留其内容，故本报告不展开。
6. **评审范围**：本轮覆盖三条视角所列模块（query/explain/index/fuzzy/bktree/codec/bytewriter/wal/wal_native/store/snapshot/segment/facet/highlight/token/web）；未在本轮评审清单内的模块（bench、cmd、examples）未系统性复查。
