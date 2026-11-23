<script setup>
import { computed, ref } from 'vue'

const props = defineProps({ samples: { type: Array, default: () => [] } })
const windowSize = ref(60)
const offset = ref(null)
const hovered = ref(null)
const last = computed(() => Math.max(1, props.samples.length - 1))
const span = computed(() => Math.min(last.value, windowSize.value))
const start = computed(() => offset.value == null ? Math.max(0, last.value - span.value) : Math.min(offset.value, last.value - span.value))
const visible = computed(() => props.samples.slice(start.value, start.value + span.value + 1).map((tokens, index) => ({ second: start.value + index, tokens })))
const peak = computed(() => Math.max(1, ...visible.value.map((point) => point.tokens)))
const points = computed(() => visible.value.map((point) => `${x(point.second)},${y(point.tokens)}`).join(' '))
const x = (second) => 46 + (second - start.value) / Math.max(1, span.value) * 576
const y = (tokens) => 145 - tokens / peak.value * 125
const selected = computed(() => visible.value.find((point) => point.second === hovered.value))
function zoom(factor) { windowSize.value = Math.max(2, Math.min(Math.max(60, last.value), Math.round(span.value * factor))) }
function hover(event) {
  const rect = event.currentTarget.getBoundingClientRect()
  const position = (event.clientX - rect.left) / rect.width * 640
  hovered.value = Math.max(start.value, Math.min(last.value, Math.round(start.value + (position - 46) / 576 * span.value)))
}
</script>

<template>
  <section class="live-chart" aria-label="实时吞吐曲线">
    <div class="panel-toolbar">
      <strong>每秒吞吐</strong>
      <span class="toolbar-actions">
        <button class="small-button" type="button" aria-label="放大曲线" @click="zoom(0.7)">＋</button>
        <button class="small-button" type="button" aria-label="缩小曲线" @click="zoom(1.4)">－</button>
        <button class="small-button" type="button" @click="offset = null; windowSize = 60">跟随最新</button>
      </span>
    </div>
    <svg viewBox="0 0 640 180" role="img" aria-label="吞吐曲线，悬停查看 token，滚轮缩放" @wheel.prevent="zoom($event.deltaY > 0 ? 1.2 : 0.8)" @pointermove="hover" @pointerleave="hovered = null">
      <path d="M46 15V145H622" fill="none" stroke="var(--line)" />
      <text x="4" y="25">{{ peak }}</text><text x="18" y="148">0</text>
      <text x="46" y="172">{{ start }} s</text><text x="574" y="172">{{ Math.min(last, start + span) }} s</text>
      <polyline :points="points" fill="none" stroke="var(--coral)" stroke-width="2" />
      <template v-if="selected">
        <line :x1="x(selected.second)" y1="15" :x2="x(selected.second)" y2="145" stroke="var(--muted)" stroke-dasharray="3 3" />
        <circle :cx="x(selected.second)" :cy="y(selected.tokens)" r="4" fill="var(--coral)" />
      </template>
    </svg>
    <div class="chart-caption"><span>{{ selected ? `${selected.second} s · ${selected.tokens} token/s` : '按流式片段估算；悬停查看，滚轮缩放。' }}</span></div>
    <label v-if="last > span" class="chart-range">时间窗口<input type="range" :value="start" min="0" :max="last - span" step="1" aria-label="曲线时间窗口" @input="offset = Number($event.target.value)" /></label>
  </section>
</template>
