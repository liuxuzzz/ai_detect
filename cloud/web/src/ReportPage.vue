<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { api } from './api'
import { formatDate, reportThroughput } from './report-format'
import ReportMetrics from './ReportMetrics.vue'
import ReportContents from './ReportContents.vue'
import ReportFeedback from './ReportFeedback.vue'
import ReportImageShare from './ReportImageShare.vue'

const props = defineProps({ kind: String, identifier: String })
const report = ref(null)
const reportElement = ref(null)
const loading = ref(true)
const error = ref('')
const token = ref(localStorage.getItem('aijiance_token') || '')
const request = new AbortController()

// This controls the shared page's presentation; expiry is enforced by the API.
function checkEmbedding(sharing) {
  if (window.self === window.top) return
  let parentOrigin = ''
  try { parentOrigin = new URL(document.referrer).origin } catch { /* No referrer. */ }
  if (parentOrigin === location.origin) return
  if (!sharing) throw new Error('请在新窗口打开此报告')
  if (sharing.allow_any_iframe) return
  try {
    const allowed = new URL(sharing.allowed_domain).origin
    if (allowed === parentOrigin) return
  } catch { /* No valid embedding origin configured. */ }
  throw new Error('此分享不允许在当前网站内嵌，请在新窗口打开')
}
onMounted(async () => {
  try {
    if (token.value) {
      try { await api.me(token.value) } catch { token.value = '' }
    }
    const result = props.kind === 'share'
      ? await api.sharedReport(props.identifier, token.value, request.signal)
      : await api.report(props.identifier, token.value, request.signal)
    checkEmbedding(result.sharing)
    if (!request.signal.aborted) {
      report.value = result.report || result
      document.title = `${report.value.model} · AI质量检测报告`
    }
  } catch (failure) { if (!request.signal.aborted) error.value = failure.message }
  finally { if (!request.signal.aborted) loading.value = false }
})
onBeforeUnmount(() => request.abort())
function rated(result) {
  report.value = { ...report.value, average_score: result.average_score, rating_count: result.rating_count, my_score: result.score }
}
function login() { location.assign('/') }
</script>

<template>
  <div class="app-shell">
    <header class="app-header"><div class="header-inner"><a class="brand" href="/"><span class="brand-mark">AI</span>AI质量检测</a><a class="button outline" href="/">返回公开排行</a></div></header>
    <main class="page report-page" :aria-busy="loading">
      <p v-if="loading" class="empty-cell" role="status">正在加载报告数据…</p>
      <p v-else-if="error" class="monitor-error" role="alert">{{ error }}</p>
      <article v-else-if="report" ref="reportElement">
        <header class="report-detail-head">
          <div><p class="eyebrow">{{ report.api_domain }}</p><h1>{{ report.model }}</h1><p>{{ report.prompt_name || '测试报告' }} · {{ formatDate(report.created_at) }}</p></div>
          <ReportImageShare :report-element="reportElement" :model="report.model" />
        </header>
        <ReportMetrics :report="report" />
        <ReportContents :data="report.data" :average="reportThroughput(report)" />
        <ReportFeedback :report="report" :token="token" @rated="rated" @login="login" />
      </article>
    </main>
  </div>
</template>

<style src="./app.css"></style>
