<script setup>
import { onMounted, ref } from 'vue'
import { api } from './api'

const error = ref('')
onMounted(async () => {
  const parameters = new URLSearchParams(location.hash.slice(1))
  const code = parameters.get('code')
  history.replaceState(null, '', '/auth/callback')
  if (!code || parameters.has('error')) {
    error.value = '第三方登录未完成。请重试；若该邮箱已有未验证账号，请先通过邮箱找回密码完成验证。'
    return
  }
  try {
    const session = await api.oauthExchange({ code })
    localStorage.setItem('aijiance_token', session.token)
    location.replace('/')
  } catch (failure) { error.value = failure.message }
})
</script>

<template>
  <main class="auth-callback">
    <h1>AI质量检测</h1>
    <p v-if="error" role="alert">{{ error }}</p>
    <p v-else role="status">正在完成登录…</p>
    <a v-if="error" class="button primary" href="/">返回登录</a>
  </main>
</template>
