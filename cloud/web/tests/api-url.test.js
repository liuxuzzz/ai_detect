import assert from 'node:assert/strict'
import test from 'node:test'
import { backendUrl } from '../src/api-url.js'

test('data, uploads and SSE use the same domain and port as the page', () => {
  for (const pageUrl of ['http://192.0.2.10:6600/tests?tab=mine#result', 'https://ai.example.test/r/report', 'https://[2001:db8::1]:8443/']) {
    const origin = new URL(pageUrl).origin
    for (const path of ['/api/reports/upload', '/api/tasks/12/events', '/api/public/reports/report', '/api/public/shares/token']) {
      assert.equal(backendUrl(path, { pageUrl }), origin + path)
    }
  }
})

test('HTTPS domains keep their normal HTTPS port without API configuration', () => {
  assert.equal(backendUrl('/api/tasks?status=queued', { pageUrl: 'https://ai.example.test/' }), 'https://ai.example.test/api/tasks?status=queued')
})

test('legacy runtime API configuration cannot send requests to a different origin', async () => {
  globalThis.location = { href: 'https://ai.example.test/r/report' }
  globalThis.__AI_DETECT_CONFIG__ = { apiBaseUrl: 'https://old-api.example.test', apiPort: '6601' }
  try {
    const { apiUrl } = await import('../src/api-url.js?runtime-test')
    assert.equal(apiUrl('/api/reports/upload'), 'https://ai.example.test/api/reports/upload')
  } finally {
    delete globalThis.location
    delete globalThis.__AI_DETECT_CONFIG__
  }
})
