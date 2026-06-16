/********************************************************************
  Church Media Archive Worker v1.2
  --------------------------------------------------
  Secrets required:
    OA_CLIENT_ID
    OA_CLIENT_SECRET
    OA_REFRESH_TOKEN
  --------------------------------------------------
  Dev Mode behavior:
    - DEVELOPER_MODE = false: ignores ?refresh
    - DEVELOPER_MODE = true : allows ?refresh to bypass cache
  Notes:
    - ?test returns OAuth scope info, YouTube status, Drive status,
             raw counts, titles, and parsed services
  --------------------------------------------------
  CHANGELOG
  v1.0 — Initial release
    - OAuth 2.0 for YouTube and Google Drive
    - Year selector with card grid
    - Series-specific thumbnails
    - Service / Sermon / Audio buttons per card
    - ?test diagnostic endpoint
    - DEVELOPER_MODE ?refresh cache bypass (used "ON"/"OFF" string)
    - Optional suffix parsing from video titles (e.g. "- Recital")
    - CARD_TITLE_PREFIX for verbatim card title control

  v1.1 — 2026-06-15
    - Cards with a title suffix (e.g. "Recital") no longer inherit
      Drive sermon/audio files from the same date, preventing
      cross-contamination when two streams share a date
    - DEVELOPER_MODE changed from "ON"/"OFF" string to true/false boolean

  v1.2 — 2026-06-15
    - Added lang="en" to <html> tag to prevent Chrome from
      misidentifying the page language and prompting translation
********************************************************************/

// ============================================================
//  CHANNEL CONFIG
// ============================================================
const CHANNEL_ID          = "UCxZ8LTstrCOotf74qO0dOFA";
const UPLOADS_PLAYLIST_ID = "UU" + CHANNEL_ID.slice(2);

// ============================================================
//  PAGE CONFIG
// ============================================================
const PAGE_TITLE        = "Covenant Media";
const FAVICON_URL       = "https://covenantpaso.pages.dev/cpc-favicon.webp";
const CARD_TITLE_PREFIX = "";  // Used verbatim before the date — include any spacing/punctuation you want

// ============================================================
//  FEATURE TOGGLES
// ============================================================
const ENABLE_YOUTUBE_LINKS = true;
const ENABLE_SERMON_VIDEO  = true;   // Google Drive sermon video links
const ENABLE_SERMON_AUDIO  = true;   // Google Drive audio links + /audio/ proxy

// ============================================================
//  VIDEO TITLE PARSING
//  Regex must capture groups: (month)(day)(year)(optional suffix)
//  Group 4 always captures optional suffix text after the date (e.g. "- Recital")
// ============================================================
const TITLE_REGEX       = /^CPC Live.*?(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s*-\s*(.+))?/;
const TITLE_DATE_FORMAT = "MDY";  // "MDY" or "YMD"

// ============================================================
//  THUMBNAIL CONFIG
// ============================================================
const DEFAULT_THUMB = "https://covenantpaso.pages.dev/cpc-youtube.png";

// Series-specific thumbnails (processed top-to-bottom, first match wins)
// Format: YYYY-MM-DD for start/end. Leave empty array if no series configured.
const SERIES_CONFIG = [
  {
    name:  "David",
    start: "2025-09-07",
    end:   "2025-11-23",
    url:   "https://covenantpaso.pages.dev/david.png"
  },
  {
    name:  "Advent 2025",
    start: "2025-11-30",
    end:   "2025-12-21",
    url:   "https://covenantpaso.pages.dev/advent2025.png"
  }
];

// ============================================================
//  GOOGLE DRIVE CONFIG
// ============================================================
const AUDIO_FOLDER_ID  = "1jgs3zgILmdQ02-nGz-KRjvvlA3e5z7bC";
const SERMON_FOLDER_ID = "1BK61x2UfDYjJqYtkR5oWMI7rZA2-TbLf";

// ============================================================
//  CACHE CONFIG
// ============================================================
const CACHE_TTL = 21600;  // 6 hours
const CACHE_KEY = "https://cache.local/church-media-archive-v1";

// ============================================================
//  DEVELOPER MODE
// ============================================================
const DEVELOPER_MODE = true;  // true or false
function devModeOn() {
  return DEVELOPER_MODE === true;
}

