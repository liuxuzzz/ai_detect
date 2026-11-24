import 'package:flutter_test/flutter_test.dart';

import 'package:aijiance/model_reasoning.dart';

void main() {
  test('known providers expose vendor-specific intensity choices', () {
    expect(reasoningOptionsForModel('gpt-5.1'), hasLength(5));
    expect(reasoningOptionsForModel('gpt-6.1-sol').map((option) => option.id), [
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
    expect(
      reasoningOptionsForModel('gpt-6.2-sol').map((option) => option.id),
      reasoningOptionsForModel('gpt-6.1-sol').map((option) => option.id),
    );
    expect(
      reasoningOptionsForModel('gpt-6.1-sol').map((option) => option.label),
      ['轻度 (low)', '中 (medium)', '高 (high)', '极高 (xhigh)', '最大 (max)'],
    );
    expect(reasoningOptionsForModel('claude-sonnet-4'), hasLength(4));
    expect(reasoningOptionsForModel('gemini-2.5-pro'), hasLength(4));
    expect(reasoningOptionsForModel('deepseek-reasoner').map((e) => e.id), [
      'default',
      'low',
      'medium',
      'high',
      'max',
    ]);
    expect(reasoningOptionsForModel('grok-4'), hasLength(5));
    expect(reasoningOptionsForModel('glm-5'), hasLength(4));
    expect(reasoningOptionsForModel('kimi-k2'), hasLength(4));
    expect(reasoningOptionsForModel('MiniMax-M2'), hasLength(4));
  });

  test('unknown models allow an optional manually supplied request field', () {
    expect(reasoningOptionsForModel('my-private-model'), hasLength(1));
    final defaultBody = applyReasoning(
      {'model': 'my-private-model'},
      'my-private-model',
      '',
    );
    expect(defaultBody, {'model': 'my-private-model'});
    final customBody = applyReasoning(
      {'model': 'my-private-model'},
      'my-private-model',
      'vendor-deep',
    );
    expect(customBody['reasoning_effort'], 'vendor-deep');
  });

  test('request parameters follow each vendor format', () {
    expect(applyReasoning({}, 'deepseek-reasoner', 'default'), isEmpty);
    expect(
      applyReasoning({}, 'deepseek-reasoner', 'max')['reasoning_effort'],
      'max',
    );
    expect(applyReasoning({}, 'gpt-5.1', 'high')['reasoning_effort'], 'high');
    expect(applyReasoning({}, 'gpt-6.1-sol', 'max')['reasoning_effort'], 'max');
    expect(applyReasoning({}, 'claude-sonnet-4', 'medium')['thinking'], {
      'type': 'enabled',
      'budget_tokens': 8192,
    });
    expect(applyReasoning({}, 'gemini-2.5-pro', 'low')['thinking_config'], {
      'thinking_budget': 2048,
    });
  });

  test('explicit custom efforts survive labels and request serialization', () {
    for (final model in [
      'deepseek-v4',
      'gpt-5.1',
      'claude-sonnet-4',
      'gemini-2.5-pro',
    ]) {
      expect(reasoningLabel(model, 'vendor-deep'), '自定义 (vendor-deep)');
      expect(applyReasoning({}, model, ' vendor-deep '), {
        'reasoning_effort': 'vendor-deep',
      });
    }
  });
}
