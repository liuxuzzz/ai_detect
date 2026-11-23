import 'dart:convert';
import 'dart:io';

import 'package:aijiance/channel_proxy.dart';
import 'package:aijiance/data.dart';
import 'package:aijiance/db.dart';
import 'package:flutter_test/flutter_test.dart';

import 'duckdb_test_support.dart';

const channel = Upstream(
  id: 'key-channel',
  name: 'API Key 渠道',
  baseUrl: 'https://example.test/v1',
  apiKey: 'fixture-api-key',
  models: ['gpt-5', 'gpt-4.1'],
  selectedModel: 'gpt-5',
  reasoningModels: {'gpt-5'},
  reasoningConfigured: true,
  proxy: ChannelProxy(type: 'socks5', host: 'localhost', port: 1081),
  note: '保留渠道配置',
);

void main() {
  test(
    'legacy channel authentication is removed without losing configuration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ai-channel-auth-',
      );
      LocalDb open() => LocalDb(
        supportDirectory: () async => directory,
        libraryPath: duckdbTestLibrary,
      );
      var db = open();
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      final legacy = Upstream.fromMap({
        ...channel.toMap(),
        'id': 'legacy-channel',
        'name': '旧渠道',
        'api_key': 'fixture-access-token',
      });
      await db.saveUpstream(channel);
      await db.saveUpstream(legacy);
      await db.execute('''
      ALTER TABLE upstreams ADD COLUMN auth_type VARCHAR DEFAULT 'api_key';
      ALTER TABLE upstreams ADD COLUMN oauth_client_secret VARCHAR;
      ALTER TABLE upstreams ADD COLUMN oauth_refresh_token VARCHAR;
      ALTER TABLE upstreams ADD COLUMN oauth_expires_at BIGINT;
      UPDATE upstreams SET auth_type = 'oauth2',
        oauth_client_secret = 'fixture-client-secret',
        oauth_refresh_token = 'fixture-refresh-token', oauth_expires_at = 123
        WHERE id = 'legacy-channel';
    ''');
      await db.close();

      db = open();
      final restored = await db.upstreams();
      expect(
        restored.firstWhere((u) => u.id == channel.id).toMap(),
        channel.toMap(),
      );
      expect(
        restored.firstWhere((u) => u.id == legacy.id).toMap(),
        legacy.copyWith(apiKey: '').toMap(),
      );
      final columns = await db.query("PRAGMA table_info('upstreams')");
      expect(
        columns.map((c) => c['name']),
        isNot(anyElement(anyOf('auth_type', startsWith('oauth_')))),
      );
      await db.saveUpstream(legacy.copyWith(apiKey: 'replacement-api-key'));
      await db.close();
      db = open();
      expect(
        (await db.upstreams()).firstWhere((u) => u.id == legacy.id).apiKey,
        'replacement-api-key',
      );
    },
  );

  test('legacy backups discard browser tokens and keep API Key channels', () {
    final parsed = BackupData.parse(
      jsonEncode({
        'format': 'ai-channel-diagnostics',
        'version': 1,
        'upstreams': [
          {...channel.toMap(), 'auth_type': 'api_key'},
          {
            ...channel.toMap(),
            'id': 'legacy-channel',
            'auth_type': 'oauth2',
            'api_key': 'fixture-access-token',
            'oauth_refresh_token': 'fixture-refresh-token',
            'oauth_client_secret': 'fixture-client-secret',
          },
        ],
        'prompts': [],
        'settings': [],
        'diagnostics': [],
      }),
    );
    final rows = parsed.tables['upstreams']!;
    expect(rows.first, channel.toMap());
    expect(rows.last, {
      ...channel.toMap(),
      'id': 'legacy-channel',
      'api_key': '',
    });
    final cleaned = jsonEncode(rows);
    expect(cleaned, isNot(contains('oauth')));
    expect(cleaned, isNot(contains('fixture-access-token')));
    expect(cleaned, isNot(contains('fixture-refresh-token')));
    expect(cleaned, isNot(contains('fixture-client-secret')));
  });
}
