//
// worker.js - R2 HLS Video Streaming Worker + Player
//
// Serves HLS video (master/variant .m3u8 playlists + .ts segments)
// out of an R2 bucket, with byte-range support so seeking/scrubbing
// works on a multi-hour file - AND serves the player page itself, so
// there's nothing else to host. Built to get around Google Drive's
// anonymous-viewer download quota for the memorial video project.
//
// Bindings required (Worker > Settings > Bindings):
//   R2 Bucket    VIDEO_BUCKET   ->  the "video" bucket
//
// Optional env var (Worker > Settings > Variables):
//   ACCESS_TOKEN  - if set, gates BOTH the player page and the video
//                   files behind ?key=<value>. The player page bakes
//                   the token into its own generated video URL, so
//                   visitors only ever need the one link:
//                     https://<worker-url>/?key=<value>
//                   Leave unset to keep everything open to anyone
//                   with the link.
//
// Notes to self:
//   - Bucket layout: video/kuhn/master.m3u8, video/kuhn/v0../v3/
//   - MASTER_PLAYLIST_KEY below points at that file - update it if
//     a different cut ever gets uploaded under a new prefix
//   - DOWNLOAD_URL below is optional - point it at any real .mp4,
//     anywhere (R2, edgeintegrated.com, wherever) - the player links
//     to this Worker's own /download route, which fetches DOWNLOAD_URL
//     and re-serves it with Content-Disposition: attachment set, so
//     it downloads correctly regardless of what the origin sends.
//     Leave DOWNLOAD_URL blank to hide the download button entirely.
//   - Uploaded via upload-r2-hls.sh (rclone) - that script sets
//     Content-Type per file: .m3u8 -> application/vnd.apple.mpegurl,
//     .ts -> video/mp2t. If playback ever breaks, check that first.
//   - R2 bucket's own "Public Access" setting stays Disabled - this
//     Worker is the only way in, regardless of that setting.
//   - Custom domain: kuhn.covenantpaso.com (Worker > Settings >
//     Domains & Routes > Add > Custom Domain). Required for the
//     Cache API below to actually do anything - it's a documented
//     no-op on *.workers.dev.
//   - Cache API note: Cloudflare's cache does NOT auto-slice Range
//     requests out of a cached full response (confirmed - this isn't
//     an assumption). So cache misses fetch and store the FULL
//     object, and Range slicing is done by hand, in-Worker, against
//     either the fresh or cached copy. Segments are small (a few MB
//     at most for a 6s chunk) so buffering one to slice it is cheap.
//   - player.html (standalone version) is no longer needed - folded
//     into this file as of 1.1.
//
// Changelog (newest first)
//   1.7 - DOWNLOAD_URL is now proxied through this Worker (new
//         /download route) instead of linked to directly, so
//         Content-Disposition applies no matter where the file is
//         actually hosted - the origin's own headers don't matter.
//   1.6 - .mp4 responses now get Content-Disposition: attachment, so
//         the download button actually downloads instead of opening
//         the browser's built-in video player.
//   1.5 - Reverted autoplay - muted-only wasn't worth it for this,
//         video just sits ready to play like before.
//   1.4 - Autoplay on load, muted by default (browsers block autoplay
//         with sound outright - this isn't a Plyr/hls.js limitation,
//         every browser enforces it the same way). Visitors just
//         click the mute icon to turn sound on.
//   1.3 - Added Cache API: video objects are cached at Cloudflare's
//         edge after first request (per colo), with manual byte-range
//         slicing since the cache doesn't do that automatically.
//         Requires the custom domain (see notes above).
//   1.2 - Player now uses Plyr for controls (was bare native <video>
//         controls) so a download button can be added; page title
//         changed to "Video Streamer"
//   1.1 - Folded the player page (hls.js + native Safari fallback)
//         into this Worker at "/" - no separate file to host.
//         Access gate now covers the player page too.
//   1.0 - Initial version: R2 range-request passthrough, optional
//         ?key= token gate, CORS headers for cross-origin playback
//

// ---- CONFIG ----
const MASTER_PLAYLIST_KEY = 'kuhn/master.m3u8'; // HLS master playlist path inside the bucket
const DOWNLOAD_URL = 'https://edgeintegrated.com/2026-0815-kuhn.mp4'; // optional - shows a download button in the player when set
const DOWNLOAD_PATH = '/download'; // this Worker's own route that proxies DOWNLOAD_URL
const PLAYER_PATHS = ['/', '/player', '/index.html']; // paths that render the player instead of serving an object
// -----------------

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, HEAD, OPTIONS',
          'access-control-allow-headers': 'Range',
        },
      });
    }

    const url = new URL(request.url);

    // Access gate - covers the player page and every object below it.
    if (env.ACCESS_TOKEN && url.searchParams.get('key') !== env.ACCESS_TOKEN) {
      return new Response('Forbidden', { status: 403 });
    }

    if (request.method === 'GET' && PLAYER_PATHS.includes(url.pathname)) {
      return new Response(renderPlayerHtml(env), {
        headers: { 'content-type': 'text/html; charset=UTF-8' },
      });
    }

    if (request.method === 'GET' && url.pathname === DOWNLOAD_PATH && DOWNLOAD_URL) {
      return proxyDownload();
    }

    const key = decodeURIComponent(url.pathname.slice(1));
    if (!key) {
      return new Response('Not found', { status: 404 });
    }

    return serveVideoObject(key, request, env, ctx);
  },
};

