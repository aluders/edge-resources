/********************************************************************
  YouTube Redirect Worker (OAuth 2.0 — supports unlisted videos)
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
    const CACHE_KEY = `https://cache.local/simple-v7/${UPLOADS_PLAYLIST_ID}`;
    const cache = caches.default;
    const cacheRequest = new Request(CACHE_KEY);

    const url = new URL(request.url);
    const isEmbed = url.searchParams.has("embed");
    const allowRefresh = devModeOn() && url.searchParams.has("refresh");

    // 1) Check Cache (unless dev-mode refresh is active)
    if (!allowRefresh) {
      const cached = await cache.match(cacheRequest);
      if (cached) return rewriteRedirect(cached, isEmbed);
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
      // We check top 5 to safely find the upcoming stream even if other clips were uploaded
      const plParams = new URLSearchParams({
        part: "snippet",
        playlistId: UPLOADS_PLAYLIST_ID,
        maxResults: "5"
      });

      const plRes = await fetch(
        `https://www.googleapis.com/youtube/v3/playlistItems?${plParams}`,
        { headers: authHeader }
      );
      if (!plRes.ok) throw new Error(`Playlist API Error: ${plRes.status}`);
      const plData = await plRes.json();

      if (!plData.items?.length) throw new Error("No videos found.");

      const videoIds = plData.items.map((i) => i.snippet.resourceId.videoId).join(",");

      // 📡 STEP 2: Get Details (Cost: ~1 unit)
      // Necessary to confirm "Upcoming" status vs just "Recent Upload"
      const vParams = new URLSearchParams({
        part: "snippet,liveStreamingDetails",
        id: videoIds
      });

      const vRes = await fetch(
        `https://www.googleapis.com/youtube/v3/videos?${vParams}`,
        { headers: authHeader }
      );
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
        vData.items.sort(
          (a, b) => new Date(b.snippet.publishedAt) - new Date(a.snippet.publishedAt)
        );
        targetVideo = vData.items[0];
      }

      // 💾 Cache the video ID
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
