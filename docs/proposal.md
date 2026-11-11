# moonseek — 项目申报书（一页项目说明）

| | |
|---|---|
| **项目名称** | moonseek — 纯 MoonBit 嵌入式全文搜索引擎 |
| **参赛方向** | 数据处理与数据库 / 工具库（基础软件生态空白填补） |
| **公开仓库** | https://github.com/NaIWaniubi/moonseek |
| **包注册** | https://mooncakes.io/packages/NaIWaniubi/moonseek （v0.4.0） |
| **许可证** | Apache-2.0（OSI 认可） |
| **队伍信息** | 队长：【填写姓名】· GitHub ID：NaIWaniubi · 队员：【填写或无】 |
| **联系方式** | 【填写邮箱/电话】· 推荐人：【填写 GitHub ID 或"无"】 |
| **规模** | 引擎 ~5,600 行 + 测试 ~3,600 行 MoonBit；242 项测试（native）/ 225 项（wasm-gc、js） |
| **提交版本** | v0.4.0（2026-11-12）· 提交日期：【填写】 |

## 解决什么问题

MoonBit 生态已有 HTTP 服务器、加密库、数据库驱动，但缺少 tantivy/Lucene 级的嵌入式全文搜索引擎：现有同类项目均为极早期原型（下载量 <100），无「索引 + 分词 + 排序 + 持久化」一体实现，且中文检索普遍依赖外部词典。moonseek 填补这一空白：纯 MoonBit 核心零 FFI，同一套代码编译到 native / WebAssembly / JavaScript 三端，浏览器里可直接跑完整搜索引擎。

## 核心能力

倒排索引与多字段加权 · BM25 排序 · CJK 二元切分（免词典中文检索）· 布尔/短语/前缀/字段限定查询 · 模糊搜索与 BK-tree 加速（2.4 万词项提速 13–1780×）· did-you-mean 拼写纠错 · 分面过滤与聚合 · 服务端高亮与片段提取（码点级偏移）· 逐词项 BM25 分数解释 · 段式索引与分层合并 · WAL 预写日志崩溃恢复 · CRC 校验快照（兼容 MSK1/2）

## 工程质量证据

- **测试**：242 项 native / 225 项 wasm-gc+js 全绿，含 quickcheck 属性测试、快照位翻转/截断检测、WAL 尾巴撕裂恢复、段合并正确性
- **CI**：GitHub Actions 八矩阵全绿（ubuntu×windows × native/wasm-gc/js × debug+release + 基准作业）
- **基准**（2 万文档 / 8.5 MB 文本 / 2.38 万词项，release）：建索引 ~6,500 docs/s；选择性词项查询 0.01 ms；饱和词项 6–7 ms；模糊查询 BK-tree 0.05–12 ms；17.6 MB 快照序列化 1.0 s / 加载 0.8 s
- **独立审查**：三路专家评审（算法正确性 / 持久化与崩溃恢复 / API 设计）产出 24 项发现，24 个独立复核员确认 23 项属实，全部修复并附回归测试；报告见 `docs/review-report.md`
- **文档**：双语 README、架构文档、性能白皮书（`docs/benchmark.md`）、17 维特性矩阵（`docs/comparison.md` vs tantivy/Lucene/bleve）、三层可运行示例

## 可复现演示

```bash
git clone https://github.com/NaIWaniubi/moonseek && cd moonseek
moon test --target native                      # 242 项测试
moon run examples/advanced --target native     # 全能力演示（分面/模糊/纠错/解释/分页/高亮）
moon build --target wasm-gc
cp _build/wasm-gc/debug/build/web/web.wasm demo/web.wasm
cd demo && python -m http.server 8000          # 浏览器：60 篇中英文档实时检索
```

## 与评审维度对照

| 评审维度 | 本项目证据 |
|---|---|
| 完成度 | 12 项核心能力全部实现并有测试；CLI + 三层示例 + 浏览器演示可端到端运行；mooncakes 已发 v0.4.0 |
| 生态贡献 | 填补 MoonBit 无嵌入式全文搜索引擎的空白；纯 MoonBit 核心零 FFI；API 覆盖索引/查询/分面/高亮/解释全链路，可直接被生态项目依赖 |
| 工程质量 | 242 项测试含属性测试与崩溃恢复用例；八矩阵 CI 全绿；三路独立评审 24 项发现全部结案；零编译告警 |
| 展示表现 | 单页浏览器演示（60 篇中英文档、分面 chips、BM25 分数解释面板、实时基准）；性能白皮书与 17 维特性矩阵 |

## 来源与原创性

原创项目，非移植：未复制任何第三方实现；依赖仅 `moonbitlang/core`（Apache-2.0）与 `moonbitlang/async`（Apache-2.0，仅用于 native 文件层）。算法（BM25、CJK bigram、BK-tree、WAL 帧格式）为公开文献实现，代码独立编写。

## AI 辅助声明

本项目使用 AI 辅助代码、测试与文档编写；目标、架构路径与质量由参赛者掌握，全部代码公开可审计。
