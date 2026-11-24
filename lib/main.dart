import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'data.dart';
import 'db.dart';
import 'diagnostics_service.dart';
import 'agent_tools.dart';
import 'model_output.dart';
import 'request_details.dart';
import 'settings.dart';
import 'formatters.dart';
import 'throughput_chart.dart';
import 'model_reasoning.dart';
import 'model_selection_dialog.dart';
import 'diagnostic_report.dart';
import 'channel_proxy.dart';
import 'cloud_client.dart';

const ink = Color(0xff1c2933),
    muted = Color(0xff71808b),
    panel = Color(0xffffffff),
    panel2 = Color(0xfff3f6f5),
    bg = Color(0xfff5f7f6),
    teal = Color(0xff087f70),
    orange = Color(0xffc77b16),
    red = Color(0xffc84955),
    line = Color(0xffdfe6e3);

InputDecoration _dropdownDecoration(String label) => InputDecoration(
  labelText: label,
  filled: true,
  fillColor: panel2,
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(11),
    borderSide: const BorderSide(color: line),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(11),
    borderSide: const BorderSide(color: line),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(11),
    borderSide: const BorderSide(color: teal, width: 1.4),
  ),
);

BoxDecoration _dropdownBox({bool disabled = false}) => BoxDecoration(
  color: disabled ? panel2 : panel,
  borderRadius: BorderRadius.circular(11),
  border: Border.all(color: disabled ? line : const Color(0xffb8cbc5)),
);

class _RunState {
  _RunState(this.upstreamId, this.cancellation, this.detectionMode);

  final String upstreamId;
  final DiagnosticCancellation cancellation;
  final String detectionMode;
  bool running = true;
  String output = '';
  String status = '连接上游…';
  List<ModelActivity> activities = [];
  List<RetryEvent> retries = [];
  List<HttpExchange> exchanges = [];
  List<SamplePoint> points = [];
  int tokens = 0, tps = 0;
  int? tcpConnectMs, ttftMs;
  DateTime? startedAt;
  Diagnostic? last;
  int attempt = 0;
  Timer? sampleTimer, activityFlushTimer;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AijianceApp());
}

class AijianceApp extends StatelessWidget {
  const AijianceApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'AI质量检测',
    theme: ThemeData.light(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.light(
        primary: teal,
        onPrimary: Colors.white,
        surface: panel,
        onSurface: ink,
        error: red,
      ),
      dividerColor: line,
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: panel2,
        border: OutlineInputBorder(
          borderSide: BorderSide(color: line),
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: line),
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: teal, width: 1.4),
          borderRadius: BorderRadius.all(Radius.circular(11)),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    home: const HarnessHome(),
  );
}

class HarnessHome extends StatefulWidget {
  const HarnessHome({
    super.key,
    this.database,
    this.diagnostics,
    this.stopwatchFactory,
  });
  final Stopwatch Function()? stopwatchFactory;
  final LocalDb? database;
  final DiagnosticsService? diagnostics;
  @override
  State<HarnessHome> createState() => _HarnessHomeState();
}

class _HarnessHomeState extends State<HarnessHome> {
  late final db = widget.database ?? LocalDb();
  late final diagnostics = widget.diagnostics ?? DiagnosticsService();
  DiagnosticCancellation? activeCancellation;
  final activeRuns = <String, _RunState>{};
  final exchangeDetails = ValueNotifier<List<HttpExchange>>([]);
  final selectedAttempt = ValueNotifier<int>(0);
  HarnessSettings settings = const HarnessSettings();
  String? expandedChannelId;
  final historyPages = <String, int>{};
  List<ModelActivity> liveActivities = [];
  List<RetryEvent> liveRetries = [];
  Timer? sampleTimer;
  Timer? activityFlushTimer;
  final outputRevision = ValueNotifier<int>(0);
  Widget? cachedModelOutput;
  DateTime? runStarted;
  int historySelection = 0;
  String? loadingHistoryId;
  final uuid = const Uuid();
  List<Upstream> ups = [];
  List<TestPrompt> prompts = [];
  Map<String, List<Map<String, Object?>>> historyByUpstream = {};
  List<HttpExchange> liveExchanges = [];
  Map<String, RateMetrics> rates = {};
  Upstream? selected;
  TestPrompt? selectedPrompt;
  Diagnostic? last;
  bool running = false;
  String liveOutput = '';
  int liveTps = 0;
  int liveTokens = 0;
  int? liveTcpConnectMs, liveTtft;
  List<SamplePoint> livePoints = [];
  String status = '就绪';
  int outputVersion = 0;
  bool sidebarExpanded = true;
  // The null entry also lets an empty workspace switch tabs before adding a channel.
  final workspaceTabs = <String?, int>{};
  final viewedHistories = <String, Diagnostic>{};
  int get workspaceTab => workspaceTabs[selected?.id] ?? 0;
  set workspaceTab(int value) {
    workspaceTabs[selected?.id] = value;
  }

  bool get viewingHistory => viewedHistories.containsKey(selected?.id);
  bool get channelRunning => activeRuns[selected?.id]?.running == true;
  String testModel = '';
  String reasoningEffort = 'default';
  String detectionMode = 'agent';
  late final customReasoning = TextEditingController();