// ============================================================
//  OAUTH
// ============================================================
async function getAccessToken(env) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
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
//  MAIN WORKER
// ============================================================
export default {
  async fetch(request, env) {
    const cache    = caches.default;
    const cacheReq = new Request(CACHE_KEY);
    const url      = new URL(request.url);
    const testMode = url.searchParams.has("test");
    const allowRefresh = devModeOn() && url.searchParams.has("refresh");

    // ------------------------------------------------------------
    //  AUDIO PROXY  (only active if ENABLE_SERMON_AUDIO is true)
    // ------------------------------------------------------------
    if (ENABLE_SERMON_AUDIO && url.pathname.startsWith("/audio/")) {
      const parts    = url.pathname.split("/").filter(Boolean);
      const fileId   = parts[1];
      const fileName = decodeURIComponent(parts[2] || "audio.mp3");

      const token    = await getAccessToken(env);
      const driveRes = await fetch(
        `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media&supportsAllDrives=true`,
        { headers: { Authorization: "Bearer " + token } }
      );

      return new Response(driveRes.body, {
        headers: {
          "Content-Type":        "audio/mpeg",
          "Content-Disposition": `inline; filename="${fileName}"`,
          "Cache-Control":       "public, max-age=86400"
        }
      });
    }

    // ------------------------------------------------------------
    //  CACHE CHECK
    // ------------------------------------------------------------
    if (!allowRefresh && !testMode) {
      const cached = await cache.match(cacheReq);
      if (cached) return cached;
    }

    // ------------------------------------------------------------
    //  MAIN LOGIC
    // ------------------------------------------------------------
    try {
      const accessToken = await getAccessToken(env);
      const authHeader  = { Authorization: `Bearer ${accessToken}` };

      // ---------- Fetch YouTube playlist (all pages) ----------
      async function fetchYouTube() {
        let items = [];
        let next  = null;
        do {
          const params = new URLSearchParams({
            part:       "snippet",
            playlistId: UPLOADS_PLAYLIST_ID,
            maxResults: "50"
          });
          if (next) params.set("pageToken", next);

          const res  = await fetch(
            `https://www.googleapis.com/youtube/v3/playlistItems?${params}`,
            { headers: authHeader }
          );
          const json = await res.json();
          items.push(...(json.items || []));
          next = json.nextPageToken;
        } while (next);

        return items;
      }

      // ---------- Fetch Google Drive folder ----------
      async function fetchDrive(folderId) {
        if (!folderId) return [];
        const q   = `'${folderId}' in parents and trashed = false`;
        const res = await fetch(
          "https://www.googleapis.com/drive/v3/files?" +
            "q=" + encodeURIComponent(q) +
            "&pageSize=1000&fields=files(id,name,webViewLink,mimeType)" +
            "&supportsAllDrives=true&includeItemsFromAllDrives=true",
          { headers: authHeader }
        );
        const json = await res.json();
        return json.files || [];
      }

      // ---------- Fetch only what's enabled ----------
      const [playlistItems, audioFiles, sermonFiles] = await Promise.all([
        fetchYouTube(),
        ENABLE_SERMON_AUDIO ? fetchDrive(AUDIO_FOLDER_ID)  : Promise.resolve([]),
        ENABLE_SERMON_VIDEO ? fetchDrive(SERMON_FOLDER_ID) : Promise.resolve([])
      ]);

      // ---------- Parse services from playlist titles ----------
      const services = playlistItems
        .map(item => {
          const t = item.snippet?.title?.trim();
          if (!t) return null;

          const m = t.match(TITLE_REGEX);
          if (!m) return null;

          const id = item.snippet.resourceId?.videoId;
          let mm, dd, yy;

          if (TITLE_DATE_FORMAT === "YMD") {
            [, yy, mm, dd] = m;
          } else {
            [, mm, dd, yy] = m;
          }

          const suffix = m[4] ? m[4].trim() : null;

          return {
            id,
            year:     yy,
            mm:       parseInt(mm),
            dd:       parseInt(dd),
            suffix,
            dateObj:  new Date(`${yy}-${mm.padStart(2,"0")}-${dd.padStart(2,"0")}`),
            driveKey: `${yy}-${mm.padStart(2,"0")}${dd.padStart(2,"0")}`
          };
        })
        .filter(Boolean)
        .sort((a, b) => b.dateObj - a.dateObj);

      // ---------- Index drive files by date key ----------
      const audioIndex  = {};
      const sermonIndex = {};

      audioFiles.forEach(f => {
        const m = f.name.match(/(\d{4}-\d{4})/);
        if (m) audioIndex[m[1]] = f;
      });

      sermonFiles.forEach(f => {
        const m = f.name.match(/(\d{4}-\d{4})/);
        if (m) sermonIndex[m[1]] = f;
      });

      // ---------- Group by year ----------
      const years = {};
      services.forEach(s => {
        if (!years[s.year]) years[s.year] = [];
        years[s.year].push({
          ...s,
          audioFile:  audioIndex[s.driveKey]  || null,
          sermonFile: sermonIndex[s.driveKey] || null
        });
      });

      const yearList   = Object.keys(years).sort((a, b) => b - a);
      const latestYear = yearList[0];

      // ------------------------------------------------------------
      //  TEST MODE — enhanced OAuth + API diagnostics
      // ------------------------------------------------------------
      if (testMode) {
        const ytTestRes = await fetch(
          `https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&playlistId=${UPLOADS_PLAYLIST_ID}&maxResults=1`,
          { headers: authHeader }
        );
        const ytTestJson = await ytTestRes.json();

        const driveTestRes = await fetch(
          `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(`'${AUDIO_FOLDER_ID}' in parents`)}&pageSize=1&fields=files(id,name)&supportsAllDrives=true&includeItemsFromAllDrives=true`,
          { headers: authHeader }
        );
        const driveTestJson = await driveTestRes.json();

        const tokenInfoRes  = await fetch(
          `https://oauth2.googleapis.com/tokeninfo?access_token=${accessToken}`
        );
        const tokenInfoJson = await tokenInfoRes.json();

        return new Response(
          JSON.stringify({
            youtube: {
              status:       ytTestRes.status,
              ok:           ytTestRes.ok,
              itemCount:    playlistItems.length,
              titles:       playlistItems.map(i => i.snippet?.title),
              services:     services,
              sampleResult: ytTestJson
            },
            drive: {
              status:       driveTestRes.status,
              ok:           driveTestRes.ok,
              audioCount:   audioFiles.length,
              sermonCount:  sermonFiles.length,
              sampleResult: driveTestJson
            },
            token: {
              scopes:     tokenInfoJson.scope,
              email:      tokenInfoJson.email,
              expires_in: tokenInfoJson.expires_in,
              error:      tokenInfoJson.error || null
            },
            yearList,
            latestYear
          }, null, 2),
          { headers: { "content-type": "application/json" } }
        );
      }

      // ============================================================
      //  BUILD HTML
      // ============================================================
      let html = `
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<link rel="icon" type="image/webp" href="${FAVICON_URL}">
<title>${PAGE_TITLE}</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">
<style>
:root {
  --bg: #000;
  --fg: #fff;
  --card-bg1: #0c0c0c;
  --card-bg2: #151515;
  --card-border: #1f1f1f;
}

body {
  font-family: Inter, sans-serif;
  padding: 2rem;
  background: var(--bg);
  color: var(--fg);
}

h1 {
  margin-bottom: 1.5rem;
  font-size: 2rem;
  font-weight: 600;
}

#yearSelector {
  padding: 0.6rem 1rem;
  font-size: 1.05rem;
  border-radius: 999px;
  border: 1px solid #222;
  background: #050505;
  color: white;
  margin-bottom: 1.7rem;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px,1fr));
  gap: 1.4rem;
}

.card {
  max-height: 380px;
  overflow: hidden;
  background: linear-gradient(145deg, var(--card-bg1), var(--card-bg2));
  border: 1px solid var(--card-border);
  border-radius: 16px;
  padding: 1rem;
  transition: all 0.2s ease;
  box-shadow: 0 12px 30px rgba(0,0,0,0.6);
}

.card:hover {
  transform: translateY(-3px) scale(1.02);
  box-shadow: 0 22px 60px rgba(0,0,0,0.85);
}

.card img {
  width: 100%;
  border-radius: 12px;
  margin-bottom: 0.75rem;
  display: block;
  aspect-ratio: 16 / 9;
  object-fit: cover;
  background-color: #222;
}

.card-title {
  font-size: 1rem;
  margin-bottom: 0.6rem;
}

.card-links {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 4px;
}

.card-links a,
.card-links .empty {
  min-width: 0;
}

.card-links a {
  width: 100%;
  text-align: center;
  white-space: nowrap;
  padding: 6px 8px;
  border-radius: 8px;
  background: #111;
  border: 1px solid #222;
  color: white;
  position: relative;
  text-decoration: none;
  font-size: 0.85rem;
  line-height: 1.2;
  box-sizing: border-box;
  overflow: hidden;
}

.card-links a::before {
  content: "";
  position: absolute;
  left: 0; top: 0; bottom: 0;
  width: 4px;
  border-radius: 8px 0 0 8px;
}

.card-links a.service::before      { background: #61AFEF; }
.card-links a.sermon-video::before { background: #C678DD; }
.card-links a.sermon-audio::before { background: #98C379; }

.card-links .empty { visibility: hidden; }
</style>
</head>
<body>

<h1>${PAGE_TITLE}</h1>

<select id="yearSelector">
`;

      yearList.forEach(y => {
        html += `<option value="${y}" ${y === latestYear ? "selected" : ""}>${y}</option>`;
      });

      html += `</select>`;

      // ---------- Year blocks ----------
      yearList.forEach(year => {
        html += `<div class="year-block" id="year-${year}" style="display:${
          year === latestYear ? "block" : "none"
        };"><div class="grid">`;

        years[year].forEach(v => {
          const datePart = `${v.mm}/${v.dd}/${v.dateObj.getFullYear()}`;
          const title = v.suffix
            ? `${CARD_TITLE_PREFIX}${datePart} - ${v.suffix}`
            : `${CARD_TITLE_PREFIX}${datePart}`;

          // Determine thumbnail
          let thumbUrl = DEFAULT_THUMB;
          for (const series of SERIES_CONFIG) {
            if (v.dateObj >= new Date(series.start) && v.dateObj <= new Date(series.end)) {
              thumbUrl = series.url;
              break;
            }
          }

          html += `
<div class="card">
  <img src="${thumbUrl}" alt="Thumbnail">
  <div class="card-title">${title}</div>
  <div class="card-links">
`;
          const btns = [];

          if (ENABLE_YOUTUBE_LINKS) {
            btns.push(
              `<a class="service" target="_blank" href="https://www.youtube.com/watch?v=${v.id}">Service</a>`
            );
          }

          // v1.1 — suffix cards skip Drive files to avoid date collision
          if (ENABLE_SERMON_VIDEO && v.sermonFile && !v.suffix) {
            btns.push(
              `<a class="sermon-video" target="_blank" href="${v.sermonFile.webViewLink}">Sermon</a>`
            );
          }

          if (ENABLE_SERMON_AUDIO && v.audioFile && !v.suffix) {
            const safeName = encodeURIComponent(v.audioFile.name);
            btns.push(
              `<a class="sermon-audio" target="_blank" href="/audio/${v.audioFile.id}/${safeName}">Audio</a>`
            );
          }

          // Pad to 3 slots
          while (btns.length < 3) btns.push(`<div class="empty"></div>`);

          html += btns.join("\n");

          html += `
  </div>
</div>
`;
        });

        html += `</div></div>`;
      });

      // ---------- Scripts ----------
      html += `
<script>
document.getElementById("yearSelector").addEventListener("change", function() {
  document.querySelectorAll(".year-block").forEach(e => e.style.display = "none");
  document.getElementById("year-" + this.value).style.display = "block";
});

function updateThumbnails() {
  const grid = document.querySelector(".grid");
  if (!grid) return;
  const columns = window.getComputedStyle(grid)
    .getPropertyValue("grid-template-columns")
    .split(" ").length;
  const hide = (columns === 1);
  document.querySelectorAll(".card img").forEach(img => {
    img.style.display = hide ? "none" : "block";
  });
}

window.addEventListener("load", updateThumbnails);
window.addEventListener("resize", updateThumbnails);
</script>
</body></html>`;

      const response = new Response(html, {
        headers: { "content-type": "text/html; charset=utf-8" }
      });

      await cache.put(cacheReq, response.clone(), { expirationTtl: CACHE_TTL });

      return response;

    } catch (err) {
      return new Response("Error: " + err.message, { status: 500 });
    }
  }
};
