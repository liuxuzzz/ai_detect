import 'model_reasoning.dart';

enum ModelApi { responses, chatCompletions }

ModelApi modelApiFor(String baseUrl, String model) {
  final url = Uri.parse(baseUrl.trim());
  if (url.host == 'api.openai.com' ||
      url.path.replaceFirst(RegExp(r'/+$'), '').endsWith('/responses') ||
      reasoningVendorForModel(model) == ReasoningVendor.openAi) {
    return ModelApi.responses;
  }
  return ModelApi.chatCompletions;
}

Uri upstreamEndpoint(String baseUrl, String endpoint) {
  final url = Uri.parse(baseUrl.trim());
  final path = url.path.replaceFirst(RegExp(r'/+$'), '');
  final prefix = path.replaceFirst(
    RegExp(r'/(chat/completions|responses|models)$'),
    '',
  );
  return url
      .replace(path: '${path.isEmpty ? '/v1' : prefix}/$endpoint')
      .removeFragment();
}

Map<String, dynamic> responsesRequest({
  required String model,
  required List<Map<String, dynamic>> messages,
  required String reasoningEffort,
  List<Map<String, Object?>>? tools,
}) {
  final body = <String, dynamic>{
    'model': model,
    'input': [for (final message in messages) ..._responseItems(message)],
    'stream': true,
    'store': false,
    if (tools != null) ...{
      'tools': [
        for (final tool in tools)
          if (tool['function'] case final Map function)
            {'type': 'function', 'strict': false, ...function},
      ],
      'include': ['reasoning.encrypted_content'],
    },
  };
  if (reasoningEffort.trim().isNotEmpty && reasoningEffort != 'default') {
    body['reasoning'] = {'effort': reasoningEffort.trim(), 'summary': 'auto'};
  }
  return body;
}

/// Accepts ordinary conversation messages and the output items of earlier turns.
Iterable<Map<String, dynamic>> _responseItems(
  Map<String, dynamic> message,
) sync* {
  if (message['type'] != null) {
    yield message;
  } else if (message['role'] == 'tool') {
    yield {
      'type': 'function_call_output',
      'call_id': message['tool_call_id'],
      'output': message['content'],
    };
  } else {
    if (message['content'] != null) {
      yield {'role': message['role'], 'content': message['content']};
    }
    if (message['tool_calls'] case final List calls) {
      for (final call in calls.whereType<Map>()) {
        final function = call['function'] as Map;
        yield {
          'type': 'function_call',
          'call_id': call['id'],
          'name': function['name'],
          'arguments': function['arguments'],
        };
      }
    }
  }
}
