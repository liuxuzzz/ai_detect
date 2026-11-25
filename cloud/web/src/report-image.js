const projectUrl = 'https://github.com/liuxuzzz/ai_detect'

export function supportsTabCapture() {
  return typeof globalThis.CropTarget?.fromElement === 'function'
    && typeof navigator.mediaDevices?.getDisplayMedia === 'function'
}

export function stopCapture(stream) {
  for (const track of stream?.getTracks() || []) track.stop()
}

export async function captureFrame(stream, target, signal) {
  const track = stream.getVideoTracks()[0]
  if (track?.getSettings().displaySurface !== 'browser' || typeof track.cropTo !== 'function') {
    throw new Error('请在浏览器的共享窗口中选择当前报告标签页')
  }
  try {
    await track.cropTo(await CropTarget.fromElement(target))
  } catch {
    throw new Error('无法捕获预览区域，请重新选择当前报告标签页')
  }
  const deadline = AbortSignal.any([signal, AbortSignal.timeout(5000)])
  deadline.throwIfAborted()

  const video = document.createElement('video')
  video.muted = true
  video.playsInline = true
  video.srcObject = stream
  let onAbort
  try {
    // This video is attached after cropTo resolves, so its first frame is cropped.
    const aborted = new Promise((_, reject) => {
      onAbort = () => reject(new Error('等待预览画面超时，请重试'))
      deadline.addEventListener('abort', onAbort, { once: true })
    })
    await Promise.race([video.play(), aborted])
    deadline.throwIfAborted()
    const canvas = document.createElement('canvas')
    canvas.width = video.videoWidth
    canvas.height = video.videoHeight
    canvas.getContext('2d').drawImage(video, 0, 0)
    return canvas.toDataURL('image/png')
  } finally {
    deadline.removeEventListener('abort', onAbort)
    video.pause()
    video.srcObject = null
  }
}

async function watermark() {
  const { default: QRCode } = await import('qrcode')
  const site = new URL('/', location.href).href
  const footer = document.createElement('footer')
  footer.className = 'report-image-watermark'
  const qr = new Image(112, 112)
  qr.alt = '云端网站二维码'
  qr.src = await QRCode.toDataURL(site, { scale: 6 })
  await qr.decode()
  const labels = document.createElement('div')
  const title = document.createElement('strong')
  title.textContent = 'AI质量检测'
  labels.append(title)
  for (const label of [site, projectUrl]) {
    const line = document.createElement('div')
    line.textContent = label
    labels.append(line)
  }
  footer.append(labels, qr)
  return footer
}

export async function reportImage(report, frameImage, signal) {
  const [{ toBlob }, footer] = await Promise.all([import('html-to-image'), watermark()])
  signal.throwIfAborted()
  if (!report?.isConnected) throw new Error('报告已关闭')
  const width = report.getBoundingClientRect().width
  const snapshot = report.cloneNode(true)
  snapshot.querySelectorAll('[data-image-exclude]').forEach(node => node.remove())
  const frame = snapshot.querySelector('.report-model-preview iframe')
  if (frame) {
    if (!frameImage) throw new Error('请先截取模型输出的画面')
    const still = new Image()
    still.alt = '模型输出截图'
    still.className = 'report-image-frame'
    still.src = frameImage
    await still.decode()
    signal.throwIfAborted()
    frame.replaceWith(still)
  }
  snapshot.append(footer)
  snapshot.classList.add('report-image-export')
  const staging = document.createElement('div')
  staging.className = 'report-image-staging'
  staging.style.width = `${width}px`
  staging.inert = true
  staging.append(snapshot)
  document.body.append(staging)
  try {
    const { height } = snapshot.getBoundingClientRect()
    const pixelRatio = Math.min(2, 16000 / Math.max(width, height), Math.sqrt(24_000_000 / (width * height)))
    const blob = await toBlob(snapshot, {
      backgroundColor: '#fff', pixelRatio, skipFonts: true,
    })
    signal.throwIfAborted()
    if (!blob) throw new Error('无法生成报告图片')
    return blob
  } finally {
    staging.remove()
  }
}
