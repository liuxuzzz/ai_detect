import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

/// Uses Edge's browser engine so scripts, SVG, Canvas and CSS animations run.
class WindowsHtmlPreview extends StatefulWidget {
  const WindowsHtmlPreview({super.key, required this.source});

  final String source;

  @override
  State<WindowsHtmlPreview> createState() => _WindowsHtmlPreviewState();
}

class _WindowsHtmlPreviewState extends State<WindowsHtmlPreview> {
  final controller = WebviewController();
  final subscriptions = <StreamSubscription<dynamic>>[];
  Directory? directory;
  String? host;
  Timer? refresh;
  bool initialized = false;
  bool initializing = false;
  bool ready = false;
  bool loading = false;
  bool installing = false;
  bool missingRuntime = false;
  String? error;
  String? loadedSource;
  int revision = 0;
  double contentHeight = 520;
  Future<void>? releasing;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    initializing = true;
    try {
      final version = await WebviewController.getWebViewVersion();
      if (!mounted) return;
      if (version == null) {
        setState(() => missingRuntime = true);
        return;
      }
      await controller.initialize();
      initialized = true;
      if (!mounted) return;
      directory = await Directory.systemTemp.createTemp('ai-detect-preview-');
      host = '${p.basename(directory!.path).toLowerCase()}.invalid';
      if (!mounted) return;
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await controller.setCacheDisabled(true);
      // A private virtual host serves only this preview's generated document.
      // Unlike NavigateToString, this also supports HTML larger than 2 MB.
      await controller.addVirtualHostNameMapping(
        host!,
        directory!.path,
        WebviewHostResourceAccessKind.denyCors,
      );
      await controller.addScriptToExecuteOnDocumentCreated(_resizeScript);
      if (!mounted) return;
      subscriptions.add(controller.webMessage.listen(_onMessage));
      subscriptions.add(
        controller.onLoadError.listen((failure) {
          if (mounted) setState(() => error = '网页预览加载失败：${failure.name}');
        }),
      );
      ready = true;
      await _load();
      if (mounted) setState(() {});
    } catch (failure) {
      if (mounted) setState(() => error = '网页预览初始化失败：$failure');
    } finally {
      initializing = false;
      if (!mounted) await _release();
    }
  }

  void _onMessage(dynamic message) {
    if (!mounted ||
        message is! Map ||
        message['type'] != 'preview-height' ||
        message['revision'] != '$revision' ||
        message['height'] is! num) {
      return;
    }
    final height = (message['height'] as num).toDouble();
    if (!height.isFinite || height <= 0) return;
    // Keep texture allocations bounded for very long pages; the browser can
    // scroll the remainder without truncating its content.
    final bounded = height.clamp(240.0, 4096.0).ceilToDouble();
    if ((bounded - contentHeight).abs() >= 1) {
      setState(() => contentHeight = bounded);
    }
  }

  Future<void> _load() async {
    if (!ready || loading || !mounted) return;
    loading = true;
    try {
      while (mounted && loadedSource != widget.source) {
        final source = widget.source;
        await File(
          p.join(directory!.path, 'index.html'),
        ).writeAsString(source, flush: true);
        if (!mounted) return;
        revision++;
        await controller.loadUrl('https://$host/index.html?revision=$revision');
        loadedSource = source;
      }
    } catch (failure) {
      if (mounted) setState(() => error = '网页预览加载失败：$failure');
    } finally {
      loading = false;
      if (!mounted) await _release();
    }
  }

  @override
  void didUpdateWidget(covariant WindowsHtmlPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      refresh ??= Timer(const Duration(milliseconds: 500), () {
        refresh = null;
        unawaited(_load());
      });
    }
  }

  Future<void> _installRuntime() async {
    setState(() {
      installing = true;
      error = null;
    });
    try {
      final installer = File(
        p.join(
          p.dirname(Platform.resolvedExecutable),
          'MicrosoftEdgeWebview2Setup.exe',
        ),
      );
      if (await installer.exists()) {
        final result = await Process.run(installer.path, ['/install']);
        if (!const {0, 1641, 3010}.contains(result.exitCode)) {
          throw StateError('安装程序退出码 ${result.exitCode}');
        }
        if (!mounted) return;
        missingRuntime = false;
        await _initialize();
      } else {
        final opened = await launchUrl(
          Uri.parse('https://developer.microsoft.com/microsoft-edge/webview2/'),
          mode: LaunchMode.externalApplication,
        );
        if (!opened) throw StateError('无法打开微软 WebView2 下载页面');
      }
    } catch (failure) {
      if (mounted) setState(() => error = '安装 WebView2 失败：$failure');
    } finally {
      if (mounted) setState(() => installing = false);
    }
  }

  Future<void> _release() => releasing ??= _releaseResources();

  Future<void> _releaseResources() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    try {
      if (initialized) {
        initialized = false;
        await controller.dispose();
      }
    } finally {
      final temporary = directory;
      directory = null;
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  @override
  void dispose() {
    refresh?.cancel();
    // Initialization and file writes finish their own cleanup if closed early.
    if (!initializing && !loading) unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (missingRuntime) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('HTML 动画预览需要 Microsoft Edge WebView2 运行库。安装后即可显示完整网页和动画。'),
          if (error != null) Text(error!),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: installing ? null : _installRuntime,
                child: Text(installing ? '正在安装…' : '安装 WebView2'),
              ),
              TextButton(
                onPressed: installing
                    ? null
                    : () {
                        setState(() {
                          missingRuntime = false;
                          error = null;
                        });
                        unawaited(_initialize());
                      },
                child: const Text('安装后重试'),
              ),
            ],
          ),
        ],
      );
    }
    if (error != null) return SelectableText(error!);
    if (!ready) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SizedBox(
      height: contentHeight,
      child: Webview(
        controller,
        permissionRequested: (_, _, _) => WebviewPermissionDecision.deny,
      ),
    );
  }
}

const _resizeScript = r'''
(() => {
  if (window !== window.top) return;
  const revision = new URL(location.href).searchParams.get('revision');
  function start() {
    let pending = false;
    let lastHeight = 0;
    function measure() {
      pending = false;
      const body = document.body;
      if (!body) return;
      const box = body.getBoundingClientRect();
      const margin = parseFloat(getComputedStyle(body).marginBottom) || 0;
      const height = Math.ceil(Math.max(body.scrollHeight, body.offsetHeight, box.height) + Math.max(0, box.top) + margin);
      if (height !== lastHeight) {
        lastHeight = height;
        window.chrome.webview.postMessage({type: 'preview-height', revision, height});
      }
    }
    function schedule() { if (!pending) { pending = true; requestAnimationFrame(measure); } }
    new ResizeObserver(schedule).observe(document.body);
    new MutationObserver(schedule).observe(document.body, {subtree: true, childList: true, attributes: true, characterData: true});
    window.addEventListener('resize', schedule);
    window.addEventListener('load', schedule, true);
    if (document.fonts) document.fonts.ready.then(schedule);
    schedule();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once: true});
  else start();
})();
''';
