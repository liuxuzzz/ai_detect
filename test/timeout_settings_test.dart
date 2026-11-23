import 'dart:io';

import 'package:aijiance/db.dart';
import 'package:aijiance/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'duckdb_test_support.dart';

void main() {
  for (final (stored, expected) in [(null, 3600), ('60', 3600), ('34', 34)]) {
    test('upgrades legacy idle timeout $stored to $expected', () async {
      final directory = await Directory.systemTemp.createTemp('idle-upgrade-');
      LocalDb open() => LocalDb(
        supportDirectory: () async => directory,
        libraryPath: duckdbTestLibrary,
      );
      var db = open();
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });
      if (stored != null) await db.setSetting('idle_timeout', stored);
      await db.setSetting('connection_timeout', '17');
      await db.execute(
        "DELETE FROM store_metadata WHERE key = 'stream_idle_timeout_60_minutes_v1'",
      );
      await db.close();
      db = open();
      final settings = await HarnessSettings.load(db);
      expect(settings.idleTimeout, expected);
      expect(settings.connectionTimeout, 17);

      // An explicit choice made after upgrading must survive future launches.
      await db.setSetting('idle_timeout', '60');
      await db.close();
      db = open();
      expect((await HarnessSettings.load(db)).idleTimeout, 60);
    });
  }
}
