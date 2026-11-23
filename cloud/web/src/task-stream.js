import { apiUrl } from './api-url'

export async function streamTask(token, id, signal, onSnapshot) {
  const response = await fetch(apiUrl(`/api/tasks/${id}/events`), {
    headers: { Authorization: `Bearer ${token}`, Accept: 'text/event-stream' },
    signal,
    cache: 'no-store',
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw Object.assign(new Error(body.error || `连接失败 (${response.status})`), {
      retryable: ![401, 403, 404].includes(response.status),
    })
  }
  if (!response.body) throw new Error('浏览器不支持流式响应')
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n')
      let boundary
      while ((boundary = buffer.indexOf('\n\n')) >= 0) {
        const event = buffer.slice(0, boundary)
        buffer = buffer.slice(boundary + 2)
        const data = event.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trimStart()).join('\n')
        if (event.includes('event: unavailable')) throw Object.assign(new Error(data), { retryable: false })
        if (data && event.includes('event: snapshot')) onSnapshot(JSON.parse(data))
      }
    }
  } finally {
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}