// Fetches DOWNLOAD_URL and re-serves it with Content-Disposition set,
// so the download button gets a real download regardless of what
// headers the origin (R2, edgeintegrated.com, wherever) actually sends.
async function proxyDownload() {
  const upstream = await fetch(DOWNLOAD_URL);
  if (!upstream.ok || !upstream.body) {
    return new Response('Download unavailable', { status: 502 });
  }

  const headers = new Headers(upstream.headers);
  const filename = DOWNLOAD_URL.split('/').pop();
  headers.set('content-disposition', `attachment; filename="${filename}"`);
  headers.set('access-control-allow-origin', '*');

  return new Response(upstream.body, { status: upstream.status, headers });
}

// Serves one R2 object (playlist or segment), caching the full object
// at Cloudflare's edge and handling Range requests by hand on top of
// whichever copy (cached or freshly fetched) is available.
async function serveVideoObject(key, request, env, ctx) {
  const cache = caches.default;
  const cacheUrl = new URL(request.url);
  cacheUrl.search = ''; // ?key= shouldn't fragment the cache - it's a single shared token
  const cacheKey = new Request(cacheUrl.toString(), { method: 'GET' });

  let source = await cache.match(cacheKey);

  if (!source) {
    const object = await env.VIDEO_BUCKET.get(key);
    if (object === null) {
      return new Response('Not found', { status: 404 });
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    headers.set('accept-ranges', 'bytes');
    headers.set('cache-control', 'public, max-age=31536000, immutable');
    headers.set('content-length', String(object.size));

    source = new Response(object.body, { status: 200, headers });
    ctx.waitUntil(cache.put(cacheKey, source.clone()));
  }

  const headers = new Headers(source.headers);
  headers.set('access-control-allow-origin', '*');

  // Force an actual download (instead of the browser opening its own
  // video player) for .mp4 files - this is what the player's download
  // button relies on. Video content types play inline by default, so
  // without this header the button just streams the file instead.
  if (key.toLowerCase().endsWith('.mp4')) {
    const filename = key.split('/').pop();
    headers.set('content-disposition', `attachment; filename="${filename}"`);
  }

  const range = request.headers.get('range');
  const size = Number(source.headers.get('content-length'));
  const match = range ? /^bytes=(\d+)-(\d*)$/.exec(range) : null;

  if (!match) {
    return new Response(source.body, { status: 200, headers });
  }

  const start = Number(match[1]);
  const end = match[2] ? Number(match[2]) : size - 1;

  const buf = await source.arrayBuffer();
  const sliced = buf.slice(start, end + 1);

  headers.set('content-range', `bytes ${start}-${end}/${size}`);
  headers.set('content-length', String(sliced.byteLength));

  return new Response(sliced, { status: 206, headers });
}

function renderPlayerHtml(env) {
  const gate = env.ACCESS_TOKEN ? `?key=${encodeURIComponent(env.ACCESS_TOKEN)}` : '';
  const streamUrl = `/${MASTER_PLAYLIST_KEY}${gate}`;
  const downloadUrl = DOWNLOAD_URL ? `${DOWNLOAD_PATH}${gate}` : '';

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Video Streamer</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/plyr/3.7.8/plyr.min.css">
<style>
  html, body {
    margin: 0;
    height: 100%;
    background: #111;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  .wrap { width: 100%; max-width: 960px; padding: 16px; box-sizing: border-box; }
  .plyr { border-radius: 6px; overflow: hidden; }
  .message { color: #ccc; text-align: center; padding: 40px 16px; }
</style>
</head>
<body>
  <div class="wrap">
    <video id="player" controls playsinline></video>
  </div>

  <script src="https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.15/hls.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/plyr/3.7.8/plyr.min.js"></script>
  <script>
    const STREAM_URL = "${streamUrl}";
    const DOWNLOAD_URL = "${downloadUrl}";
    const video = document.getElementById("player");

    if (video.canPlayType("application/vnd.apple.mpegurl")) {
      // Safari / iOS - plays HLS natively, no library needed
      video.src = STREAM_URL;
    } else if (window.Hls && Hls.isSupported()) {
      const hls = new Hls();
      hls.loadSource(STREAM_URL);
      hls.attachMedia(video);
    } else {
      document.querySelector(".wrap").innerHTML =
        '<p class="message">Sorry, this browser cannot play the video. Try Chrome, Firefox, Edge, or Safari.</p>';
    }

    // Plyr replaces the native controls with a custom bar. The
    // "download" token only shows up if DOWNLOAD_URL is set below -
    // Plyr can't point it at STREAM_URL since that's a playlist, not
    // an actual downloadable file.
    const controls = [
      "play-large", "play", "progress", "current-time", "duration",
      "mute", "volume", "settings", "fullscreen",
    ];
    if (DOWNLOAD_URL) {
      controls.splice(controls.length - 1, 0, "download");
    }

    new Plyr(video, {
      controls,
      settings: ["speed"],
      urls: DOWNLOAD_URL ? { download: DOWNLOAD_URL } : undefined,
    });
  </script>
</body>
</html>`;
}
