# moonseek — 项目申报书

## 基本信息

- **项目名称**：moonseek — 纯 MoonBit 嵌入式全文搜索引擎
- **仓库**：https://github.com/NaIWaniubi/moonseek （公开，Apache-2.0）
- **包注册**：https://mooncakes.io/packages/NaIWaniubi/moonseek （0.1.0 已发布）
- **参赛方向**：数据处理与数据库 / 工具库（基础软件生态空白填补）
- **规模**：~5,600 行有效 MoonBit 代码（不含测试与依赖），242 项测试

## 解决什么问题

MoonBit 生态已有 HTTP 服务器、加密库、数据库驱动，但**缺少 tantivy/Lucene 级的嵌入式全文搜索引擎**——现有 MoonSearch/NyaSearch 等均为极早期原型（下载量 <100），无「索引+分词+排序+持久化」一体实现。moonseek 填补这一空白，且同一套核心代码可编译到 native、WebAssembly、JavaScript 三端。

## 核心功能

1. **倒排索引**：term → postings（文档号+词频+位置），多字段加权（title×3 / body×1）
2. **BM25 排序**：可配置 k1/b，字段权重加成
3. **中英混合分词**：拉丁词小写化+停用词；CJK 重叠二元切分（Lucene CJKAnalyzer 策略），**免词典支持中文检索**
4. **查询语法**：词项、"精确短语"、AND/OR/NOT、field:term、前缀*、括号、隐式 AND
5. **崩溃安全持久化**：MSK3 版本化快照 + CRC-32 校验；原子写入（临时文件→fsync→rename）；WAL 预写日志 + 崩溃恢复（只回放完整条目）；损坏/截断文件拒绝加载
6. **模糊搜索与纠错**：Levenshtein/Damerau 编辑距离 + BK-tree 加速（2.4 万词项词典提速 13–1780×）；did-you-mean 词频加权纠错
7. **分面搜索**：facet 过滤 + 聚合计数 + 分页；排序控制（分数/ID）与游标分页
8. **服务端高亮**：码点偏移映射、HTML 转义、片段提取（Lucene 级 API）
9. **分数解释**：逐词项 BM25 分解（tf/df/idf/贡献分），支撑「为什么是这个结果」
10. **浏览器运行**：WasmGC + js-string builtins 导出，搜索引擎完整跑在浏览器里

## 工程质量证据

- **测试**：242 项（native）/ 225 项（wasm-gc、js），覆盖分词、布尔/短语/前缀/模糊查询、BM25 排序、分面过滤聚合、高亮偏移与转义、段合并、WAL 尾巴截断恢复、快照往返、位翻转/截断/坏版本检测、quickcheck 属性测试
- **CI**：GitHub Actions，ubuntu×windows × wasm-gc×js×native 六矩阵全绿
- **基准**（bench/stress，2 万文档 / 8.5MB 文本 / 2.38 万词项，release）：建索引 6.7s（≈3000 docs/s）；选择性词项查询 0.02ms；饱和词项 13ms；模糊查询 BK-tree 0.05–12ms（线性 85–150ms）；快照 17MB 序列化 2.4s / 加载 1.7s
- **浏览器实测**（headless Chromium）：60 文档 25ms 建索引，中文/英文/字段/模糊查询、分面过滤、高亮、分数解释全部通过，零 JS 错误
- **独立审查**：三路专家评审（正确性/持久化/API）产出 24 项发现，24 个独立复核确认 23 项属实，全部修复（字段限定语义、分数可对账、WAL 恢复策略、封装纪律），终审报告 docs/review-report.md
- **文档**：中英双语 README、架构文档、性能白皮书（docs/benchmark.md）、17 维特性矩阵（docs/comparison.md vs tantivy/Lucene/bleve）、三层示例（basic/persistence/advanced）

## 演示

单页浏览器演示（demo/）：内置 MoonBit 文档摘要 + 论语/道德经语料，现场输入「搜索引擎」「学而时习之」「memory safety」即时出结果并高亮。索引与查询全部在本地浏览器完成，无网络请求。

## 后续规划

- 11–1 月（黑客松 Q2）：postings 迭代器求值器（避免每查询物化打分表）、更大规模真实语料压测、分布式分片原型
- 2027 春（OSC2027）：分布式分片查询 / SQL 风格过滤层（以启动日后新增工作参赛）

## AI 辅助声明

本项目使用 AI 辅助代码、测试与文档编写；目标、架构路径与质量由参赛者掌握，全部代码公开可审计。