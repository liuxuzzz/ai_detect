import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'data.dart';
import 'formatters.dart';
import 'windows_html_preview.dart';

class OutputPart {
  const OutputPart(this.offset, this.text, {this.html});

  final int offset;

  /// Exact original output, including fences when present.
  final String text;
  final String? html;
}

final _htmlStart = RegExp(
  r'<!doctype\s+html\b[^>]*>|<(?:html|head|body|title|meta|link|main|header|footer|nav|aside|section|article|div|table|caption|thead|tbody|tfoot|tr|th|td|h[1-6]|p|ul|ol|li|form|label|input|textarea|select|option|details|summary|figure|figcaption|blockquote|code|pre|style|script|span|svg|canvas|iframe|video|audio|button|a|img|br|hr)\b[^>]*>',
  caseSensitive: false,
);
final _tags = RegExp(
  r'''<!--[\s\S]*?-->|<(script|style)\b[^>]*>[\s\S]*?</\1\s*>|</?([a-z][a-z0-9:-]*)\b(?:"[^"]*"|'[^']*'|[^'">])*>''',
  caseSensitive: false,
);
const _voidTags = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// Split only HTML out of the response; prose and other code remain untouched.
/// An unfinished fence/root consumes the remaining text while streaming.
List<OutputPart> splitModelOutput(String output) {
  final parts = <OutputPart>[];

  void raw(String text, int offset) {
    var cursor = 0;
    while (cursor < text.length) {
      final start = _htmlStart.firstMatch(text.substring(cursor));
      if (start == null) {
        parts.add(OutputPart(offset + cursor, text.substring(cursor)));
        break;
      }
      final begin = cursor + start.start;
      if (begin > cursor) {
        parts.add(OutputPart(offset + cursor, text.substring(cursor, begin)));
      }
      var rootStart = begin;
      if (text.substring(begin).toLowerCase().startsWith('<!doctype')) {
        final html = RegExp(
          r'<html\b[^>]*>',
          caseSensitive: false,
        ).firstMatch(text.substring(begin + start.group(0)!.length));
        if (html != null) {
          rootStart = begin + start.group(0)!.length + html.start;
        }
      }
      final root = RegExp(
        r'<([a-z][a-z0-9:-]*)\b',
        caseSensitive: false,
      ).matchAsPrefix(text, rootStart)?.group(1)?.toLowerCase();
      var end = text.length;
      var depth = 0;
      if (root != null) {
        for (final tag in _tags.allMatches(text, rootStart)) {
          final name = (tag.group(1) ?? tag.group(2))?.toLowerCase();
          if (name != root) continue;
          final token = tag.group(0)!;
          if (tag.group(1) != null) {
            // A complete style/script token includes its own closing tag.
            if (depth == 0) {
              end = tag.end;
              break;
            }
          } else if (token.startsWith('</')) {
            depth--;
          } else if (!_voidTags.contains(name) && !token.endsWith('/>')) {
            depth++;
          }
          if (depth == 0) {
            end = tag.end;
            break;
          }
        }
      }
      final source = text.substring(begin, end);
      parts.add(OutputPart(offset + begin, source, html: source));
      cursor = end;
    }
  }

  final fence = RegExp(
    r'^([ \t]*)(`{3,}|~{3,})([^\n\r]*)\r?\n',
    multiLine: true,
  );
  var cursor = 0;
  while (cursor < output.length) {
    final open = fence.firstMatch(output.substring(cursor));
    if (open == null) {
      raw(output.substring(cursor), cursor);
      break;
    }
    final begin = cursor + open.start;
    if (begin > cursor) raw(output.substring(cursor, begin), cursor);
    final contentStart = cursor + open.end;
    final marker = open.group(2)!;
    final close = RegExp(
      '^[ \\t]*${marker[0]}{${marker.length},}[ \\t]*(?:\\r?\\n|\$)',
      multiLine: true,
    ).firstMatch(output.substring(contentStart));
    final contentEnd = close == null
        ? output.length
        : contentStart + close.start;
    final end = close == null ? output.length : contentStart + close.end;
    final content = output.substring(contentStart, contentEnd);
    final language = open.group(3)!.trim().toLowerCase();
    if (language == 'html' ||
        language == 'htm' ||
        (language.isEmpty && _htmlStart.hasMatch(content))) {
      parts.add(OutputPart(begin, output.substring(begin, end), html: content));
    } else {
      parts.add(OutputPart(begin, output.substring(begin, end)));
    }
    cursor = end;
  }
  return parts;
}

