// Pages, JSON requests, uploads and SSE share the browser's origin.
export function backendUrl(path, { pageUrl = globalThis.location?.href } = {}) {
  return new URL(path.replace(/^\/+/, ''), new URL('/', pageUrl)).href
}

export const apiUrl = (path) => backendUrl(path)
