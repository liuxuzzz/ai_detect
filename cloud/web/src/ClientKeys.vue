<script setup>
import { nextTick, onMounted, ref } from 'vue'
import { Plus, Refresh } from '@element-plus/icons-vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from './api'
import { apiUrl } from './api-url'

const props = defineProps({
  token: { type: String, required: true },
  formatDate: { type: Function, required: true },
})

const keys = ref(null)
const busy = ref(false)
const newSecret = ref('')
const revealed = ref(false)
const secretInput = ref(null)

async function run(action) {
  if (busy.value) return
  busy.value = true
  try {
    await action()
  } catch (error) {
    ElMessage.error(error.message)
  } finally {
    busy.value = false
  }
}

async function refresh() {
  keys.value = await api.clientKeys(props.token)
}

function createKey() {
  return run(async () => {
    const { key, ...info } = await api.createClientKey(props.token)
    revealed.value = false
    newSecret.value = key
    if (keys.value) keys.value = [info, ...keys.value]
    else await refresh()
  })
}

function viewKey(item) {
  return run(async () => {
    const { key } = await api.revealClientKey(props.token, item.id)
    revealed.value = false
    newSecret.value = key
  })
}

function revokeKey(item) {
  return run(async () => {
    const confirmed = await ElMessageBox.confirm(
      `撤销 ${item.prefix}… 后，使用此 Key 的客户端将无法上传报告。`,
      '撤销 Client Key',
      { type: 'warning', confirmButtonText: '撤销', cancelButtonText: '取消' },
    ).then(() => true, () => false)
    if (!confirmed) return
    await api.revokeClientKey(props.token, item.id)
    ElMessage.success('Client Key 已撤销')
    await refresh()
  })
}

async function copyKey() {
  try {
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(newSecret.value)
      ElMessage.success('已复制 Client Key')
      return
    }
  } catch {}
  revealed.value = true
  await nextTick()
  secretInput.value?.focus()
  secretInput.value?.select()
  ElMessage.info('Key 已选中，请使用系统复制快捷键')
}

onMounted(() => run(refresh))
</script>

<template>
  <section aria-labelledby="client-keys-heading">
    <div class="panel-toolbar">
      <h1 id="client-keys-heading" class="panel-heading">我的 Client Key</h1>
      <div class="toolbar-actions">
        <button class="button outline icon-button" type="button" aria-label="刷新 Client Key" title="刷新 Client Key" :disabled="busy" @click="run(refresh)">
          <Refresh aria-hidden="true" />
        </button>
        <button class="button primary" type="button" :disabled="busy" @click="createKey">
          <Plus aria-hidden="true" />创建 Client Key
        </button>
      </div>
    </div>
    <p class="muted">在客户端「全局设置」中，将云端地址填写为 <code>{{ apiUrl('') }}</code>（与浏览器地址相同），再填入创建的 Client Key，即可上传检测报告。</p>

    <div v-loading="busy" class="table-frame" :aria-busy="busy">
      <table v-if="keys?.length" class="data-table work-table" aria-label="我的 Client Key">
        <thead><tr><th>Key 前缀</th><th>创建时间</th><th>状态</th><th>操作</th></tr></thead>
        <tbody>
          <tr v-for="item in keys" :key="item.id">
            <th scope="row"><code>{{ item.prefix }}…</code></th>
            <td data-label="创建时间">{{ formatDate(item.created_at) }}</td>
            <td data-label="状态">
              <span class="status-dot" :class="item.revoked_at ? 'disabled' : 'success'">{{ item.revoked_at ? '已撤销' : '有效' }}</span>
            </td>
            <td data-label="操作" class="row-actions">
              <template v-if="!item.revoked_at">
                <button v-if="item.can_reveal" class="small-button" type="button" :disabled="busy" @click="viewKey(item)">查看 / 复制</button>
                <span v-else class="muted">旧版 Key 无法显示</span>
                <button class="small-button" type="button" :disabled="busy" @click="revokeKey(item)">撤销</button>
              </template>
              <span v-else class="muted">—</span>
            </td>
          </tr>
        </tbody>
      </table>
      <div v-else class="empty-cell">
        {{ busy ? '正在加载…' : keys ? '暂无 Client Key' : '列表未加载，点击刷新重试' }}
      </div>
    </div>

    <el-dialog :model-value="Boolean(newSecret)" title="Client Key" width="min(480px, calc(100vw - 24px))"
      :close-on-click-modal="false" @update:model-value="(open) => { if (!open) newSecret = '' }">
      <el-input ref="secretInput" :model-value="newSecret" :type="revealed ? 'text' : 'password'" readonly aria-label="完整 Client Key" />
      <template #footer>
        <button class="button outline" type="button" @click="revealed = !revealed">{{ revealed ? '隐藏' : '显示' }}</button>
        <button class="button primary" type="button" @click="copyKey">复制 Key</button>
      </template>
    </el-dialog>
  </section>
</template>
