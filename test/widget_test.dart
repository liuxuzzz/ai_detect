import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
import 'package:aijiance/main.dart';
import 'package:aijiance/data.dart';
import 'package:aijiance/db.dart';
import 'package:aijiance/diagnostics_service.dart';
import 'package:aijiance/agent_tools.dart';
import 'package:aijiance/model_output.dart';
import 'package:aijiance/throughput_chart.dart';
import 'package:aijiance/settings.dart';
import 'package:aijiance/formatters.dart';
import 'package:fl_chart/fl_chart.dart';

const _upstream = Upstream(
  id: 'u',
  name: 'test',
  baseUrl: 'https://example.com/v1',
  apiKey: 'key',
  models: ['model'],
  selectedModel: 'model',
);
const _prompt = TestPrompt(id: 'p', name: 'test', content: '  原样发送我的提示词\n');

class _TestClient extends http.BaseClient {
  _TestClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

class _MemoryDb extends LocalDb {
  _MemoryDb({
    this.configured = false,
    this.extraUpstreams = const [],
    this.records = const [],
  });
  final List<Upstream> extraUpstreams;
  final List<Diagnostic> records;
  final bool configured;
  final saved = <Diagnostic>[];
  int diagnosticReads = 0;
  final settings = <String, String>{};
  @override
  Future<List<Upstream>> upstreams() async =>
      configured ? [_upstream, ...extraUpstreams] : [];
  @override
  Future<List<TestPrompt>> prompts() async => configured ? [_prompt] : [];
  @override
  Future<void> saveDiagnostic(Diagnostic d) async => saved.add(d);
  @override
  Future<List<Map<String, Object?>>> history() async =>
      [...saved.reversed, ...records].map((d) => d.toMap()).toList();
  @override
  Future<Diagnostic?> diagnostic(String id) async =>
      [...saved, ...records].where((d) => d.id == id).firstOrNull;
  @override
  Future<DiagnosticRead?> diagnosticRead(
    String id, {
    bool includeChunks = true,
  }) async {
    diagnosticReads++;
    final record = await diagnostic(id);
    return record == null ? null : DiagnosticRead(diagnostic: record);
  }

  @override
  Future<Map<String, RateMetrics>> rates() async => {};
  @override
  Future<String?> setting(String key) async => settings[key];
  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }
}

class _HtmlAgentService extends DiagnosticsService {
  final done = Completer<StreamResult>();

  @override
  Future<StreamResult> agent({
    required Upstream upstream,
    required TestPrompt prompt,
    required AgentToolRuntime runtime,
    required void Function(int) onTcpConnected,
    required void Function(String) onText,
    DiagnosticCancellation? cancellation,
    void Function(HttpExchange)? onExchange,
    void Function(ModelActivity)? onActivity,
    void Function(String)? onHtml,
    Duration connectionTimeout = const Duration(seconds: 45),
    Duration idleTimeout = const Duration(seconds: 60),
    String reasoningEffort = 'default',
    int maxRounds = 8,
  }) async {
    onText('准备创建');
    onHtml?.call('<h1>初始页面</h1>');
    onHtml?.call('<h1>最终页面</h1>');
    onText('创建完成');
    return done.future;
  }
}

Diagnostic _record(
  String id, {
  String upstream = 'u',
  List<HttpExchange> exchanges = const [],
  List<SamplePoint> points = const [SamplePoint(1, 10)],
  List<RetryEvent> retries = const [],
}) => Diagnostic(
  id: id,
  upstreamId: upstream,
  upstreamName: upstream == 'u' ? 'test' : 'second-channel',
  model: 'model',
  promptName: '历史提示词-$id',
  prompt: '历史问题-$id',
  output: '历史输出-$id\n```html\n<p>页面-$id</p>\n```',
  startedAt: '2026-11-15T12:00:00.000',
  durationMs: 1234,
  firstByteMs: 10,
  ttftMs: 20,
  inputTokens: 20,
  outputTokens: 10,
  totalTokens: 30,
  cacheReadTokens: 5,
  cacheWriteTokens: 2,
  points: points,
  retries: retries,
  error: '',
  exchanges: exchanges,
);

