import 'dart:convert';
import 'channel_proxy.dart';

class Upstream {
  const Upstream({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    this.proxy = const ChannelProxy(),
    this.note = '',
    this.selectedModel = '',
    this.reasoningModels = const <String>{},
    this.reasoningConfigured = false,
  });
  final String id, name, baseUrl, apiKey, note, selectedModel;
  final List<String> models;

  /// Models for which the operator explicitly enabled reasoning controls.
  /// An empty set is kept compatible with older in-memory records and means
  /// known reasoning models use their provider defaults.
  final Set<String> reasoningModels;
  final bool reasoningConfigured;
  final ChannelProxy proxy;
  Upstream copyWith({
    String? selectedModel,
    List<String>? models,
    String? apiKey,
    ChannelProxy? proxy,
    Set<String>? reasoningModels,
    bool? reasoningConfigured,
  }) => Upstream(
    id: id,
    name: name,
    baseUrl: baseUrl,
    apiKey: apiKey ?? this.apiKey,
    models: models ?? this.models,
    proxy: proxy ?? this.proxy,
    note: note,
    selectedModel: selectedModel ?? this.selectedModel,
    reasoningModels: reasoningModels ?? this.reasoningModels,
    reasoningConfigured: reasoningConfigured ?? this.reasoningConfigured,
  );
  factory Upstream.fromMap(Map<String, Object?> m) => Upstream(
    id: m['id'] as String,
    name: m['name'] as String,
    baseUrl: m['base_url'] as String,
    // Older backups stored an access token in this field for browser login.
    // Require an API Key instead of reusing that token as a permanent key.
    apiKey: m['auth_type'] == 'oauth2' ? '' : m['api_key'] as String,
    proxy: ChannelProxy.fromMap(m),
    note: (m['note'] as String?) ?? '',
    selectedModel: (m['selected_model'] as String?) ?? '',
    models: List<String>.from(jsonDecode((m['models'] as String?) ?? '[]')),
    reasoningModels: _decodeReasoningModels(m['reasoning_models']),
    reasoningConfigured: (m['reasoning_configured'] as bool?) ?? false,
  );
  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'base_url': baseUrl,
    'api_key': apiKey,
    ...proxy.toMap(),
    'models': jsonEncode(models),
    'reasoning_models': jsonEncode(reasoningModels.toList()),
    'reasoning_configured': reasoningConfigured,
    'selected_model': selectedModel,
    'note': note,
  };

  static Set<String> _decodeReasoningModels(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is List) return decoded.whereType<String>().toSet();
    }
    if (value is Iterable) return value.whereType<String>().toSet();
    return <String>{};
  }
}

class TestPrompt {
  const TestPrompt({
    required this.id,
    required this.name,
    required this.content,
  });
  final String id, name, content;
  factory TestPrompt.fromMap(Map<String, Object?> m) => TestPrompt(
    id: m['id'] as String,
    name: m['name'] as String,
    content: m['content'] as String,
  );
}

const defaultPelicanPrompt = TestPrompt(
  id: 'default-pelican',
  name: '鹈鹕测试',
  content:
      '创建一个 HTML ，内容是一张精细的 SVG 图片，画面是鹈鹕骑着自行车穿过故宫门，故宫门高 1.9999 米，车座椅高 0.5249 米，鹈鹕脖子以下 0.4751 米，脖子长 1.1011 米，让它摆好姿势能坐着车座椅成功骑车穿过门，做成 2D 动画版本，不要测试。',
);

class RetryEvent {
  const RetryEvent(this.at, this.reason, this.attempt, {this.elapsedMs});
  final DateTime at;
  final String reason;
  final int attempt;
  final int? elapsedMs;
  Map<String, Object?> toMap() => {
    'at': at.toIso8601String(),
    'reason': reason,
    'attempt': attempt,
    'elapsed_ms': elapsedMs,
  };
  factory RetryEvent.fromMap(Map<String, dynamic> m) => RetryEvent(
    DateTime.parse(m['at']),
    m['reason'],
    m['attempt'],
    elapsedMs: m['elapsed_ms'] as int?,
  );
}

class ModelActivity {
  const ModelActivity({
    required this.kind,
    required this.content,
    this.name = '',
    this.id = '',
    this.elapsedMs = 0,
    this.attempt = 1,
  });
  final String kind, content, name, id;
  final int elapsedMs, attempt;
  Map<String, Object?> toMap() => {
    'kind': kind,
    'content': content,
    'name': name,
    'id': id,
    'elapsed_ms': elapsedMs,
    'attempt': attempt,
  };
  factory ModelActivity.fromMap(Map<String, dynamic> m) => ModelActivity(
    kind: m['kind'] as String,
    content: m['content'] as String,
    name: m['name'] as String? ?? '',
    id: m['id'] as String? ?? '',
    elapsedMs: m['elapsed_ms'] as int? ?? 0,
    attempt: m['attempt'] as int? ?? 1,
  );
}

