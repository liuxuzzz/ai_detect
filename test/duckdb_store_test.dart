import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aijiance/data.dart';
import 'package:aijiance/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

import 'duckdb_test_support.dart';

Diagnostic record(String id, List<ResponseChunk> chunks) => Diagnostic(
  id: id,
  upstreamId: 'channel',
  upstreamName: '渠道',
  model: 'model',
  promptName: '题目',
  prompt: '原始题目',
  output: '<p>结果</p>',
  startedAt: '2026-11-16T00:00:00',
  durationMs: 200000,
  firstByteMs: 35,
  tcpConnectMs: 20,
  ttftMs: 55,
  inputTokens: 100,
  outputTokens: 2000,
  totalTokens: 2100,
  cacheReadTokens: 30,
  cacheWriteTokens: 5,
  points: const [SamplePoint(0, 20), SamplePoint(1, 0), SamplePoint(2, 40)],
  retries: [RetryEvent(DateTime(2026), 'HTTP 503', 1, elapsedMs: 20)],
  error: '',
  activities: const [ModelActivity(kind: 'thinking', content: '推理')],
  exchanges: [
    HttpExchange(
      startedAt: '2026-11-16',
      method: 'POST',
      url: 'https://example.test',
      requestHeaders: const {'x-request': 'original'},
      requestBody: '{"prompt":"原始题目"}',
      streamMode: true,
      responseHeaders: const {'x-response': 'original'},
      statusCode: 200,
      chunks: chunks,
      durationMs: 200000,
    ),
  ],
);

