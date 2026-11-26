<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { ArrowDown, ArrowLeft, ArrowRight, Plus, Refresh, Search } from '@element-plus/icons-vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from './api'
import ProfileCenter from './ProfileCenter.vue'
import ChannelEditor from './ChannelEditor.vue'
import TaskEditor from './TaskEditor.vue'
import PromptManager from './PromptManager.vue'
import TaskActions from './TaskActions.vue'
import TaskMonitor from './TaskMonitor.vue'
import ReportMetrics from './ReportMetrics.vue'
import ReportContents from './ReportContents.vue'
import ReportImageShare from './ReportImageShare.vue'
import ReportFeedback from './ReportFeedback.vue'
import SiteSettings from './SiteSettings.vue'
import AuthDialog from './AuthDialog.vue'
import { formatMetric, formatDuration, formatThroughput, formatDate, reportThroughput } from './report-format'

const periods = [
  { key: 'latest', label: '最新测试' },
  { key: 'today', label: '今日排行' },
  { key: 'week', label: '本周排行' },
  { key: 'month', label: '本月排行' },
]
const adminPanels = [
  { key: 'users', label: '用户管理' },
  { key: 'reports', label: '报告管理' },
  { key: 'tasks', label: '任务管理' },
  { key: 'prompts', label: '提示词管理' },
  { key: 'settings', label: '站点设置' },
]
const taskModes = { immediate: '立即执行', delayed: '延时执行', scheduled: '定时执行' }
const statusLabels = { success: '成功', completed: '完成', queued: '排队中', running: '执行中', failed: '失败', paused: '已暂停', stopped: '已停止', disabled: '用户已禁用' }
const token = ref(localStorage.getItem('aijiance_token') || '')
const user = ref(null)
const view = ref('public')
const workspaceSection = ref('tests')
const adminSection = ref('users')
const testSection = ref('results')
const publicPeriod = ref('latest')
const publicSearch = ref('')
const searchTerm = ref('')
const publicResults = reactive({ items: [], page: 0, more: true, loading: false, request: null })
const publicFacets = reactive([
  { key: 'api_domain', label: '厂商', selected: '', open: false, items: [], page: 0, more: true, loading: false, request: null },
  { key: 'model', label: '模型', selected: '', open: false, items: [], page: 0, more: true, loading: false, request: null },
])
const selectedReport = ref(null)
const reportDetails = ref(null)
const reportElement = ref(null)
const detailLoading = ref(false)
const detailError = ref('')
const detailDialog = ref(false)
const authDialog = ref(false)
const registrationEnabled = ref(null)
const workspaceLoading = ref(false)
const dashboard = ref({ summary: {}, items: [], total: 0, page: 0, limit: 50 })
const channels = ref([])
const tasks = ref([])
const retryingTasks = reactive(new Set())
const deletingReports = reactive(new Set())
const deletingTasks = reactive(new Set())
const taskFormVisible = ref(false)
const monitoredTask = ref(null)
const channelEditor = ref(null)
const adminData = ref({ users: { items: [], total: 0, page: 0, limit: 12 }, reports: { items: [], total: 0, page: 0, limit: 12 }, tasks: { items: [], total: 0, page: 0, limit: 12 }, prompts: { items: [], total: 0, page: 0, limit: 12 } })
const adminLoading = ref(false)

const loggedIn = computed(() => Boolean(user.value))
const isAdmin = computed(() => Boolean(user.value?.is_admin))

function channelModels(channel) {
  return [...new Set([channel?.model, ...(channel?.models || [])].filter(Boolean))]
}
const publicSelection = computed(() => Object.fromEntries(publicFacets.map(({ key, selected }) => [key, selected])))
const hasPublicFilter = computed(() => Boolean(publicSearch.value || publicFacets.some(({ selected }) => selected)))
const adminCurrent = computed(() => adminData.value[adminSection.value])
const adminPageCount = computed(() => Math.max(1, Math.ceil(adminCurrent.value.total / adminCurrent.value.limit)))

function providerInitial(item) { return (item?.name || item?.api_domain || '未').slice(0, 1).toUpperCase() }
function clearPublicFilters() { publicSearch.value = ''; searchTerm.value = ''; publicFacets.forEach((facet) => { facet.selected = '' }) }
function showPublic() { view.value = 'public'; window.scrollTo(0, 0) }

