import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'db.dart';
import 'cloud_endpoint.dart';
import 'about.dart';

class HarnessSettings {
  const HarnessSettings({
    this.retryCount = 2,
    this.connectionTimeout = 45,
    this.idleTimeout = 3600,
    this.cloudApiUrl = '',
    this.cloudClientKey = '',
  });
  final int retryCount, connectionTimeout, idleTimeout;
  final String cloudApiUrl, cloudClientKey;
  static Future<HarnessSettings> load(LocalDb db) async {
    Future<int> read(String key, int fallback, int min, int max) async =>
        (int.tryParse(await db.setting(key) ?? '') ?? fallback).clamp(min, max);
    return HarnessSettings(
      retryCount: await read('retry_count', 2, 0, 20),
      connectionTimeout: await read('connection_timeout', 45, 1, 86400),
      idleTimeout: await read('idle_timeout', 3600, 1, 86400),
      cloudApiUrl: normalizeCloudApiUrl(
        await db.setting('cloud_api_url') ?? '',
      ),
      cloudClientKey: await db.setting('cloud_client_key') ?? '',
    );
  }
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.db, required this.settings});
  final LocalDb db;
  final HarnessSettings settings;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final form = GlobalKey<FormState>();
  late final retry = TextEditingController(
    text: '${widget.settings.retryCount}',
  );
  late final connection = TextEditingController(
    text: '${widget.settings.connectionTimeout}',
  );
  late final idle = TextEditingController(
    text: '${widget.settings.idleTimeout}',
  );
  late final cloudUrl = TextEditingController(
    text: widget.settings.cloudApiUrl,
  );
  late final cloudKey = TextEditingController(
    text: widget.settings.cloudClientKey,
  );
  bool busy = false;
  String message = '';
  @override
  void dispose() {
    for (final controller in [retry, connection, idle, cloudUrl, cloudKey]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget field(
    String label,
    TextEditingController controller, {
    bool retries = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      validator: (text) {
        final value = int.tryParse(text ?? '');
        final min = retries ? 0 : 1, max = retries ? 20 : 86400;
        return value == null || value < min || value > max
            ? '$min–$max，整数'
            : null;
      },
    ),
  );

  Future<void> backup(bool importing) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      const type = XTypeGroup(
        label: 'JSON',
        extensions: ['json'],
        uniformTypeIdentifiers: ['public.json'],
      );
      if (importing) {
        final file = await openFile(acceptedTypeGroups: [type]);
        if (file == null) return;
        await widget.db.importBackup(await file.readAsString());
        final settings = await HarnessSettings.load(widget.db);
        if (!mounted) return;
        retry.text = '${settings.retryCount}';
        connection.text = '${settings.connectionTimeout}';
        idle.text = '${settings.idleTimeout}';
        message = '导入完成';
      } else {
        final location = await getSaveLocation(
          suggestedName:
              'AI质量检测-${DateTime.now().toIso8601String().substring(0, 10)}.json',
          acceptedTypeGroups: [type],
        );
        if (location == null) return;
        final bytes = Uint8List.fromList(
          utf8.encode(await widget.db.exportBackup()),
        );
        await XFile.fromData(
          bytes,
          mimeType: 'application/json',
        ).saveTo(location.path);
        message = '备份完成';
      }
    } catch (e) {
      message = '${importing ? '导入' : '备份'}失败：$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('全局设置'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field('错误重试次数', retry, retries: true),
                field('Stream 连接超时 (s)', connection),
                field('Stream 空闲超时 (s)', idle),
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    '空闲超时从最近收到的数据分片开始计时；测试总时限为 60 分钟。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const Divider(),
                TextFormField(
                  controller: cloudUrl,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: '云端地址（可选）',
                    hintText: 'http://127.0.0.1:6600',
                    helperText: '留空即可离线使用；需要分享报告时填写浏览器中打开的站点地址',
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: cloudKey,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: '云端 Client Key（可选）',
                    hintText: '从分享站「个人中心」创建并复制 API Key（Client Key）',
                  ),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 8),
                const Text(
                  '云端地址和 Client Key 都是可选的。不配置时客户端只保存在本地并支持离线使用；需要分享报告时，可在 $cloudShareUrl 注册，在个人中心创建 Client Key，并填写浏览器中打开的站点地址；也可自建评测分享站。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => openProjectLink(context, cloudShareUrl),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开评测分享站'),
                  ),
                ),
                const Divider(),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => backup(false),
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('导出备份（含密钥）'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => backup(true),
                      icon: const Icon(Icons.file_upload_outlined),
                      label: const Text('导入备份（合并）'),
                    ),
                  ],
                ),
                const Divider(),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => const AppAboutDialog(),
                        ),
                  icon: const Icon(Icons.info_outline),
                  label: const Text('关于'),
                ),
                if (busy) const LinearProgressIndicator(),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(message),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  if (!form.currentState!.validate()) return;
                  setState(() => busy = true);
                  try {
                    for (final entry in {
                      'retry_count': retry.text,
                      'connection_timeout': connection.text,
                      'idle_timeout': idle.text,
                      'cloud_api_url': normalizeCloudApiUrl(cloudUrl.text),
                      'cloud_client_key': cloudKey.text.trim(),
                    }.entries) {
                      await widget.db.setSetting(entry.key, entry.value);
                    }
                    if (context.mounted) {
                      setState(() => busy = false);
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        message = '保存失败：$e';
                        busy = false;
                      });
                    }
                  }
                },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
