<script setup>
import { ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api } from './api'
import { formatDate } from './report-format'

const props = defineProps({
  report: { type: Object, required: true },
  token: { type: String, default: '' },
})
const emit = defineEmits(['rated', 'login'])
const draft = ref(0)
const saved = ref(0)
const ratingSaving = ref(false)
const commentSaving = ref(false)
const commentText = ref('')
const comments = ref({ items: [], total: 0 })

watch(() => props.report.my_score, (score) => { saved.value = draft.value = score ?? 0 }, { immediate: true })
watch(() => props.report.id, async (id, previous, onCleanup) => {
  const request = new AbortController()
  onCleanup(() => request.abort())
  comments.value = { items: [], total: 0 }
  commentText.value = ''
  try {
    const result = await api.comments(id, { page: 0, limit: 20 }, request.signal)
    if (!request.signal.aborted) comments.value = result
  } catch (error) { if (!request.signal.aborted) ElMessage.error(error.message) }
}, { immediate: true })

async function rate() {
  if (!props.token) { emit('login'); return }
  if (ratingSaving.value || !draft.value || draft.value === saved.value) return
  const id = props.report.id
  const session = props.token
  ratingSaving.value = true
  try {
    const result = await api.rate(session, id, draft.value)
    if (props.report.id !== id || props.token !== session) return
    saved.value = draft.value = result.score
    emit('rated', result)
    ElMessage.success('评分已保存')
  } catch (error) { ElMessage.error(error.message) }
  finally { ratingSaving.value = false }
}
async function comment() {
  if (!props.token) { emit('login'); return }
  if (commentSaving.value || !commentText.value.trim()) return
  const id = props.report.id
  commentSaving.value = true
  try {
    await api.comment(props.token, id, commentText.value.trim())
    const result = await api.comments(id, { page: 0, limit: 20 })
    if (props.report.id === id) { commentText.value = ''; comments.value = result }
  } catch (error) { ElMessage.error(error.message) }
  finally { commentSaving.value = false }
}
</script>

<template>
  <div class="report-feedback">
    <div class="rating-box">
      <div><strong>给这个测试报告打分</strong><small v-if="saved">你的评分 {{ saved }} / 5</small></div>
      <div v-if="token" class="rating-actions">
        <el-rate v-model="draft" :disabled="ratingSaving" :colors="['#eb5e3a', '#eb5e3a', '#eb5e3a']" />
        <button class="small-button filled" :disabled="ratingSaving || !draft || draft === saved" type="button" @click="rate">{{ saved ? '更新评分' : '提交评分' }}</button>
      </div>
      <button v-else class="small-button filled" type="button" @click="emit('login')">登录后评分</button>
    </div>
    <section class="comments-box">
      <h3>评论 {{ comments.total }}</h3>
      <form class="comment-form" @submit.prevent="comment">
        <el-input v-model="commentText" type="textarea" :rows="2" maxlength="2000" show-word-limit
          :placeholder="token ? '写下你的测试观察…' : '登录后可以发表评论'" :disabled="!token || commentSaving" />
        <button class="button primary" type="submit" :disabled="commentSaving">发表评论</button>
      </form>
      <div class="comment-list">
        <article v-for="item in comments.items" :key="item.id" class="comment-item">
          <div><strong>{{ item.email }}</strong><small>{{ formatDate(item.created_at) }}</small></div><p>{{ item.content }}</p>
        </article>
        <p v-if="!comments.items.length" class="comment-empty">还没有评论。</p>
      </div>
    </section>
  </div>
</template>
