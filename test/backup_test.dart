import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'duckdb_test_support.dart';
import 'package:aijiance/db.dart';
import 'package:aijiance/data.dart';
import 'package:aijiance/channel_proxy.dart';

void main() {
  test(
    'backup merges atomically and preserves full transport, activities and settings',
    () async {
      final directory = await Directory.systemTemp.createTemp('ai-backup-');
      final db = LocalDb(
        supportDirectory: () async => directory,
        libraryPath: duckdbTestLibrary,
      );
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      const up = Upstream(
        id: 'u',
        name: '渠道',
        baseUrl: 'https://example.com',
        apiKey: 'secret',
        models: ['m'],
        proxy: ChannelProxy(type: 'socks5', host: 'localhost', port: 1081),
      );
      await db.saveUpstream(up);
      await db.setSetting('retry_count', '4');
      final record = Diagnostic(
        id: 'd',
        upstreamId: 'u',
        upstreamName: '渠道',
        model: 'm',
        promptName: '题目',
        prompt: '问题',
        output: '<p>答案</p>',
        startedAt: '2026-11-16T00:00:00.000',
        durationMs: 3200,
        firstByteMs: 30,
        tcpConnectMs: 1234,
        ttftMs: 50,
        inputTokens: 100,
        outputTokens: 20,
        totalTokens: 120,
        cacheReadTokens: 30,
        cacheWriteTokens: 5,
        points: const [
          SamplePoint(0, 20),
          SamplePoint(1, 0),
          SamplePoint(2, 0),
          SamplePoint(3, 0),
        ],
        retries: [RetryEvent(DateTime(2026), 'HTTP 503', 1, elapsedMs: 20)],
        error: '',
        activities: const [ModelActivity(kind: 'thinking', content: '推理')],
        exchanges: [
          HttpExchange(
            startedAt: '2026-11-16',
            method: 'POST',
            url: 'https://example.com',
            requestHeaders: const {},
            requestBody: '{}',
            streamMode: true,
            chunks: [
              ResponseChunk(
                elapsedMs: 30,
                base64: base64Encode(utf8.encode('data: 原文\n\n')),
              ),
            ],
          ),
        ],
      );
      await db.saveDiagnostic(record);
      final source = await db.exportBackup();
      final parsed = BackupData.parse(source);
      expect(parsed.tables['upstreams']!.single['api_key'], 'secret');
      await db.deleteUpstream('u');
      await db.saveUpstream(
        const Upstream(
          id: 'other',
          name: '另一个',
          baseUrl: 'x',
          apiKey: 'x',
          models: [],
        ),
      );
      await db.setSetting('retry_count', '0');
      await db.importBackup(source);
      expect(await db.setting('retry_count'), '4');
      expect(await db.upstreams(), hasLength(2));
      final restored = (await db.diagnostic('d'))!;
      expect(restored.toMap(), record.toMap());
      final beforeFiles = await directory
          .list()
          .where((f) => f.path.contains('before-import'))
          .toList();
      expect(beforeFiles, hasLength(1));
      final before = BackupData.parse(
        await File(beforeFiles.single.path).readAsString(),
      );
      expect(before.tables['settings']!.single['value'], '0');

      final broken = jsonDecode(source) as Map<String, dynamic>;
      broken['settings'] = [
        {'key': 'retry_count', 'value': '99'},
      ];
      await expectLater(
        db.importBackup(jsonEncode(broken)),
        throwsFormatException,
      );
      expect(await db.setting('retry_count'), '4');
      // A database failure after earlier tables changed rolls the whole import back.
      await db.execute("""
        CREATE TABLE limited_prompts (id VARCHAR PRIMARY KEY, name VARCHAR,
          content VARCHAR CHECK (content != '触发回滚'));
        INSERT INTO limited_prompts SELECT * FROM prompts;
        DROP TABLE prompts;
        ALTER TABLE limited_prompts RENAME TO prompts;
      """);
      final altered = jsonDecode(source) as Map<String, dynamic>;
      altered['upstreams'][0]['name'] = '不得保留';
      altered['prompts'][0]['content'] = '触发回滚';
      await expectLater(
        db.importBackup(jsonEncode(altered)),
        throwsA(isA<StateError>()),
      );
      expect((await db.upstreams()).firstWhere((u) => u.id == 'u').name, '渠道');
      expect(
        (await db.upstreams()).firstWhere((u) => u.id == 'u').proxy.toMap(),
        up.proxy.toMap(),
      );
    },
  );

  test(
    'rejects corrupt versions, incomplete tables and duplicate identifiers',
    () {
      final root = {
        'format': 'ai-channel-diagnostics',
        'version': 1,
        'upstreams': [],
        'prompts': [],
        'settings': [],
        'diagnostics': [],
      };
      expect(() => BackupData.parse('{}'), throwsFormatException);
      expect(
        () => BackupData.parse(jsonEncode({...root, 'version': 2})),
        throwsFormatException,
      );
      expect(
        () => BackupData.parse(jsonEncode({...root}..remove('diagnostics'))),
        throwsFormatException,
      );
      expect(
        () => BackupData.parse(
          jsonEncode({
            ...root,
            'settings': [
              {'key': 'prompt', 'value': 'a'},
              {'key': 'prompt', 'value': 'b'},
            ],
          }),
        ),
        throwsFormatException,
      );
    },
  );
}
