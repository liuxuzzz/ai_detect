import 'dart:convert';

import 'package:aijiance/data.dart';
import 'package:aijiance/request_details.dart';
import 'package:aijiance/stream_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HttpExchange exchange(
  List<ResponseChunk> chunks, {
  int? duration = 1000,
  List<TrafficSecond> seconds = const [],
  int? storedCount,
}) => HttpExchange(
  startedAt: '2026-11-16T00:00:00',
  method: 'POST',
  url: 'https://example.test',
  requestHeaders: const {},
  requestBody: '{}',
  streamMode: true,
  statusCode: 200,
  chunks: chunks,
  durationMs: duration,
  secondSummaries: seconds,
  storedChunkCount: storedCount,
);
ResponseChunk chunk(int elapsed, String text) =>
    ResponseChunk(elapsedMs: elapsed, base64: base64Encode(utf8.encode(text)));
Finder scroller(String page) => find
    .descendant(
      of: find.byKey(PageStorageKey(page)),
      matching: find.byType(Scrollable),
    )
    .first;
Finder textContaining(String text) => find.byWidgetPredicate(
  (w) => w is Text && (w.data?.contains(text) ?? false),
);

Future<void> settleDecode(WidgetTester tester) async {
  await tester.pump();
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (find.text('加载中').evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) fail('decode timed out');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> wheel(
  WidgetTester tester,
  Finder view, {
  double delta = 450,
}) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(view),
      scrollDelta: Offset(0, delta),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> wheelUntilVisible(
  WidgetTester tester,
  Finder tail,
  Finder view,
) async {
  for (var i = 0; i < 500 && tail.evaluate().isEmpty; i++) {
    await wheel(tester, view);
  }
  expect(tail, findsOneWidget);
  await tester.ensureVisible(tail);
  await tester.pumpAndSettle();
}

Future<void> scrollToCount(
  WidgetTester tester,
  String page,
  String count,
) async {
  for (var i = 0; i < 500 && find.text(count).evaluate().isEmpty; i++) {
    await wheel(tester, scroller(page), delta: 350);
    if (find.text('加载中').evaluate().isNotEmpty) await settleDecode(tester);
  }
  expect(find.text(count), findsOneWidget);
}

Future<void> show(
  WidgetTester tester,
  ValueNotifier<List<HttpExchange>> notifier, {
  bool active = true,
  Future<StoredLogPage> Function(int, int?, int)? loadLogs,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: RequestDetailsView(
        exchanges: notifier,
        active: active,
        loadLogs: loadLogs,
      ),
    ),
  ),
);

