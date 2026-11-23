import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'data.dart';
import 'duckdb_store.dart';
export 'backup_data.dart';

class DiagnosticRead {
  const DiagnosticRead({required this.diagnostic});
  final Diagnostic diagnostic;
}

class LocalDb {
  LocalDb({Future<Directory> Function()? supportDirectory, this.libraryPath})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _supportDirectory;
  final String? libraryPath;
  Future<DuckStore>? _opening;

  Future<DuckStore> get _store => _opening ??= _open();
  Future<DuckStore> _open() async {
    final directory = await _supportDirectory();
    await directory.create(recursive: true);
    final store = await DuckStore.open(
      p.join(directory.path, 'aijiance.duckdb'),
      libraryPath: libraryPath,
    );
    try {
      await store.call<void>('seed');
      return store;
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  Future<T> _call<T>(String method, [Object? argument]) async =>
      (await _store).call<T>(method, argument);

  Future<List<Upstream>> upstreams() => _call('upstreams');
  Future<void> saveUpstream(Upstream upstream) =>
      _call('saveUpstream', upstream);
  Future<void> deleteUpstream(String id) => _call('deleteUpstream', id);
  Future<List<TestPrompt>> prompts() => _call('prompts');
  Future<void> savePrompt(TestPrompt prompt) => _call('savePrompt', prompt);
  Future<void> deletePrompt(String id) => _call('deletePrompt', id);
  Future<String?> setting(String key) => _call('setting', key);
  Future<void> setSetting(String key, String value) =>
      _call('setSetting', [key, value]);
  Future<void> saveDiagnostic(Diagnostic diagnostic) =>
      _call('saveDiagnostic', diagnostic);
  Future<void> deleteDiagnostic(String id) => _call('deleteDiagnostic', id);
  Future<List<Map<String, Object?>>> history() => _call('history');
  Future<Map<String, RateMetrics>> rates() => _call('rates');

  Future<Diagnostic?> diagnostic(String id) => _call('diagnostic', [id, true]);
  Future<DiagnosticRead?> diagnosticRead(
    String id, {
    bool includeChunks = true,
  }) async {
    final diagnostic = await _call<Diagnostic?>('diagnostic', [
      id,
      includeChunks,
    ]);
    return diagnostic == null ? null : DiagnosticRead(diagnostic: diagnostic);
  }

  Future<StoredLogPage> logPage(
    String id,
    int attempt, {
    int? afterSecond,
    int limit = 10,
  }) {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
    return _call('logPage', [id, attempt, afterSecond, limit]);
  }

  Future<HttpExchange> fullExchange(String id, int attempt) =>
      _call('fullExchange', [id, attempt]);

  Future<String> exportBackup() => _call('export');
  Future<void> importBackup(String source) async {
    // Validation and all row decoding happen in the database worker.
    await _call<void>('validateBackup', source);
    final before = await exportBackup();
    final directory = await _supportDirectory();
    await File(
      p.join(
        directory.path,
        'before-import-${DateTime.now().microsecondsSinceEpoch}.json',
      ),
    ).writeAsString(before, flush: true);
    await _call<void>('importBackup', source);
  }

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => _call('query', [sql, args]);
  Future<void> execute(String sql, [List<Object?> args = const []]) =>
      _call('execute', [sql, args]);
  Future<void> close() async {
    final opening = _opening;
    if (opening == null) return;
    DuckStore store;
    try {
      store = await opening;
    } catch (_) {
      return;
    }
    await store.close();
  }
}
