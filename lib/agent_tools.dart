import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A tool call assembled from streamed OpenAI-compatible tool-call deltas.
class AgentToolCall {
  const AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;

  Map<String, Object?> toMessagePart() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

/// Tools exposed by the default Agent workflow. They are deliberately small
/// and local: the model can create and inspect HTML, but it cannot run shell
/// commands or access arbitrary files on the user's machine.
class AgentTools {
  static const definitions = <Map<String, Object?>>[
    {
      'type': 'function',
      'function': {
        'name': 'write_html_file',
        'description': '将完整 HTML 写入工作区文件。path 使用相对路径，content 是完整 HTML。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '相对文件名，例如 result.html'},
            'content': {'type': 'string', 'description': '完整 HTML 内容'},
          },
          'required': ['content'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_html_file',
        'description': '读取之前写入的 HTML 文件，用于检查和修改。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '相对文件名'},
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_html_files',
        'description': '列出工作区中已经生成的 HTML 文件。',
        'parameters': {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'render_html',
        'description': '读取 HTML 文件并在客户端打开渲染预览。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '相对文件名'},
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
  ];
}

/// Sandboxed local runtime for the HTML tools.
class AgentToolRuntime {
  AgentToolRuntime(this.root);

  final Directory root;

  Future<String> execute(
    AgentToolCall call, {
    void Function(String html)? onHtml,
  }) async {
    final args = _arguments(call.arguments);
    switch (call.name) {
      case 'write_html_file':
      case 'write_file':
        final content = '${args['content'] ?? args['html'] ?? ''}';
        if (content.trim().isEmpty) return '写入失败：content 为空';
        final file = await _file(args['path']?.toString() ?? 'result.html');
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
        onHtml?.call(content);
        return jsonEncode({
          'ok': true,
          'path': p.relative(file.path, from: root.path),
          'bytes': content.length,
        });
      case 'read_html_file':
        final file = await _file(args['path']?.toString() ?? 'result.html');
        if (!await file.exists()) return '读取失败：文件不存在';
        final content = await file.readAsString();
        onHtml?.call(content);
        return content;
      case 'render_html':
        final file = await _file(args['path']?.toString() ?? 'result.html');
        if (!await file.exists()) return '渲染失败：文件不存在';
        final content = await file.readAsString();
        onHtml?.call(content);
        return jsonEncode({
          'ok': true,
          'path': p.relative(file.path, from: root.path),
          'preview': 'requested',
        });
      case 'list_html_files':
        if (!await root.exists()) return '[]';
        final files = await root
            .list(recursive: true)
            .where(
              (entry) =>
                  entry is File && entry.path.toLowerCase().endsWith('.html'),
            )
            .map((entry) => p.relative(entry.path, from: root.path))
            .toList();
        return jsonEncode(files);
      default:
        return '工具不存在：${call.name}';
    }
  }

  Map<String, dynamic> _arguments(String source) {
    try {
      final value = jsonDecode(source);
      return value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<File> _file(String requested) async {
    final clean = requested.trim().isEmpty ? 'result.html' : requested.trim();
    final candidate = File(p.normalize(p.join(root.path, clean)));
    final rootPath = p.normalize(root.absolute.path);
    final filePath = p.normalize(candidate.absolute.path);
    if (filePath != rootPath && !p.isWithin(rootPath, filePath)) {
      throw FormatException('工具路径必须位于 HTML 工作区内');
    }
    if (!filePath.toLowerCase().endsWith('.html')) {
      throw FormatException('HTML 工具只能操作 .html 文件');
    }
    return candidate;
  }
}
