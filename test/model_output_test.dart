import 'package:aijiance/model_output.dart';
import 'package:aijiance/data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final output in [
    '只会输出普通文本，答案是 42。\n1 < 2。',
    '说明\n```html\n<div>第一个</div>\n```\n中间文字\n```html\n<p>第二个</p>\n```\n结束',
    '前文\n<!doctype html><html><head><style>body{color:red}</style></head><body><div><div>内容</div></div><script>const s = "</html>";</script></body></html>\n后文',
    '前文<div>未结束的 HTML',
    '```html\n<div>未结束的围栏',
    '```python\nprint("<div>this is code</div>")\n```\n末尾',
    '前<img src="a">后<br/>最后',
  ]) {
    test('preserves every original character: ${output.substring(0, 8)}', () {
      final parts = splitModelOutput(output);
      expect(parts.map((p) => p.text).join(), output);
      for (final part in parts) {
        expect(
          output.substring(part.offset, part.offset + part.text.length),
          part.text,
        );
      }
    });
  }

  test(
    'recognizes multiple fenced and raw HTML without folding prose or Python',
    () {
      final parts = splitModelOutput(
        '前文\n```html\n<div>一个</div>\n```\n中间<p>两个</p>后文\n```python\nprint("<p>code</p>")\n```\n',
      );
      expect(parts.where((p) => p.html != null).map((p) => p.html), [
        '<div>一个</div>\n',
        '<p>两个</p>',
      ]);
      expect(parts.last.html, isNull);
      expect(parts.last.text, contains('print('));
    },
  );

  test('does not swallow prose following a raw full HTML document', () {
    final parts = splitModelOutput(
      '开头<!doctype html><html><body>答案</body></html>结尾',
    );
    expect(parts.map((p) => p.html), [
      null,
      '<!doctype html><html><body>答案</body></html>',
      null,
    ]);
    expect(parts.last.text, '结尾');
  });

  test('recognizes documents beginning with metadata or script tags', () {
    final parts = splitModelOutput(
      '<meta charset="utf-8"><title>诊断</title><script>document.body</script>',
    );
    expect(
      parts.where((part) => part.html != null).first.html,
      contains('<meta charset'),
    );
  });

  testWidgets(
    'Agent artifact renders with commentary and retains source access',
    (tester) async {
      const source = '<!doctype html><html><body><h1>工具生成页面</h1></body></html>';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ModelOutputView(
              output: '已创建页面\n$source',
              autoPreviewHtml: true,
              activities: [
                ModelActivity(kind: 'output', content: '已创建页面'),
                ModelActivity(
                  kind: 'html_artifact',
                  id: 'page',
                  content: source,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已创建页面'), findsOneWidget);
      expect(find.byType(HtmlPagePreview), findsOneWidget);
      expect(
        tester.widget<HtmlPagePreview>(find.byType(HtmlPagePreview)).source,
        source,
      );
      await tester.tap(find.text('源代码'));
      await tester.pumpAndSettle();
      expect(find.text(source), findsOneWidget);
      expect(find.byType(HtmlPagePreview), findsNothing);
    },
  );

  testWidgets('old Agent appended HTML is visible alongside activity output', (
    tester,
  ) async {
    const source = '<html><body><h1>历史工具页面</h1></body></html>';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ModelOutputView(
            output: '已完成\n$source',
            autoPreviewHtml: true,
            activities: [ModelActivity(kind: 'output', content: '已完成')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HtmlPagePreview), findsOneWidget);
    expect(
      tester.widget<HtmlPagePreview>(find.byType(HtmlPagePreview)).source,
      source,
    );
  });

  testWidgets('Agent fenced HTML renders automatically without tool calls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ModelOutputView(
            output: '```html\n<h1>直接输出页面</h1>\n```',
            autoPreviewHtml: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HtmlPagePreview), findsOneWidget);
  });

  testWidgets(
    'HTML folds in the output, expands during streaming, and keeps original source',
    (tester) async {
      const beginning = '前文\n```html\n';
      const source = '<div style="--x:var(--y)">答案</div>';
      Future<void> show(String output, bool receiving) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ModelOutputView(output: output, receiving: receiving),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show('$beginning$source', true);
      expect(find.text('前文\n'), findsOneWidget);
      expect(find.byType(Html), findsNothing);
      expect(find.text(source), findsNothing);
      await tester.tap(find.text('HTML'));
      await tester.pumpAndSettle();
      expect(find.text(source), findsOneWidget);
      await tester.tap(find.text('渲染预览'));
      await tester.pumpAndSettle();
      expect(find.byType(Html), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The same HTML block remains expanded and in preview as chunks arrive.
      await show('$beginning$source<p>新内容</p>\n```\n后文', false);
      expect(find.byType(Html), findsOneWidget);
      expect(find.text('后文'), findsOneWidget);
      await tester.tap(find.text('源代码'));
      await tester.pumpAndSettle();
      expect(find.text('$source<p>新内容</p>\n'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