function resetPage(state) {
  state.request?.abort()
  Object.assign(state, { items: [], page: 0, more: true, loading: false, request: null })
}
async function appendPublicPage(state) {
  if (state.loading || !state.more) return
  const request = new AbortController()
  const facet = state.key || ''
  const query = { period: publicPeriod.value, search: searchTerm.value, ...publicSelection.value, facet, page: state.page }
  if (facet) delete query[facet]
  state.request = request
  state.loading = true
  try {
    const result = await api.publicRankings(query, request.signal)
    if (state.request !== request) return
    const field = facet ? 'name' : 'id'
    const seen = new Set(state.items.map((item) => item[field]))
    state.items.push(...result.items.filter((item) => !seen.has(item[field])))
    state.more = result.has_more
    state.page++
  } catch (error) {
    if (!request.signal.aborted) ElMessage.error(error.message)
  } finally {
    if (state.request === request) Object.assign(state, { request: null, loading: false })
  }
}
function reloadPublicPage(state) { resetPage(state); return appendPublicPage(state) }
function loadPublic() { return reloadPublicPage(publicResults) }
function refreshPublic() {
  return Promise.all([loadPublic(), ...publicFacets.filter(({ open }) => open).map(reloadPublicPage)])
}
function toggleFacet(facet) {
  facet.open = !facet.open
  if (facet.open) reloadPublicPage(facet)
  else resetPage(facet)
}
function chooseTag(facet, name) { facet.selected = facet.selected === name ? '' : name }

watch(publicSearch, (value, previous, onCleanup) => {
  const timer = setTimeout(() => { searchTerm.value = value.trim() }, 250)
  onCleanup(() => clearTimeout(timer))
})
watch([publicPeriod, searchTerm, publicSelection], loadPublic)
for (const facet of publicFacets) {
  const other = publicFacets.find(({ key }) => key !== facet.key)
  watch([publicPeriod, searchTerm, () => other.selected], () => {
    if (facet.open) reloadPublicPage(facet)
  })
}
function openReport(report) {
  reportDetails.value = null
  detailError.value = ''
  selectedReport.value = report
  detailDialog.value = true
}
watch([detailDialog, () => selectedReport.value?.id, () => user.value?.id], async ([open, id, userId], previous, onCleanup) => {
  if (!open || !id) return
  const request = new AbortController()
  onCleanup(() => request.abort())
  detailLoading.value = true
  detailError.value = ''
  try {
    const result = await api.reportDetails(id, userId ? token.value : '', request.signal)
    if (!request.signal.aborted) reportDetails.value = result
  } catch (error) {
    if (!request.signal.aborted) detailError.value = error.message
  } finally {
    if (!request.signal.aborted) detailLoading.value = false
  }
})
async function reportRated(result) {
  reportDetails.value = { ...reportDetails.value, average_score: result.average_score, rating_count: result.rating_count, my_score: result.score }
  await loadPublic()
}

