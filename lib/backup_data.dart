import 'dart:convert';
import 'data.dart';

class BackupData {
  BackupData._(this.tables);
  final Map<String, List<Map<String, Object?>>> tables;
  factory BackupData.parse(String source) {
    final root = jsonDecode(source);
    if (root is! Map ||
        root['format'] != 'ai-channel-diagnostics' ||
        root['version'] != 1) {
      throw const FormatException('备份格式或版本无效');
    }
    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in ['upstreams', 'prompts', 'settings', 'diagnostics']) {
      final rows = root[table];
      if (rows is! List) throw FormatException('备份缺少 $table');
      final ids = <String>{};
      tables[table] = rows.map((value) {
        final row = Map<String, Object?>.from(value as Map);
        late Map<String, Object?> clean;
        switch (table) {
          case 'upstreams':
            clean = Upstream.fromMap(row).toMap();
          case 'prompts':
            final prompt = TestPrompt.fromMap(row);
            clean = {
              'id': prompt.id,
              'name': prompt.name,
              'content': prompt.content,
            };
          case 'diagnostics':
            clean = Diagnostic.fromMap(row).toMap();
          case 'settings':
            clean = {
              'key': row['key'] as String,
              'value': row['value'] as String,
            };
          default:
            throw const FormatException('备份表无效');
        }
        final id = clean[table == 'settings' ? 'key' : 'id'] as String;
        if (id.isEmpty || !ids.add(id)) {
          throw FormatException('$table 存在无效或重复 ID');
        }
        if (table == 'settings') {
          final text = clean['value'] as String;
          if ([
            'retry_count',
            'connection_timeout',
            'idle_timeout',
            'request_timeout',
          ].contains(id)) {
            final number = int.tryParse(text);
            final retry = id == 'retry_count';
            if (number == null ||
                number < (retry ? 0 : 1) ||
                number > (retry ? 20 : 86400)) {
              throw FormatException('备份设置无效：$id');
            }
          }
        }
        return clean;
      }).toList();
    }
    return BackupData._(tables);
  }
}
