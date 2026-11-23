import assert from 'node:assert/strict'
import test from 'node:test'
import { backendUrl } from '../src/api-url.js'

test('API data and SSE URLs use the backend port on the current host', () => {
  const options = { pageUrl: 'http://192.0.2.10:8080/tests?tab=mine#result' }
  for (const path of ['/api/reports/upload', '/api/tasks/12/events', '/api/public/reports/report', '/api/public/shares/token']) {
    assert.equal(backendUrl(path, options), `http://192.0.2.10:8081${path}`)
  }
})

test('custom ports and IPv6 keep the page protocol and host', () => {
  assert.equal(backendUrl('/api/tasks', {
    pageUrl: 'https://[2001:db8::1]:8080/', apiPort: '8443',
  }), 'https://[2001:db8::1]:8443/api/tasks')
})

test('an explicit backend origin or path works independently of the page', () => {
  assert.equal(backendUrl('/api/tasks?status=queued', {
    apiBaseUrl: ' https://api.example.test/cloud/ ',
  }), 'https://api.example.test/cloud/api/tasks?status=queued')
})

test('Cloudflare API domains keep HTTPS and do not add the Docker port', () => {
  assert.equal(backendUrl('/api/auth/options', {
    apiBaseUrl: 'https://api.example.test', apiPort: '8081', pageUrl: 'https://ai.example.test/',
  }), 'https://api.example.test/api/auth/options')
})

test('the startup runtime config overrides the build defaults', async () => {
  globalThis.__AI_DETECT_CONFIG__ = { apiBaseUrl: 'https://runtime-api.example.test', apiPort: '8081' }
  try {
    const { apiUrl } = await import('../src/api-url.js?runtime-test')
    assert.equal(apiUrl('/api/reports/upload'), 'https://runtime-api.example.test/api/reports/upload')
  } finally { delete globalThis.__AI_DETECT_CONFIG__ }
})