class SamplePoint {
  const SamplePoint(this.seconds, this.tokensPerSecond);
  final double seconds, tokensPerSecond;
  Map<String, Object?> toMap() => {'seconds': seconds, 'tps': tokensPerSecond};
  factory SamplePoint.fromMap(Map<String, dynamic> m) => SamplePoint(
    (m['seconds'] as num).toDouble(),
    (m['tps'] as num).toDouble(),
  );
}

/// An original transport chunk, with timing measured from request start.
class ResponseChunk {
  const ResponseChunk({
    required this.elapsedMs,
    required this.base64,
    this.decodedText,
    this.sequence,
  });
  final int elapsedMs;
  final String base64;
  // Predecoded text retains UTF-8 continuity when a stored page starts mid-stream.
  final String? decodedText;
  final int? sequence;
  List<int> get bytes => base64Decode(base64);

  /// Transport capture uses padded base64. Counting bytes needs no allocation.
  int get byteLength => base64.isEmpty
      ? 0
      : base64.length * 3 ~/ 4 -
            (base64.endsWith('==')
                ? 2
                : base64.endsWith('=')
                ? 1
                : 0);
  Map<String, Object?> toMap() => {'elapsed_ms': elapsedMs, 'base64': base64};
  factory ResponseChunk.fromMap(Map<String, dynamic> row) => ResponseChunk(
    elapsedMs: row['elapsed_ms'] as int,
    base64: row['base64'] as String,
  );
}

class TrafficSecond {
  const TrafficSecond({
    required this.second,
    required this.bytes,
    required this.chunkCount,
  });
  final int second, bytes, chunkCount;
}

class StoredLogPage {
  const StoredLogPage({required this.seconds, required this.chunks});
  final List<int> seconds;
  final List<ResponseChunk> chunks;
}

/// One HTTP attempt. Authentication headers are redacted before capture.
class HttpExchange {
  const HttpExchange({
    required this.startedAt,
    required this.method,
    required this.url,
    required this.requestHeaders,
    required this.requestBody,
    required this.streamMode,
    this.statusCode,
    this.reasonPhrase,
    this.responseHeaders = const {},
    this.chunks = const [],
    this.durationMs,
    this.error = '',
    this.storedResponseBytes,
    this.storedChunkCount,
    this.secondSummaries = const [],
  });
  final int? storedResponseBytes, storedChunkCount;
  final List<TrafficSecond> secondSummaries;
  final String startedAt, method, url, requestBody, error;
  final bool streamMode;
  final Map<String, String> requestHeaders, responseHeaders;
  final int? statusCode, durationMs;
  final String? reasonPhrase;
  final List<ResponseChunk> chunks;
  int get responseBytes =>
      storedResponseBytes ??
      chunks.fold(0, (sum, chunk) => sum + chunk.byteLength);
  HttpExchange withChunks(List<ResponseChunk> value) => HttpExchange(
    startedAt: startedAt,
    method: method,
    url: url,
    requestHeaders: requestHeaders,
    requestBody: requestBody,
    streamMode: streamMode,
    statusCode: statusCode,
    reasonPhrase: reasonPhrase,
    responseHeaders: responseHeaders,
    chunks: value,
    durationMs: durationMs,
    error: error,
    storedResponseBytes: storedResponseBytes,
    storedChunkCount: storedChunkCount,
    secondSummaries: secondSummaries,
  );
  String get responseBody => utf8.decode(
    chunks.expand((chunk) => chunk.bytes).toList(),
    allowMalformed: true,
  );
  Map<String, Object?> toMap() => {
    'started_at': startedAt,
    'method': method,
    'url': url,
    'request_headers': requestHeaders,
    'request_body': requestBody,
    'stream_mode': streamMode,
    'status_code': statusCode,
    'reason_phrase': reasonPhrase,
    'response_headers': responseHeaders,
    'chunks': chunks.map((chunk) => chunk.toMap()).toList(),
    'duration_ms': durationMs,
    'error': error,
  };
  factory HttpExchange.fromMap(Map<String, dynamic> row) => HttpExchange(
    startedAt: row['started_at'] as String,
    method: row['method'] as String,
    url: row['url'] as String,
    requestHeaders: Map<String, String>.from(row['request_headers'] as Map),
    requestBody: row['request_body'] as String,
    streamMode: row['stream_mode'] as bool,
    statusCode: row['status_code'] as int?,
    reasonPhrase: row['reason_phrase'] as String?,
    responseHeaders: Map<String, String>.from(row['response_headers'] as Map),
    chunks: (row['chunks'] as List)
        .map((c) => ResponseChunk.fromMap(c as Map<String, dynamic>))
        .toList(),
    durationMs: row['duration_ms'] as int?,
    error: row['error'] as String? ?? '',
  );
}

