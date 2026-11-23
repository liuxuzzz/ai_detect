import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aijiance/agent_tools.dart';
import 'package:aijiance/data.dart';
import 'package:aijiance/diagnostics_service.dart';
import 'package:aijiance/model_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

const upstream = Upstream(
  id: 'u',
  name: 'OpenAI relay',
  baseUrl: 'https://example.test/v1/chat/completions',
  apiKey: 'secret',
  models: ['gpt-fixture'],
  selectedModel: 'gpt-fixture',
);
const prompt = TestPrompt(id: 'p', name: 'fixture', content: ' 原样提示词\n');

http.StreamedResponse sse(List<Map<String, dynamic>> events) {
  final bytes = utf8.encode(
    events
        .map(
          (event) =>
              'event: ${event['type']}\r\ndata: ${jsonEncode(event)}\r\n\r\n',
        )
        .join(),
  );
  return http.StreamedResponse(
    Stream.fromIterable([
      for (var i = 0; i < bytes.length; i += 7)
        bytes.sublist(i, (i + 7).clamp(0, bytes.length)),
    ]),
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

Map<String, dynamic> completed(List<Map<String, dynamic>> output) => {
  'type': 'response.completed',
  'response': {
    'status': 'completed',
    'error': null,
    'output': output,
    'usage': {
      'input_tokens': 20,
      'output_tokens': 5,
      'total_tokens': 25,
      'input_tokens_details': {'cached_tokens': 12},
      'cache_creation_input_tokens': 4,
    },
  },
};

Future<StreamResult> run(
  DiagnosticsService service, {
  void Function(String)? onText,
  void Function(ModelActivity)? onActivity,
  void Function(HttpExchange)? onExchange,
}) => service.stream(
  upstream: upstream,
  prompt: prompt,
  reasoningEffort: 'high',
  onTcpConnected: (_) {},
  onText: onText ?? (_) {},
  onActivity: onActivity,
  onExchange: onExchange,
);

void main() {
  test(
    'raw chunks keep the idle timeout alive during continuous Responses output',
    () async {
      late Future<StreamResult> running;
      late DiagnosticsService service;
      final exchanges = <HttpExchange>[];
      final time = FakeAsync();
      time.run((time) {
        final body = StreamController<List<int>>();
        final text = <String>[];
        service = DiagnosticsService(
          client: _Client(
            (_) async => http.StreamedResponse(
              body.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        Object? error;
        running = service.stream(
          upstream: upstream,
          prompt: prompt,
          onTcpConnected: (_) {},
          onText: text.add,
          onExchange: exchanges.add,
          idleTimeout: const Duration(seconds: 60),
        );
        running.then<void>(
          (_) {},
          onError: (Object value) {
            error = value;
          },
        );
        time.flushMicrotasks();
        void send(String value) {
          body.add(utf8.encode(value));
          time.flushMicrotasks();
        }

        // Several network chunks can form a single SSE event. Receiving bytes
        // must reset the timer even while its JSON/event is still incomplete.
        for (var event = 0; event < 3; event++) {
          send('data: {"type":"response.output_text.delta",');
          time.elapse(const Duration(seconds: 40));
          send('"output_index":0,"content_index":0,');
          time.elapse(const Duration(seconds: 40));
          send('"delta":"片段"}\n\n');
          time.elapse(const Duration(seconds: 40));
        }
        // A heartbeat is inbound traffic even though it contains no model text.
        send(': heartbeat\n\n');
        time.elapse(const Duration(seconds: 40));
        expect(text, ['片段', '片段', '片段']);
        expect(error, isNull);
        send(
          'data: ${jsonEncode(completed([
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '片段片段片段'},
              ],
            },
          ]))}\n\n',
        );
        unawaited(body.close());
        time.elapse(Duration.zero);
        time.flushMicrotasks();
        expect(error, isNull);
      });
      final result = await running;
      expect(result.output, '片段片段片段');
      expect(exchanges.last.error, isEmpty);
      service.close();
      expect(time.nonPeriodicTimerCount, 0);
    },
  );

  test(
    'idle timeout starts again after the most recent chunk and aborts a stalled stream',
    () {
      fakeAsync((time) {
        final body = StreamController<List<int>>();
        final exchanges = <HttpExchange>[];
        var aborted = false;
        final service = DiagnosticsService(
          client: _Client((request) async {
            unawaited(
              (request as http.AbortableRequest).abortTrigger!.then(
                (_) => aborted = true,
              ),
            );
            return http.StreamedResponse(body.stream, 200);
          }),
        );
        Object? error;
        service
            .stream(
              upstream: upstream,
              prompt: prompt,
              onTcpConnected: (_) {},
              onText: (_) {},
              onExchange: exchanges.add,
              idleTimeout: const Duration(seconds: 60),
            )
            .then<void>(
              (_) {},
              onError: (Object value) {
                error = value;
              },
            );
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 40));
        body.add(utf8.encode(': heartbeat\n\n'));
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 59));
        expect(error, isNull);
        time.elapse(const Duration(seconds: 1));
        expect(error, isA<TimeoutException>());
        expect(aborted, true);
        expect(exchanges.last.error, contains('已连续 60 秒未收到上游数据'));
        unawaited(body.close());
        time.flushMicrotasks();
        service.close();
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('selects Responses for OpenAI and normalizes model discovery URLs', () {
    for (final model in ['gpt-5', 'openai/gpt-5', 'o3', 'openai/o3']) {
      expect(modelApiFor(upstream.baseUrl, model), ModelApi.responses);
    }
    expect(
      modelApiFor('https://api.openai.com/v1', 'alias'),
      ModelApi.responses,
    );
    expect(
      modelApiFor('https://example.test/v1/responses/', 'alias'),
      ModelApi.responses,
    );
    expect(
      modelApiFor(upstream.baseUrl, 'deepseek-reasoner'),
      ModelApi.chatCompletions,
    );
    expect(
      upstreamEndpoint(
        'https://example.test/gateway/v1/responses/?tenant=x#test',
        'models',
      ).toString(),
      'https://example.test/gateway/v1/models?tenant=x',
    );
    expect(
      upstreamEndpoint('https://example.test', 'responses').path,
      '/v1/responses',
    );
  });

  test(
    'streams Responses text and reasoning once and reads nested cache usage',
    () async {
      final text = <String>[];
      final activities = <ModelActivity>[];
      final exchanges = <HttpExchange>[];
      final output = <Map<String, dynamic>>[
        {
          'type': 'reasoning',
          'summary': [
            {'type': 'summary_text', 'text': '先思考'},
          ],
        },
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': '你好 world'},
          ],
        },
      ];
      final service = DiagnosticsService(
        client: _Client((request) async {
          expect(request.url.path, '/v1/responses');
          expect(request.headers['Authorization'], 'Bearer secret');
          final body = jsonDecode((request as http.Request).body) as Map;
          expect(body['input'], [
            {'role': 'user', 'content': prompt.content},
          ]);
          expect(body['reasoning'], {'effort': 'high', 'summary': 'auto'});
          expect(body['store'], false);
          expect(body['stream'], true);
          for (final key in [
            'messages',
            'reasoning_effort',
            'stream_options',
          ]) {
            expect(body.containsKey(key), false);
          }
          return sse([
            {
              'type': 'response.created',
              'response': {'status': 'in_progress'},
            },
            {
              'type': 'response.reasoning_summary_text.delta',
              'output_index': 0,
              'summary_index': 0,
              'delta': '先思考',
            },
            {
              'type': 'response.reasoning_summary_text.done',
              'output_index': 0,
              'summary_index': 0,
              'text': '先思考',
            },
            {
              'type': 'response.output_text.delta',
              'output_index': 1,
              'content_index': 0,
              'delta': '你好 ',
            },
            {
              'type': 'response.output_text.done',
              'output_index': 1,
              'content_index': 0,
              'text': '你好 world',
            },
            completed(output),
          ]);
        }),
      );
      addTearDown(service.close);
      final result = await run(
        service,
        onText: text.add,
        onActivity: activities.add,
        onExchange: exchanges.add,
      );
      expect(result.output, '你好 world');
      expect(text.join(), result.output);
      expect(activities.map((e) => e.content), ['先思考']);
      expect(result.inputTokens, 20);
      expect(result.outputTokens, 5);
      expect(result.totalTokens, 25);
      expect(result.cacheReadTokens, 12);
      expect(result.cacheWriteTokens, 4);
      expect(result.responseOutput, output);
      expect(exchanges.last.url, 'https://example.test/v1/responses');
      expect(exchanges.last.error, isEmpty);
      expect(exchanges.last.requestHeaders['Authorization'], '[已隐藏]');
    },
  );

  test('reads a non-streaming JSON Responses result', () async {
    final payload = completed([
      {
        'type': 'message',
        'content': [
          {'type': 'output_text', 'text': 'JSON answer'},
        ],
      },
    ])['response'];
    final service = DiagnosticsService(
      client: _Client(
        (_) async => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(payload))),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(service.close);
    expect((await run(service)).output, 'JSON answer');
  });

  test(
    'rejects failed, incomplete, error and truncated Responses streams',
    () async {
      for (final terminal in [
        {
          'type': 'response.failed',
          'response': {
            'status': 'failed',
            'error': {'code': 'server_error'},
          },
        },
        {
          'type': 'response.incomplete',
          'response': {
            'status': 'incomplete',
            'incomplete_details': {'reason': 'max_output_tokens'},
          },
        },
        {'type': 'error', 'message': 'failed'},
        {'type': 'response.in_progress'},
      ]) {
        final service = DiagnosticsService(
          client: _Client(
            (_) async => sse([
              {'type': 'response.output_text.delta', 'delta': 'partial'},
              terminal,
            ]),
          ),
        );
        addTearDown(service.close);
        await expectLater(run(service), throwsFormatException);
      }
    },
  );

  test(
    'Agent replays encrypted reasoning, tool calls and function results',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aijiance-responses-agent-',
      );
      addTearDown(() => root.delete(recursive: true));
      var round = 0;
      final activities = <ModelActivity>[];
      const arguments = '{"path":"result.html","content":"<h1>hi</h1>"}';
      final reasoning = <String, dynamic>{
        'id': 'rs_1',
        'type': 'reasoning',
        'summary': [],
        'encrypted_content': 'encrypted-fixture',
      };
      final call = <String, dynamic>{
        'id': 'fc_1',
        'type': 'function_call',
        'call_id': 'call_1',
        'name': 'write_html_file',
        'arguments': arguments,
        'status': 'completed',
      };
      final service = DiagnosticsService(
        client: _Client((request) async {
          final body = jsonDecode((request as http.Request).body) as Map;
          expect(request.url.path, '/v1/responses');
          expect(body['tools'].first['name'], 'write_html_file');
          expect(body['tools'].first.containsKey('function'), false);
          expect(body['tools'].first['strict'], false);
          expect(body['include'], ['reasoning.encrypted_content']);
          if (++round == 1) {
            return sse([
              {
                'type': 'response.output_item.added',
                'output_index': 0,
                'item': reasoning,
              },
              {
                'type': 'response.output_item.added',
                'output_index': 1,
                'item': {...call, 'arguments': '', 'status': 'in_progress'},
              },
              {
                'type': 'response.function_call_arguments.delta',
                'output_index': 1,
                'item_id': 'fc_1',
                'delta': arguments.substring(0, 12),
              },
              {
                'type': 'response.function_call_arguments.delta',
                'output_index': 1,
                'item_id': 'fc_1',
                'delta': arguments.substring(12),
              },
              {
                'type': 'response.function_call_arguments.done',
                'output_index': 1,
                'arguments': arguments,
              },
              {
                'type': 'response.output_item.done',
                'output_index': 1,
                'item': call,
              },
              completed([reasoning, call]),
            ]);
          }
          final input = body['input'] as List;
          expect(input[1], reasoning);
          expect(input[2], call);
          expect(input.last['type'], 'function_call_output');
          expect(input.last['call_id'], 'call_1');
          expect(jsonDecode(input.last['output'])['ok'], true);
          return sse([
            completed([
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '完成'},
                ],
              },
            ]),
          ]);
        }),
      );
      addTearDown(service.close);
      final result = await service.agent(
        upstream: upstream,
        prompt: prompt,
        runtime: AgentToolRuntime(root),
        onTcpConnected: (_) {},
        onText: (_) {},
        onActivity: activities.add,
        reasoningEffort: 'high',
      );
      expect(round, 2);
      expect(result.output, '完成');
      expect(result.totalTokens, 50);
      expect(
        activities
            .where((e) => e.kind == 'tool_call')
            .map((e) => e.content)
            .join(),
        arguments,
      );
      expect(
        activities
            .where((e) => e.kind == 'tool_call')
            .map((e) => e.name)
            .join(),
        'write_html_file',
      );
      expect(
        await File('${root.path}/result.html').readAsString(),
        '<h1>hi</h1>',
      );
    },
  );

  test(
    'total test deadline aborts stalled response headers and records a timeout',
    () async {
      final pending = Completer<http.StreamedResponse>();
      var aborted = false;
      final exchanges = <HttpExchange>[];
      final service = DiagnosticsService(
        testTimeout: const Duration(milliseconds: 20),
        client: _Client((request) async {
          unawaited(
            (request as http.AbortableRequest).abortTrigger!.then(
              (_) => aborted = true,
            ),
          );
          return pending.future;
        }),
      );
      addTearDown(service.close);
      await expectLater(
        run(service, onExchange: exchanges.add),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(aborted, true);
      expect(exchanges.last.error, contains('测试超时'));
      pending.completeError(http.ClientException('late failure'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'Agent deadline interrupts a stalled stream with the timeout cause',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aijiance-agent-deadline-',
      );
      addTearDown(() => root.delete(recursive: true));
      final body = StreamController<List<int>>();
      addTearDown(() {
        unawaited(body.close());
      });
      final exchanges = <HttpExchange>[];
      final service = DiagnosticsService(
        testTimeout: const Duration(milliseconds: 20),
        client: _Client((_) async => http.StreamedResponse(body.stream, 200)),
      );
      addTearDown(service.close);
      await expectLater(
        service.agent(
          upstream: upstream,
          prompt: prompt,
          runtime: AgentToolRuntime(root),
          onTcpConnected: (_) {},
          onText: (_) {},
          onExchange: exchanges.add,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(exchanges.last.error, contains('测试超时'));
      expect(exchanges.last.error, isNot(contains('用户已停止')));
    },
  );
}
