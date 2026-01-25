/********************************************************************
  Latest Non-Live Video Redirect Worker
  + Developer Mode gate for ?flags
  --------------------------------------------------
  Dev Mode behavior:
    - DEVELOPER_MODE = "OFF": disables manual/cache-busting flags (?refresh)
                              and diagnostic-style flags if you add any later.
                              Normal operation (redirect) still works.
    - DEVELOPER_MODE = "ON" : allows ?refresh (and any future ?flags).
********************************************************************/

/********************************************************************
  DEVELOPER MODE
********************************************************************/
const DEVELOPER_MODE = "OFF"; // "ON" or "OFF"
function devModeOn() {
  return String(DEVELOPER_MODE).trim().toUpperCase() === "ON";
}

export default {
  async fetch(request, env) {
    const CHANNEL_ID = "UCxZ8LTstrCOotf74qO0dOFA";
    const UPLOADS_PLAYLIST_ID = "UUxZ8LTstrCOotf74qO0dOFA";
    const API_KEY = env.YOUTUBE_API_KEY;

    const CACHE_TTL = 21600; // 6 hours
    const CACHE_KEY = `https://cache.local/latest-nonlive-video/${CHANNEL_ID}`;
    const cache = caches.default;
    const cacheRequest = new Request(CACHE_KEY);

    const url = new URL(request.url);
    const isEmbedMode = url.searchParams.has("embed");

    // ------------------------------------------------------------
    // DEV MODE GATE: disable all ?flag endpoints unless ON
    // For this worker, the only "flag" today is ?refresh.
    // (We intentionally do NOT treat ?embed as a dev flag.)
    // ------------------------------------------------------------
    const hasDevFlags = url.searchParams.has("refresh");
    if (hasDevFlags && !devModeOn()) {
      // If someone tries to force refresh while dev mode is OFF,
      // behave like the flag doesn't exist and just use normal behavior.
      url.searchParams.delete("refresh");
      // (continue normally)
    }

    // Try cache first unless dev-mode refresh is allowed AND present
    let cachedResponse = await cache.match(cacheRequest);
    const allowRefresh = devModeOn() && url.searchParams.has("refresh");

    if (cachedResponse && !allowRefresh) {
      return rewriteRedirect(cachedResponse, isEmbedMode);
    }

    if (!API_KEY) {
      return new Response("Missing YOUTUBE_API_KEY", { status: 500 });
    }

    try {
      // 1️⃣ Fetch multiple recent items from uploads playlist
      const playlistParams = new URLSearchParams({
        part: "snippet",
        playlistId: UPLOADS_PLAYLIST_ID,
        maxResults: "10",
        key: API_KEY
      });

      const playlistUrl = `https://www.googleapis.com/youtube/v3/playlistItems?${playlistParams}`;
      const playlistRes = await fetch(playlistUrl);
      if (!playlistRes.ok) {
        throw new Error(`YouTube Playlist API error: ${playlistRes.status}`);
      }

      const playlistData = await playlistRes.json();
      if (!playlistData.items || playlistData.items.length === 0) {
        throw new Error("No public videos found in playlist.");
      }

      // 2️⃣ Extract video IDs
      const videoIds = playlistData.items
        .map((item) => item.snippet?.resourceId?.videoId)
        .filter(Boolean);

      if (videoIds.length === 0) {
        throw new Error("No video IDs found.");
      }

      // 3️⃣ Get video statuses
      const videosParams = new URLSearchParams({
        part: "snippet,liveStreamingDetails",
        id: videoIds.join(","),
        key: API_KEY
      });

      const videosUrl = `https://www.googleapis.com/youtube/v3/videos?${videosParams}`;
      const videosRes = await fetch(videosUrl);
      if (!videosRes.ok) {
        throw new Error(`YouTube Videos API error: ${videosRes.status}`);
      }

      const videosData = await videosRes.json();
      if (!videosData.items || videosData.items.length === 0) {
        throw new Error("No video details found.");
      }

      // 4️⃣ Find the first completed or normal upload (skip live/upcoming)
      const validVideo = videosData.items.find(
        (v) =>
          v.snippet?.liveBroadcastContent === "none" ||
          v.snippet?.liveBroadcastContent === "completed"
      );

      if (!validVideo) {
        throw new Error("No completed or uploaded videos found.");
      }

      const videoId = validVideo.id;

      // Store canonical representation (videoId only)
      const stored = new Response(videoId, {
        headers: { "Content-Type": "text/plain" }
      });

      await cache.put(cacheRequest, stored.clone(), {
        expirationTtl: CACHE_TTL
      });

      return redirectForMode(videoId, isEmbedMode);
    } catch (err) {
      console.error("Worker error:", err);

      if (cachedResponse) {
        console.warn("Falling back to cached version.");
        return rewriteRedirect(cachedResponse, isEmbedMode);
      }

      return new Response("Server error: " + (err?.message || String(err)), { status: 500 });
    }
  }
};

// Convert cached videoId -> correct redirect
function rewriteRedirect(cachedResponse, isEmbedMode) {
  return cachedResponse.text().then((videoId) => redirectForMode(videoId, isEmbedMode));
}

// Emit either embed URL or watch URL
function redirectForMode(videoId, isEmbedMode) {
  const target = isEmbedMode
    ? `https://www.youtube.com/embed/${videoId}?rel=0&modestbranding=1&controls=1&showinfo=0`
    : `https://www.youtube.com/watch?v=${videoId}`;

  return Response.redirect(target, 302);
}
