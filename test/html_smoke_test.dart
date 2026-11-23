import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_html/flutter_html.dart';

void main() {
  testWidgets('html smoke', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Html(
            data:
                '''<!doctype html><html><head><style>body { font-family: Arial; } table { border-collapse: collapse; } td { border: 1px solid #ddd; }</style></head><body><h1>Title</h1><p style="color: #ddd; --vendor-value: var(--x)">Answer</p><ul><li>one</li><li>two</li></ul><table><tr><td>ok</td></tr></table></body></html>''',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
