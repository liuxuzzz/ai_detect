<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'
import { apiUrl } from './api-url'

const emit = defineEmits(['close', 'session'])
const mode = ref('login')
const options = ref(null)
const loading = ref(false)
const error = ref('')
const email = ref('')
const password = ref('')
const code = ref('')
const sending = ref(false)
const countdown = ref(0)
const request = new AbortController()
let timer
const title = computed(() => ({ login: '登录 AI质量检测', register: '创建账号', reset: '找回密码' })[mode.value])
const needsCode = computed(() => mode.value === 'reset' || (mode.value === 'register' && options.value?.email_verification))

async function loadOptions() {
  error.value = ''
  try { options.value = await api.authOptions(request.signal) }
  catch (failure) { if (!request.signal.aborted) error.value = failure.message }
}
onMounted(loadOptions)
onBeforeUnmount(() => { request.abort(); clearInterval(timer) })

function switchMode(next) {
  mode.value = next
  error.value = ''
  password.value = ''
  code.value = ''
}
async function sendCode() {
  if (sending.value || countdown.value || !email.value) return
  sending.value = true
  error.value = ''
  try {
    const result = await api.emailCode({ email: email.value, purpose: mode.value === 'reset' ? 'reset' : 'register' })
    ElMessage.success(result.message)
    countdown.value = 60
    clearInterval(timer)
    timer = setInterval(() => { countdown.value--; if (!countdown.value) clearInterval(timer) }, 1000)
  } catch (failure) { error.value = failure.message }
  finally { sending.value = false }
}
async function submit() {
  loading.value = true
  error.value = ''
  try {
    if (mode.value === 'login') {
      emit('session', await api.login({ email: email.value, password: password.value }))
    } else if (mode.value === 'register') {
      const result = await api.register({ email: email.value, password: password.value, email_code: code.value })
      ElMessage.success(result.is_superadmin ? '超级管理员已创建，请登录并配置站点' : '注册成功，请登录')
      switchMode('login')
      await loadOptions()
    } else {
      await api.resetPassword({ email: email.value, code: code.value, new_password: password.value })
      ElMessage.success('密码已重置，请重新登录')
      switchMode('login')
    }
  } catch (failure) { error.value = failure.message }
  finally { loading.value = false }
}
function loginProvider(provider) { window.location.assign(apiUrl(`/api/auth/oauth/${provider}/start`)) }
</script>

<template>
  <el-dialog :model-value="true" :title="title" width="440px" :close-on-click-modal="!loading" @close="emit('close')">
    <form class="auth-form" @submit.prevent="submit">
      <p v-if="options?.bootstrap_required" class="bootstrap-note">欢迎部署 AI质量检测。第一个成功注册的账号将成为超级管理员，请先创建您的账号。</p>
      <p v-else-if="mode === 'reset'" class="muted">输入注册邮箱，通过邮件验证码设置新密码。旧登录会话将失效。</p>
      <p v-else class="muted">登录后可管理测试、分享报告并参与评分。</p>
      <label>邮箱<input v-model="email" type="email" required maxlength="254" autocomplete="email" :disabled="loading" /></label>
      <div v-if="needsCode" class="email-code-row">
        <label>邮箱验证码<input v-model="code" required inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="one-time-code" :disabled="loading" /></label>
        <button class="button outline" type="button" :disabled="!email || sending || countdown > 0 || loading" @click="sendCode">{{ sending ? '正在发送…' : countdown ? `${countdown} 秒后重发` : '发送验证码' }}</button>
      </div>
      <label>{{ mode === 'reset' ? '新密码' : '密码' }}<input v-model="password" type="password" required :minlength="mode === 'login' ? 1 : 8" maxlength="1024" :autocomplete="mode === 'login' ? 'current-password' : 'new-password'" :disabled="loading" /></label>
      <p v-if="error" role="alert" class="monitor-error">{{ error }}</p>
      <button class="button primary full-button" type="submit" :disabled="loading || (mode !== 'login' && !options)">{{ loading ? '正在处理…' : mode === 'login' ? '登录' : mode === 'register' ? '注册' : '重置密码' }}</button>
      <button v-if="mode === 'login' && options?.password_reset" class="text-button" type="button" :disabled="loading" @click="switchMode('reset')">忘记密码？</button>
      <button v-if="mode === 'login' && options?.registration_enabled" class="switch-auth" type="button" :disabled="loading" @click="switchMode('register')">还没有账号？立即注册</button>
      <button v-else-if="mode !== 'login'" class="switch-auth" type="button" :disabled="loading" @click="switchMode('login')">返回登录</button>
      <p v-if="options?.registration_enabled === false" class="muted">注册已关闭，请联系管理员。</p>
      <p v-if="!options" class="muted">{{ error ? '登录方式加载失败' : '正在加载登录方式…' }}<button v-if="error" class="text-button" type="button" @click="loadOptions">重试</button></p>
      <div v-if="mode !== 'reset' && (options?.github || options?.google)" class="provider-buttons">
        <button v-if="options.github" class="button outline" type="button" :disabled="loading" @click="loginProvider('github')">使用 GitHub {{ mode === 'register' ? '注册' : '登录' }}</button>
        <button v-if="options.google" class="button outline" type="button" :disabled="loading" @click="loginProvider('google')">使用 Google {{ mode === 'register' ? '注册' : '登录' }}</button>
      </div>
    </form>
  </el-dialog>
</template>
