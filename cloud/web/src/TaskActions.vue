<script setup>
import { ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from './api'

const props = defineProps({ token: String, task: Object })
const emit = defineEmits(['changed', 'inspect'])
const busy = ref(false)
const labels = { pause: '暂停', resume: '继续', stop: '停止', delete: '删除' }
async function act(action) {
  if (busy.value) return
  const descriptions = {
    pause: '暂停后不会自动执行。执行中的上游请求会中断，继续时将重新发起测试。',
    stop: '停止后将中断上游请求，并保留已收到的输出和诊断数据。',
    delete: '删除任务队列记录并中断当前请求。已生成的报告可在报告管理中处理。',
  }
  busy.value = true
  try {
    if (descriptions[action]) {
      const confirmed = await ElMessageBox.confirm(descriptions[action], `${labels[action]}任务 #${props.task.id}`,
        { type: 'warning', confirmButtonText: labels[action], cancelButtonText: '取消' }).then(() => true, () => false)
      if (!confirmed) return
    }
    if (action === 'delete') await api.adminDeleteTask(props.token, props.task.id)
    else await api.controlTask(props.token, props.task.id, action)
    emit('changed')
    ElMessage.success(`任务已${labels[action] === '继续' ? '恢复排队' : labels[action]}`)
  } catch (error) { ElMessage.error(error.message) }
  finally { busy.value = false }
}
</script>

<template>
  <span class="task-actions">
    <button class="small-button" type="button" @click="emit('inspect', task)">实时详情</button>
    <template v-if="!task.owner_disabled">
      <button v-if="['queued', 'running'].includes(task.status)" class="small-button" type="button" :disabled="busy" @click="act('pause')">暂停</button>
      <button v-if="task.status === 'paused'" class="small-button" type="button" :disabled="busy" @click="act('resume')">继续</button>
      <button v-if="['queued', 'running', 'paused'].includes(task.status)" class="small-button danger" type="button" :disabled="busy" @click="act('stop')">停止</button>
    </template>
    <button class="small-button danger" type="button" :disabled="busy" @click="act('delete')">删除</button>
  </span>
</template>