String _previewSource(String source) => source
    .replaceAll(
      RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false),
      '',
    )
    .replaceAll(
      RegExp(r'<link\b[^>]*stylesheet[^>]*>', caseSensitive: false),
      '',
    )
    .replaceAll(
      RegExp(
        r'''\sstyle\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''',
        caseSensitive: false,
      ),
      '',
    );

class ModelOutputView extends StatefulWidget {
  const ModelOutputView({
    super.key,
    required this.output,
    this.receiving = false,
    this.activities = const [],
    this.autoPreviewHtml = false,
  });
  final String output;
  final bool receiving;
  final List<ModelActivity> activities;
  final bool autoPreviewHtml;
  @override
  State<ModelOutputView> createState() => _ModelOutputViewState();
}

class _ModelOutputViewState extends State<ModelOutputView> {
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ModelOutputView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.receiving &&
        scroll.hasClients &&
        scroll.position.pixels >= scroll.position.maxScrollExtent - 64 &&
        (oldWidget.output != widget.output ||
            oldWidget.activities != widget.activities)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
  }

  List<Widget> outputWidgets(String output, String prefix, bool receiving) {
    final parts = splitModelOutput(output);
    return [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].html == null)
          SelectableText(
            parts[i].text,
            style: const TextStyle(height: 1.7, fontSize: 14),
          )
        else
          _HtmlBlock(
            key: ValueKey('$prefix-${parts[i].offset}'),
            source: parts[i].html!,
            receiving: receiving && i == parts.length - 1,
            autoPreview: widget.autoPreviewHtml,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final activities = widget.activities;
    final hasOutput = activities.any((a) => a.kind == 'output');
    final hasThinking = activities.any((a) => a.kind == 'thinking');
    final hasArtifact = activities.any((a) => a.kind == 'html_artifact');
    final activityOutput = activities
        .where((a) => a.kind == 'output')
        .map((a) => a.content)
        .join();
    return ListView(
      controller: scroll,
      children: [
        if (hasThinking && !hasOutput && !hasArtifact && widget.output.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(widget.receiving ? '正在思考，尚未收到正文' : '本次仅收到思考过程，未收到正文'),
          ),
        for (var i = 0; i < activities.length; i++)
          if (activities[i].kind == 'output') ...[
            if (hasThinking && (i == 0 || activities[i - 1].kind != 'output'))
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '正文',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ...outputWidgets(
              activities[i].content,
              'activity-$i',
              widget.receiving && i == activities.length - 1,
            ),
          ] else if (activities[i].kind == 'html_artifact')
            _HtmlBlock(
              key: ValueKey('artifact-${activities[i].id}'),
              source: activities[i].content,
              receiving: false,
              autoPreview: true,
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: const Color(0xfff3f6f5),
                borderRadius: BorderRadius.circular(6),
                child: ExpansionTile(
                  key: ValueKey('activity-$i'),
                  initiallyExpanded: !const {
                    'write_html_file',
                    'read_html_file',
                    'render_html',
                  }.contains(activities[i].name),
                  leading: Icon(
                    activities[i].kind == 'thinking'
                        ? Icons.psychology_outlined
                        : Icons.terminal,
                    size: 18,
                  ),
                  title: Text(
                    activities[i].kind == 'thinking'
                        ? '思考过程'
                        : '${activities[i].kind == 'tool_result' ? '工具结果' : '工具调用'}${activities[i].name.isEmpty ? '' : ' · ${activities[i].name}'}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    '第 ${activities[i].attempt} 次请求 · ${secondsText(activities[i].elapsedMs)}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        activities[i].content,
                        style: const TextStyle(height: 1.6, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        if (!hasOutput && !hasArtifact)
          ...outputWidgets(widget.output, 'output', widget.receiving),
        // Older Agent runs stored tool-created HTML only after the combined
        // assistant text. Keep that suffix visible when activities exist.
        if (hasOutput &&
            !hasArtifact &&
            widget.output.startsWith(activityOutput) &&
            widget.output.length > activityOutput.length)
          ...outputWidgets(
            widget.output.substring(activityOutput.length),
            'artifact-suffix',
            widget.receiving,
          ),
      ],
    );
  }
}

class _HtmlBlock extends StatefulWidget {
  const _HtmlBlock({
    super.key,
    required this.source,
    required this.receiving,
    this.autoPreview = false,
  });

  final String source;
  final bool receiving;
  final bool autoPreview;

  @override
  State<_HtmlBlock> createState() => _HtmlBlockState();
}

class _HtmlBlockState extends State<_HtmlBlock> {
  late bool preview = widget.autoPreview;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Material(
      color: const Color(0xfff3f6f5),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: widget.autoPreview,
        title: const Text(
          'HTML',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: widget.receiving ? const Text('正在接收') : null,
        leading: const Icon(Icons.code),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('源代码')),
                ButtonSegment(value: true, label: Text('渲染预览')),
              ],
              selected: {preview},
              onSelectionChanged: (value) =>
                  setState(() => preview = value.first),
              showSelectedIcon: false,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.topLeft,
            child: preview
                ? HtmlPagePreview(source: widget.source)
                : SelectableText(
                    widget.source,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

/// Uses native browser engines on Windows and macOS for HTML and animation.
class HtmlPagePreview extends StatefulWidget {
  const HtmlPagePreview({super.key, required this.source});

  final String source;

  @override
  State<HtmlPagePreview> createState() => _HtmlPagePreviewState();
}

class _HtmlPagePreviewState extends State<HtmlPagePreview> {
  MethodChannel? channel;
  Timer? refresh;
  String? error;
  // Keep the platform view visible while WebKit sends its first measured
  // height. The value is replaced as soon as the document is ready.
  double contentHeight = 520;

  Future<void> _handlePreviewCall(MethodCall call) async {
    if (call.method != 'contentHeight' || call.arguments is! num) return;
    final height = (call.arguments as num).toDouble();
    if (!mounted || !height.isFinite || height <= 0) return;
    if ((height - contentHeight).abs() >= 1) {
      setState(() => contentHeight = height.ceilToDouble());
    }
  }

  Future<void> _update() async {
    try {
      await channel?.invokeMethod<void>('loadHtml', widget.source);
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = '预览加载失败：${e.message}');
    }
  }

  @override
  void didUpdateWidget(covariant HtmlPagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source && channel != null) {
      // Refresh at most twice per second while tokens arrive.
      refresh ??= Timer(const Duration(milliseconds: 500), () {
        refresh = null;
        if (mounted) unawaited(_update());
      });
    }
  }

  @override
  void dispose() {
    refresh?.cancel();
    channel?.setMethodCallHandler(null);
    channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return WindowsHtmlPreview(source: widget.source);
    }
    if (defaultTargetPlatform != TargetPlatform.macOS || kIsWeb) {
      return Html(data: _previewSource(widget.source));
    }
    if (error != null) return Text(error!);
    return SizedBox(
      height: contentHeight,
      child: AppKitView(
        viewType: 'aijiance/html-preview',
        creationParams: {'html': widget.source},
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (id) {
          channel = MethodChannel('aijiance/html-preview/$id');
          channel!.setMethodCallHandler(_handlePreviewCall);
          unawaited(_update());
        },
      ),
    );
  }
}
