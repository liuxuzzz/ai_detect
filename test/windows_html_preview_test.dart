import 'dart:async';
import 'dart:io';

import 'package:aijiance/model_output.dart';
import 'package:aijiance/windows_html_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_windows/webview_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('io.jns.webview.win');
  const view = MethodChannel('io.jns.webview.win/7');
  const events = MethodChannel('io.jns.webview.win/7/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  String? version;
  Completer<Map<String, dynamic>>? initialization;

  setUp(() {
    calls = [];
    version = '140.0.0.0';
    initialization = null;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getWebViewVersion' => version,
        'initialize' => initialization?.future ?? {'textureId': 7},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(view, (call) async {
      calls.add(call);
      return call.method == 'addScriptToExecuteOnDocumentCreated'
          ? 'resize'
          : null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(view, null);
    messenger.setMockMethodCallHandler(events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> settleIO(WidgetTester tester, {int expectedLoads = 1}) async {
    // Alternate Flutter microtasks with actual file I/O completion.
    for (var i = 0; i < 30; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      if (calls.where((call) => call.method == 'loadUrl').length >=
          expectedLoads) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 100; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      final mappings = calls.where(
        (call) => call.method == 'setVirtualHostNameMapping',
      );
      final exists = await tester.runAsync(() async {
        for (final call in mappings) {
          if (await Directory((call.arguments as List)[1] as String).exists()) {
            return true;
          }
        }
        return false;
      });
      if (calls.any((call) => call.method == 'dispose') && exists == false) {
        break;
      }
    }
  }

  testWidgets(
    'Windows routes large HTML to WebView2 without stripping animation scripts',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source =
          '<html><body><canvas id="scene"></canvas><script>requestAnimationFrame(() => {});</script><!--${'x' * (2 * 1024 * 1024)}--></body></html>';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: HtmlPagePreview(source: source)),
          ),
        ),
      );
      await settleIO(tester);
      expect(find.byType(WindowsHtmlPreview), findsOneWidget);
      expect(find.byType(Webview), findsOneWidget);
      final mapping =
          calls
                  .singleWhere(
                    (call) => call.method == 'setVirtualHostNameMapping',
                  )
                  .arguments
              as List;
      final directory = Directory(mapping[1] as String);
      expect(
        await tester.runAsync(
          () => File('${directory.path}/index.html').readAsString(),
        ),
        source,
      );
      expect(
        calls.singleWhere((call) => call.method == 'loadUrl').arguments,
        'https://${mapping[0]}/index.html?revision=1',
      );
      expect(calls.any((call) => call.method == 'loadStringContent'), isFalse);
      final script =
          calls
                  .singleWhere(
                    (call) =>
                        call.method == 'addScriptToExecuteOnDocumentCreated',
                  )
                  .arguments
              as String;
      expect(script, contains('ResizeObserver'));
      await remove(tester);
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      expect(await tester.runAsync(directory.exists), isFalse);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'streamed updates reuse the browser and load the latest complete HTML',
    (tester) async {
      Future<void> show(String source) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WindowsHtmlPreview(source: source)),
        ),
      );
      await show('<html><body>first</body></html>');
      await settleIO(tester);
      final mapping =
          calls
                  .singleWhere(
                    (call) => call.method == 'setVirtualHostNameMapping',
                  )
                  .arguments
              as List;
      await show('<html><body>second</body></html>');
      await tester.pump(const Duration(milliseconds: 200));
      await show(
        '<html><body><script>window.latest = true;</script>latest</body></html>',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await settleIO(tester, expectedLoads: 2);
      expect(calls.where((call) => call.method == 'initialize'), hasLength(1));
      expect(calls.where((call) => call.method == 'loadUrl'), hasLength(2));
      expect(
        await tester.runAsync(
          () => File('${mapping[1]}/index.html').readAsString(),
        ),
        contains('window.latest = true'),
      );
      await remove(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing WebView2 shows install and retry instead of a static preview',
    (tester) async {
      version = null;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: WindowsHtmlPreview(source: '<h1>page</h1>')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('安装 WebView2'), findsOneWidget);
      expect(find.byType(Webview), findsNothing);
      version = '140.0.0.0';
      await tester.tap(find.text('安装后重试'));
      await settleIO(tester);
      expect(find.byType(Webview), findsOneWidget);
      await remove(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing during browser initialization releases its resources', (
    tester,
  ) async {
    initialization = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: WindowsHtmlPreview(source: '<h1>page</h1>')),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(calls.any((call) => call.method == 'initialize'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    initialization!.complete({'textureId': 7});
    await remove(tester);
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    expect(calls.where((call) => call.method == 'loadUrl'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
