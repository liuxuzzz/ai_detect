<script setup>
import { reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api } from './api'

const props = defineProps({ token: String, items: Array, formatDate: Function })
const emit = defineEmits(['changed'])
const editing = ref(false)
const saving = ref(false)
const form = reactive({ id: null, name: '', content: '', enabled: true })

function edit(prompt = null) {
  Object.assign(form, prompt || { id: null, name: '', content: '', enabled: true })
  editing.value = true
}
async function save() {
  if (saving.value) return
  saving.value = true
  try {
    if (form.id) await api.updatePrompt(props.token, form.id, form)
    else await api.createPrompt(props.token, form)
    editing.value = false
    emit('changed')
    ElMessage.success('提示词已保存')
  } catch (error) { ElMessage.error(error.message) }
  finally { saving.value = false }
}
async function remove(prompt) {
  const confirmed = await ElMessageBox.confirm(`确认删除“${prompt.name}”吗？已提交的任务保留原提示词。`, '删除提示词',
    { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' }).then(() => true, () => false)
  if (!confirmed) return
  try {
    await api.deletePrompt(props.token, prompt.id)
    emit('changed')
    ElMessage.success('提示词已删除')
  } catch (error) { ElMessage.error(error.message) }
}
</script>

<template>
  <section aria-label="提示词管理">
    <div class="panel-toolbar prompt-toolbar">
      <span class="muted">用户可选择、预览公共提示词，正文由管理员维护。</span>
      <button class="button primary" type="button" @click="edit()">添加提示词</button>
    </div>
    <table class="data-table work-table" aria-label="公共提示词列表">
      <thead><tr><th>提示词</th><th>状态</th><th>更新时间</th><th>操作</th></tr></thead>
      <tbody><tr v-for="prompt in items" :key="prompt.id">
        <th scope="row"><strong>{{ prompt.name }}</strong><span class="cell-note prompt-excerpt">{{ prompt.content }}</span></th>
        <td data-label="状态">{{ prompt.enabled ? '已启用' : '已停用' }}</td>
        <td data-label="更新时间">{{ formatDate(prompt.updated_at) }}</td>
        <td class="row-actions" data-label="操作">
          <button class="small-button" type="button" @click="edit(prompt)">查看 / 编辑</button>
          <button class="small-button danger" type="button" @click="remove(prompt)">删除</button>
        </td>
      </tr></tbody>
    </table>
    <el-dialog v-model="editing" :title="form.id ? '编辑提示词' : '添加提示词'" width="min(680px, calc(100vw - 24px))" :close-on-click-modal="false" :show-close="!saving" :close-on-press-escape="!saving">
      <form class="dialog-form" @submit.prevent="save">
        <label>名称<input v-model="form.name" required maxlength="100" :disabled="saving" /></label>
        <label>提示词正文<textarea v-model="form.content" required rows="14" :disabled="saving" /></label>
        <label class="check-label"><input v-model="form.enabled" type="checkbox" :disabled="saving" />允许用户选择</label>
        <button class="button primary" type="submit" :disabled="saving">{{ saving ? '正在保存…' : '保存提示词' }}</button>
      </form>
    </el-dialog>
  </section>
</template>
