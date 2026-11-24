import 'package:aijiance/model_output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_windows/webview_windows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows renders HTML and runs Canvas, SVG and animation scripts', (
    tester,
  ) async {
    const source = '''<!doctype html><html><head><style>
      @keyframes move { from { transform: translateX(0); } to { transform: translateX(100px); } }
      #shape { animation: move 2s linear infinite; }
      </style></head><body><h1>Windows preview</h1>
      <canvas id="canvas" width="100" height="100"></canvas>
      <svg width="200" height="80"><circle id="shape" cx="20" cy="20" r="10" fill="red"/></svg>
      <script>
      window.framesRendered = 0;
      function animate() {
        window.framesRendered++;
        const ctx = document.getElementById('canvas').getContext('2d');
        ctx.fillStyle = 'rgb(255, 0, 0)'; ctx.fillRect(0, 0, 100, 100);
        requestAnimationFrame(animate);
      }
      requestAnimationFrame(animate);
      </script></body></html>''';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: HtmlPagePreview(source: source)),
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    WebviewController? controller;
    int firstFrame = 0;
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      final webview = find.byType(Webview);
      if (webview.evaluate().isEmpty) continue;
      controller = tester.widget<Webview>(webview).controller;
      firstFrame =
          (await controller.executeScript('window.framesRendered || 0') as num)
              .toInt();
      if (firstFrame > 0) break;
    }
    expect(
      firstFrame,
      greaterThan(0),
      reason: 'WebView2 must execute the generated HTML scripts',
    );
    await tester.pump(const Duration(milliseconds: 200));
    final frame = await controller!.executeScript('window.framesRendered');
    expect(
      frame,
      greaterThan(firstFrame),
      reason: 'Animation must continue across frames',
    );
    expect(
      await controller.executeScript(
        "document.querySelector('h1').textContent",
      ),
      'Windows preview',
    );
    expect(
      await controller.executeScript(
        "Array.from(document.getElementById('canvas').getContext('2d').getImageData(0,0,1,1).data)",
      ),
      [255, 0, 0, 255],
    );
    expect(
      await controller.executeScript(
        "document.getElementById('shape').getAnimations().length",
      ),
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });
}
