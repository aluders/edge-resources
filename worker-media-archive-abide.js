/********************************************************************
  Church Media Archive Worker (OAuth 2.0 — supports unlisted videos)
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
    - ?embed remains available in both modes
    - ?test returns raw counts, titles, and parsed services
********************************************************************/

// ============================================================
//  CHANNEL CONFIG
// ============================================================
const CHANNEL_ID          = "UCBl48WQE_6YH4u4rbpVtlqA";
const UPLOADS_PLAYLIST_ID = "UU" + CHANNEL_ID.slice(2);

// ============================================================
//  PAGE CONFIG
// ============================================================
const PAGE_TITLE        = "Abide Media Archive";
const FAVICON_URL       = "https://abide.pages.dev/favicon.ico";
const CARD_TITLE_PREFIX = "Abide - ";  // Used verbatim before the date — include any spacing/punctuation you want

// ============================================================
//  FEATURE TOGGLES
// ============================================================
const ENABLE_YOUTUBE_LINKS = true;
const ENABLE_SERMON_VIDEO  = false;  // Google Drive sermon video links
const ENABLE_SERMON_AUDIO  = false;  // Google Drive audio links + /audio/ proxy

// ============================================================
//  VIDEO TITLE PARSING
//  Regex must capture groups: (month)(day)(year)(optional suffix)
//  Example for "CPC Live 1/5/2025":  /^CPC Live.*?(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s*-\s*(.+))?/
//  Example for "Church Service 2025-01-05": /^Church Service.*?(\d{4})-(\d{2})-(\d{2})(?:\s*-\s*(.+))?/
//  Update TITLE_DATE_FORMAT to match your group order:
//    "MDY" = groups are (month, day, year)
//    "YMD" = groups are (year, month, day)
//  Group 4 always captures optional suffix text after the date (e.g. "- Recital")
// ============================================================
const TITLE_REGEX       = /^Abide Live.*?(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s*-\s*(.+))?/;
const TITLE_DATE_FORMAT = "MDY";  // "MDY" or "YMD"

// ============================================================
//  THUMBNAIL CONFIG
// ============================================================
const DEFAULT_THUMB = "https://abide.pages.dev/thumbnail-4k-white.png";

// Series-specific thumbnails (processed top-to-bottom, first match wins)
// Format: YYYY-MM-DD for start/end. Leave empty array if no series configured.
const SERIES_CONFIG = [
  // {
  //   name: "Series Name",      // for your reference only
  //   start: "2025-09-07",
  //   end:   "2025-11-23",
  //   url:   "https://example.com/series-thumb.png"
  // },
];

// ============================================================
//  GOOGLE DRIVE CONFIG (only used if features enabled above)
// ============================================================
const AUDIO_FOLDER_ID  = "";  // Google Drive folder ID for audio files
const SERMON_FOLDER_ID = "";  // Google Drive folder ID for sermon video links

// ============================================================
//  CACHE CONFIG
// ============================================================
const CACHE_TTL = 21600;  // 6 hours
const CACHE_KEY = "https://cache.local/church-media-archive-v1";

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
            // MDY (default)
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

      // ---------- Test mode: return full diagnostics ----------
      if (testMode) {
        return new Response(
          JSON.stringify({
            youtube:    playlistItems.length,
            audio:      audioFiles.length,
            sermon:     sermonFiles.length,
            titles:     playlistItems.map(i => i.snippet?.title),
            services:   services,
            yearList:   yearList,
            latestYear: latestYear
          }, null, 2),
          { headers: { "content-type": "application/json" } }
        );
      }

      // ============================================================
      //  BUILD HTML
      // ============================================================
      let html = `
<!DOCTYPE html>
<html>
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

          if (ENABLE_SERMON_VIDEO && v.sermonFile) {
            btns.push(
              `<a class="sermon-video" target="_blank" href="${v.sermonFile.webViewLink}">Sermon</a>`
            );
          }

          if (ENABLE_SERMON_AUDIO && v.audioFile) {
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
