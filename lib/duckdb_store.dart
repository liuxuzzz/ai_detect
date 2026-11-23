import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_duckdb/dart_duckdb.dart' as duck;
import 'package:dart_duckdb/open.dart' as loader;

import 'data.dart';
import 'backup_data.dart';

/// A database connection, result conversion and bulk appends all live off the UI.
class DuckStore {
  DuckStore._();
  final _pending = <int, Completer<Object?>>{};
  final _responses = ReceivePort();
  final _errors = ReceivePort();
  final _ready = Completer<SendPort>();
  Isolate? _worker;
  int _sequence = 0;
  bool _closed = false;

  static Future<DuckStore> open(String path, {String? libraryPath}) async {
    final store = DuckStore._();
    store._responses.listen((dynamic message) {
      if (message is SendPort) {
        store._ready.complete(message);
        return;
      }
      final data = message as List;
      final id = data[0] as int;
      final completer = id == -1 ? null : store._pending.remove(id);
      if (data[1] == true) {
        completer?.complete(data[2]);
      } else {
        final error = data[2] == 'FormatException'
            ? FormatException(data[3] as String)
            : StateError(data[3] as String);
        final stack = StackTrace.fromString(data[4] as String);
        if (id == -1 && !store._ready.isCompleted) {
          store._ready.completeError(error, stack);
        } else {
          completer?.completeError(error, stack);
        }
      }
    });
    store._errors.listen((dynamic error) {
      final failure = StateError('DuckDB worker: $error');
      if (!store._ready.isCompleted) store._ready.completeError(failure);
      for (final pending in store._pending.values) {
        pending.completeError(failure);
      }
      store._pending.clear();
    });
    try {
      store._worker = await Isolate.spawn(
        _databaseWorker,
        (store._responses.sendPort, path, libraryPath),
        onError: store._errors.sendPort,
        debugName: 'AI渠道检测 DuckDB',
      );
      await store._ready.future;
      return store;
    } catch (_) {
      store._responses.close();
      store._errors.close();
      store._worker?.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Future<T> call<T>(String method, [Object? argument]) async {
    if (_closed) throw StateError('数据库已关闭');
    final port = await _ready.future;
    final id = _sequence++;
    final pending = Completer<Object?>();
    _pending[id] = pending;
    port.send([id, method, argument]);
    return (await pending.future) as T;
  }

  Future<void> close() async {
    if (_closed) return;
    await call<void>('close');
    _closed = true;
    _responses.close();
    _errors.close();
    _worker?.kill(priority: Isolate.beforeNextEvent);
  }
}

Future<void> _databaseWorker((SendPort, String, String?) config) async {
  final (reply, path, libraryPath) = config;
  final requests = ReceivePort();
  _DuckEngine? engine;
  try {
    if (libraryPath != null) {
      loader.open.overrideFor(
        Platform.isMacOS
            ? duck.OperatingSystem.macOS
            : Platform.isWindows
            ? duck.OperatingSystem.windows
            : duck.OperatingSystem.linux,
        libraryPath,
      );
    }
    engine = await _DuckEngine.open(path);
    reply.send(requests.sendPort);
    await for (final dynamic message in requests) {
      final data = message as List;
      final id = data[0] as int;
      final method = data[1] as String;
      try {
        final result = await engine.dispatch(method, data[2]);
        reply.send([id, true, result]);
        if (method == 'close') break;
      } catch (error, stack) {
        reply.send([
          id,
          false,
          error is FormatException ? 'FormatException' : 'DatabaseError',
          '$error',
          '$stack',
        ]);
      }
    }
  } catch (error, stack) {
    reply.send([-1, false, 'DatabaseError', '$error', '$stack']);
  } finally {
    requests.close();
    await engine?.close();
  }
}

class _DuckEngine {
  _DuckEngine(this.database, this.connection);
  final duck.Database database;
  final duck.Connection connection;
  bool _closed = false;

  static Future<_DuckEngine> open(String path) async {
    final database = await duck.duckdb.open(path, settings: {'threads': '4'});
    final connection = await duck.duckdb.connect(database);
    final engine = _DuckEngine(database, connection);
    try {
      for (final sql in _schema) {
        await connection.execute(sql);
      }
      await engine.removeLegacyChannelAuth();
      await engine.migrateIdleTimeout();
      return engine;
    } catch (_) {
      await engine.close();
      rethrow;
    }
  }

  Future<void> removeLegacyChannelAuth() async {
    final columns = await query("PRAGMA table_info('upstreams')");
    final obsolete = columns
        .map((column) => column['name'] as String)
        .where((name) => name == 'auth_type' || name.startsWith('oauth_'))
        .toList();
    if (obsolete.isEmpty) return;
    if (obsolete.contains('auth_type')) {
      // Commit the token cleanup before altering the table: DuckDB cannot
      // commit updates followed by column drops in the same transaction.
      // Both steps can safely run again if startup is interrupted.
      await execute(
        "UPDATE upstreams SET api_key = '' WHERE auth_type = 'oauth2'",
      );
    }
    await transaction(() async {
      for (final name in obsolete) {
        final quoted = name.replaceAll('"', '""');
        await execute('ALTER TABLE upstreams DROP COLUMN "$quoted"');
      }
    });
  }

  Future<void> migrateIdleTimeout() => transaction(() async {
    const migration = 'stream_idle_timeout_60_minutes_v1';
    final applied = await query(
      'SELECT value FROM store_metadata WHERE key = ?',
      [migration],
    );
    if (applied.isNotEmpty) return;
    // Earlier settings saves persisted the former 60-second default.
    // Upgrade it once so later, deliberate timeout choices remain intact.
    await execute(
      "UPDATE settings SET value = '3600' WHERE key = 'idle_timeout' AND trim(value) = '60'",
    );
    await insert('store_metadata', {'key': migration, 'value': '1'});
  });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await connection.dispose();
    await database.dispose();
  }

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    duck.PreparedStatement? statement;
    duck.ResultSet? result;
    try {
      if (args.isEmpty) {
        result = await connection.query(sql);
      } else {
        statement = await connection.prepare(sql);
        statement.bindParams(args);
        result = await statement.execute();
      }
      final columns = result.columnNames;
      final rows = <Map<String, Object?>>[];
      // Copy each row before advancing the native cursor: fetchAll() retains
      // BLOB views from chunks which the binding releases while fetching later
      // chunks. Copying only after fetchAll() is already too late.
      for (var row = result.fetchOne(); row != null; row = result.fetchOne()) {
        rows.add({
          for (var i = 0; i < columns.length; i++)
            columns[i]: row[i] is Uint8List
                ? Uint8List.fromList(row[i] as Uint8List)
                : row[i],
        });
      }
      return rows;
    } finally {
      await result?.dispose();
      await statement?.dispose();
    }
  }

  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    if (args.isEmpty) {
      await connection.execute(sql);
    } else {
      await query(sql, args);
    }
  }

  Future<T> transaction<T>(Future<T> Function() action) async {
    await execute('BEGIN TRANSACTION');
    try {
      final result = await action();
      await execute('COMMIT');
      return result;
    } catch (_) {
      try {
        await execute('ROLLBACK');
      } catch (_) {
        // A failed commit can already have rolled back the transaction.
        // Preserve the original database error in that case.
      }
      rethrow;
    }
  }

  Future<void> insert(String table, Map<String, Object?> row) => execute(
    'INSERT OR REPLACE INTO $table (${row.keys.join(',')}) VALUES (${List.filled(row.length, '?').join(',')})',
    row.values.toList(),
  );

  Future<void> append(String table, Iterable<List<Object?>> rows) async {
    final appender = await connection.append(table, null);
    try {
      for (final row in rows) {
        for (final value in row) {
          appender.append(value);
        }
        appender.endRow();
      }
      appender.flush();
    } finally {
      appender.dispose();
    }
  }

  Future<void> saveUpstream(Upstream upstream) async {
    final row = upstream.toMap()
      ..remove('models')
      ..remove('reasoning_models')
      ..remove('reasoning_configured');
    await insert('upstreams', row);
    await execute('DELETE FROM upstream_models WHERE upstream_id = ?', [
      upstream.id,
    ]);
    await append('upstream_models', [
      for (var i = 0; i < upstream.models.length; i++)
        [
          upstream.id,
          i,
          upstream.models[i],
          !upstream.reasoningConfigured ||
                  upstream.reasoningModels.contains(upstream.models[i])
              ? true
              : false,
        ],
    ]);
  }

  Future<List<Upstream>> upstreams() async {
    final rows = await query('SELECT * FROM upstreams ORDER BY rowid');
    final models = await query(
      'SELECT * FROM upstream_models ORDER BY ordinal',
    );
    return rows
        .map(
          (row) => Upstream.fromMap({
            ...row,
            'models': jsonEncode([
              for (final model in models)
                if (model['upstream_id'] == row['id']) model['model'] as String,
            ]),
            'reasoning_models': jsonEncode([
              for (final model in models)
                if (model['upstream_id'] == row['id'] &&
                    model['reasoning_enabled'] != false)
                  model['model'] as String,
            ]),
            'reasoning_configured': models.any(
              (model) => model['upstream_id'] == row['id'],
            ),
          }),
        )
        .toList();
  }

  Future<void> saveDiagnostic(Diagnostic diagnostic) async {
    // Large arrays never enter a JSON column: each fact table has an explicit grain.
    final row = <String, Object?>{
      'id': diagnostic.id,
      'upstream_id': diagnostic.upstreamId,
      'upstream_name': diagnostic.upstreamName,
      'model': diagnostic.model,
      'prompt_name': diagnostic.promptName,
      'prompt': diagnostic.prompt,
      'output': diagnostic.output,
      'started_at': diagnostic.startedAt,
      'duration_ms': diagnostic.durationMs,
      'first_byte_ms': diagnostic.firstByteMs,
      'tcp_connect_ms': diagnostic.tcpConnectMs,
      'ttft_ms': diagnostic.ttftMs,
      'input_tokens': diagnostic.inputTokens,
      'output_tokens': diagnostic.outputTokens,
      'total_tokens': diagnostic.totalTokens,
      'cache_read_tokens': diagnostic.cacheReadTokens,
      'cache_write_tokens': diagnostic.cacheWriteTokens,
      'error': diagnostic.error,
      'stream_mode': diagnostic.streamMode ? 1 : 0,
      'detection_mode': diagnostic.detectionMode,
    };
    for (final table in _factTables) {
      await execute('DELETE FROM $table WHERE diagnostic_id = ?', [
        diagnostic.id,
      ]);
    }
    await insert('diagnostics', row);
    final id = diagnostic.id;
    await append('metric_samples', [
      for (var i = 0; i < diagnostic.points.length; i++)
        [
          id,
          i,
          diagnostic.points[i].seconds,
          diagnostic.points[i].tokensPerSecond,
        ],
    ]);
    await append('retry_events', [
      for (var i = 0; i < diagnostic.retries.length; i++)
        [
          id,
          i,
          diagnostic.retries[i].at.toIso8601String(),
          diagnostic.retries[i].reason,
          diagnostic.retries[i].attempt,
          diagnostic.retries[i].elapsedMs,
        ],
    ]);
    await append('model_activities', [
      for (var i = 0; i < diagnostic.activities.length; i++)
        [
          id,
          i,
          diagnostic.activities[i].kind,
          diagnostic.activities[i].content,
          diagnostic.activities[i].name,
          diagnostic.activities[i].id,
          diagnostic.activities[i].elapsedMs,
          diagnostic.activities[i].attempt,
        ],
    ]);
    for (var attempt = 0; attempt < diagnostic.exchanges.length; attempt++) {
      final exchange = diagnostic.exchanges[attempt];
      await append('request_attempts', [
        [
          id,
          attempt,
          exchange.startedAt,
          exchange.method,
          exchange.url,
          exchange.requestBody,
          exchange.streamMode ? 1 : 0,
          exchange.statusCode,
          exchange.reasonPhrase,
          exchange.durationMs,
          exchange.error,
          exchange.responseBytes,
          exchange.chunks.length,
        ],
      ]);
      await append('http_headers', [
        for (final entry in exchange.requestHeaders.entries)
          [id, attempt, 'request', entry.key, entry.value],
        for (final entry in exchange.responseHeaders.entries)
          [id, attempt, 'response', entry.key, entry.value],
      ]);
      final seconds = <int, List<int>>{};
      final sink = _ChunkSink();
      final decoder = const Utf8Decoder(
        allowMalformed: true,
      ).startChunkedConversion(StringConversionSink.fromStringSink(sink));
      // An appender batches all transport rows in one transaction, off the UI.
      final appender = await connection.append('stream_chunks', null);
      try {
        for (var i = 0; i < exchange.chunks.length; i++) {
          final chunk = exchange.chunks[i];
          final bytes = Uint8List.fromList(chunk.bytes);
          final second = chunk.elapsedMs ~/ 1000;
          sink.buffer = StringBuffer();
          decoder.add(bytes);
          if (i == exchange.chunks.length - 1 && exchange.durationMs != null) {
            decoder.close();
          }
          final values = [
            id,
            attempt,
            i,
            chunk.elapsedMs,
            second,
            bytes.length,
            bytes,
            sink.buffer.toString(),
          ];
          for (final value in values) {
            appender.append(value);
          }
          appender.endRow();
          final summary = seconds.putIfAbsent(second, () => [0, 0, i, i]);
          summary[0] += bytes.length;
          summary[1]++;
          summary[3] = i;
        }
        appender.flush();
      } finally {
        appender.dispose();
      }
      await append('traffic_seconds', [
        for (final entry in seconds.entries)
          [
            id,
            attempt,
            entry.key,
            entry.value[0],
            entry.value[1],
            entry.value[2],
            entry.value[3],
          ],
      ]);
    }
  }

  Future<Diagnostic?> diagnostic(String id, {bool includeChunks = true}) async {
    final rows = await query('SELECT * FROM diagnostics WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final points = await query(
      'SELECT elapsed_second, tokens_per_second FROM metric_samples WHERE diagnostic_id = ? ORDER BY sample_index',
      [id],
    );
    final retries = await query(
      'SELECT * FROM retry_events WHERE diagnostic_id = ? ORDER BY event_index',
      [id],
    );
    final activities = await query(
      'SELECT * FROM model_activities WHERE diagnostic_id = ? ORDER BY activity_index',
      [id],
    );
    final attempts = await query(
      'SELECT * FROM request_attempts WHERE diagnostic_id = ? ORDER BY attempt_index',
      [id],
    );
    final exchanges = <HttpExchange>[];
    for (final attempt in attempts) {
      final index = attempt['attempt_index'] as int;
      final headers = await query(
        'SELECT direction, name, value FROM http_headers WHERE diagnostic_id = ? AND attempt_index = ?',
        [id, index],
      );
      final summaries = await query(
        'SELECT * FROM traffic_seconds WHERE diagnostic_id = ? AND attempt_index = ? ORDER BY elapsed_second',
        [id, index],
      );
      final chunks = includeChunks
          ? await _chunks(id, index)
          : <ResponseChunk>[];
      exchanges.add(
        HttpExchange(
          startedAt: attempt['started_at'] as String,
          method: attempt['method'] as String,
          url: attempt['url'] as String,
          requestBody: attempt['request_body'] as String,
          streamMode: attempt['stream_mode'] == 1,
          statusCode: attempt['status_code'] as int?,
          reasonPhrase: attempt['reason_phrase'] as String?,
          durationMs: attempt['duration_ms'] as int?,
          error: attempt['error'] as String,
          chunks: chunks,
          requestHeaders: {
            for (final h in headers)
              if (h['direction'] == 'request')
                h['name'] as String: h['value'] as String,
          },
          responseHeaders: {
            for (final h in headers)
              if (h['direction'] == 'response')
                h['name'] as String: h['value'] as String,
          },
          storedResponseBytes: attempt['response_bytes'] as int,
          storedChunkCount: attempt['chunk_count'] as int,
          secondSummaries: [
            for (final summary in summaries)
              TrafficSecond(
                second: summary['elapsed_second'] as int,
                bytes: summary['inbound_bytes'] as int,
                chunkCount: summary['chunk_count'] as int,
              ),
          ],
        ),
      );
    }
    return Diagnostic(
      id: row['id'] as String,
      upstreamId: row['upstream_id'] as String,
      upstreamName: row['upstream_name'] as String,
      model: row['model'] as String,
      promptName: row['prompt_name'] as String,
      prompt: row['prompt'] as String,
      output: row['output'] as String,
      startedAt: row['started_at'] as String,
      durationMs: row['duration_ms'] as int,
      firstByteMs: row['first_byte_ms'] as int,
      tcpConnectMs: row['tcp_connect_ms'] as int?,
      ttftMs: row['ttft_ms'] as int,
      inputTokens: row['input_tokens'] as int,
      outputTokens: row['output_tokens'] as int,
      totalTokens: row['total_tokens'] as int,
      cacheReadTokens: row['cache_read_tokens'] as int?,
      cacheWriteTokens: row['cache_write_tokens'] as int?,
      error: row['error'] as String,
      streamMode: row['stream_mode'] == 1,
      detectionMode: (row['detection_mode'] as String?) ?? 'single',
      exchanges: exchanges,
      points: [
        for (final p in points)
          SamplePoint(
            (p['elapsed_second'] as num).toDouble(),
            (p['tokens_per_second'] as num).toDouble(),
          ),
      ],
      retries: [
        for (final r in retries)
          RetryEvent(
            DateTime.parse(r['occurred_at'] as String),
            r['reason'] as String,
            r['attempt'] as int,
            elapsedMs: r['elapsed_ms'] as int?,
          ),
      ],
      activities: [
        for (final a in activities)
          ModelActivity(
            kind: a['kind'] as String,
            content: a['content'] as String,
            name: a['name'] as String,
            id: a['activity_id'] as String,
            elapsedMs: a['elapsed_ms'] as int,
            attempt: a['attempt'] as int,
          ),
      ],
    );
  }

  Future<List<ResponseChunk>> _chunks(
    String id,
    int attempt, {
    List<int>? seconds,
  }) async {
    final rows = await query(
      '''SELECT elapsed_ms, payload, decoded_text, chunk_index FROM stream_chunks
      WHERE diagnostic_id = ? AND attempt_index = ?
      ${seconds == null ? '' : 'AND elapsed_second IN (${List.filled(seconds.length, '?').join(',')})'}
      ORDER BY chunk_index''',
      [id, attempt, ...?seconds],
    );
    return [
      for (final row in rows)
        ResponseChunk(
          elapsedMs: row['elapsed_ms'] as int,
          base64: base64Encode(row['payload'] as List<int>),
          decodedText: row['decoded_text'] as String,
          sequence: row['chunk_index'] as int,
        ),
    ];
  }

  Future<StoredLogPage> logPage(
    String id,
    int attempt,
    int? afterSecond,
    int limit,
  ) async {
    final summaries = await query(
      '''SELECT elapsed_second FROM traffic_seconds
      WHERE diagnostic_id = ? AND attempt_index = ? AND elapsed_second > ?
      ORDER BY elapsed_second LIMIT ?''',
      [id, attempt, afterSecond ?? -1, limit],
    );
    final seconds = [for (final row in summaries) row['elapsed_second'] as int];
    return StoredLogPage(
      seconds: seconds,
      chunks: seconds.isEmpty
          ? []
          : await _chunks(id, attempt, seconds: seconds),
    );
  }

  Future<String> exportBackup() async {
    final runs = await query(
      'SELECT id FROM diagnostics ORDER BY started_at, id',
    );
    final records = <Map<String, Object?>>[];
    for (final run in runs) {
      records.add((await diagnostic(run['id'] as String))!.toMap());
    }
    return jsonEncode({
      'format': 'ai-channel-diagnostics',
      'version': 1,
      'created_at': DateTime.now().toIso8601String(),
      'upstreams': (await upstreams()).map((u) => u.toMap()).toList(),
      'prompts': await query('SELECT * FROM prompts'),
      'settings': await query('SELECT * FROM settings'),
      'diagnostics': records,
    });
  }

  Future<void> importTables(
    Map<String, List<Map<String, Object?>>> tables,
  ) async {
    for (final row in tables['upstreams'] ?? <Map<String, Object?>>[]) {
      await saveUpstream(Upstream.fromMap(row));
    }
    for (final table in ['prompts', 'settings']) {
      for (final row in tables[table] ?? <Map<String, Object?>>[]) {
        await insert(table, row);
      }
    }
    for (final row in tables['diagnostics'] ?? <Map<String, Object?>>[]) {
      await saveDiagnostic(Diagnostic.fromMap(row));
    }
  }

  Future<dynamic> dispatch(String method, dynamic arg) async {
    switch (method) {
      case 'query':
        return query(arg[0] as String, (arg[1] as List).cast<Object?>());
      case 'execute':
        return execute(arg[0] as String, (arg[1] as List).cast<Object?>());
      case 'upstreams':
        return upstreams();
      case 'saveUpstream':
        return transaction(() => saveUpstream(arg as Upstream));
      case 'deleteUpstream':
        return transaction(() async {
          await execute('DELETE FROM upstream_models WHERE upstream_id = ?', [
            arg,
          ]);
          await execute('DELETE FROM upstreams WHERE id = ?', [arg]);
        });
      case 'prompts':
        return (await query(
          'SELECT * FROM prompts ORDER BY rowid',
        )).map(TestPrompt.fromMap).toList();
      case 'savePrompt':
        final prompt = arg as TestPrompt;
        return insert('prompts', {
          'id': prompt.id,
          'name': prompt.name,
          'content': prompt.content,
        });
      case 'deletePrompt':
        return execute('DELETE FROM prompts WHERE id = ?', [arg]);
      case 'setting':
        final rows = await query('SELECT value FROM settings WHERE key = ?', [
          arg,
        ]);
        return rows.isEmpty ? null : rows.single['value'];
      case 'setSetting':
        return insert('settings', {'key': arg[0], 'value': arg[1]});
      case 'saveDiagnostic':
        return transaction(() => saveDiagnostic(arg as Diagnostic));
      case 'deleteDiagnostic':
        return transaction(() async {
          for (final table in _factTables) {
            await execute('DELETE FROM $table WHERE diagnostic_id = ?', [arg]);
          }
          await execute('DELETE FROM diagnostics WHERE id = ?', [arg]);
        });
      case 'history':
        return query(
          'SELECT id, upstream_id, upstream_name, model, prompt_name, started_at, duration_ms, total_tokens, error, stream_mode, detection_mode FROM diagnostics ORDER BY started_at DESC',
        );
      case 'diagnostic':
        return diagnostic(arg[0] as String, includeChunks: arg[1] as bool);
      case 'logPage':
        return logPage(
          arg[0] as String,
          arg[1] as int,
          arg[2] as int?,
          arg[3] as int,
        );
      case 'rates':
        final rows = await query('SELECT * FROM channel_rates');
        return <String, RateMetrics>{
          for (final row in rows)
            row['upstream_id'] as String: RateMetrics(
              requests: (row['requests'] as num).toInt(),
              tokens: (row['tokens'] as num).toInt(),
              durationMs: (row['duration'] as num).toInt(),
            ),
        };
      case 'export':
        return transaction(exportBackup);
      case 'import':
        return transaction(
          () => importTables(
            (arg as Map).cast<String, List<Map<String, Object?>>>(),
          ),
        );
      case 'fullExchange':
        final diagnostic = await this.diagnostic(arg[0] as String);
        if (diagnostic == null) throw StateError('记录不存在');
        return diagnostic.exchanges[arg[1] as int];
      case 'validateBackup':
        BackupData.parse(arg as String);
        return null;
      case 'importBackup':
        return transaction(
          () => importTables(BackupData.parse(arg as String).tables),
        );
      case 'seed':
        return transaction(() async {
          if ((await query(
            "SELECT value FROM store_metadata WHERE key = 'pelican_prompt_seed_v1'",
          )).isEmpty) {
            final old = await query(
              'SELECT id FROM prompts WHERE id = ? AND name = ? AND content = ?',
              [
                'default-reasoning',
                '综合智力测试',
                '请解决下面的智力测试题，给出清晰、可复核的推理过程，并在最后给出答案：\n\n',
              ],
            );
            final id = old.isEmpty
                ? defaultPelicanPrompt.id
                : 'default-reasoning';
            if ((await query('SELECT id FROM prompts WHERE id = ?', [
                  id,
                ])).isEmpty ||
                old.isNotEmpty) {
              await insert('prompts', {
                'id': id,
                'name': defaultPelicanPrompt.name,
                'content': defaultPelicanPrompt.content,
              });
            }
            await insert('store_metadata', {
              'key': 'pelican_prompt_seed_v1',
              'value': '1',
            });
            await insert('store_metadata', {
              'key': 'initialized',
              'value': '1',
            });
          }
        });
      case 'close':
        return close();
      default:
        throw StateError('未知数据库操作：$method');
    }
  }
}

