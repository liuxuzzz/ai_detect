import 'agent_tools.dart';
import 'data.dart';

/// Decodes Responses events, retaining output items for stateless Agent turns.
class ResponsesStream {
  ResponsesStream({required this.onText, this.onActivity});

  final void Function(String) onText;
  final void Function(ModelActivity)? onActivity;
  final _parts = <String, String>{};
  final _items = <int, Map<String, dynamic>>{};
  final _output = StringBuffer();
  Map<String, dynamic>? usage;
  bool completed = false;

  String get output => _output.toString();
  List<Map<String, dynamic>> get outputItems => [
    for (final index in _items.keys.toList()..sort()) _items[index]!,
  ];
  List<AgentToolCall> get toolCalls => [
    for (final item in outputItems)
      if (item['type'] == 'function_call')
        AgentToolCall(
          id: item['call_id'] as String? ?? item['id'] as String? ?? '',
          name: item['name'] as String? ?? '',
          arguments: item['arguments'] as String? ?? '',
        ),
  ];

  void add(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    final response = (event['response'] as Map?) ?? event;
    final status = response['status'];
    if (type == 'error' ||
        type == 'response.failed' ||
        status == 'failed' ||
        event['error'] != null ||
        response['error'] != null) {
      throw const FormatException('上游 Responses 请求失败');
    }
    if (type == 'response.incomplete' || status == 'incomplete') {
      throw const FormatException('上游 Responses 响应未完成');
    }
    if (status == 'cancelled') {
      throw const FormatException('上游 Responses 请求已取消');
    }
    if (response['usage'] case final Map value) {
      usage = value.cast<String, dynamic>();
    }
    final index = (event['output_index'] as num?)?.toInt() ?? 0;
    final part = (event['content_index'] as num?)?.toInt() ?? 0;
    switch (type) {
      case 'response.output_text.delta':
      case 'response.refusal.delta':
        _part('$index:$part:text', event['delta'], delta: true);
      case 'response.output_text.done':
        _part('$index:$part:text', event['text']);
      case 'response.refusal.done':
        _part('$index:$part:text', event['refusal']);
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_summary_text.done':
        _part(
          '$index:${event['summary_index'] ?? 0}:summary',
          event[type.endsWith('.delta') ? 'delta' : 'text'],
          delta: type.endsWith('.delta'),
        );
      case 'response.reasoning_text.delta':
      case 'response.reasoning_text.done':
        _part(
          '$index:$part:reasoning',
          event[type.endsWith('.delta') ? 'delta' : 'text'],
          delta: type.endsWith('.delta'),
        );
      case 'response.output_item.added':
      case 'response.output_item.done':
        if (event['item'] case final Map item) {
          _item(index, item.cast<String, dynamic>());
        }
      case 'response.content_part.done':
        if (event['part'] case final Map value) _content(index, part, value);
      case 'response.function_call_arguments.delta':
      case 'response.function_call_arguments.done':
        final item = _items.putIfAbsent(
          index,
          () => {'type': 'function_call', 'id': event['item_id']},
        );
        _arguments(
          index,
          item,
          event[type.endsWith('.delta') ? 'delta' : 'arguments'],
          delta: type.endsWith('.delta'),
        );
    }
    if (response['output'] case final List items) {
      for (var i = 0; i < items.length; i++) {
        if (items[i] case final Map item) {
          _item(i, item.cast<String, dynamic>());
        }
      }
    }
    if (type == 'response.completed' || status == 'completed') {
      if (status != null && status != 'completed') {
        throw const FormatException('上游 Responses 状态异常');
      }
      completed = true;
    }
  }

  void _item(int index, Map<String, dynamic> value) {
    final previous = _items[index];
    final item = _items[index] = {...?previous, ...value};
    if (value['type'] == 'function_call') {
      if (previous?['name'] != value['name']) {
        onActivity?.call(
          ModelActivity(
            kind: 'tool_call',
            id: _callId(item),
            name: value['name'] as String? ?? '',
            content: '',
          ),
        );
      }
      _arguments(index, item, value['arguments']);
    }
    if (value['content'] case final List parts) {
      for (var i = 0; i < parts.length; i++) {
        if (parts[i] case final Map part) _content(index, i, part);
      }
    }
    if (value['summary'] case final List parts) {
      for (var i = 0; i < parts.length; i++) {
        if (parts[i] case final Map part) {
          _part('$index:$i:summary', part['text']);
        }
      }
    }
  }

  void _content(int index, int part, Map value) {
    switch (value['type']) {
      case 'output_text':
        _part('$index:$part:text', value['text']);
      case 'refusal':
        _part('$index:$part:text', value['refusal']);
      case 'reasoning_text':
        _part('$index:$part:reasoning', value['text']);
    }
  }

  void _arguments(
    int index,
    Map<String, dynamic> item,
    dynamic value, {
    bool delta = false,
  }) {
    final suffix = _suffix('$index:arguments', value, delta: delta);
    item['arguments'] = _parts['$index:arguments'] ?? '';
    if (suffix.isNotEmpty) {
      onActivity?.call(
        ModelActivity(kind: 'tool_call', id: _callId(item), content: suffix),
      );
    }
  }

  String _callId(Map item) => '${item['call_id'] ?? item['id'] ?? ''}';

  void _part(String key, dynamic value, {bool delta = false}) {
    final suffix = _suffix(key, value, delta: delta);
    if (suffix.isEmpty) return;
    if (key.endsWith(':text')) {
      _output.write(suffix);
      onText(suffix);
    } else {
      onActivity?.call(ModelActivity(kind: 'thinking', content: suffix));
    }
  }

  String _suffix(String key, dynamic value, {required bool delta}) {
    if (value is! String) return '';
    final current = _parts[key] ?? '';
    final suffix = delta
        ? value
        : value.startsWith(current)
        ? value.substring(current.length)
        : '';
    _parts[key] = current + suffix;
    return suffix;
  }
}
