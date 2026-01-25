/********************************************************************
  YouTube Redirect Worker
  + Developer Mode gate for ?flags
  --------------------------------------------------
  Dev Mode behavior:
    - DEVELOPER_MODE = "OFF": ignores ?refresh (prevents cache-busting abuse)
    - DEVELOPER_MODE = "ON" : allows ?refresh to bypass cache
  Notes:
    - ?embed remains available in both modes (not considered a dev flag)
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
    const UPLOADS_PLAYLIST_ID = "UUxZ8LTstrCOotf74qO0dOFA";
    const API_KEY = env.YOUTUBE_API_KEY;

    const CACHE_TTL = 21600; // 6 hours
    const CACHE_KEY = `https://cache.local/simple-v7/${UPLOADS_PLAYLIST_ID}`;
    const cache = caches.default;
    const cacheRequest = new Request(CACHE_KEY);

    const url = new URL(request.url);
    const isEmbed = url.searchParams.has("embed");

    // ------------------------------------------------------------
    // DEV MODE GATE: only allow cache-busting ?refresh when ON
    // (We intentionally do NOT treat ?embed as a dev flag.)
    // ------------------------------------------------------------
    const allowRefresh = devModeOn() && url.searchParams.has("refresh");

    // 1) Check Cache (unless dev-mode refresh is allowed AND present)
    if (!allowRefresh) {
      const cached = await cache.match(cacheRequest);
      if (cached) return rewriteRedirect(cached, isEmbed);
    }

    if (!API_KEY) return new Response("Missing API Key", { status: 500 });

    try {
      // 📡 STEP 1: Get Playlist (Cost: ~1 unit)
      // We check top 5 to safely find the upcoming stream even if you uploaded other clips
      const plParams = new URLSearchParams({
        part: "snippet",
        playlistId: UPLOADS_PLAYLIST_ID,
        maxResults: "5",
        key: API_KEY
      });

      const plRes = await fetch(`https://www.googleapis.com/youtube/v3/playlistItems?${plParams}`);
      if (!plRes.ok) throw new Error(`Playlist API Error: ${plRes.status}`);
      const plData = await plRes.json();

      if (!plData.items?.length) throw new Error("No videos found.");

      const videoIds = plData.items.map((i) => i.snippet.resourceId.videoId).join(",");

      // 📡 STEP 2: Get Details (Cost: ~1 unit)
      // Necessary to confirm "Upcoming" status vs just "Recent Upload"
      const vParams = new URLSearchParams({
        part: "snippet,liveStreamingDetails",
        id: videoIds,
        key: API_KEY
      });

      const vRes = await fetch(`https://www.googleapis.com/youtube/v3/videos?${vParams}`);
      if (!vRes.ok) throw new Error(`Videos API Error: ${vRes.status}`);
      const vData = await vRes.json();

      // 🧠 LOGIC: Priority Sorting
      // 1. Live -> 2. Upcoming -> 3. Newest Upload
      let targetVideo = vData.items?.find((v) => v.snippet.liveBroadcastContent === "live");

      if (!targetVideo) {
        targetVideo = vData.items?.find(
          (v) =>
            v.snippet.liveBroadcastContent === "upcoming" ||
            (v.liveStreamingDetails?.scheduledStartTime && !v.liveStreamingDetails?.actualEndTime)
        );
      }

      if (!targetVideo) {
        // Fallback: Sort by date to get the true latest upload
        if (!vData.items?.length) throw new Error("No video details found.");
        vData.items.sort((a, b) => new Date(b.snippet.publishedAt) - new Date(a.snippet.publishedAt));
        targetVideo = vData.items[0];
      }

      // 💾 Cache It (store videoId only)
      const responseBody = new Response(targetVideo.id, {
        headers: { "Content-Type": "text/plain" }
      });

      await cache.put(cacheRequest, responseBody.clone(), { expirationTtl: CACHE_TTL });

      return redirectForMode(targetVideo.id, isEmbed);
    } catch (err) {
      console.error(err);
      const fallback = await cache.match(cacheRequest);
      if (fallback) return rewriteRedirect(fallback, isEmbed);
      return new Response("Server error: " + (err?.message || String(err)), { status: 500 });
    }
  }
};

function rewriteRedirect(resp, isEmbed) {
  return resp.text().then((id) => redirectForMode(id, isEmbed));
}

function redirectForMode(id, isEmbed) {
  const target = isEmbed
    ? `https://www.youtube.com/embed/${id}?rel=0&modestbranding=1&controls=1&showinfo=0`
    : `https://www.youtube.com/watch?v=${id}`;
  return Response.redirect(target, 302);
}