function openAuth() { authDialog.value = true }
function updateSession(session) {
  token.value = session.token
  user.value = session.user
  localStorage.setItem('aijiance_token', session.token)
}
function signedIn(session) {
  updateSession(session)
  authDialog.value = false
  ElMessage.success('登录成功')
}
async function restoreSession() { if (token.value) { try { user.value = await api.me(token.value) } catch { logout(false) } } }
function logout(showMessage = true) { token.value = ''; user.value = null; localStorage.removeItem('aijiance_token'); view.value = 'public'; if (showMessage) ElMessage.success('已退出登录') }
async function enterWorkspace(section = 'tests') {
  if (!loggedIn.value) { openAuth(); return }
  view.value = 'workspace'
  workspaceSection.value = section
  window.scrollTo(0, 0)
  if (section === 'admin') await loadAdmin()
  else if (section !== 'profile') await loadWorkspace()
}
async function loadWorkspace() {
  workspaceLoading.value = true
  try {
    if (workspaceSection.value === 'channels') {
      channels.value = await api.channels(token.value)
      return
    }
    const [nextDashboard, nextChannels, nextTasks] = await Promise.all([api.dashboard(token.value, { page: 0, limit: 50, sort: 'created' }), api.channels(token.value), api.tasks(token.value)])
    dashboard.value = nextDashboard
    channels.value = nextChannels
    tasks.value = nextTasks
  } catch (error) { ElMessage.error(error.message) } finally { workspaceLoading.value = false }
}
watch([view, workspaceSection, testSection, token], ([screen, section, tab, session], previous, onCleanup) => {
  if (!session || screen !== 'workspace' || section !== 'tests') return
  if (tab === 'results') {
    if (previous[2] === 'queue') void loadWorkspace()
    return
  }
  let active = true
  let refreshing = false
  const timer = window.setInterval(async () => {
    if (refreshing || workspaceLoading.value) return
    refreshing = true
    try {
      const nextTasks = await api.tasks(session)
      if (active) tasks.value = nextTasks
    } catch {
    } finally {
      refreshing = false
    }
  }, 3000)
  onCleanup(() => { active = false; window.clearInterval(timer) })
})
function openTaskForm() {
  taskFormVisible.value = true
}
async function taskQueued() {
  taskFormVisible.value = false
  testSection.value = 'queue'
  await loadWorkspace()
}
async function retryTask(task) {
  if (retryingTasks.has(task.id) || deletingTasks.has(task.id)) return
  retryingTasks.add(task.id)
  try {
    const retried = await api.retryTask(token.value, task.id)
    tasks.value = tasks.value.map((item) => item.id === task.id ? { ...item, ...retried } : item)
    ElMessage.success('任务已重新入队，将立即重试')
    await loadWorkspace()
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    retryingTasks.delete(task.id)
  }
}
async function removeMyReport(report) {
  if (deletingReports.has(report.id)) return
  deletingReports.add(report.id)
  try {
    const confirmed = await ElMessageBox.confirm(
      `确认删除“${report.model}”的测试结果吗？删除后，公开排行、报告及分享链接将不可访问。`,
      '删除测试结果',
      { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' },
    ).then(() => true, () => false)
    if (!confirmed) return
    await api.deleteMyReport(token.value, report.id)
    if (selectedReport.value?.id === report.id) detailDialog.value = false
    ElMessage.success('测试结果已删除')
    await Promise.all([loadWorkspace(), refreshPublic()])
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    deletingReports.delete(report.id)
  }
}
async function removeTask(task) {
  if (deletingTasks.has(task.id) || retryingTasks.has(task.id) || task.status === 'running') return
  deletingTasks.add(task.id)
  try {
    const description = task.status === 'queued'
      ? '删除后，此任务将不再执行。'
      : '已生成的报告可在「测试结果」中管理。'
    const confirmed = await ElMessageBox.confirm(
      `确认删除任务 #${task.id} 的队列记录吗？${description}`,
      '删除任务',
      { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' },
    ).then(() => true, () => false)
    if (!confirmed) return
    await api.deleteTask(token.value, task.id)
    tasks.value = tasks.value.filter((item) => item.id !== task.id)
    ElMessage.success('任务已删除')
    await loadWorkspace()
  } catch (error) {
    ElMessage.error(error.message)
    await loadWorkspace()
  } finally {
    deletingTasks.delete(task.id)
  }
}
function openChannel(channel = null) {
  channelEditor.value = { channel }
}
async function channelSaved() {
  channelEditor.value = null
  await loadWorkspace()
}
async function testChannel(channel) {
  try {
    const result = await api.testChannel(token.value, channel.id)
    const message = 'HTTP ' + result.status + ' · ' + result.latency_ms + ' ms'
    if (result.ok) ElMessage.success('连接成功 · ' + message)
    else ElMessage.error('连接失败 · ' + message)
  } catch (error) { ElMessage.error(error.message) }
}
async function removeChannel(channel) { try { await ElMessageBox.confirm(`确认删除渠道“${channel.name}”吗？`, '删除渠道', { type: 'warning' }); await api.deleteChannel(token.value, channel.id); await loadWorkspace(); ElMessage.success('渠道已删除') } catch (error) { if (error !== 'cancel') ElMessage.error(error.message) } }
async function loadAdmin() {
  const section = adminSection.value
  if (section === 'settings') return
  adminLoading.value = true
  try {
    const { page, limit } = adminData.value[section]
    const fetchPage = { users: api.users, reports: api.reports, tasks: api.adminTasks, prompts: api.adminPrompts }[section]
    adminData.value[section] = await fetchPage(token.value, { page, limit })
  } catch (error) { ElMessage.error(error.message) } finally { if (section === adminSection.value) adminLoading.value = false }
}
async function switchAdmin(section) {
  adminSection.value = section
  if (section !== 'settings') { adminData.value[section].page = 0; await loadAdmin() }
}
async function adminPage(page) { adminData.value[adminSection.value].page = page; await loadAdmin() }
async function toggleUser(item, field) {
  try {
    if (field === 'disabled' && !item.disabled) {
      const confirmed = await ElMessageBox.confirm(
        '禁用后会中断并禁用该用户的活动任务，在首页隐藏其报告。重新启用后，任务需手动继续。',
        `禁用 ${item.email}`, { type: 'warning', confirmButtonText: '禁用用户', cancelButtonText: '取消' },
      ).then(() => true, () => false)
      if (!confirmed) return
    }
    await api.patchUser(token.value, item.id, { [field]: !item[field] })
    if (item.id === user.value?.id && field === 'disabled' && !item.disabled) { logout(false); return }
    await Promise.all([loadAdmin(), refreshPublic()])
    ElMessage.success('用户状态已更新')
  } catch (error) { ElMessage.error(error.message) }
}
function refreshTaskViews() {
  return workspaceSection.value === 'admin' ? loadAdmin() : loadWorkspace()
}
watch([view, workspaceSection, adminSection, token], ([screen, section, panel, session], previous, onCleanup) => {
  if (!session || screen !== 'workspace' || section !== 'admin' || panel !== 'tasks') return
  let active = true
  let refreshing = false
  const timer = setInterval(async () => {
    if (refreshing || adminLoading.value) return
    refreshing = true
    const { page, limit } = adminData.value.tasks
    try {
      const result = await api.adminTasks(session, { page, limit })
      if (active && adminData.value.tasks.page === page) adminData.value.tasks = result
    } catch {} finally { refreshing = false }
  }, 3000)
  onCleanup(() => { active = false; clearInterval(timer) })
})
async function deleteReport(item) { try { await ElMessageBox.confirm('确认隐藏这条测试报告吗？', '报告管理', { type: 'warning' }); await api.deleteReport(token.value, item.id); await loadAdmin(); await refreshPublic(); ElMessage.success('报告已隐藏') } catch (error) { if (error !== 'cancel') ElMessage.error(error.message) } }

onMounted(async () => { await Promise.all([loadPublic(), restoreSession()]) })
</script>

<template>
  <div class="app-shell">
    <header class="app-header">
      <div class="header-inner">
        <button class="brand" type="button" @click="showPublic"><span class="brand-mark">AI</span>AI质量检测</button>
        <nav class="top-nav" aria-label="主导航">
          <button :aria-current="view === 'public' ? 'page' : undefined" type="button" @click="showPublic">公开排行</button>
          <button v-if="loggedIn" :aria-current="view === 'workspace' && workspaceSection === 'tests' ? 'page' : undefined" type="button" @click="enterWorkspace('tests')">我的测试</button>
          <button v-if="loggedIn" :aria-current="view === 'workspace' && workspaceSection === 'channels' ? 'page' : undefined" type="button" @click="enterWorkspace('channels')">渠道管理</button>
          <button v-if="loggedIn" :aria-current="view === 'workspace' && workspaceSection === 'profile' ? 'page' : undefined" type="button" @click="enterWorkspace('profile')">个人中心</button>
          <button v-if="isAdmin" :aria-current="view === 'workspace' && workspaceSection === 'admin' ? 'page' : undefined" type="button" @click="enterWorkspace('admin')">管理中心</button>
        </nav>
        <div class="header-actions">
          <span v-if="loggedIn" class="account-label" :title="user.email">{{ user.email }}</span>
          <button v-if="loggedIn" class="button outline" type="button" @click="logout()">退出</button>
          <button v-else class="button primary" type="button" @click="openAuth()">登录 / 注册</button>
        </div>
      </div>
    </header>

    <main v-if="view === 'public'" class="page" aria-label="公开排行">
      <div class="panel-toolbar">
        <div class="segmented" role="group" aria-label="榜单周期">
          <button v-for="period in periods" :key="period.key" :aria-pressed="publicPeriod === period.key" type="button" @click="publicPeriod = period.key">{{ period.label }}</button>
        </div>
        <div class="toolbar-actions">
          <button class="button outline icon-button" type="button" aria-label="刷新榜单" title="刷新榜单" :disabled="publicResults.loading" @click="refreshPublic"><Refresh aria-hidden="true" /></button>
        </div>
      </div>
      <div class="filter-bar">
        <label class="search-control"><Search aria-hidden="true" /><input v-model="publicSearch" maxlength="200" aria-label="搜索厂商、模型或测试名称" type="search" placeholder="搜索厂商、模型或测试名称" /></label>
        <button v-for="facet in publicFacets" :key="facet.key" class="button outline facet-toggle" :class="{ active: facet.selected }" type="button"
          :aria-expanded="facet.open" :aria-controls="`facet-${facet.key}`" :title="facet.selected || undefined" @click="toggleFacet(facet)">
          <span>{{ facet.label }}<template v-if="facet.selected">：{{ facet.selected }}</template></span><ArrowDown aria-hidden="true" />
        </button>
        <button v-if="hasPublicFilter" class="text-button" type="button" @click="clearPublicFilters">清除筛选</button>
      </div>
      <section v-for="facet in publicFacets" v-show="facet.open" :id="`facet-${facet.key}`" :key="facet.key" class="facet-panel" :aria-label="`${facet.label}标签`" :aria-busy="facet.loading">
        <div class="facet-tags">
          <button v-if="facet.selected" class="text-button" type="button" @click="chooseTag(facet, facet.selected)">全部{{ facet.label }}</button>
          <button v-for="tag in facet.items" :key="tag.name" class="facet-tag" type="button" :aria-pressed="facet.selected === tag.name" @click="chooseTag(facet, tag.name)">{{ tag.name }}<span>({{ tag.count }})</span></button>
          <span v-if="!facet.items.length && !facet.loading && !facet.more" class="muted">没有匹配的{{ facet.label }}</span>
          <button v-if="facet.more" class="button outline facet-more" type="button" :disabled="facet.loading" @click="appendPublicPage(facet)">{{ facet.loading ? '加载中…' : '加载更多' }}</button>
        </div>
      </section>
      <div class="table-frame" :aria-busy="publicResults.loading">
        <table class="data-table report-table" aria-label="公开测试结果">
          <thead><tr><th class="position-column">{{ publicPeriod === 'latest' ? '序号' : '排名' }}</th><th class="report-column">模型 / 厂商</th><th>评分</th><th>首 token</th><th>总 token</th><th>平均吞吐</th><th>总耗时</th><th>完成时间</th></tr></thead>
          <tbody>
            <tr v-for="(report, index) in publicResults.items" :key="report.id" class="report-row clickable-row" @click="openReport(report)">
              <td class="position-cell"><span class="rank-number" :class="{ leading: publicPeriod !== 'latest' && index < 3 }">{{ String(index + 1).padStart(2, '0') }}</span></td>
              <th scope="row" class="report-cell">
                <button class="record-link" type="button" @click.stop="openReport(report)">{{ report.model || '未命名模型' }}</button>
                <span class="cell-note">{{ report.api_domain }}</span>
              </th>
              <td data-label="评分"><span v-if="report.rating_count" class="score-chip">{{ Number(report.average_score).toFixed(1) }} <small>({{ report.rating_count }})</small></span><span v-else class="muted">未评分</span></td>
              <td data-label="首 token">{{ formatDuration(report.ttft_ms) }}</td>
              <td data-label="总 token">{{ formatMetric(report.total_tokens, '', 0) }}</td>
              <td data-label="平均吞吐">{{ formatThroughput(report.tokens_per_second) }}</td>
              <td data-label="总耗时">{{ formatDuration(report.duration_ms) }}</td>
              <td data-label="完成时间" class="muted completion-cell"><time :datetime="report.created_at">{{ formatDate(report.created_at) }}</time></td>
            </tr>
          </tbody>
        </table>
        <div v-if="!publicResults.items.length" class="empty-cell">{{ publicResults.loading ? '正在加载…' : publicResults.more ? '测试结果尚未加载' : hasPublicFilter ? '没有匹配的测试结果' : '暂无公开测试结果' }}</div>
      </div>
      <div v-if="publicResults.more && (publicResults.items.length || !publicResults.loading)" class="report-more">
        <button class="button outline" type="button" :disabled="publicResults.loading" @click="appendPublicPage(publicResults)">{{ publicResults.loading ? '正在加载…' : '更多' }}</button>
      </div>
    </main>

    <main v-else class="page">
      <section v-if="workspaceSection === 'tests'" aria-label="我的测试">
        <div class="panel-toolbar">
          <div class="segmented" role="group" aria-label="个人测试面板">
            <button :aria-pressed="testSection === 'results'" type="button" @click="testSection = 'results'">测试结果 <span>{{ dashboard.total }}</span></button>
            <button :aria-pressed="testSection === 'queue'" type="button" @click="testSection = 'queue'">任务队列 <span>{{ tasks.length }}</span></button>
          </div>
          <div class="toolbar-actions">
            <button class="button outline icon-button" type="button" aria-label="刷新测试" title="刷新测试" :disabled="workspaceLoading" @click="loadWorkspace"><Refresh aria-hidden="true" /></button>
            <button class="button primary" type="button" @click="openTaskForm"><Plus aria-hidden="true" />添加测试</button>
          </div>
        </div>
        <div v-loading="workspaceLoading" class="table-frame" :aria-busy="workspaceLoading">
          <template v-if="testSection === 'results'">
            <table class="data-table work-table" aria-label="测试结果">
              <thead><tr><th>模型 / 厂商</th><th>状态</th><th>首 token</th><th>总 token</th><th>平均吞吐</th><th>总耗时</th><th>时间</th><th>操作</th></tr></thead>
              <tbody><tr v-for="item in dashboard.items" :key="item.id">
                <th scope="row"><button type="button" class="text-button" @click="openReport(item)">{{ item.model }}</button><span class="cell-note">{{ item.api_domain }}</span></th>
                <td data-label="状态"><span class="status-dot" :class="item.status">{{ statusLabels[item.status] || item.status }}</span></td>
                <td data-label="首 token">{{ formatDuration(item.ttft_ms) }}</td><td data-label="总 token">{{ formatMetric(item.total_tokens, '', 0) }}</td>
                <td data-label="平均吞吐">{{ formatThroughput(item.tokens_per_second) }}</td><td data-label="总耗时">{{ formatDuration(item.duration_ms) }}</td>
                <td data-label="时间" class="muted">{{ formatDate(item.created_at) }}</td>
                <td data-label="操作" class="row-actions">
                  <a class="small-button" :href="`/r/${item.slug}`" target="_blank" rel="noopener">查看报告 ↗</a>
                  <button class="small-button danger" type="button" :disabled="deletingReports.has(item.id)" @click="removeMyReport(item)">删除</button>
                </td>
              </tr></tbody>
            </table>
            <div v-if="!dashboard.items.length" class="empty-cell">{{ workspaceLoading ? '正在加载…' : '暂无测试结果' }}</div>
          </template>
          <template v-else>
            <table class="data-table work-table" aria-label="任务队列">
              <thead><tr><th>任务 / 模型</th><th>执行方式</th><th>状态</th><th>计划时间</th><th>结果</th><th>操作</th></tr></thead>
              <tbody><tr v-for="task in tasks" :key="task.id">
                <th scope="row"><strong>{{ task.model || '未选择模型' }}</strong><span class="cell-note">#{{ task.id }}<template v-if="task.prompt_name"> · {{ task.prompt_name }}</template></span></th>
                <td data-label="执行方式">{{ taskModes[task.execution_mode] || task.execution_mode }}</td>
                <td data-label="状态"><span class="status-dot" :class="task.status">{{ statusLabels[task.status] || task.status }}</span></td>
                <td data-label="计划时间">{{ formatDate(task.scheduled_for) }}</td>
                <td data-label="结果" class="wrap-cell"><a v-if="task.report_slug" class="small-button" :href="`/r/${task.report_slug}`" target="_blank" rel="noopener">查看报告 ↗</a><template v-else>{{ task.error || '—' }}</template></td>
                <td data-label="操作" class="row-actions">
                  <button class="small-button" type="button" @click="monitoredTask = task.id">实时详情</button>
                  <button v-if="task.status === 'failed'" class="small-button" type="button"
                    :disabled="retryingTasks.has(task.id) || deletingTasks.has(task.id)" :aria-busy="retryingTasks.has(task.id)" @click="retryTask(task)">
                    {{ retryingTasks.has(task.id) ? '正在重试…' : '立即重试' }}
                  </button>
                  <button class="small-button danger" type="button"
                    :disabled="task.status === 'running' || deletingTasks.has(task.id) || retryingTasks.has(task.id)"
                    :title="task.status === 'running' ? '任务正在执行，请等待完成后删除' : undefined" @click="removeTask(task)">删除</button>
                </td>
              </tr></tbody>
            </table>
            <div v-if="!tasks.length" class="empty-cell">{{ workspaceLoading ? '正在加载…' : '暂无任务' }}</div>
          </template>
        </div>
      </section>

      <section v-else-if="workspaceSection === 'channels'" aria-label="渠道管理">
        <div class="panel-toolbar">
          <h1 class="panel-heading">渠道 <small>{{ channels.length }} 个</small></h1>
          <button class="button primary" type="button" @click="openChannel()"><Plus aria-hidden="true" />添加渠道</button>
        </div>
        <div v-loading="workspaceLoading" class="channel-grid" :aria-busy="workspaceLoading">
          <article v-for="channel in channels" :key="channel.id" class="channel-card">
            <div class="channel-top">
              <span class="channel-avatar">{{ providerInitial(channel) }}</span>
              <div class="channel-identity"><h2>{{ channel.name }}</h2><span class="channel-url" :title="channel.base_url">{{ channel.base_url }}</span></div>
              <span v-if="channel.pinned" class="pin-label">置顶</span>
            </div>
            <div class="channel-actions">
              <button class="small-button" type="button" @click="testChannel(channel)">测试连接</button>
              <button class="small-button" type="button" @click="openChannel(channel)">编辑</button>
              <button class="small-button danger" type="button" @click="removeChannel(channel)">删除</button>
            </div>
            <p v-if="channel.description" class="channel-description">{{ channel.description }}</p>
            <div class="model-list">
              <span v-for="model in channelModels(channel).slice(0, 4)" :key="model">
                {{ model }}<template v-if="model === channel.model">（默认）</template>
              </span>
              <small v-if="channelModels(channel).length > 4">+{{ channelModels(channel).length - 4 }}</small>
              <em v-if="!channelModels(channel).length">暂无模型</em>
            </div>
          </article>
          <div v-if="!channels.length" class="empty-cell channel-empty">{{ workspaceLoading ? '正在加载…' : '暂无渠道' }}</div>
        </div>
      </section>

      <ProfileCenter v-else-if="workspaceSection === 'profile' && loggedIn" :key="user.id" :token="token" :user="user" :format-date="formatDate" @session-updated="updateSession" />

      <section v-else-if="workspaceSection === 'admin' && isAdmin" aria-label="管理中心">
        <div class="panel-toolbar">
          <div class="segmented" role="group" aria-label="管理面板">
            <button v-for="panel in adminPanels" :key="panel.key" :aria-pressed="adminSection === panel.key" type="button" @click="switchAdmin(panel.key)">{{ panel.label }}</button>
          </div>
          <div v-if="adminSection !== 'settings'" class="toolbar-actions pagination" aria-label="管理列表分页">
            <span class="toolbar-meta">共 {{ adminCurrent.total }} 条</span>
            <button class="button outline icon-button" :disabled="adminLoading || adminCurrent.page <= 0" type="button" aria-label="上一页" title="上一页" @click="adminPage(adminCurrent.page - 1)"><ArrowLeft aria-hidden="true" /></button>
            <span>{{ adminCurrent.page + 1 }} / {{ adminPageCount }}</span>
            <button class="button outline icon-button" :disabled="adminLoading || adminCurrent.page + 1 >= adminPageCount" type="button" aria-label="下一页" title="下一页" @click="adminPage(adminCurrent.page + 1)"><ArrowRight aria-hidden="true" /></button>
          </div>
        </div>
        <SiteSettings v-if="adminSection === 'settings'" :token="token" @updated="registrationEnabled = $event.registration_enabled" />
        <div v-else v-loading="adminLoading" class="table-frame" :aria-busy="adminLoading">
          <PromptManager v-if="adminSection === 'prompts'" :token="token" :items="adminCurrent.items" :format-date="formatDate" @changed="loadAdmin" />
          <table v-else-if="adminSection === 'users'" class="data-table work-table" aria-label="用户列表">
            <thead><tr><th>用户</th><th>角色</th><th>状态</th><th>注册时间</th><th>操作</th></tr></thead>
            <tbody><tr v-for="item in adminCurrent.items" :key="item.id">
              <th scope="row"><strong>{{ item.email }}</strong><span class="cell-note">ID {{ item.id }}</span></th>
              <td data-label="角色">{{ item.is_superadmin ? '超级管理员' : item.is_admin ? '管理员' : '普通用户' }}</td>
              <td data-label="状态"><span class="status-dot" :class="item.disabled ? 'disabled' : 'success'">{{ item.disabled ? '已禁用' : '正常' }}</span></td>
              <td data-label="注册时间">{{ formatDate(item.created_at) }}</td>
              <td class="row-actions"><button class="small-button" type="button" :disabled="item.is_superadmin" @click="toggleUser(item, 'disabled')">{{ item.disabled ? '启用' : '禁用' }}</button><button class="small-button" type="button" :disabled="item.is_superadmin" @click="toggleUser(item, 'is_admin')">{{ item.is_admin ? '取消管理员' : '设为管理员' }}</button></td>
            </tr></tbody>
          </table>
          <table v-else-if="adminSection === 'reports'" class="data-table work-table" aria-label="报告列表">
            <thead><tr><th>报告</th><th>所有者</th><th>渠道 / 模型</th><th>时间</th><th>操作</th></tr></thead>
            <tbody><tr v-for="item in adminCurrent.items" :key="item.id">
              <th scope="row"><strong>{{ item.prompt_name || item.slug }}</strong><span class="cell-note">{{ item.slug }}</span></th>
              <td data-label="所有者">ID {{ item.owner_id }}</td>
              <td data-label="渠道 / 模型" class="wrap-cell"><strong>{{ item.api_domain }}</strong><span class="cell-note">{{ item.model }}</span></td>
              <td data-label="时间">{{ formatDate(item.created_at) }}</td>
              <td class="row-actions"><button class="small-button danger" type="button" @click="deleteReport(item)">隐藏报告</button></td>
            </tr></tbody>
          </table>
          <table v-else class="data-table work-table" aria-label="任务列表">
            <thead><tr><th>任务 / 模型</th><th>所有者</th><th>状态</th><th>执行时间</th><th>错误</th><th>操作</th></tr></thead>
            <tbody><tr v-for="item in adminCurrent.items" :key="item.id">
              <th scope="row"><strong>{{ item.model || '未选择模型' }}</strong><span class="cell-note">#{{ item.id }} · {{ item.prompt_name || '渠道提示词' }}</span></th>
              <td data-label="所有者" class="wrap-cell">{{ item.owner_email }}<span class="cell-note">ID {{ item.owner_id }}</span></td>
              <td data-label="状态"><span class="status-dot" :class="item.status">{{ statusLabels[item.status] || item.status }}</span></td>
              <td data-label="执行时间">{{ formatDate(item.scheduled_for) }}</td><td data-label="错误" class="wrap-cell">{{ item.error || '—' }}</td>
              <td data-label="操作" class="row-actions"><TaskActions :token="token" :task="item" @changed="loadAdmin" @inspect="monitoredTask = $event.id" /></td>
            </tr></tbody>
          </table>
          <div v-if="!adminCurrent.items.length" class="empty-cell">{{ adminLoading ? '正在加载…' : '暂无记录' }}</div>
        </div>
      </section>
    </main>

    <el-dialog v-model="detailDialog" title="测试报告详情" width="1000px" class="report-dialog" destroy-on-close>
      <div v-if="selectedReport" ref="reportElement" class="report-detail">
        <div class="report-detail-head">
          <div><p class="eyebrow">{{ selectedReport.api_domain }}</p><h2>{{ selectedReport.model }}</h2><p>{{ selectedReport.prompt_name || '公开测试结果' }} · {{ formatDate(selectedReport.created_at) }}</p></div>
          <div class="toolbar-actions" data-image-exclude>
            <ReportImageShare v-if="reportDetails" :report-element="reportElement" :model="reportDetails.model" />
            <a class="button outline" :href="`/r/${selectedReport.slug}`" target="_blank" rel="noopener">查看报告 ↗</a>
          </div>
        </div>
        <p v-if="detailLoading" role="status">正在加载报告数据…</p>
        <p v-else-if="detailError" class="monitor-error" role="alert">{{ detailError }}</p>
        <template v-else-if="reportDetails">
          <h3 class="panel-heading report-section-title">检测指标</h3>
          <ReportMetrics :report="reportDetails" />
          <ReportContents :data="reportDetails.data" :average="reportThroughput(reportDetails)" />
          <ReportFeedback :key="`${reportDetails.id}-${user?.id || 'anonymous'}`" :report="reportDetails" :token="loggedIn ? token : ''" @rated="reportRated" @login="openAuth()" />
        </template>
      </div>
    </el-dialog>
    <AuthDialog v-if="authDialog" @close="authDialog = false" @session="signedIn" />
    <TaskEditor v-if="taskFormVisible" :token="token"
      :channels="channels.filter((channel) => channel.enabled && channel.owner_id === user?.id)"
      @close="taskFormVisible = false" @queued="taskQueued" />
    <TaskMonitor v-if="monitoredTask && loggedIn" :token="token" :task-id="monitoredTask" :format-date="formatDate" @close="monitoredTask = null" @changed="refreshTaskViews" />
    <ChannelEditor v-if="channelEditor" v-bind="channelEditor" :token="token"
      @close="channelEditor = null" @saved="channelSaved" />
  </div>
</template>

<style src="./app.css"></style>
