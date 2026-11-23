import 'dart:io';

import 'package:aijiance/data.dart';
import 'package:aijiance/db.dart';
import 'package:flutter_test/flutter_test.dart';

import 'duckdb_test_support.dart';

void main() {
  test('fresh database seeds the exact Pelican prompt once', () async {
    final directory = await Directory.systemTemp.createTemp('pelican-default-');
    LocalDb db = LocalDb(
      supportDirectory: () async => directory,
      libraryPath: duckdbTestLibrary,
    );
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    final prompt = (await db.prompts()).single;
    expect(prompt.name, '鹈鹕测试');
    expect(
      prompt.content,
      '创建一个 HTML ，内容是一张精细的 SVG 图片，画面是鹈鹕骑着自行车穿过故宫门，故宫门高 1.9999 米，车座椅高 0.5249 米，鹈鹕脖子以下 0.4751 米，脖子长 1.1011 米，让它摆好姿势能坐着车座椅成功骑车穿过门，做成 2D 动画版本，不要测试。',
    );
    await db.deletePrompt(prompt.id);
    await db.close();
    db = LocalDb(
      supportDirectory: () async => directory,
      libraryPath: duckdbTestLibrary,
    );
    expect(await db.prompts(), isEmpty);
  });

  for (final customized in [false, true]) {
    test(
      'existing default is ${customized ? 'preserved when customized' : 'updated while keeping its selected ID'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'pelican-upgrade-',
        );
        LocalDb db = LocalDb(
          supportDirectory: () async => directory,
          libraryPath: duckdbTestLibrary,
        );
        addTearDown(() async {
          await db.close();
          await directory.delete(recursive: true);
        });
        await db.deletePrompt(defaultPelicanPrompt.id);
        await db.execute(
          "DELETE FROM store_metadata WHERE key = 'pelican_prompt_seed_v1'",
        );
        final previous = TestPrompt(
          id: 'default-reasoning',
          name: '综合智力测试',
          content: customized
              ? '自定义内容'
              : '请解决下面的智力测试题，给出清晰、可复核的推理过程，并在最后给出答案：\n\n',
        );
        await db.savePrompt(previous);
        await db.setSetting('prompt', previous.id);
        await db.close();
        db = LocalDb(
          supportDirectory: () async => directory,
          libraryPath: duckdbTestLibrary,
        );
        final prompts = await db.prompts();
        expect(await db.setting('prompt'), previous.id);
        expect(prompts.where((p) => p.name == '鹈鹕测试'), hasLength(1));
        final old = prompts.singleWhere((p) => p.id == previous.id);
        expect(
          old.content,
          customized ? previous.content : defaultPelicanPrompt.content,
        );
        expect(prompts, hasLength(customized ? 2 : 1));
      },
    );
  }
}
