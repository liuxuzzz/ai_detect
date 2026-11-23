export const reasoningLabel = (value = 'default') => ({
  unknown: '推理强度未记录', default: '默认（default）', minimal: '极低（minimal）', low: '低（low）',
  medium: '中（medium）', high: '高（high）', xhigh: '极高（xhigh）', max: '最大（max）',
})[value] || value

export function modelPreview(data = {}) {
  const artifact = (data.activities || []).filter((item) => item.kind === 'html_artifact' && item.content?.trim()).at(-1)
  if (artifact) return artifact.content
  const output = data.output || ''
  const fenced = output.match(/```(?:html|svg)\s*\r?\n([\s\S]*?)(?:```|$)/i)
  if (fenced) return fenced[1]
  const start = output.search(/<(?:!doctype\s+html|html\b|svg\b|div\b)/i)
  if (start < 0) return ''
  const source = output.slice(start)
  const closing = source.match(/<\/(?:html|svg)>/i)
  return closing ? source.slice(0, closing.index + closing[0].length) : source
}

export function samplesInRange(samples, start, span) {
  return samples.filter((point) => Number.isFinite(point.seconds) && Number.isFinite(point.tps)
    && point.seconds >= start && point.seconds <= start + span && point.tps >= 0)
}
