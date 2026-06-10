/********************************************************************
  YouTube Redirect Worker v1.0
  --------------------------------------------------
  Version History:
    1.0 - Initial release. Combined live/last routes into single
          worker, switched to OAuth for unlisted video support.
  --------------------------------------------------
  ⚠️  Set CHANNEL_ID below before deploying to a new church.
  --------------------------------------------------
  Routes:
    live.*  → Latest live / upcoming / recent stream
    last.*  → Latest completed non-live video
  --------------------------------------------------
  Secrets required:
    OA_CLIENT_ID
    OA_CLIENT_SECRET
    OA_REFRESH_TOKEN
  --------------------------------------------------
  Dev Mode behavior:
    - DEVELOPER_MODE = "OFF": ignores ?refresh
    - DEVELOPER_MODE = "ON" : allows ?refresh to bypass cache
  Notes:
    - ?embed works on both routes
    - Each route has its own cache key
********************************************************************/

// ============================================================
//  CHANNEL CONFIG
// ============================================================
const CHANNEL_ID          = "UCBl48WQE_6YH4u4rbpVtlqA";
const UPLOADS_PLAYLIST_ID = "UU" + CHANNEL_ID.slice(2);

// ============================================================
//  CACHE CONFIG
// ============================================================
const CACHE_TTL      = 21600;  // 6 hours
const CACHE_KEY_LIVE = `https://cache.local/yt-redirect-live/${UPLOADS_PLAYLIST_ID}`;
const CACHE_KEY_LAST = `https://cache.local/yt-redirect-last/${UPLOADS_PLAYLIST_ID}`;

// ============================================================
//  DEVELOPER MODE
// ============================================================
const DEVELOPER_MODE = "OFF";  // "ON" or "OFF"
function devModeOn() {
  return String(DEVELOPER_MODE).trim().toUpperCase() === "ON";
}

// ============================================================
//  OAUTH
// ============================================================
async function getAccessToken(env) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id:     env.OA_CLIENT_ID,
      client_secret: env.OA_CLIENT_SECRET,
      refresh_token: env.OA_REFRESH_TOKEN,
      grant_type:    "refresh_token"
    })
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`OAuth token exchange failed: ${res.status} — ${err}`);
  }

  const json = await res.json();
  if (!json.access_token) throw new Error("No access_token in OAuth response");
  return json.access_token;
}

// ============================================================
//  SHARED: FETCH PLAYLIST ITEMS
// ============================================================
async function fetchPlaylistItems(playlistId, maxResults, authHeader) {
  const params = new URLSearchParams({
    part:       "snippet",
    playlistId: playlistId,
    maxResults: String(maxResults)
  });

  const res = await fetch(
    `https://www.googleapis.com/youtube/v3/playlistItems?${params}`,
    { headers: authHeader }
  );
  if (!res.ok) throw new Error(`Playlist API Error: ${res.status}`);

  const data = await res.json();
  if (!data.items?.length) throw new Error("No videos found.");
  return data.items;
}

// ============================================================
//  SHARED: FETCH VIDEO DETAILS
// ============================================================
async function fetchVideoDetails(videoIds, authHeader) {
  const params = new URLSearchParams({
    part: "snippet,liveStreamingDetails",
    id:   videoIds.join(",")
  });

  const res = await fetch(
    `https://www.googleapis.com/youtube/v3/videos?${params}`,
    { headers: authHeader }
  );
  if (!res.ok) throw new Error(`Videos API Error: ${res.status}`);

  const data = await res.json();
  if (!data.items?.length) throw new Error("No video details found.");
  return data.items;
}

// ============================================================
//  ROUTE: LIVE
//  Priority: Live → Upcoming → Newest Upload
// ============================================================
async function handleLive(authHeader) {
  const items    = await fetchPlaylistItems(UPLOADS_PLAYLIST_ID, 5, authHeader);
  const videoIds = items.map(i => i.snippet.resourceId.videoId);
  const videos   = await fetchVideoDetails(videoIds, authHeader);

  // 1. Live
  let target = videos.find(v => v.snippet.liveBroadcastContent === "live");

  // 2. Upcoming
  if (!target) {
    target = videos.find(
      v =>
        v.snippet.liveBroadcastContent === "upcoming" ||
        (v.liveStreamingDetails?.scheduledStartTime && !v.liveStreamingDetails?.actualEndTime)
    );
  }

  // 3. Newest upload
  if (!target) {
    videos.sort((a, b) => new Date(b.snippet.publishedAt) - new Date(a.snippet.publishedAt));
    target = videos[0];
  }

  return target.id;
}

// ============================================================
//  ROUTE: LAST
//  Returns latest completed non-live video
// ============================================================
async function handleLast(authHeader) {
  const items    = await fetchPlaylistItems(UPLOADS_PLAYLIST_ID, 10, authHeader);
  const videoIds = items.map(i => i.snippet?.resourceId?.videoId).filter(Boolean);
  const videos   = await fetchVideoDetails(videoIds, authHeader);

  const target = videos.find(
    v =>
      v.snippet?.liveBroadcastContent === "none" ||
      v.snippet?.liveBroadcastContent === "completed"
  );

  if (!target) throw new Error("No completed or uploaded videos found.");
  return target.id;
}

// ============================================================
//  SHARED: REDIRECT
// ============================================================
function redirectForMode(id, isEmbed) {
  const target = isEmbed
    ? `https://www.youtube.com/embed/${id}?rel=0&modestbranding=1&controls=1&showinfo=0`
    : `https://www.youtube.com/watch?v=${id}`;
  return Response.redirect(target, 302);
}

function rewriteRedirect(resp, isEmbed) {
  return resp.text().then(id => redirectForMode(id, isEmbed));
}

// ============================================================
//  MAIN WORKER
// ============================================================
export default {
  async fetch(request, env) {
    const url          = new URL(request.url);
    const isEmbed      = url.searchParams.has("embed");
    const allowRefresh = devModeOn() && url.searchParams.has("refresh");

    // Determine route from hostname
    const hostname = url.hostname;
    const isLive   = hostname.startsWith("live.");
    const isLast   = hostname.startsWith("last.");

    if (!isLive && !isLast) {
      return new Response(
        `Unknown route: ${hostname}. Expected live.* or last.*`,
        { status: 404 }
      );
    }

    const cacheKey = isLive ? CACHE_KEY_LIVE : CACHE_KEY_LAST;
    const cache    = caches.default;
    const cacheReq = new Request(cacheKey);

    // Check cache
    if (!allowRefresh) {
      const cached = await cache.match(cacheReq);
      if (cached) return rewriteRedirect(cached, isEmbed);
    }

    // Validate secrets
    if (!env.OA_CLIENT_ID || !env.OA_CLIENT_SECRET || !env.OA_REFRESH_TOKEN) {
      return new Response("Missing OAuth secrets", { status: 500 });
    }

    try {
      const accessToken = await getAccessToken(env);
      const authHeader  = { Authorization: `Bearer ${accessToken}` };

      const videoId = isLive
        ? await handleLive(authHeader)
        : await handleLast(authHeader);

      await cache.put(
        cacheReq,
        new Response(videoId, { headers: { "Content-Type": "text/plain" } }).clone(),
        { expirationTtl: CACHE_TTL }
      );

      return redirectForMode(videoId, isEmbed);

    } catch (err) {
      console.error(err);
      const fallback = await cache.match(cacheReq);
      if (fallback) return rewriteRedirect(fallback, isEmbed);
      return new Response("Server error: " + (err?.message || String(err)), { status: 500 });
    }
  }
};