void main() {
  test(
    'OLAP facts persist independently, range pages avoid full payload reads and reopen losslessly',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ai-duckdb-facts-',
      );
      LocalDb db = LocalDb(
        supportDirectory: () async => directory,
        libraryPath: duckdbTestLibrary,
      );
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      // A SQLite file is intentionally ignored. No migration path or legacy reader.
      await File(
        '${directory.path}/aijiance.sqlite',
      ).writeAsString('unused legacy data');
      final data = base64Encode(utf8.encode('data: ${'x' * 256}\n\n'));
      final chunks = List.generate(
        20000,
        (i) => ResponseChunk(elapsedMs: i * 10, base64: data),
      );
      final original = record('run', chunks);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 2),
        (_) => ticks++,
      );
      final saveWatch = Stopwatch()..start();
      await db.saveDiagnostic(original);
      saveWatch.stop();
      timer.cancel();
      expect(ticks, greaterThan(0));
      final columns = await db.query(
        "SELECT column_name FROM information_schema.columns WHERE table_name='diagnostics'",
      );
      expect(
        columns.map((c) => c['column_name']),
        isNot(contains('exchanges')),
      );
      expect(columns.map((c) => c['column_name']), isNot(contains('points')));
      expect(
        (await db.query(
          'SELECT COUNT(*) AS count FROM stream_chunks',
        )).single['count'],
        20000,
      );
      expect(
        (await db.query(
          'SELECT COUNT(*) AS count FROM traffic_seconds',
        )).single['count'],
        200,
      );
      expect(
        (await db.query(
          'SELECT COUNT(*) AS count FROM metric_samples',
        )).single['count'],
        3,
      );
      expect(
        (await db.query(
          'SELECT COUNT(*) AS count FROM retry_events',
        )).single['count'],
        1,
      );
      expect(
        (await db.query(
          'SELECT COUNT(*) AS count FROM model_activities',
        )).single['count'],
        1,
      );
      final overview = (await db.diagnosticRead(
        'run',
        includeChunks: false,
      ))!.diagnostic;
      expect(overview.exchanges.single.chunks, isEmpty);
      expect(overview.exchanges.single.storedChunkCount, 20000);
      expect(
        overview.exchanges.single.responseBytes,
        original.exchanges.single.responseBytes,
      );
      expect(overview.exchanges.single.secondSummaries, hasLength(200));
      expect(overview.points.map((p) => p.tokensPerSecond), [20, 0, 40]);
      final watch = Stopwatch()..start();
      final first = await db.logPage('run', 0);
      watch.stop();
      expect(first.seconds, List.generate(10, (i) => i));
      expect(first.chunks, hasLength(1000));
      expect(first.chunks.first.sequence, 0);
      expect(first.chunks.last.sequence, 999);
      final second = await db.logPage(
        'run',
        0,
        afterSecond: first.seconds.last,
      );
      expect(second.seconds, List.generate(10, (i) => i + 10));
      expect(second.chunks.first.sequence, 1000);
      expect(second.chunks.last.sequence, 1999);
      final last = await db.logPage('run', 0, afterSecond: 189);
      expect(last.seconds.last, 199);
      expect(last.chunks.last.sequence, 19999);
      expect((await db.logPage('run', 0, afterSecond: 199)).chunks, isEmpty);
      expect(first.chunks.first.bytes, chunks.first.bytes);
      expect(first.chunks.first.decodedText, utf8.decode(chunks.first.bytes));
      expect((await db.rates())['channel']!.tokens, 2100);
      expect((await db.history()).single.containsKey('output'), isFalse);
      // OLAP aggregation operates on numeric facts, without parsing a JSON blob.
      final analysis = await db.query(
        '''SELECT COUNT(*) AS seconds,
      SUM(inbound_bytes)::BIGINT AS bytes, SUM(chunk_count)::BIGINT AS chunks
      FROM traffic_seconds WHERE diagnostic_id = ?''',
        ['run'],
      );
      expect(analysis.single['bytes'], original.exchanges.single.responseBytes);
      expect(analysis.single['chunks'], 20000);
      await db.close();
      db = LocalDb(
        supportDirectory: () async => directory,
        libraryPath: duckdbTestLibrary,
      );
      final restored = (await db.diagnostic('run'))!;
      expect(
        restored.toMap()..remove('exchanges'),
        original.toMap()..remove('exchanges'),
      );
      final actualExchange = restored.exchanges.single;
      final expectedExchange = original.exchanges.single;
      expect(
        actualExchange.toMap()..remove('chunks'),
        expectedExchange.toMap()..remove('chunks'),
      );
      expect(actualExchange.chunks.length, expectedExchange.chunks.length);
      for (var i = 0; i < actualExchange.chunks.length; i++) {
        expect(
          actualExchange.chunks[i].elapsedMs,
          expectedExchange.chunks[i].elapsedMs,
          reason: 'chunk $i timing',
        );
        expect(
          actualExchange.chunks[i].base64,
          expectedExchange.chunks[i].base64,
          reason: 'chunk $i bytes',
        );
      }
      expect(
        await File('${directory.path}/aijiance.sqlite').readAsString(),
        'unused legacy data',
      );
      debugPrint(
        'DuckDB: 20,000 chunks / ${original.exchanges.single.responseBytes} bytes; bulk save ${saveWatch.elapsedMilliseconds}ms; first 10-second page ${watch.elapsedMilliseconds}ms; UI timer ticks $ticks',
      );
    },
  );

  test(
    'keyset pages cover sparse seconds and UTF-8 split across a page boundary',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ai-duckdb-unicode-',
      );
      final db = LocalDb(
        supportDirectory: () async => directory,
        libraryPath: duckdbTestLibrary,
      );
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      final utf = utf8.encode('中文😀');
      final chunks = [
        for (var i = 0; i < 9; i++)
          ResponseChunk(
            elapsedMs: i * 2000,
            base64: base64Encode(utf8.encode('log-$i\n')),
          ),
        ResponseChunk(
          elapsedMs: 18000,
          base64: base64Encode(utf.sublist(0, 2)),
        ),
        ResponseChunk(elapsedMs: 20000, base64: base64Encode(utf.sublist(2))),
      ];
      await db.saveDiagnostic(record('unicode', chunks));
      final first = await db.logPage('unicode', 0);
      expect(first.seconds, List.generate(10, (i) => i * 2));
      expect(first.chunks.last.decodedText, '');
      final next = await db.logPage('unicode', 0, afterSecond: 18);
      expect(next.seconds, [20]);
      expect(next.chunks.single.decodedText, '中文😀');
      final full = await db.fullExchange('unicode', 0);
      expect(
        full.responseBody,
        utf8.decode(chunks.expand((c) => c.bytes).toList()),
      );
      expect(full.requestHeaders['x-request'], 'original');
      expect(full.responseHeaders['x-response'], 'original');
      // Replacement is atomic and doesn't duplicate rows in any child fact table.
      await db.saveDiagnostic(record('unicode', chunks));
      expect(
        (await db.query('SELECT COUNT(*) AS n FROM stream_chunks')).single['n'],
        11,
      );
      expect(
        (await db.query(
          'SELECT COUNT(*) AS n FROM traffic_seconds',
        )).single['n'],
        11,
      );
      expect(
        (await db.query(
          'SELECT COUNT(*) AS n FROM metric_samples',
        )).single['n'],
        3,
      );
      expect(() => db.logPage('unicode', 0, limit: 0), throwsArgumentError);
    },
  );
}
