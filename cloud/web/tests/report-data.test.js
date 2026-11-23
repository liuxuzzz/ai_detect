import assert from 'node:assert/strict'
import test from 'node:test'
import { modelPreview, samplesInRange, reasoningLabel } from '../src/report-data.js'
import { metricItems, formatDuration, formatTokens } from '../src/report-format.js'

test('report units match the desktop and missing cache is distinct from zero', () => {
  assert.equal(formatDuration(1250), '1.25 s')
  assert.equal(formatTokens(1234.4), '1,234 token')
  const metrics = Object.fromEntries(metricItems({ metrics: {
    tokens_per_second: 8.8, cache_read_tokens: null, cache_write_tokens: 0,
  } }))
  assert.equal(metrics['平均吞吐'], '9 token/s')
  assert.equal(metrics['缓存读取'], '未上报')
  assert.equal(metrics['缓存写入'], '0 token')
  assert.equal(reasoningLabel('high'), '高（high）')
})

test('chart window retains fractional time samples and zero throughput', () => {
  const points = [{ seconds: 0, tps: 0 }, { seconds: 0.25, tps: 8 }, { seconds: 1, tps: 2 }]
  assert.deepEqual(samplesInRange(points, 0, 0.5), points.slice(0, 2))
  assert.deepEqual(samplesInRange(points, 0.5, 0.5), [points[2]])
})

test('preview uses the last artifact or isolated HTML, while plain output stays text', () => {
  assert.equal(modelPreview({ output: 'hello <script>alert(1)</script>' }), '')
  assert.equal(modelPreview({ output: 'prose\n```html\n<div>preview</div>\n```\ntrailing' }), '<div>preview</div>\n')
  assert.equal(modelPreview({ output: '<html><body>preview</body></html>trailing' }), '<html><body>preview</body></html>')
  assert.equal(modelPreview({ output: '<div>old</div>', activities: [
    { kind: 'html_artifact', content: '<svg>first</svg>' },
    { kind: 'html_artifact', content: '<svg>last</svg>' },
  ] }), '<svg>last</svg>')
})
