/// Reasoning controls understood by common OpenAI-compatible upstreams.
///
/// Unknown model ids deliberately have only the default option. That avoids
/// sending vendor-specific fields to an endpoint that may reject them.
class ReasoningOption {
  const ReasoningOption(this.id, this.label);
  final String id;
  final String label;
}

enum ReasoningVendor {
  openAi,
  claude,
  gemini,
  deepSeek,
  grok,
  glm,
  kimi,
  minimax,
  unknown,
}

ReasoningVendor reasoningVendorForModel(String model) {
  final value = model.toLowerCase();
  if (value.contains('claude')) return ReasoningVendor.claude;
  if (value.contains('gemini') || value.contains('gemi')) {
    return ReasoningVendor.gemini;
  }
  if (value.contains('deepseek') ||
      value.contains('deep-seek') ||
      value.contains('r1')) {
    return ReasoningVendor.deepSeek;
  }
  if (value.contains('grok') || value.contains('xai')) {
    return ReasoningVendor.grok;
  }
  if (value.contains('glm') ||
      value.contains('chatglm') ||
      value.contains('zhipu')) {
    return ReasoningVendor.glm;
  }
  if (value.contains('kimi') || value.contains('moonshot')) {
    return ReasoningVendor.kimi;
  }
  if (value.contains('minimax') || value.contains('mini-max')) {
    return ReasoningVendor.minimax;
  }
  if (value.contains('gpt') ||
      value.contains('openai') ||
      value.startsWith('o1') ||
      value.startsWith('o3') ||
      value.startsWith('o4')) {
    return ReasoningVendor.openAi;
  }
  return ReasoningVendor.unknown;
}

List<ReasoningOption> reasoningOptionsForModel(String model) {
  const defaults = [ReasoningOption('default', '默认 (default)')];
  final vendor = reasoningVendorForModel(model);
  if (vendor == ReasoningVendor.unknown) return defaults;
  // OpenAI-compatible reasoning_effort is deliberately model-version
  // agnostic. Relays frequently rename models (and private models may use a
  // GPT-like id), so a client should expose the standard effort scale rather
  // than baking a special case for one model generation.
  if (vendor == ReasoningVendor.openAi) {
    return const [
      ReasoningOption('low', '轻度 (low)'),
      ReasoningOption('medium', '中 (medium)'),
      ReasoningOption('high', '高 (high)'),
      ReasoningOption('xhigh', '极高 (xhigh)'),
      ReasoningOption('max', '最大 (max)'),
    ];
  }
  if (vendor == ReasoningVendor.claude || vendor == ReasoningVendor.gemini) {
    return const [
      ReasoningOption('default', '默认 (default)'),
      ReasoningOption('low', '低 (low)'),
      ReasoningOption('medium', '中 (medium)'),
      ReasoningOption('high', '高 (high)'),
    ];
  }
  if (vendor == ReasoningVendor.grok) {
    return const [
      ReasoningOption('default', '默认 (default)'),
      ReasoningOption('minimal', '极低 (minimal)'),
      ReasoningOption('low', '低 (low)'),
      ReasoningOption('medium', '中 (medium)'),
      ReasoningOption('high', '高 (high)'),
    ];
  }
  return [
    const ReasoningOption('default', '默认 (default)'),
    const ReasoningOption('low', '低 (low)'),
    const ReasoningOption('medium', '中 (medium)'),
    const ReasoningOption('high', '高 (high)'),
    if (vendor == ReasoningVendor.deepSeek)
      const ReasoningOption('max', '最大 (max)'),
  ];
}

String reasoningLabel(String model, String id) =>
    reasoningOptionsForModel(model)
        .firstWhere(
          (option) => option.id == id,
          orElse: () => ReasoningOption(id, '自定义 ($id)'),
        )
        .label;

bool hasKnownReasoningFormat(String model) =>
    reasoningVendorForModel(model) != ReasoningVendor.unknown;

int _budgetFor(String intensity) => switch (intensity) {
  'low' => 2048,
  'medium' => 8192,
  'high' => 16384,
  'xhigh' => 32768,
  'max' => 65536,
  'minimal' => 1024,
  _ => 0,
};

/// Adds the vendor-specific reasoning field to a chat-completions body.
Map<String, dynamic> applyReasoning(
  Map<String, dynamic> body,
  String model,
  String intensity,
) {
  intensity = intensity.trim();
  if (intensity.isEmpty || intensity == 'default') {
    return body;
  }
  final vendor = reasoningVendorForModel(model);
  if (vendor == ReasoningVendor.unknown || _budgetFor(intensity) == 0) {
    // Relay models may expose additional effort values. Explicit custom
    // values use reasoning_effort; known budgets keep the vendor format.
    body['reasoning_effort'] = intensity;
    return body;
  }
  switch (vendor) {
    case ReasoningVendor.claude:
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': _budgetFor(intensity),
      };
    case ReasoningVendor.gemini:
      body['thinking_config'] = {'thinking_budget': _budgetFor(intensity)};
    case ReasoningVendor.openAi:
    case ReasoningVendor.grok:
    case ReasoningVendor.deepSeek:
    case ReasoningVendor.glm:
    case ReasoningVendor.kimi:
    case ReasoningVendor.minimax:
      body['reasoning_effort'] = intensity;
    case ReasoningVendor.unknown:
      break;
  }
  return body;
}