class Diagnostic {
  const Diagnostic({
    required this.id,
    required this.upstreamId,
    required this.upstreamName,
    required this.model,
    required this.promptName,
    required this.prompt,
    required this.output,
    required this.startedAt,
    required this.durationMs,
    required this.firstByteMs,
    this.tcpConnectMs,
    required this.ttftMs,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.points,
    required this.retries,
    required this.error,
    this.streamMode = true,
    this.detectionMode = 'single',
    this.exchanges = const [],
    this.activities = const [],
  });
  final String id,
      upstreamId,
      upstreamName,
      model,
      promptName,
      prompt,
      output,
      startedAt,
      error;
  final int durationMs,
      firstByteMs,
      ttftMs,
      inputTokens,
      outputTokens,
      totalTokens;
  final int? tcpConnectMs, cacheReadTokens, cacheWriteTokens;
  final List<SamplePoint> points;
  final List<RetryEvent> retries;
  final bool streamMode;

  /// `single` is the original one-request stream check; `agent` is the
  /// multi-turn tool workflow.
  final String detectionMode;
  final List<HttpExchange> exchanges;
  final List<ModelActivity> activities;
  double? get cacheHitRate {
    final cached = cacheReadTokens;
    return cached == null || inputTokens <= 0 || cached > inputTokens
        ? null
        : cached / inputTokens;
  }

  double get averageTps =>
      durationMs == 0 ? 0 : outputTokens / (durationMs / 1000);
  double get averageLatencyMs => outputTokens == 0
      ? 0
      : (durationMs - ttftMs).clamp(0, durationMs) / outputTokens;

  factory Diagnostic.fromMap(Map<String, Object?> row) {
    final pointRows = jsonDecode(row['points'] as String) as List<dynamic>;
    final retryRows = jsonDecode(row['retries'] as String) as List<dynamic>;
    return Diagnostic(
      id: row['id'] as String,
      upstreamId: row['upstream_id'] as String,
      upstreamName: row['upstream_name'] as String,
      model: row['model'] as String,
      promptName: row['prompt_name'] as String,
      prompt: row['prompt'] as String,
      output: row['output'] as String,
      startedAt: row['started_at'] as String,
      durationMs: row['duration_ms'] as int,
      firstByteMs: row['first_byte_ms'] as int,
      tcpConnectMs: row['tcp_connect_ms'] as int?,
      ttftMs: row['ttft_ms'] as int,
      inputTokens: row['input_tokens'] as int,
      outputTokens: row['output_tokens'] as int,
      totalTokens: row['total_tokens'] as int,
      cacheReadTokens: row['cache_read_tokens'] as int?,
      cacheWriteTokens: row['cache_write_tokens'] as int?,
      points: pointRows
          .map((e) => SamplePoint.fromMap(e as Map<String, dynamic>))
          .toList(),
      retries: retryRows
          .map((e) => RetryEvent.fromMap(e as Map<String, dynamic>))
          .toList(),
      error: row['error'] as String,
      streamMode: row['stream_mode'] != 0,
      detectionMode: (row['detection_mode'] as String?) ?? 'single',
      exchanges: (jsonDecode(row['exchanges'] as String? ?? '[]') as List)
          .map((e) => HttpExchange.fromMap(e as Map<String, dynamic>))
          .toList(),
      activities: (jsonDecode(row['activities'] as String? ?? '[]') as List)
          .map((e) => ModelActivity.fromMap(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'upstream_id': upstreamId,
    'upstream_name': upstreamName,
    'model': model,
    'prompt_name': promptName,
    'prompt': prompt,
    'output': output,
    'started_at': startedAt,
    'duration_ms': durationMs,
    'first_byte_ms': firstByteMs,
    'tcp_connect_ms': tcpConnectMs,
    'ttft_ms': ttftMs,
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'total_tokens': totalTokens,
    'cache_read_tokens': cacheReadTokens,
    'cache_write_tokens': cacheWriteTokens,
    'points': jsonEncode(points.map((e) => e.toMap()).toList()),
    'retries': jsonEncode(retries.map((e) => e.toMap()).toList()),
    'error': error,
    'stream_mode': streamMode ? 1 : 0,
    'detection_mode': detectionMode,
    'exchanges': jsonEncode(exchanges.map((e) => e.toMap()).toList()),
    'activities': jsonEncode(activities.map((e) => e.toMap()).toList()),
  };
}

class RateMetrics {
  const RateMetrics({
    required this.requests,
    required this.tokens,
    required this.durationMs,
  });

  final int requests, tokens, durationMs;
  double get rpm => durationMs <= 0 ? 0 : requests * 60000 / durationMs;
  double get tpm => durationMs <= 0 ? 0 : tokens * 60000 / durationMs;
}
