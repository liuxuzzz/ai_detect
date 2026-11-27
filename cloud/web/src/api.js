import { apiUrl } from './api-url'

const json = async (url, options = {}) => {
  const response = await fetch(apiUrl(url), {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(data.error || `请求失败 (${response.status})`)
  return data
}

const auth = (token) => ({ Authorization: `Bearer ${token}` })

export const api = {
  authOptions: (signal) => json('/api/auth/options', { signal, cache: 'no-store' }),
  emailCode: (value) => json('/api/auth/email-code', { method: 'POST', body: JSON.stringify(value) }),
  resetPassword: (value) => json('/api/auth/password/reset', { method: 'POST', body: JSON.stringify(value) }),
  oauthExchange: (value) => json('/api/auth/oauth/exchange', { method: 'POST', body: JSON.stringify(value) }),
  authSettings: (token, signal) => json('/api/admin/auth-settings', { headers: auth(token), signal, cache: 'no-store' }),
  updateAuthSettings: (token, value) => json('/api/admin/auth-settings', { method: 'PUT', headers: auth(token), body: JSON.stringify(value) }),
  testMail: (token) => json('/api/admin/auth-settings/test-mail', { method: 'POST', headers: auth(token) }),
  registration: (signal) => json('/api/auth/registration', { signal, cache: 'no-store' }),
  siteSettings: (token, signal) => json('/api/admin/settings', { headers: auth(token), signal, cache: 'no-store' }),
  updateSiteSettings: (token, value) => json('/api/admin/settings', { method: 'PUT', headers: auth(token), body: JSON.stringify(value) }),
  register: (value) => json('/api/auth/register', { method: 'POST', body: JSON.stringify(value) }),
  login: (value) => json('/api/auth/login', { method: 'POST', body: JSON.stringify(value) }),
  me: (token) => json('/api/auth/me', { headers: auth(token) }),
  reportVisibility: (token) => json('/api/auth/report-visibility', { headers: auth(token), cache: 'no-store' }),
  updateReportVisibility: (token, value) => json('/api/auth/report-visibility', { method: 'PUT', headers: auth(token), body: JSON.stringify(value) }),
  changePassword: (token, value) => json('/api/auth/password', { method: 'PUT', headers: auth(token), body: JSON.stringify(value) }),
  clientKeys: (token) => json('/api/auth/client-keys', { headers: auth(token), cache: 'no-store' }),
  createClientKey: (token) => json('/api/auth/client-keys', { method: 'POST', headers: auth(token) }),
  revealClientKey: (token, id) => json(`/api/auth/client-keys/${id}`, { headers: auth(token), cache: 'no-store' }),
  revokeClientKey: (token, id) => json(`/api/auth/client-keys/${id}`, { method: 'DELETE', headers: auth(token) }),
  dashboard: (token, query) => {
    const params = new URLSearchParams()
    Object.entries(query).forEach(([key, value]) => {
      if (value !== '' && value !== null && value !== undefined) params.set(key, value)
    })
    return json(`/api/dashboard?${params}`, { headers: auth(token) })
  },
  publicRankings: (query, signal) => json(`/api/public/rankings?${new URLSearchParams(query)}`, { signal }),
  reportDetails: (id, token, signal) => json(`/api/reports/${id}/details`, { headers: token ? auth(token) : {}, signal, cache: 'no-store' }),
  report: (slug, token, signal) => json(`/api/public/reports/${encodeURIComponent(slug)}`, { headers: token ? auth(token) : {}, signal, cache: 'no-store' }),
  sharedReport: (share, token, signal) => json(`/api/public/shares/${encodeURIComponent(share)}`, { headers: token ? auth(token) : {}, signal, cache: 'no-store' }),
  deleteMyReport: (token, id) => json(`/api/reports/${id}`, { method: 'DELETE', headers: auth(token) }),
  updateReportRanking: (token, id, visibility) => json(`/api/reports/${id}/ranking-visibility`, { method: 'PUT', headers: auth(token), body: JSON.stringify(visibility) }),
  comments: (id, query = {}, signal) => {
    const params = new URLSearchParams()
    Object.entries(query).forEach(([key, value]) => {
      if (value !== '' && value !== null && value !== undefined) params.set(key, value)
    })
    return json(`/api/reports/${id}/comments?${params}`, { signal })
  },
  rate: (token, id, score) => json(`/api/reports/${id}/rating`, { method: 'POST', headers: auth(token), body: JSON.stringify({ score }) }),
  comment: (token, id, content) => json(`/api/reports/${id}/comments`, { method: 'POST', headers: auth(token), body: JSON.stringify({ content }) }),
  channels: (token) => json('/api/channels', { headers: auth(token) }),
  addChannel: (token, value) => json('/api/channels', { method: 'POST', headers: auth(token), body: JSON.stringify(value) }),
  updateChannel: (token, id, value) => json(`/api/channels/${id}`, { method: 'PUT', headers: auth(token), body: JSON.stringify(value) }),
  deleteChannel: (token, id) => json(`/api/channels/${id}`, { method: 'DELETE', headers: auth(token) }),
  discoverModels: (token, value, signal) => json('/api/channels/models/discover', {
    method: 'POST', headers: auth(token), body: JSON.stringify(value), signal,
  }),
  testChannel: (token, id) => json(`/api/channels/${id}/test`, { method: 'POST', headers: auth(token) }),
  testChannelDraft: (token, value, signal) => json('/api/channels/test', {
    method: 'POST', headers: auth(token), body: JSON.stringify(value), signal,
  }),
  tasks: (token) => json('/api/tasks', { headers: auth(token) }),
  addTask: (token, value) => json('/api/tasks', { method: 'POST', headers: auth(token), body: JSON.stringify(value) }),
  prompts: (token, signal) => json('/api/prompts', { headers: auth(token), signal, cache: 'no-store' }),
  adminPrompts: (token, query = {}) => json(`/api/admin/prompts?${new URLSearchParams(query)}`, { headers: auth(token), cache: 'no-store' }),
  createPrompt: (token, value) => json('/api/admin/prompts', { method: 'POST', headers: auth(token), body: JSON.stringify(value) }),
  updatePrompt: (token, id, value) => json(`/api/admin/prompts/${id}`, { method: 'PUT', headers: auth(token), body: JSON.stringify(value) }),
  deletePrompt: (token, id) => json(`/api/admin/prompts/${id}`, { method: 'DELETE', headers: auth(token) }),
  controlTask: (token, id, action) => json(`/api/admin/tasks/${id}/control`, { method: 'POST', headers: auth(token), body: JSON.stringify({ action }) }),
  adminDeleteTask: (token, id) => json(`/api/admin/tasks/${id}`, { method: 'DELETE', headers: auth(token) }),
  retryTask: (token, id) => json(`/api/tasks/${id}/retry`, { method: 'POST', headers: auth(token) }),
  deleteTask: (token, id) => json(`/api/tasks/${id}`, { method: 'DELETE', headers: auth(token) }),
  users: (token, query = {}) => json(`/api/admin/users?${new URLSearchParams(query)}`, { headers: auth(token) }),
  reports: (token, query = {}) => json(`/api/admin/reports?${new URLSearchParams(query)}`, { headers: auth(token) }),
  adminTasks: (token, query = {}) => json(`/api/admin/tasks?${new URLSearchParams(query)}`, { headers: auth(token) }),
  deleteReport: (token, id) => json(`/api/admin/reports/${id}`, { method: 'DELETE', headers: auth(token) }),
  patchUser: (token, id, value) => json(`/api/admin/users/${id}`, { method: 'PATCH', headers: auth(token), body: JSON.stringify(value) }),
}
