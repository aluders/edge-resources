/********************************************************************
  YouTube Scheduler + Go-Live + Auto-End Worker  v1.0
  --------------------------------------------------
  Cron Schedule:
    - 0 6 * * thu    Thursday: auto-schedule next Sunday's broadcast
    - Sunday crons:  One or more UTC crons to cover your go-live window
                     in both PDT (UTC-7) and PST (UTC-8). If your window
                     crosses a UTC hour boundary you may need 3 crons.
                     Example (9 AM service): * 15, * 16, * 17 * * sun
                     Example (10:30 service): * 17, * 18 * * sun
    - End stream:    Single cron at the UTC hour that falls within your
                     end window in both seasons (window must be wide enough
                     to contain both PT times).
                     Example: 0 20 * * sun covers 1PM PDT / 12PM PST

  DST Strategy:
    - Time window checks (in PT) filter which cron executions actually run
    - Go-live window may need 2-3 Sunday crons if it crosses a UTC hour
      boundary - the window check handles the rest automatically
    - Scheduling uses SCHEDULE_HOUR_PT + 7 (PDT) as starting UTC, then
      checks and adjusts +1 hour if PST is detected
    - PDT (summer): UTC-7  |  PST (winter): UTC-8

  Required OAuth Scopes (all three needed for full functionality):
    - https://www.googleapis.com/auth/youtube
    - https://www.googleapis.com/auth/youtube.force-ssl
    - https://www.googleapis.com/auth/gmail.send

  Cloudflare Environment Variables:
    Secrets (encrypted):
      - YT_CLIENT_ID
      - YT_CLIENT_SECRET
      - YT_REFRESH_TOKEN
    Plain text (not encrypted, easy to update):
      - NOTIFICATION_TO  comma-separated email/SMS addresses

  Logging Modes:
    - VERBOSE_LOGGING = true: Full detailed logs (every API call, state change)
    - VERBOSE_LOGGING = false: Condensed logs (just key events and results)

  Developer Endpoints (requires DEVELOPER_MODE = true):
    - ?test       OAuth status, scopes, channel access, window config
    - ?keys       List all live stream IDs bound to this channel
    - ?schedule   Manually trigger next Sunday's broadcast creation
    - ?golive     Manually trigger go-live (finds any upcoming broadcast)
    - ?endstream  Manually trigger end-stream (today's live broadcast only)

  Changelog:
    v1.0 - Initial versioned release
         - Full scheduling, go-live, auto-end, and notification pipeline
         - OAuth-only (no API key required)
         - DST-aware scheduling and go-live windows
         - Two-step transition (testing → live)
         - SMS gateway notification support via Gmail API
         - NOTIFICATION_TO moved to Cloudflare plain text env variable
********************************************************************/

/********************************************************************
  CONFIGURATION
********************************************************************/
// STREAM SCHEDULE: When the event technically starts
const SCHEDULE_HOUR_PT = 9;
const SCHEDULE_MINUTE_PT = 0;

// GO LIVE TIMING: When to start attempting to go live
// For a 10:30 service, start at 10:27 and end at 10:35
// For a 9:00 service, you might use 8:57 to 9:05
const GO_LIVE_START_HOUR_PT = 8;   // Hour to start attempting (PT)
const GO_LIVE_START_MIN_PT = 55;    // Minute to start attempting (PT)
const GO_LIVE_END_HOUR_PT = 9;     // Hour to stop attempting (PT)
const GO_LIVE_END_MIN_PT = 10;      // Minute to stop attempting (PT)

// END STREAM TIMING: When to automatically end the live stream
// For a 10:30-12:00 service, you might use 12:00 to 12:03
const END_STREAM_START_HOUR_PT = 13;  // Hour to start attempting to end (PT)
const END_STREAM_START_MIN_PT = 0;    // Minute to start attempting to end (PT)
const END_STREAM_END_HOUR_PT = 13;    // Hour to stop attempting to end (PT)
const END_STREAM_END_MIN_PT = 5;      // Minute to stop attempting to end (PT)

// PRIVACY: "public", "unlisted", or "private"
const PRIVACY_STATUS = "unlisted";

// BROADCAST NAMING: Every character before the date (e.g., "CPC Live - " → "CPC Live - 6/7/2026")
const BROADCAST_TITLE_PREFIX = "Abide Live - ";