class _ChunkSink implements StringSink {
  StringBuffer buffer = StringBuffer();
  @override
  void write(Object? object) => buffer.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
}

const _factTables = [
  'metric_samples',
  'retry_events',
  'model_activities',
  'request_attempts',
  'http_headers',
  'stream_chunks',
  'traffic_seconds',
];

const _schema = [
  'CREATE TABLE IF NOT EXISTS store_metadata (key VARCHAR PRIMARY KEY, value VARCHAR NOT NULL)',
  'CREATE TABLE IF NOT EXISTS upstreams (id VARCHAR PRIMARY KEY, name VARCHAR NOT NULL, base_url VARCHAR NOT NULL, api_key VARCHAR NOT NULL, selected_model VARCHAR NOT NULL, note VARCHAR NOT NULL)',
  "ALTER TABLE upstreams ADD COLUMN IF NOT EXISTS proxy_type VARCHAR DEFAULT 'none'",
  "ALTER TABLE upstreams ADD COLUMN IF NOT EXISTS proxy_host VARCHAR DEFAULT '127.0.0.1'",
  'ALTER TABLE upstreams ADD COLUMN IF NOT EXISTS proxy_port INTEGER DEFAULT 7890',
  'CREATE TABLE IF NOT EXISTS upstream_models (upstream_id VARCHAR, ordinal INTEGER, model VARCHAR, reasoning_enabled BOOLEAN DEFAULT TRUE)',
  'ALTER TABLE upstream_models ADD COLUMN IF NOT EXISTS reasoning_enabled BOOLEAN DEFAULT TRUE',
  'CREATE TABLE IF NOT EXISTS prompts (id VARCHAR PRIMARY KEY, name VARCHAR NOT NULL, content VARCHAR NOT NULL)',
  'CREATE TABLE IF NOT EXISTS settings (key VARCHAR PRIMARY KEY, value VARCHAR NOT NULL)',
  '''CREATE TABLE IF NOT EXISTS diagnostics (
    id VARCHAR PRIMARY KEY, upstream_id VARCHAR, upstream_name VARCHAR, model VARCHAR,
    prompt_name VARCHAR, prompt VARCHAR, output VARCHAR, started_at VARCHAR,
    duration_ms BIGINT, first_byte_ms BIGINT, tcp_connect_ms BIGINT, ttft_ms BIGINT,
    input_tokens BIGINT, output_tokens BIGINT, total_tokens BIGINT,
    cache_read_tokens BIGINT, cache_write_tokens BIGINT, error VARCHAR, stream_mode INTEGER)''',
  'ALTER TABLE diagnostics ADD COLUMN IF NOT EXISTS detection_mode VARCHAR DEFAULT \'single\'',
  'CREATE TABLE IF NOT EXISTS metric_samples (diagnostic_id VARCHAR, sample_index BIGINT, elapsed_second DOUBLE, tokens_per_second DOUBLE)',
  'CREATE TABLE IF NOT EXISTS retry_events (diagnostic_id VARCHAR, event_index BIGINT, occurred_at VARCHAR, reason VARCHAR, attempt INTEGER, elapsed_ms BIGINT)',
  'CREATE TABLE IF NOT EXISTS model_activities (diagnostic_id VARCHAR, activity_index BIGINT, kind VARCHAR, content VARCHAR, name VARCHAR, activity_id VARCHAR, elapsed_ms BIGINT, attempt INTEGER)',
  '''CREATE TABLE IF NOT EXISTS request_attempts (diagnostic_id VARCHAR, attempt_index INTEGER,
    started_at VARCHAR, method VARCHAR, url VARCHAR, request_body VARCHAR, stream_mode INTEGER,
    status_code INTEGER, reason_phrase VARCHAR, duration_ms BIGINT, error VARCHAR,
    response_bytes BIGINT, chunk_count BIGINT)''',
  'CREATE TABLE IF NOT EXISTS http_headers (diagnostic_id VARCHAR, attempt_index INTEGER, direction VARCHAR, name VARCHAR, value VARCHAR)',
  '''CREATE TABLE IF NOT EXISTS stream_chunks (diagnostic_id VARCHAR, attempt_index INTEGER,
    chunk_index BIGINT, elapsed_ms BIGINT, elapsed_second BIGINT, byte_count BIGINT,
    payload BLOB, decoded_text VARCHAR)''',
  '''CREATE TABLE IF NOT EXISTS traffic_seconds (diagnostic_id VARCHAR, attempt_index INTEGER,
    elapsed_second BIGINT, inbound_bytes BIGINT, chunk_count BIGINT, first_chunk BIGINT, last_chunk BIGINT)''',
  'CREATE INDEX IF NOT EXISTS chunks_time ON stream_chunks(diagnostic_id, attempt_index, elapsed_second)',
  'CREATE INDEX IF NOT EXISTS seconds_time ON traffic_seconds(diagnostic_id, attempt_index, elapsed_second)',
  '''CREATE OR REPLACE VIEW channel_rates AS SELECT upstream_id, COUNT(*) AS requests,
    SUM(total_tokens)::BIGINT AS tokens, SUM(duration_ms)::BIGINT AS duration
    FROM diagnostics WHERE error = '' AND duration_ms > 0 GROUP BY upstream_id''',
];
