export function formatMetric(value, suffix = '', decimals) {
  if (value == null || value === '' || !Number.isFinite(Number(value))) return '-'
  const number = Number(value)
  const digits = decimals ?? (Number.isInteger(number) ? 0 : 1)
  return `${number.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })}${suffix}`
}

const scaledMetric = (value, scale, suffix, decimals) => formatMetric(value == null ? null : value * scale, suffix, decimals)
export const formatDuration = (value) => scaledMetric(value, 0.001, ' s', 2)
export const formatTokens = (value) => formatMetric(value, ' token', 0)
export const formatThroughput = (value) => formatMetric(value, ' token/s', 0)

export function reportThroughput(report = {}) {
  const value = report.metrics?.tokens_per_second ?? report.tokens_per_second
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
}

const dateFormat = new Intl.DateTimeFormat('sv-SE', {
  timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
})
export function formatDate(value) {
  if (!value) return '-'
  const date = new Date(value)
  return Number.isFinite(date.getTime()) ? dateFormat.format(date) : '-'
}

export function metricItems(report = {}) {
  const metrics = { ...report, ...report.metrics }
  return [
    ['评分', metrics.rating_count ? `${formatMetric(metrics.average_score, '', 1)} / 5` : '未评分'],
    ['首 token 延时', formatDuration(metrics.ttft_ms)],
    ['平均吞吐', formatThroughput(reportThroughput(report))],
    ['总 token', formatTokens(metrics.total_tokens)],
    ['输入 token', formatTokens(metrics.input_tokens)],
    ['输出 token', formatTokens(metrics.output_tokens)],
    ['平均 RPM', formatMetric(metrics.rpm, ' req/min', 1)],
    ['平均 TPM', formatMetric(metrics.tpm, ' token/min', 0)],
    ['首字节延时', formatDuration(metrics.first_byte_ms > 0 ? metrics.first_byte_ms : null)],
    ['平均 token 延时', scaledMetric(metrics.average_latency_ms, 0.001, ' s/token', 2)],
    ['TCP 连接成功延时', formatMetric(metrics.tcp_connect_ms, ' ms', 0)],
    ['缓存读取', metrics.cache_read_tokens == null ? '未上报' : formatTokens(metrics.cache_read_tokens)],
    ['缓存写入', metrics.cache_write_tokens == null ? '未上报' : formatTokens(metrics.cache_write_tokens)],
    ['缓存命中率', scaledMetric(metrics.cache_hit_rate, 100, '%', 1)],
    ['总耗时', formatDuration(metrics.duration_ms)],
    ['故障/重试次数', formatMetric(metrics.retry_count, ' 次', 0)],
  ]
}
