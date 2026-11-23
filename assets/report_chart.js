(() => {
  const chart = document.querySelector('.chart');
  const svg = chart?.querySelector('svg');
  if (!svg || chart.dataset.interactive) return;

  const samples = Array.from(svg.querySelectorAll('.sample-point'), (dot) => {
    if (dot.dataset.seconds != null && dot.dataset.tps != null) {
      return { seconds: Number(dot.dataset.seconds), tps: Number(dot.dataset.tps) };
    }
    const match = dot.querySelector('title')?.textContent.match(/^([\d,.]+) s · ([\d,.]+) token\/s$/);
    return match && { seconds: Number(match[1].replaceAll(',', '')), tps: Number(match[2].replaceAll(',', '')) };
  }).filter((point) => point && Number.isFinite(point.seconds) && Number.isFinite(point.tps))
    .sort((first, second) => first.seconds - second.seconds);
  if (!samples.length) return;
  chart.dataset.interactive = 'true';

  const formatTime = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const formatTokens = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  const fullEnd = Math.max(1, samples.at(-1).seconds + 1);
  const left = 80, right = 860, top = 30, bottom = 350;
  const plotWidth = right - left;
  let start = 0, width = fullEnd, drag, hover, visible, xFor, yFor;

  const toolbar = document.createElement('div');
  toolbar.style.cssText = 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px';
  const range = document.createElement('span');
  range.style.marginInlineEnd = 'auto';
  toolbar.append(range);
  const button = (label, title, action) => {
    const control = document.createElement('button');
    control.type = 'button';
    control.textContent = label;
    control.title = title;
    control.setAttribute('aria-label', title);
    control.addEventListener('click', action);
    toolbar.append(control);
    return control;
  };
  const zoomIn = button('＋', '放大曲线', () => zoom(0.5));
  const zoomOut = button('－', '缩小曲线', () => zoom(2));
  const reset = button('全量', '显示完整曲线', () => setView(0, fullEnd));
  chart.before(toolbar);
  chart.style.height = 'auto';
  svg.style.cssText = 'display:block;width:100%;height:auto;touch-action:pan-y';
  svg.setAttribute('viewBox', '0 0 900 400');
  svg.setAttribute('aria-label', '每秒吞吐曲线，可滚轮缩放，拖动平移，悬停或点按查看采样点');

  function node(tag, attrs, parent, text) {
    const element = document.createElementNS(svg.namespaceURI, tag);
    for (const [name, value] of Object.entries(attrs)) element.setAttribute(name, value);
    if (text != null) element.textContent = text;
    parent.append(element);
    return element;
  }

  function draw() {
    svg.replaceChildren();
    const end = start + width;
    visible = samples.filter((point) => point.seconds >= start && point.seconds <= end);
    const lineSamples = samples.filter((point) => point.seconds >= Math.floor(start) && point.seconds <= Math.ceil(end));
    const peak = lineSamples.reduce((max, point) => Math.max(max, point.tps), 0);
    const step = Math.max(1, Math.ceil(peak * 1.15 / 4));
    const maxY = step * 4;
    xFor = (seconds) => left + (seconds - start) / width * plotWidth;
    yFor = (tps) => bottom - tps / maxY * (bottom - top);
    const axisText = { fill: '#71808b', 'font-size': 14 };
    const line = (x1, y1, x2, y2, stroke) => node('line', { x1, y1, x2, y2, stroke }, svg);
    for (let index = 0; index <= 4; index++) {
      const tps = index * step;
      const height = yFor(tps);
      line(left, height, right, height, '#dfe6e3');
      node('text', { ...axisText, x: left - 10, y: height + 4, 'text-anchor': 'end' }, svg, formatTokens.format(tps));
    }
    for (let index = 0; index <= 5; index++) {
      const seconds = start + width * index / 5;
      const position = xFor(seconds);
      line(position, top, position, bottom, '#edf1ef');
      node('text', { ...axisText, x: position, y: bottom + 20, 'text-anchor': 'middle' }, svg, formatTime.format(seconds));
    }
    line(left, top, left, bottom, '#71808b');
    line(left, bottom, right, bottom, '#71808b');
    node('text', { ...axisText, x: 470, y: 393, 'text-anchor': 'middle' }, svg, '时间 (s)');
    node('text', { ...axisText, x: 16, y: 190, 'text-anchor': 'middle', transform: 'rotate(-90 16 190)' }, svg, 'Token/s');

    const plot = node('svg', { x: left, y: top, width: plotWidth, height: bottom - top, overflow: 'hidden' }, svg);
    node('polyline', {
      fill: 'none', stroke: '#087f70', 'stroke-width': 1.25, 'vector-effect': 'non-scaling-stroke',
      points: lineSamples.map((point) => `${xFor(point.seconds) - left},${yFor(point.tps) - top}`).join(' '),
    }, plot);
    if (visible.length <= 120) {
      for (const point of visible) node('circle', { cx: xFor(point.seconds) - left, cy: yFor(point.tps) - top, r: 1.5, fill: '#087f70' }, plot);
    }
    hover = node('g', { 'pointer-events': 'none' }, svg);
    range.textContent = `${formatTime.format(start)}–${formatTime.format(end)} s`;
    zoomIn.disabled = width <= 1;
    zoomOut.disabled = reset.disabled = width >= fullEnd;
    svg.style.cursor = width < fullEnd ? 'grab' : 'crosshair';
  }

  function setView(nextStart, nextWidth) {
    width = Math.max(1, Math.min(fullEnd, nextWidth));
    start = Math.max(0, Math.min(fullEnd - width, nextStart));
    draw();
  }

  function zoom(factor, anchor = 0.5) {
    const nextWidth = Math.max(1, Math.min(fullEnd, width * factor));
    setView(start + (width - nextWidth) * anchor, nextWidth);
  }

  function location(event) {
    const matrix = svg.getScreenCTM();
    return matrix && new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
  }

  function inside(point) {
    return point && point.x >= left && point.x <= right && point.y >= top && point.y <= bottom;
  }

  function showPoint(point) {
    hover.replaceChildren();
    if (!inside(point) || !visible.length) return;
    const seconds = start + (point.x - left) / plotWidth * width;
    const sample = visible.reduce((nearest, candidate) =>
      Math.abs(candidate.seconds - seconds) < Math.abs(nearest.seconds - seconds) ? candidate : nearest);
    const sampleX = xFor(sample.seconds), sampleY = yFor(sample.tps);
    node('line', { x1: sampleX, x2: sampleX, y1: top, y2: bottom, stroke: '#71808b', 'stroke-dasharray': '4 4' }, hover);
    node('circle', { cx: sampleX, cy: sampleY, r: 4, fill: '#087f70', stroke: '#fff' }, hover);
    const tooltipX = sampleX > right - 165 ? sampleX - 164 : sampleX + 8;
    const tooltipY = Math.max(top, Math.min(bottom - 52, sampleY - 55));
    node('rect', { x: tooltipX, y: tooltipY, width: 156, height: 46, rx: 5, fill: '#1c2933' }, hover);
    node('text', { x: tooltipX + 10, y: tooltipY + 18, fill: '#fff', 'font-size': 14 }, hover, `${formatTime.format(sample.seconds)} s`);
    node('text', { x: tooltipX + 10, y: tooltipY + 36, fill: '#fff', 'font-size': 14 }, hover, `${formatTokens.format(sample.tps)} token/s`);
  }

  svg.addEventListener('wheel', (event) => {
    const point = location(event);
    if (!inside(point) || !event.deltaY || (event.deltaY < 0 ? width <= 1 : width >= fullEnd)) return;
    event.preventDefault();
    zoom(event.deltaY < 0 ? 0.8 : 1.25, (point.x - left) / plotWidth);
    showPoint(point);
  }, { passive: false });
  svg.addEventListener('pointerdown', (event) => {
    const point = location(event);
    if (!inside(point) || event.button !== 0) return;
    showPoint(point);
    if (width >= fullEnd) return;
    drag = { id: event.pointerId, x: point.x, start };
    svg.setPointerCapture(event.pointerId);
  });
  svg.addEventListener('pointermove', (event) => {
    const point = location(event);
    if (drag?.id === event.pointerId && point) {
      setView(drag.start - (point.x - drag.x) / plotWidth * width, width);
      svg.style.cursor = 'grabbing';
    } else {
      showPoint(point);
    }
  });
  svg.addEventListener('lostpointercapture', () => {
    drag = null;
    svg.style.cursor = 'grab';
  });
  svg.addEventListener('pointerleave', () => hover.replaceChildren());
  draw();
})();
