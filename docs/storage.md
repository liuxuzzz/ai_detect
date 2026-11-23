# DuckDB 存储

数据库路径为系统 Application Support 目录中的 `aijiance.duckdb`。
新版本从空库启用，不读取或迁移旧 `aijiance.sqlite`。

## 数据粒度

| 表 | 每行代表什么 |
| --- | --- |
| `upstreams` / `upstream_models` | 渠道配置 / 渠道的一个模型 |
| `prompts` / `settings` | 提示词 / 一项设置 |
| `diagnostics` | 一次检测的标量汇总、输出和检测时的渠道/模型快照 |
| `metric_samples` | 检测的一个秒级吞吐采样点，零值也保留 |
| `request_attempts` | 一次 HTTP 尝试的状态、耗时、请求正文、字节和分片总数 |
| `http_headers` | 一项请求或响应头 |
| `stream_chunks` | 一个原始传输分片：序号、接收时间、字节数、BLOB 原文及 UTF-8 文本 |
| `traffic_seconds` | 一次 HTTP 尝试的一秒入站字节数、分片数及分片序号范围 |
| `retry_events` | 一次故障/重试事件 |
| `model_activities` | 一个 Thinking、工具调用或输出活动 |

分片、曲线、重试、模型列表和活动不存为 JSON 数组列。原始协议正文仍是文本，JSON 仅用于可移植的备份格式。
`channel_rates` 视图直接从检测事实聚合累计 RPM/TPM 所需的请求数、token 和耗时；分析查询无需解析日志 JSON。

## 写入和读取

数据库连接、SQL、结果转换、备份编码和 Appender 批量写入在独立 Dart isolate 中运行。DuckDB 查询配置 4 个执行线程。每次保存及导入使用事务，替换同一检测时同时替换子表数据。

历史列表只查标量摘要；打开历史记录只读取输出、秒级曲线、故障和请求元数据，不读 `stream_chunks.payload`。Stream 曲线直接使用 `traffic_seconds`，无需扫描或解码所有分片。

Response 与 Stream 的正文按有数据的秒分组，初始 10 条。滚动接近底部时，以最后已读秒作为游标：

```sql
SELECT elapsed_second
FROM traffic_seconds
WHERE diagnostic_id = ? AND attempt_index = ? AND elapsed_second > ?
ORDER BY elapsed_second
LIMIT 10;
```

随后只查这 10 个秒对应的分片，按 `chunk_index` 排序。游标分页允许秒之间有空档；滚动触底前自动请求下一批，同一时间只进行一次读取与解码。两个视图共用已经读取的页，但分别保留加载数量和滚动位置。新页只组装新读取的内容，旧页不重新解码。

原始字节使用 BLOB；派生文本在写入时用连续 UTF-8 解码器生成，因此跨分片/跨页的中文和 emoji 不会因分页损坏。读 BLOB 时在推进原生游标之前拷贝字节，避免结果集内存释放后产生悬空视图。

## 云端同步

客户端继续使用本地 DuckDB，离线时仍可检测和查看历史。上传已保存的测试时，通过 Axum API 发送结构化指标、提示词、模型输出、曲线采样、活动和重试记录；不上传 HTML 报告，也不直连云端数据库。上传失败不删除本地数据，联网后可重新上传。

云端将指标写入 PostgreSQL 的 `reports.metadata`、完整报告内容写入版本化的 `reports.data` JSONB。Vue 列表读取摘要，打开详情后才加载正文并渲染。原始 HTTP 头和请求正文保留在客户端，不随报告上传。客户端的 HTML 导出仅用于本地离线文件。

## macOS 构建与测试

`dart_duckdb` 通过 CocoaPods 捆绑原生库，运行应用无需安装 DuckDB 服务。首次构建需联网下载原生依赖。开发机测试先执行：

```bash
flutter pub get
dart run tool/bootstrap_duckdb.dart
flutter test
flutter build macos --debug
```

准备脚本从 DuckDB 官方 GitHub Release API 获取 v1.4.2 的 macOS universal 二进制并核对固定 SHA-256，同时准备测试路径和插件构建路径。测试也可以用 `AI_CHANNEL_DUCKDB_LIBRARY` 指向兼容的动态库。
