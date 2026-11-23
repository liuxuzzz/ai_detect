import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aijiance/cloud_client.dart';
import 'package:aijiance/data.dart';

class _Client extends http.BaseClient {
  http.BaseRequest? request;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode('{"slug":"abc","owner_url":"https://cloud/r/abc"}'),
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  test('uploads structured data with client key and API domain', () async {
    final client = _Client();
    final cloud = CloudClient(client: client);
    final d = Diagnostic(
      id: 'd',
      upstreamId: 'u',
      upstreamName: 'test',
      model: 'demo',
      promptName: 'p',
      prompt: 'prompt',
      output: '<p>ok</p>',
      startedAt: DateTime.now().toIso8601String(),
      durationMs: 100,
      firstByteMs: 10,
      tcpConnectMs: 8,
      ttftMs: 20,
      inputTokens: 1,
      outputTokens: 2,
      totalTokens: 3,
      cacheReadTokens: 1,
      cacheWriteTokens: 0,
      points: const [SamplePoint(0, 0), SamplePoint(0.25, 8)],
      retries: [
        RetryEvent(
          DateTime.utc(2026, 11, 20),
          'fixture retry',
          2,
          elapsedMs: 50,
        ),
      ],
      activities: const [
        ModelActivity(kind: 'thinking', content: 'plan', elapsedMs: 10),
      ],
      exchanges: const [
        HttpExchange(
          startedAt: '2026-11-20T00:00:00Z',
          method: 'POST',
          url: 'https://api.example.com/v1/responses',
          requestHeaders: {'Authorization': 'Bearer PRIVATE-TEST-CREDENTIAL'},
          requestBody:
              '{"reasoning":{"effort":"high"},"input":"PRIVATE-RAW-REQUEST"}',
          streamMode: true,
        ),
      ],
      error: '',
    );
    final url = await cloud.uploadReport(
      apiBaseUrl: 'https://cloud.example/',
      clientKey: 'aij_test',
      diagnostic: d,
      upstreamBaseUrl: 'https://API.Example.com/v1',
      rates: const RateMetrics(requests: 2, tokens: 900, durationMs: 60000),
    );
    expect(url, 'https://cloud/r/abc');
    expect(
      client.request!.url.toString(),
      'https://cloud.example/api/reports/upload',
    );
    expect(client.request!.headers['X-Client-Key'], 'aij_test');
    final body = jsonDecode((client.request! as http.Request).body);
    expect(body['api_domain'], 'api.example.com');
    expect(body['model'], 'demo');
    expect(body.containsKey('html'), isFalse);
    expect(body['data']['version'], 1);
    expect(body['data']['output'], '<p>ok</p>');
    expect(body['data']['prompt'], 'prompt');
    expect(body['data']['samples'], [
      {'seconds': 0, 'tps': 0},
      {'seconds': 0.25, 'tps': 8},
    ]);
    expect(body['data']['activities'][0]['content'], 'plan');
    expect(body['data']['retries'][0]['elapsed_ms'], 50);
    expect(body['data']['reasoning_effort'], 'high');
    expect(body['data'].containsKey('exchanges'), isFalse);
    expect((client.request! as http.Request).body, isNot(contains('PRIVATE-')));

    expect(body['metadata'], containsPair('tcp_connect_ms', 8));
    expect(body['metadata'], containsPair('cache_read_tokens', 1));
    expect(body['metadata'], containsPair('cache_write_tokens', 0));
    expect(body['metadata'], containsPair('cache_hit_rate', 1.0));
    expect(body['metadata'], containsPair('retry_count', 1));
    expect(body['metadata'], containsPair('rpm', 2.0));
    expect(body['metadata'], containsPair('tpm', 900.0));
    await cloud.uploadReport(
      apiBaseUrl: 'http://192.0.2.10:6600/',
      clientKey: 'aij_test',
      diagnostic: d,
      upstreamBaseUrl: 'https://api.example.com/v1',
    );
    expect(
      client.request!.url.toString(),
      'http://192.0.2.10:6600/api/reports/upload',
    );
  });
}
