import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'data.dart';
import 'formatters.dart';

class ThroughputChart extends StatefulWidget {
  const ThroughputChart({
    super.key,
    required this.points,
    required this.retries,
    this.startedAt,
    required this.onFault,
  });
  final List<SamplePoint> points;
  final List<RetryEvent> retries;
  final DateTime? startedAt;
  final ValueChanged<int> onFault;
  @override
  State<ThroughputChart> createState() => _ThroughputChartState();
}

class _ThroughputChartState extends State<ThroughputChart> {
  RangeValues? viewport;
  double get end =>
      math.max(1, widget.points.isEmpty ? 1 : widget.points.last.seconds + 1);
  RangeValues get range => viewport == null
      ? RangeValues(0, end)
      : RangeValues(
          viewport!.start.clamp(0, end - 1),
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

  double faultTime(RetryEvent event) =>
      (event.elapsedMs ??
          (widget.startedAt == null
              ? 0
              : event.at.difference(widget.startedAt!).inMilliseconds)) /
      1000;

  @override
  Widget build(BuildContext context) {
    final view = range;
    final width = view.end - view.start;
    final points = widget.points
        .where(
          (p) =>
              p.seconds >= view.start.floor() && p.seconds <= view.end.ceil(),
        )
        .toList();
    final faults = widget.retries
        .where((e) => faultTime(e) >= view.start && faultTime(e) <= view.end)
        .toList();
    double faultY(RetryEvent event) {
      final second = faultTime(event).floor();
      return widget.points
              .where((p) => p.seconds == second)
              .firstOrNull
              ?.tokensPerSecond ??
          0;
    }

    final maxY = points.fold<double>(
      0,
      (v, p) => math.max(v, p.tokensPerSecond),
    );
    final intervalY = math.max(1.0, (maxY * 1.15 / 4).ceilToDouble());
    const color = Color(0xff087f70), red = Color(0xffc84955);
    Widget label(double value, TitleMeta meta, {bool x = false}) {
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
          x ? numberText(value, decimals: 2) : tokenText(value),
          style: const TextStyle(fontSize: 9, color: Color(0xff71808b)),
        ),
      );
    }

    final result = Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${numberText(view.start, decimals: 2)}–${numberText(view.end, decimals: 2)} s',
                key: const ValueKey('chart-range'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
            IconButton(
              tooltip: '放大曲线',
              onPressed: width <= 1 ? null : () => zoom(.5),
              icon: const Icon(Icons.zoom_in, size: 20),
            ),
            IconButton(
              tooltip: '缩小曲线',
              onPressed: width >= end ? null : () => zoom(2),
              icon: const Icon(Icons.zoom_out, size: 20),
            ),
            TextButton(
              onPressed: () => setState(() => viewport = null),
              child: const Text('全量'),
            ),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 12, top: 8),
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
                      '吞吐 (token/s)',
                      style: TextStyle(fontSize: 10),
                    ),
                    axisNameSize: 20,
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 56,
                      interval: intervalY,
                      getTitlesWidget: (value, meta) => label(value, meta),
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
                          label(value, meta, x: true),
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  touchSpotThreshold: 16,
                  touchCallback: (event, response) {
                    if (event is FlTapUpEvent &&
                        response?.lineBarSpots != null) {
                      final fault = response!.lineBarSpots!
                          .where((s) => s.barIndex == 1)
                          .firstOrNull;
                      if (fault != null && fault.spotIndex < faults.length) {
                        widget.onFault(faults[fault.spotIndex].attempt);
                      }
                    }
                  },
                  touchTooltipData: LineTouchTooltipData(
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => spots
                        .map(
                          (s) => LineTooltipItem(
                            '${numberText(s.x, decimals: 2)} s\n${tokenText(s.y)} token/s${s.barIndex == 1 ? '\n请求故障 · 点击详情' : ''}',
                            TextStyle(
                              color: s.barIndex == 1 ? red : Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: points
                        .map((p) => FlSpot(p.seconds, p.tokensPerSecond))
                        .toList(),
                    color: color,
                    barWidth: 1.25,
                    isCurved: false,
                    dotData: FlDotData(
                      show: points.length <= 120,
                      getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                        radius: 1.5,
                        color: color,
                        strokeWidth: 0,
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: color.withValues(alpha: .07),
                    ),
                  ),
                  LineChartBarData(
                    spots: faults
                        .map((e) => FlSpot(faultTime(e), faultY(e)))
                        .toList(),
                    color: red,
                    barWidth: 0,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                        radius: 5,
                        color: red,
                        strokeWidth: 2,
                        strokeColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        RangeSlider(
          key: const ValueKey('chart-slider'),
          values: view,
          min: 0,
          max: end,
          labels: RangeLabels(
            '${numberText(view.start, decimals: 2)} s',
            '${numberText(view.end, decimals: 2)} s',
          ),
          onChanged: (value) {
            if (value.end - value.start >= 1) setState(() => viewport = value);
          },
        ),
      ],
    );
    return result;
  }
}