HttpExchange _exchange({
  bool streaming = true,
  String body = 'data: [DONE]\n\n',
  String error = '',
}) => HttpExchange(
  startedAt: '2026-11-15T12:00:00.000',
  method: 'POST',
  url: 'https://example.com/v1/chat/completions',
  requestHeaders: const {'Authorization': '[已隐藏]'},
  requestBody: '{"messages":[{"role":"user","content":"历史问题"}]}',
  streamMode: streaming,
  statusCode: 200,
  responseHeaders: const {'x-request-id': 'history-req'},
  chunks: [
    ResponseChunk(elapsedMs: 100, base64: base64Encode(utf8.encode(body))),
  ],
  durationMs: 1234,
  error: error,
);

void main() {
  testWidgets(
    'GPT single-mode HTML renders after reasoning and remains available in history',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const html =
          '<!doctype html><html><body><h1>GPT 页面</h1><script>document.title = "demo";</script></body></html>';
      final gpt = Upstream(
        id: 'gpt',
        name: 'GPT channel',
        baseUrl: _upstream.baseUrl,
        apiKey: 'key',
        models: const ['gpt-6.2-sol'],
        selectedModel: 'gpt-6.2-sol',
      );
      final db = _MemoryDb(configured: true, extraUpstreams: [gpt]);
      db.settings['detection_mode'] = 'single';
      final service = DiagnosticsService(
        client: _TestClient((request) async {
          expect(request.url.path, '/v1/responses');
          final events = [
            {
              'type': 'response.reasoning_summary_text.delta',
              'output_index': 0,
              'summary_index': 0,
              'delta': '先规划页面',
            },
            {
              'type': 'response.output_text.delta',
              'output_index': 1,
              'content_index': 0,
              'delta': '```html\n${html.substring(0, 40)}',
            },
            {
              'type': 'response.output_text.delta',
              'output_index': 1,
              'content_index': 0,
              'delta': '${html.substring(40)}\n```',
            },
            {
              'type': 'response.completed',
              'response': {'status': 'completed', 'output': []},
            },
          ];
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                events.map((e) => 'data: ${jsonEncode(e)}\n\n').join(),
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(database: db, diagnostics: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('GPT channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(db.saved.single.error, isEmpty);
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      expect(
        tester.widget<HtmlPagePreview>(find.byType(HtmlPagePreview)).source,
        '$html\n',
      );
      await tester.tap(find.text('源代码'));
      await tester.pumpAndSettle();
      expect(find.text('$html\n'), findsOneWidget);
      await tester.tap(find.text('渲染预览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检测指标'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('实时输出'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('history-${db.saved.single.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'thinking-only truncated run stores actual token usage and an error without retrying',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1120, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(configured: true);
      db.settings['detection_mode'] = 'single';
      var requests = 0;
      final service = DiagnosticsService(
        client: _TestClient((_) async {
          requests++;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                'data: {"choices":[{"delta":{"content":"","reasoning_content":"思考中的草稿代码"}}]}\n\n'
                'data: {"choices":[{"delta":{"content":"","reasoning_content":null},"finish_reason":"length"}],"usage":{"prompt_tokens":603,"completion_tokens":65536,"total_tokens":66139,"completion_tokens_details":{"reasoning_tokens":65536}}}\n\n'
                'data: [DONE]\n\n',
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(database: db, diagnostics: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final saved = db.saved.single;
      expect(requests, 1);
      expect(saved.output, isEmpty);
      expect(saved.error, contains('finish_reason=length'));
      expect(saved.inputTokens, 603);
      expect(saved.outputTokens, 65536);
      expect(saved.totalTokens, 66139);
      expect(find.text('本次仅收到思考过程，未收到正文'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('output-error'))).data,
        contains('已达到输出 token 上限'),
      );
      expect(find.text('检测完成（含错误）'), findsOneWidget);
      await tester.tap(find.text('test').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('history-${saved.id}')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('output-error'))).data,
        contains('已达到输出 token 上限'),
      );
      await tester.tap(find.text('检测指标'));
      await tester.pumpAndSettle();
      expect(find.text('65,536 token'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('DeepSeek max and custom effort persist and reach the upstream', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const deepseek = Upstream(
      id: 'deepseek',
      baseUrl: 'https://example.com/v1',
      apiKey: 'key',
      name: 'DeepSeek channel',
      models: ['deepseek-reasoner'],
      selectedModel: 'deepseek-reasoner',
    );
    final db = _MemoryDb(configured: true, extraUpstreams: [deepseek]);
    db.settings['detection_mode'] = 'single';
    final requests = <Map<String, dynamic>>[];
    final service = DiagnosticsService(
      client: _TestClient((request) async {
        requests.add(
          jsonDecode((request as http.Request).body) as Map<String, dynamic>,
        );
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
        );
      }),
    );
    addTearDown(service.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HarnessHome(database: db, diagnostics: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek channel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择推理强度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最大 (max)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始 AI 检测'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(requests.single['reasoning_effort'], 'max');
    await tester.tap(find.byTooltip('选择推理强度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'vendor-deep');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(db.settings['reasoning:deepseek:deepseek-reasoner'], 'vendor-deep');
    await tester.tap(find.text('test').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek channel').first);
    await tester.pumpAndSettle();
    expect(find.text('自定义 (vendor-deep)'), findsOneWidget);
    await tester.tap(find.text('开始 AI 检测'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(requests.last['reasoning_effort'], 'vendor-deep');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'running channel can browse history without streaming overwriting it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(
        configured: true,
        records: [
          _record('old', exchanges: [_exchange()]),
        ],
      );
      db.settings['detection_mode'] = 'single';
      final body = StreamController<List<int>>();
      final service = DiagnosticsService(
        client: _TestClient(
          (_) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(database: db, diagnostics: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.pump();
      await tester.tap(find.text('test').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-old')));
      await tester.pumpAndSettle();
      expect(find.text('历史输出-old\n'), findsOneWidget);
      expect(find.text('停止检测'), findsOneWidget);
      body.add(
        utf8.encode('data: {"choices":[{"delta":{"content":"后台输出"}}]}\n\n'),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('历史输出-old\n'), findsOneWidget);
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(
        find.text('{"messages":[{"role":"user","content":"历史问题"}]}'),
        findsOneWidget,
      );
      await tester.tap(find.text('返回当前测试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('实时输出'));
      await tester.pumpAndSettle();
      expect(find.text('后台输出'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-old')));
      await tester.pumpAndSettle();
      body.add(utf8.encode('data: [DONE]\n\n'));
      await tester.runAsync(() => body.close());
      await tester.pumpAndSettle();
      expect(db.saved.single.output, '后台输出');
      expect(find.text('历史输出-old\n'), findsOneWidget);
      await tester.tap(find.text('返回最近测试'));
      await tester.pumpAndSettle();
      expect(find.text('后台输出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('each channel retains its history and selected workspace tab', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const second = Upstream(
      id: 'u2',
      name: 'second-channel',
      baseUrl: 'https://example.com/v1',
      apiKey: 'key',
      models: ['model'],
      selectedModel: 'model',
    );
    final db = _MemoryDb(
      configured: true,
      extraUpstreams: [second],
      records: [
        _record('a'),
        _record('b', upstream: 'u2'),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: HarnessHome(database: db)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('test').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检测指标'));
    await tester.pumpAndSettle();
    expect(find.text('30 token'), findsOneWidget);
    await tester.tap(find.text('second-channel').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('诊断详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('test').first);
    await tester.pumpAndSettle();
    expect(find.text('30 token'), findsOneWidget);
    expect(find.text('历史输出-a\n'), findsNothing);
    await tester.tap(find.text('second-channel').first);
    await tester.pumpAndSettle();
    expect(find.text('无原始请求记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Agent artifact stays rendered during streaming, completion and history',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(configured: true);
      final service = _HtmlAgentService();
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(database: db, diagnostics: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      expect(
        tester.widget<HtmlPagePreview>(find.byType(HtmlPagePreview)).source,
        '<h1>最终页面</h1>',
      );
      service.done.complete(const StreamResult(output: '准备创建创建完成'));
      await tester.pumpAndSettle();
      final saved = db.saved.single;
      expect(saved.output, '准备创建创建完成');
      expect(
        saved.activities.where((a) => a.kind == 'html_artifact'),
        hasLength(1),
      );
      expect(
        saved.activities.singleWhere((a) => a.kind == 'html_artifact').content,
        '<h1>最终页面</h1>',
      );
      expect(saved.detectionMode, 'agent');
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      await tester.tap(find.text('test').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('history-${saved.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      expect(
        tester.widget<HtmlPagePreview>(find.byType(HtmlPagePreview)).source,
        '<h1>最终页面</h1>',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings shows about, version, project and sharing help', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'AI质量检测',
      packageName: 'com.example.aijiance',
      version: '0.1.2',
      buildNumber: '3',
      buildSignature: '',
    );
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: HarnessHome(database: _MemoryDb())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全局设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://ai_detect.wv.gs/'), findsOneWidget);
    await tester.ensureVisible(find.text('关于'));
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.text('关于 AI质量检测'), findsOneWidget);
    expect(find.text('版本 v0.1.2'), findsOneWidget);
    expect(
      find.text('https://github.com/liuxuzzz/ai_detect.git'),
      findsOneWidget,
    );
    expect(find.textContaining('首个公开版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stop stream retains output and allows a new test', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = _MemoryDb(configured: true);
    final body = StreamController<List<int>>();
    var requests = 0;
    var aborted = false;
    final service = DiagnosticsService(
      client: _TestClient((request) async {
        requests++;
        expect(jsonDecode((request as http.Request).body)['messages'], [
          {'role': 'user', 'content': _prompt.content},
        ]);
        if (requests == 1) {
          unawaited(
            (request as http.AbortableRequest).abortTrigger!.then(
              (_) => aborted = true,
            ),
          );
          return http.StreamedResponse(body.stream, 200);
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode('data: {"choices":[{"delta":{"content":"完成"}}]}\n\n'),
          ),
          200,
        );
      }),
    );
    addTearDown(service.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HarnessHome(database: db, diagnostics: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始 AI 检测'));
    await tester.pump();
    body.add(
      utf8.encode('data: {"choices":[{"delta":{"content":"保留这段输出"}}]}\n\n'),
    );
    await tester.pump();
    expect(find.text('停止检测'), findsOneWidget);
    await tester.tap(find.text('停止检测'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(aborted, isTrue);
    expect(find.text('已停止'), findsOneWidget);
    expect(db.saved.single.error, '用户已停止');
    expect(db.saved.single.exchanges.single.error, '用户已停止');
    expect(db.saved.single.exchanges.single.requestBody, contains('原样发送'));
    expect(db.saved.single.retries, isEmpty);
    expect(db.saved.single.output, '保留这段输出');
    await tester.pump(const Duration(seconds: 1));
    expect(requests, 1);
    await tester.tap(find.text('开始 AI 检测'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(db.saved.last.error, isEmpty);
    expect(db.saved.last.exchanges.single.responseBody, contains('完成'));
    expect(find.text('完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
    unawaited(body.close());
    await tester.pump();
  });

  testWidgets('stop during retry delay prevents the next request', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = _MemoryDb(configured: true);
    var requests = 0;
    final service = DiagnosticsService(
      client: _TestClient((_) async {
        requests++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('unavailable')),
          503,
        );
      }),
    );
    addTearDown(service.close);
    await tester.pumpWidget(
      MaterialApp(
        home: HarnessHome(database: db, diagnostics: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始 AI 检测'));
    await tester.pump();
    expect(requests, 1);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.tap(find.text('停止检测'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(requests, 1);
    expect(db.saved.single.error, '用户已停止');
    expect(db.saved.single.retries, hasLength(1));
    expect(db.saved.single.exchanges.single.statusCode, 503);
    expect(db.saved.single.exchanges.single.responseBody, 'unavailable');
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(1440, 900), const Size(1120, 698)]) {
    testWidgets('metrics fit at ${size.width} with axis units', (tester) async {
      final db = _MemoryDb();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: HarnessHome(database: db)));
      await tester.pumpAndSettle();
      expect(find.text('AI 检测工作区'), findsOneWidget);
      await tester.tap(find.text('检测指标'));
      await tester.pumpAndSettle();
      for (final label in [
        '首 token 延时',
        '平均吞吐',
        '总 token',
        '输入 token',
        '输出 token',
        '平均 RPM',
        '平均 TPM',
        '时间 (秒)',
        '吞吐 (token/s)',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('收起侧栏'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('当前测试：Stream'), findsNothing);
    });
  }

  testWidgets(
    'channel histories open output and original request/response without changing global prompt',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1120, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const second = Upstream(
        id: 'u2',
        name: 'second-channel',
        baseUrl: 'https://example.com/v1',
        apiKey: 'key',
        models: ['model'],
        selectedModel: 'model',
      );
      final db = _MemoryDb(
        configured: true,
        extraUpstreams: [second],
        records: [
          _record('a', exchanges: [_exchange()]),
          _record('b'),
          _record('c', upstream: 'u2'),
        ],
      );
      await tester.pumpWidget(MaterialApp(home: HarnessHome(database: db)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test').first);
      await tester.pumpAndSettle();
      expect(find.text('检测历史 · 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-c')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('history-a')));
      await tester.pumpAndSettle();
      expect(find.text('历史输出-a\n'), findsOneWidget);
      expect(find.text('历史记录'), findsNothing);
      final export = find.byKey(const ValueKey('export-html'));
      expect(export, findsOneWidget);
      expect(tester.widget<OutlinedButton>(export).onPressed, isNotNull);
      expect(
        tester.getTopLeft(export).dx,
        greaterThan(tester.getTopLeft(find.text('模型输出')).dx),
      );
      await tester.tap(find.text('源代码'));
      await tester.pumpAndSettle();
      expect(find.text('<p>页面-a</p>\n'), findsOneWidget);
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(export, findsNothing);
      expect(
        find.text('{"messages":[{"role":"user","content":"历史问题"}]}'),
        findsOneWidget,
      );
      await tester.tap(find.text('Response'));
      await tester.pumpAndSettle();
      expect(find.text('data: [DONE]\n\n'), findsOneWidget);
      expect(find.text('x-request-id: history-req'), findsOneWidget);
      await tester.tap(find.text('Stream 分片'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('data: [DONE]\n\n'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('data: [DONE]\n\n'), findsOneWidget);
      await tester.tap(find.text('实时输出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检测指标'));
      await tester.pumpAndSettle();
      expect(find.text('30 token'), findsOneWidget);
      expect(db.diagnosticReads, 1);
      await tester.tap(find.byKey(const ValueKey('history-b')));
      await tester.pumpAndSettle();
      expect(find.text('历史输出-b\n'), findsOneWidget);
      expect(find.text('历史输出-a\n'), findsNothing);
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(find.text('无原始请求记录'), findsOneWidget);
      await tester.tap(find.text('实时输出'));
      await tester.pumpAndSettle();
      final channel = find.text('second-channel');
      await tester.ensureVisible(channel);
      await tester.pumpAndSettle();
      await tester.tap(channel);
      await tester.pumpAndSettle();
      expect(find.text('检测历史 · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-a')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('history-c')));
      await tester.pumpAndSettle();
      expect(find.text('历史输出-c\n'), findsOneWidget);
      expect(
        db.settings['prompt'],
        isNull,
      ); // History viewing keeps the global test prompt.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'request details update live while receiving and survive retry persistence',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(configured: true);
      final body = StreamController<List<int>>();
      var requests = 0;
      final service = DiagnosticsService(
        client: _TestClient((_) async {
          requests++;
          return requests == 1
              ? http.StreamedResponse(
                  Stream.value(utf8.encode('retry-body')),
                  503,
                )
              : http.StreamedResponse(
                  body.stream,
                  200,
                  headers: {'x-request-id': 'live-req'},
                );
        }),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(database: db, diagnostics: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(requests, 2);
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 次请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 2 次请求').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Response'));
      await tester.pumpAndSettle();
      expect(find.text('x-request-id: live-req'), findsOneWidget);
      const event =
          'data: {"choices":[{"delta":{"content":"live-answer"}}]}\n\n';
      body.add(utf8.encode(event));
      await tester.pumpAndSettle();
      expect(find.text(event), findsOneWidget);
      await tester.tap(find.text('实时输出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止检测'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(db.saved.single.exchanges, hasLength(2));
      expect(db.saved.single.exchanges.first.responseBody, 'retry-body');
      expect(db.saved.single.exchanges.last.responseBody, event);
      expect(db.saved.single.exchanges.last.error, '用户已停止');
      await tester.tap(find.text('test').first);
      await tester.pumpAndSettle();
      expect(find.text('检测历史 · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      unawaited(body.close());
      await tester.pump();
    },
  );

  test('diagnostic persistence keeps exchanges, accepts legacy rows', () {
    final record = _record(
      'roundtrip',
      exchanges: [
        _exchange(),
        _exchange(
          streaming: false,
          body: '{"error":"failed"}',
          error: 'failed',
        ),
      ],
    );
    final restored = Diagnostic.fromMap(record.toMap());
    expect(restored.exchanges, hasLength(2));
    expect(restored.exchanges.first.responseBody, 'data: [DONE]\n\n');
    expect(restored.exchanges.last.error, 'failed');
    expect(restored.exchanges.last.responseBody, '{"error":"failed"}');
    expect(
      Diagnostic.fromMap(record.toMap()..remove('exchanges')).exchanges,
      isEmpty,
    );
  });

  test(
    'average rates use cumulative duration rather than averaging per-run rates',
    () {
      // A 10s run and a 50s run are two requests in one minute.
      const rates = RateMetrics(requests: 2, tokens: 900, durationMs: 60000);
      expect(rates.rpm, 2);
      expect(rates.tpm, 900);
      const empty = RateMetrics(requests: 0, tokens: 0, durationMs: 0);
      expect(empty.rpm, 0);
      expect(empty.tpm, 0);
    },
  );
  test('numbers use US grouping and precise seconds', () {
    expect(numberText(1234567), '1,234,567.0');
    expect(numberText(1234567, decimals: 0), '1,234,567');
    expect(secondsText(1234), '1.23 s');
    expect(secondsText(10), '0.01 s');
  });

  testWidgets('channel history toggles and pages five records at a time', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = _MemoryDb(
      configured: true,
      records: List.generate(12, (i) => _record('page-$i')),
    );
    await tester.pumpWidget(MaterialApp(home: HarnessHome(database: db)));
    await tester.pumpAndSettle();
    expect(find.text('检测历史 · 12'), findsNothing);
    await tester.tap(find.text('test').first);
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      expect(find.byKey(ValueKey('history-page-$i')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('history-page-5')), findsNothing);
    await tester.tap(find.byTooltip('下一页历史'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-page-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('history-page-0')), findsNothing);
    await tester.tap(find.byTooltip('下一页历史'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-page-10')), findsOneWidget);
    expect(find.byKey(const ValueKey('history-page-11')), findsOneWidget);
    await tester.tap(find.text('test').first);
    await tester.pumpAndSettle();
    expect(find.text('检测历史 · 12'), findsNothing);
    await tester.tap(find.text('test').first);
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fault marker selects original attempt and retains chart range across tabs',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(
        configured: true,
        records: [
          _record(
            'fault',
            exchanges: [
              _exchange(error: 'failure one'),
              _exchange(error: 'failure two'),
            ],
            points: List.generate(
              101,
              (i) => SamplePoint(i.toDouble(), i.isEven ? 10 : 0),
            ),
            retries: [
              RetryEvent(DateTime(2026), 'failure two', 2, elapsedMs: 50000),
            ],
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp(home: HarnessHome(database: db)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-fault')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检测指标'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('放大曲线'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('放大曲线'));
      await tester.pumpAndSettle();
      final slider = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('chart-slider')),
      );
      slider.onChanged!(const RangeValues(40, 60));
      await tester.pumpAndSettle();
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.titlesData.bottomTitles.sideTitles.maxIncluded, isTrue);
      expect(chart.data.minX, 40);
      expect(chart.data.maxX, 60);
      expect(chart.data.lineBarsData.first.spots, hasLength(21));
      final faultBar = chart.data.lineBarsData[1];
      expect(faultBar.spots.single.x, 50);
      chart.data.lineTouchData.touchCallback!(
        FlTapUpEvent(TapUpDetails(kind: PointerDeviceKind.mouse)),
        LineTouchResponse(
          touchLocation: Offset.zero,
          touchChartCoordinate: Offset.zero,
          lineBarSpots: [
            TouchLineBarSpot(faultBar, 1, faultBar.spots.single, 0),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Request'), findsOneWidget);
      expect(find.text('第 2 次请求'), findsOneWidget);
      expect(find.text('failure two'), findsOneWidget);
      await tester.tap(find.text('故障与重试'));
      await tester.pumpAndSettle();
      expect(find.text('Request'), findsNothing);
      await tester.tap(find.text('failure two'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 次请求'), findsOneWidget);
      expect(find.text('Request'), findsOneWidget);
      await tester.tap(find.text('检测指标'));
      await tester.pumpAndSettle();
      final restored = tester.widget<RangeSlider>(
        find.byKey(const ValueKey('chart-slider')),
      );
      expect(restored.values, const RangeValues(40, 60));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'current throughput counts a rolling second and curve keeps fixed second buckets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(configured: true);
      final body = StreamController<List<int>>();
      final service = DiagnosticsService(
        client: _TestClient(
          (_) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(
            database: db,
            diagnostics: service,
            stopwatchFactory: tester.binding.clock.stopwatch,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.pump();
      await tester.tap(find.text('检测指标'));
      await tester.pump();
      expect(find.text('当前吞吐'), findsOneWidget);
      expect(find.text('0 token/s'), findsOneWidget);
      void emit(String text) => body.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': text},
              },
            ],
          })}\n\n',
        ),
      );
      emit('甲乙');
      await tester.pump(const Duration(milliseconds: 100));
      emit('丙丁');
      await tester.pump(const Duration(milliseconds: 100));
      // Count received tokens over a one-second window without extrapolating
      // a 100 ms fragment into an instantaneous tokens/second value.
      expect(find.text('4 token/s'), findsOneWidget);
      final partial = tester.widget<ThroughputChart>(
        find.byType(ThroughputChart),
      );
      expect(partial.points.single.tokensPerSecond, 4);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('2 token/s'), findsOneWidget);
      emit('戊己庚');
      await tester.pump(const Duration(milliseconds: 100));
      // The rolling window crosses a bucket boundary; the old fragments age
      // out while the new second's output is visible immediately.
      expect(find.text('3 token/s'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('0 token/s'), findsOneWidget);
      final chart = tester.widget<ThroughputChart>(
        find.byType(ThroughputChart),
      );
      expect(chart.points.map((p) => p.tokensPerSecond), [4, 3, 0]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0 token/s'), findsOneWidget);
      body.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'content': [
                    {'type': 'tool_result', 'tool_use_id': 'local-result', 'content': '本地工具读取的内容不属于模型输出'},
                  ],
                },
              },
            ],
          })}\n\n',
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('0 token/s'), findsOneWidget);
      await tester.tap(find.text('停止检测'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(db.saved.single.points.take(3).map((p) => p.tokensPerSecond), [
        4,
        3,
        0,
      ]);
      expect(db.saved.single.outputTokens, 7);
      unawaited(body.close());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'idle seconds are zero sampled and thinking and tool fragments persist in order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(configured: true);
      final body = StreamController<List<int>>();
      final service = DiagnosticsService(
        client: _TestClient(
          (_) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(
            database: db,
            diagnostics: service,
            stopwatchFactory: tester.binding.clock.stopwatch,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      await tester.pump();
      void emit(Map<String, dynamic> delta) => body.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {'delta': delta},
            ],
          })}\n\n',
        ),
      );
      emit({'reasoning_content': '推理开始'});
      await tester.pump(const Duration(milliseconds: 110));
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.text('推理开始'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('检测指标'));
      await tester.pump();
      final chart = tester.widget<ThroughputChart>(
        find.byType(ThroughputChart, skipOffstage: false),
      );
      expect(chart.points.map((p) => p.seconds), [0, 1, 2, 3]);
      expect(chart.points.first.tokensPerSecond, greaterThan(0));
      expect(chart.points.skip(1).every((p) => p.tokensPerSecond == 0), isTrue);
      await tester.tap(find.text('实时输出'));
      await tester.pump();
      emit({
        'tool_calls': [
          {
            'index': 0,
            'function': {'name': 'search', 'arguments': '{"q":'},
          },
        ],
      });
      emit({
        'tool_calls': [
          {
            'index': 0,
            'function': {'arguments': '"x"}'},
          },
        ],
      });
      emit({'content': '最终输出'});
      await tester.pump(const Duration(milliseconds: 110));
      expect(find.text('工具调用 · search'), findsOneWidget);
      expect(find.text('{"q":"x"}'), findsOneWidget);
      await tester.tap(find.text('停止检测'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final record = db.saved.single;
      expect(record.activities.map((e) => e.kind), [
        'thinking',
        'tool_call',
        'output',
      ]);
      expect(record.activities[1].content, '{"q":"x"}');
      expect(record.output, '最终输出');
      expect(record.ttftMs, lessThan(1000));
      expect(record.points.map((p) => p.seconds), [0, 1, 2, 3]);
      expect(record.points[1].tokensPerSecond, 0);
      unawaited(body.close());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('global settings validate and persist across reopening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = _MemoryDb();
    await tester.pumpWidget(MaterialApp(home: HarnessHome(database: db)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全局设置'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '-1');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('0–20，整数'), findsOneWidget);
    await tester.enterText(fields.at(0), '0');
    await tester.enterText(fields.at(1), '12');
    await tester.enterText(fields.at(2), '34');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    final config = await HarnessSettings.load(db);
    expect(config.retryCount, 0);
    expect(config.connectionTimeout, 12);
    expect(config.idleTimeout, 34);
    await tester.tap(find.text('全局设置'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(fields.at(0)).controller!.text, '0');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final retries in [0, 2]) {
    testWidgets('global retry count $retries controls number of attempts', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = _MemoryDb(configured: true)
        ..settings['retry_count'] = '$retries';
      var attempts = 0;
      final service = DiagnosticsService(
        client: _TestClient((_) async {
          attempts++;
          return http.StreamedResponse(
            Stream.value(utf8.encode('unavailable')),
            503,
          );
        }),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: HarnessHome(database: db, diagnostics: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始 AI 检测'));
      for (var i = 0; i <= retries; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(attempts, retries + 1);
      expect(db.saved.single.retries, hasLength(retries + 1));
      expect(db.saved.single.exchanges, hasLength(retries + 1));
      expect(tester.takeException(), isNull);
    });
  }
}
