import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'data.dart';
import 'formatters.dart';
import 'model_output.dart';

String _esc(String value) => const HtmlEscape().convert(value);

String _date(Diagnostic d) =>
    DateTime.tryParse(d.startedAt)?.toLocal().toString().split('.').first ??
    d.startedAt;

Map<String, String> _summary(Diagnostic d, RateMetrics? rates) => {
  '渠道': d.upstreamName,
  '模型': d.model,
  '提示词': d.promptName,
  '请求时间': _date(d),
  '状态': d.error.isEmpty ? '成功' : '失败：${d.error}',
  '首 Token 延时': d.ttftMs > 0 ? secondsText(d.ttftMs) : 'N/A',
  '平均吞吐': '${tokenText(d.averageTps)} token/s',
  '总 Token': tokenText(d.totalTokens),
  '输入 Token': tokenText(d.inputTokens),
  '输出 Token': tokenText(d.outputTokens),
  '平均 RPM': rates == null ? 'N/A' : '${numberText(rates.rpm)} req/min',
  '平均 TPM': rates == null ? 'N/A' : '${tokenText(rates.tpm)} token/min',
  '首字节延时': d.firstByteMs > 0 ? secondsText(d.firstByteMs) : 'N/A',
  '平均 Token 延时': '${(d.averageLatencyMs / 1000).toStringAsFixed(2)} s/token',
  'TCP 连接成功延时': d.tcpConnectMs == null
      ? 'N/A'
      : '${tokenText(d.tcpConnectMs!)} ms',
  '缓存读取': cacheTokenText(d.cacheReadTokens),
  '缓存写入': cacheTokenText(d.cacheWriteTokens),
  '缓存命中率': cacheHitRateText(d.cacheHitRate),
  '总耗时': secondsText(d.durationMs),
  '故障/重试次数': tokenText(d.retries.length),
};

String _renderedOutputHtml(Diagnostic d) {
  // Agent files and assistant replies are separate outputs. Render the last
  // saved artifact directly, including for historical runs that also appended
  // it to the reply. Parsing their concatenation moves prose into the page.
  final artifact = d.activities
      .where((a) => a.kind == 'html_artifact' && a.content.trim().isNotEmpty)
      .lastOrNull;
  final content =
      artifact?.content ??
      splitModelOutput(
        d.output,
      ).where((part) => part.html != null).map((part) => part.html!).join();
  if (content.isEmpty) {
    return d.output.isEmpty ? '<p>（无输出）</p>' : '<pre>${_esc(d.output)}</pre>';
  }
  // Keep model CSS and scripts in their own document so report axes stay intact.
  final document = html_parser.parse(content);
  document.head!.append(
    dom.Element.tag('style')
      ..text = '''
html,body{height:auto!important;min-height:0!important;max-height:none!important;overflow:visible!important}
''',
  );
  document.body!.append(dom.Element.tag('script')..text = _previewResizeScript);
  return '<script>$_reportResizeScript</script>'
      '<iframe title="模型输出预览" data-model-preview sandbox="allow-scripts" scrolling="no" '
      'style="display:block;width:100%;height:1px;border:0;background:white;overflow:hidden" '
      'srcdoc="${_esc(document.outerHtml)}"></iframe>';
}

// The opaque sandbox keeps model scripts separate. Only its own frame may
// report a height; resize/image/font/DOM changes all remeasure the content.
const _reportResizeScript = r'''
window.addEventListener('message',function(event){
  var frame=document.querySelector('iframe[data-model-preview]');
  if(!frame || event.source!==frame.contentWindow || !event.data ||
     event.data.type!=='ai-channel-preview-height')return;
  var height=event.data.height;
  if(typeof height==='number' && Number.isFinite(height) && height>0 &&
     Math.abs(frame.getBoundingClientRect().height-height)>1){
    frame.style.height=Math.ceil(height)+'px';
  }
});
''';

const _previewResizeScript = r'''
(function(){
  var pending=false;
  function measure(){
    pending=false;
    var body=document.body;
    if(!body)return;
    var box=body.getBoundingClientRect();
    var margin=parseFloat(getComputedStyle(body).marginBottom)||0;
    var height=Math.ceil(Math.max(body.scrollHeight,body.offsetHeight,box.height)+Math.max(0,box.top)+margin);
    parent.postMessage({type:'ai-channel-preview-height',height:Math.max(1,height)},'*');
  }
  function schedule(){if(!pending){pending=true;requestAnimationFrame(measure);}}
  new ResizeObserver(schedule).observe(document.body);
  new MutationObserver(schedule).observe(document.body,{subtree:true,childList:true,attributes:true,characterData:true});
  window.addEventListener('resize',schedule);
  window.addEventListener('load',schedule,true);
  if(document.fonts)document.fonts.ready.then(schedule);
  schedule();
})();
''';

