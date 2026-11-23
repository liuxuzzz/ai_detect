import 'package:flutter/material.dart';

class ModelSelectionDialog extends StatefulWidget {
  const ModelSelectionDialog({
    super.key,
    required this.models,
    required this.selected,
  });

  final List<String> models;
  final List<String> selected;

  @override
  State<ModelSelectionDialog> createState() => _ModelSelectionDialogState();
}

class _ModelSelectionDialogState extends State<ModelSelectionDialog> {
  late final selected = widget.selected.toSet();
  late final models = {...widget.selected, ...widget.models}.toList();
  String search = '';

  @override
  Widget build(BuildContext context) {
    final visible = models
        .where((model) => model.toLowerCase().contains(search))
        .toList();
    return AlertDialog(
      title: const Text('选择渠道模型'),
      content: SizedBox(
        width: 480,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('勾选要添加到渠道的模型'),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: '搜索模型',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  setState(() => search = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Text('已选 ${selected.length} 个 · 共 ${models.length} 个'),
            const SizedBox(height: 8),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有匹配的模型'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final model = visible[index];
                        return CheckboxListTile(
                          title: Text(model),
                          value: selected.contains(model),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              selected.add(model);
                            } else {
                              selected.remove(model);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected.toList()),
          child: const Text('确认选择'),
        ),
      ],
    );
  }
}
