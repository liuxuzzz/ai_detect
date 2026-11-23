<script setup>
import { computed, nextTick, ref, watch } from 'vue'
import { streamTask } from './task-stream'
import LiveThroughputChart from './LiveThroughputChart.vue'

const props = defineProps({ token: String, taskId: Number, formatDate: Function })
const emit = defineEmits(['close', 'changed'])
const task = ref(null)
const connected = ref(false)
const reconnecting = ref(false)
const error = ref('')
const tab = ref('output')
const follow = ref(true)
const output = ref(null)
const preview = ref(false)
const statuses = { queued: '排队中', running: '执行中', paused: '已暂停', stopped: '已停止', disabled: '用户已禁用', completed: '完成', failed: '失败' }
const reasoningLabels = { default: '默认（default）', minimal: '极低（minimal）', low: '低（low）', medium: '中（medium）', high: '高（high）', xhigh: '极高（xhigh）', max: '最大（max）' }
const live = computed(() => task.value?.live || {})
const metrics = computed(() => live.value.metrics || {})
const diagnostics = computed(() => live.value.diagnostics || {})
const number = (value, suffix = '', digits = 0) => value == null ? '未上报' : `${Number(value).toLocaleString('en-US', { maximumFractionDigits: digits })}${suffix}`
const seconds = (value) => value == null ? '—' : `${(value / 1000).toFixed(2)} s`
const metricItems = computed(() => [
  ['首 token 延时', seconds(metrics.value.ttft_ms)],
  ['平均吞吐' + (metrics.value.output_tokens == null ? '（估算）' : ''), number(metrics.value.tokens_per_second ?? live.value.estimated_tokens_per_second, ' token/s')],
  ['总 token', number(metrics.value.total_tokens)],
  ['输入 token', number(metrics.value.input_tokens)],
  ['输出 token' + (metrics.value.output_tokens == null ? '（估算）' : ''), number(metrics.value.output_tokens ?? live.value.estimated_output_tokens)],
  ['平均 RPM', number(metrics.value.rpm, ' req/min', 1)],
  ['平均 TPM', number(metrics.value.tpm, ' token/min')],
  ['首字节延时', seconds(metrics.value.first_byte_ms)],
  ['平均 token 延时', metrics.value.average_latency_ms == null ? '未上报' : `${(metrics.value.average_latency_ms / 1000).toFixed(3)} s/token`],
  ['TCP 连接成功延时', number(metrics.value.tcp_connect_ms ?? diagnostics.value.tcp_connect_ms, ' ms')],
  ['缓存读取', number(metrics.value.cache_read_tokens)],
  ['缓存写入', number(metrics.value.cache_write_tokens)],
  ['缓存命中率', metrics.value.cache_hit_rate == null ? '未上报' : number(metrics.value.cache_hit_rate * 100, '%', 1)],
  ['总耗时', seconds(task.value?.elapsed_ms ?? metrics.value.duration_ms)],
  ['执行次数', number(task.value?.attempt, ' 次')],
])
const previewSource = computed(() => {
  const text = live.value.output || ''
  const fenced = text.match(/```(?:html|svg)\s*\n([\s\S]*?)(?:```|$)/i)
  const html = fenced?.[1] || text.match(/<(?:!doctype|html\b|svg\b)[\s\S]*/i)?.[0]
  return html ? `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'">${html}` : ''
})
watch(() => [props.taskId, props.token], ([id, token], previous, onCleanup) => {
  const controller = new AbortController()
  let retry
  onCleanup(() => { controller.abort(); clearTimeout(retry) })
  task.value = null
  async function connect() {
    let retryable = true
    reconnecting.value = false
    try {
      await streamTask(token, id, controller.signal, (snapshot) => {
        const oldStatus = task.value?.status
        task.value = snapshot
        connected.value = true
        error.value = ''
        if (oldStatus && oldStatus !== snapshot.status) emit('changed')
      })
    } catch (failure) {
      if (!controller.signal.aborted) error.value = failure.message
      retryable = failure.retryable !== false
    } finally {
      connected.value = false
      if (retryable && !controller.signal.aborted && !['completed', 'failed', 'stopped'].includes(task.value?.status)) {
        reconnecting.value = true
        retry = setTimeout(connect, 1500)
      }
    }
  }
  void connect()
}, { immediate: true })
watch(() => [live.value.output, live.value.reasoning, tab.value], async () => {
  if (follow.value) { await nextTick(); if (output.value) output.value.scrollTop = output.value.scrollHeight }
})
</script>

