import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aijiance/data.dart';
import 'package:aijiance/agent_tools.dart';
import 'package:aijiance/diagnostics_service.dart';

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

const upstream = Upstream(
  id: 'u',
  name: 'test',
  baseUrl: 'https://example.com/v1',
  apiKey: 'key',
  models: [],
  selectedModel: 'model',
);
const prompt = TestPrompt(id: 'p', name: 'test', content: '  原样提示词\n');

void main() {
  test(
    'sends the selected prompt verbatim as a stream and parses usage',
    () async {
      final exchanges = <HttpExchange>[];
      final service = DiagnosticsService(
        tcpConnectProbe: (_, _) async => 17,
        client: _ScriptedClient((request) async {
          final body = jsonDecode((request as http.Request).body) as Map;
          expect(body['messages'], [
            {'role': 'user', 'content': prompt.content},
          ]);
          expect(body['stream'], isTrue);
          expect(body['stream_options']['include_usage'], isTrue);
          expect(
            body.keys,
            unorderedEquals(['model', 'messages', 'stream', 'stream_options']),
          );
          expect(request.headers['Accept'], 'text/event-stream');
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                'data: {"choices":[{"delta":{"content":"答案"}}]}\n\n'
                'data: {"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":5,"cache_creation_tokens":2}},"choices":[]}\n\n'
                'data: [DONE]\n\n',
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(service.close);
      final output = <String>[];
      int? tcpConnectMs;
      final result = await service.stream(
        upstream: upstream,
        prompt: prompt,
        onTcpConnected: (elapsedMs) => tcpConnectMs = elapsedMs,
        onText: output.add,
        onExchange: exchanges.add,
      );
      expect(result.output, '答案');
      expect(output, ['答案']);
      expect(tcpConnectMs, 17);
      expect(result.inputTokens, 12);
      expect(result.outputTokens, 3);
      expect(result.totalTokens, 15);
      expect(result.cacheReadTokens, 5);
      expect(result.cacheWriteTokens, 2);
      expect(exchanges.last.streamMode, isTrue);
      expect(exchanges.last.responseBody, contains('答案'));
    },
  );

  test(
    'distinguishes omitted cache usage from explicit zero and gateway hits',
    () async {
      final cases = [
        (usage: <String, dynamic>{}, read: null, write: null),
        (
          usage: {
            'prompt_tokens_details': {
              'cached_tokens': 0,
              'cache_write_tokens': 12,
            },
          },
          read: 0,
          write: 12,
        ),
        (
          usage: {
            'prompt_tokens_details': {'cached_tokens': null},
            'prompt_cache_hit_tokens': '17',
            'prompt_cache_miss_tokens': 9,
          },
          read: 17,
          write: null,
        ),
      ];
      for (final fixture in cases) {
        final service = DiagnosticsService(
          tcpConnectProbe: (_, _) async => 17,
          client: _ScriptedClient(
            (_) async => http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  'data: {"choices":[{"delta":{"content":"answer"}}]}\n\n'
                  'data: ${jsonEncode({'usage': fixture.usage})}\n\n'
                  'data: {"usage":{"completion_tokens":3}}\n\n'
                  'data: [DONE]\n\n',
                ),
              ),
              200,
            ),
          ),
        );
        addTearDown(service.close);
        final result = await service.stream(
          upstream: upstream,
          prompt: prompt,
          onTcpConnected: (_) {},
          onText: (_) {},
        );
        expect(result.cacheReadTokens, fixture.read);
        expect(result.cacheWriteTokens, fixture.write);
      }
    },
  );

  test(
    'cancels while waiting for response headers and captures the failure',
    () async {
      final token = DiagnosticCancellation();
      final headers = Completer<http.StreamedResponse>();
      var aborted = false;
      final exchanges = <HttpExchange>[];
      final service = DiagnosticsService(
        client: _ScriptedClient((request) async {
          unawaited(
            (request as http.AbortableRequest).abortTrigger!.then(
              (_) => aborted = true,
            ),
          );
          return headers.future;
        }),
      );
      addTearDown(service.close);
      final result = service.stream(
        upstream: upstream,
        prompt: prompt,
        onTcpConnected: (_) {},
        onText: (_) {},
        cancellation: token,
        onExchange: exchanges.add,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await expectLater(result, throwsA(isA<DiagnosticCancelled>()));
      expect(aborted, isTrue);
      expect(exchanges.last.error, '用户已停止');
      expect(exchanges.last.statusCode, isNull);
      headers.completeError(http.ClientException('late response'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('captures original SSE bytes and redacts secrets', () async {
    const raw =
        ': ping\r\ndata: {"choices":[{"delta":{"content":"你好"}}]}\r\n\r\ndata: [DONE]\n\n';
    final bytes = utf8.encode(raw);
    final split = bytes.indexOf(utf8.encode('你').first) + 1;
    final pieces = [
      bytes.sublist(0, split),
      bytes.sublist(split, split + 1),
      bytes.sublist(split + 1),
    ];
    final exchanges = <HttpExchange>[];
    final service = DiagnosticsService(
      client: _ScriptedClient((request) async {
        expect(request.headers['Authorization'], 'Bearer key');
        return http.StreamedResponse(
          Stream.fromIterable(pieces),
          200,
          reasonPhrase: 'OK',
          headers: {'x-request-id': 'req-123', 'set-cookie': 'private-cookie'},
        );
      }),
    );
    addTearDown(service.close);
    final result = await service.stream(
      upstream: upstream,
      prompt: prompt,
      onTcpConnected: (_) {},
      onText: (_) {},
      onExchange: exchanges.add,
    );
    final trace = exchanges.last;
    expect(result.output, '你好');
    expect(trace.url, 'https://example.com/v1/chat/completions');
    expect(trace.requestHeaders['Authorization'], '[已隐藏]');
    expect(trace.responseHeaders['set-cookie'], '[已隐藏]');
    expect(trace.responseHeaders['x-request-id'], 'req-123');
    expect(trace.responseBody, raw);
    expect(trace.responseBytes, bytes.length);
    expect(trace.chunks.map((chunk) => chunk.bytes), pieces);
    expect(trace.statusCode, 200);
    expect(trace.reasonPhrase, 'OK');
    expect(trace.durationMs, isNotNull);
    expect(trace.error, isEmpty);
  });

  test('captures upstream error body and status', () async {
    const body = '{"error":{"message":"rate limited"}}';
    final exchanges = <HttpExchange>[];
    final service = DiagnosticsService(
      client: _ScriptedClient(
        (_) async => http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          429,
          headers: {'retry-after': '2'},
        ),
      ),
    );
    addTearDown(service.close);
    await expectLater(
      service.stream(
        upstream: upstream,
        prompt: prompt,
        onTcpConnected: (_) {},
        onText: (_) {},
        onExchange: exchanges.add,
      ),
      throwsException,
    );
    expect(exchanges.last.statusCode, 429);
    expect(exchanges.last.responseBody, body);
    expect(exchanges.last.responseHeaders['retry-after'], '2');
    expect(exchanges.last.error, contains('429'));
  });

  test(
    'separates thinking and tool call fragments from visible output',
    () async {
      final activities = <ModelActivity>[];
      final service = DiagnosticsService(
        client: _ScriptedClient(
          (_) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                'data: {"choices":[{"delta":{"reasoning_content":"先推理","tool_calls":[{"index":0,"id":"call","function":{"name":"search","arguments":"{\\"q\\":"}}],"content":"答案"}}]}\n\n'
                'data: [DONE]\n\n',
              ),
            ),
            200,
          ),
        ),
      );
      addTearDown(service.close);
      final result = await service.stream(
        upstream: upstream,
        prompt: prompt,
        onTcpConnected: (_) {},
        onText: (_) {},
        onActivity: activities.add,
      );
      expect(result.output, '答案');
      expect(activities.map((event) => event.kind), ['thinking', 'tool_call']);
      expect(activities.first.content, '先推理');
      expect(activities.last.name, 'search');
    },
  );

  test(
    'Agent workflow executes HTML tool and returns its result to the model',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aijiance-agent-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      var requestCount = 0;
      final service = DiagnosticsService(
        tcpConnectProbe: (_, _) async => 1,
        client: _ScriptedClient((request) async {
          requestCount++;
          final body = jsonDecode((request as http.Request).body) as Map;
          expect(body['tools'], isNotEmpty);
          if (requestCount == 1) {
            expect(body['messages'].last['role'], 'user');
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"write_html_file","arguments":"{\\"path\\":\\"result.html\\",\\"content\\":\\"<h1>hi</h1>\\"}"}}]}}]}\n\n'
                  'data: [DONE]\n\n',
                ),
              ),
              200,
            );
          }
          expect(body['messages'].any((m) => m['role'] == 'tool'), isTrue);
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                'data: {"choices":[{"delta":{"content":"完成"}}]}\n\n'
                'data: [DONE]\n\n',
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(service.close);
      String? html;
      final result = await service.agent(
        upstream: upstream,
        prompt: prompt,
        runtime: AgentToolRuntime(root),
        onTcpConnected: (_) {},
        onText: (_) {},
        onHtml: (value) => html = value,
      );
      expect(requestCount, 2);
      expect(result.output, '完成');
      expect(html, '<h1>hi</h1>');
      expect(
        await File('${root.path}/result.html').readAsString(),
        '<h1>hi</h1>',
      );
    },
  );
}
