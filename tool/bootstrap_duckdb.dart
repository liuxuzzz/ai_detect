// Installs the official, checksum-pinned macOS DuckDB binary for tests and CocoaPods.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isMacOS) throw UnsupportedError('此脚本用于 macOS');
  final directory = Directory('.dart_tool/duckdb')..createSync(recursive: true);
  final zip = '${directory.path}/libduckdb.zip';
  const checksum =
      '3951dd422902e8a02db6128520b94e71aed88c42af80ead134da0efd62fc49ed';
  Future<ProcessResult> run(String command, List<String> args) async {
    final result = await Process.run(command, args);
    if (result.exitCode != 0) throw StateError('$command: ${result.stderr}');
    return result;
  }

  if (!File(zip).existsSync()) {
    await run('curl', [
      '--fail',
      '--location',
      '--max-time',
      '180',
      '--retry',
      '2',
      '--header',
      'Accept: application/octet-stream',
      'https://api.github.com/repos/duckdb/duckdb/releases/assets/315529468',
      '-o',
      zip,
    ]);
  }
  final hash = await run('shasum', ['-a', '256', zip]);
  if (!hash.stdout.toString().startsWith(checksum)) {
    throw StateError('DuckDB v1.4.2 二进制校验失败，请删除 $zip 后重试');
  }
  await run('unzip', ['-o', zip, 'libduckdb.dylib', '-d', directory.path]);
  final config = File('.dart_tool/package_config.json');
  final packages =
      (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
  final package = packages.cast<Map>().firstWhere(
    (p) => p['name'] == 'dart_duckdb',
  );
  final root = config.absolute.uri.resolve(package['rootUri'] as String);
  final nativeDirectory = Directory.fromUri(
    root.resolve('macos/Libraries/release/'),
  );
  await nativeDirectory.create(recursive: true);
  await File(
    '${directory.path}/libduckdb.dylib',
  ).copy('${nativeDirectory.path}/libduckdb.dylib');
  stdout.writeln('DuckDB v1.4.2 已准备好（SHA-256 已验证）');
}
