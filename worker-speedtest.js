// =============================================================================
// Edge Integrated Speedtest -- Cloudflare Worker
// =============================================================================
// Serves the speed test page as a static response. All test logic runs
// client-side in the browser against Cloudflare's public speed.cloudflare.com
// edge endpoints -- this worker's only job is delivering the HTML/CSS/JS.
//
// CACHING
//   Uses the Workers Cache API (caches.default) directly in code below --
//   this is plain JS, works with a dashboard paste-and-deploy same as
//   everything else. On a cache hit for a given Cloudflare data center, the
//   cached response is served straight back and the code below the
//   cache.match() never re-runs. This is a per-data-center cache. To force a
//   fresh copy after editing the page, bump CACHE_BUSTER below; changing
//   that value changes the cache key.
//
// CHANGELOG (page-internal version tracked separately in the VERSION const
// inside the HTML below -- this is the worker/deploy-level history)
//   v1.0  Initial multi-stream saturation test against speed.cloudflare.com
//   v1.1  Needle-gauge UI, speedtest.net tick scale, upper-biased scoring,
//         version tag, Workers Cache enabled
//   v1.2  Score from EMA-smoothed series (top 90%) instead of raw samples
//   v1.3  Median-of-3 despike filter before the EMA
//   v1.4  Ookla methodology match: min-latency, pretest-sized chunks/
//         streams, direction-specific scoring (download vs upload)
//   v1.5  Mid-test stream escalation (adds streams if headroom detected
//         during first half of test, matching Ookla's documented behavior)
//   v1.6  Worker fetch failures now logged/surfaced instead of swallowed
//   v1.7  Upload switched to XHR upload.onprogress for real-time crediting
//   v1.8  Rolling 2.5s window for rate calc (upload.onprogress fires
//         sparser than SAMPLE_MS on slow connections)
//   v1.9  Proportional chunk sizing (~0.75s per chunk at the pretest-
//         measured rate) to reduce buffer-bloat overcrediting
//   v2.0  Rebuilt upload to match Cloudflare's own documented methodology:
//         completion-timed fetch() + PerformanceResourceTiming + adaptive
//         per-stream size escalation, replacing XHR/onprogress entirely
//   v2.1  Top-justified page layout (better on mobile), favicon added
//   v2.2  Corrected caching approach: switched to the Cache API
//         (caches.default) directly in code, which works with a dashboard
//         paste-and-deploy workflow.
// =============================================================================

const CACHE_BUSTER = 'v2.2'; // bump this (and only this) to force a fresh cached copy after edits

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname !== "/" && url.pathname !== "/index.html") {
      return new Response("Not found", { status: 404 });
    }

    const cache = caches.default;
    const cacheKey = new Request(url.origin + url.pathname + '?cb=' + CACHE_BUSTER, request);

    let response = await cache.match(cacheKey);
    if (response) return response;

    response = new Response(HTML, {
      headers: {
        "content-type": "text/html;charset=UTF-8",
        "cache-control": "public, max-age=3600, stale-while-revalidate=86400"
      }
    });

    // put() is fire-and-forget here on purpose -- we still return the
    // response immediately either way, this just seeds the cache for the
    // next visitor to this data center.
    await cache.put(cacheKey, response.clone());
    return response;
  }
};

