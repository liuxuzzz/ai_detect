<script setup>
import { computed, nextTick, onBeforeUnmount, ref } from 'vue'
import { captureFrame, reportImage, stopCapture, supportsTabCapture } from './report-image'

const props = defineProps({ reportElement: Object, model: String })
const open = ref(false)
const previewHost = ref(null)
const captureTarget = ref(null)
const source = ref('')
const frameWidth = ref(1)
const frameHeight = ref(1)
const availableWidth = ref(1)
const availableHeight = ref(1)
const revision = ref(0)
const busy = ref(false)
const error = ref('')
const copied = ref(false)
const imageUrl = ref('')
const capturing = ref(false)
const canCapture = supportsTabCapture()
const canCopy = typeof navigator.clipboard?.write === 'function' && typeof globalThis.ClipboardItem === 'function'
const scale = computed(() => Math.min(1, availableWidth.value / frameWidth.value, availableHeight.value / frameHeight.value))
const filename = computed(() => `AI质量检测-${(props.model || '报告').replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_').slice(0, 100)}.png`)

let operation, stream, blob, resizeObserver

function clearImage() {
  if (imageUrl.value) URL.revokeObjectURL(imageUrl.value)
  imageUrl.value = ''
  blob = null
  copied.value = false
}

function close() {
  operation?.abort()
  operation = null
  stopCapture(stream)
  stream = null
  resizeObserver?.disconnect()
  clearImage()
  busy.value = false
  capturing.value = false
}

async function show() {
  const frame = props.reportElement?.querySelector('.report-model-preview iframe')
  source.value = frame?.srcdoc || ''
  if (frame) {
    const size = frame.getBoundingClientRect()
    frameWidth.value = Math.max(1, size.width)
    frameHeight.value = Math.max(1, size.height)
  }
  error.value = ''
  open.value = true
  if (!frame) await generate()
}

async function observePreview() {
  resizeObserver?.disconnect()
  await nextTick()
  if (!previewHost.value) return
  resizeObserver = new ResizeObserver(([entry]) => {
    availableWidth.value = entry.contentRect.width
    availableHeight.value = entry.contentRect.height
  })
  resizeObserver.observe(previewHost.value)
}

function resetPreview() {
  clearImage()
  error.value = ''
  revision.value++
  observePreview()
}

async function allowCapture() {
  const request = new AbortController()
  operation = request
  busy.value = true
  error.value = ''
  try {
    const selected = await navigator.mediaDevices.getDisplayMedia({
      audio: false, video: { displaySurface: 'browser' },
      preferCurrentTab: true, selfBrowserSurface: 'include', surfaceSwitching: 'exclude', monitorTypeSurfaces: 'exclude',
    })
    if (request.signal.aborted) {
      stopCapture(selected)
      return
    }
    const track = selected.getVideoTracks()[0]
    if (track?.getSettings().displaySurface !== 'browser' || typeof track.cropTo !== 'function') {
      stopCapture(selected)
      throw new Error('请选择当前报告标签页')
    }
    stream = selected
    capturing.value = true
    track.addEventListener('ended', () => {
      if (stream === selected) {
        stream = null
        capturing.value = false
      }
    }, { once: true })
  } catch (failure) {
    if (!request.signal.aborted) {
      error.value = failure.name === 'NotAllowedError' ? '未授权标签页捕获' : failure.message
    }
  } finally {
    if (!request.signal.aborted) busy.value = false
  }
}

async function generate() {
  if (busy.value) return
  const request = new AbortController()
  operation = request
  busy.value = true
  error.value = ''
  try {
    let frameImage
    if (source.value) {
      frameImage = await captureFrame(stream, captureTarget.value, request.signal)
      stopCapture(stream)
      stream = null
      capturing.value = false
    }
    const result = await reportImage(props.reportElement, frameImage, request.signal)
    blob = result
    imageUrl.value = URL.createObjectURL(result)
  } catch (failure) {
    if (!request.signal.aborted) error.value = failure.message
  } finally {
    if (!request.signal.aborted) {
      stopCapture(stream)
      stream = null
      capturing.value = false
      busy.value = false
    }
  }
}

async function copy() {
  try {
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
    copied.value = true
    error.value = ''
  } catch {
    error.value = '浏览器未能写入剪贴板，可以下载 PNG'
  }
}

onBeforeUnmount(close)
</script>

<template>
  <button class="button outline" type="button" data-image-exclude @click="show">分享为图片</button>
  <el-dialog v-model="open" title="分享报告图片" class="report-image-dialog" width="min(960px, calc(100vw - 24px))"
    append-to-body destroy-on-close @opened="observePreview" @close="close">
    <img v-if="imageUrl" class="report-image-result" :src="imageUrl" alt="整页报告图片预览" />
    <template v-else-if="source">
      <p class="muted">{{ capturing ? '动画运行到想要的画面时，点击「截取当前画面」。' : '可以重播动画。允许捕获后，在浏览器中选择当前报告标签页。' }}</p>
      <div ref="previewHost" class="report-image-stage">
        <div ref="captureTarget" class="report-image-target" :style="{ width: `${frameWidth * scale}px`, height: `${frameHeight * scale}px` }">
          <iframe :key="revision" title="截图动画预览" sandbox="allow-scripts" :srcdoc="source"
            :style="{ width: `${frameWidth}px`, height: `${frameHeight}px`, transform: `scale(${scale})` }" />
        </div>
      </div>
      <p v-if="!canCapture" class="muted">动画截图需要支持标签页区域捕获的 Chrome 或 Edge，并通过 HTTPS 打开报告。</p>
    </template>
    <p v-if="busy" role="status">{{ source && !capturing && !imageUrl ? '正在准备截图…' : '正在生成报告图片…' }}</p>
    <p v-if="error" class="monitor-error" role="alert">{{ error }}</p>
    <template #footer>
      <div class="report-image-actions">
        <template v-if="imageUrl">
          <button v-if="source" class="button outline" type="button" @click="resetPreview">重新取景</button>
          <button v-if="canCopy" class="button outline" type="button" @click="copy">{{ copied ? '已复制' : '复制图片' }}</button>
          <a class="button primary" :href="imageUrl" :download="filename">下载 PNG</a>
        </template>
        <template v-else-if="source">
          <button class="button outline" type="button" :disabled="busy" @click="resetPreview">重新播放</button>
          <button v-if="capturing" class="button primary" type="button" :disabled="busy" @click="generate">截取当前画面</button>
          <button v-else-if="canCapture" class="button primary" type="button" :disabled="busy" @click="allowCapture">允许捕获标签页</button>
        </template>
        <button v-else-if="error" class="button primary" type="button" :disabled="busy" @click="generate">重试</button>
      </div>
    </template>
  </el-dialog>
</template>
