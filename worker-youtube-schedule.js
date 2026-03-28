/********************************************************************
  YouTube Scheduler + Go-Live Worker
  --------------------------------------------------
  DST Strategy:
    - TWO Sunday crons (17 and 18 UTC) ensure coverage year-round
    - During PST: 18:xx UTC = 10:xx PT ✅ (17:xx = 9:xx PT, skipped)
    - During PDT: 17:xx UTC = 10:xx PT ✅ (18:xx = 11:xx PT, skipped)
    - Time window check filters which cron actually runs
  
  Logging Modes:
    - VERBOSE_LOGGING = true: Full detailed logs (every API call, state change)
    - VERBOSE_LOGGING = false: Condensed logs (just key events and results)
  
  Recent Updates:
    - Two-step transition: testing → live (simulates YouTube Studio preview)
    - Browser-like headers to transition API call
    - 20-second retry delay (reduced from 30 to account for two-step)
    - Feature toggles for scheduling, go-live, and logging verbosity
********************************************************************/

/********************************************************************
  CONFIGURATION
********************************************************************/
// STREAM SCHEDULE: When the event technically starts
const SCHEDULE_HOUR_PT = 10;
const SCHEDULE_MINUTE_PT = 30;

// GO LIVE TIMING
const GO_LIVE_HOUR_PT = 10;
const GO_LIVE_MIN_START = 27;
const GO_LIVE_MIN_END = 35;

const UPLOADS_PLAYLIST_ID = "UUxZ8LTstrCOotf74qO0dOFA";
const THUMBNAIL_URL = "https://covenantpaso.pages.dev/cpc-youtube.png";
const CATEGORY_ID = "29";
const YT_STREAM_ID = "xZ8LTstrCOotf74qO0dOFA1768252326942616";

/********************************************************************
  FEATURE TOGGLES
********************************************************************/
const ENABLE_SCHEDULING = true;  // Set to false to disable Thursday scheduling
const ENABLE_GO_LIVE = true;     // Set to false to disable Sunday go-live
const VERBOSE_LOGGING = true;    // Set to false for condensed logging
const DEVELOPER_MODE = false;    // Set to true to enable ?test, ?keys, ?schedule, ?golive

function devModeOn() {
  return DEVELOPER_MODE === true;
}

/********************************************************************
  ENHANCED LOGGING UTILITIES
********************************************************************/
function logSection(title) {
  if (!VERBOSE_LOGGING) return;
  console.log("\n" + "=".repeat(60));
  console.log(`  ${title}`);
  console.log("=".repeat(60));
}

function logSubSection(title) {
  if (!VERBOSE_LOGGING) return;
  console.log("\n" + "-".repeat(60));
  console.log(`  ${title}`);
  console.log("-".repeat(60));
}

function logKeyValue(key, value) {
  if (!VERBOSE_LOGGING) return;
  console.log(`  ${key.padEnd(25)}: ${value}`);
}

