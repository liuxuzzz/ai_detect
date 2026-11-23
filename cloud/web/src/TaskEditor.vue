<script setup>
import { computed, nextTick, onMounted, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'

const props = defineProps({ token: String, channels: { type: Array, default: () => [] } })
const emit = defineEmits(['close', 'queued'])
const form = reactive({
  upstream_id: '', model: '', reasoning_effort: 'default', prompt_kind: 'library', prompt_id: '',
  prompt_text: '', execution_mode: 'immediate',
})
const saving = ref(false)
const prompts = ref([])
const promptsLoading = ref(false)
const promptRequest = new AbortController()
const promptChoice = ref('')
const selectedPrompt = computed(() => prompts.value.find((prompt) => prompt.id === form.prompt_id))
watch(promptChoice, (choice) => {
  form.prompt_kind = choice.startsWith('library:') ? 'library' : choice
  form.prompt_id = choice.startsWith('library:') ? Number(choice.slice(8)) : null
})
async function loadPrompts() {
  promptsLoading.value = true
  try {
    prompts.value = await api.prompts(props.token, promptRequest.signal)
    if (!promptChoice.value) promptChoice.value = prompts.value.length ? `library:${prompts.value[0].id}` : 'pelican'
  } catch (error) {
    if (!promptRequest.signal.aborted) ElMessage.error(error.message)
  } finally { promptsLoading.value = false }
}
onMounted(loadPrompts)
onBeforeUnmount(() => promptRequest.abort())
const scheduleError = ref('')
const delayTime = ref('00:05:00')
const scheduledAt = ref(null)
const delayPicker = ref(null)
const datePicker = ref(null)
const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
const selectedChannel = computed(() => props.channels.find((channel) => channel.id === Number(form.upstream_id)))
const models = computed(() => [...new Set([
  selectedChannel.value?.model, ...(selectedChannel.value?.models || []),
].filter(Boolean))])
const delayMs = computed(() => {
  if (!delayTime.value) return 0
  const [hours, minutes, seconds] = delayTime.value.split(':').map(Number)
  return (hours * 3600 + minutes * 60 + seconds) * 1000
})

watch(selectedChannel, (channel) => {
  form.model = channel?.model || channel?.models?.[0] || ''
  if (form.prompt_kind === 'channel' && !channel?.prompt?.trim()) promptChoice.value = 'pelican'
})
watch([delayTime, scheduledAt], () => { scheduleError.value = '' })
watch(() => form.execution_mode, async (mode) => {
  scheduleError.value = ''
  await nextTick()
  if (mode === 'delayed') delayPicker.value?.handleOpen()
  if (mode === 'scheduled') datePicker.value?.handleOpen()
})

function disabledDate(date) {
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  return date.getTime() < today.getTime()
}

async function addTask() {
  if (saving.value) return
  if (!form.upstream_id || !form.model) {
    ElMessage.warning('请选择渠道和模型')
    return
  }
  if (!promptChoice.value || (form.prompt_kind === 'library' && !selectedPrompt.value)) {
    ElMessage.warning('请选择提示词')
    return
  }
  const payload = { ...form }
  if (form.execution_mode === 'delayed') {
    if (!Number.isFinite(delayMs.value) || delayMs.value <= 0) {
      scheduleError.value = '请选择大于零的延时时长'
      return
    }
    payload.delay_ms = delayMs.value
  } else if (form.execution_mode === 'scheduled') {
    if (!(scheduledAt.value instanceof Date) || !(scheduledAt.value.getTime() > Date.now())) {
      scheduleError.value = '请选择未来的执行日期和时间'
      return
    }
    payload.scheduled_for = scheduledAt.value.toISOString()
  }
  saving.value = true
  try {
    await api.addTask(props.token, payload)
    ElMessage.success('测试任务已加入队列')
    emit('queued')
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <el-dialog :model-value="true" title="添加测试任务" width="min(520px, calc(100vw - 24px))"
    :close-on-click-modal="false" :close-on-press-escape="!saving" :show-close="!saving" @close="emit('close')">
    <form class="dialog-form task-editor" @submit.prevent="addTask">
      <label>渠道<select v-model="form.upstream_id" required>
        <option value="" disabled>请选择渠道</option>
        <option v-for="channel in channels" :key="channel.id" :value="channel.id">{{ channel.name }}</option>
      </select></label>
      <label>模型<select v-model="form.model" required>
        <option value="" disabled>请选择模型</option>
        <option v-for="model in models" :key="model" :value="model">{{ model }}</option>
      </select></label>
      <label>提示词<select v-model="promptChoice" :disabled="promptsLoading || saving" required>
        <option value="" disabled>{{ promptsLoading ? '正在加载公共提示词…' : '请选择提示词' }}</option>
        <option v-for="prompt in prompts" :key="prompt.id" :value="`library:${prompt.id}`">公共 · {{ prompt.name }}</option>
        <option value="pelican">内置 · 鹈鹕测试</option>
        <option v-if="selectedChannel?.prompt?.trim()" value="channel">渠道提示词</option>
        <option value="custom">自定义提示词</option>
      </select></label>
      <button v-if="!prompts.length && !promptsLoading" class="text-button" type="button" @click="loadPrompts">刷新公共提示词</button>
      <label v-if="selectedPrompt && form.prompt_kind === 'library'">提示词预览（管理员维护，只读）
        <textarea :value="selectedPrompt.content" readonly rows="6" aria-label="公共提示词预览" />
      </label>
      <label v-if="form.prompt_kind === 'channel'">渠道提示词预览<textarea :value="selectedChannel?.prompt" readonly rows="5" /></label>
      <label v-if="form.prompt_kind === 'custom'">提示词正文<textarea v-model="form.prompt_text" required rows="5" /></label>
      <label>推理强度<select v-model="form.reasoning_effort">
        <option value="default">默认（default）</option>
        <option value="minimal">极低（minimal）</option>
        <option value="low">低（low）</option>
        <option value="medium">中（medium）</option>
        <option value="high">高（high）</option>
        <option value="xhigh">极高（xhigh）</option>
        <option value="max">最大（max）</option>
      </select></label>
      <label>执行方式<select v-model="form.execution_mode" :disabled="saving">
        <option value="immediate">立即执行</option>
        <option value="delayed">延时执行</option>
        <option value="scheduled">定时执行</option>
      </select></label>
      <label v-if="form.execution_mode === 'delayed'">延时时长（时:分:秒）
        <el-time-picker ref="delayPicker" v-model="delayTime" format="HH:mm:ss" value-format="HH:mm:ss"
          :editable="false" :clearable="false" :disabled="saving" aria-label="延时时长" placeholder="点击选择延时时长" />
      </label>
      <label v-if="form.execution_mode === 'scheduled'">执行时间（{{ timeZone }}）
        <el-date-picker ref="datePicker" v-model="scheduledAt" type="datetime" format="YYYY-MM-DD HH:mm:ss"
          :editable="false" :clearable="false" :disabled-date="disabledDate" :disabled="saving"
          aria-label="执行日期和时间" placeholder="点击选择日期和时间" />
      </label>
      <p v-if="form.execution_mode === 'delayed'" class="schedule-hint">提交后等待所选时长执行。</p>
      <p v-else-if="form.execution_mode === 'scheduled'" class="schedule-hint">按所选时区的日期和时间执行一次。</p>
      <p v-if="scheduleError" class="schedule-error" role="alert">{{ scheduleError }}</p>
      <button class="button primary full-button" :disabled="saving" type="submit">
        {{ saving ? '正在提交…' : '加入测试队列' }}
      </button>
    </form>
  </el-dialog>
</template>

<style scoped>
.task-editor :deep(.el-date-editor) { width: 100%; }
.task-editor :deep(input.el-input__inner) { border: 0; padding: 0; height: 100%; }
.task-editor :deep(.el-input__wrapper) { min-height: 34px; }
.schedule-hint, .schedule-error { margin: 0; font-size: 12px; }
.schedule-hint { color: var(--muted); }
.schedule-error { color: var(--el-color-danger); }
</style>
