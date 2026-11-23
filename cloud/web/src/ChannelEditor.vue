<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'

const props = defineProps({ token: String, channel: Object })
const emit = defineEmits(['close', 'saved'])
const existing = props.channel
const initialModels = [...new Set([...(existing?.models || []), existing?.model].filter(Boolean))]
const form = reactive({
  name: existing?.name || '',
  provider_type: existing?.provider_type || 'openai-compatible',
  base_url: existing?.base_url || '',
  api_key: '',
  description: existing?.description || '',
  model: existing?.model || initialModels[0] || '',
  models: initialModels,
  pinned: existing?.pinned || false,
  enabled: existing?.enabled ?? true,
  prompt: existing?.prompt || '',
  schedule: existing?.schedule ?? null,
})
const discovered = ref([])
const search = ref('')
const manualModel = ref('')
const loading = ref(false)
const saving = ref(false)
const testing = ref(false)
const testResult = ref(null)
const discoveryError = ref('')
let upstreamRequest
const busy = computed(() => loading.value || testing.value || saving.value)

const needsKey = computed(() => !existing ||
  form.base_url.trim().replace(/\/+$/, '') !== existing.base_url.trim().replace(/\/+$/, ''))
const candidates = computed(() => {
  const term = search.value.trim().toLowerCase()
  return [...new Set([...form.models, ...discovered.value])]
    .filter((model) => model.toLowerCase().includes(term))
})

watch([() => form.base_url, () => form.api_key], () => {
  discovered.value = []
  discoveryError.value = ''
  testResult.value = null
})
watch(() => form.models, (models) => {
  if (!models.includes(form.model)) form.model = models[0] || ''
})

async function discoverModels() {
  if (busy.value) return
  if (!form.base_url || (needsKey.value && !form.api_key)) {
    discoveryError.value = '请填写 Base URL 和 API Key'
    return
  }
  const controller = new AbortController()
  upstreamRequest = controller
  loading.value = true
  discoveryError.value = ''
  try {
    const result = await api.discoverModels(props.token, connectionInput(), controller.signal)
    if (controller.signal.aborted) return
    discovered.value = result.models
    search.value = ''
  } catch (error) {
    if (!controller.signal.aborted) discoveryError.value = error.message
  } finally {
    loading.value = false
  }
}

function connectionInput() {
  return { channel_id: existing?.id, base_url: form.base_url, api_key: form.api_key }
}

async function testConnection() {
  if (busy.value) return
  if (!form.base_url || (needsKey.value && !form.api_key)) {
    testResult.value = { ok: false, message: '请填写 Base URL 和 API Key' }
    return
  }
  const controller = new AbortController()
  upstreamRequest = controller
  testing.value = true
  testResult.value = null
  try {
    const result = await api.testChannelDraft(props.token, connectionInput(), controller.signal)
    if (controller.signal.aborted) return
    testResult.value = {
      ok: result.ok,
      message: (result.ok ? '连接成功' : '连接失败') + ' · HTTP ' + result.status + ' · ' + result.latency_ms + ' ms',
    }
  } catch (error) {
    if (!controller.signal.aborted) testResult.value = { ok: false, message: error.message }
  } finally {
    testing.value = false
  }
}

function addManualModel() {
  const model = manualModel.value.trim()
  if (!model) return
  if (!form.models.includes(model)) form.models = [...form.models, model]
  manualModel.value = ''
  search.value = ''
}

async function saveChannel() {
  if (busy.value) return
  saving.value = true
  try {
    if (existing) await api.updateChannel(props.token, existing.id, form)
    else await api.addChannel(props.token, form)
    ElMessage.success(existing ? '渠道已更新' : '渠道已添加')
    emit('saved')
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    saving.value = false
  }
}

onBeforeUnmount(() => upstreamRequest?.abort())
</script>