// Simple logging that always shows (even when VERBOSE_LOGGING is false)
function logSimple(message) {
  console.log(message);
}

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
    const cronString = event.cron || "";
    const scheduledTime = event?.scheduledTime ? new Date(event.scheduledTime) : new Date();
    const actualTime = new Date();
    
    const pt = getPacificTimeParts(scheduledTime);
    const dayOfWeek = new Date(scheduledTime).toLocaleString('en-US', { 
      timeZone: 'America/Los_Angeles', 
      weekday: 'long' 
    });

    // Condensed logging (always shows)
    if (!VERBOSE_LOGGING) {
      logSimple(`[${cronString}] ${dayOfWeek} ${pt.year}-${pt.month}-${pt.day} ${pt.hour}:${pt.minute} PT`);
    }
    
    // Verbose logging (detailed)
    logSection("CRON EXECUTION START");
    logKeyValue("Cron Pattern", cronString);
    logKeyValue("Scheduled Time (UTC)", scheduledTime.toISOString());
    logKeyValue("Actual Time (UTC)", actualTime.toISOString());
    logKeyValue("Time Drift", `${Math.abs(actualTime - scheduledTime)}ms`);
    logKeyValue("Pacific Date", `${pt.year}-${pt.month}-${pt.day}`);
    logKeyValue("Pacific Time", `${pt.hour}:${pt.minute}`);
    logKeyValue("Pacific Day of Week", dayOfWeek);

    // THURSDAY SCHEDULING
    if (cronString === "0 6 * * thu") {
      logSection("THURSDAY SCHEDULING JOB");
      logKeyValue("Expected", "Schedule next Sunday's stream");
      
      if (!ENABLE_SCHEDULING) {
        logKeyValue("Status", "⚠️ DISABLED");
        if (VERBOSE_LOGGING) {
          console.log("⚠️ Scheduling is disabled via ENABLE_SCHEDULING flag");
          console.log("Set ENABLE_SCHEDULING = true to enable");
        } else {
          logSimple("⚠️ Scheduling disabled");
        }
        return;
      }
      
      logKeyValue("Will Run", "scheduleNextSunday()");
      logKeyValue("Will NOT Run", "Go-Live logic (skipped)");
      
      if (!VERBOSE_LOGGING) {
        logSimple("📅 Running Thursday scheduling...");
      }
      
      ctx.waitUntil(scheduleNextSunday(env));
      return; // Exit early - don't run Sunday logic
    }

    // SUNDAY GO-LIVE
    // Check if this looks like a Sunday cron (for safety)
    if (!cronString.includes("17") && !cronString.includes("18") && !cronString.includes("sun")) {
      console.log("⚠️  Unknown cron pattern - not Thursday, not Sunday");
      logKeyValue("Cron Pattern", cronString);
      console.log("Skipping all logic\n" + "=".repeat(60) + "\n");
      return;
    }
    
    logSection("SUNDAY GO-LIVE CHECK");
    
    if (!ENABLE_GO_LIVE) {
      logKeyValue("Status", "⚠️ DISABLED");
      if (VERBOSE_LOGGING) {
        console.log("⚠️ Go-Live is disabled via ENABLE_GO_LIVE flag");
        console.log("Set ENABLE_GO_LIVE = true to enable");
        console.log("=".repeat(60) + "\n");
      } else {
        logSimple("⚠️ Go-Live disabled");
      }
      return;
    }
    
    logKeyValue("Will Run", "Go-Live logic (if in window)");
    logKeyValue("Will NOT Run", "Scheduling (Thursday only)");
    
    const currentHour = parseInt(pt.hour, 10);
    const currentMin = parseInt(pt.minute, 10);
    
    logKeyValue("Current Hour (PT)", currentHour);
    logKeyValue("Current Minute (PT)", currentMin);
    logKeyValue("Target Hour (PT)", GO_LIVE_HOUR_PT);
    logKeyValue("Window Start", `${GO_LIVE_HOUR_PT}:${pad2(GO_LIVE_MIN_START)}`);
    logKeyValue("Window End", `${GO_LIVE_HOUR_PT}:${pad2(GO_LIVE_MIN_END)}`);
    
    const hourMatches = currentHour === GO_LIVE_HOUR_PT;
    const minInRange = currentMin >= GO_LIVE_MIN_START && currentMin <= GO_LIVE_MIN_END;
    const inWindow = hourMatches && minInRange;
    
    logKeyValue("Hour Matches?", hourMatches ? "✅ YES" : "❌ NO");
    logKeyValue("Minute In Range?", minInRange ? "✅ YES" : "❌ NO");
    logKeyValue("Inside Window?", inWindow ? "✅ YES - WILL ATTEMPT GO-LIVE" : "❌ NO - SKIPPING");
    
    if (!VERBOSE_LOGGING && !inWindow) {
      logSimple(`⏭️ Outside window (${currentHour}:${pad2(currentMin)} not in ${GO_LIVE_HOUR_PT}:${pad2(GO_LIVE_MIN_START)}-${GO_LIVE_HOUR_PT}:${pad2(GO_LIVE_MIN_END)})`);
    }
    
    if (!hourMatches) {
      logSubSection("WHY SKIPPING: Hour Mismatch");
      logKeyValue("Expected Hour", GO_LIVE_HOUR_PT);
      logKeyValue("Actual Hour", currentHour);
      logKeyValue("Explanation", currentHour < GO_LIVE_HOUR_PT ? "Too early" : "Too late");
      
      // DST explanation
      if (cronString.includes("17")) {
        console.log("\n  ℹ️  This is the 17:xx UTC cron");
        console.log("     During PST (winter): 17 UTC = 9 AM PT → Too early ⏭️");
        console.log("     During PDT (summer): 17 UTC = 10 AM PT → Perfect ✅");
        console.log("     Current season appears to be PST (winter)");
      } else if (cronString.includes("18")) {
        console.log("\n  ℹ️  This is the 18:xx UTC cron");
        console.log("     During PST (winter): 18 UTC = 10 AM PT → Perfect ✅");
        console.log("     During PDT (summer): 18 UTC = 11 AM PT → Too late ⏭️");
        console.log("     Current season appears to be PDT (summer)");
      }
      
      console.log("\n" + "=".repeat(60) + "\n");
      return;
    }
    
    if (!minInRange) {
      logSubSection("WHY SKIPPING: Outside Minute Window");
      logKeyValue("Current Minute", currentMin);
      logKeyValue("Too Early?", currentMin < GO_LIVE_MIN_START ? "YES" : "NO");
      logKeyValue("Too Late?", currentMin > GO_LIVE_MIN_END ? "YES" : "NO");
      console.log("\n" + "=".repeat(60) + "\n");
      return;
    }

    // INSIDE WINDOW - ATTEMPT GO-LIVE
    logSubSection("🎬 EXECUTING GO-LIVE SEQUENCE");
    
    if (!VERBOSE_LOGGING) {
      logSimple(`🎬 Inside window - attempting go-live...`);
    }
    
    ctx.waitUntil(
      (async () => {
        try {
          logKeyValue("Strategy", "2 attempts, 20 seconds apart");
          
          if (VERBOSE_LOGGING) {
            console.log("\n🚀 ATTEMPT 1/2");
            console.log("   Time:", new Date().toISOString());
          }
          const result1 = await goLiveToday(env);
          
          if (VERBOSE_LOGGING) {
            logKeyValue("Attempt 1 Result", result1);
          } else {
            logSimple(`🚀 Attempt 1: ${result1}`);
          }
          
          if (result1 === "ALREADY_LIVE") {
            if (VERBOSE_LOGGING) {
              console.log("\n✅ Stream already live - no retry needed");
              console.log("=".repeat(60) + "\n");
            } else {
              logSimple("✅ Already live");
            }
            return;
          }

          if (VERBOSE_LOGGING) {
            console.log("\n⏳ Waiting 20 seconds before attempt 2...");
          }
          await new Promise(resolve => setTimeout(resolve, 20000));

          if (VERBOSE_LOGGING) {
            console.log("\n🚀 ATTEMPT 2/2");
            console.log("   Time:", new Date().toISOString());
          }
          const result2 = await goLiveToday(env);
          
          if (VERBOSE_LOGGING) {
            logKeyValue("Attempt 2 Result", result2);
            console.log("\n" + "=".repeat(60) + "\n");
          } else {
            logSimple(`🚀 Attempt 2: ${result2}`);
          }
        } catch (err) {
          console.error("\n❌ GO-LIVE SEQUENCE ERROR:", err);
          if (VERBOSE_LOGGING) {
            console.error("Stack:", err.stack);
            console.log("\n" + "=".repeat(60) + "\n");
          }
        }
      })()
    );
  },

  async fetch(request, env) {
    const url = new URL(request.url);

    const hasAnyFlags =
      url.searchParams.has("keys") ||
      url.searchParams.has("test") ||
      url.searchParams.has("schedule") ||
      url.searchParams.has("golive");

    if (hasAnyFlags && !devModeOn()) {
      return new Response("Not Found", { status: 404 });
    }

    if (url.searchParams.has("keys")) {
      const token = await getAccessToken(env);
      if (!token) return new Response("OAuth Failed", { status: 500 });

      const res = await fetch(
        "https://youtube.googleapis.com/youtube/v3/liveStreams?part=id,snippet&mine=true",
        { headers: { Authorization: `Bearer ${token}` } }
      );

      const data = await safeJson(res);
      if (!data.items) return new Response(JSON.stringify(data, null, 2));

      const summary = data.items.map((item) => ({
        TITLE: item.snippet.title,
        STREAM_ID: item.id
      }));

      return new Response(JSON.stringify(summary, null, 2), {
        headers: { "Content-Type": "application/json" }
      });
    }

    if (url.searchParams.has("test")) {
      const token = await getAccessToken(env);
      const now = new Date();
      const pt = getPacificTimeParts(now);
      const currentHour = parseInt(pt.hour, 10);
      const currentMin = parseInt(pt.minute, 10);
      
      const inWindow = 
        currentHour === GO_LIVE_HOUR_PT &&
        currentMin >= GO_LIVE_MIN_START &&
        currentMin <= GO_LIVE_MIN_END;
      
      let report = `OAUTH STATUS\n`;
      report += `  Token Retrieved: ${token ? "✅ Yes" : "❌ No"}\n`;
      
      // Test token scopes and permissions
      if (token) {
        // Test 1: Get token info (check scopes)
        try {
          const tokenInfoRes = await fetch(
            `https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=${token}`
          );
          const tokenInfo = await tokenInfoRes.json();
          
          if (tokenInfoRes.ok && tokenInfo.scope) {
            const scopes = tokenInfo.scope.split(' ');
            const hasYouTube = scopes.some(s => s.includes('youtube') && !s.includes('readonly'));
            report += `  Scopes Valid: ${hasYouTube ? "✅ Yes" : "❌ No (missing write permission)"}\n`;
            report += `  Token Expires: ${tokenInfo.expires_in} seconds\n`;
          } else {
            report += `  Scopes Valid: ⚠️ Unable to verify\n`;
          }
        } catch (e) {
          report += `  Scopes Valid: ⚠️ Check failed\n`;
        }
        
        // Test 2: Can we list broadcasts?
        try {
          const listRes = await fetch(
            "https://youtube.googleapis.com/youtube/v3/liveBroadcasts?part=id&mine=true&maxResults=1",
            { headers: { Authorization: `Bearer ${token}` } }
          );
          report += `  Can List Broadcasts: ${listRes.ok ? "✅ Yes" : `❌ No (${listRes.status})`}\n`;
        } catch (e) {
          report += `  Can List Broadcasts: ❌ Error\n`;
        }
        
        // Test 3: Check channel access
        try {
          const channelRes = await fetch(
            "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true",
            { headers: { Authorization: `Bearer ${token}` } }
          );
          const channelData = await channelRes.json();
          if (channelRes.ok && channelData.items?.[0]) {
            report += `  Channel Access: ✅ ${channelData.items[0].snippet.title}\n`;
          } else {
            report += `  Channel Access: ❌ Failed (${channelRes.status})\n`;
          }
        } catch (e) {
          report += `  Channel Access: ❌ Error\n`;
        }
      }
      
      report += `\nTIME INFORMATION\n`;
      report += `  Server UTC: ${now.toISOString()}\n`;
      report += `  Pacific: ${pt.year}-${pt.month}-${pt.day} ${pt.hour}:${pt.minute}\n`;
      report += `  Day: ${now.toLocaleString('en-US', { timeZone: 'America/Los_Angeles', weekday: 'long' })}\n`;
      
      report += `\nWINDOW CONFIGURATION\n`;
      report += `  Target: ${GO_LIVE_HOUR_PT}:${pad2(GO_LIVE_MIN_START)} - ${GO_LIVE_HOUR_PT}:${pad2(GO_LIVE_MIN_END)} PT\n`;
      report += `  In Window: ${inWindow ? "YES ✅" : "NO ⏭️"}\n`;
      
      report += `\nDST INFORMATION\n`;
      report += `  17 UTC = ${getPacificTimeParts(new Date(Date.UTC(2025, 1, 1, 17, 0))).hour}:00 PT (winter/PST)\n`;
      report += `  18 UTC = ${getPacificTimeParts(new Date(Date.UTC(2025, 1, 1, 18, 0))).hour}:00 PT (winter/PST)\n`;
      
      report += `\nDEVELOPER MODE: ${DEVELOPER_MODE}\n`;
      
      // Add diagnosis
      if (token) {
        report += `\n${"=".repeat(60)}\n`;
        report += `DIAGNOSIS:\n`;
        report += `If all checks above show ✅, your OAuth is configured correctly.\n`;
        report += `If you see ❌ on "Scopes Valid" or "Can List Broadcasts",\n`;
        report += `you need to regenerate your refresh token with full permissions.\n`;
      }
      
      return new Response(report, { 
        status: 200, 
        headers: { "Content-Type": "text/plain; charset=utf-8" } 
      });
    }

    if (url.searchParams.has("schedule")) {
      const result = await scheduleNextSunday(env);
      return new Response(result, { status: 200 });
    }

    if (url.searchParams.has("golive")) {
      await goLiveToday(env);
      return new Response("GoLive attempted (check logs).", { status: 200 });
    }

    return new Response("OK", { status: 200 });
  }
};

