<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'
import ClientKeys from './ClientKeys.vue'

const props = defineProps({
  token: { type: String, required: true },
  user: { type: Object, required: true },
  formatDate: { type: Function, required: true },
})
const emit = defineEmits(['session-updated'])
const section = ref('client-keys')
const saving = ref(false)
const password = reactive({ current: '', next: '', confirm: '' })
const sharing = ref(true)
const sharingLoading = ref(true)
const sharingSaving = ref(false)

onMounted(async () => {
  try {
    const result = await api.reportVisibility(props.token)
    sharing.value = result.public_reports
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    sharingLoading.value = false
  }
})

async function saveSharing() {
  if (sharingSaving.value) return
  sharingSaving.value = true
  try {
    const result = await api.updateReportVisibility(props.token, { public_reports: sharing.value })
    sharing.value = result.public_reports
    ElMessage.success(result.public_reports ? '已开启公开排行分享' : '已关闭公开排行分享')
  } catch (error) {
    sharing.value = !sharing.value
    ElMessage.error(error.message)
  } finally {
    sharingSaving.value = false
  }
}

async function changePassword() {
  if (saving.value) return
  if (password.next !== password.confirm) {
    ElMessage.error('两次输入的新密码不一致')
    return
  }
  saving.value = true
  try {
    const session = await api.changePassword(props.token, {
      current_password: password.current,
      new_password: password.next,
    })
    emit('session-updated', session)
    Object.assign(password, { current: '', next: '', confirm: '' })
    ElMessage.success('密码已修改')
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <section aria-labelledby="profile-heading">
    <div class="panel-toolbar">
      <h1 id="profile-heading" class="panel-heading">个人中心</h1>
      <span class="profile-account">{{ user.email }} <small class="muted">{{ user.is_admin ? '管理员' : '普通用户' }}</small></span>
    </div>
    <div class="segmented profile-tabs" role="group" aria-label="个人中心设置">
      <button :aria-pressed="section === 'client-keys'" type="button" @click="section = 'client-keys'">我的 Client Key</button>
      <button :aria-pressed="section === 'sharing'" type="button" @click="section = 'sharing'">报告分享</button>
      <button :aria-pressed="section === 'password'" type="button" @click="section = 'password'">修改密码</button>
    </div>

    <ClientKeys v-if="section === 'client-keys'" :token="token" :format-date="formatDate" />
    <section v-else-if="section === 'sharing'" class="password-panel" aria-labelledby="sharing-heading" :aria-busy="sharingLoading || sharingSaving">
      <h2 id="sharing-heading" class="panel-heading">公开排行分享</h2>
      <p class="muted">开启后，自己上传的成功测试会出现在公开排行。关闭后，自己的测试不会出现在公开排行。</p>
      <label class="sharing-setting"><input v-model="sharing" type="checkbox" :disabled="sharingLoading || sharingSaving" @change="saveSharing" />允许我的测试显示在公开排行</label>
    </section>
    <section v-else class="password-panel" aria-labelledby="password-heading">
      <h2 id="password-heading" class="panel-heading">修改密码</h2>
      <p class="muted">修改后，其他已登录会话需要重新登录，Client Key 继续有效。</p>
      <form class="auth-form" :aria-busy="saving" @submit.prevent="changePassword">
        <input class="visually-hidden" type="text" name="username" :value="user.email" autocomplete="username" readonly tabindex="-1" aria-label="账号邮箱" />
        <label>当前密码<input v-model="password.current" name="current-password" type="password" autocomplete="current-password" required :disabled="saving" /></label>
        <label>新密码<input v-model="password.next" name="new-password" type="password" autocomplete="new-password" minlength="8" maxlength="1024" placeholder="至少 8 个字符" required :disabled="saving" /></label>
        <label>确认新密码<input v-model="password.confirm" name="confirm-password" type="password" autocomplete="new-password" minlength="8" maxlength="1024" required :disabled="saving" /></label>
        <button class="button primary" type="submit" :disabled="saving">{{ saving ? '正在保存…' : '保存新密码' }}</button>
      </form>
    </section>
  </section>
</template>
