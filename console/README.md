# moonseek 控制台（web console）

`moonseek-server` HTTP 服务的成品级 Web 控制台：纯静态、零依赖、离线可用（无 npm、无 CDN、无构建步骤、无框架、无 `import`），只由 `index.html`（内联 CSS）+ `console.js`（普通 `<script>`）+ 本文件组成。

## 启动

服务端由 `moonseek-server` 提供（默认监听 `http://127.0.0.1:7700`，见 `../docs/api.md`）。控制台是纯静态资源，两种启动方式任选：

```bash
# 方式一：任意静态服务器托管本目录
cd moonseek/console
python -m http.server 8080
# 浏览器打开 http://127.0.0.1:8080/ ，把页面顶部“服务地址”保持为 http://127.0.0.1:7700，点「连接」

# 方式二：由服务端直接托管这三个文件（推荐，同源无 CORS 顾虑）
#   把 moonseek/console/ 作为静态目录挂到服务端即可，打开 /console/index.html
```

> 请通过 `http://` 打开本页面（用 `python -m http.server` 或服务端托管）。直接双击 `index.html` 走 `file://` 时，部分浏览器会拦截 `file://` 到 `http://127.0.0.1` 的 `fetch`；此时请改用上面的方式启动。服务端已设置 `Access-Control-Allow-Origin: *`，跨源部署（如 8080 端口托管）同样可用。

## 功能

- **顶部**：服务地址输入框（默认 `http://127.0.0.1:7700`）、连接按钮、连接状态点（绿=`GET /healthz` 正常 / 红=失败）、服务端版本号。
- **搜索**：搜索框 + 搜索按钮，`Enter` 触发；显示 `total` 与响应里的 `took_ms`（本次查询耗时，毫秒）。
- **结果区**：每条命中显示 id、`score`、`snippet`（经 XSS 防护：仅 `<mark>`/`</mark>` 标签放行，其余全部转义）、可折叠的 `explain` 表格（field/term/tf/df/idf/norm/score）。
- **分面侧栏**：把 `facets` 的每个字段渲染成可点击的「值 + 计数」chip；点击后作为 `filter=field:value` 重新查询，已选中高亮，另有「清除筛选」。分面字段可在面板内编辑（默认 `license,year`）。
- **聚合面板**：`POST /search`，渲染 `aggs` 的 `terms`（条形）、`stats`（count/min/max/avg/sum）、`histogram`（条形）；跟随搜索自动刷新，也可点「运行聚合」手动触发。
- **建索引**：选择本地 `.json`/`.jsonl`/`.csv`/`.md`/`.txt` 文件并解析为文档，分批 POST 到 `/index/bulk`，显示解析进度、上传进度与索引条数/耗时。
- **索引统计**：每 2 秒轮询 `GET /_stats`，展示 `docs`/`terms`/`snapshot_bytes`/`queries_served`/`avg_query_ms`/`p99_query_ms`（数字块 + 条形）。
- **查询语法速查**、**命中为 0 时调用 `GET /suggest`** 显示“你是不是想搜：…”。

键盘：`/` 聚焦搜索框，`Esc` 清空。

## 安全与健壮性

- 所有插入 DOM 的值都经 `escapeHtml()`；搜索片段经 `safeSnippet()`，只放行裸 `<mark>`/`</mark>`，杜绝 XSS。
- 网络失败、HTTP 错误（`{error, code}` 形状）、超时都会显示可读提示，界面不会白屏。

## 与 API 契约

唯一权威定义是 [`../docs/api.md`](../docs/api.md)。控制台只使用其中定义的端点、字段名与错误形状。
