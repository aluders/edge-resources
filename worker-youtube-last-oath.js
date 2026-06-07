/********************************************************************
  Latest Non-Live Video Redirect Worker (OAuth 2.0 — supports unlisted videos)
  --------------------------------------------------
  Secrets required:
    YOUTUBE_CLIENT_ID
    YOUTUBE_CLIENT_SECRET
    YOUTUBE_REFRESH_TOKEN
  --------------------------------------------------
  Dev Mode behavior:
    - DEVELOPER_MODE = "OFF": ignores ?refresh
    - DEVELOPER_MODE = "ON" : allows ?refresh to bypass cache
  Notes:
    - ?embed remains available in both modes
********************************************************************/

/********************************************************************
  CHANNEL CONFIG
********************************************************************/
const CHANNEL_ID = "UCBl48WQE_6YH4u4rbpVtlqA";
const UPLOADS_PLAYLIST_ID = "UU" + CHANNEL_ID.slice(2);

/********************************************************************
  DEVELOPER MODE
********************************************************************/
const DEVELOPER_MODE = "OFF"; // "ON" or "OFF"
function devModeOn() {
  return String(DEVELOPER_MODE).trim().toUpperCase() === "ON";
}

async function getAccessToken(env) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.YOUTUBE_CLIENT_ID,
      client_secret: env.YOUTUBE_CLIENT_SECRET,
      refresh_token: env.YOUTUBE_REFRESH_TOKEN,
      grant_type: "refresh_token"
    })
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`OAuth token exchange failed: ${res.status} — ${err}`);
  }

  const data = await res.json();
  if (!data.access_token) throw new Error("No access_token in OAuth response");
  return data.access_token;
}

export default {
  async fetch(request, env) {
    const CACHE_TTL = 21600; // 6 hours
    const CACHE_KEY = `https://cache.local/latest-nonlive-video/${CHANNEL_ID}`;
    const cache = caches.default;
    const cacheRequest = new Request(CACHE_KEY);

    const url = new URL(request.url);
    const isEmbedMode = url.searchParams.has("embed");
    const allowRefresh = devModeOn() && url.searchParams.has("refresh");

    // 1) Check Cache (unless dev-mode refresh is active)
    if (!allowRefresh) {
      const cached = await cache.match(cacheRequest);
      if (cached) return rewriteRedirect(cached, isEmbedMode);
    }

    // Validate secrets
    if (!env.YOUTUBE_CLIENT_ID || !env.YOUTUBE_CLIENT_SECRET || !env.YOUTUBE_REFRESH_TOKEN) {
      return new Response("Missing OAuth secrets", { status: 500 });
    }

    try {
      // 🔑 Get a fresh access token
      const accessToken = await getAccessToken(env);
      const authHeader = { Authorization: `Bearer ${accessToken}` };

      // 📡 STEP 1: Get Playlist (Cost: ~1 unit)
      const plParams = new URLSearchParams({
        part: "snippet",
        playlistId: UPLOADS_PLAYLIST_ID,
        maxResults: "10"
      });

      const plRes = await fetch(
        `https://www.googleapis.com/youtube/v3/playlistItems?${plParams}`,
        { headers: authHeader }
      );
      if (!plRes.ok) throw new Error(`Playlist API Error: ${plRes.status}`);
      const plData = await plRes.json();

      if (!plData.items?.length) throw new Error("No videos found.");

      const videoIds = plData.items
        .map((i) => i.snippet?.resourceId?.videoId)
        .filter(Boolean);

      if (!videoIds.length) throw new Error("No video IDs found.");

      // 📡 STEP 2: Get Details (Cost: ~1 unit)
      const vParams = new URLSearchParams({
        part: "snippet,liveStreamingDetails",
        id: videoIds.join(",")
      });

      const vRes = await fetch(
        `https://www.googleapis.com/youtube/v3/videos?${vParams}`,
        { headers: authHeader }
      );
      if (!vRes.ok) throw new Error(`Videos API Error: ${vRes.status}`);
      const vData = await vRes.json();

      if (!vData.items?.length) throw new Error("No video details found.");

      // 🧠 LOGIC: Find the first completed or normal upload (skip live/upcoming)
      const targetVideo = vData.items.find(
        (v) =>
          v.snippet?.liveBroadcastContent === "none" ||
          v.snippet?.liveBroadcastContent === "completed"
      );

      if (!targetVideo) throw new Error("No completed or uploaded videos found.");

      // 💾 Cache the video ID
      const responseBody = new Response(targetVideo.id, {
        headers: { "Content-Type": "text/plain" }
      });

      await cache.put(cacheRequest, responseBody.clone(), { expirationTtl: CACHE_TTL });

      return redirectForMode(targetVideo.id, isEmbedMode);
    } catch (err) {
      console.error("Worker error:", err);
      const fallback = await cache.match(cacheRequest);
      if (fallback) return rewriteRedirect(fallback, isEmbedMode);
      return new Response("Server error: " + (err?.message || String(err)), { status: 500 });
    }
  }
};

function rewriteRedirect(cachedResponse, isEmbedMode) {
  return cachedResponse.text().then((videoId) => redirectForMode(videoId, isEmbedMode));
}

function redirectForMode(videoId, isEmbedMode) {
  const target = isEmbedMode
    ? `https://www.youtube.com/embed/${videoId}?rel=0&modestbranding=1&controls=1&showinfo=0`
    : `https://www.youtube.com/watch?v=${videoId}`;
  return Response.redirect(target, 302);
}
