import 'dart:convert';
import 'package:http/http.dart' as http;
import 'data.dart';
import 'cloud_endpoint.dart';

class CloudClient {
  CloudClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<String> uploadReport({
    required String apiBaseUrl,
    required String clientKey,
    required Diagnostic diagnostic,
    required String upstreamBaseUrl,
    RateMetrics? rates,
  }) async {
    final base = normalizeCloudApiUrl(apiBaseUrl);
    if (base.isEmpty || clientKey.trim().isEmpty) {
      throw ArgumentError('请先在全局设置中填写云端地址和 Client Key');
    }
    final uri = Uri.parse('$base/api/reports/upload');
    final parsedHost = Uri.tryParse(upstreamBaseUrl)?.host;
    final apiDomain = (parsedHost == null || parsedHost.isEmpty)
        ? upstreamBaseUrl
              .replaceFirst(RegExp(r'^https?://'), '')
              .split('/')
              .first
              .toLowerCase()
        : parsedHost.toLowerCase();
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json', 'X-Client-Key': clientKey},
      body: jsonEncode({
        'api_domain': apiDomain,
        'model': diagnostic.model,
        'prompt_name': diagnostic.promptName,
        'data': {
          'version': 1,
          'source': 'client',
          'upstream_name': diagnostic.upstreamName,
          'prompt': diagnostic.prompt,
          'output': diagnostic.output,
          'started_at': diagnostic.startedAt,
          'error': diagnostic.error,
          'detection_mode': diagnostic.detectionMode,
          'reasoning_effort': _reasoningEffort(diagnostic),
          'samples': diagnostic.points.map((point) => point.toMap()).toList(),
          'activities': diagnostic.activities
              .map((activity) => activity.toMap())
              .toList(),
          'retries': diagnostic.retries.map((retry) => retry.toMap()).toList(),
        },
        'metadata': {
          'upstream_name': diagnostic.upstreamName,
          'duration_ms': diagnostic.durationMs,
          'first_byte_ms': diagnostic.firstByteMs,
          'tcp_connect_ms': diagnostic.tcpConnectMs,
          'ttft_ms': diagnostic.ttftMs,
          'input_tokens': diagnostic.inputTokens,
          'output_tokens': diagnostic.outputTokens,
          'total_tokens': diagnostic.totalTokens,
          'tokens_per_second': diagnostic.averageTps,
          'average_latency_ms': diagnostic.averageLatencyMs,
          'cache_read_tokens': diagnostic.cacheReadTokens,
          'cache_write_tokens': diagnostic.cacheWriteTokens,
          'cache_hit_rate': diagnostic.cacheHitRate,
          'retry_count': diagnostic.retries.length,
          'rpm': rates?.rpm,
          'tpm': rates?.tpm,
          'status': diagnostic.error.isEmpty ? 'success' : 'error',
          'detection_mode': diagnostic.detectionMode,
        },
      }),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>? ?? {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? '云端上传失败 (${response.statusCode})');
    }
    final ownerUrl = body['owner_url'] as String?;
    if (ownerUrl == null) throw const FormatException('云端未返回报告页面地址');
    return ownerUrl;
  }

  String _reasoningEffort(Diagnostic diagnostic) {
    // Extract the scalar setting locally; request bodies and headers stay local.
    if (diagnostic.exchanges.isEmpty) return 'unknown';
    try {
      final body = jsonDecode(diagnostic.exchanges.first.requestBody);
      if (body is! Map) return 'unknown';
      final reasoning = body['reasoning'];
      final value = reasoning is Map
          ? reasoning['effort']
          : body['reasoning_effort'];
      return value is String ? value : 'default';
    } on FormatException {
      return 'unknown';
    }
  }
}
