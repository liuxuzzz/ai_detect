import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const appName = 'AI质量检测';
const projectUrl = 'https://github.com/liuxuzzz/ai_detect.git';
const cloudShareUrl = 'https://ai_detect.wv.gs/';

Future<void> openProjectLink(BuildContext context, String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {
    // Keep the address available when the OS cannot open a browser.
  }
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('无法打开浏览器，请复制地址访问：$url')));
  }
}

class AppAboutDialog extends StatefulWidget {
  const AppAboutDialog({super.key});

  @override
  State<AppAboutDialog> createState() => _AppAboutDialogState();
}

class _AppAboutDialogState extends State<AppAboutDialog> {
  late final info = PackageInfo.fromPlatform();
  late final notes = rootBundle.loadString('CHANGELOG.md');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('关于 $appName'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<PackageInfo>(
              future: info,
              builder: (_, snapshot) => Text(
                snapshot.hasData
                    ? '版本 v${snapshot.data!.version}'
                    : snapshot.hasError
                    ? '暂时无法读取版本信息'
                    : '正在读取版本…',
              ),
            ),
            const SizedBox(height: 12),
            const Text('项目地址'),
            TextButton(
              onPressed: () => openProjectLink(context, projectUrl),
              child: const Text('ai_detect · GitHub'),
            ),
            const SelectableText(projectUrl),
            const Divider(height: 28),
            FutureBuilder<String>(
              future: notes,
              builder: (_, snapshot) => SelectableText(
                snapshot.data ?? (snapshot.hasError ? '版本说明读取失败' : '正在加载版本说明…'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
