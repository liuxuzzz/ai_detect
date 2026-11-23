// Use the page's hostname by default so a published build works via DNS or IP.
// An explicit base URL also supports APIs deployed on a separate host or path.
export function backendUrl(path, { apiBaseUrl = '', apiPort = '6601', pageUrl = globalThis.location?.href } = {}) {
  let base
  if (apiBaseUrl.trim()) {
    base = new URL(apiBaseUrl.trim().replace(/\/+$/, '') + '/')
  } else {
    base = new URL(pageUrl)
    base.port = apiPort
    base.pathname = '/'
    base.search = ''
    base.hash = ''
  }
  return new URL(path.replace(/^\/+/, ''), base).href
}

const config = import.meta.env ?? {}
const runtime = globalThis.__AI_DETECT_CONFIG__ ?? {}
export const apiUrl = (path) => backendUrl(path, {
  apiBaseUrl: runtime.apiBaseUrl || config.VITE_API_BASE_URL,
  apiPort: runtime.apiPort || config.VITE_API_PORT,
})
