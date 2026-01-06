export default {
  async fetch(request, env) {
    const UPLOADS_PLAYLIST_ID = "UUxZ8LTstrCOotf74qO0dOFA";
    const API_KEY = env.YOUTUBE_API_KEY;
    const CACHE_TTL = 21600; // 6 hours 
    const CACHE_KEY = `https://cache.local/simple-v7/${UPLOADS_PLAYLIST_ID}`;
    const cache = caches.default;
    const cacheRequest = new Request(CACHE_KEY);
    const url = new URL(request.url);

    // 1. Check Cache
    if (!url.searchParams.has("refresh")) {
      const cached = await cache.match(cacheRequest);
      if (cached) return rewriteRedirect(cached, url.searchParams.has("embed"));
    }

    if (!API_KEY) return new Response("Missing API Key", { status: 500 });

    try {
      // 📡 STEP 1: Get Playlist (Cost: 1 Unit)
      // We check top 5 to safely find the upcoming stream even if you uploaded other clips
      const plParams = new URLSearchParams({
        part: "snippet",
        playlistId: UPLOADS_PLAYLIST_ID,
        maxResults: "5",
        key: API_KEY,
      });

      const plRes = await fetch(`https://www.googleapis.com/youtube/v3/playlistItems?${plParams}`);
      if (!plRes.ok) throw new Error(`Playlist API Error: ${plRes.status}`);
      const plData = await plRes.json();
      
      if (!plData.items?.length) throw new Error("No videos found.");

      const videoIds = plData.items.map(i => i.snippet.resourceId.videoId).join(",");

      // 📡 STEP 2: Get Details (Cost: 1 Unit)
      // Necessary to confirm "Upcoming" status vs just "Recent Upload"
      const vParams = new URLSearchParams({
        part: "snippet,liveStreamingDetails",
        id: videoIds,
        key: API_KEY,
      });

      const vRes = await fetch(`https://www.googleapis.com/youtube/v3/videos?${vParams}`);
      if (!vRes.ok) throw new Error(`Videos API Error: ${vRes.status}`);
      const vData = await vRes.json();

      // 🧠 LOGIC: Priority Sorting
      // 1. Live -> 2. Upcoming -> 3. Newest Upload
      let targetVideo = vData.items.find(v => v.snippet.liveBroadcastContent === "live");

      if (!targetVideo) {
        targetVideo = vData.items.find(v => 
          v.snippet.liveBroadcastContent === "upcoming" || 
          (v.liveStreamingDetails?.scheduledStartTime && !v.liveStreamingDetails?.actualEndTime)
        );
      }

      if (!targetVideo) {
        // Fallback: Sort by date to get the true latest upload
        vData.items.sort((a, b) => new Date(b.snippet.publishedAt) - new Date(a.snippet.publishedAt));
        targetVideo = vData.items[0];
      }

      // 💾 Cache It
      const responseBody = new Response(targetVideo.id, { 
        headers: { "Content-Type": "text/plain" } 
      });
      
      await cache.put(cacheRequest, responseBody.clone(), { expirationTtl: CACHE_TTL });

      return redirectForMode(targetVideo.id, url.searchParams.has("embed"));

    } catch (err) {
      console.error(err);
      const fallback = await cache.match(cacheRequest);
      if (fallback) return rewriteRedirect(fallback, url.searchParams.has("embed"));
      return new Response("Server error: " + err.message, { status: 500 });
    }
  },
};

function rewriteRedirect(resp, isEmbed) {
  return resp.text().then(id => redirectForMode(id, isEmbed));
}

function redirectForMode(id, isEmbed) {
  const target = isEmbed
    ? `https://www.youtube.com/embed/${id}?rel=0&modestbranding=1&controls=1&showinfo=0`
    : `https://www.youtube.com/watch?v=${id}`;
  return Response.redirect(target, 302);
}
