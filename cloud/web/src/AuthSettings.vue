<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'

const props = defineProps({ token: { type: String, required: true } })
const settings = ref(null)
const busy = ref(false)
const error = ref('')
const request = new AbortController()
onBeforeUnmount(() => request.abort())

async function load() {
  busy.value = true
  error.value = ''
  try { settings.value = await api.authSettings(props.token, request.signal) }
  catch (failure) { if (!request.signal.aborted) error.value = failure.message }
  finally { busy.value = false }
}
onMounted(load)
async function save(section) {
  busy.value = true
  error.value = ''
  try {
    const source = settings.value[section]
    const value = section === 'smtp'
      ? { enabled: source.enabled, host: source.host, port: source.port, security: source.security, username: source.username, password: source.password, from_address: source.from_address, from_name: source.from_name }
      : { enabled: source.enabled, client_id: source.client_id, client_secret: source.client_secret }
    const result = await api.updateAuthSettings(props.token, { [section]: value })
    settings.value[section] = result[section]
    ElMessage.success('配置已保存')
  } catch (failure) { error.value = failure.message }
  finally { busy.value = false }
}
async function testMail() {
  busy.value = true
  error.value = ''
  try { await api.testMail(props.token); ElMessage.success('测试邮件已发送到您的账号邮箱') }
  catch (failure) { error.value = failure.message }
  finally { busy.value = false }
}
</script>

<template>
  <section class="identity-settings" aria-label="邮件与第三方登录" :aria-busy="busy">
    <div class="panel-toolbar"><h2 class="panel-heading">邮件与第三方登录</h2><button class="button outline" type="button" :disabled="busy" @click="load">刷新登录配置</button></div>
    <p v-if="error" role="alert" class="monitor-error">{{ error }}</p>
    <template v-if="settings">
      <form class="identity-form" @submit.prevent="save('smtp')">
        <h3>SMTP 邮件服务</h3>
        <p class="muted">启用后，新用户注册须验证邮箱，并可通过邮件验证码找回密码。首次创建超级管理员无需邮件服务。密码留空保留已保存的值。</p>
        <label class="checkbox"><input v-model="settings.smtp.enabled" type="checkbox" :disabled="busy" />启用邮件服务</label>
        <div class="identity-grid">
          <label>SMTP 服务器<input v-model="settings.smtp.host" :required="settings.smtp.enabled" :disabled="busy" placeholder="smtp.example.com" /></label>
          <label>SMTP 端口<input v-model.number="settings.smtp.port" type="number" min="1" max="65535" required :disabled="busy" /></label>
          <label>传输加密<select v-model="settings.smtp.security" :disabled="busy"><option value="tls">TLS（通常为 465）</option><option value="starttls">STARTTLS（通常为 587）</option><option value="plain">不加密（仅用于内部邮件服务）</option></select></label>
          <label>SMTP 用户名<input v-model="settings.smtp.username" :disabled="busy" autocomplete="off" /></label>
          <label>SMTP 密码<input v-model="settings.smtp.password" type="password" :disabled="busy" autocomplete="new-password" :placeholder="settings.smtp.password_set ? '已保存，留空保留' : '填写密码或授权码'" /></label>
          <label>发件邮箱<input v-model="settings.smtp.from_address" type="email" :required="settings.smtp.enabled" :disabled="busy" /></label>
          <label>发件人名称<input v-model="settings.smtp.from_name" :disabled="busy" /></label>
        </div>
        <div class="toolbar-actions"><button class="button primary" type="submit" :disabled="busy">保存邮件设置</button><button class="button outline" type="button" :disabled="busy || !settings.smtp.enabled" @click="testMail">发送测试邮件到我的邮箱</button></div>
      </form>
      <form v-for="provider in ['github', 'google']" :key="provider" class="identity-form" @submit.prevent="save(provider)">
        <h3>{{ provider === 'github' ? 'GitHub' : 'Google' }} 登录</h3>
        <p class="muted">填写应用凭证并启用后，登录页才会显示入口。Client Secret 留空保留已保存的值。</p>
        <label class="checkbox"><input v-model="settings[provider].enabled" type="checkbox" :disabled="busy" />启用 {{ provider === 'github' ? 'GitHub' : 'Google' }} 登录</label>
        <div class="identity-grid">
          <label>Client ID<input v-model="settings[provider].client_id" :required="settings[provider].enabled" :disabled="busy" autocomplete="off" /></label>
          <label>Client Secret<input v-model="settings[provider].client_secret" type="password" :disabled="busy" autocomplete="new-password" :placeholder="settings[provider].client_secret_set ? '已保存，留空保留' : '填写应用密钥'" /></label>
        </div>
        <p>回调地址（复制到提供商的应用设置）：<code class="callback-url">{{ settings[provider].callback_url }}</code></p>
        <button class="button primary" type="submit" :disabled="busy">保存 {{ provider === 'github' ? 'GitHub' : 'Google' }} 配置</button>
      </form>
    </template>
    <p v-else-if="busy" role="status">正在加载配置…</p>
  </section>
</template>
