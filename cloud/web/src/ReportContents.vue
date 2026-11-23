<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import ReportChart from './ReportChart.vue'
import { modelPreview, reasoningLabel } from './report-data'

const props = defineProps({ data: { type: Object, required: true } })
const frame = ref(null)
const height = ref(540)
const preview = computed(() => modelPreview(props.data))
const source = computed(() => {
  const policy = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'">`
  const style = '<style>html,body{height:auto!important;min-height:0!important;max-height:none!important;overflow:visible!important}</style>'
  const measure = `<script>new ResizeObserver(()=>{const body=document.body;const box=body.getBoundingClientRect();parent.postMessage({type:'report-preview-height',height:Math.ceil(Math.max(body.scrollHeight,body.offsetHeight,box.height)+Math.max(0,box.top))},'*')}).observe(document.body);<\/script>`
  return `<!doctype html><html><head>${policy}${style}</head><body>${preview.value}${measure}</body></html>`
})
function resize(event) {
  if (event.source !== frame.value?.contentWindow || event.data?.type !== 'report-preview-height') return
  if (Number.isFinite(event.data.height)) height.value = Math.max(200, Math.min(20000, event.data.height))
}
onMounted(() => window.addEventListener('message', resize))
onBeforeUnmount(() => window.removeEventListener('message', resize))
</script>

<template>
  <div class="report-contents">
    <p v-if="data.source === 'legacy'" class="muted">此报告已从旧版页面恢复为数据。旧版未保存的提示词、重试和活动记录可能为空。</p>
    <p v-if="data.error" class="monitor-error" role="alert">测试失败：{{ data.error }}</p>
    <p class="muted">{{ data.upstream_name }} · {{ reasoningLabel(data.reasoning_effort) }} · {{ data.detection_mode === 'agent' ? 'Agent 测试' : '单次测试' }}</p>
    <details v-if="data.prompt"><summary>测试提示词</summary><pre class="live-output">{{ data.prompt }}</pre></details>
    <ReportChart :samples="data.samples || []" />
    <section><h2 class="panel-heading">模型输出</h2>
      <iframe v-if="preview" ref="frame" title="模型输出预览" class="model-preview" sandbox="allow-scripts" :srcdoc="source" :style="{ height: `${height}px` }" />
      <details v-if="preview"><summary>原始输出</summary><pre class="live-output">{{ data.output || preview }}</pre></details>
      <pre v-else-if="data.output" class="live-output">{{ data.output }}</pre>
      <p v-else-if="!preview" class="muted">未保存模型输出。</p>
    </section>
    <details v-for="(activity, index) in (data.activities || []).filter(a => a.kind !== 'html_artifact')" :key="index">
      <summary>{{ activity.kind === 'thinking' ? '推理内容' : activity.kind === 'tool_result' ? '工具结果' : '模型活动' }}{{ activity.name ? ` · ${activity.name}` : '' }}</summary>
      <pre class="live-output">{{ activity.content }}</pre>
    </details>
    <section v-if="data.retries?.length"><h2 class="panel-heading">故障 / 重试</h2><p v-for="(retry, index) in data.retries" :key="index">第 {{ retry.attempt }} 次 · {{ retry.at }} · {{ retry.reason }}</p></section>
  </div>
</template>