/********************************************************************
  SCHEDULE NEXT SUNDAY STREAM
********************************************************************/
async function scheduleNextSunday(env) {
  try {
    logSubSection("Starting Schedule Process");
    
    const apiKey = env.YOUTUBE_API_KEY;
    if (!apiKey) {
      console.error("❌ Missing env.YOUTUBE_API_KEY");
      return "❌ Missing env.YOUTUBE_API_KEY";
    }
    logKeyValue("API Key", "✅ Present");

    // Calculate next Sunday
    const now = new Date();
    const today = now.getUTCDay();
    const daysUntilSunday = (7 - today) % 7 || 7;
    
    logKeyValue("Today (UTC)", now.toISOString());
    logKeyValue("Day of Week", ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][today]);
    logKeyValue("Days Until Sunday", daysUntilSunday);
    
    const nextSunday = new Date(now);
    nextSunday.setUTCDate(now.getUTCDate() + daysUntilSunday);

    // Generate title
    const m = nextSunday.getUTCMonth() + 1;
    const d = nextSunday.getUTCDate();
    const y = nextSunday.getUTCFullYear();
    const title = `CPC Live - ${m}/${d}/${y}`;
    
    logKeyValue("Next Sunday (UTC)", nextSunday.toISOString().split('T')[0]);
    logKeyValue("Title", title);

    // Set start time with DST auto-correction
    logSubSection("DST Auto-Correction");
    
    nextSunday.setUTCHours(17, SCHEDULE_MINUTE_PT, 0, 0);
    logKeyValue("Initial UTC Time", nextSunday.toISOString());
    
    const checkPT = getPacificTimeParts(nextSunday);
    logKeyValue("Converts to PT", `${checkPT.hour}:${checkPT.minute}`);
    logKeyValue("Target PT", `${SCHEDULE_HOUR_PT}:${pad2(SCHEDULE_MINUTE_PT)}`);
    
    if (parseInt(checkPT.hour, 10) === SCHEDULE_HOUR_PT - 1) {
      console.log("  ⚠️  Hour is one less than target (PST detected)");
      nextSunday.setUTCHours(18, SCHEDULE_MINUTE_PT, 0, 0);
      const newCheckPT = getPacificTimeParts(nextSunday);
      logKeyValue("Adjusted UTC Time", nextSunday.toISOString());
      logKeyValue("New PT Time", `${newCheckPT.hour}:${newCheckPT.minute}`);
      logKeyValue("Correction", "Added 1 hour to compensate for PST");
    } else {
      console.log("  ✅ Hour matches target (PDT detected or already correct)");
    }

    const scheduledStart = nextSunday.toISOString();
    const description = "CPC 10:30am Worship Service\nJoin us this Sunday at CPC!";

    // Check for duplicates
    logSubSection("Duplicate Check");
    logKeyValue("Checking uploads for", title);
    
    const existing = await findVideoInUploads(apiKey, title, 15);
    if (existing) {
      console.log(`  ⚠️  Found existing: ${existing}`);
      return `⚠️ Already scheduled: ${title}\nvideoId=${existing}`;
    }
    logKeyValue("Duplicate Check", "✅ No duplicates found");

    // Create broadcast
    logSubSection("Creating Broadcast");
    
    const token = await getAccessToken(env);
    if (!token) {
      console.error("❌ OAuth token failed");
      return "❌ OAuth token failed";
    }
    logKeyValue("OAuth Token", "✅ Obtained");

    const createPayload = {
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
    };
    
    console.log("  Request Payload:", JSON.stringify(createPayload, null, 2));
    
    const createRes = await fetch(
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts?part=snippet,contentDetails,status",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify(createPayload)
      }
    );

    logKeyValue("Response Status", createRes.status);
    
    const create = await safeJson(createRes);
    console.log("  Response Body:", JSON.stringify(create, null, 2));
    
    if (!create.id) {
      console.error("❌ Broadcast creation failed");
      return `❌ Broadcast creation failed:\n${JSON.stringify(create)}`;
    }

    const broadcastId = create.id;
    logKeyValue("Broadcast ID", broadcastId);
    logKeyValue("Initial State", create.status?.lifeCycleStatus || "unknown");

    // Bind stream
    logSubSection("Binding Stream");
    logKeyValue("Stream ID", YT_STREAM_ID);
    
    const bindRes = await fetch(
      `https://youtube.googleapis.com/youtube/v3/liveBroadcasts/bind?id=${broadcastId}&part=id,contentDetails&streamId=${YT_STREAM_ID}`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` }
      }
    );

    const bind = await safeJson(bindRes);
    logKeyValue("Bind Status", bindRes.status);
    console.log("  Bind Response:", JSON.stringify(bind, null, 2));

    // Upload thumbnail & update category
    logSubSection("Post-Processing");
    
    const thumbResult = await uploadThumbnail(token, broadcastId);
    logKeyValue("Thumbnail Upload", thumbResult);
    
    const categoryResult = await updateVideoCategory(token, broadcastId, title, description);
    logKeyValue("Category Update", categoryResult);

    logSection("SCHEDULING COMPLETE");
    return (
      `✅ Successfully scheduled: ${title}\n` +
      `Scheduled Time: ${scheduledStart}\n` +
      `Video ID: ${broadcastId}\n` +
      `Thumbnail: ${thumbResult}\n` +
      `Category: ${categoryResult}`
    );
  } catch (err) {
    console.error("❌ scheduleNextSunday error:", err);
    console.error("Stack:", err.stack);
    return "❌ scheduleNextSunday error:\n" + err.toString();
  }
}

/********************************************************************
  GO LIVE TODAY'S BROADCAST
********************************************************************/
async function goLiveToday(env) {
  try {
    logSubSection("OAuth Authentication");
    
    const token = await getAccessToken(env);
    if (!token) {
      console.error("❌ Failed to get OAuth token");
      return "ERROR";
    }
    logKeyValue("OAuth Token", "✅ Obtained");

    // Get today's date in PT
    const nowPT = getPacificTimeParts(new Date());
    const todayPT = `${nowPT.month}/${nowPT.day}/${nowPT.year}`;
    
    if (!VERBOSE_LOGGING) {
      logSimple(`  Looking for broadcast: ${todayPT}`);
    }
    
    logSubSection("Fetching Broadcasts");
    logKeyValue("Looking for date (PT)", todayPT);
    
    const apiUrl = 
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts" +
      "?part=id,snippet,status" +
      "&mine=true" +
      "&broadcastType=event" +
      "&maxResults=25";
    
    logKeyValue("API Endpoint", apiUrl);
    
    const res = await fetch(apiUrl, {
      headers: { Authorization: `Bearer ${token}` }
    });

    logKeyValue("Response Status", res.status);
    
    const data = await safeJson(res);

    if (data._parseError) {
      console.error("❌ JSON parse error:", data.raw);
      return "ERROR";
    }
    if (!res.ok) {
      console.error(`❌ API error (${res.status}):`, JSON.stringify(data, null, 2));
      return "ERROR";
    }
    if (!data.items || data.items.length === 0) {
      console.log("ℹ️  No broadcasts found");
      return "NOT_FOUND";
    }

    logKeyValue("Total Broadcasts Found", data.items.length);
    
    // Filter for today's broadcasts first
    const todaysBroadcasts = data.items.filter((item) => {
      const scheduledStr = item.snippet?.scheduledStartTime;
      if (!scheduledStr) return false;

      const scheduledPT = getPacificTimeParts(new Date(scheduledStr));
      const isToday = 
        scheduledPT.day === nowPT.day &&
        scheduledPT.month === nowPT.month &&
        scheduledPT.year === nowPT.year;

      return isToday;
    });

    logKeyValue("Today's Broadcasts", todaysBroadcasts.length);
    
    // Only log detailed info for today's broadcasts
    if (todaysBroadcasts.length > 0) {
      logSubSection("Today's Broadcast Details");
      todaysBroadcasts.forEach((item, idx) => {
        const scheduledStr = item.snippet?.scheduledStartTime;
        const scheduledPT = scheduledStr ? getPacificTimeParts(new Date(scheduledStr)) : null;
        
        console.log(`\n  [${idx + 1}] ${item.snippet?.title}`);
        logKeyValue("    ID", item.id);
        logKeyValue("    Scheduled (UTC)", scheduledStr || "N/A");
        if (scheduledPT) {
          logKeyValue("    Scheduled (PT)", `${scheduledPT.month}/${scheduledPT.day}/${scheduledPT.year} ${scheduledPT.hour}:${scheduledPT.minute}`);
        }
        logKeyValue("    State", item.status?.lifeCycleStatus || "unknown");
        logKeyValue("    Privacy", item.status?.privacyStatus || "unknown");
      });
    }

    // Filter for today's broadcasts
    logSubSection("Selection Process");
    
    if (todaysBroadcasts.length === 0) {
      console.log("❌ No broadcasts match today's date");
      return "NOT_FOUND";
    }

    // Check if any are already live
    logSubSection("Checking Current State");
    
    const alreadyLive = todaysBroadcasts.find(b => b.status?.lifeCycleStatus === "live");
    if (alreadyLive) {
      console.log(`✅ Already live: "${alreadyLive.snippet.title}"`);
      logKeyValue("Broadcast ID", alreadyLive.id);
      return "ALREADY_LIVE";
    }

    // Find best candidate
    const stateOrder = ["ready", "testing", "testStarting", "upcoming"];
    
    let broadcast = null;
    let selectedReason = "";
    
    for (const state of stateOrder) {
      broadcast = todaysBroadcasts.find(b => b.status?.lifeCycleStatus === state);
      if (broadcast) {
        selectedReason = `Best state: ${state}`;
        break;
      }
    }

    if (!broadcast) {
      broadcast = todaysBroadcasts[0];
      selectedReason = "Fallback: first broadcast";
    }

    logSubSection("Selected Broadcast");
    logKeyValue("Title", broadcast.snippet?.title);
    logKeyValue("ID", broadcast.id);
    logKeyValue("Current State", broadcast.status?.lifeCycleStatus);
    logKeyValue("Privacy", broadcast.status?.privacyStatus);
    logKeyValue("Selection Reason", selectedReason);

    // Two-step transition: testing → live
    // This simulates what YouTube Studio does when you preview the stream
    logSubSection("Transitioning to Live (Two-Step Process)");
    
    // STEP 1: Transition to testing
    if (!VERBOSE_LOGGING) {
      logSimple(`  Step 1: Transitioning to testing...`);
    }
    
    logKeyValue("Step 1", "Transition to testing");
    const testingUrl = 
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts/transition" +
      `?part=id,snippet,status` +
      `&broadcastStatus=testing` +
      `&id=${broadcast.id}`;
    
    logKeyValue("Endpoint", testingUrl);
    
    const testingRes = await fetch(testingUrl, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Accept-Language": "en-US,en;q=0.9",
        "Content-Type": "application/json",
        "Origin": "https://studio.youtube.com",
        "Referer": "https://studio.youtube.com/"
      }
    });
    
    logKeyValue("Testing Response", testingRes.status);
    
    const testingData = await safeJson(testingRes);
    
    if (VERBOSE_LOGGING) {
      console.log("  Response Body:", JSON.stringify(testingData, null, 2));
    }
    
    if (!testingRes.ok) {
      const errorMsg = testingData.error?.message || "No message";
      const errorReason = testingData.error?.errors?.[0]?.reason || "Unknown";
      
      if (VERBOSE_LOGGING) {
        console.error(`❌ Testing transition failed (${testingRes.status})`);
        if (testingData.error) {
          logKeyValue("Error Message", errorMsg);
          logKeyValue("Error Reason", errorReason);
          console.log("  Full Error:", JSON.stringify(testingData.error, null, 2));
        }
      } else {
        logSimple(`  ❌ Testing failed (${testingRes.status}): ${errorMsg} [${errorReason}]`);
      }
      
      return "ERROR";
    }
    
    if (VERBOSE_LOGGING) {
      logKeyValue("Testing State", testingData.status?.lifeCycleStatus);
      console.log("  ✅ Successfully transitioned to testing");
    } else {
      logSimple(`  ✅ Testing transition successful`);
    }
    
    // Wait for YouTube to stabilize
    logKeyValue("Waiting", "10 seconds for YouTube to stabilize...");
    if (!VERBOSE_LOGGING) {
      logSimple(`  Waiting 10 seconds...`);
    }
    await new Promise(resolve => setTimeout(resolve, 10000));
    
    // STEP 2: Transition to live
    if (!VERBOSE_LOGGING) {
      logSimple(`  Step 2: Transitioning to live...`);
    }
    
    logKeyValue("Step 2", "Transition to live");
    const liveUrl = 
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts/transition" +
      `?part=id,snippet,status` +
      `&broadcastStatus=live` +
      `&id=${broadcast.id}`;
    
    logKeyValue("Endpoint", liveUrl);
    
    const liveRes = await fetch(liveUrl, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json",
        "Accept-Language": "en-US,en;q=0.9",
        "Content-Type": "application/json",
        "Origin": "https://studio.youtube.com",
        "Referer": "https://studio.youtube.com/"
      }
    });

    logKeyValue("Live Response", liveRes.status);
    
    const liveData = await safeJson(liveRes);
    
    if (VERBOSE_LOGGING) {
      console.log("  Response Body:", JSON.stringify(liveData, null, 2));
    }

    if (liveRes.status === 409) {
      if (VERBOSE_LOGGING) {
        console.log(`⚠️  409 Conflict - Broadcast may be transitioning`);
        if (liveData.error?.message) {
          logKeyValue("Error Message", liveData.error.message);
        }
      } else {
        logSimple(`  ⚠️ 409 Conflict: ${liveData.error?.message || 'Still transitioning'}`);
      }
      return "RETRY_LATER";
    }

    if (!liveRes.ok) {
      const errorMsg = liveData.error?.message || "No message";
      const errorReason = liveData.error?.errors?.[0]?.reason || "Unknown";
      
      if (VERBOSE_LOGGING) {
        console.error(`❌ Live transition failed (${liveRes.status})`);
        if (liveData.error) {
          logKeyValue("Error Message", errorMsg);
          logKeyValue("Error Reason", errorReason);
          logKeyValue("Error Domain", liveData.error.errors?.[0]?.domain || "Unknown");
          console.log("  Full Error:", JSON.stringify(liveData.error, null, 2));
        }
        
        // Special handling for 403
        if (liveRes.status === 403) {
          console.log("\n⚠️  403 FORBIDDEN - Possible causes:");
          console.log("  1. Broadcast not in transitionable state");
          console.log("  2. Stream not connected/health check failing");
          console.log("\n  🔍 Check YouTube Studio manually:");
          console.log(`     https://studio.youtube.com/video/${broadcast.id}/livestreaming`);
        }
      } else {
        logSimple(`  ❌ Live transition failed (${liveRes.status}): ${errorMsg} [${errorReason}]`);
      }
      
      return "ERROR";
    }

    const newState = liveData.status?.lifeCycleStatus;
    
    if (VERBOSE_LOGGING) {
      console.log(`\n✅ TWO-STEP TRANSITION SUCCESSFUL!`);
      logKeyValue("Final State", newState);
    } else {
      logSimple(`  ✅ Success! State: ${newState}`);
    }
    
    return newState === "live" ? "ALREADY_LIVE" : "SUCCESS";
    
  } catch (err) {
    console.error("❌ goLiveToday error:", err);
    console.error("Stack:", err.stack);
    return "ERROR";
  }
}

