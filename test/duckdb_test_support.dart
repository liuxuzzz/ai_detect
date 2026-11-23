import 'dart:io';

String get duckdbTestLibrary {
  final configured = Platform.environment['AI_CHANNEL_DUCKDB_LIBRARY'];
  if (configured != null) return configured;
  final library = Platform.isWindows
      ? 'duckdb.dll'
      : Platform.isMacOS
      ? 'libduckdb.dylib'
      : 'libduckdb.so';
  final file = File('.dart_tool/duckdb/$library');
  if (!file.existsSync()) {
    throw StateError('请先运行 python3 tool/bootstrap_duckdb.py');
  }
  return file.absolute.path;
}