// BROADCAST DESCRIPTION: Shown on the YouTube video
const BROADCAST_DESCRIPTION = "Abide Calvary Sunday Service\nJoin us this Sunday!";

const THUMBNAIL_URL = "https://abide.pages.dev/thumbnail-hd-white.png";
const CATEGORY_ID = "29";
const YT_STREAM_ID = "Bl48WQE_6YH4u4rbpVtlqA1778617073153287"; // YouTube stream ID for binding

// GO-LIVE NOTIFICATION: Keep subject and body short for SMS gateways (plain text only, no emoji)
// NOTIFICATION_TO is set as a plain text Cloudflare environment variable (not in code)
const NOTIFICATION_SUBJECT = "Abide Live";
const NOTIFICATION_BODY = "Sunday service is now live.";

/********************************************************************
  FEATURE TOGGLES
********************************************************************/
const ENABLE_SCHEDULING = true;  // Set to false to disable Thursday scheduling
const ENABLE_GO_LIVE = true;     // Set to false to disable Sunday go-live
const ENABLE_AUTO_END = true;    // Set to true to automatically end stream at specified time
const ENABLE_GO_LIVE_NOTIFICATION = false;  // Set to true to send email/SMS when stream goes live
const VERBOSE_LOGGING = true;    // Set to false for condensed logging