Future<String> diagnosticHtml(Diagnostic d, {RateMetrics? rates}) async {
  const escapeText = HtmlEscape(HtmlEscapeMode.element);
  final metricRows = _summary(d, rates).entries
      .map(
        (row) =>
            '<tr><th>${escapeText.convert(row.key)}</th><td>${escapeText.convert(row.value)}</td></tr>',
      )
      .join();
  final chartScript = d.points.isEmpty
      ? ''
      : '<script data-report-chart>${await rootBundle.loadString('assets/report_chart.js')}</script>';
  return '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>AI 渠道检测报告</title><style>body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#1c2933;max-width:1000px;margin:32px auto;padding:0 24px}h1,h2{color:#087f70}table{border-collapse:collapse;width:100%;margin:12px 0 24px}th,td{border:1px solid #dfe6e3;padding:8px 12px;text-align:left;vertical-align:top}th{background:#f3f6f5;width:220px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f3f6f5;padding:14px;border-radius:4px}section{margin:28px 0}.chart{width:100%;height:460px;border:1px solid #dfe6e3;padding:12px;box-sizing:border-box}.chart svg{width:100%;height:100%}.chart .sample-point:hover{r:3;fill-opacity:1;stroke:#fff;stroke-width:1}.rendered-output{border:1px solid #dfe6e3;padding:16px;border-radius:4px}</style><body><h1>AI 渠道检测报告</h1><p>${_esc(_date(d))}</p><section><h2>检测指标</h2><table>$metricRows</table></section><section><h2>每秒吞吐曲线</h2><div class="chart">${_svgChart(d)}</div>$chartScript</section><section><h2>模型输出</h2><div class="rendered-output">${_renderedOutputHtml(d)}</div></section></body></html>''';
}

String _svgPoints(Diagnostic d) {
  if (d.points.isEmpty) return '';
  final maxX = d.points.last.seconds <= 0 ? 1 : d.points.last.seconds;
  final maxY = _chartScale(d).max;
  return d.points
      .map(
        (p) =>
            '${(p.seconds / maxX * 780 + 80).toStringAsFixed(1)},${(350 - p.tokensPerSecond / maxY * 300).toStringAsFixed(1)}',
      )
      .join(' ');
}

String _svgChart(Diagnostic d) {
  final maxX = d.points.isEmpty || d.points.last.seconds <= 0
      ? 1
      : d.points.last.seconds;
  final scale = _chartScale(d);
  final maxY = scale.max;
  final maxYLabel = tokenText(maxY);
  final points = _svgPoints(d);
  final xLabel = numberText(maxX, decimals: 2);
  final yTicks = List.generate(maxY ~/ scale.step + 1, (index) {
    final value = scale.step * index;
    final y = 350 - value / maxY * 300;
    return '<line x1="80" y1="$y" x2="860" y2="$y" stroke="#dfe6e3"/><text class="y-tick" x="70" y="${y + 4}" text-anchor="end" fill="#71808b" font-size="14">${tokenText(value)}</text>';
  }).join();
  final tickCount = d.points.length <= 8 ? d.points.length : 8;
  final xTicks = d.points.isEmpty
      ? '<text x="80" y="375" fill="#71808b" font-size="12">0.00 s</text>'
      : List.generate(tickCount, (index) {
          final pointIndex = tickCount == 1
              ? 0
              : (index * (d.points.length - 1) / (tickCount - 1)).round();
          final p = d.points[pointIndex];
          final x = p.seconds / maxX * 780 + 80;
          return '<line x1="$x" y1="50" x2="$x" y2="350" stroke="#edf1ef"/><line x1="$x" y1="350" x2="$x" y2="356" stroke="#71808b"/><text class="x-tick" x="$x" y="375" text-anchor="middle" fill="#71808b" font-size="13">${numberText(p.seconds, decimals: 2)}</text>';
        }).join();
  final dotOpacity = d.points.length <= 120 ? '1' : '0';
  final dots = d.points.map((p) {
    final x = p.seconds / maxX * 780 + 80;
    final y = 350 - p.tokensPerSecond / maxY * 300;
    return '<circle class="sample-point" data-seconds="${p.seconds}" data-tps="${p.tokensPerSecond}" cx="$x" cy="$y" r="1.5" fill="#087f70" fill-opacity="$dotOpacity" pointer-events="all"><title>${numberText(p.seconds, decimals: 2)} s · ${tokenText(p.tokensPerSecond)} token/s</title></circle>';
  }).join();
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 420" role="img" aria-label="每秒吞吐曲线，横轴时间秒，纵轴 token/s"><text x="450" y="410" text-anchor="middle" fill="#71808b" font-size="14">时间 (s)</text><text x="16" y="190" text-anchor="middle" fill="#71808b" font-size="14" transform="rotate(-90 16 190)">Token/s</text>$yTicks$xTicks<line x1="80" y1="50" x2="80" y2="350" stroke="#71808b"/><line x1="80" y1="350" x2="860" y2="350" stroke="#71808b"/><polyline fill="none" stroke="#087f70" stroke-width="1.25" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round" points="$points"/>$dots<text x="80" y="35" fill="#71808b" font-size="12">0–$maxYLabel token/s</text><text x="860" y="395" text-anchor="end" fill="#71808b" font-size="12">$xLabel s</text></svg>';
}

({int step, int max}) _chartScale(Diagnostic d) {
  final peak = d.points.fold<double>(
    1,
    (value, point) => math.max(value, point.tokensPerSecond),
  );
  final target = peak / 4;
  final power = math.pow(10, (math.log(target) / math.ln10).floor());
  final factor = [1, 2, 5, 10].firstWhere((n) => n * power >= target);
  final step = math.max(1, (factor * power).ceil());
  return (step: step, max: (peak / step).ceil() * step);
}
