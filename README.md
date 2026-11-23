# AI质量检测

Flutter desktop harness for measuring the quality of OpenAI-compatible AI relay services.

当前版本：**v0.1.1**。项目地址：[ai_detect](https://github.com/liuxuzzz/ai_detect)。全局设置 → 关于中可以查看版本和修改说明。

客户端保留本地 DuckDB，支持离线检测。需要云端分享时，可前往 [评测分享站](https://ai_detect.wv.gs/) 注册，在个人中心创建 API Key（Client Key），再将浏览器中打开的站点地址和 Key 填入全局设置；也可以用 `cloud/` 自建评测分享站。云端 PostgreSQL 通过 API 接收检测数据。

安装包构建、GitHub Release 发布和下载方式见 [发布说明](docs/releases.md)，更新记录见 [CHANGELOG.md](CHANGELOG.md)。

自建云端站点的环境变量、Cloudflare 域名、首次管理员注册、SMTP 和 GitHub/Google 登录配置见 [云端部署说明](cloud/README.md)。

## 已实现

- 左侧上游连接管理：名称、Base URL、API Key、备注、模型获取与保存；可在编辑窗口合并获取的模型，也可手动添加多个模型。
- 每个渠道可以独立选择直连、HTTP 或 SOCKS5 代理，并配置代理主机和端口。模型获取、连接测试、流式请求和 Agent 多轮请求共用该渠道路由；失败不回退直连，HTTPS 保持证书校验。启用代理时 TCP 指标测量本机到代理的建连延时。
- 上游使用 API Key 认证。旧版 OAuth2 渠道升级或导入备份后保留渠道配置、清除旧令牌，需重新填写 API Key。
- 上游编辑窗口提供真实模型请求和“测试上游”按钮，会用当前模型发送最小测试请求并显示错误原因。
- 多组检测提示词，DuckDB 持久化，并保存全局下次默认选择。
- 内置默认提示词“鹈鹕测试”，原样使用指定的 HTML/SVG 自行车过宫门动画题目。升级时替换未编辑的旧默认提示词，保留用户自定义内容；删除后不会在每次启动时自动添加回来。
- 检测模式分为“Agent 工作流”和“单轮流式”。默认使用 Agent 工作流；可在工作区切换并记住全局选择。单轮模式只发送一次流式请求，用于测量上游原始速度和输出质量。
- Agent 工作流向 OpenAI 兼容上游声明 HTML 工作流工具，执行多轮 tool-call、回传 `tool` 结果，并逐轮保存请求/响应。内置 `write_html_file`、`read_html_file`、`list_html_files`、`render_html`，生成的 HTML 作为独立产物展示，默认展开渲染预览，可切换源码；模型直接输出的 HTML 同样自动渲染。产物更新、检测结束和历史回放均保留预览；工具路径限制在本地 HTML 工作区内，不执行 shell 或任意本地文件操作。
- `/chat/completions` 检测和上游连通测试固定使用 Stream，开启 `stream_options.include_usage`，采集 TCP 建连成功延时和首 token 延时；工作区不重复显示固定的 Stream 模式。
- 检测前可从上游保存的多个模型中选择测试模型和推理强度。GPT-6.1 系列提供轻度 (`low`)、中 (`medium`)、高 (`high`)、极高 (`xhigh`)、最大 (`max`) 五档；其他已识别模型按各自支持范围显示。按模型名识别 GPT/OpenAI、Claude、Gemini、DeepSeek、Grok、GLM、Kimi、MiniMax，并分别发送 `reasoning_effort`、Claude `thinking.budget_tokens` 或 Gemini `thinking_config`；未知模型可手动填写 `reasoning_effort` 参数值，留空时不添加字段。强度选择按上游和模型保存。
- 检测任务按上游独立在后台运行。运行一个渠道时仍可切换到其他渠道并启动新的检测；每个渠道分别保留输出、Thinking/工具活动、吞吐曲线、重试记录、停止句柄和完成状态，侧栏用橙色圆点标记后台运行中的渠道。
- 全局设置可配置错误重试次数（默认 2 次）和 Stream 连接/空闲超时（默认 45/60 秒）；超时中止连接并保存原始记录。已有输出或 Thinking/工具信息后失败会保留部分结果，不自动重复生成。
- 检测中可点击“停止检测”，取消连接或重试等待，保留已收到的内容和指标，记录为“用户已停止”；停止后可重新开始。
- 指标展示缓存读取/写入 token、平均 RPM（req/min）和 TPM（token/min）。速率取该上游全部成功检测的累计请求数或输入+输出 token ÷ 累计检测分钟，包含重试等待，重试不另计请求；不代表上游限额。
- 当前吞吐显示最近 1 秒收到的模型 token 数，随实时输出刷新，停止输出 1 秒后归零；吞吐曲线以固定 1 秒区间累加，当前秒持续更新，标明横轴时间（秒）和纵轴吞吐（token/s）。统计模型正文、Thinking 和工具调用参数，排除本地工具返回内容；实时输出按 100ms 批量刷新并隔离在输出面板。逐秒 token 使用文本估算，最终用量优先使用接口 usage；缓存未上报时显示 0，缓存未命中不算缓存写入。
- 检测请求仅包含所选提示词的一条 user 消息，原样发送，不追加 system 消息或 HTML 等格式条件；新增提示词内容默认为空。
- 输出区保留普通文本，将 HTML 代码围栏或原始 HTML 片段显示为可展开的区块，每块可切换“源代码 / 渲染预览”，流式接收时同样可展开。原文完整保存；macOS 使用内嵌 WebKit 渲染完整 HTML、CSS 和 JavaScript，预览随页面内容自动撑高，无内部纵向滚动，流式接收时最多每 500ms 刷新一次页面；其他平台使用基础 HTML 预览。
- 解析 OpenAI、DeepSeek 等常见 `usage` 字段：输入/输出 token、cached tokens、cache creation/write tokens，并计算缓存命中率。
- 独立“故障与重试”页记录每次失败时间、尝试编号和原因，点击后在“诊断详情”定位对应请求。流式故障在曲线上标红点，切回曲线保留缩放和区间。
- 每次检测结果持久化到本地 DuckDB。点击左侧渠道可展开/折叠历史，每页显示最近 5 条并可翻页，点击记录直接在右侧显示输出、HTML 源码/预览和指标；支持将检测报告导出为 HTML。查看历史不改变全局检测提示词。正文与原始响应按需读取。
- 历史记录支持删除，删除会级联清理该次检测的指标、曲线、重试、活动、请求响应和 Stream 分片数据。
- 工作区“诊断详情”Tab 提供 Request / Response / Stream 分片查看，检测期间实时更新，历史记录也能查看。保存每次重试的 URL、方法、实际请求正文、请求/响应头、状态码、原始响应正文、分片字节和接收时间；复制记录包含分片的 Base64 原始字节。鉴权与 Cookie 头会在采集时隐藏，失败或停止也保留已收到的数据。
- 诊断日志按秒分组，Response / Stream 共用一个外层滚动区域，隐藏滚动条；初始显示 10 条秒日志，滚动接近底部时自动分页加载后续内容，不再显示加载按钮。历史正文按秒从 DuckDB 分页查询，两个视图复用已读页；有界文本块使用统一的选择区域，避免每条日志内嵌滚动控件；隐藏工作区页面保留查看状态，避免切换时重复构建全文。HTML 报告按内容高度展开模型页面，图片、字体及异步内容变化后自动更新高度。
- 使用全新 DuckDB 数据库，不迁移旧 SQLite 数据。检测、分片、秒级流量、吞吐采样、故障、活动和模型列表分别入表；大数组不再作为整段 JSON 保存，支持直接按时间范围查询和 SQL 聚合。详见 [存储结构](docs/storage.md)。
- 实时输出按顺序展示接口返回的 reasoning/thinking、工具调用/结果和普通内容，可折叠查看。Agent 模式执行声明的内置 HTML 工具；单轮模式只展示工具信息。需要上游返回对应字段，不能获取未公开的内部推理。
- 曲线逐秒保存，包括等待与停顿的零值；支持缩放和区间选择，不合并原始秒级数据。Token 延时统一为两位小数秒，TCP 连接延时用毫秒；Token 数量、吞吐及 TPM 使用整数及美式千位分隔；原始协议字段保留原单位。
- HTML 报告的吞吐曲线可用滚轮或按钮缩放，放大后可拖动查看其他时间段，悬停或点按显示采样时间和该秒的 token 数。云端 Vue 报告按需加载 PostgreSQL 中的结构化数据，支持登录后更新自己的评分；客户端通过 API 上传数据，保留本地 DuckDB 离线存储。
- 全局设置可导出/合并导入 JSON 备份，包含渠道密钥、提示词、设置、检测历史、Thinking、曲线及原始请求响应。导入先校验，再以事务合并；同 ID 覆盖，其他数据保留。导入前自动在 Application Support 留存恢复备份。
- 测试仅请求配置的真实上游，不会用模拟输出生成检测指标。

## 启动

```bash
flutter pub get
flutter run -d macos
```

当前在 macOS 验证 `flutter build macos --debug`、`flutter analyze` 和 `flutter test`。应用使用 DuckDB 保存到系统 Application Support 目录下的 `aijiance.duckdb`，数据库操作和批量转换在后台 isolate 中执行。首次构建通过 CocoaPods 准备原生库；测试前运行 `python3 tool/bootstrap_duckdb.py`。macOS 沙盒已启用出站网络客户端权限；修改 entitlements 后需重新构建应用。Windows 和 Linux 安装包由 GitHub Actions 在对应平台构建，并进行启动与包结构检查；首次 GitHub 运行后可在 Actions 查看实际构建结果。
