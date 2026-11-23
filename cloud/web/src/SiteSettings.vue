<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'
import AuthSettings from './AuthSettings.vue'

const props = defineProps({ token: { type: String, required: true } })
const emit = defineEmits(['updated'])
const settings = ref(null)
const loading = ref(false)
const saving = ref(false)
const error = ref('')
const currentSite = location.origin
const siteUrl = ref(currentSite)
let request
const quota = reactive({ count: 100, duration: 1, unit: 86400 })
const quotaValid = computed(() => Number.isInteger(quota.count) && quota.count >= 1 && quota.count <= 1000000
  && Number.isInteger(quota.duration) && quota.duration >= 1 && quota.duration * quota.unit <= 31536000)

function syncQuota(result) {
  quota.count = result.upload_limit
  quota.unit = [86400, 3600, 60, 1].find(unit => result.upload_window_seconds % unit === 0)
  quota.duration = result.upload_window_seconds / quota.unit
}

async function load() {
  request?.abort()
  const current = request = new AbortController()
  loading.value = true
  error.value = ''
  try {
    const result = await api.siteSettings(props.token, current.signal)
    if (!current.signal.aborted) { settings.value = result; syncQuota(result); siteUrl.value = result.site_url || currentSite }
  } catch (failure) {
    if (!current.signal.aborted) error.value = failure.message
  } finally {
    if (!current.signal.aborted) loading.value = false
  }
}
watch(() => props.token, load, { immediate: true })
onBeforeUnmount(() => request?.abort())

async function setRegistration(enabled) {
  if (loading.value || saving.value || !settings.value) return
  saving.value = true
  error.value = ''
  try {
    const result = await api.updateSiteSettings(props.token, { registration_enabled: enabled })
    settings.value = result
    emit('updated', result)
    ElMessage.success(result.registration_enabled ? '注册已开启' : '注册已关闭')
  } catch (failure) { error.value = failure.message }
  finally { saving.value = false }
}

async function saveQuota() {
  if (loading.value || saving.value || !quotaValid.value) return
  saving.value = true
  error.value = ''
  try {
    settings.value = await api.updateSiteSettings(props.token, {
      upload_limit: quota.count,
      upload_window_seconds: quota.duration * quota.unit,
    })
    syncQuota(settings.value)
    ElMessage.success('上传限额已保存，立即生效')
  } catch (failure) { error.value = failure.message }
  finally { saving.value = false }
}

async function saveSiteUrl() {
  if (loading.value || saving.value) return
  saving.value = true
  error.value = ''
  try {
    settings.value = await api.updateSiteSettings(props.token, { site_url: siteUrl.value })
    siteUrl.value = settings.value.site_url
    ElMessage.success('站点地址已保存，立即生效')
  } catch (failure) { error.value = failure.message }
  finally { saving.value = false }
}
</script>

<template>
  <section class="site-settings" aria-label="站点设置" :aria-busy="loading || saving">
    <div class="panel-toolbar"><h1 class="panel-heading">站点设置</h1><button class="button outline" type="button" :disabled="loading || saving" @click="load">刷新设置</button></div>
    <p v-if="error" class="monitor-error" role="alert">{{ error }}</p>
    <p v-if="loading && !settings" class="muted" role="status">正在加载设置…</p>
    <form v-if="settings" class="site-address-form" @submit.prevent="saveSiteUrl">
      <h2 class="panel-heading">站点地址</h2>
      <p class="muted">首次管理员网页登录时自动记录，用于报告分享和登录完成后的跳转。更换域名后在这里更新，无需配置 server 环境变量。</p>
      <label>网站公开地址<input v-model="siteUrl" type="url" required :disabled="loading || saving" placeholder="https://ai.example.com" /></label>
      <div class="toolbar-actions"><button class="button outline" type="button" :disabled="loading || saving" @click="siteUrl = currentSite">使用当前访问地址</button><button class="button primary" type="submit" :disabled="loading || saving">保存站点地址</button></div>
    </form>
    <div v-if="settings" class="registration-setting">
      <div><h2 class="panel-heading">开放注册</h2><p class="muted">关闭后，访客无法创建新账号。已有账号仍可正常登录。</p></div>
      <el-switch :model-value="settings.registration_enabled" :loading="saving" :disabled="loading || saving"
        aria-label="开放注册" active-text="已开启" inactive-text="已关闭" @change="setRegistration" />
    </div>
    <form v-if="settings" class="upload-policy" @submit.prevent="saveQuota">
      <h2 class="panel-heading">每人上传限额</h2>
      <p class="muted">所有用户（包括管理员）分别计数，同一账号的多个 Client Key 共用限额。按最近一段时间的成功上传计算，删除报告不会返还次数；不影响本地检测和云端任务。</p>
      <div class="toolbar-actions quota-fields">
        <span>每</span>
        <el-input-number v-model="quota.duration" :min="1" :max="Math.floor(31536000 / quota.unit)" :precision="0" :disabled="saving || loading" aria-label="上传时间窗口" />
        <el-select v-model="quota.unit" :disabled="saving || loading" aria-label="上传时间单位" style="width: 110px">
          <el-option label="秒" :value="1" />
          <el-option label="分钟" :value="60" />
          <el-option label="小时" :value="3600" />
          <el-option label="天" :value="86400" />
        </el-select>
        <span>最多上传</span>
        <el-input-number v-model="quota.count" :min="1" :max="1000000" :precision="0" :disabled="saving || loading" aria-label="每人上传次数" />
        <span>次</span>
        <button class="button primary" type="submit" :disabled="saving || loading || !quotaValid">{{ saving ? '正在保存…' : '保存上传限额' }}</button>
      </div>
    </form>
    <AuthSettings :token="token" />
  </section>
</template>
