/********************************************************************
  CONFIGURATION
********************************************************************/
// STREAM SCHEDULE: When the event technically starts (for the Title/Metadata)
const SCHEDULE_HOUR_PT = 10;   // 10 AM
const SCHEDULE_MINUTE_PT = 30; // 30 Minutes

// GO LIVE WINDOW: The range of minutes we attempt to start the stream
const GO_LIVE_HOUR = 10;
const GO_LIVE_MIN_START = 28; // Start trying at 10:28
const GO_LIVE_MIN_END = 35;   // Stop trying at 10:35

const UPLOADS_PLAYLIST_ID = "UUxZ8LTstrCOotf74qO0dOFA";
const THUMBNAIL_URL = "https://covenantpaso.pages.dev/cpc-youtube.png";
const CATEGORY_ID = "29"; // Nonprofits & Activism

/********************************************************************
  SAFE JSON PARSER
********************************************************************/
async function safeJson(response) {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch (_) {
    return { _parseError: true, raw: text };
  }
}

/********************************************************************
  MAIN WORKER
********************************************************************/
export default {
  async scheduled(event, env, ctx) {
    // 1. THURSDAY SCHEDULING (Run blindly based on cron string)
    if (event.cron.includes("thu")) {
      console.log("📅 Scheduling Cron Triggered");
      ctx.waitUntil(scheduleNextSunday(env));
      return;
    }

    // 2. SUNDAY GO-LIVE (Run selectively based on time window)
    const pt = getPacificTimeParts(new Date());
    const currentHour = parseInt(pt.hour);
    const currentMin = parseInt(pt.minute);

    // Check if we are inside the "Go Live" window (10:28 to 10:35)
    if (currentHour === GO_LIVE_HOUR && currentMin >= GO_LIVE_MIN_START && currentMin <= GO_LIVE_MIN_END) {
      console.log(`✅ Inside Go-Live Window (${currentHour}:${currentMin} PT). Starting Double-Check Loop.`);
      
      // We wrap this in a blocking function to ensure the wait happens
      ctx.waitUntil((async () => {
        // ATTEMPT 1 (Immediate)
        console.log("🚀 Attempt 1/2");
        await goLiveUpcoming(env);

        // WAIT 30 SECONDS
        console.log("⏳ Waiting 30s for Attempt 2...");
        await new Promise(resolve => setTimeout(resolve, 30000));

        // ATTEMPT 2 (30s later)
        console.log("🚀 Attempt 2/2");
        await goLiveUpcoming(env);
      })());

    } else {
      console.log(`⏭️ Cron fired at ${currentHour}:${currentMin} PT. Outside window. Skipping.`);
    }
  },

  async fetch(request, env) {
    const url = new URL(request.url);

    /**************************************
     HELPER: FIND STREAM IDs (?keys)
    **************************************/
    if (url.searchParams.has("keys")) {
      const token = await getAccessToken(env);
      if (!token) return new Response("OAuth Failed", { status: 500 });
      
      // Fetch all stream keys associated with this channel
      const res = await fetch(
        "https://youtube.googleapis.com/youtube/v3/liveStreams?part=id,snippet&mine=true", 
        { headers: { Authorization: `Bearer ${token}` } }
      );
      
      const data = await safeJson(res);
      
      if (!data.items) return new Response(JSON.stringify(data, null, 2));

      // Return a clean list to read easily (SECURITY UPDATE: Removed actual key)
      const summary = data.items.map(item => ({
        TITLE: item.snippet.title,
        STREAM_ID: item.id  // <--- This is the ID you need for Cloudflare
      }));

      return new Response(JSON.stringify(summary, null, 2), {
        headers: { "Content-Type": "application/json" }
      });
    }

    /**************************************
     TEST ENDPOINT (?test)
    **************************************/
    if (url.searchParams.has("test")) {
      const token = await getAccessToken(env);
      let oauthStatus = token ? "OAuth OK" : "OAuth ERROR: No token returned";
      
      const pt = getPacificTimeParts(new Date());
      
      return new Response(
        `${oauthStatus}\n` + 
        `Server Time: ${pt.month}/${pt.day} ${pt.hour}:${pt.minute} PT\n` +
        `Window: ${GO_LIVE_HOUR}:${GO_LIVE_MIN_START} - ${GO_LIVE_HOUR}:${GO_LIVE_MIN_END}`,
        { status: 200, headers: { "Content-Type": "text/plain" } }
      );
    }

    if (url.searchParams.has("schedule")) {
      return new Response(await scheduleNextSunday(env), { status: 200 });
    }

    if (url.searchParams.has("golive")) {
      return new Response(await goLiveUpcoming(env), { status: 200 });
    }

    return new Response("OK", { status: 200 });
  }
};