const HTML = `
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EDGE SPEEDTEST</title>
<link rel="shortcut icon" href="https://park.edgeintegrated.com/favicon.ico">
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
    align-items:flex-start;
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
//   v1.4  Matched Ookla's documented methodology: latency reports the
//         minimum round trip (not median); a pretest probe decides stream
//         count and chunk size per direction instead of fixed constants;
//         scoring now splits by direction -- download drops top 10%/
//         bottom 22% and averages the rest, upload averages the fastest
//         half (Ookla scores upload more aggressively than download)
//   v1.5  Mid-test stream escalation, matching Ookla's documented "add
//         threads during the first half of the test if headroom is
//         detected" behavior. Pretest now starts conservative (6 streams)
//         instead of jumping straight to the ceiling (raised 8 -> 10),
//         leaving room to actually discover extra headroom -- targets
//         upload consistently reading lower than speedtest.net. Scoring
//         window is now the exact steady-state phase (post-escalation),
//         not a fixed percentage, since total test time is now variable.
//   v1.6  Worker fetch failures were being silently swallowed -- a
//         connection that failed on every single attempt would spin
//         forever with zero visible errors and report 0.0 at the end.
//         Now logs failures to console, shows a visible message after 5
//         consecutive failures, checks res.ok (HTTP error codes don't
//         reject fetch() on their own), and adds backoff between retries
//         instead of a tight failure loop.
//   v1.7  Real root cause of 0.0 upload on cellular found: fetch() has no
//         upload-progress API, so bytes were only credited once an entire
//         chunk finished -- on high-latency/slow-throughput links, a
//         single chunk could outlast the whole test with nothing ever
//         credited, despite the request eventually succeeding (hence no
//         visible error either). Rewrote upload to use XMLHttpRequest's
//         upload.onprogress for real incremental byte crediting, matching
//         how download already worked via the streaming body reader.
//         In-flight uploads are now aborted cleanly on stop instead of
//         lingering until their own timeout.
//   v1.8  Fixed dial decaying to zero on upload even with v1.7's fix:
//         upload.onprogress fires sparser than SAMPLE_MS on slower
//         connections, so single-tick deltas were reading real gaps
//         between events as literal zero throughput. Rate is now computed
//         over a rolling 2.5s window instead of just the immediately
//         preceding tick, absorbing event burstiness while still
//         redrawing the dial every SAMPLE_MS.
//   v1.9  Fixed dial starting way too high (~100Mbps) then decaying toward
//         the real number on slow uploads: upload.onprogress reports
//         bytes handed to the local send buffer, not bytes actually
//         delivered -- on connections with real buffering depth (common
//         on cellular), a large chunk gets buffered near-instantly,
//         reporting an inflated rate until the buffer saturates and
//         throttles down to the true rate. Chunk size is now proportional
//         to the pretest reading (~0.75s of transfer at that rate)
//         instead of a few fixed tiers, so a genuine ~5Mbps connection no
//         longer gets bucketed with a 40Mbps one and handed an 8MB chunk.
//   v2.0  Rebuilt upload measurement to match Cloudflare's own documented
//         methodology instead of guessing further: dropped XHR/onprogress
//         (buffer-handoff based, not real delivery) in favor of
//         completion-timed fetch() requests with PerformanceResourceTiming
//         for precise duration, and per-stream adaptive escalation --
//         start small, double the size whenever a request completes
//         faster than MIN_REQUEST_DURATION_MS (too fast to be a
//         trustworthy bandwidth sample), same as Cloudflare's "ramp-up
//         with increasing file sizes per direction" approach. In-flight
//         requests now cancel via AbortController on stop.
(() => {
  const VERSION = 'v2.0';

  const DOWN_URL = 'https://speed.cloudflare.com/__down';
  const UP_URL = 'https://speed.cloudflare.com/__up';

  const MAX_STREAMS = 10;         // hard ceiling; pretest picks a conservative starting point below this
  const RAMP_STEP_MS = 900;
  const STREAMS_PER_STEP = 3;
  const STEADY_MS = 10000;
  const DOWN_CHUNK_BYTES = 32 * 1000 * 1000;
  const UP_CHUNK_BYTES = 16 * 1000 * 1000;
  const SAMPLE_MS = 300;
  const DISPLAY_SMOOTHING = 0.16;
  const ESCALATE_WINDOW_MS = 6000;      // "first half" of the test where extra streams may be added
  const ESCALATE_CHECK_MS = 1500;       // how often to re-check for headroom during that window
  const ESCALATE_GAIN_THRESHOLD = 0.08; // need >8% throughput gain since the last check to justify adding streams
  const MIN_REQUEST_DURATION_MS = 500;  // upload requests faster than this are latency-dominated, not a trustworthy bandwidth sample -- escalate size

  const MBPS_TICKS = [0, 5, 10, 50, 100, 250, 500, 750, 1000];
  const MS_TICKS = [0, 10, 25, 50, 100, 150, 200, 300, 500];
  const PRETEST_BYTES = 4 * 1000 * 1000;  // 4MB pre-test probe to size the real test

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

  function median3(arr){
    const s = arr.slice().sort((a, b) => a - b);
    return s[Math.floor(s.length / 2)];
  }

  // Quick single-connection probe before the real test, used to decide how many
  // parallel streams and how large a chunk size to use. Ookla's own doc describes
  // this exact pattern (small probe -> pick thread count/file size accordingly),
  // though their "4 Mbps -> 2 vs 4 threads" thresholds are from a much slower-internet
  // era; scaled up here for connections that are commonly gigabit-class today.
  async function pretestProbe(direction){
    const t0 = performance.now();
    try {
      if (direction === 'down'){
        const res = await fetch(DOWN_URL + '?bytes=' + PRETEST_BYTES + '&r=' + Math.random(), { cache: 'no-store', mode: 'cors' });
        await res.arrayBuffer();
      } else {
        const payload = new Uint8Array(PRETEST_BYTES);
        crypto.getRandomValues(payload.subarray(0, Math.min(65536, payload.length)));
        await fetch(UP_URL + '?r=' + Math.random(), { method: 'POST', body: payload, cache: 'no-store', mode: 'cors' });
      }
    } catch(e) { console.error('pretest probe (' + direction + ') failed:', e); return 0; }
    const dt = (performance.now() - t0) / 1000;
    return dt > 0 ? (PRETEST_BYTES * 8) / dt / 1000000 : 0;
  }

  function decideStreamCount(pretestMbps){
    if (pretestMbps < 4) return 2;
    if (pretestMbps < 50) return 4;
    return 6; // start below MAX_STREAMS even on fast connections -- escalation decides if more helps
  }

  function chunkSizeFor(pretestMbps, direction){
    // Chunk size now scales proportionally to the pretest reading, targeting
    // roughly TARGET_SECONDS of real transfer time at that rate, instead of a
    // few fixed tiers. Fixed tiers put e.g. a genuine ~5Mbps connection in the
    // same bucket as a 40Mbps one -- an 8MB chunk at 5Mbps takes 11+ seconds
    // at true line rate, giving local send-buffer bloat a lot of room to
    // report inflated progress before the real bottleneck is ever felt. A
    // proportionally-sized chunk keeps that window small regardless of speed.
    const maxBytes = direction === 'down' ? DOWN_CHUNK_BYTES : UP_CHUNK_BYTES;
    const minBytes = 256 * 1000;
    const targetSeconds = 0.75;
    const bytesPerSecond = (pretestMbps * 1000000) / 8;
    const sized = bytesPerSecond * targetSeconds;
    return Math.min(maxBytes, Math.max(minBytes, Math.round(sized)));
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
    const minLatency = Math.min(...times);
    const jitter = times.length > 1
      ? times.slice(1).reduce((s,v,i)=> s + Math.abs(v - times[i]), 0) / (times.length - 1)
      : 0;
    latResult.innerHTML = minLatency.toFixed(0) + '<small>ms</small>';
    jitResult.innerHTML = jitter.toFixed(1) + '<small>ms</small>';
    return { minLatency, jitter };
  }

  async function runSaturationTest(direction){
    setGaugeScale(MBPS_TICKS, 'MBPS', direction === 'down' ? '#00d9c0' : '#ffb454');
    statusText.textContent = 'probing ' + (direction === 'down' ? 'download' : 'upload') + ' connection';
    performance.clearResourceTimings();
    const pretestMbps = await pretestProbe(direction);
    let currentStreams = decideStreamCount(pretestMbps);
    const chunkBytes = chunkSizeFor(pretestMbps, direction);

    let byteCounter = 0;
    let stop = false;
    let activeStreams = 0;
    let consecutiveFailures = 0;
    let lastErrorMsg = '';
    const activeControllers = new Set();
    const bump = (n) => { byteCounter += n; consecutiveFailures = 0; };

    function noteFailure(e){
      consecutiveFailures++;
      lastErrorMsg = (e && e.message) ? e.message : String(e);
      console.error((direction === 'down' ? 'Download' : 'Upload') + ' request failed:', e);
      if (consecutiveFailures === 5){
        streamText.textContent = (direction === 'down' ? 'download' : 'upload') + ' requests failing: ' + lastErrorMsg + ' (see browser console)';
      }
    }

    async function downloadWorker(){
      activeStreams++;
      streamText.textContent = activeStreams + ' stream' + (activeStreams>1?'s':'') + ' active';
      while(!stop){
        try {
          const res = await fetch(DOWN_URL + '?bytes=' + chunkBytes + '&r=' + Math.random(), { cache: 'no-store', mode: 'cors' });
          if (!res.ok) throw new Error('HTTP ' + res.status);
          const reader = res.body.getReader();
          while(true){
            const result = await reader.read();
            if (result.done) break;
            if (result.value) bump(result.value.length);
            if (stop) { reader.cancel().catch(()=>{}); break; }
          }
        } catch(e) {
          noteFailure(e);
          if (!stop) await new Promise(r => setTimeout(r, 300));
        }
      }
      activeStreams--;
    }

    async function uploadWorker(){
      activeStreams++;
      streamText.textContent = activeStreams + ' stream' + (activeStreams>1?'s':'') + ' active';
      // Start from the pretest-informed size, but refine per-stream from here:
      // if a request completes faster than MIN_REQUEST_DURATION_MS, it's too
      // small to be a trustworthy sample (dominated by latency, not
      // bandwidth) -- Cloudflare's own methodology explicitly calls this out
      // and escalates to larger sizes until a request takes long enough.
      // Crediting happens only on full completion (real server-acknowledged
      // bytes, not local send-buffer handoff), which is what made the old
      // XHR/onprogress approach unreliable on connections with real buffering.
      let streamBytes = Math.max(64 * 1000, Math.min(chunkBytes, UP_CHUNK_BYTES));
      while(!stop){
        let payload;
        try {
          payload = new Uint8Array(streamBytes);
          crypto.getRandomValues(payload.subarray(0, Math.min(65536, payload.length)));
        } catch(e) {
          noteFailure(e);
          break;
        }
        const reqUrl = UP_URL + '?r=' + Math.random();
        const controller = new AbortController();
        activeControllers.add(controller);
        const t0 = performance.now();
        try {
          const res = await fetch(reqUrl, { method: 'POST', body: payload, cache: 'no-store', mode: 'cors', signal: controller.signal });
          activeControllers.delete(controller);
          if (stop) break;
          if (!res.ok) throw new Error('HTTP ' + res.status);
          let durationMs = performance.now() - t0;
          const entries = performance.getEntriesByName(reqUrl);
          const entry = entries[entries.length - 1];
          if (entry && entry.responseEnd > entry.requestStart) durationMs = entry.responseEnd - entry.requestStart;
          bump(payload.length);
          if (durationMs < MIN_REQUEST_DURATION_MS && streamBytes < UP_CHUNK_BYTES){
            streamBytes = Math.min(UP_CHUNK_BYTES, streamBytes * 2);
          }
        } catch(e) {
          activeControllers.delete(controller);
          if (!stop){
            noteFailure(e);
            await new Promise(r => setTimeout(r, 300));
          }
        }
      }
      activeStreams--;
    }

    const worker = direction === 'down' ? downloadWorker : uploadWorker;

    // Rate is computed over a rolling window rather than just the immediately
    // preceding tick. upload.onprogress events (unlike the download body reader)
    // can fire sparser than SAMPLE_MS on slower/higher-latency connections --
    // reading gaps between events as literal zero throughput is what caused the
    // dial to decay to zero even while data was still moving steadily.
    const RATE_WINDOW_MS = 2500;
    const windowSamples = [{ t: performance.now(), bytes: 0 }];
    const smoothedSamples = [];
    const recentRaw = [];
    let displayMbps = 0;
    const sampleTimer = setInterval(() => {
      const now = performance.now();
      windowSamples.push({ t: now, bytes: byteCounter });
      while (windowSamples.length > 2 && now - windowSamples[0].t > RATE_WINDOW_MS) windowSamples.shift();
      const oldest = windowSamples[0];
      const dt = (now - oldest.t) / 1000;
      const db = byteCounter - oldest.bytes;
      if (dt > 0.05){
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
    while (launched < currentStreams){
      const step = Math.min(STREAMS_PER_STEP, currentStreams - launched);
      for (let i = 0; i < step; i++){ worker(); launched++; }
      statusText.textContent = 'ramping ' + (direction === 'down' ? 'download' : 'upload');
      await new Promise(r => setTimeout(r, RAMP_STEP_MS));
    }

    // Escalation window -- matches Ookla's documented behavior of only adding
    // extra threads during the first half of the test, and only if they're
    // determined to be needed. Re-check throughput every ESCALATE_CHECK_MS; if
    // it's still climbing meaningfully, add more streams (up to MAX_STREAMS).
    // If it's plateaued, stop escalating early rather than waiting out the
    // full window -- no reason to keep polling once headroom is exhausted.
    const escalateDeadline = performance.now() + ESCALATE_WINDOW_MS;
    let lastCheckMbps = displayMbps;
    while (performance.now() < escalateDeadline && currentStreams < MAX_STREAMS){
      await new Promise(r => setTimeout(r, ESCALATE_CHECK_MS));
      const gain = lastCheckMbps > 0 ? (displayMbps - lastCheckMbps) / lastCheckMbps : 1;
      if (gain < ESCALATE_GAIN_THRESHOLD) break;
      const step = Math.min(STREAMS_PER_STEP, MAX_STREAMS - currentStreams);
      for (let i = 0; i < step; i++){ worker(); currentStreams++; }
      statusText.textContent = 'escalating ' + (direction === 'down' ? 'download' : 'upload') + ' (headroom detected)';
      lastCheckMbps = displayMbps;
    }

    statusText.textContent = 'sustaining ' + (direction === 'down' ? 'download' : 'upload');
    const samplesBeforeSteady = smoothedSamples.length;
    await new Promise(r => setTimeout(r, STEADY_MS));

    stop = true;
    activeControllers.forEach(c => c.abort());
    clearInterval(sampleTimer);
    await new Promise(r => setTimeout(r, 400));

    // Score only from samples collected during the dedicated steady-state hold
    // (after ramp + escalation finished) -- exact, unlike the old fixed-percentage
    // trim, which assumed a fixed test duration that escalation no longer guarantees.
    // Matches Ookla's documented split: download drops the fastest 10% and the
    // slowest ~22% and averages the middle-upper band; upload sorts and averages
    // just the fastest half, which is deliberately more aggressive.
    const steady = smoothedSamples.slice(samplesBeforeSteady);
    const pool = steady.length ? steady : smoothedSamples;
    const sorted = pool.slice().sort((a, b) => a - b);
    const dropBottom = direction === 'down' ? 0.22 : 0.50;
    const dropTop = direction === 'down' ? 0.10 : 0;
    const lo = Math.floor(sorted.length * dropBottom);
    const hi = Math.ceil(sorted.length * (1 - dropTop));
    const windowed = sorted.slice(lo, hi);
    const result = windowed.length
      ? windowed.reduce((s, v) => s + v, 0) / windowed.length
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