/********************************************************************
  HELPER: TIMEZONE
********************************************************************/
function getPacificTimeParts(date) {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  });

  const parts = formatter.formatToParts(date);
  const p = {};
  parts.forEach(({ type, value }) => {
    p[type] = value;
  });

  return {
    year: p.year,
    month: p.month,
    day: p.day,
    hour: p.hour,
    minute: p.minute
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

    const res = await fetch(`https://www.googleapis.com/youtube/v3/playlistItems?${params}`);
    const json = await safeJson(res);

    if (json.items) {
      for (const it of json.items) {
        if (it.snippet?.title?.trim() === targetTitle) {
          return it.snippet.resourceId?.videoId || null;
        }
      }
    }
    if (i < attempts) await new Promise((r) => setTimeout(r, 2000));
  }
  return null;
}

async function updateVideoCategory(accessToken, videoId, title, description) {
  try {
    const res = await fetch("https://youtube.googleapis.com/youtube/v3/videos?part=snippet", {
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
    });
    const json = await safeJson(res);
    return res.ok ? "✅ OK" : `❌ FAILED: ${JSON.stringify(json)}`;
  } catch (err) {
    return `❌ Error: ${err.toString()}`;
  }
}

async function uploadThumbnail(accessToken, videoId) {
  try {
    const cacheBuster = `?t=${Date.now()}`;
    const img = await fetch(THUMBNAIL_URL + cacheBuster, {
      cf: { cacheTtl: 0 }
    });

    if (!img.ok) {
      return `❌ Fetch failed (${img.status})`;
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
    
    return res.ok ? "✅ OK" : `❌ Upload failed (${res.status})`;
  } catch (err) {
    return `❌ Error: ${err.toString()}`;
  }
}

/********************************************************************
  SMALL UTILS
********************************************************************/
function pad2(n) {
  const s = String(n);
  return s.length === 1 ? `0${s}` : s;
}