/********************************************************************
  SCHEDULE NEXT SUNDAY STREAM (DST AWARE)
********************************************************************/
async function scheduleNextSunday(env) {
  try {
    const apiKey = env.YOUTUBE_API_KEY;
    if (!apiKey) return "❌ Missing env.YOUTUBE_API_KEY";

    // 1. Calculate Next Sunday Date
    const now = new Date();
    const today = now.getUTCDay(); // 0 is Sunday
    const daysUntilSunday = (7 - today) % 7 || 7; 
    
    const nextSunday = new Date(now);
    nextSunday.setUTCDate(now.getUTCDate() + daysUntilSunday);

    // 2. Generate Title
    const m = nextSunday.getUTCMonth() + 1;
    const d = nextSunday.getUTCDate();
    const y = nextSunday.getUTCFullYear();
    const title = `CPC Live - ${m}/${d}/${y}`;
    
    // 3. Set Start Time (AUTO-CORRECT FOR DST)
    // First, try setting UTC based on the assumption we are in Standard time or Daylight
    // We set 17:MM UTC (which is 10:MM PDT / 9:MM PST)
    nextSunday.setUTCHours(17, SCHEDULE_MINUTE_PT, 0, 0);
    
    // Check what time this is in Pacific
    const checkPT = getPacificTimeParts(nextSunday);
    
    // If it resulted in HOUR - 1 (e.g. 9:30 instead of 10:30), add 1 hour
    if (parseInt(checkPT.hour) === SCHEDULE_HOUR_PT - 1) {
      nextSunday.setUTCHours(18, SCHEDULE_MINUTE_PT, 0, 0); // Shift to 18:30 UTC
    }

    const scheduledStart = nextSunday.toISOString();
    const description = "CPC 10:30am Worship Service\nJoin us this Sunday at CPC!";

    // --- DUPLICATE CHECK ---
    const existing = await findVideoInUploads(apiKey, title, 15);
    if (existing)
      return `⚠️ Already scheduled: ${title}\nvideoId=${existing}`;

    // --- CREATE BROADCAST ---
    const token = await getAccessToken(env);

    const createRes = await fetch(
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts?part=snippet,contentDetails,status",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          snippet: {
            title,
            scheduledStartTime: scheduledStart,
            description,
            defaultLanguage: "en",
            defaultAudioLanguage: "en"
          },
          status: {
            privacyStatus: "public",
            selfDeclaredMadeForKids: false
          },
          contentDetails: {
            enableArchive: true,
            enableEmbed: true,
            enableDvr: true
          }
        })
      }
    );

    const create = await safeJson(createRes);
    if (!create.id)
      return `❌ Broadcast creation failed:\n${JSON.stringify(create)}`;

    const broadcastId = create.id;

    // --- BIND STREAM ---
    await fetch(
      `https://youtube.googleapis.com/youtube/v3/liveBroadcasts/bind?id=${broadcastId}&part=id,contentDetails&streamId=${env.YT_STREAM_ID}`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` }
      }
    );

    // --- ID OPTIMIZATION ---
    // Use the broadcastId directly as the videoId (no playlist search needed)
    const videoId = broadcastId;

    // --- UPLOAD THUMBNAIL & UPDATE CATEGORY ---
    const thumbResult = await uploadThumbnail(token, videoId);
    const categoryResult = await updateVideoCategory(token, videoId, title, description);

    return (
      `Scheduled ${title} for ${scheduledStart} (UTC)\n` +
      `videoId=${videoId}\n` +
      `thumbnail=${thumbResult}\n` +
      `category=${categoryResult}`
    );
  } catch (err) {
    return "❌ scheduleNextSunday error:\n" + err.toString();
  }
}

/********************************************************************
  GO LIVE HANDLER (ROBUST WINDOW + DOUBLE CHECK)
********************************************************************/
async function goLiveUpcoming(env) {
  try {
    const token = await getAccessToken(env);
    if (!token) {
        console.log("❌ OAuth token failed");
        return;
    }

    // 1. Get "Today" in Pacific Time
    const nowPT = getPacificTimeParts(new Date());
    
    // 2. Fetch ALL upcoming broadcasts
    const res = await fetch(
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts?part=id,snippet,status&broadcastStatus=upcoming&mine=true&maxResults=5",
      { headers: { Authorization: `Bearer ${token}` } }
    );
    const data = await safeJson(res);

    if (!data.items || data.items.length === 0) {
      console.log("ℹ️ No upcoming broadcasts found. (Already live?)");
      return;
    }

    // 3. Find the broadcast that is scheduled for TODAY
    const match = data.items.find(item => {
      const scheduledDate = new Date(item.snippet.scheduledStartTime);
      const scheduledPT = getPacificTimeParts(scheduledDate);

      // Compare strict Day/Month/Year
      return (
        scheduledPT.day === nowPT.day &&
        scheduledPT.month === nowPT.month &&
        scheduledPT.year === nowPT.year
      );
    });

    if (!match) {
      console.log(`❌ Found streams, but none scheduled for today.`);
      return;
    }

    const broadcastId = match.id;
    const title = match.snippet.title;

    console.log(`Found matching stream: ${title} (${broadcastId}). Sending Live Transition...`);

    // 4. Transition to Live
    const tr = await fetch(
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts/transition" +
        `?part=id,snippet,status` +
        `&broadcastStatus=live&id=${broadcastId}`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` }
      }
    );

    const transition = await safeJson(tr);

    if (tr.status === 409) {
       console.log(`⚠️ Transition returned 409 (Stream likely already live/starting).`);
    } else {
       console.log(`✅ GO LIVE COMMAND SENT: ${JSON.stringify(transition)}`);
    }

    return;
  } catch (err) {
    console.log("❌ goLiveUpcoming error: " + err.toString());
  }
}

