import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:aijiance/data.dart';
import 'package:aijiance/diagnostic_report.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final diagnostic = Diagnostic(
    id: 'run-1',
    upstreamId: 'upstream-1',
    upstreamName: '测试渠道',
    model: 'test-model',
    promptName: '智力测试',
    prompt: 'solve this',
    output: '```html\n<div>答案 <strong>正确</strong></div>\n```',
    startedAt: '2026-11-16T10:00:00.704298',
    durationMs: 2500,
    firstByteMs: 120,
    tcpConnectMs: 34,
    ttftMs: 210,
    inputTokens: 10,
    outputTokens: 25,
    totalTokens: 35,
    cacheReadTokens: 4,
    cacheWriteTokens: 2,
    points: const [SamplePoint(0, 0), SamplePoint(1, 12)],
    retries: const [],
    error: '',
    exchanges: [
      HttpExchange(
        startedAt: '2026-11-16T10:00:00.000',
        method: 'POST',
        url: 'https://example.test/v1/chat',
        requestHeaders: const {'content-type': 'application/json'},
        requestBody: '{"model":"test-model"}',
        streamMode: true,
        statusCode: 200,
        responseHeaders: const {'content-type': 'text/event-stream'},
        chunks: [
          ResponseChunk(
            elapsedMs: 200,
            base64: base64Encode(utf8.encode('data: answer')),
          ),
        ],
        durationMs: 2500,
      ),
    ],
  );

  test('HTML report includes metrics, curve and rendered output', () async {
    final html = await diagnosticHtml(
      diagnostic,
      rates: const RateMetrics(requests: 2, tokens: 900, durationMs: 60000),
    );
    expect(html, contains('缓存读取'));
    final document = html_parser.parse(html);
    expect(document.querySelector('body > p')!.text, '2026-11-16 10:00:00');
    expect(html, contains('<th>请求时间</th><td>2026-11-16 10:00:00</td>'));
    expect(
      document.querySelector('iframe')!.attributes['srcdoc'],
      contains('<div>答案 <strong>正确</strong></div>'),
    );
    expect(html, contains('时间 (s)'));
    expect(html, contains('Token/s'));
    expect(html, isNot(contains('```html')));
    expect(html, contains('首 Token 延时'));
    expect(html, contains('0.21 s'));
    expect(html, contains('<th>首字节延时</th><td>0.12 s</td>'));
    expect(html, contains('<th>平均 RPM</th><td>2.0 req/min</td>'));
    expect(html, contains('<th>平均 TPM</th><td>900 token/min</td>'));
    expect(document.querySelector('script[data-report-chart]'), isNotNull);
    expect(html, contains('每秒吞吐曲线'));
    expect(html, isNot(contains('Request headers')));
    expect(html, isNot(contains('height:720px')));
    expect(document.querySelector('iframe')!.attributes['scrolling'], 'no');
    final preview = html_parser.parse(
      document.querySelector('iframe')!.attributes['srcdoc']!,
    );
    expect(preview.querySelector('script')!.text, contains('ResizeObserver'));
    expect(html, contains('event.source!==frame.contentWindow'));
    expect(document.querySelectorAll('table'), hasLength(1));
    expect(document.querySelectorAll('.x-tick'), hasLength(2));
    expect(document.querySelectorAll('.y-tick').map((e) => e.text), [
      '0',
      '5',
      '10',
      '15',
    ]);
    expect(document.querySelector('circle title')!.text, '0.00 s · 0 token/s');
    expect(html.indexOf('每秒吞吐曲线'), lessThan(html.indexOf('<h2>模型输出')));
    expect(diagnostic.toMap(), isNot(contains('rating')));
  });

  test('HTML report distinguishes unreported reads from zero writes', () async {
    final result = Diagnostic.fromMap({
      ...diagnostic.toMap(),
      'cache_read_tokens': null,
      'cache_write_tokens': 0,
    });
    final html = await diagnosticHtml(result);
    expect(html, contains('<th>缓存读取</th><td>未上报</td>'));
    expect(html, contains('<th>缓存写入</th><td>0</td>'));
    expect(html, contains('<th>缓存命中率</th><td>N/A</td>'));
  });

  const finalReply =
      '已创建 [《穿门而过》HTML 动画](pelican-palace.html)。\n\n'
      '鹈鹕全程坐在车座上踩踏，进门前向前屈颈。\n\n'
      '按你的要求，未运行测试。';
  const artifact =
      '<!doctype html><html><head><title>穿门而过</title></head>'
      '<body><h1>动画成品</h1><svg id="animation"></svg>'
      '<script>document.body.dataset.ready="yes";</script></body></html>';

  test(
    'Agent report uses the latest artifact independently of assistant text',
    () async {
      for (final output in [
        finalReply,
        '$finalReply\n$artifact',
        '$finalReply\n<html><body>过时的内联页面</body></html>',
      ]) {
        final record = Diagnostic.fromMap({
          ...diagnostic.toMap(),
          'detection_mode': 'agent',
          'output': output,
          'activities': jsonEncode([
            const ModelActivity(
              kind: 'html_artifact',
              content: '<h1>初稿</h1>',
            ).toMap(),
            const ModelActivity(
              kind: 'html_artifact',
              content: artifact,
            ).toMap(),
            const ModelActivity(kind: 'output', content: finalReply).toMap(),
          ]),
        });
        final report = await diagnosticHtml(record);
        final document = html_parser.parse(report);
        final frame = document.querySelector('iframe[data-model-preview]')!;
        final preview = html_parser.parse(frame.attributes['srcdoc']!);
        expect(
          document.querySelectorAll('iframe[data-model-preview]'),
          hasLength(1),
        );
        expect(preview.querySelector('h1')!.text, '动画成品');
        expect(preview.querySelector('#animation'), isNotNull);
        expect(
          preview.querySelector('script')!.text,
          contains('dataset.ready'),
        );
        expect(preview.querySelector('pre'), isNull);
        expect(report, isNot(contains('已创建')));
        expect(report, isNot(contains('未运行测试')));
        expect(report, isNot(contains('初稿')));
        expect(report, isNot(contains('过时的内联页面')));
      }
    },
  );

  test(
    'legacy reports isolate inline HTML from surrounding commentary',
    () async {
      for (final output in [
        '$finalReply\n$artifact\n结束说明',
        '开头说明\n```html\n$artifact\n```\n$finalReply',
      ]) {
        final record = Diagnostic.fromMap({
          ...diagnostic.toMap(),
          'output': output,
        });
        final report = await diagnosticHtml(record);
        final frame = html_parser.parse(report).querySelector('iframe')!;
        final preview = html_parser.parse(frame.attributes['srcdoc']!);
        expect(preview.querySelector('h1')!.text, '动画成品');
        expect(preview.querySelector('pre'), isNull);
        expect(report, isNot(contains('已创建')));
        expect(report, isNot(contains('开头说明')));
        expect(report, isNot(contains('结束说明')));
      }
    },
  );

  test('plain text remains visible when the model generated no HTML', () async {
    final record = Diagnostic.fromMap({
      ...diagnostic.toMap(),
      'output': finalReply,
    });
    final report = html_parser.parse(await diagnosticHtml(record));
    expect(report.querySelector('iframe'), isNull);
    expect(report.querySelector('.rendered-output pre')!.text, finalReply);
  });

  test(
    'long curves keep every sample and limit overlapping axis labels',
    () async {
      final record = Diagnostic.fromMap({
        ...diagnostic.toMap(),
        'points': jsonEncode(
          List.generate(
            181,
            (i) => SamplePoint(i.toDouble(), (i % 17 * 100).toDouble()).toMap(),
          ),
        ),
      });
      final document = html_parser.parse(await diagnosticHtml(record));
      expect(document.querySelectorAll('.x-tick'), hasLength(8));
      expect(document.querySelectorAll('.x-tick').last.text, '180.00');
      expect(document.querySelectorAll('circle'), hasLength(181));
      expect(document.querySelectorAll('.y-tick').last.text, '2,000');
      expect(document.querySelectorAll('table'), hasLength(1));
    },
  );

  test('empty and zero curves have distinct integer ticks', () async {
    for (final points in [
      [],
      [const SamplePoint(0, 0).toMap()],
    ]) {
      final record = Diagnostic.fromMap({
        ...diagnostic.toMap(),
        'points': jsonEncode(points),
      });
      final document = html_parser.parse(await diagnosticHtml(record));
      expect(document.querySelectorAll('.y-tick').map((e) => e.text), [
        '0',
        '1',
      ]);
    }
  });
}
