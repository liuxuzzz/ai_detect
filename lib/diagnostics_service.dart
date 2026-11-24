import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'data.dart';
import 'agent_tools.dart';
import 'model_reasoning.dart';
import 'model_api.dart';
import 'responses_stream.dart';
import 'upstream_http.dart';

class DiagnosticCancelled implements Exception {
  const DiagnosticCancelled();

  @override
  String toString() => '用户已停止';
}

/// One token covers the active request and any retry delay for a whole run.
class DiagnosticCancellation {
  bool _cancelled = false;
  Object _reason = const DiagnosticCancelled();
  final _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() => _cancelWith(const DiagnosticCancelled());

  void _cancelWith(Object reason) {
    if (_cancelled) return;
    _reason = reason;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw _reason;
  }

  void Function() _listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  Future<T> wait<T>(Future<T> future) {
    final result = Completer<T>();
    final remove = _listen(() {
      if (!result.isCompleted) {
        result.completeError(_reason);
      }
    });
    future.then(
      (value) {
        remove();
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        remove();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future.whenComplete(remove);
  }

  Stream<T> guardStream<T>(Stream<T> stream) {
    late final StreamController<T> guarded;
    StreamSubscription<T>? subscription;
    void Function()? remove;
    guarded = StreamController<T>(
      onListen: () {
        if (isCancelled) {
          guarded.addError(_reason);
          unawaited(guarded.close());
          return;
        }
        subscription = stream.listen(
          (value) {
            if (!isCancelled) guarded.add(value);
          },
          onError: guarded.addError,
          onDone: () {
            remove?.call();
            unawaited(guarded.close());
          },
        );
        remove = _listen(() {
          guarded.addError(_reason);
          unawaited(guarded.close());
          unawaited(subscription?.cancel());
        });
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        remove?.call();
        unawaited(subscription?.cancel());
      },
    );
    return guarded.stream;
  }

  Future<void> delay(Duration duration) async {
    throwIfCancelled();
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    try {
      await wait(done.future);
    } finally {
      timer.cancel();
    }
  }
}

class StreamResult {
  const StreamResult({
    required this.output,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.toolCalls = const [],
    this.responseOutput = const [],
    this.finishReason,
  });

  final String output;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final List<AgentToolCall> toolCalls;
  final List<Map<String, dynamic>> responseOutput;
  final String? finishReason;

  String get error => switch (finishReason) {
    'length' =>
      '输出被上游截断（finish_reason=length）：已达到输出 token 上限${output.isEmpty ? '，未生成正文' : '，正文不完整'}。',
    'content_filter' => '输出被上游内容过滤中断（finish_reason=content_filter）。',
    'insufficient_system_resource' =>
      '上游资源不足，输出已中断（finish_reason=insufficient_system_resource）。',
    _ => '',
  };
}

class ProbeResult {
  const ProbeResult({required this.statusCode, required this.message});

  final int statusCode;
  final String message;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

class _ExchangeCapture {
  _ExchangeCapture(this.request, this.streaming, this.onUpdate);
  final http.Request request;
  final bool streaming;
  final void Function(HttpExchange)? onUpdate;
  final started = DateTime.now();
  final watch = Stopwatch()..start();
  final chunks = <ResponseChunk>[];
  http.StreamedResponse? response;
  Timer? updateTimer;
  bool finished = false;
  String error = '';

  Map<String, String> _headers(Map<String, String> headers) => {
    for (final entry in headers.entries)
      entry.key:
          const {
            'authorization',
            'proxy-authorization',
            'x-api-key',
            'api-key',
            'cookie',
            'set-cookie',
          }.contains(entry.key.toLowerCase())
          ? '[已隐藏]'
          : entry.value,
  };

  void emit({bool immediate = true}) {
    if (onUpdate == null) return;
    if (!immediate) {
      updateTimer ??= Timer(const Duration(milliseconds: 100), () {
        updateTimer = null;
        emit();
      });
      return;
    }
    updateTimer?.cancel();
    updateTimer = null;
    onUpdate!(
      HttpExchange(
        startedAt: started.toIso8601String(),
        method: request.method,
        url: request.url.toString(),
        requestHeaders: _headers(request.headers),
        requestBody: request.body,
        streamMode: streaming,
        statusCode: response?.statusCode,
        reasonPhrase: response?.reasonPhrase,
        responseHeaders: _headers(response?.headers ?? {}),
        chunks: List.unmodifiable(chunks),
        durationMs: finished ? watch.elapsedMilliseconds : null,
        error: error,
      ),
    );
  }

  void received(http.StreamedResponse value) {
    if (finished) return;
    response = value;
    emit();
  }

  List<int> chunk(List<int> bytes) {
    if (!finished && bytes.isNotEmpty) {
      chunks.add(
        ResponseChunk(
          elapsedMs: watch.elapsedMilliseconds,
          base64: base64Encode(bytes),
        ),
      );
      emit(immediate: false);
    }
    return bytes;
  }

  void finish([Object? failure]) {
    if (finished) return;
    finished = true;
    watch.stop();
    error = failure?.toString() ?? '';
    emit();
  }
}

typedef TcpConnectProbe = Future<int> Function(Uri uri, Duration timeout);

class _TestDeadline {
  _TestDeadline(DiagnosticCancellation? external, this.timeout) {
    _remove =
        external?._listen(() => token._cancelWith(external._reason)) ?? () {};
    _timer = Timer(timeout, () {
      expired = true;
      token._cancelWith(error);
    });
  }

  final Duration timeout;
  final token = DiagnosticCancellation();
  late final Timer _timer;
  late final void Function() _remove;
  bool expired = false;

  TimeoutException get error =>
      TimeoutException('测试超时：${timeout.inMinutes} 分钟', timeout);

  void close() {
    _timer.cancel();
    _remove();
  }
}

class DiagnosticsService {
  DiagnosticsService({
    http.Client? client,
    TcpConnectProbe? tcpConnectProbe,
    this.testTimeout = const Duration(minutes: 60),
  }) : _client = client,
       _tcpConnectProbe =
           tcpConnectProbe ?? (client == null ? _socketConnectProbe : null);

  final http.Client? _client;
  final TcpConnectProbe? _tcpConnectProbe;
  final Duration testTimeout;
  final _ownedClients = <http.Client>{};
  bool _closed = false;

  Future<http.Client> _openClient(Upstream upstream, Duration timeout) async {
    if (_closed) throw StateError('请求服务已关闭');
    final client = await createUpstreamHttpClient(
      upstream.proxy,
      connectionTimeout: timeout,
    );
    if (_closed) {
      client.close();
      throw StateError('请求服务已关闭');
    }
    _ownedClients.add(client);
    return client;
  }

  void _releaseClient(http.Client client) {
    if (_ownedClients.remove(client)) client.close();
  }

  Future<List<String>> fetchModels({required Upstream upstream}) async {
    final client =
        _client ?? await _openClient(upstream, const Duration(seconds: 15));
    try {
      final response = await client
          .get(
            upstreamEndpoint(upstream.baseUrl, 'models'),
            headers: {'Authorization': 'Bearer ${upstream.apiKey.trim()}'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
      final data = jsonDecode(response.body);
      if (data is! Map || data['data'] is! List) {
        throw const FormatException('接口未返回 data 模型列表');
      }
      final models = (data['data'] as List)
          .whereType<Map>()
          .map((e) => e['id'])
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList();
      if (models.isEmpty) throw const FormatException('接口返回的模型列表为空');
      return models;
    } finally {
      _releaseClient(client);
    }
  }

  Future<ProbeResult> testConnection({required Upstream upstream}) async {
    if (upstream.baseUrl.trim().isEmpty) {
      throw const FormatException('Base URL 不能为空');
    }
    if (upstream.apiKey.trim().isEmpty) {
      throw const FormatException('API Key 不能为空');
    }
    if (upstream.selectedModel.trim().isEmpty) {
      throw const FormatException('请先选择模型');
    }
    final result = await stream(
      upstream: upstream,
      prompt: const TestPrompt(
        id: 'connection-test',
        name: '连接测试',
        content: '连接测试：请只回复 OK。',
      ),
      onTcpConnected: (_) {},
      onText: (_) {},
      connectionTimeout: const Duration(seconds: 30),
    );
    return ProbeResult(
      statusCode: 200,
      message: result.output.isEmpty ? '上游已响应' : '上游已响应，模型可用',
    );
  }

  Future<StreamResult> stream({
    required Upstream upstream,
    required TestPrompt prompt,
    required void Function(int elapsedMs) onTcpConnected,
    required void Function(String chunk) onText,
    DiagnosticCancellation? cancellation,
    void Function(HttpExchange)? onExchange,
    void Function(ModelActivity)? onActivity,
    Duration connectionTimeout = const Duration(seconds: 45),
    Duration idleTimeout = const Duration(minutes: 60),
    String reasoningEffort = 'default',
    List<Map<String, dynamic>>? messages,
    List<Map<String, Object?>>? tools,
  }) async {
    cancellation?.throwIfCancelled();
    final api = modelApiFor(upstream.baseUrl, upstream.selectedModel);
    final deadline = _TestDeadline(cancellation, testTimeout);
    final token = deadline.token;
    final abort = Completer<void>();
    void abortRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    final remove = token._listen(abortRequest);
    _ExchangeCapture? capture;
    http.Client? client;
    try {
      final http.Client requestClient =
          _client ??
          await token.wait<http.Client>(
            _openClient(upstream, connectionTimeout).then((value) {
              if (token.isCancelled) {
                _releaseClient(value);
                token.throwIfCancelled();
              }
              return value;
            }),
          );
      client = requestClient;
      final request =
          http.AbortableRequest(
              'POST',
              upstreamEndpoint(
                upstream.baseUrl,
                api == ModelApi.responses ? 'responses' : 'chat/completions',
              ),
              abortTrigger: abort.future,
            )
            ..headers.addAll({
              'Authorization': 'Bearer ${upstream.apiKey}',
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            });
      final conversation =
          messages ??
          [
            {'role': 'user', 'content': prompt.content},
          ];
      final requestBody = api == ModelApi.responses
          ? responsesRequest(
              model: upstream.selectedModel,
              messages: conversation,
              reasoningEffort: reasoningEffort,
              tools: tools,
            )
          : applyReasoning(
              {
                'model': upstream.selectedModel,
                'messages': conversation,
                'stream': true,
                'stream_options': {'include_usage': true},
                ...?tools == null ? null : {'tools': tools},
              },
              upstream.selectedModel,
              reasoningEffort,
            );
      request.body = jsonEncode(requestBody);

      capture = _ExchangeCapture(request, true, onExchange)..emit();
      if (_tcpConnectProbe case final probe?) {
        final elapsedMs = await token.wait(
          probe(
            upstream.proxy.enabled
                ? Uri(
                    scheme: 'http',
                    host: upstream.proxy.host,
                    port: upstream.proxy.port,
                  )
                : request.url,
            connectionTimeout,
          ),
        );
        onTcpConnected(elapsedMs);
      }
      final response = await token
          .wait(requestClient.send(request))
          .timeout(testTimeout);
      capture.received(response);
      void idleExpired(EventSink<List<int>> sink) {
        sink.addError(
          TimeoutException(
            '流式空闲超时：已连续 ${idleTimeout.inSeconds} 秒未收到上游数据',
            idleTimeout,
          ),
        );
        sink.close();
        abortRequest();
      }

      // Keep cancellation outside timeout: a stalled provider must not delay
      // delivery of the timeout error while its subscription is being closed.
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await token
            .guardStream(
              response.stream.timeout(idleTimeout, onTimeout: idleExpired),
            )
            .map(capture.chunk)
            .transform(utf8.decoder)
            .join();
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      final output = StringBuffer();
      String? finishReason;
      int? inputTokens;
      int? outputTokens;
      int? totalTokens;
      int? cacheReadTokens;
      int? cacheWriteTokens;
      final toolBuilders = <int, _ToolCallBuilder>{};
      final responses = ResponsesStream(onText: onText, onActivity: onActivity);

      await for (final event in _events(
        token
            .guardStream(
              response.stream.timeout(idleTimeout, onTimeout: idleExpired),
            )
            .map(capture.chunk),
        jsonResponse:
            response.headers['content-type']?.contains('application/json') ??
            false,
      )) {
        if (api == ModelApi.responses) responses.add(event);
        final usage = api == ModelApi.responses
            ? responses.usage
            : event['usage'];
        if (usage is Map<String, dynamic>) {
          inputTokens =
              _number(usage['prompt_tokens'] ?? usage['input_tokens']) ??
              inputTokens;
          outputTokens =
              _number(usage['completion_tokens'] ?? usage['output_tokens']) ??
              outputTokens;
          totalTokens = _number(usage['total_tokens']) ?? totalTokens;
          cacheReadTokens =
              _cacheCount(
                usage,
                ['cached_tokens', 'cache_read_tokens'],
                [
                  'cache_read_input_tokens',
                  'cache_read_tokens',
                  'prompt_cache_hit_tokens',
                  'cached_tokens',
                ],
              ) ??
              cacheReadTokens;
          cacheWriteTokens =
              _cacheCount(
                usage,
                ['cache_creation_tokens', 'cache_write_tokens'],
                [
                  'cache_creation_input_tokens',
                  'cache_write_tokens',
                  'cache_creation_tokens',
                ],
              ) ??
              cacheWriteTokens;
        }

        if (api == ModelApi.responses) {
          if (responses.completed) break;
          continue;
        }
        if (event['error'] != null) {
          throw FormatException('上游返回错误：${event['error']}');
        }
        final choices = event['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final choice = choices.first as Map;
          if (choice['finish_reason'] case final String reason) {
            finishReason = reason;
          }
          final delta = choice['delta'];
          if (delta is Map) _activities(delta, onActivity);
          if (delta is Map && delta['tool_calls'] is List) {
            for (final raw in (delta['tool_calls'] as List).whereType<Map>()) {
              final index =
                  (raw['index'] as num?)?.toInt() ?? toolBuilders.length;
              final builder = toolBuilders.putIfAbsent(
                index,
                _ToolCallBuilder.new,
              );
              final id = raw['id'];
              if (id is String && id.isNotEmpty) builder.id = id;
              final function = raw['function'];
              if (function is Map) {
                final name = function['name'];
                final arguments = function['arguments'];
                if (name is String) builder.name.write(name);
                if (arguments is String) builder.arguments.write(arguments);
              }
            }
          }
          // A few OpenAI-compatible Claude relays stream Anthropic-style
          // content blocks instead of `delta.tool_calls`.
          if (delta is Map && delta['content'] is List) {
            for (final raw in (delta['content'] as List).whereType<Map>()) {
              if (raw['type'] != 'tool_use') continue;
              final index = toolBuilders.length;
              final builder = toolBuilders.putIfAbsent(
                index,
                _ToolCallBuilder.new,
              );
              final id = raw['id'];
              final name = raw['name'];
              if (id is String && id.isNotEmpty) builder.id = id;
              if (name is String) builder.name.write(name);
              if (raw['input'] is Map) {
                builder.arguments.write(jsonEncode(raw['input']));
              }
            }
          }
          final content = delta is Map ? delta['content'] : null;
          if (content is String && content.isNotEmpty) {
            output.write(content);
            onText(content);
          } else if (content is List) {
            for (final part in content) {
              if (part is Map &&
                  (part['type'] == null ||
                      part['type'] == 'text' ||
                      part['type'] == 'output_text') &&
                  part['text'] is String) {
                final text = part['text'] as String;
                output.write(text);
                onText(text);
              }
            }
          }
        }
      }

      if (api == ModelApi.responses && !responses.completed) {
        throw const FormatException('上游 Responses 流提前结束，未收到完成事件');
      }
      final result = StreamResult(
        finishReason: finishReason,
        output: api == ModelApi.responses
            ? responses.output
            : output.toString(),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: totalTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        responseOutput: api == ModelApi.responses
            ? responses.outputItems
            : const [],
        toolCalls: api == ModelApi.responses
            ? responses.toolCalls
            : [
                for (final builder in toolBuilders.values)
                  AgentToolCall(
                    id: builder.id.isEmpty
                        ? 'call-${toolBuilders.keys.first}'
                        : builder.id,
                    name: builder.name.toString(),
                    arguments: builder.arguments.toString(),
                  ),
              ],
      );
      // A 200 response can still end without a complete answer. Keep usage and
      // partial output while marking the model's termination in the trace.
      capture.finish(result.error.isEmpty ? null : result.error);
      return result;
    } catch (e) {
      capture?.finish(deadline.expired ? deadline.error : e);
      if (deadline.expired) throw deadline.error;
      rethrow;
    } finally {
      capture?.finish();
      remove();
      deadline.close();
      abortRequest();
      if (client != null) _releaseClient(client);
    }
  }

  /// Run a Cherry Studio/Codex-like tool loop over the same streaming
  /// transport. Each turn is captured as its own HTTP exchange and tool
  /// results are encoded for the model's selected API.
  Future<StreamResult> agent({
    required Upstream upstream,
    required TestPrompt prompt,
    required AgentToolRuntime runtime,
    required void Function(int elapsedMs) onTcpConnected,
    required void Function(String chunk) onText,
    DiagnosticCancellation? cancellation,
    void Function(HttpExchange)? onExchange,
    void Function(ModelActivity)? onActivity,
    void Function(String html)? onHtml,
    Duration connectionTimeout = const Duration(seconds: 45),
    Duration idleTimeout = const Duration(minutes: 60),
    String reasoningEffort = 'default',
    int maxRounds = 8,
  }) async {
    cancellation?.throwIfCancelled();
    final api = modelApiFor(upstream.baseUrl, upstream.selectedModel);
    final deadline = _TestDeadline(cancellation, testTimeout);
    try {
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': prompt.content},
      ];
      final output = StringBuffer();
      int inputTokens = 0, outputTokens = 0, totalTokens = 0;
      int? cacheRead = 0, cacheWrite = 0;
      for (var round = 0; round < maxRounds; round++) {
        final result = await stream(
          upstream: upstream,
          prompt: prompt,
          messages: messages,
          tools: AgentTools.definitions
              .map((e) => e.cast<String, Object?>())
              .toList(),
          onTcpConnected: onTcpConnected,
          onText: (text) {
            output.write(text);
            onText(text);
          },
          cancellation: deadline.token,
          onExchange: onExchange,
          onActivity: onActivity,
          connectionTimeout: connectionTimeout,
          idleTimeout: idleTimeout,
          reasoningEffort: reasoningEffort,
        );
        inputTokens += result.inputTokens ?? 0;
        outputTokens += result.outputTokens ?? 0;
        totalTokens +=
            result.totalTokens ??
            ((result.inputTokens ?? 0) + (result.outputTokens ?? 0));
        cacheRead = _sumKnown(cacheRead, result.cacheReadTokens);
        cacheWrite = _sumKnown(cacheWrite, result.cacheWriteTokens);
        if (result.error.isNotEmpty || result.toolCalls.isEmpty) {
          return StreamResult(
            finishReason: result.finishReason,
            output: output.toString(),
            inputTokens: inputTokens == 0 ? null : inputTokens,
            outputTokens: outputTokens == 0 ? null : outputTokens,
            totalTokens: totalTokens == 0 ? null : totalTokens,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
          );
        }
        if (api == ModelApi.responses) {
          // Reasoning items, including encrypted content, must accompany tool calls.
          messages.addAll(result.responseOutput);
        } else {
          messages.add({
            'role': 'assistant',
            'content': result.output.isEmpty ? null : result.output,
            'tool_calls': [
              for (final call in result.toolCalls) call.toMessagePart(),
            ],
          });
        }
        for (final call in result.toolCalls) {
          deadline.token.throwIfCancelled();
          String toolResult;
          try {
            toolResult = await runtime.execute(call, onHtml: onHtml);
          } catch (error) {
            toolResult = '工具执行失败：$error';
          }
          onActivity?.call(
            ModelActivity(
              kind: 'tool_result',
              id: call.id,
              name: call.name,
              content: toolResult,
            ),
          );
          messages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content': toolResult,
          });
        }
      }
      throw StateError('Agent 工具循环超过 $maxRounds 轮');
    } catch (e) {
      if (deadline.expired) throw deadline.error;
      rethrow;
    } finally {
      deadline.close();
    }
  }

  void close() {
    _closed = true;
    _client?.close();
    for (final client in _ownedClients) {
      client.close();
    }
    _ownedClients.clear();
  }

  static Future<int> _socketConnectProbe(Uri uri, Duration timeout) async {
    final watch = Stopwatch()..start();
    final socket = await Socket.connect(
      uri.host,
      uri.hasPort
          ? uri.port
          : uri.scheme == 'https'
          ? 443
          : 80,
      timeout: timeout,
    );
    watch.stop();
    socket.destroy();
    return watch.elapsedMilliseconds;
  }

  static Stream<Map<String, dynamic>> _events(
    Stream<List<int>> bytes, {
    required bool jsonResponse,
  }) async* {
    final text = bytes.transform(utf8.decoder);
    if (jsonResponse) {
      yield _event(await text.join());
      return;
    }
    final data = <String>[];
    await for (final line in text.transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isEmpty) continue;
        final value = data.join('\n');
        data.clear();
        if (value.trim() == '[DONE]') return;
        if (value.trim().isNotEmpty) yield _event(value);
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
    if (data.isNotEmpty && data.join('\n').trim() != '[DONE]') {
      yield _event(data.join('\n'));
    }
  }

  static Map<String, dynamic> _event(String value) {
    final event = jsonDecode(value);
    if (event is! Map<String, dynamic>) {
      throw const FormatException('上游未返回有效模型响应');
    }
    return event;
  }

  static void _activities(Map message, void Function(ModelActivity)? emit) {
    if (emit == null) return;
    final reasoning = message['reasoning_content'] ?? message['reasoning'];
    if (reasoning is String && reasoning.isNotEmpty) {
      emit(ModelActivity(kind: 'thinking', content: reasoning));
    }
    final tools = message['tool_calls'];
    if (tools is List) {
      for (final tool in tools.whereType<Map>()) {
        final function = tool['function'];
        if (function is Map) {
          emit(
            ModelActivity(
              kind: 'tool_call',
              id: '${tool['index'] ?? tool['id'] ?? 0}',
              name: function['name'] as String? ?? '',
              content: function['arguments'] as String? ?? '',
            ),
          );
        }
      }
    }
    final function = message['function_call'];
    if (function is Map) {
      emit(
        ModelActivity(
          kind: 'tool_call',
          id: 'function',
          name: function['name'] as String? ?? '',
          content: function['arguments'] as String? ?? '',
        ),
      );
    }
    final content = message['content'];
    if (content is List) {
      for (final part in content.whereType<Map>()) {
        if (part['type'] == 'thinking' || part['type'] == 'reasoning') {
          emit(
            ModelActivity(
              kind: 'thinking',
              content: '${part['thinking'] ?? part['text'] ?? ''}',
            ),
          );
        } else if (part['type'] == 'tool_use') {
          emit(
            ModelActivity(
              kind: 'tool_call',
              id: '${part['id'] ?? ''}',
              name: '${part['name'] ?? ''}',
              content: jsonEncode(part['input']),
            ),
          );
        } else if (part['type'] == 'tool_result') {
          emit(
            ModelActivity(
              kind: 'tool_result',
              id: '${part['tool_use_id'] ?? ''}',
              content: _contentText(part['content']),
            ),
          );
        }
      }
    }
  }

  static String _contentText(dynamic content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where(
            (part) =>
                part['type'] == null ||
                part['type'] == 'text' ||
                part['type'] == 'output_text',
          )
          .map((part) => part['text'])
          .whereType<String>()
          .join();
    }
    return '';
  }

  static int? _cacheCount(
    Map<String, dynamic> usage,
    List<String> detailKeys,
    List<String> usageKeys,
  ) {
    final values = [
      for (final details in [
        usage['prompt_tokens_details'],
        usage['input_tokens_details'],
      ])
        if (details is Map)
          for (final key in detailKeys) details[key],
      for (final key in usageKeys) usage[key],
    ];
    for (final value in values) {
      final count = value is int
          ? value
          : value is String
          ? int.tryParse(value.trim(), radix: 10)
          : null;
      if (count != null && count >= 0) return count;
    }
    return null;
  }

  static int? _sumKnown(int? total, int? count) =>
      total == null || count == null ? null : total + count;

  static int? _number(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value');
}

class _ToolCallBuilder {
  String id = '';
  final name = StringBuffer();
  final arguments = StringBuffer();
}
