import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'data.dart';
import 'formatters.dart';

/// Shows network traffic grouped by elapsed second.
///
/// The outgoing request is represented by a blue point at second zero. The
/// incoming response is grouped by the second in which each transport chunk
/// arrived and is shown in teal. The widget keeps a local snapshot while
/// paused, so live exchange updates can continue in the background.
class StreamTrafficChart extends StatefulWidget {
  const StreamTrafficChart({
    super.key,
    required this.exchange,
    required this.requestBytes,
  });

  final HttpExchange exchange;
  final int requestBytes;

  @override
  State<StreamTrafficChart> createState() => _StreamTrafficChartState();
}

class _StreamTrafficChartState extends State<StreamTrafficChart> {
  bool paused = false;
  List<ResponseChunk> snapshot = const [];
  int snapshotRequestBytes = 0;
  RangeValues? viewport;
  final outputBySecond = <int, int>{};
  int lastSecond = 0;

  @override
  void initState() {
    super.initState();
    _captureLiveData();
  }

  @override
  void didUpdateWidget(covariant StreamTrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!paused &&
        (!identical(oldWidget.exchange, widget.exchange) ||
            oldWidget.requestBytes != widget.requestBytes)) {
      _captureLiveData();
    }
  }

  void _captureLiveData() {
    if (widget.exchange.secondSummaries.isNotEmpty) {
      outputBySecond.clear();
      lastSecond = 0;
      for (final second in widget.exchange.secondSummaries) {
        outputBySecond[second.second] = second.bytes;
        lastSecond = math.max(lastSecond, second.second);
      }
      snapshot = const [];
      snapshotRequestBytes = widget.requestBytes;
      return;
    }
    final next = widget.exchange.chunks;
    final appending =
        snapshot.length <= next.length &&
        (snapshot.isEmpty ||
            identical(snapshot.last, next[snapshot.length - 1]));
    final start = appending ? snapshot.length : 0;
    if (!appending) {
      outputBySecond.clear();
      lastSecond = 0;
    }
    snapshot = List.unmodifiable(widget.exchange.chunks);
    snapshotRequestBytes = widget.requestBytes;
    for (var i = start; i < snapshot.length; i++) {
      final chunk = snapshot[i];
      final second = chunk.elapsedMs ~/ 1000;
      lastSecond = math.max(lastSecond, second);
      outputBySecond.update(
        second,
        (bytes) => bytes + chunk.byteLength,
        ifAbsent: () => chunk.byteLength,
      );
    }
  }

  List<ResponseChunk> get chunks => snapshot;

  double get end {
    return math.max(1, lastSecond + 1).toDouble();
  }

  RangeValues get range => viewport == null
      ? RangeValues(0, end)
      : RangeValues(
          viewport!.start.clamp(0, math.max(0, end - 1)),
          viewport!.end.clamp(1, end),
        );

  void zoom(double factor) {
    final current = range;
    final width = ((current.end - current.start) * factor).clamp(1.0, end);
    final start = ((current.start + current.end - width) / 2).clamp(
      0.0,
      end - width,
    );
    setState(() => viewport = RangeValues(start, start + width));
  }

  void togglePaused() {
    setState(() {
      if (paused) _captureLiveData();
      paused = !paused;
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = range;
    final width = view.end - view.start;
    final outputSpots =
        outputBySecond.entries
            .map(
              (entry) => FlSpot(entry.key.toDouble(), entry.value.toDouble()),
            )
            .where((spot) => spot.x >= view.start && spot.x <= view.end)
            .toList()
          ..sort((a, b) => a.x.compareTo(b.x));
    final inputSpots = snapshotRequestBytes == 0
        ? <FlSpot>[]
        : [FlSpot(0, snapshotRequestBytes.toDouble())]
              .where((spot) => spot.x >= view.start && spot.x <= view.end)
              .toList();
    final maxBytes = [
      ...outputSpots.map((spot) => spot.y),
      ...inputSpots.map((spot) => spot.y),
    ].fold<double>(0, math.max);
    final intervalY = math.max(1.0, (maxBytes * 1.15 / 4).ceilToDouble());

    Widget axisLabel(double value, TitleMeta meta, {bool x = false}) {
      final intervalX = math.max(1.0, (width / 5).ceilToDouble());
      if (x &&
          value != meta.min &&
          value != meta.max &&
          (value - meta.min < intervalX * .45 ||
              meta.max - value < intervalX * .45)) {
        return const SizedBox.shrink();
      }
      return SideTitleWidget(
        meta: meta,
        fitInside: SideTitleFitInsideData.fromTitleMeta(
          meta,
          distanceFromEdge: 0,
        ),
        child: Text(
          numberText(value, decimals: x ? 2 : 0),
          style: const TextStyle(fontSize: 9, color: Color(0xff71808b)),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Stream 流量（每秒字节）',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xff3568a8),
              ),
            ),
            const SizedBox(width: 4),
            const Text('请求出', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 12),
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xff087f70),
              ),
            ),
            const SizedBox(width: 4),
            const Text('响应入', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 8),
            IconButton(
              key: ValueKey(
                paused ? 'stream-chart-resume' : 'stream-chart-pause',
              ),
              tooltip: paused ? '继续加载曲线' : '暂停加载曲线',
              onPressed: togglePaused,
              icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 19),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '${numberText(view.start, decimals: 2)}–${numberText(view.end, decimals: 2)} s${paused ? ' · 已暂停' : ' · 实时加载'}',
                key: const ValueKey('stream-chart-range'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
            IconButton(
              tooltip: '放大曲线',
              onPressed: width <= 1 ? null : () => zoom(.5),
              icon: const Icon(Icons.zoom_in, size: 19),
            ),
            IconButton(
              tooltip: '缩小曲线',
              onPressed: width >= end ? null : () => zoom(2),
              icon: const Icon(Icons.zoom_out, size: 19),
            ),
            TextButton(
              onPressed: () => setState(() => viewport = null),
              child: const Text('全量'),
            ),
          ],
        ),
        SizedBox(
          // Keep the chart compact enough for the details pane at the
          // minimum supported window size while retaining the same controls
          // as the main throughput chart.
          height: 190,
          child: Padding(
            padding: const EdgeInsets.only(right: 12, top: 4),
            child: LineChart(
              duration: Duration.zero,
              LineChartData(
                minX: view.start,
                maxX: view.end,
                minY: 0,
                maxY: intervalY * 4,
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      const FlLine(color: Color(0xffdfe6e3), strokeWidth: .8),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: const Text(
                      '字节/秒',
                      style: TextStyle(fontSize: 10),
                    ),
                    axisNameSize: 20,
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 58,
                      interval: intervalY,
                      getTitlesWidget: (value, meta) => axisLabel(value, meta),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text(
                      '时间 (秒)',
                      style: TextStyle(fontSize: 10),
                    ),
                    axisNameSize: 22,
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: math.max(1, (width / 5).ceil()).toDouble(),
                      maxIncluded: true,
                      getTitlesWidget: (value, meta) =>
                          axisLabel(value, meta, x: true),
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => const Color(0xff172b3a),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => spots
                        .map(
                          (spot) => LineTooltipItem(
                            '${numberText(spot.x, decimals: 2)} s\n${spot.barIndex == 0 ? '请求出' : '响应入'}：${numberText(spot.y, decimals: 0)} bytes',
                            TextStyle(
                              color: spot.barIndex == 0
                                  ? const Color(0xffb8d9ff)
                                  : const Color(0xffb5f5de),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: inputSpots,
                    color: const Color(0xff3568a8),
                    barWidth: 0,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                        radius: 5,
                        color: const Color(0xff3568a8),
                        strokeWidth: 2,
                        strokeColor: Colors.white,
                      ),
                    ),
                  ),
                  LineChartBarData(
                    spots: outputSpots,
                    color: const Color(0xff087f70),
                    barWidth: 2,
                    isCurved: false,
                    dotData: FlDotData(show: outputSpots.length <= 120),
                    belowBarData: BarAreaData(
                      show: true,
                      color: const Color(0xff087f70).withValues(alpha: .07),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        RangeSlider(
          key: const ValueKey('stream-chart-slider'),
          values: view,
          min: 0,
          max: end,
          labels: RangeLabels(
            '${numberText(view.start, decimals: 2)} s',
            '${numberText(view.end, decimals: 2)} s',
          ),
          onChanged: (value) {
            if (value.end - value.start >= 1) {
              setState(() => viewport = value);
            }
          },
        ),
      ],
    );
  }
}
