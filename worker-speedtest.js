export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return new Response(HTML, {
        headers: {
          "content-type": "text/html;charset=UTF-8",
          "cache-control": "public, max-age=3600, stale-while-revalidate=86400"
        }
      });
    }

    return new Response("Not found", { status: 404 });
  }
};

const HTML = `
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EDGE SPEEDTEST</title>
<style>
  :root{
    --bg: #0b0e11;
    --panel: #12161b;
    --panel-2: #171c22;
    --line: #232a31;
    --text: #e6edf3;
    --muted: #7d8590;
    --cyan: #00d9c0;
    --amber: #ffb454;
    --red: #ff6b6b;
  }
  *{box-sizing:border-box;}
  html,body{margin:0;padding:0;background:var(--bg);color:var(--text);}
  body{
    font-family: 'Inter', system-ui, -apple-system, sans-serif;
    min-height:100vh;
    display:flex;
    align-items:center;
    justify-content:center;
    padding:24px;
  }
  .rig{
    width:100%;
    max-width:720px;
  }
  .eyebrow{
    font-family:'JetBrains Mono', monospace;
    font-size:12px;
    letter-spacing:0.12em;
    color:var(--muted);
    text-transform:uppercase;
    display:flex;
    justify-content:space-between;
    margin-bottom:10px;
  }
  .eyebrow .dot{color:var(--cyan);}
  .panel{
    background:var(--panel);
    border:1px solid var(--line);
    border-radius:2px;
    padding:0;
    overflow:hidden;
  }
  .gauge-wrap{
    position:relative;
    border-bottom:1px solid var(--line);
    background:var(--panel);
    display:flex;
    flex-direction:column;
    align-items:center;
    padding:18px 14px 4px;
  }
  .gauge-wrap svg{
    width:100%;
    max-width:440px;
    height:auto;
    display:block;
  }
  .gauge-phase-tag{
    font-family:'JetBrains Mono', monospace;
    font-size:11px;
    color:var(--muted);
    text-transform:uppercase;
    letter-spacing:0.1em;
    margin-top:-6px;
    margin-bottom:10px;
  }
  .gauge-tick-label{
    font-family:'JetBrains Mono', monospace;
    font-size:11px;
    fill:var(--muted);
  }
  .stats{
    display:grid;
    grid-template-columns:repeat(4,1fr);
  }
  .stat{
    padding:16px 14px;
    border-right:1px solid var(--line);
  }
  .stat:last-child{border-right:none;}
  .stat .label{
    font-family:'JetBrains Mono', monospace;
    font-size:10px;
    color:var(--muted);
    text-transform:uppercase;
    letter-spacing:0.1em;
    margin-bottom:6px;
  }
  .stat .value{
    font-family:'JetBrains Mono', monospace;
    font-size:20px;
    font-weight:600;
  }
  .stat .value.dl{color:var(--cyan);}
  .stat .value.ul{color:var(--amber);}
  .stat .value small{
    font-size:11px;
    color:var(--muted);
    font-weight:400;
    margin-left:3px;
  }
  .controls{
    display:flex;
    align-items:center;
    justify-content:space-between;
    padding:14px;
    border-top:1px solid var(--line);
    background:var(--panel-2);
  }
  .status{
    font-family:'JetBrains Mono', monospace;
    font-size:12px;
    color:var(--muted);
  }
  button{
    font-family:'JetBrains Mono', monospace;
    font-size:12px;
    letter-spacing:0.08em;
    text-transform:uppercase;
    background:var(--cyan);
    color:#04211d;
    border:none;
    padding:10px 20px;
    border-radius:2px;
    cursor:pointer;
    font-weight:700;
  }
  button:disabled{
    background:var(--line);
    color:var(--muted);
    cursor:default;
  }
  .footnote{
    margin-top:14px;
    font-family:'JetBrains Mono', monospace;
    font-size:11px;
    color:var(--muted);
    line-height:1.6;
  }
  @media (max-width:520px){
    .stats{grid-template-columns:repeat(2,1fr);}
    .stat:nth-child(2){border-right:none;}
  }
</style>
</head>
<body>

<div class="rig">
  <div class="eyebrow">
    <span>Edge Integrated Speedtest <span id="version-tag"></span> <span class="dot">&bull;</span> powered by Cloudflare</span>
  </div>

  <div class="panel">
    <div class="gauge-wrap">
      <svg id="gauge" viewBox="0 0 400 320" xmlns="http://www.w3.org/2000/svg">
        <path id="gauge-track" fill="none" stroke="#232a31" stroke-width="14" stroke-linecap="round"></path>
        <path id="gauge-fill" fill="none" stroke="#00d9c0" stroke-width="14" stroke-linecap="round"></path>
        <g id="gauge-ticks"></g>
        <line id="gauge-needle" x1="200" y1="200" x2="200" y2="65" stroke="#e6edf3" stroke-width="3" stroke-linecap="round"></line>
        <circle cx="200" cy="200" r="7" fill="#e6edf3"></circle>
      </svg>
      <div class="gauge-phase-tag" id="stream-text">&nbsp;</div>
    </div>

    <div class="stats">
      <div class="stat">
        <div class="label">Download</div>
        <div class="value dl" id="dl-result">&mdash;</div>
      </div>
      <div class="stat">
        <div class="label">Upload</div>
        <div class="value ul" id="ul-result">&mdash;</div>
      </div>
      <div class="stat">
        <div class="label">Latency</div>
        <div class="value" id="lat-result">&mdash;</div>
      </div>
      <div class="stat">
        <div class="label">Jitter</div>
        <div class="value" id="jit-result">&mdash;</div>
      </div>
    </div>

    <div class="controls">
      <div class="status">
        <span id="status-text">ready</span>
      </div>
      <button id="start-btn">Run Test</button>
    </div>
  </div>

  <div class="footnote">
    Measures against Cloudflare's public edge network using ramped parallel streams
    held open long enough to reach steady-state throughput, rather than Cloudflare's
    own light-touch quality sampling. Results reflect a saturating, multi-connection
    test similar in spirit to traditional ISP speed tests.
  </div>
</div>

<script>
// Edge Integrated Speedtest -- changelog
//   v1.0  Initial multi-stream saturation test against speed.cloudflare.com
//   v1.1  Needle-gauge UI (replaces oscilloscope trace), speedtest.net tick
//         scale, upper-biased scoring, version tag, Workers Cache enabled
//   v1.2  Score from the EMA-smoothed series (top 90%) instead of raw
//         samples -- matches what the needle actually shows
//   v1.3  Median-of-3 despike filter before the EMA -- the speedtest.net
//         tick scale compressed the 500-1000 Mbps segment, making the
//         needle oversensitive to momentary burst artifacts right in the
//         range a symmetric gigabit connection sits in
(() => {
  const VERSION = 'v1.3';

  const DOWN_URL = 'https://speed.cloudflare.com/__down';
  const UP_URL = 'https://speed.cloudflare.com/__up';

  const MAX_STREAMS = 8;
  const RAMP_STEP_MS = 900;
  const STREAMS_PER_STEP = 3;
  const STEADY_MS = 10000;
  const DOWN_CHUNK_BYTES = 32 * 1000 * 1000;
  const UP_CHUNK_BYTES = 16 * 1000 * 1000;
  const SAMPLE_MS = 300;
  const DISPLAY_SMOOTHING = 0.16;

  const MBPS_TICKS = [0, 5, 10, 50, 100, 250, 500, 750, 1000];
  const MS_TICKS = [0, 10, 25, 50, 100, 150, 200, 300, 500];

  const el = (id) => document.getElementById(id);
  const startBtn = el('start-btn');
  const statusText = el('status-text');
  const streamText = el('stream-text');
  const dlResult = el('dl-result');
  const ulResult = el('ul-result');
  const latResult = el('lat-result');
  const jitResult = el('jit-result');
  const gaugeFillEl = el('gauge-fill');
  const gaugeTrackEl = el('gauge-track');
  const gaugeNeedleEl = el('gauge-needle');
  const gaugeTicksEl = el('gauge-ticks');

  const G = { cx: 200, cy: 200, radius: 150, minAngle: -125, maxAngle: 125 };
  const gaugeState = { ticks: MBPS_TICKS, currentAngle: -125, targetAngle: -125, color: '#00d9c0' };

  function polarToCartesian(cx, cy, r, angleDeg){
    const rad = angleDeg * Math.PI / 180;
    return { x: cx + r * Math.sin(rad), y: cy - r * Math.cos(rad) };
  }

  function buildArcPath(cx, cy, r, startAngle, endAngle, steps){
    steps = steps || 48;
    if (endAngle < startAngle) endAngle = startAngle;
    let d = '';
    for (let i = 0; i <= steps; i++){
      const a = startAngle + (endAngle - startAngle) * (i / steps);
      const p = polarToCartesian(cx, cy, r, a);
      d += (i === 0 ? 'M' : 'L') + p.x.toFixed(2) + ',' + p.y.toFixed(2) + ' ';
    }
    return d.trim();
  }

  function valueToAngle(value, ticks){
    const lo = ticks[0], hi = ticks[ticks.length - 1];
    const v = Math.max(lo, Math.min(hi, value));
    const segCount = ticks.length - 1;
    const segAngle = (G.maxAngle - G.minAngle) / segCount;
    for (let i = 0; i < segCount; i++){
      if (v <= ticks[i + 1] || i === segCount - 1){
        const span = (ticks[i + 1] - ticks[i]) || 1;
        const t = (v - ticks[i]) / span;
        return G.minAngle + i * segAngle + t * segAngle;
      }
    }
    return G.maxAngle;
  }

  function drawTicks(ticks){
    gaugeTicksEl.innerHTML = '';
    ticks.forEach(v => {
      const a = valueToAngle(v, ticks);
      const p1 = polarToCartesian(G.cx, G.cy, G.radius + 12, a);
      const p2 = polarToCartesian(G.cx, G.cy, G.radius + 2, a);
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      line.setAttribute('x1', p1.x.toFixed(2));
      line.setAttribute('y1', p1.y.toFixed(2));
      line.setAttribute('x2', p2.x.toFixed(2));
      line.setAttribute('y2', p2.y.toFixed(2));
      line.setAttribute('stroke', '#7d8590');
      line.setAttribute('stroke-width', '2');
      gaugeTicksEl.appendChild(line);

      const lp = polarToCartesian(G.cx, G.cy, G.radius + 28, a);
      const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      text.setAttribute('x', lp.x.toFixed(2));
      text.setAttribute('y', lp.y.toFixed(2));
      text.setAttribute('text-anchor', 'middle');
      text.setAttribute('class', 'gauge-tick-label');
      text.textContent = String(v);
      gaugeTicksEl.appendChild(text);
    });
  }

  function setGaugeScale(ticks, unit, color){
    gaugeState.ticks = ticks;
    gaugeState.color = color;
    gaugeFillEl.setAttribute('stroke', color);
    gaugeNeedleEl.setAttribute('stroke', color);
    drawTicks(ticks);
    gaugeState.targetAngle = G.minAngle;
  }

  function setGaugeValue(value){
    gaugeState.targetAngle = valueToAngle(value, gaugeState.ticks);
  }

  function animateGauge(){
    const diff = gaugeState.targetAngle - gaugeState.currentAngle;
    gaugeState.currentAngle += diff * 0.09;
    if (Math.abs(diff) < 0.05) gaugeState.currentAngle = gaugeState.targetAngle;
    gaugeNeedleEl.setAttribute('transform', 'rotate(' + gaugeState.currentAngle.toFixed(2) + ' ' + G.cx + ' ' + G.cy + ')');
    gaugeFillEl.setAttribute('d', buildArcPath(G.cx, G.cy, G.radius, G.minAngle, gaugeState.currentAngle));
    requestAnimationFrame(animateGauge);
  }

  function initGauge(){
    gaugeTrackEl.setAttribute('d', buildArcPath(G.cx, G.cy, G.radius, G.minAngle, G.maxAngle));
    setGaugeScale(MBPS_TICKS, 'MBPS', '#00d9c0');
    requestAnimationFrame(animateGauge);
  }

  function percentile(arr, p){
    if (!arr.length) return 0;
    const sorted = arr.slice().sort((a, b) => a - b);
    const idx = Math.min(sorted.length - 1, Math.floor(p * sorted.length));
    return sorted[idx];
  }

  function median3(arr){
    const s = arr.slice().sort((a, b) => a - b);
    return s[Math.floor(s.length / 2)];
  }

  async function measureLatency(){
    statusText.textContent = 'measuring idle latency';
    setGaugeScale(MS_TICKS, 'MS', '#e6edf3');
    const times = [];
    for (let i = 0; i < 16; i++){
      const t0 = performance.now();
      try {
        await fetch(DOWN_URL + '?bytes=0&r=' + Math.random(), { cache: 'no-store', mode: 'cors' });
      } catch(e) { continue; }
      const dt = performance.now() - t0;
      times.push(dt);
      setGaugeValue(dt);
      await new Promise(r => setTimeout(r, 80));
    }
    const med = percentile(times, 0.5);
    const jitter = times.length > 1
      ? times.slice(1).reduce((s,v,i)=> s + Math.abs(v - times[i]), 0) / (times.length - 1)
      : 0;
    latResult.innerHTML = med.toFixed(0) + '<small>ms</small>';
    jitResult.innerHTML = jitter.toFixed(1) + '<small>ms</small>';
    return { med, jitter };
  }

  async function runSaturationTest(direction){
    setGaugeScale(MBPS_TICKS, 'MBPS', direction === 'down' ? '#00d9c0' : '#ffb454');
    let byteCounter = 0;
    let stop = false;
    let activeStreams = 0;
    const bump = (n) => { byteCounter += n; };

    async function downloadWorker(){
      activeStreams++;
      streamText.textContent = activeStreams + ' stream' + (activeStreams>1?'s':'') + ' active';
      while(!stop){
        try {
          const res = await fetch(DOWN_URL + '?bytes=' + DOWN_CHUNK_BYTES + '&r=' + Math.random(), { cache: 'no-store', mode: 'cors' });
          const reader = res.body.getReader();
          while(true){
            const result = await reader.read();
            if (result.done) break;
            if (result.value) bump(result.value.length);
            if (stop) { reader.cancel().catch(()=>{}); break; }
          }
        } catch(e) { /* transient, keep looping */ }
      }
      activeStreams--;
    }

    async function uploadWorker(){
      activeStreams++;
      streamText.textContent = activeStreams + ' stream' + (activeStreams>1?'s':'') + ' active';
      const payload = new Uint8Array(UP_CHUNK_BYTES);
      crypto.getRandomValues(payload.subarray(0, Math.min(65536, payload.length)));
      while(!stop){
        try {
          await fetch(UP_URL + '?r=' + Math.random(), { method: 'POST', body: payload, cache: 'no-store', mode: 'cors' });
          bump(payload.length);
        } catch(e) { /* transient */ }
      }
      activeStreams--;
    }

    const worker = direction === 'down' ? downloadWorker : uploadWorker;
    const maxStreams = MAX_STREAMS;

    let lastBytes = 0;
    let lastT = performance.now();
    const smoothedSamples = [];
    const recentRaw = [];
    let displayMbps = 0;
    const sampleTimer = setInterval(() => {
      const now = performance.now();
      const dt = (now - lastT) / 1000;
      const db = byteCounter - lastBytes;
      lastBytes = byteCounter;
      lastT = now;
      if (dt > 0){
        const rawMbps = (db * 8) / dt / 1000000;
        recentRaw.push(rawMbps);
        if (recentRaw.length > 3) recentRaw.shift();
        const despiked = recentRaw.length === 3 ? median3(recentRaw) : rawMbps;
        displayMbps = displayMbps === 0 ? despiked : displayMbps + (despiked - displayMbps) * DISPLAY_SMOOTHING;
        smoothedSamples.push(displayMbps);
        setGaugeValue(displayMbps);
      }
    }, SAMPLE_MS);

    let launched = 0;
    while (launched < maxStreams){
      const step = Math.min(STREAMS_PER_STEP, maxStreams - launched);
      for (let i = 0; i < step; i++){ worker(); launched++; }
      statusText.textContent = 'ramping ' + (direction === 'down' ? 'download' : 'upload');
      await new Promise(r => setTimeout(r, RAMP_STEP_MS));
    }

    statusText.textContent = 'sustaining ' + (direction === 'down' ? 'download' : 'upload');
    await new Promise(r => setTimeout(r, STEADY_MS));

    stop = true;
    clearInterval(sampleTimer);
    await new Promise(r => setTimeout(r, 400));

    // Score from the EMA-smoothed series -- the same values the needle tracked --
    // rather than raw per-interval samples. Drop the first ~35% as ramp
    // contamination, then average the top 90% of what's left (drop only the
    // bottom 10%, which is mostly the tail end of the ramp settling in).
    const steady = smoothedSamples.slice(Math.floor(smoothedSamples.length * 0.35));
    const pool = steady.length ? steady : smoothedSamples;
    const sorted = pool.slice().sort((a, b) => a - b);
    const lo = Math.floor(sorted.length * 0.10);
    const upper = sorted.slice(lo);
    const result = upper.length
      ? upper.reduce((s, v) => s + v, 0) / upper.length
      : sorted.reduce((s, v) => s + v, 0) / (sorted.length || 1);

    // snap the dial to match the number we're about to report, so the needle's
    // resting position always agrees with the stat box
    setGaugeValue(result);
    return result;
  }

  async function runFullTest(){
    startBtn.disabled = true;
    dlResult.textContent = '\\u2014';
    ulResult.textContent = '\\u2014';
    latResult.textContent = '\\u2014';
    jitResult.textContent = '\\u2014';
    streamText.textContent = '\\u00a0';

    try {
      await measureLatency();

      const dl = await runSaturationTest('down');
      dlResult.innerHTML = dl.toFixed(1) + '<small>Mbps</small>';

      const ul = await runSaturationTest('up');
      ulResult.innerHTML = ul.toFixed(1) + '<small>Mbps</small>';

      statusText.textContent = 'test complete';
      streamText.textContent = '\\u00a0';
    } catch(err){
      statusText.textContent = 'test failed \\u2014 check console';
      console.error(err);
    } finally {
      startBtn.disabled = false;
    }
  }

  startBtn.addEventListener('click', runFullTest);
  el('version-tag').textContent = VERSION;
  initGauge();
})();
</script>
</body>
</html>

`;
