/*
==================================================================
  UniFi Protect Alert -> Email (SMS Gateway) Cloudflare Worker
  v1.2
==================================================================
  WHAT IT DOES
    Receives a UniFi Protect Alarm Manager webhook (Custom Webhook,
    POST) and sends a short, subject-less email via the Gmail API --
    intended to be delivered through a carrier email-to-SMS gateway
    (e.g. 5551234567@vtext.com).

    Message format:
        <Trigger> detected on <Alarm Name>
    e.g. "Person detected on Tunnel 1"

    UniFi Protect's webhook does NOT include a friendly camera name,
    only the device MAC address. This script uses the ALARM NAME
    instead -- so name each Alarm Manager alarm after the camera or
    area it covers (e.g. "Tunnel 1", "Back Lot").

  USAGE
    1. In UniFi Protect -> Alarm Manager, create one alarm per
       camera/trigger to alert on, with:
         - Activity: Person Detected (or Vehicle / Animal / etc.)
         - Scope: the camera
         - Action: Webhook -> Custom Webhook -> POST
         - Delivery URL: https://<this-worker>.workers.dev/
                          (append ?token=<WEBHOOK_SECRET> if
                          REQUIRE_WEBHOOK_SECRET is true below)
       Name the alarm after the camera, e.g. "Tunnel 1".

    2. Toggle behavior in the CONFIG block directly below.

    3. In Worker Settings -> Variables, set:
         Secrets (encrypted):
           OA_CLIENT_ID
           OA_CLIENT_SECRET
           OA_REFRESH_TOKEN
           WEBHOOK_SECRET   (only needed if REQUIRE_WEBHOOK_SECRET
                             is true)
         Variables:
           FROM_EMAIL       sending Workspace address
           TO_EMAIL         SMS gateway address(es), comma-separated
           TRIGGER_LABELS   optional JSON to override trigger wording
                             e.g. {"person":"Person","vehicle":"Vehicle"}

  NOTES
    - No email subject is sent, since most carrier SMS gateways
      ignore or mangle it, and some display it ahead of the body.
    - UniFi Protect's Custom Webhook has no built-in auth. The
      WEBHOOK_SECRET query-string check is a lightweight guard
      against random internet POSTs -- it is not full auth.

  VERSION HISTORY
    1.2 - Message wording moved into CONFIG.MESSAGE_FORMAT
    1.1 - Added CONFIG block for toggles (webhook secret
          enforcement, event link, debug logging) instead of
          burying behavior in code
    1.0 - Initial version
==================================================================
*/

// ==================================================================
// CONFIG - toggle behavior here. Site-specific values (addresses,
// credentials, secrets) still live in Worker Settings -> Variables,
// since those change per deployment and shouldn't be hardcoded.
// ==================================================================
const CONFIG = {
  // Require the incoming request's ?token= to match the
  // WEBHOOK_SECRET Worker variable. Recommended to leave true,
  // since UniFi Protect's Custom Webhook has no auth of its own.
  REQUIRE_WEBHOOK_SECRET: true,

  // Append a short " - <link>" to the message with a deep link
  // back into the Protect event (alarm.eventLocalLink). Off by
  // default to keep SMS messages as short as possible.
  INCLUDE_EVENT_LINK: false,

  // Log the full incoming payload to the console on every request.
  // Useful when first wiring up a new alarm; noisy otherwise.
  DEBUG_LOGGING: false,

  // Fallback trigger key used if UniFi Protect's payload doesn't
  // include one (shouldn't normally happen).
  DEFAULT_TRIGGER_KEY: 'motion',

  // Message wording. Available placeholders:
  //   {trigger}  the detected activity, e.g. "Person"
  //               (title-cased key, or a TRIGGER_LABELS override)
  //   {alarm}    the UniFi Protect alarm name, e.g. "Tunnel 1"
  // e.g. "{trigger} detected on {alarm}" -> "Person detected on Tunnel 1"
  MESSAGE_FORMAT: '{trigger} detected on {alarm}'
};

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }

    // ---- Shared-secret check ----
    if (CONFIG.REQUIRE_WEBHOOK_SECRET) {
      const url = new URL(request.url);
      if (!env.WEBHOOK_SECRET || url.searchParams.get('token') !== env.WEBHOOK_SECRET) {
        return new Response('Unauthorized', { status: 401 });
      }
    }

    let payload;
    try {
      payload = await request.json();
    } catch (err) {
      return new Response('Bad Request: invalid JSON', { status: 400 });
    }

    if (CONFIG.DEBUG_LOGGING) {
      console.log('[*] Incoming payload:', JSON.stringify(payload));
    }

    const alarm = payload?.alarm || {};
    const alarmName = alarm.name || 'Unknown Alarm';
    const trigger = alarm.triggers?.[0] || {};
    const triggerKey = trigger.key || CONFIG.DEFAULT_TRIGGER_KEY;

    let message = buildMessage(triggerKey, alarmName, env);

    if (CONFIG.INCLUDE_EVENT_LINK && alarm.eventLocalLink) {
      message += ` - ${alarm.eventLocalLink}`;
    }

    try {
      await sendEmail(env, message);
    } catch (err) {
      console.error('[x] Failed to send email:', err);
      return new Response('Failed to send alert email', { status: 502 });
    }

    console.log(`[+] Alert sent: ${message}`);
    return new Response('OK', { status: 200 });
  }
};

// ---- Build the human-readable alert text ----
function buildMessage(triggerKey, alarmName, env) {
  let labels = {};
  if (env.TRIGGER_LABELS) {
    try {
      labels = JSON.parse(env.TRIGGER_LABELS);
    } catch (err) {
      console.error('[!] TRIGGER_LABELS is not valid JSON, using defaults');
    }
  }

  const label = labels[triggerKey] || titleCase(triggerKey);

  return CONFIG.MESSAGE_FORMAT
    .replace('{trigger}', label)
    .replace('{alarm}', alarmName);
}

function titleCase(str) {
  return str.replace(/[_-]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

// ---- Gmail send (OAuth2 refresh-token flow) ----
async function sendEmail(env, bodyText) {
  const accessToken = await getAccessToken(env);

  const toAddresses = env.TO_EMAIL.split(',').map((a) => a.trim()).join(', ');

  const rawLines = [
    `From: ${env.FROM_EMAIL}`,
    `To: ${toAddresses}`,
    'Content-Type: text/plain; charset="UTF-8"',
    '',
    bodyText
  ];
  const raw = rawLines.join('\r\n');
  const encodedMessage = base64UrlEncode(raw);

  const res = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ raw: encodedMessage })
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Gmail API error ${res.status}: ${errText}`);
  }
}

async function getAccessToken(env) {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: env.OA_CLIENT_ID,
      client_secret: env.OA_CLIENT_SECRET,
      refresh_token: env.OA_REFRESH_TOKEN,
      grant_type: 'refresh_token'
    })
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Token refresh failed ${res.status}: ${errText}`);
  }

  const data = await res.json();
  return data.access_token;
}

function base64UrlEncode(str) {
  const bytes = new TextEncoder().encode(str);
  let binary = '';
  bytes.forEach((b) => (binary += String.fromCharCode(b)));
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
