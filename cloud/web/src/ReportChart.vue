<script setup>
import { computed, ref } from 'vue'
import { samplesInRange } from './report-data'

const props = defineProps({ samples: { type: Array, default: () => [] } })
const windowSize = ref(null)
const offset = ref(0)
const hovered = ref(null)
const last = computed(() => Math.max(1, props.samples.at(-1)?.seconds || 0))
const span = computed(() => Math.min(last.value, windowSize.value ?? last.value))
const start = computed(() => Math.max(0, Math.min(offset.value, last.value - span.value)))
const visible = computed(() => samplesInRange(props.samples, start.value, span.value))
const peak = computed(() => Math.max(1, Math.ceil(visible.value.reduce((max, p) => Math.max(max, p.tps), 0))))
const x = (second) => 50 + (second - start.value) / span.value * 570
const y = (tokens) => 170 - tokens / peak.value * 140
const points = computed(() => visible.value.map((p) => `${x(p.seconds)},${y(p.tps)}`).join(' '))
const selected = computed(() => visible.value.find((p) => p.seconds === hovered.value))
function zoom(factor) { windowSize.value = Math.max(Math.min(1, last.value), Math.min(last.value, span.value * factor)) }
function hover(event) {
  const matrix = event.currentTarget.getScreenCTM()
  if (!matrix) return
  const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse())
  const second = start.value + (point.x - 50) / 570 * span.value
  hovered.value = visible.value.reduce((nearest, p) => !nearest || Math.abs(p.seconds - second) < Math.abs(nearest.seconds - second) ? p : nearest, null)?.seconds
}
</script>

<template>
  <section class="live-chart" aria-label="报告吞吐曲线">
    <div class="panel-toolbar"><strong>每秒吞吐曲线</strong><span class="toolbar-actions">
      <button class="small-button" type="button" aria-label="放大报告曲线" @click="zoom(0.7)">＋</button>
      <button class="small-button" type="button" aria-label="缩小报告曲线" @click="zoom(1.4)">－</button>
      <button class="small-button" type="button" @click="windowSize = null; offset = 0">显示全部</button>
    </span></div>
    <svg v-if="samples.length" viewBox="0 0 640 210" role="img" aria-label="每秒 token 曲线，悬停查看，滚轮缩放"
      @wheel.prevent="zoom($event.deltaY > 0 ? 1.2 : 0.8)" @pointermove="hover" @pointerleave="hovered = null">
      <path d="M50 20V170H620" fill="none" stroke="var(--line)" />
      <text x="2" y="25">{{ peak }} token/s</text><text x="25" y="175">0</text>
      <text x="50" y="200">{{ start.toFixed(1) }} s</text><text x="550" y="200">{{ (start + span).toFixed(1) }} s</text>
      <polyline :points="points" fill="none" stroke="var(--coral)" stroke-width="2" />
      <circle v-if="visible.length === 1" :cx="x(visible[0].seconds)" :cy="y(visible[0].tps)" r="3" fill="var(--coral)" />
      <template v-if="selected"><line :x1="x(selected.seconds)" y1="20" :x2="x(selected.seconds)" y2="170" stroke="var(--muted)" stroke-dasharray="3 3" /><circle :cx="x(selected.seconds)" :cy="y(selected.tps)" r="4" fill="var(--coral)" /></template>
    </svg>
    <p v-else class="muted">未保存曲线采样。</p>
    <div class="chart-caption">{{ selected ? `${selected.seconds.toFixed(2)} s · ${Math.round(selected.tps).toLocaleString('en-US')} token/s` : '悬停查看每个点的 token，滚轮缩放。曲线按流式片段估算。' }}</div>
    <label v-if="last > span" class="chart-range">时间窗口<input type="range" :value="start" min="0" :max="last - span" step="0.1" aria-label="报告曲线时间窗口" @input="offset = Number($event.target.value)" /></label>
  </section>
</template>
