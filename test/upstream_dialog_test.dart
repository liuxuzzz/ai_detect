import 'package:aijiance/data.dart';
import 'package:aijiance/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'channel dialog validates proxy ports and restores saved SOCKS5 settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Upstream upstream = const Upstream(
        id: 'u',
        name: '渠道',
        baseUrl: 'https://relay.test/v1',
        apiKey: 'key',
        models: ['model'],
        selectedModel: 'model',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final result = await showDialog<Upstream>(
                    context: context,
                    builder: (_) =>
                        UpstreamDialog(id: upstream.id, initial: upstream),
                  );
                  if (result != null) upstream = result;
                },
                child: const Text('打开渠道'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开渠道'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('channel-proxy-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SOCKS5').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('channel-proxy-host')))
            .controller!
            .text,
        '127.0.0.1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('channel-proxy-port')),
        '0',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(UpstreamDialog), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('channel-proxy-port')),
        '1081',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(upstream.proxy.type, 'socks5');
      expect(upstream.proxy.port, 1081);
      await tester.tap(find.text('打开渠道'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('channel-proxy-port')))
            .controller!
            .text,
        '1081',
      );
      expect(find.text('SOCKS5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
