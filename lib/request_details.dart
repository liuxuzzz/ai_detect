import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'formatters.dart';
import 'stream_chart.dart';

class _CurrentChunkStringSink implements StringSink {
  StringBuffer _current = StringBuffer();
  void beginChunk() => _current = StringBuffer();
  String endChunk() => _current.toString();
  @override
  void write(Object? object) => _current.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _current.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _current.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _current.writeln(object);
}

// Bound each paragraph's layout cost, even for a multi-megabyte single SSE event.
// Prepared in the decode isolate, never asynchronously inside a visible row.
const _textBlockSize = 1024;
const _textBlockLines = 16;

List<String> _textBlocks(String text) {
  if (text.isEmpty) return const [''];
  final blocks = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = (start + _textBlockSize).clamp(0, text.length);
    var lines = 0;
    var lastNewline = -1;
    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) == 10) {
        lastNewline = i;
        if (++lines == _textBlockLines) {
          end = i + 1;
          break;
        }
      }
    }
    // Prefer a line boundary; otherwise retain every character of long lines.
    if (end < text.length && lastNewline >= start) end = lastNewline + 1;
    if (end < text.length &&
        text.codeUnitAt(end) >= 0xdc00 &&
        text.codeUnitAt(end) <= 0xdfff) {
      end--;
    }
    if (end < text.length &&
        text.codeUnitAt(end - 1) == 13 &&
        text.codeUnitAt(end) == 10) {
      end--;
    }
    blocks.add(text.substring(start, end));
    start = end;
  }
  return blocks;
}

const _logBatchSize = 10;

class _SecondLog {
  _SecondLog(this.second, this.firstChunk, this.endChunk, this.bytes);
  final int second, firstChunk;
  int endChunk, bytes;
  int get chunkCount => endChunk - firstChunk;
}

class _LogRow {
  const _LogRow(
    this.groupIndex,
    this.text, {
    this.chunkIndex,
    this.part = 0,
    this.startsSecond = false,
  });
  final int groupIndex, part;
  final int? chunkIndex;
  final bool startsSecond;
  final String text;
}

class _DecodeRequest {
  const _DecodeRequest(this.exchange, this.groupLimit);
  final HttpExchange exchange;
  final int groupLimit;
}

class _DecodedPayload {
  const _DecodedPayload(
    this.groups,
    this.responseRows,
    this.streamRows,
    this.responseEnds,
    this.streamEnds,
  );
  final List<_SecondLog> groups;
  final List<_LogRow> responseRows, streamRows;
  // Cumulative row counts let each view select its own ten-second batches.
  final List<int> responseEnds, streamEnds;
  int get decodedGroups => responseEnds.length;
}

_DecodedPayload _decodePayload(_DecodeRequest request) {
  final exchange = request.exchange;
  final groups = <_SecondLog>[];
  // Index timestamps/byte counts without decoding any unloaded response bytes.
  for (var i = 0; i < exchange.chunks.length; i++) {
    final chunk = exchange.chunks[i];
    final second = chunk.elapsedMs ~/ 1000;
    if (groups.isEmpty || groups.last.second != second) {
      groups.add(_SecondLog(second, i, i + 1, chunk.byteLength));
    } else {
      groups.last.endChunk = i + 1;
      groups.last.bytes += chunk.byteLength;
    }
  }
  final sink = _CurrentChunkStringSink();
  final decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(StringConversionSink.fromStringSink(sink));
  final responseRows = <_LogRow>[];
  final streamRows = <_LogRow>[];
  final responseEnds = <int>[];
  final streamEnds = <int>[];
  final count = request.groupLimit.clamp(0, groups.length);
  for (var g = 0; g < count; g++) {
    final group = groups[g];
    final body = StringBuffer();
    for (var i = group.firstChunk; i < group.endChunk; i++) {
      sink.beginChunk();
      final chunk = exchange.chunks[i];
      if (chunk.decodedText == null) {
        decoder.add(chunk.bytes);
        if (i == exchange.chunks.length - 1 && exchange.durationMs != null) {
          decoder.close();
        }
      }
      final text = chunk.decodedText ?? sink.endChunk();
      final parts = _textBlocks(text);
      for (var part = 0; part < parts.length; part++) {
        streamRows.add(
          _LogRow(
            g,
            parts[part],
            chunkIndex: i,
            part: part,
            startsSecond: i == group.firstChunk && part == 0,
          ),
        );
      }
      body.write(text);
    }
    final parts = _textBlocks(body.toString());
    for (var part = 0; part < parts.length; part++) {
      responseRows.add(
        _LogRow(g, parts[part], part: part, startsSecond: part == 0),
      );
    }
    responseEnds.add(responseRows.length);
    streamEnds.add(streamRows.length);
  }
  return _DecodedPayload(
    groups,
    responseRows,
    streamRows,
    responseEnds,
    streamEnds,
  );
}