void main() {
  test('transport byte count matches raw bytes', () {
    for (final text in ['', 'a', 'ab', 'abc', '中文😀']) {
      final value = chunk(0, text);
      expect(value.byteLength, utf8.encode(text).length);
      expect(exchange([value]).responseBytes, value.byteLength);
    }
  });

  testWidgets(
    'scrolling loads more second groups without buttons or nested scrollers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final notifier = ValueNotifier([
        exchange([
          for (var s = 0; s < 25; s++) ...[
            chunk(s * 2000 + 100, 'second-$s-A\n\n'),
            chunk(s * 2000 + 200, 'second-$s-B\n\n'),
          ],
        ]),
      ]);
      addTearDown(notifier.dispose);
      await show(tester, notifier);
      await tester.tap(find.text('Response'));
      await settleDecode(tester);
      expect(find.text('10 / 25 条秒日志'), findsOneWidget);
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.text('加载后续 10 条'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const PageStorageKey('response-body')),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
      await scrollToCount(tester, 'response-body', '20 / 25 条秒日志');
      await scrollToCount(tester, 'response-body', '25 / 25 条秒日志');
      await wheelUntilVisible(
        tester,
        textContaining('second-24-B'),
        scroller('response-body'),
      );
      await tester.tap(find.text('Stream 分片'));
      await settleDecode(tester);
      expect(find.text('10 / 25 条秒日志'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const PageStorageKey('stream-chunks')),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
      await scrollToCount(tester, 'stream-chunks', '25 / 25 条秒日志');
      expect(find.text('加载后续 10 条'), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      final offset = tester
          .state<ScrollableState>(scroller('stream-chunks'))
          .position
          .pixels;
      await tester.tap(find.text('Response'));
      await settleDecode(tester);
      expect(find.text('25 / 25 条秒日志'), findsOneWidget);
      await tester.tap(find.text('Stream 分片'));
      await settleDecode(tester);
      expect(
        tester
            .state<ScrollableState>(scroller('stream-chunks'))
            .position
            .pixels,
        offset,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '20000 chunks only decode requested ten seconds and preserve paused chart',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = base64Encode(utf8.encode('data: ${'x' * 256}\n\n'));
      final record = exchange(
        List.generate(
          20000,
          (i) => ResponseChunk(elapsedMs: i * 10, base64: value),
        ),
      );
      final notifier = ValueNotifier([record]);
      addTearDown(notifier.dispose);
      await show(tester, notifier, active: false);
      await tester.pumpAndSettle();
      expect(find.text('Request'), findsNothing);
      await show(tester, notifier);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stream 分片'));
      await settleDecode(tester);
      expect(find.text('10 / 200 条秒日志'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(Text).evaluate().length, lessThan(80));
      await tester.tap(find.byKey(const ValueKey('stream-chart-pause')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Response'));
      await settleDecode(tester);
      await scrollToCount(tester, 'response-body', '20 / 200 条秒日志');
      await tester.tap(find.text('Stream 分片'));
      await settleDecode(tester);
      expect(find.text('10 / 200 条秒日志'), findsOneWidget);
      expect(find.byKey(const ValueKey('stream-chart-resume')), findsOneWidget);
      await show(tester, notifier, active: false);
      notifier.value = [record];
      await tester.pumpAndSettle();
      await show(tester, notifier);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large single second has bounded text blocks and one outer scroll view',
    (tester) async {
      final notifier = ValueNotifier([
        exchange([chunk(0, '${'中文😀' * 3000}TAIL_AFTER_8192')]),
      ]);
      addTearDown(notifier.dispose);
      await show(tester, notifier);
      await tester.tap(find.text('Response'));
      await settleDecode(tester);
      final tail = textContaining('TAIL_AFTER_8192');
      await wheelUntilVisible(tester, tail, scroller('response-body'));
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        if (text.style?.fontFamily == 'monospace') {
          expect(text.data!.length, lessThanOrEqualTo(1024));
          expect(text.data, isNot(contains('�')));
        }
      }
      await tester.tap(find.text('Stream 分片'));
      await settleDecode(tester);
      await wheelUntilVisible(tester, tail, scroller('stream-chunks'));
      expect(find.text('1 / 1 条秒日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live seconds update and become available by scrolling', (
    tester,
  ) async {
    final first = [for (var i = 0; i < 10; i++) chunk(i * 1000, 'second-$i\n')];
    final notifier = ValueNotifier([exchange(first, duration: null)]);
    addTearDown(notifier.dispose);
    await show(tester, notifier);
    await tester.tap(find.text('Response'));
    await settleDecode(tester);
    notifier.value = [
      exchange([
        ...first,
        chunk(9500, 'CURRENT_SECOND\n'),
        chunk(10000, 'NEXT_SECOND\n'),
      ]),
    ];
    await settleDecode(tester);
    expect(find.text('10 / 11 条秒日志'), findsOneWidget);
    await wheelUntilVisible(
      tester,
      textContaining('CURRENT_SECOND'),
      scroller('response-body'),
    );

    await wheelUntilVisible(
      tester,
      textContaining('NEXT_SECOND'),
      scroller('response-body'),
    );
    expect(find.text('11 / 11 条秒日志'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stored logs query ten seconds near the bottom and reuse cached pages across tabs',
    (tester) async {
      final notifier = ValueNotifier([
        exchange(
          [],
          storedCount: 50,
          seconds: [
            for (var i = 0; i < 25; i++)
              TrafficSecond(second: i, bytes: 16, chunkCount: 2),
          ],
        ),
      ]);
      addTearDown(notifier.dispose);
      final cursors = <int?>[];
      Future<StoredLogPage> load(int attempt, int? after, int limit) async {
        cursors.add(after);
        final start = (after ?? -1) + 1;
        final end = (start + limit).clamp(0, 25);
        return StoredLogPage(
          seconds: [for (var i = start; i < end; i++) i],
          chunks: [
            for (var i = start; i < end; i++) ...[
              ResponseChunk(
                elapsedMs: i * 1000,
                base64: base64Encode(utf8.encode('$i-A\n')),
                decodedText: '$i-A\n',
                sequence: i * 2,
              ),
              ResponseChunk(
                elapsedMs: i * 1000 + 1,
                base64: base64Encode(utf8.encode('$i-B\n')),
                decodedText: '$i-B\n',
                sequence: i * 2 + 1,
              ),
            ],
          ],
        );
      }

      await show(tester, notifier, loadLogs: load);
      await tester.pumpAndSettle();
      expect(cursors, isEmpty);
      await tester.tap(find.text('Response'));
      await settleDecode(tester);
      expect(cursors, [null]);
      expect(find.text('10 / 25 条秒日志'), findsOneWidget);
      await scrollToCount(tester, 'response-body', '20 / 25 条秒日志');
      expect(cursors, [null, 9]);
      await tester.tap(find.text('Stream 分片'));
      await settleDecode(tester);
      expect(cursors, [null, 9]);
      expect(find.byType(StreamTrafficChart), findsOneWidget);
      expect(find.text('10 / 25 条秒日志'), findsOneWidget);
      await scrollToCount(tester, 'stream-chunks', '20 / 25 条秒日志');
      expect(cursors, [null, 9]); // Already fetched for Response.
      await scrollToCount(tester, 'stream-chunks', '25 / 25 条秒日志');
      expect(cursors, [null, 9, 19]);
      expect(find.text('25 / 25 条秒日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('UTF-8 characters split across chunks stay intact', (
    tester,
  ) async {
    final bytes = utf8.encode('中文😀');
    final notifier = ValueNotifier([
      exchange([
        ResponseChunk(elapsedMs: 0, base64: base64Encode(bytes.sublist(0, 2))),
        ResponseChunk(elapsedMs: 1, base64: base64Encode(bytes.sublist(2))),
      ]),
    ]);
    addTearDown(notifier.dispose);
    await show(tester, notifier);
    await tester.tap(find.text('Response'));
    await settleDecode(tester);
    expect(find.text('中文😀'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