const DEVELOPER_MODE = false;    // Set to true to enable ?test, ?keys, etc.

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
    if (!cronString.includes("sun")) {
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
    
    // Convert times to minutes since midnight for easier comparison
    const currentTimeMinutes = currentHour * 60 + currentMin;
    const windowStartMinutes = GO_LIVE_START_HOUR_PT * 60 + GO_LIVE_START_MIN_PT;
    const windowEndMinutes = GO_LIVE_END_HOUR_PT * 60 + GO_LIVE_END_MIN_PT;
    
    logKeyValue("Current Time (PT)", `${currentHour}:${pad2(currentMin)}`);
    logKeyValue("Window Start", `${GO_LIVE_START_HOUR_PT}:${pad2(GO_LIVE_START_MIN_PT)}`);
    logKeyValue("Window End", `${GO_LIVE_END_HOUR_PT}:${pad2(GO_LIVE_END_MIN_PT)}`);
    
    const inWindow = currentTimeMinutes >= windowStartMinutes && currentTimeMinutes <= windowEndMinutes;
    
    logKeyValue("Inside Window?", inWindow ? "✅ YES - WILL ATTEMPT GO-LIVE" : "❌ NO - SKIPPING");
    
    if (!VERBOSE_LOGGING && !inWindow) {
      logSimple(`⏭️ Outside window (${currentHour}:${pad2(currentMin)} not in ${GO_LIVE_START_HOUR_PT}:${pad2(GO_LIVE_START_MIN_PT)}-${GO_LIVE_END_HOUR_PT}:${pad2(GO_LIVE_END_MIN_PT)})`);
    }
    
    if (!inWindow) {
      logSubSection("WHY SKIPPING: Outside Time Window");
      logKeyValue("Current Time", `${currentHour}:${pad2(currentMin)}`);
      logKeyValue("Window", `${GO_LIVE_START_HOUR_PT}:${pad2(GO_LIVE_START_MIN_PT)} - ${GO_LIVE_END_HOUR_PT}:${pad2(GO_LIVE_END_MIN_PT)}`);
      
      if (currentTimeMinutes < windowStartMinutes) {
        logKeyValue("Reason", "Too early");
      } else {
        logKeyValue("Reason", "Too late");
      }
      
      console.log("\n" + "=".repeat(60) + "\n");
      // No return here - fall through to end-stream check
    } else {

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
          const result1 = await goLiveToday(env, true); // true = today only (production)
          
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
          const result2 = await goLiveToday(env, true); // true = today only (production)
          
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
    } // end of else (inWindow go-live)
    
    // CHECK FOR AUTO-END STREAM WINDOW
    if (!ENABLE_AUTO_END) {
      // Auto-end is disabled, skip this check
      return;
    }
    
    logSection("AUTO-END STREAM CHECK");
    
    // Check if we're in the end-stream window
    const endWindowStartMinutes = END_STREAM_START_HOUR_PT * 60 + END_STREAM_START_MIN_PT;
    const endWindowEndMinutes = END_STREAM_END_HOUR_PT * 60 + END_STREAM_END_MIN_PT;
    const inEndWindow = currentTimeMinutes >= endWindowStartMinutes && currentTimeMinutes <= endWindowEndMinutes;
    
    logKeyValue("Current Time (PT)", `${currentHour}:${pad2(currentMin)}`);
    logKeyValue("End Window Start", `${END_STREAM_START_HOUR_PT}:${pad2(END_STREAM_START_MIN_PT)}`);
    logKeyValue("End Window End", `${END_STREAM_END_HOUR_PT}:${pad2(END_STREAM_END_MIN_PT)}`);
    logKeyValue("Inside End Window?", inEndWindow ? "✅ YES - WILL ATTEMPT TO END" : "❌ NO - SKIPPING");
    
    if (!VERBOSE_LOGGING && !inEndWindow) {
      logSimple(`⏭️ Outside end window (${currentHour}:${pad2(currentMin)} not in ${END_STREAM_START_HOUR_PT}:${pad2(END_STREAM_START_MIN_PT)}-${END_STREAM_END_HOUR_PT}:${pad2(END_STREAM_END_MIN_PT)})`);
    }
    
    if (!inEndWindow) {
      if (VERBOSE_LOGGING) {
        logSubSection("WHY SKIPPING: Outside End Window");
        logKeyValue("Current Time", `${currentHour}:${pad2(currentMin)}`);
        logKeyValue("Window", `${END_STREAM_START_HOUR_PT}:${pad2(END_STREAM_START_MIN_PT)} - ${END_STREAM_END_HOUR_PT}:${pad2(END_STREAM_END_MIN_PT)}`);
        console.log("\n" + "=".repeat(60) + "\n");
      }
      return;
    }
    
    // INSIDE END WINDOW - ATTEMPT TO END STREAM
    logSubSection("🛑 EXECUTING END-STREAM SEQUENCE");
    
    if (!VERBOSE_LOGGING) {
      logSimple(`🛑 Inside end window - attempting to end stream...`);
    }
    
    ctx.waitUntil(
      (async () => {
        try {
          const result = await endStreamToday(env);
          
          if (VERBOSE_LOGGING) {
            logKeyValue("End Stream Result", result);
            console.log("\n" + "=".repeat(60) + "\n");
          } else {
            logSimple(`🛑 End stream: ${result}`);
          }
        } catch (err) {
          console.error("\n❌ END-STREAM SEQUENCE ERROR:", err);
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
      url.searchParams.has("golive") ||
      url.searchParams.has("endstream");

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
      
      // Convert times to minutes since midnight for easier comparison
      const currentTimeMinutes = currentHour * 60 + currentMin;
      const windowStartMinutes = GO_LIVE_START_HOUR_PT * 60 + GO_LIVE_START_MIN_PT;
      const windowEndMinutes = GO_LIVE_END_HOUR_PT * 60 + GO_LIVE_END_MIN_PT;
      const inWindow = currentTimeMinutes >= windowStartMinutes && currentTimeMinutes <= windowEndMinutes;
      
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
      report += `  Target: ${GO_LIVE_START_HOUR_PT}:${pad2(GO_LIVE_START_MIN_PT)} - ${GO_LIVE_END_HOUR_PT}:${pad2(GO_LIVE_END_MIN_PT)} PT\n`;
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
      // Dev mode: skip date filter - finds any upcoming broadcast for testing
      await goLiveToday(env, false);
      return new Response("GoLive attempted (check logs).", { status: 200 });
    }
    
    if (url.searchParams.has("endstream")) {
      await endStreamToday(env);
      return new Response("EndStream attempted (check logs).", { status: 200 });
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
    
    // Get OAuth token first
    const token = await getAccessToken(env);
    if (!token) {
      console.error("❌ OAuth token failed");
      return "❌ OAuth token failed";
    }
    logKeyValue("OAuth Token", "✅ Obtained");

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
    const title = `${BROADCAST_TITLE_PREFIX}${m}/${d}/${y}`;
    
    logKeyValue("Next Sunday (UTC)", nextSunday.toISOString().split('T')[0]);
    logKeyValue("Title", title);

    // Set start time with DST auto-correction
    logSubSection("DST Auto-Correction");
    
    // Start with PDT offset (UTC-7): target PT hour + 7 = starting UTC hour
    // e.g. 9 AM service → 16 UTC; 10 AM service → 17 UTC
    nextSunday.setUTCHours(SCHEDULE_HOUR_PT + 7, SCHEDULE_MINUTE_PT, 0, 0);
    logKeyValue("Initial UTC Time", nextSunday.toISOString());
    
    const checkPT = getPacificTimeParts(nextSunday);
    logKeyValue("Converts to PT", `${checkPT.hour}:${checkPT.minute}`);
    logKeyValue("Target PT", `${SCHEDULE_HOUR_PT}:${pad2(SCHEDULE_MINUTE_PT)}`);
    
    if (parseInt(checkPT.hour, 10) === SCHEDULE_HOUR_PT - 1) {
      // One hour short = PST (UTC-8), add 1 hour to compensate
      console.log("  ⚠️  Hour is one less than target (PST detected)");
      nextSunday.setUTCHours(SCHEDULE_HOUR_PT + 8, SCHEDULE_MINUTE_PT, 0, 0);
      const newCheckPT = getPacificTimeParts(nextSunday);
      logKeyValue("Adjusted UTC Time", nextSunday.toISOString());
      logKeyValue("New PT Time", `${newCheckPT.hour}:${newCheckPT.minute}`);
      logKeyValue("Correction", "Added 1 hour to compensate for PST");
    } else {
      console.log("  ✅ Hour matches target (PDT detected or already correct)");
    }

    const scheduledStart = nextSunday.toISOString();

    // Check for duplicates using liveBroadcasts API (works with unlisted videos)
    logSubSection("Duplicate Check");
    logKeyValue("Checking for existing", title);
    
    const listUrl = 
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts" +
      "?part=snippet" +
      "&mine=true" +
      "&broadcastType=event" +
      "&maxResults=50";
    
    const listRes = await fetch(listUrl, {
      headers: { Authorization: `Bearer ${token}` }
    });
    
    const listData = await safeJson(listRes);
    
    if (listRes.ok && listData.items) {
      const existing = listData.items.find(item => item.snippet?.title === title);
      if (existing) {
        console.log(`  ⚠️  Found existing: ${existing.id}`);
        return `⚠️ Already scheduled: ${title}\nvideoId=${existing.id}`;
      }
    }
    
    logKeyValue("Duplicate Check", "✅ No duplicates found");

    // Create broadcast
    logSubSection("Creating Broadcast");

    const createPayload = {
      snippet: {
        title,
        scheduledStartTime: scheduledStart,
        description: BROADCAST_DESCRIPTION,
        defaultLanguage: "en",
        defaultAudioLanguage: "en"
      },
      status: {
        privacyStatus: PRIVACY_STATUS,
        selfDeclaredMadeForKids: false
      },
      contentDetails: {
        enableArchive: true,
        enableEmbed: PRIVACY_STATUS === "public",  // Embedding only allowed for public broadcasts
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
    
    const categoryResult = await updateVideoCategory(token, broadcastId, title, BROADCAST_DESCRIPTION);
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
  todayOnly = true  → production/cron: only matches today's date
  todayOnly = false → dev/?golive: picks the soonest upcoming broadcast
********************************************************************/
async function goLiveToday(env, todayOnly = true) {
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
      logSimple(todayOnly
        ? `  Looking for broadcast: ${todayPT}`
        : `  Looking for next upcoming broadcast (dev mode)`
      );
    }
    
    logSubSection("Fetching Broadcasts");
    logKeyValue("Mode", todayOnly ? "Production (today only)" : "Dev (any upcoming)");
    logKeyValue("Looking for date (PT)", todayOnly ? todayPT : "Any upcoming");
    
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

    // Filter broadcasts based on mode
    let candidateBroadcasts;

    if (todayOnly) {
      // Production: only today's date
      candidateBroadcasts = data.items.filter((item) => {
        const scheduledStr = item.snippet?.scheduledStartTime;
        if (!scheduledStr) return false;
        const scheduledPT = getPacificTimeParts(new Date(scheduledStr));
        return (
          scheduledPT.day === nowPT.day &&
          scheduledPT.month === nowPT.month &&
          scheduledPT.year === nowPT.year
        );
      });
      logKeyValue("Today's Broadcasts", candidateBroadcasts.length);
    } else {
      // Dev mode: any non-completed broadcast, sorted soonest first
      const excludedStates = ["complete", "revoked"];
      candidateBroadcasts = data.items
        .filter(item => !excludedStates.includes(item.status?.lifeCycleStatus))
        .sort((a, b) => {
          const aTime = new Date(a.snippet?.scheduledStartTime || 0).getTime();
          const bTime = new Date(b.snippet?.scheduledStartTime || 0).getTime();
          return aTime - bTime;
        });
      logKeyValue("Upcoming Broadcasts", candidateBroadcasts.length);
    }
    
    // Log details of candidates
    if (candidateBroadcasts.length > 0) {
      logSubSection(todayOnly ? "Today's Broadcast Details" : "Upcoming Broadcast Details");
      candidateBroadcasts.forEach((item, idx) => {
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

    logSubSection("Selection Process");
    
    if (candidateBroadcasts.length === 0) {
      console.log(todayOnly
        ? "❌ No broadcasts match today's date"
        : "❌ No upcoming broadcasts found"
      );
      return "NOT_FOUND";
    }

    // Check if any are already live
    logSubSection("Checking Current State");
    
    const alreadyLive = candidateBroadcasts.find(b => b.status?.lifeCycleStatus === "live");
    if (alreadyLive) {
      console.log(`✅ Already live: "${alreadyLive.snippet.title}"`);
      logKeyValue("Broadcast ID", alreadyLive.id);
      return "ALREADY_LIVE";
    }

    // Find best candidate by state
    const stateOrder = ["ready", "testing", "testStarting", "upcoming"];
    
    let broadcast = null;
    let selectedReason = "";
    
    for (const state of stateOrder) {
      broadcast = candidateBroadcasts.find(b => b.status?.lifeCycleStatus === state);
      if (broadcast) {
        selectedReason = `Best state: ${state}`;
        break;
      }
    }

    if (!broadcast) {
      broadcast = candidateBroadcasts[0];
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
    
    const alreadyTesting = broadcast.status?.lifeCycleStatus === "testing";
    
    if (alreadyTesting) {
      // Already in testing state - skip step 1 to avoid redundantTransition error
      logKeyValue("Step 1", "Skipped - already in testing state");
      if (!VERBOSE_LOGGING) {
        logSimple(`  Step 1: Skipped (already in testing)`);
      }
    } else {
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
    }
    
    // Wait for YouTube to stabilize (skip if already in testing - already stable)
    if (!alreadyTesting) {
      logKeyValue("Waiting", "10 seconds for YouTube to stabilize...");
      if (!VERBOSE_LOGGING) {
        logSimple(`  Waiting 10 seconds...`);
      }
      await new Promise(resolve => setTimeout(resolve, 10000));
    }
    
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

    // Send go-live notification if enabled
    if (ENABLE_GO_LIVE_NOTIFICATION) {
      const notifyResult = await sendNotificationEmail(token, env);
      if (VERBOSE_LOGGING) {
        logKeyValue("Notification", notifyResult);
      } else {
        logSimple(`  📧 Notification: ${notifyResult}`);
      }
    }
    
    return newState === "live" ? "ALREADY_LIVE" : "SUCCESS";
    
  } catch (err) {
    console.error("❌ goLiveToday error:", err);
    console.error("Stack:", err.stack);
    return "ERROR";
  }
}

/********************************************************************
  END TODAY'S LIVE STREAM
********************************************************************/
async function endStreamToday(env) {
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
      logSimple(`  Looking for live broadcast: ${todayPT}`);
    }
    
    logSubSection("Fetching Live Broadcasts");
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
    
    // Filter for today's broadcasts
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
    
    if (todaysBroadcasts.length === 0) {
      console.log("❌ No broadcasts match today's date");
      return "NOT_FOUND";
    }

    // Find broadcasts that are currently live
    const liveBroadcasts = todaysBroadcasts.filter(b => 
      b.status?.lifeCycleStatus === "live" || 
      b.status?.lifeCycleStatus === "liveStarting"
    );
    
    logKeyValue("Currently Live", liveBroadcasts.length);
    
    if (liveBroadcasts.length === 0) {
      console.log("ℹ️  No live broadcasts found for today");
      return "NOT_LIVE";
    }

    // End all live broadcasts (usually just one)
    const broadcast = liveBroadcasts[0];
    
    logSubSection("Ending Live Broadcast");
    logKeyValue("Title", broadcast.snippet?.title);
    logKeyValue("ID", broadcast.id);
    logKeyValue("Current State", broadcast.status?.lifeCycleStatus);
    
    // Transition to complete
    const transitionUrl = 
      "https://youtube.googleapis.com/youtube/v3/liveBroadcasts/transition" +
      `?part=id,snippet,status` +
      `&broadcastStatus=complete` +
      `&id=${broadcast.id}`;
    
    logKeyValue("Endpoint", transitionUrl);
    
    const transitionRes = await fetch(transitionUrl, {
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

    logKeyValue("Response Status", transitionRes.status);
    
    const transition = await safeJson(transitionRes);
    
    if (VERBOSE_LOGGING) {
      console.log("  Response Body:", JSON.stringify(transition, null, 2));
    }

    if (!transitionRes.ok) {
      const errorMsg = transition.error?.message || "No message";
      const errorReason = transition.error?.errors?.[0]?.reason || "Unknown";
      
      if (VERBOSE_LOGGING) {
        console.error(`❌ End stream failed (${transitionRes.status})`);
        if (transition.error) {
          logKeyValue("Error Message", errorMsg);
          logKeyValue("Error Reason", errorReason);
          console.log("  Full Error:", JSON.stringify(transition.error, null, 2));
        }
      } else {
        logSimple(`  ❌ End failed (${transitionRes.status}): ${errorMsg} [${errorReason}]`);
      }
      
      return "ERROR";
    }

    const newState = transition.status?.lifeCycleStatus;
    
    if (VERBOSE_LOGGING) {
      console.log(`\n✅ STREAM ENDED SUCCESSFULLY!`);
      logKeyValue("Final State", newState);
    } else {
      logSimple(`  ✅ Success! State: ${newState}`);
    }
    
    return "SUCCESS";
    
  } catch (err) {
    console.error("❌ endStreamToday error:", err);
    console.error("Stack:", err.stack);
    return "ERROR";
  }
}

/********************************************************************
  SEND GO-LIVE NOTIFICATION EMAIL
  Requires gmail.send scope on the OAuth token.
  NOTIFICATION_TO is read from Cloudflare plain text env variable.
  Supports multiple recipients as comma-separated addresses.
  Works with SMS gateways (number@txt.att.net, etc.) - keep
  NOTIFICATION_SUBJECT and NOTIFICATION_BODY short and plain text only.
********************************************************************/
async function sendNotificationEmail(token, env) {
  try {
    const to = env.NOTIFICATION_TO;
    if (!to) {
      return "⚠️ Skipped - NOTIFICATION_TO env variable not set";
    }

    const message = [
      `To: ${to}`,
      `Subject: ${NOTIFICATION_SUBJECT}`,
      `Content-Type: text/plain; charset=UTF-8`,
      ``,
      NOTIFICATION_BODY
    ].join('\r\n');

    // Base64url encode (URL-safe, no padding) as required by Gmail API
    const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(message)))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

    const res = await fetch(
      'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ raw: encoded })
      }
    );

    const data = await safeJson(res);

    if (VERBOSE_LOGGING) {
      console.log("  Notification Response:", JSON.stringify(data, null, 2));
    }

    return res.ok
      ? `✅ Sent to ${to}`
      : `❌ Failed (${res.status}): ${data.error?.message || 'Unknown'}`;

  } catch (err) {
    return `❌ Error: ${err.toString()}`;
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
    
    // Use native FormData instead of manually constructing multipart body
    const formData = new FormData();
    formData.append('videoFile', new Blob([imgBuf], { type: 'image/png' }), 'thumb.png');

    const res = await fetch(
      `https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=${videoId}`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`
          // Don't set Content-Type - FormData sets it automatically with correct boundary
        },
        body: formData
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