String _headers(Map<String, String> headers) =>
    headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');

Widget _bodyText(String value) => SelectableText(
  value.isEmpty ? '（空）' : value,
  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.6),
);

Widget _section(String title, String value, {bool selectable = true}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (selectable)
            _bodyText(value)
          else
            Text(
              value.isEmpty ? '（空）' : value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.6,
              ),
            ),
        ],
      ),
    );

// A sliver instead of a nested scrolling/paginated text control. Every block is
// already decoded; scrolling only creates bounded synchronous text layouts.
Widget _bodySliver(List<String> blocks) => SliverList.builder(
  itemCount: blocks.length,
  itemBuilder: (_, i) => _bodyText(blocks[i]),
);

class RequestDetailsView extends StatefulWidget {
  const RequestDetailsView({
    super.key,
    required this.exchanges,
    this.selectedAttempt,
    this.active = true,
    this.loadLogs,
    this.loadExchange,
  });
  final ValueNotifier<int>? selectedAttempt;
  final ValueListenable<List<HttpExchange>> exchanges;
  final bool active;
  final Future<StoredLogPage> Function(
    int attempt,
    int? afterSecond,
    int limit,
  )?
  loadLogs;
  final Future<HttpExchange> Function(int attempt)? loadExchange;
  @override
  State<RequestDetailsView> createState() => _RequestDetailsViewState();
}

class _RequestDetailsViewState extends State<RequestDetailsView> {
  int attempt = 0;
  Widget? cachedContent;
  @override
  void initState() {
    super.initState();
    attempt = widget.selectedAttempt?.value ?? 0;
    widget.selectedAttempt?.addListener(_selectAttempt);
  }

  void _selectAttempt() =>
      setState(() => attempt = widget.selectedAttempt!.value);
  @override
  void dispose() {
    widget.selectedAttempt?.removeListener(_selectAttempt);
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<List<HttpExchange>>(
    valueListenable: widget.exchanges,
    builder: (context, exchanges, _) {
      // No work for an unvisited/hidden details tab. Retain its existing state.
      if (!widget.active) {
        return TickerMode(
          enabled: false,
          child: cachedContent ?? const SizedBox.shrink(),
        );
      }
      final index = attempt.clamp(
        0,
        exchanges.isEmpty ? 0 : exchanges.length - 1,
      );
      final exchange = exchanges.isEmpty ? null : exchanges[index];
      cachedContent = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '请求详情',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                if (exchange != null)
                  TextButton.icon(
                    onPressed: () async {
                      final full = widget.loadExchange == null
                          ? exchange
                          : await widget.loadExchange!(index);
                      final text = await compute(_encodeExchange, full);
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制本次尝试的完整记录')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制记录'),
                  ),
              ],
            ),
          ),
          if (exchange == null)
            const Expanded(
              child: Center(
                child: Text('无原始请求记录', textAlign: TextAlign.center),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xfff3f6f5),
                      border: Border.all(color: const Color(0xffdfe6e3)),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: index,
                        isDense: true,
                        borderRadius: BorderRadius.circular(12),
                        dropdownColor: Colors.white,
                        items: [
                          for (var i = 0; i < exchanges.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text('第 ${i + 1} 次请求'),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => attempt = value);
                          widget.selectedAttempt?.value = value;
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      '${exchange.streamMode ? 'Stream' : '非流式'} · ${exchange.statusCode == null ? '未收到响应头' : 'HTTP ${exchange.statusCode}'} · ${exchange.durationMs == null ? '进行中' : secondsText(exchange.durationMs!)} · ${numberText(exchange.responseBytes, decimals: 0)} bytes',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (exchange.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    exchange.error.length > 2048
                        ? '${exchange.error.substring(0, 2048)}…'
                        : exchange.error,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _ExchangePages(
                key: ValueKey('$index:${exchange.startedAt}'),
                exchange: exchange,
                loadLogs: widget.loadLogs == null
                    ? null
                    : (after, limit) => widget.loadLogs!(index, after, limit),
              ),
            ),
          ],
        ],
      );
      return TickerMode(enabled: true, child: cachedContent!);
    },
  );
}