/********************************************************************
  HELPER: TIMEZONE (Intl API)
********************************************************************/
function getPacificTimeParts(date) {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    hour12: false 
  });

  const parts = formatter.formatToParts(date);
  const p = {};
  parts.forEach(({ type, value }) => { p[type] = value; });
  
  return {
    year: p.year,
    month: p.month,
    day: p.day,
    hour: p.hour, 
    minute: p.minute.padStart(2, '0')
  };
}

/********************************************************************
  HELPER: AUTH & VIDEO FINDING
********************************************************************/
async function getAccessToken(env) {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.YT_CLIENT_ID,
      client_secret: env.YT_CLIENT_SECRET,
      refresh_token: env.YT_REFRESH_TOKEN,
      grant_type: "refresh_token"
    })
  });

  const j = await safeJson(r);
  return j.access_token || null;
}

async function findVideoInUploads(apiKey, targetTitle, attempts = 15) {
  for (let i = 1; i <= attempts; i++) {
    const params = new URLSearchParams({
      part: "snippet",
      playlistId: UPLOADS_PLAYLIST_ID,
      maxResults: "10",
      key: apiKey
    });

    const res = await fetch(
      `https://www.googleapis.com/youtube/v3/playlistItems?${params}`
    );

    const json = await safeJson(res);

    if (json.items) {
      for (const it of json.items) {
        if (it.snippet?.title?.trim() === targetTitle) {
          return it.snippet.resourceId?.videoId || null;
        }
      }
    }
    if (i < attempts) await new Promise(r => setTimeout(r, 2000));
  }
  return null;
}

async function updateVideoCategory(accessToken, videoId, title, description) {
  try {
    const res = await fetch(
      "https://youtube.googleapis.com/youtube/v3/videos?part=snippet",
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          id: videoId,
          snippet: {
            title,
            description,
            categoryId: CATEGORY_ID
          }
        })
      }
    );
    const json = await safeJson(res);
    return res.ok ? "Category OK" : `❌ Category PATCH failed: ${JSON.stringify(json)}`;
  } catch (err) {
    return `❌ Category error: ${err.toString()}`;
  }
}

async function uploadThumbnail(accessToken, videoId) {
  try {
    const cacheBuster = `?t=${Date.now()}`;
    const img = await fetch(THUMBNAIL_URL + cacheBuster, {
      cf: { cacheTtl: 0 } 
    });
    
    if (!img.ok) {
       return `❌ Failed to fetch source image (HTTP ${img.status})`;
    }

    const imgBuf = await img.arrayBuffer();

    const boundary = "CGI_UPLOAD_" + Math.random().toString(36).slice(2);
    const body = new Blob(
      [
        `--${boundary}\r\n`,
        `Content-Disposition: form-data; name="videoFile"; filename="thumb.png"\r\n`,
        `Content-Type: image/png\r\n\r\n`,
        new Uint8Array(imgBuf),
        `\r\n--${boundary}--\r\n`
      ],
      { type: `multipart/form-data; boundary=${boundary}` }
    );

    const res = await fetch(
      `https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=${videoId}`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": `multipart/form-data; boundary=${boundary}`
        },
        body
      }
    );
    return res.ok ? "Thumbnail OK" : "❌ Upload failed";
  } catch (err) {
    return `❌ Thumb error: ${err.toString()}`;
  }
}