<template>
  <el-dialog :model-value="true" :title="`测试实时详情 · #${taskId}`" width="min(1120px, calc(100vw - 24px))" class="task-monitor" @close="emit('close')">
    <div v-if="error" class="monitor-error" role="alert">{{ error }}<span v-if="reconnecting"> · 正在尝试重新连接</span></div>
    <template v-if="task">
      <div class="panel-toolbar">
        <div><strong>{{ task.model }}</strong><span class="cell-note">{{ task.channel_name || '渠道已删除' }} · {{ task.prompt_name }} · {{ reasoningLabels[task.reasoning_effort] || task.reasoning_effort }}</span></div>
        <span class="status-dot" :class="task.status">{{ statuses[task.status] || task.status }}<small v-if="connected"> · 实时连接</small></span>
      </div>
      <p class="muted monitor-phase">{{ task.error || live.phase || '等待执行' }} · {{ task.started_at ? formatDate(task.started_at) : `计划 ${formatDate(task.scheduled_for)}` }}</p>
      <div class="detail-metrics"><div v-for="[label, value] in metricItems" :key="label"><span>{{ label }}</span><strong>{{ value }}</strong></div></div>
      <LiveThroughputChart :samples="live.samples || []" />
      <div class="panel-toolbar monitor-tabs">
        <div class="segmented" aria-label="执行详情内容">
          <button :aria-pressed="tab === 'output'" type="button" @click="tab = 'output'">模型输出</button>
          <button :aria-pressed="tab === 'reasoning'" type="button" @click="tab = 'reasoning'">推理内容</button>
          <button :aria-pressed="tab === 'diagnostics'" type="button" @click="tab = 'diagnostics'">诊断数据</button>
        </div>
        <label v-if="tab !== 'diagnostics'"><input v-model="follow" type="checkbox" />跟随输出</label>
      </div>
      <template v-if="tab === 'diagnostics'">
        <dl class="request-diagnostics">
          <dt>请求</dt><dd>{{ diagnostics.method || 'POST' }} {{ diagnostics.endpoint || '等待连接' }}</dd>
          <dt>响应</dt><dd>{{ diagnostics.status || '等待响应' }} · {{ diagnostics.content_type || '—' }}</dd>
          <dt>接收数据</dt><dd>{{ number(diagnostics.received_bytes, ' bytes') }} · {{ number(diagnostics.chunks, ' 个数据块') }}</dd>
        </dl>
        <details><summary>最近 40 条流式事件</summary><pre class="live-output">{{ JSON.stringify(live.events || [], null, 2) }}</pre></details>
      </template>
      <template v-else>
        <div v-if="tab === 'output' && previewSource" class="preview-toolbar"><label><input v-model="preview" type="checkbox" />预览 HTML / SVG</label></div>
        <iframe v-if="tab === 'output' && preview && previewSource" class="model-preview" title="模型输出预览" sandbox="" :srcdoc="previewSource" />
        <pre ref="output" class="live-output" :aria-label="tab === 'reasoning' ? '实时推理内容' : '实时模型输出'">{{ (tab === 'reasoning' ? live.reasoning : live.output) || '尚未收到内容' }}</pre>
      </template>
      <a v-if="task.report_slug" class="button outline" :href="`/r/${task.report_slug}`" target="_blank" rel="noopener">查看完整报告 ↗</a>
    </template>
    <div v-else-if="!error" class="empty-cell">正在连接实时测试…</div>
  </el-dialog>
</template>