String _encodeExchange(HttpExchange exchange) =>
    const JsonEncoder.withIndent('  ').convert(exchange.toMap());

class _ExchangePages extends StatefulWidget {
  const _ExchangePages({super.key, required this.exchange, this.loadLogs});
  final HttpExchange exchange;
  final Future<StoredLogPage> Function(int? afterSecond, int limit)? loadLogs;
  @override
  State<_ExchangePages> createState() => _ExchangePagesState();
}

class _ExchangePagesState extends State<_ExchangePages>
    with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 3, vsync: this)
    ..addListener(_tabChanged);
  int selected = 0;
  late final requestBlocks = _textBlocks(widget.exchange.requestBody);
  int responseLimit = _logBatchSize, streamLimit = _logBatchSize;
  final responseScroll = ScrollController();
  final streamScroll = ScrollController();
  final pendingScrollChecks = <bool>{};
  final loadTriggerOffset = <bool, double?>{false: null, true: null};
  Widget? cachedResponse, cachedStream;
  final storedChunks = <ResponseChunk>[];
  int storedGroups = 0;
  int? afterSecond;
  bool storedDone = false;
  bool decoding = false;
  HttpExchange? decodedSource;
  _DecodedPayload? payload;
  String? decodeError;
  @override
  void initState() {
    super.initState();
    responseScroll.addListener(() => _scheduleScrollLoad(false));
    streamScroll.addListener(() => _scheduleScrollLoad(true));
  }

  @override
  void dispose() {
    tabs.dispose();
    responseScroll.dispose();
    streamScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ExchangePages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.exchange, widget.exchange) && selected != 0) {
      _ensureDecoded();
    }
  }

  void _tabChanged() {
    if (selected == tabs.index) return;
    setState(() {
      selected = tabs.index;
    });
    if (selected != 0) _ensureDecoded();
  }

  void _ensureDecoded() {
    if (decoding) return;
    final limit = selected == 1 ? responseLimit : streamLimit;
    if (identical(decodedSource, widget.exchange) &&
        payload != null &&
        (payload!.decodedGroups >= limit ||
            payload!.decodedGroups ==
                (widget.loadLogs != null
                    ? widget.exchange.secondSummaries.length
                    : payload!.groups.length))) {
      return;
    }
    if (widget.loadLogs != null) {
      _ensureStoredDecoded(limit);
      return;
    }
    final source = widget.exchange;
    decodeError = null;
    if (source.responseBytes <= 32768 && source.chunks.length <= 128) {
      payload = _decodePayload(_DecodeRequest(source, limit));
      decodedSource = source;
      return;
    }
    decoding = true;
    compute(_decodePayload, _DecodeRequest(source, limit)).then(
      (result) {
        if (!mounted) return;
        setState(() {
          payload = result;
          decodedSource = source;
          decoding = false;
        });
        // Coalesce live updates while a decode is in flight.
        if (selected != 0) _ensureDecoded();
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            decodeError = '$error';
            decoding = false;
            decodedSource = source;
          });
        }
      },
    );
  }

  Future<void> _ensureStoredDecoded(int limit) async {
    decoding = true;
    decodeError = null;
    final source = widget.exchange;
    try {
      while (storedGroups < limit && !storedDone) {
        final page = await widget.loadLogs!(afterSecond, _logBatchSize);
        if (!mounted) return;
        if (page.seconds.isEmpty) {
          if (storedGroups < source.secondSummaries.length) {
            throw StateError('秒日志索引与正文记录不一致');
          }
          storedDone = true;
          break;
        }
        if (afterSecond != null && page.seconds.first <= afterSecond!) {
          throw StateError('日志分页游标没有前进');
        }
        // Decode only this new batch. Previously loaded seconds are append-only
        // and are never decoded or laid out again just to fetch a later page.
        final prepared = await compute(
          _decodePayload,
          _DecodeRequest(source.withChunks(page.chunks), _logBatchSize),
        );
        if (!mounted) return;
        final current = payload ??= _DecodedPayload([], [], [], [], []);
        final groupOffset = current.groups.length;
        final chunkOffset = storedChunks.length;
        final responseOffset = current.responseRows.length;
        final streamOffset = current.streamRows.length;
        _LogRow shift(_LogRow row) => _LogRow(
          row.groupIndex + groupOffset,
          row.text,
          chunkIndex: row.chunkIndex == null
              ? null
              : row.chunkIndex! + chunkOffset,
          part: row.part,
          startsSecond: row.startsSecond,
        );
        current.groups.addAll(prepared.groups);
        current.responseRows.addAll(prepared.responseRows.map(shift));
        current.streamRows.addAll(prepared.streamRows.map(shift));
        current.responseEnds.addAll(
          prepared.responseEnds.map((end) => end + responseOffset),
        );
        current.streamEnds.addAll(
          prepared.streamEnds.map((end) => end + streamOffset),
        );
        storedChunks.addAll(page.chunks);
        storedGroups += page.seconds.length;
        afterSecond = page.seconds.last;
        storedDone = storedGroups >= source.secondSummaries.length;
      }
      payload ??= _DecodedPayload([], [], [], [], []);
      if (!mounted) return;
      setState(() {
        decodedSource = source;
        decoding = false;
      });
      if (selected != 0 && !storedDone) _ensureDecoded();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        decodeError = '$error';
        decoding = false;
      });
    }
  }

  void _scheduleScrollLoad(bool stream) {
    if (!pendingScrollChecks.add(stream)) return;
    // Scroll metrics can change during layout. Read them and append a batch
    // after the frame, coalescing rapid wheel events into a single check.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      pendingScrollChecks.remove(stream);
      if (!mounted ||
          selected != (stream ? 2 : 1) ||
          !TickerMode.valuesOf(context).enabled ||
          decoding ||
          decodeError != null) {
        return;
      }
      final scroll = stream ? streamScroll : responseScroll;
      if (scroll.hasClients &&
          scroll.position.hasContentDimensions &&
          (loadTriggerOffset[stream] == null ||
              scroll.position.pixels > loadTriggerOffset[stream]! + 24) &&
          scroll.position.extentAfter < 200) {
        _loadMore(stream);
      }
    });
  }

  void _loadMore(bool stream) {
    final total = widget.loadLogs == null
        ? payload?.groups.length ?? 0
        : widget.exchange.secondSummaries.length;
    final limit = stream ? streamLimit : responseLimit;
    if (decoding || limit >= total) return;
    loadTriggerOffset[stream] = stream
        ? streamScroll.position.pixels
        : responseScroll.position.pixels;
    setState(() {
      if (stream) {
        streamLimit =
            streamLimit.clamp(0, payload?.decodedGroups ?? 0) + _logBatchSize;
      } else {
        responseLimit =
            responseLimit.clamp(0, payload?.decodedGroups ?? 0) + _logBatchSize;
      }
      _ensureDecoded();
    });
  }

  Widget _logRow(_DecodedPayload data, _LogRow row, HttpExchange exchange) {
    final group = data.groups[row.groupIndex];
    final chunkIndex = row.chunkIndex;
    return Padding(
      padding: EdgeInsets.only(bottom: chunkIndex != null ? 12 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (row.startsSecond)
            Container(
              key: ValueKey('second-log-${group.second}'),
              margin: const EdgeInsets.only(top: 12, bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xfff1f5f9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${numberText(group.second, decimals: 0)}–${numberText(group.second + 1, decimals: 0)} s · ${numberText(group.chunkCount, decimals: 0)} 分片 · ${numberText(group.bytes, decimals: 0)} bytes',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          if (chunkIndex != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '#${(widget.loadLogs == null ? exchange.chunks[chunkIndex].sequence ?? chunkIndex : storedChunks[chunkIndex].sequence ?? chunkIndex) + 1} · +${secondsText((widget.loadLogs == null ? exchange.chunks : storedChunks)[chunkIndex].elapsedMs)} · ${numberText((widget.loadLogs == null ? exchange.chunks : storedChunks)[chunkIndex].byteLength, decimals: 0)} bytes${row.part == 0 ? '' : ' · 续 ${row.part + 1}'}',
                style: const TextStyle(color: Color(0xff64748b), fontSize: 11),
              ),
            ),
          // Text + one SelectionArea, rather than one EditableText/Scrollable per
          // transport chunk. Wheel events always belong to the outer log view.
          Text(
            row.text.isEmpty ? '（空）' : row.text,
            key: ValueKey(
              '${chunkIndex == null ? 'response' : 'stream'}-log-text-${row.groupIndex}-${chunkIndex ?? 0}-${row.part}',
            ),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _logsPage(HttpExchange exchange, {required bool stream}) {
    final data = payload;
    final ends = stream ? data?.streamEnds : data?.responseEnds;
    final rows = stream ? data?.streamRows : data?.responseRows;
    final limit = stream ? streamLimit : responseLimit;
    final loaded = data == null ? 0 : limit.clamp(0, data.decodedGroups);
    final rowCount = loaded == 0 ? 0 : ends![loaded - 1];
    final total = widget.loadLogs == null
        ? data?.groups.length ?? 0
        : exchange.secondSummaries.length;
    // Also fill a short viewport and resume a pending load after decoding or
    // receiving new seconds, without requiring another wheel event.
    _scheduleScrollLoad(stream);
    return Column(
      children: [
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _scheduleScrollLoad(stream);
                return false;
              },
              child: NotificationListener<UserScrollNotification>(
                onNotification: (notification) {
                  if (notification.direction != ScrollDirection.idle) {
                    // Repeated wheel gestures at the bottom do not change
                    // pixels, but they are still an explicit request for the
                    // next page.
                    loadTriggerOffset[stream] = null;
                    _scheduleScrollLoad(stream);
                  }
                  return false;
                },
                child: SelectionArea(
                  child: CustomScrollView(
                    key: PageStorageKey(
                      stream ? 'stream-chunks' : 'response-body',
                    ),
                    controller: stream ? streamScroll : responseScroll,
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                        sliver: SliverList.list(
                          children: [
                            if (stream)
                              StreamTrafficChart(
                                exchange: exchange,
                                requestBytes: utf8
                                    .encode(exchange.requestBody)
                                    .length,
                              )
                            else ...[
                              _section(
                                '响应状态',
                                exchange.statusCode == null
                                    ? '尚未收到响应头'
                                    : 'HTTP ${exchange.statusCode} ${exchange.reasonPhrase ?? ''}',
                                selectable: false,
                              ),
                              _section(
                                '响应头',
                                _headers(exchange.responseHeaders),
                                selectable: false,
                              ),
                            ],
                            if (decoding) const LinearProgressIndicator(),
                            if (decodeError != null)
                              Text('响应解码失败：$decodeError'),
                            if (exchange.chunks.isEmpty && total == 0)
                              const Text('尚未收到响应数据'),
                          ],
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                        sliver: SliverList.builder(
                          itemCount: rowCount,
                          addAutomaticKeepAlives: false,
                          itemBuilder: (_, i) =>
                              _logRow(data!, rows![i], exchange),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xffe2e8f0))),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$loaded / $total 条秒日志',
                key: ValueKey(
                  stream ? 'stream-log-count' : 'response-log-count',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xff64748b), fontSize: 11),
              ),
              if (decoding) ...[
                const SizedBox(width: 12),
                const Text('加载中', style: TextStyle(fontSize: 11)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final exchange = widget.exchange;
    if (selected == 1) cachedResponse = _logsPage(exchange, stream: false);
    if (selected == 2) cachedStream = _logsPage(exchange, stream: true);
    return Column(
      children: [
        TabBar(
          controller: tabs,
          tabs: [
            const Tab(text: 'Request'),
            const Tab(text: 'Response'),
            Tab(text: exchange.streamMode ? 'Stream 分片' : '响应分片'),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: selected,
            children: [
              CustomScrollView(
                key: const PageStorageKey('request-body'),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                    sliver: SliverList.list(
                      children: [
                        _section(
                          '请求',
                          '${exchange.method} ${exchange.url}\n${exchange.startedAt}',
                        ),
                        _section('请求头', _headers(exchange.requestHeaders)),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            '请求体（原文）',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                    sliver: _bodySliver(requestBlocks),
                  ),
                ],
              ),
              TickerMode(
                enabled: selected == 1,
                child: cachedResponse ?? const SizedBox.shrink(),
              ),
              TickerMode(
                enabled: selected == 2,
                child: cachedStream ?? const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class RequestDetailsDialog extends StatelessWidget {
  const RequestDetailsDialog({super.key, required this.exchanges});
  final ValueListenable<List<HttpExchange>> exchanges;
  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 1000,
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: '关闭请求详情',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          Expanded(child: RequestDetailsView(exchanges: exchanges)),
        ],
      ),
    ),
  );
}