<template>
  <el-dialog
    :model-value="true"
    :title="existing ? '编辑渠道' : '添加渠道'"
    width="min(620px, calc(100vw - 24px))"
    :close-on-click-modal="false"
    :close-on-press-escape="!saving"
    :show-close="!saving"
    @close="emit('close')"
  >
    <form class="dialog-form two-columns" @submit.prevent="saveChannel">
      <label>渠道名称<input v-model.trim="form.name" required placeholder="例如：OpenAI" /></label>
      <label>厂商类型<select v-model="form.provider_type">
        <option value="openai">OpenAI（Responses API）</option>
        <option value="openai-compatible">OpenAI Compatible</option>
        <option value="custom">自定义渠道</option>
        <option value="anthropic">Anthropic</option>
        <option value="google">Google</option>
      </select></label>
      <label class="wide">Base URL
        <input v-model.trim="form.base_url" :disabled="busy" required placeholder="https://api.example.com/v1" />
      </label>
      <label class="wide">API Key
        <input v-model.trim="form.api_key" :disabled="busy" :required="needsKey" type="password"
          :placeholder="needsKey ? '输入渠道 API Key' : '留空则保留原 Key'" autocomplete="new-password" />
      </label>

      <div class="wide channel-connection" :aria-busy="testing">
        <button class="button" type="button" :disabled="busy" @click="testConnection">
          {{ testing ? '正在测试…' : '测试连接' }}
        </button>
        <p v-if="testResult" class="connection-result" :class="{ success: testResult.ok }"
          :role="testResult.ok ? 'status' : 'alert'">{{ testResult.message }}</p>
      </div>

      <fieldset class="channel-model-picker wide">
        <legend>渠道模型</legend>
        <div class="channel-model-controls">
          <input v-model="search" aria-label="搜索模型" placeholder="搜索模型 ID" @keydown.enter.prevent />
          <button class="button" type="button" :disabled="busy" @click="discoverModels">
            {{ loading ? '正在拉取…' : '拉取模型' }}
          </button>
        </div>
        <p v-if="discoveryError" class="channel-model-error" role="alert">{{ discoveryError }}</p>
        <p class="channel-model-status" aria-live="polite">
          已选 {{ form.models.length }} 个<span v-if="discovered.length"> · 拉取到 {{ discovered.length }} 个</span>
        </p>
        <div v-if="candidates.length" class="channel-model-options">
          <label v-for="model in candidates" :key="model" class="check-label">
            <input v-model="form.models" type="checkbox" :value="model" />{{ model }}
          </label>
        </div>
        <p v-else-if="search" class="channel-model-status">没有匹配的模型</p>
        <div class="channel-model-controls">
          <input v-model="manualModel" aria-label="手动输入模型 ID" placeholder="手动输入模型 ID"
            @keydown.enter.prevent="addManualModel" />
          <button class="button" type="button" :disabled="!manualModel.trim()" @click="addManualModel">添加模型</button>
        </div>
        <label>默认模型<select v-model="form.model" :disabled="!form.models.length" :required="!!form.models.length">
          <option value="" disabled>请先选择模型</option>
          <option v-for="model in form.models" :key="model" :value="model">{{ model }}</option>
        </select></label>
      </fieldset>

      <label class="wide">厂商介绍
        <textarea v-model="form.description" rows="3" placeholder="介绍这个渠道的特点、区域或限额" />
      </label>
      <label class="check-label"><input v-model="form.pinned" type="checkbox" />置顶渠道</label>
      <label class="check-label"><input v-model="form.enabled" type="checkbox" />启用渠道</label>
      <button class="button primary full-button wide" :disabled="busy" type="submit">
        {{ saving ? '正在保存…' : '保存渠道' }}
      </button>
    </form>
  </el-dialog>
</template>

<style scoped>
.channel-connection { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
.connection-result { margin: 0; font-size: 12px; color: var(--el-color-danger); overflow-wrap: anywhere; }
.connection-result.success { color: var(--el-color-success); }
.channel-model-picker { display: grid; gap: 8px; min-width: 0; margin: 0; padding: 10px; border: 1px solid var(--line); border-radius: 5px; }
.channel-model-controls { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 8px; }
.channel-model-status, .channel-model-error { margin: 0; font-size: 12px; }
.channel-model-status { color: var(--muted); }
.channel-model-error { color: var(--el-color-danger); }
.channel-model-options { display: grid; gap: 6px; max-height: 160px; overflow: auto; overflow-wrap: anywhere; }
</style>