  bool _reasoningEnabledFor(Upstream upstream, String model) {
    if (!hasKnownReasoningFormat(model)) return false;
    // Empty is the legacy value used by older in-memory/test records. Saved
    // DuckDB records contain an explicit set for each model.
    if (!upstream.reasoningConfigured) return true;
    return upstream.reasoningModels.contains(model);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final run in activeRuns.values) {
      run.cancellation.cancel();
    }
    sampleTimer?.cancel();
    activityFlushTimer?.cancel();
    outputRevision.dispose();
    selectedAttempt.dispose();
    exchangeDetails.dispose();
    customReasoning.dispose();
    if (widget.diagnostics == null) diagnostics.close();
    if (widget.database == null) unawaited(db.close());
    super.dispose();
  }

  void _stop() {
    final run = selected == null ? null : activeRuns[selected!.id];
    run?.cancellation.cancel();
    if (run != null) {
      run.status = '正在停止…';
      setState(() {
        if (!viewingHistory) status = run.status;
      });
    }
  }

  void _showRun(_RunState run) {
    last = run.last;
    liveOutput = run.output;
    liveActivities = List.of(run.activities);
    liveRetries = List.of(run.retries);
    liveExchanges = run.exchanges;
    livePoints = List.of(run.points);
    liveTokens = run.tokens;
    liveTps = run.tps;
    liveTcpConnectMs = run.tcpConnectMs;
    liveTtft = run.ttftMs;
    runStarted = run.startedAt;
    activeCancellation = run.cancellation;
    status = run.status;
    running = run.running;
    exchangeDetails.value = List.unmodifiable(run.exchanges);
  }

  void _syncRun(_RunState run, {bool rebuild = true}) {
    if (!mounted || selected?.id != run.upstreamId || viewingHistory) return;
    _showRun(run);
    if (rebuild) {
      setState(() {});
      outputRevision.value++;
    }
  }

  Future<void> _load() async {
    final a = await db.upstreams();
    final ps = await db.prompts();
    final h = await db.history();
    final rateSummary = await db.rates();
    final saved = await db.setting('prompt');
    final savedMode = await db.setting('detection_mode');
    final loadedSettings = await HarnessSettings.load(db);
    final groupedHistory = _groupHistory(h);
    final nextSelected =
        a.where((u) => u.id == selected?.id).firstOrNull ??
        (a.isEmpty ? null : a.first);
    final nextModel = nextSelected == null
        ? ''
        : (testModel.isNotEmpty && nextSelected.models.contains(testModel)
              ? testModel
              : nextSelected.selectedModel);
    final savedReasoning = nextSelected == null || nextModel.isEmpty
        ? null
        : await db.setting('reasoning:${nextSelected.id}:$nextModel');
    if (!mounted) return;
    setState(() {
      settings = loadedSettings;
      ups = a;
      prompts = ps;
      historyByUpstream = groupedHistory;
      rates = rateSummary;
      selected = nextSelected;
      testModel = nextModel;
      final available = reasoningOptionsForModel(nextModel);
      reasoningEffort = savedReasoning?.trim().isNotEmpty == true
          ? savedReasoning!.trim()
          : available.first.id;
      customReasoning.text =
          nextSelected != null && _reasoningEnabledFor(nextSelected, nextModel)
          ? ''
          : reasoningEffort == 'default'
          ? ''
          : reasoningEffort;
      selectedPrompt =
          ps.where((e) => e.id == saved).firstOrNull ??
          (ps.isEmpty ? null : ps.first);
      detectionMode = savedMode == 'single' ? 'single' : 'agent';
    });
  }

  Map<String, List<Map<String, Object?>>> _groupHistory(
    List<Map<String, Object?>> rows,
  ) {
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final id = row['upstream_id'] as String?;
      if (id != null) (grouped[id] ??= []).add(row);
    }
    return grouped;
  }

  Future<void> _editUpstream([Upstream? u]) async {
    final result = await showDialog<Upstream>(
      context: context,
      builder: (_) => UpstreamDialog(initial: u, id: uuid.v4()),
    );
    if (result != null) {
      if (selected?.id == result.id) {
        testModel = result.selectedModel;
        reasoningEffort = _reasoningEnabledFor(result, testModel)
            ? reasoningOptionsForModel(testModel).first.id
            : 'default';
      }
      await db.saveUpstream(result);
      await _load();
    }
  }

  Future<void> _editPrompt([TestPrompt? p]) async {
    final result = await showDialog<TestPrompt>(
      context: context,
      builder: (_) => PromptDialog(initial: p, id: uuid.v4()),
    );
    if (result != null) {
      await db.savePrompt(result);
      await db.setSetting('prompt', result.id);
      await _load();
    }
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      animationStyle: AnimationStyle.noAnimation,
      builder: (_) => SettingsDialog(db: db, settings: settings),
    );
    await _load();
  }

  Future<void> _run() async {
    if (selected == null || selectedPrompt == null) return;
    final upstream = selected!;
    if (activeRuns[upstream.id]?.running == true) return;
    final model = testModel.trim().isEmpty ? upstream.selectedModel : testModel;
    final runReasoningEffort =
        !hasKnownReasoningFormat(model) || _reasoningEnabledFor(upstream, model)
        ? reasoningEffort
        : 'default';
    final runDetectionMode = detectionMode;
    final runUpstream = upstream.copyWith(selectedModel: model);
    final prompt = selectedPrompt!;
    final config = settings;
    // Keep the Agent workspace stable between runs without awaiting a
    // platform plugin before the live run state is painted.
    final home = Platform.environment['HOME'];
    final base = Platform.isMacOS && home != null
        ? '$home/Library/Application Support/AI渠道检测'
        : Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? Directory.systemTemp.path)
        : (home == null
              ? Directory.systemTemp.path
              : '$home/.local/share/aijiance');
    final htmlWorkspace = Directory('$base/html-workspace');
    if (upstream.baseUrl.trim().isEmpty || upstream.apiKey.trim().isEmpty) {
      setState(() => status = '请先补全上游 Base URL 和 API Key');
      return;
    }
    if (model.trim().isEmpty) {
      setState(() => status = '请先在上游设置中选择模型');
      return;
    }
    historySelection++;
    loadingHistoryId = null;
    viewedHistories.remove(upstream.id);
    final cancellation = DiagnosticCancellation();
    activeCancellation = cancellation;
    final started = DateTime.now();
    final run = _RunState(upstream.id, cancellation, runDetectionMode)
      ..startedAt = started;
    activeRuns[upstream.id] = run;
    final exchanges = <HttpExchange>[];
    run.exchanges = exchanges;
    exchangeDetails.value = [];
    selectedAttempt.value = 0;
    final watch = (widget.stopwatchFactory ?? Stopwatch.new)()..start();
    final outputBuffer = StringBuffer();
    final pendingActivities = <(ModelActivity, int)>[];
    int? tcpConnectMs;
    setState(() {
      run.running = true;
      run.output = '';
      run.tcpConnectMs = null;
      run.ttftMs = null;
      run.activities = [];
      run.retries = [];
      run.tokens = 0;
      run.tps = 0;
      run.points = [const SamplePoint(0, 0)];
      workspaceTab = 0;
      historyPages[upstream.id] = 0;
      run.status = '连接上游…';
      run.last = null;
      outputVersion++;
      _showRun(run);
    });
    outputRevision.value++;
    int? ttft;
    int inputTokens = 0, outputTokens = 0;
    int? cacheRead, cacheWrite;
    int? totalTokens;
    final retries = <RetryEvent>[];
    String error = '';
    final tokensBySecond = <int, int>{};
    final recentTokens = Queue<(int, int)>();
    void sample({bool updateCurve = true}) {
      final elapsedMs = watch.elapsedMilliseconds;
      final second = elapsedMs ~/ 1000;
      // Current throughput is a rolling one-second count, without scaling
      // short fragment intervals into an instantaneous rate. The curve uses
      // fixed one-second buckets and keeps the current bucket provisional.
      while (recentTokens.isNotEmpty &&
          recentTokens.first.$1 <= elapsedMs - 1000) {
        run.tps -= recentTokens.removeFirst().$2;
      }
      if (updateCurve) {
        run.points = List.generate(
          second + 1,
          (index) => SamplePoint(
            index.toDouble(),
            (tokensBySecond[index] ?? 0).toDouble(),
          ),
        );
      }
    }

    run.sampleTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final previousTps = run.tps;
      final nextSecond = watch.elapsedMilliseconds ~/ 1000;
      final updateCurve = run.points.last.seconds != nextSecond;
      sample(updateCurve: updateCurve);
      if (updateCurve || previousTps != run.tps) _syncRun(run);
    });
    void flushActivities() {
      run.activityFlushTimer?.cancel();
      run.activityFlushTimer = null;
      if (!mounted) return;
      final events = [...run.activities];
      for (final (event, attempt) in pendingActivities) {
        var index = -1;
        if (event.kind == 'tool_call' || event.kind == 'html_artifact') {
          index = events.indexWhere(
            (e) =>
                e.kind == event.kind &&
                e.id == event.id &&
                e.attempt == attempt,
          );
        } else if (events.isNotEmpty &&
            events.last.kind == event.kind &&
            events.last.attempt == attempt) {
          index = events.length - 1;
        }
        final previous = index < 0 ? null : events[index];
        final next = ModelActivity(
          kind: event.kind,
          content: event.kind == 'html_artifact'
              ? event.content
              : '${previous?.content ?? ''}${event.content}',
          name: '${previous?.name ?? ''}${event.name}',
          id: event.id,
          attempt: attempt,
          elapsedMs: previous?.elapsedMs ?? watch.elapsedMilliseconds,
        );
        if (index < 0) {
          events.add(next);
        } else {
          events[index] = next;
        }
      }
      pendingActivities.clear();
      run.activities = events;
      sample();
      run.output = outputBuffer.toString();
      _syncRun(run);
    }

    void activity(ModelActivity event, int attempt) {
      if (cancellation.isCancelled || !mounted) return;
      final modelOutput = const {
        'output',
        'thinking',
        'tool_call',
      }.contains(event.kind);
      if (modelOutput && (event.content.isNotEmpty || event.name.isNotEmpty)) {
        ttft ??= watch.elapsedMilliseconds;
        run.ttftMs = ttft;
        final count = _estimateTokens(event.content);
        final elapsedMs = watch.elapsedMilliseconds;
        final second = elapsedMs ~/ 1000;
        tokensBySecond.update(second, (v) => v + count, ifAbsent: () => count);
        recentTokens.add((elapsedMs, count));
        run.tps += count;
        run.tokens += count;
      }
      if (event.kind == 'output') outputBuffer.write(event.content);
      pendingActivities.add((event, attempt));
      // Thinking is rendered in the activity stream; keep the compact status
      // pill stable so it does not duplicate the activity heading.
      run.status = '流式输出中';
      run.activityFlushTimer ??= Timer(
        const Duration(milliseconds: 100),
        flushActivities,
      );
    }

    final attempts = config.retryCount + 1;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        cancellation.throwIfCancelled();
        void onTcpConnected(int elapsedMs) {
          tcpConnectMs ??= elapsedMs;
          run.tcpConnectMs = tcpConnectMs;
          _syncRun(run);
        }

        void onExchange(HttpExchange exchange) {
          if (runDetectionMode == 'agent') {
            // Each Agent turn is a separate HTTP request. Preserve every
            // request/response pair so the diagnostic tab can inspect the
            // complete tool loop and retries.
            if (exchanges.isNotEmpty &&
                exchanges.last.startedAt == exchange.startedAt) {
              exchanges[exchanges.length - 1] = exchange;
            } else {
              exchanges.add(exchange);
            }
          } else if (exchanges.length < attempt) {
            exchanges.add(exchange);
          } else {
            exchanges[attempt - 1] = exchange;
          }
          run.exchanges = exchanges;
          if (mounted &&
              selected?.id == run.upstreamId &&
              !viewingHistory &&
              workspaceTab == 3) {
            exchangeDetails.value = List.unmodifiable(exchanges);
          }
          _syncRun(run, rebuild: false);
        }

        void onText(String text) =>
            activity(ModelActivity(kind: 'output', content: text), attempt);
        void onActivity(ModelActivity event) => activity(event, attempt);
        final result = runDetectionMode == 'agent'
            ? await diagnostics.agent(
                upstream: runUpstream,
                prompt: prompt,
                runtime: AgentToolRuntime(htmlWorkspace),
                onTcpConnected: onTcpConnected,
                onText: onText,
                onHtml: (html) {
                  // Keep the generated page in its artifact activity, separate
                  // from the original assistant reply and token metrics.
                  activity(
                    ModelActivity(
                      kind: 'html_artifact',
                      id: 'html-preview',
                      content: html,
                    ),
                    attempt,
                  );
                  flushActivities();
                },
                onActivity: onActivity,
                cancellation: cancellation,
                onExchange: onExchange,
                connectionTimeout: Duration(seconds: config.connectionTimeout),
                idleTimeout: Duration(seconds: config.idleTimeout),
                reasoningEffort: runReasoningEffort,
              )
            : await diagnostics.stream(
                upstream: runUpstream,
                prompt: prompt,
                onTcpConnected: onTcpConnected,
                onText: onText,
                onActivity: onActivity,
                cancellation: cancellation,
                onExchange: onExchange,
                connectionTimeout: Duration(seconds: config.connectionTimeout),
                idleTimeout: Duration(seconds: config.idleTimeout),
                reasoningEffort: runReasoningEffort,
              );
        cancellation.throwIfCancelled();
        run.output = outputBuffer.toString();
        inputTokens =
            result.inputTokens ?? (prompt.content.length / 3.5).ceil();
        outputTokens = result.outputTokens ?? run.tokens;
        totalTokens = result.totalTokens;
        cacheRead = result.cacheReadTokens;
        cacheWrite = result.cacheWriteTokens;
        error = '';
        break;
      } on DiagnosticCancelled {
        error = '用户已停止';
        break;
      } catch (e) {
        if (cancellation.isCancelled) {
          error = '用户已停止';
          break;
        }
        error = e.toString();
        retries.add(
          RetryEvent(
            DateTime.now(),
            '请求失败：$e',
            attempt,
            elapsedMs: watch.elapsedMilliseconds,
          ),
        );
        if (mounted) {
          run.retries = List.of(retries);
          sample();
          _syncRun(run);
        }
        if (run.activities.isNotEmpty || attempt == attempts) break;
        try {
          await cancellation.delay(Duration(milliseconds: 250 * attempt));
        } on DiagnosticCancelled {
          error = '用户已停止';
          break;
        }
      }
    }
    if (error.isNotEmpty) {
      inputTokens = (prompt.content.length / 3.5).ceil();
      outputTokens = run.tokens;
    }
    flushActivities();
    run.activityFlushTimer?.cancel();
    run.activityFlushTimer = null;
    run.sampleTimer?.cancel();
    run.sampleTimer = null;
    sample();
    watch.stop();
    if (selected?.id == run.upstreamId) activeCancellation = null;
    final d = Diagnostic(
      id: uuid.v4(),
      upstreamId: upstream.id,
      upstreamName: upstream.name,
      model: model,
      promptName: prompt.name,
      prompt: prompt.content,
      output: run.output,
      startedAt: started.toIso8601String(),
      durationMs: watch.elapsedMilliseconds,
      firstByteMs: 0,
      tcpConnectMs: tcpConnectMs,
      ttftMs: ttft ?? 0,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens ?? inputTokens + outputTokens,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      points: run.points,
      streamMode: true,
      detectionMode: runDetectionMode,
      retries: retries,
      error: error,
      exchanges: List.unmodifiable(exchanges),
      activities: List.unmodifiable(run.activities),
    );
    try {
      await db.saveDiagnostic(d);
      final h = await db.history();
      final rateSummary = await db.rates();
      if (mounted) {
        setState(() {
          run.last = d;
          historyByUpstream = _groupHistory(h);
          rates = rateSummary;
          run.status = cancellation.isCancelled
              ? '已停止'
              : error.isEmpty
              ? '检测完成'
              : '检测完成（含错误）';
          if (selected?.id == run.upstreamId && !viewingHistory) {
            _showRun(run);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          run.last = d;
          run.status = '记录保存失败：$e';
          if (selected?.id == run.upstreamId && !viewingHistory) {
            _showRun(run);
          }
        });
      }
    } finally {
      run.running = false;
      if (mounted && selected?.id == run.upstreamId) {
        setState(() {
          if (!viewingHistory) {
            _showRun(run);
            outputVersion++;
          }
        });
      }
    }
  }

  /// Token usage is taken from the provider's final usage event when available.
  /// During streaming, this small estimate keeps the live curve responsive.
  static final _asciiWords = RegExp(r'[A-Za-z0-9_]+');

  int _estimateTokens(String text) {
    if (text.isEmpty) return 0;
    var count = _asciiWords.allMatches(text).length;
    for (final rune in text.runes) {
      if (rune > 0x7f) count++;
    }
    return count == 0 ? 1 : count;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: sidebarExpanded ? 300 : 52,
            child: sidebarExpanded ? _sidebar() : _collapsedSidebar(),
          ),
          Expanded(child: _workspace()),
        ],
      ),
    ),
  );
  Widget _collapsedSidebar() => Container(
    decoration: const BoxDecoration(
      color: panel,
      border: Border(right: BorderSide(color: line)),
    ),
    child: Column(
      children: [
        const SizedBox(height: 14),
        IconButton(
          tooltip: '展开侧栏',
          onPressed: () => setState(() => sidebarExpanded = true),
          icon: const Icon(Icons.menu_open_rounded),
        ),
        const Icon(Icons.radar_rounded, color: teal),
        const Spacer(),
        IconButton(
          tooltip: '全局设置',
          onPressed: channelRunning ? null : _openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
  );
  Widget _sidebar() => Container(
    decoration: const BoxDecoration(
      color: panel,
      border: Border(right: BorderSide(color: line)),
    ),
    padding: const EdgeInsets.fromLTRB(18, 16, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: teal.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.radar_rounded, color: teal),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI质量检测',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
            const Spacer(),
            IconButton(
              tooltip: '收起侧栏',
              onPressed: () => setState(() => sidebarExpanded = false),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionLabel('上游连接', Icons.hub_outlined, onTap: () => _editUpstream()),
        const SizedBox(height: 8),
        Expanded(
          child: ups.isEmpty
              ? _emptySide('还没有上游')
              : ListView.builder(
                  itemCount: ups.length,
                  itemBuilder: (context, index) {
                    final upstream = ups[index];
                    final item = Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _upstreamTile(upstream),
                        if (upstream.id == expandedChannelId)
                          ..._channelHistory(upstream),
                      ],
                    );
                    return item;
                  },
                ),
        ),
        const Divider(color: line),
        _sectionLabel(
          '检测提示词',
          Icons.psychology_outlined,
          onTap: () => _editPrompt(),
        ),
        const SizedBox(height: 8),
        if (prompts.isEmpty)
          _emptySide('还没有提示词')
        else
          SizedBox(
            height: MediaQuery.sizeOf(context).height < 800 ? 140 : 190,
            child: ListView(
              children: prompts
                  .map(
                    (p) => Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          p.id == selectedPrompt?.id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 17,
                          color: p.id == selectedPrompt?.id ? teal : muted,
                        ),
                        title: Text(
                          p.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: p.id == selectedPrompt?.id ? ink : muted,
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(
                            Icons.more_horiz,
                            size: 16,
                            color: muted,
                          ),
                          onSelected: (action) async {
                            if (action == 'edit') await _editPrompt(p);
                            if (action == 'delete') {
                              await db.deletePrompt(p.id);
                              await _load();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                        onTap: () async {
                          await db.setSetting('prompt', p.id);
                          setState(() => selectedPrompt = p);
                        },
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        const Divider(),
        TextButton.icon(
          onPressed: channelRunning ? null : _openSettings,
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('全局设置'),
        ),
      ],
    ),
  );
  Widget _sectionLabel(String text, IconData icon, {VoidCallback? onTap}) =>
      Row(
        children: [
          Icon(icon, size: 16, color: muted),
          const SizedBox(width: 7),
          Text(
            text,
            style: const TextStyle(
              color: muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: .6,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onTap,
            icon: const Icon(Icons.add, size: 18),
            color: teal,
            tooltip: '添加',
          ),
        ],
      );
  Widget _emptySide(String title) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 26),
    child: Column(
      children: [
        Icon(Icons.inbox_outlined, color: muted.withValues(alpha: .6)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(color: muted, fontSize: 12)),
      ],
    ),
  );
  Widget _upstreamTile(Upstream u) {
    final active = u.id == selected?.id;
    final backgroundRunning = activeRuns[u.id]?.running == true;
    return InkWell(
      onTap: () => _selectUpstream(u),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: active ? teal.withValues(alpha: .1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? teal.withValues(alpha: .4) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: active
                    ? teal
                    : backgroundRunning
                    ? orange
                    : muted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    u.name,
                    style: TextStyle(
                      color: active ? ink : muted,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    backgroundRunning
                        ? '检测中 · ${u.selectedModel.isEmpty ? '未选模型' : u.selectedModel}'
                        : u.selectedModel.isEmpty
                        ? '未选模型'
                        : u.selectedModel,
                    style: const TextStyle(color: muted, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              expandedChannelId == u.id ? Icons.expand_less : Icons.expand_more,
              size: 17,
              color: muted,
            ),
            PopupMenuButton<String>(
              enabled: activeRuns[u.id]?.running != true,
              icon: const Icon(Icons.more_horiz, size: 17, color: muted),
              onSelected: (v) async {
                if (v == 'edit') _editUpstream(u);
                if (v == 'delete') {
                  await db.deleteUpstream(u.id);
                  await _load();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _workspace() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AI 检测工作区',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    selected == null
                        ? ''
                        : '${last?.upstreamName ?? selected!.name}  /  ${last?.promptName ?? selectedPrompt?.name ?? '未选择提示词'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  if (selected != null) ...[
                    const SizedBox(height: 8),
                    _modelControls(),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (status != '历史记录') ...[_statusPill(), const SizedBox(width: 8)],
            if (viewingHistory && activeRuns.containsKey(selected?.id)) ...[
              TextButton(
                onPressed: _returnToRun,
                child: Text(channelRunning ? '返回当前测试' : '返回最近测试'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.icon(
              onPressed: channelRunning
                  ? (selected == null ||
                            activeRuns[selected!.id]
                                    ?.cancellation
                                    .isCancelled ==
                                true
                        ? null
                        : _stop)
                  : selected == null || selectedPrompt == null
                  ? null
                  : _run,
              icon: Icon(
                channelRunning
                    ? Icons.stop_circle_outlined
                    : Icons.play_arrow_rounded,
              ),
              label: Text(channelRunning ? '停止检测' : '开始 AI 检测'),
              style: FilledButton.styleFrom(
                backgroundColor: channelRunning ? red : teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _workspaceTabs(),
        const SizedBox(height: 12),
        Expanded(
          child: IndexedStack(
            index: workspaceTab,
            children: [
              _RetainedWorkspacePage(
                active: workspaceTab == 0,
                version: outputVersion,
                builder: _outputCard,
              ),
              _RetainedWorkspacePage(
                active: workspaceTab == 1,
                version: outputVersion,
                builder: () => SingleChildScrollView(
                  child: Column(
                    children: [
                      _metricsRow(),
                      const SizedBox(height: 12),
                      SizedBox(height: 530, child: _detailPanel()),
                    ],
                  ),
                ),
              ),
              _RetainedWorkspacePage(
                active: workspaceTab == 2,
                version: outputVersion,
                builder: _faultPanel,
              ),
              _card(
                RequestDetailsView(
                  key: ValueKey(outputVersion),
                  exchanges: exchangeDetails,
                  selectedAttempt: selectedAttempt,
                  active: workspaceTab == 3,
                  loadLogs:
                      status == '历史记录' &&
                          last != null &&
                          last!.exchanges.any((e) => e.storedChunkCount != null)
                      ? (attempt, after, limit) => db.logPage(
                          last!.id,
                          attempt,
                          afterSecond: after,
                          limit: limit,
                        )
                      : null,
                  loadExchange:
                      status == '历史记录' &&
                          last != null &&
                          last!.exchanges.any((e) => e.storedChunkCount != null)
                      ? (attempt) => db.fullExchange(last!.id, attempt)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _workspaceTabs() => Row(
    children: [
      _workspaceTabButton('实时输出', Icons.article_outlined, 0),
      const SizedBox(width: 6),
      _workspaceTabButton('检测指标', Icons.query_stats_rounded, 1),
      const SizedBox(width: 6),
      _workspaceTabButton('故障与重试', Icons.bug_report_outlined, 2),
      const SizedBox(width: 6),
      _workspaceTabButton('诊断详情', Icons.data_object, 3),
    ],
  );

  Widget _modelControls() {
    final models = selected!.models.isEmpty
        ? [if (testModel.isNotEmpty) testModel]
        : selected!.models;
    final modelValue = models.contains(testModel) ? testModel : null;
    final options = reasoningOptionsForModel(testModel);
    final known = _reasoningEnabledFor(selected!, testModel);
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('检测模式', style: TextStyle(color: muted, fontSize: 11)),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: _dropdownBox(disabled: channelRunning),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: detectionMode,
              isDense: true,
              borderRadius: BorderRadius.circular(12),
              dropdownColor: panel,
              icon: const Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: teal,
              ),
              items: const [
                DropdownMenuItem(
                  value: 'agent',
                  child: Text('Agent 工作流', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: 'single',
                  child: Text('单轮流式', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: channelRunning
                  ? null
                  : (value) async {
                      if (value == null) return;
                      await db.setSetting('detection_mode', value);
                      if (mounted) setState(() => detectionMode = value);
                    },
            ),
          ),
        ),
        const SizedBox(width: 4),
        const Text('测试模型', style: TextStyle(color: muted, fontSize: 11)),
        if (models.length > 1)
          SizedBox(
            width: 190,
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: _dropdownBox(disabled: channelRunning),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: modelValue,
                  isDense: true,
                  borderRadius: BorderRadius.circular(12),
                  dropdownColor: panel,
                  items: models
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(
                            value,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: channelRunning
                      ? null
                      : (value) {
                          if (value != null) _selectTestModel(value);
                        },
                ),
              ),
            ),
          )
        else
          Text(
            testModel.isEmpty ? '未选择模型' : testModel,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        const Text('推理强度', style: TextStyle(color: muted, fontSize: 11)),
        if (known)
          _reasoningPicker(options, reasoningEffort)
        else if (hasKnownReasoningFormat(testModel))
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: _dropdownBox(disabled: true),
            alignment: Alignment.centerLeft,
            child: const Text(
              '未启用推理',
              style: TextStyle(color: muted, fontSize: 12),
            ),
          )
        else
          SizedBox(
            width: 190,
            child: TextField(
              controller: customReasoning,
              enabled: !channelRunning,
              onChanged: _setCustomReasoning,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '自定义参数值',
                hintText: 'reasoning_effort',
              ),
            ),
          ),
      ],
    );
  }

  Widget _reasoningPicker(
    List<ReasoningOption> options,
    String selectedValue,
  ) => PopupMenuButton<String>(
    enabled: !channelRunning && options.length > 1,
    tooltip: '选择推理强度',
    position: PopupMenuPosition.under,
    elevation: 8,
    color: panel,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: line),
    ),
    onSelected: _selectReasoning,
    itemBuilder: (_) => [
      for (final option in [
        ...options,
        if (!options.any((option) => option.id == selectedValue))
          ReasoningOption(
            selectedValue,
            reasoningLabel(testModel, selectedValue),
          ),
      ])
        PopupMenuItem(
          value: option.id,
          height: 42,
          child: Row(
            children: [
              Icon(
                option.id == selectedValue
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 17,
                color: option.id == selectedValue ? teal : muted,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(option.label)),
            ],
          ),
        ),
      const PopupMenuItem(value: '__custom__', child: Text('自定义…')),
    ],
    child: Container(
      width: 190,
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: _dropdownBox(disabled: channelRunning),
      child: Row(
        children: [
          Expanded(
            child: Text(
              reasoningLabel(testModel, selectedValue),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.expand_more_rounded,
            size: 18,
            color: channelRunning ? muted : teal,
          ),
        ],
      ),
    ),
  );

  Widget _workspaceTabButton(String label, IconData icon, int index) {
    final active = workspaceTab == index;
    return TextButton.icon(
      onPressed: () {
        if (workspaceTab == index) return;
        if (index == 3) {
          exchangeDetails.value = List.unmodifiable(liveExchanges);
        }
        setState(() => workspaceTab = index);
      },
      icon: Icon(icon, size: 17),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: active ? teal : muted,
        backgroundColor: active
            ? teal.withValues(alpha: .09)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }

  Widget _statusPill() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: (running ? orange : teal).withValues(alpha: .1),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(
        color: (running ? orange : teal).withValues(alpha: .35),
      ),
    ),
    child: Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: running ? orange : teal,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          status,
          style: TextStyle(color: running ? orange : teal, fontSize: 11),
        ),
      ],
    ),
  );
  Widget _outputCard() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('模型输出', style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (last != null)
              Text(
                last!.model,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              key: const ValueKey('export-html'),
              onPressed: last == null || running ? null : _exportReport,
              icon: const Icon(Icons.file_download_outlined, size: 17),
              label: const Text('导出 HTML'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('upload-cloud'),
              onPressed: last == null || running ? null : _uploadCloud,
              icon: const Icon(Icons.cloud_upload_outlined, size: 17),
              label: const Text('上传云端'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: outputRevision,
            builder: (context, _, _) {
              if (workspaceTab != 0) {
                return cachedModelOutput ?? const SizedBox.shrink();
              }
              return cachedModelOutput =
                  liveOutput.isEmpty && liveActivities.isEmpty
                  ? const SizedBox.shrink()
                  : ModelOutputView(
                      key: ValueKey(outputVersion),
                      output: liveOutput,
                      activities: liveActivities,
                      receiving: running,
                      autoPreviewHtml:
                          (running
                              ? activeRuns[selected?.id]?.detectionMode
                              : last?.detectionMode ?? detectionMode) ==
                          'agent',
                    );
            },
          ),
        ),
      ],
    ),
  );
  RateMetrics? get _rates => rates[last?.upstreamId ?? selected?.id];

  Widget _metricsRow() => Column(
    children: [
      SizedBox(
        height: 164,
        child: GridView(
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 10,
            mainAxisSpacing: 8,
            mainAxisExtent: 78,
          ),
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _metric(
              '首 token 延时',
              (last?.ttftMs ?? liveTtft) == null
                  ? '--'
                  : secondsText(last?.ttftMs ?? liveTtft!),
              Icons.bolt_rounded,
              teal,
            ),
            _metric(
              running ? '当前吞吐' : '平均吞吐',
              running || last == null
                  ? '${tokenText(liveTps)} token/s'
                  : '${tokenText(last!.averageTps)} token/s',
              Icons.speed_rounded,
              const Color(0xff3d72b4),
            ),
            _metric(
              '总 token',
              last == null
                  ? '${tokenText(liveTokens)} token'
                  : '${tokenText(last!.totalTokens)} token',
              Icons.token_rounded,
              const Color(0xff9757a4),
            ),
            _metric(
              '输入 token',
              last == null ? '--' : '${tokenText(last!.inputTokens)} token',
              Icons.input_rounded,
              const Color(0xff3d72b4),
            ),
            _metric(
              '输出 token',
              last == null ? '--' : '${tokenText(last!.outputTokens)} token',
              Icons.output_rounded,
              const Color(0xff9757a4),
            ),
            _metric(
              '平均 RPM',
              _rates == null ? '--' : numberText(_rates!.rpm),
              Icons.sync_rounded,
              orange,
              unit: 'req/min',
            ),
            _metric(
              '平均 TPM',
              _rates == null ? '--' : tokenText(_rates!.tpm),
              Icons.data_usage_rounded,
              teal,
              unit: 'token/min',
            ),
            _metric(
              '平均 token 延时',
              last == null
                  ? '--'
                  : '${secondsText(last!.averageLatencyMs)}/token',
              Icons.timer_outlined,
              orange,
            ),
          ],
        ),
      ),
      if (last != null || liveTcpConnectMs != null) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _secondaryMetrics(),
            style: const TextStyle(color: muted, fontSize: 11),
          ),
        ),
      ],
    ],
  );

  String _secondaryMetrics() {
    final diagnostic = last;
    final tcpConnectMs = diagnostic?.tcpConnectMs ?? liveTcpConnectMs;
    final tcpDelay = tcpConnectMs == null
        ? '--'
        : '${tokenText(tcpConnectMs)} ms';
    return [
      'TCP 连接成功延时 $tcpDelay',
      if (diagnostic != null) ...[
        '缓存读取 ${cacheTokenText(diagnostic.cacheReadTokens, suffix: ' token')}',
        '缓存写入 ${cacheTokenText(diagnostic.cacheWriteTokens, suffix: ' token')}',
        '缓存命中率 ${cacheHitRateText(diagnostic.cacheHitRate)}',
        '总耗时 ${secondsText(diagnostic.durationMs)}',
      ],
    ].join('  ·  ');
  }

  Widget _metric(
    String title,
    String value,
    IconData icon,
    Color color, {
    String? unit,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: line),
    ),
    child: Row(
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 10),
              ),
              const SizedBox(height: 3),
              Text(
                unit == null ? value : '$value $unit',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  void _selectUpstream(Upstream upstream) {
    if (selected?.id == upstream.id) {
      setState(
        () => expandedChannelId = expandedChannelId == upstream.id
            ? null
            : upstream.id,
      );
      return;
    }
    historySelection++;
    final existingRun = activeRuns[upstream.id];
    exchangeDetails.value = [];
    liveExchanges = [];
    setState(() {
      selected = upstream;
      testModel = upstream.selectedModel;
      reasoningEffort = _reasoningEnabledFor(upstream, testModel)
          ? reasoningOptionsForModel(testModel).first.id
          : 'default';
      customReasoning.text = '';
      expandedChannelId = upstream.id;
      loadingHistoryId = null;
      selectedAttempt.value = 0;
      outputVersion++;
      outputRevision.value++;
      final history = viewedHistories[upstream.id];
      if (history != null) {
        _showHistory(history);
      } else if (existingRun != null) {
        _showRun(existingRun);
      } else {
        liveActivities = [];
        liveRetries = [];
        last = null;
        liveOutput = '';
        livePoints = [];
        liveTokens = 0;
        liveTps = 0;
        liveTcpConnectMs = null;
        liveTtft = null;
        runStarted = null;
        running = false;
        activeCancellation = null;
        status = '就绪';
      }
    });
    _restoreReasoning(upstream.id, testModel);
  }

  Future<void> _restoreReasoning(String upstreamId, String model) async {
    final saved = model.isEmpty
        ? null
        : await db.setting('reasoning:$upstreamId:$model');
    if (!mounted || selected?.id != upstreamId || testModel != model) return;
    final options = reasoningOptionsForModel(model);
    final chosen = saved?.trim().isNotEmpty == true
        ? saved!.trim()
        : options.first.id;
    setState(() {
      reasoningEffort = chosen;
      customReasoning.text = chosen == 'default' ? '' : chosen;
    });
  }

  void _selectTestModel(String model) {
    final options = reasoningOptionsForModel(model);
    final enabled = selected != null && _reasoningEnabledFor(selected!, model);
    setState(() {
      testModel = model;
      reasoningEffort = enabled ? options.first.id : 'default';
      customReasoning.text = '';
    });
    if (selected != null) _restoreReasoning(selected!.id, model);
  }

  Future<void> _selectReasoning(String value) async {
    if (value == '__custom__') {
      var draft = reasoningEffort == 'default' ? '' : reasoningEffort;
      final custom = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('自定义推理强度'),
          content: TextFormField(
            initialValue: draft,
            onChanged: (value) => draft = value,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '参数值',
              hintText: '填写上游支持的 reasoning_effort 值',
            ),
            onFieldSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (draft.trim().isNotEmpty) {
                  Navigator.pop(context, draft.trim());
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (!mounted || custom == null) return;
      value = custom;
    }
    setState(() => reasoningEffort = value);
    if (selected != null && testModel.isNotEmpty) {
      await db.setSetting('reasoning:${selected!.id}:$testModel', value);
    }
  }

  void _setCustomReasoning(String value) {
    setState(() => reasoningEffort = value);
    if (selected != null && testModel.isNotEmpty) {
      unawaited(db.setSetting('reasoning:${selected!.id}:$testModel', value));
    }
  }

  Future<void> _openHistory(Map<String, Object?> row) async {
    final version = ++historySelection;
    final id = row['id'] as String;
    setState(() => loadingHistoryId = id);
    try {
      final read = await db.diagnosticRead(id, includeChunks: false);
      final diagnostic = read?.diagnostic;
      if (!mounted || version != historySelection) return;
      if (diagnostic == null) throw StateError('记录不存在');
      setState(() {
        loadingHistoryId = null;
        viewedHistories[diagnostic.upstreamId] = diagnostic;
        _showHistory(diagnostic);
        workspaceTab = 0;
      });
    } catch (e) {
      if (mounted && version == historySelection) {
        setState(() {
          loadingHistoryId = null;
          status = '读取记录失败：$e';
        });
      }
    }
  }

  void _showHistory(Diagnostic diagnostic) {
    last = diagnostic;
    running = false;
    liveOutput = diagnostic.output;
    liveActivities = diagnostic.activities;
    liveRetries = diagnostic.retries;
    liveExchanges = diagnostic.exchanges;
    exchangeDetails.value = diagnostic.exchanges;
    runStarted = DateTime.tryParse(diagnostic.startedAt);
    liveTcpConnectMs = diagnostic.tcpConnectMs;
    liveTtft = diagnostic.ttftMs;
    selectedAttempt.value = 0;
    livePoints = diagnostic.points;
    liveTokens = diagnostic.outputTokens;
    liveTps = 0;
    outputVersion++;
    outputRevision.value++;
    status = '历史记录';
  }

  void _returnToRun() {
    final run = activeRuns[selected?.id];
    if (run == null) return;
    historySelection++;
    setState(() {
      loadingHistoryId = null;
      viewedHistories.remove(run.upstreamId);
      selectedAttempt.value = 0;
      _showRun(run);
      outputVersion++;
      outputRevision.value++;
    });
  }

  Future<void> _deleteHistory(Map<String, Object?> row) async {
    if (channelRunning) return;
    final id = row['id'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除测试记录'),
        content: const Text('将删除这次测试的输出、指标、曲线和请求详情。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await db.deleteDiagnostic(id);
    viewedHistories.removeWhere((_, diagnostic) => diagnostic.id == id);
    for (final entry in activeRuns.entries.toList()) {
      if (entry.value.last?.id == id && !entry.value.running) {
        activeRuns.remove(entry.key);
      }
    }
    if (last?.id == id) {
      exchangeDetails.value = [];
      setState(() {
        last = null;
        liveOutput = '';
        liveActivities = [];
        liveRetries = [];
        livePoints = [];
        liveTokens = 0;
        liveTps = 0;
        liveTcpConnectMs = null;
        liveTtft = null;
        runStarted = null;
        outputVersion++;
        outputRevision.value++;
        status = '就绪';
      });
    }
    final rows = await db.history();
    if (mounted) {
      setState(() => historyByUpstream = _groupHistory(rows));
    }
  }

  List<Widget> _channelHistory(Upstream upstream) {
    final rows = historyByUpstream[upstream.id] ?? const [];
    final pageCount = ((rows.length + 4) ~/ 5).clamp(1, 100000000);
    final page = (historyPages[upstream.id] ?? 0).clamp(0, pageCount - 1);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 0, 6),
        child: Text(
          '检测历史 · ${rows.length}',
          style: const TextStyle(color: muted, fontSize: 11),
        ),
      ),
      if (rows.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 8, 0, 12),
          child: Text('暂无检测记录', style: TextStyle(color: muted, fontSize: 11)),
        ),
      for (final row in rows.skip(page * 5).take(5))
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: _historyTile(row),
        ),
      if (rows.length > 5)
        Row(
          children: [
            const Spacer(),
            IconButton(
              tooltip: '上一页历史',
              onPressed: page == 0
                  ? null
                  : () => setState(() => historyPages[upstream.id] = page - 1),
              icon: const Icon(Icons.chevron_left, size: 18),
            ),
            Text(
              '${page + 1}/$pageCount',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
            IconButton(
              tooltip: '下一页历史',
              onPressed: page + 1 >= pageCount
                  ? null
                  : () => setState(() => historyPages[upstream.id] = page + 1),
              icon: const Icon(Icons.chevron_right, size: 18),
            ),
          ],
        ),
    ];
  }

  Widget _historyTile(Map<String, Object?> row) {
    final active = row['id'] == last?.id;
    final date = DateTime.tryParse(
      row['started_at'] as String? ?? '',
    )?.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    final time = date == null
        ? ''
        : '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
    final failed = (row['error'] as String? ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: active ? teal.withValues(alpha: .09) : panel2,
        borderRadius: BorderRadius.circular(6),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: ValueKey('history-${row['id']}'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => _openHistory(row),
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            failed ? Icons.error_outline : Icons.history,
                            size: 13,
                            color: failed ? red : teal,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              time,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: muted,
                              ),
                            ),
                          ),
                          if (loadingHistoryId == row['id'])
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${row['prompt_name']} · ${row['model']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Stream · ${secondsText(row['duration_ms'] as int? ?? 0)} · ${tokenText(row['total_tokens'] as num? ?? 0)} token',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                      if (failed)
                        Text(
                          row['error'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: red),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (loadingHistoryId != row['id'])
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: IconButton(
                  key: ValueKey('history-delete-${row['id']}'),
                  tooltip: '删除测试记录',
                  onPressed: channelRunning ? null : () => _deleteHistory(row),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  style: IconButton.styleFrom(
                    foregroundColor: muted,
                    hoverColor: red.withValues(alpha: .09),
                    minimumSize: const Size(32, 32),
                    padding: const EdgeInsets.all(6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportReport() async {
    final report = last;
    if (report == null) return;
    final reportRates = _rates;
    final safeModel = report.model.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    const group = XTypeGroup(label: 'HTML', extensions: ['html']);
    try {
      final location = await getSaveLocation(
        suggestedName:
            'AI质量检测-$safeModel-${DateTime.now().toIso8601String().substring(0, 10)}.html',
        acceptedTypeGroups: [group],
      );
      if (location == null) return;
      final bytes = Uint8List.fromList(
        utf8.encode(await diagnosticHtml(report, rates: reportRates)),
      );
      await XFile.fromData(bytes, mimeType: 'text/html').saveTo(location.path);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('报告已导出：${location.path}')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('报告导出失败：$error')));
      }
    }
  }

  Future<void> _uploadCloud() async {
    final report = last;
    final upstream = selected;
    if (report == null || upstream == null) return;
    try {
      final url = await CloudClient().uploadReport(
        apiBaseUrl: settings.cloudApiUrl,
        clientKey: settings.cloudClientKey,
        diagnostic: report,
        upstreamBaseUrl: upstream.baseUrl,
        rates: _rates,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('报告已上传'),
          content: SelectableText(url),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制链接'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('上传失败：$e')));
      }
    }
  }

  void _showFault(int attempt) {
    selectedAttempt.value = attempt - 1;
    exchangeDetails.value = List.unmodifiable(liveExchanges);
    setState(() => workspaceTab = 3);
  }

  Widget _faultPanel() => _card(
    Column(
      children: [
        Expanded(
          child: liveRetries.isEmpty
              ? const Center(child: Text('无故障或重试记录'))
              : ListView.builder(
                  itemCount: liveRetries.length,
                  itemBuilder: (_, index) {
                    final event = liveRetries[index];
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.error_outline,
                          color: red,
                          size: 18,
                        ),
                        title: Text(
                          event.reason.length > 2048
                              ? '${event.reason.substring(0, 2048)}…'
                              : event.reason,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          '第 ${event.attempt} 次请求 · ${secondsText(event.elapsedMs ?? (runStarted == null ? 0 : event.at.difference(runStarted!).inMilliseconds))}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => _showFault(event.attempt),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );

  Widget _detailPanel() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('实时吞吐曲线（估算）', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Expanded(
          child: ThroughputChart(
            key: ValueKey(outputVersion),
            points: livePoints,
            retries: liveRetries,
            startedAt: runStarted,
            onFault: _showFault,
          ),
        ),
      ],
    ),
  );

  Widget _card(Widget child) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: line),
    ),
    child: child,
  );
}

/// Build only the visited, active page while retaining its scroll/chart state.
class _RetainedWorkspacePage extends StatefulWidget {
  const _RetainedWorkspacePage({
    required this.active,
    required this.version,
    required this.builder,
  });
  final bool active;
  final int version;
  final Widget Function() builder;
  @override
  State<_RetainedWorkspacePage> createState() => _RetainedWorkspacePageState();
}

class _RetainedWorkspacePageState extends State<_RetainedWorkspacePage> {
  Widget? content;
  @override
  void didUpdateWidget(covariant _RetainedWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version != widget.version) content = null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.active) content = widget.builder();
    return content ?? const SizedBox.shrink();
  }
}

class UpstreamDialog extends StatefulWidget {
  const UpstreamDialog({super.key, this.initial, required this.id});
  final Upstream? initial;
  final String id;
  @override
  State<UpstreamDialog> createState() => _UpstreamDialogState();
}

class _UpstreamDialogState extends State<UpstreamDialog> {
  late final name = TextEditingController(text: widget.initial?.name ?? '');
  late final url = TextEditingController(text: widget.initial?.baseUrl ?? '');
  late final key = TextEditingController(text: widget.initial?.apiKey ?? '');
  late final note = TextEditingController(text: widget.initial?.note ?? '');
  late final manualModel = TextEditingController(
    text: widget.initial?.selectedModel ?? '',
  );
  late final newModel = TextEditingController();
  late final proxyHost = TextEditingController(
    text: widget.initial?.proxy.host ?? '127.0.0.1',
  );
  late final proxyPort = TextEditingController(
    text: '${widget.initial?.proxy.port ?? 7890}',
  );
  late String proxyType = widget.initial?.proxy.type ?? 'none';

  ChannelProxy get proxy => ChannelProxy(
    type: proxyType,
    host: proxyHost.text.trim(),
    port: int.tryParse(proxyPort.text.trim()) ?? 0,
  );
  List<String> models = [];
  Set<String> reasoningModels = <String>{};
  bool reasoningConfigured = false;
  String model = '';
  bool loading = false;
  String? modelError;
  bool testing = false;
  String? testMessage;
  bool testOk = false;
  String? validationError;

  @override
  void initState() {
    super.initState();
    models = widget.initial?.models ?? [];
    reasoningModels = widget.initial?.reasoningModels.toSet() ?? <String>{};
    reasoningConfigured = widget.initial?.reasoningConfigured ?? false;
    model = widget.initial?.selectedModel ?? '';
  }

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    key.dispose();
    note.dispose();
    manualModel.dispose();
    newModel.dispose();
    proxyHost.dispose();
    proxyPort.dispose();
    super.dispose();
  }

  void addModel(String value) {
    final added = value.trim();
    if (added.isEmpty) return;
    setState(() {
      if (!models.contains(added)) models = [...models, added];
      reasoningConfigured = true;
      if (hasKnownReasoningFormat(added)) reasoningModels.add(added);
      model = added;
      manualModel.text = added;
      newModel.clear();
      validationError = null;
    });
  }

  void removeModel(String value) {
    setState(() {
      models = models.where((entry) => entry != value).toList();
      reasoningModels.remove(value);
      if (model == value) {
        model = models.firstOrNull ?? '';
        manualModel.text = model;
      }
    });
  }

  Future<void> fetchModels() async {
    if (url.text.trim().isEmpty || key.text.trim().isEmpty) {
      setState(() => modelError = '请先填写 Base URL 和 API Key');
      return;
    }
    setState(() {
      loading = true;
      modelError = null;
    });
    final service = DiagnosticsService();
    try {
      final fetched = await service.fetchModels(
        upstream: Upstream(
          id: widget.id,
          name: name.text,
          baseUrl: url.text.trim(),
          apiKey: key.text.trim(),
          models: models,
          proxy: proxy,
        ),
      );
      if (!mounted) return;
      final existing = {
        ...models,
        if (model.trim().isNotEmpty) model.trim(),
      }.toList();
      final selected = await showDialog<List<String>>(
        context: context,
        builder: (_) =>
            ModelSelectionDialog(models: fetched, selected: existing),
      );
      if (!mounted || selected == null) return;
      if (!reasoningConfigured) {
        reasoningModels.addAll(existing.where(hasKnownReasoningFormat));
      }
      reasoningModels = {
        ...reasoningModels.where(selected.contains),
        ...selected.where(
          (entry) =>
              !existing.contains(entry) && hasKnownReasoningFormat(entry),
        ),
      };
      reasoningConfigured = true;
      models = selected;
      model = models.contains(model) ? model : models.first;
      manualModel.text = model;
    } catch (error) {
      modelError = _friendlyNetworkError(error);
    } finally {
      service.close();
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> testConnection() async {
    if (model.trim().isEmpty) {
      setState(() => testMessage = '请先选择或填写模型 ID');
      return;
    }
    setState(() {
      testing = true;
      testMessage = null;
    });
    final service = DiagnosticsService();
    try {
      final result = await service.testConnection(
        upstream: Upstream(
          id: widget.initial?.id ?? widget.id,
          name: name.text.trim(),
          baseUrl: url.text.trim(),
          apiKey: key.text.trim(),
          models: models,
          selectedModel: model.trim(),
          note: note.text,
          proxy: proxy,
        ),
      );
      testOk = result.ok;
      testMessage = result.message;
    } catch (error) {
      testOk = false;
      testMessage = _friendlyNetworkError(error);
    } finally {
      service.close();
    }
    if (mounted) setState(() => testing = false);
  }

  String _friendlyNetworkError(Object error) {
    final text = error.toString();
    if (text.contains('Operation not permitted') ||
        text.contains('operation not permitted')) {
      return '网络请求被系统拒绝：请重新构建应用（已启用 macOS 网络客户端权限）';
    }
    return text.replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
    title: Text(widget.initial == null ? '添加上游' : '编辑上游'),
    content: SizedBox(
      width: 470,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('channel-name'),
              controller: name,
              decoration: const InputDecoration(
                labelText: '渠道名称（自定义）',
                hintText: '例如：OpenAI 官方 / 公司中转站',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com/v1',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('channel-proxy-type'),
              initialValue: proxyType,
              menuMaxHeight: 320,
              dropdownColor: panel,
              borderRadius: BorderRadius.all(Radius.circular(12)),
              icon: const Icon(Icons.expand_more_rounded, color: teal),
              decoration: _dropdownDecoration('代理'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('不使用代理')),
                DropdownMenuItem(value: 'http', child: Text('HTTP')),
                DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
              ],
              onChanged: loading || testing
                  ? null
                  : (value) => setState(() => proxyType = value ?? 'none'),
            ),
            if (proxyType != 'none') ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: const ValueKey('channel-proxy-host'),
                      controller: proxyHost,
                      enabled: !loading && !testing,
                      decoration: const InputDecoration(labelText: '代理主机'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('channel-proxy-port'),
                      controller: proxyPort,
                      enabled: !loading && !testing,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: '代理端口'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: key,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: models.isEmpty
                      ? TextField(
                          controller: manualModel,
                          onChanged: (value) => model = value,
                          decoration: const InputDecoration(labelText: '模型 ID'),
                        )
                      : DropdownButtonFormField<String>(
                          initialValue: models.contains(model) ? model : null,
                          menuMaxHeight: 320,
                          dropdownColor: panel,
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          icon: const Icon(
                            Icons.expand_more_rounded,
                            color: teal,
                          ),
                          items: models
                              .map(
                                (e) =>
                                    DropdownMenuItem(value: e, child: Text(e)),
                              )
                              .toList(),
                          onChanged: (value) =>
                              setState(() => model = value ?? ''),
                          decoration: _dropdownDecoration('保存的模型'),
                        ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: loading ? null : fetchModels,
                  tooltip: '获取模型列表',
                  icon: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: testing ? null : testConnection,
                  icon: testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_circle_outline, size: 16),
                  label: const Text('测试'),
                ),
              ],
            ),
            if (models.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '模型列表 · 推理强度开关',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
              const SizedBox(height: 5),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: models
                      .map(
                        (entry) => Container(
                          height: 38,
                          padding: const EdgeInsets.only(left: 10, right: 3),
                          decoration: BoxDecoration(
                            color: entry == model
                                ? const Color(0xffe3f3ef)
                                : panel2,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: entry == model ? teal : line,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(7),
                                onTap: () => setState(() => model = entry),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    entry,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                              if (hasKnownReasoningFormat(entry))
                                Tooltip(
                                  message: reasoningModels.contains(entry)
                                      ? '已启用推理强度'
                                      : '启用推理强度',
                                  child: Switch.adaptive(
                                    value: reasoningModels.contains(entry),
                                    onChanged: (enabled) => setState(() {
                                      reasoningConfigured = true;
                                      if (enabled) {
                                        reasoningModels.add(entry);
                                      } else {
                                        reasoningModels.remove(entry);
                                      }
                                    }),
                                  ),
                                ),
                              if (models.length > 1)
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  tooltip: '删除模型',
                                  onPressed: () => removeModel(entry),
                                  icon: const Icon(Icons.close, size: 16),
                                ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: newModel,
                      onSubmitted: addModel,
                      decoration: const InputDecoration(labelText: '添加模型 ID'),
                    ),
                  ),
                  IconButton(
                    tooltip: '添加模型',
                    onPressed: () => addModel(newModel.text),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ] else
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: '添加模型',
                  onPressed: () => addModel(manualModel.text),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ),
            if (modelError != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '模型获取失败：$modelError',
                  style: const TextStyle(color: red, fontSize: 11),
                ),
              ),
            ],
            if (testMessage != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  testMessage!,
                  style: TextStyle(color: testOk ? teal : red, fontSize: 11),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '备注'),
            ),
            if (validationError != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  validationError!,
                  style: const TextStyle(color: red, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
      FilledButton(
        onPressed: () {
          final proxyError = proxy.validationError;
          if (proxyError != null) {
            setState(() => validationError = proxyError);
            return;
          }
          if (name.text.trim().isEmpty ||
              url.text.trim().isEmpty ||
              key.text.trim().isEmpty ||
              model.trim().isEmpty) {
            setState(() {
              validationError = '名称、Base URL、API Key 和模型 ID 均不能为空';
            });
            return;
          }
          final savedModels = {
            ...models,
            if (model.trim().isNotEmpty) model.trim(),
          }.toList();
          Navigator.pop(
            c,
            Upstream(
              id: widget.initial?.id ?? widget.id,
              name: name.text.trim(),
              baseUrl: url.text,
              apiKey: key.text,
              models: savedModels,
              selectedModel: model,
              reasoningModels: reasoningModels,
              reasoningConfigured: reasoningConfigured,
              note: note.text,
              proxy: proxy,
            ),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class PromptDialog extends StatefulWidget {
  const PromptDialog({super.key, this.initial, required this.id});
  final TestPrompt? initial;
  final String id;
  @override
  State<PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<PromptDialog> {
  late final name = TextEditingController(text: widget.initial?.name ?? '');
  late final content = TextEditingController(
    text: widget.initial?.content ?? '',
  );
  String? validationError;
  @override
  Widget build(BuildContext c) => AlertDialog(
    title: Text(widget.initial == null ? '添加检测提示词' : '编辑提示词'),
    content: SizedBox(
      width: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: content,
            maxLines: 8,
            decoration: const InputDecoration(labelText: '提示词内容'),
          ),
          if (validationError != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                validationError!,
                style: const TextStyle(color: red, fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
      FilledButton(
        onPressed: () {
          if (name.text.trim().isEmpty || content.text.trim().isEmpty) {
            setState(() => validationError = '名称和提示词内容均不能为空');
            return;
          }
          Navigator.pop(
            c,
            TestPrompt(
              id: widget.initial?.id ?? widget.id,
              name: name.text,
              content: content.text,
            ),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );
}
