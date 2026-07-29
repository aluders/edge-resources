/*
==================================================================
  UniFi Protect Alert -> Email (SMS Gateway) Cloudflare Worker
  v2.3
==================================================================
  WHAT IT DOES
    Receives a UniFi Protect Alarm Manager webhook (Custom Webhook,
    POST) and sends a short, subject-less email via Amazon SES --
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
           AWS_ACCESS_KEY_ID       IAM user access key
           AWS_SECRET_ACCESS_KEY   IAM user secret key
           WEBHOOK_SECRET          (only needed if
                                    REQUIRE_WEBHOOK_SECRET is true)
         Variables:
           NOTIFICATION_TO   SMS gateway address(es), comma-separated

       AWS region, sending address, and trigger wording are set as
       constants below (SITE CONFIG block) rather than Worker
       variables, since they rarely change once a deployment is
       wired up.

  NOTES
    - No email subject is sent. The message is built as a raw MIME
      email with no Subject header at all (SES's Raw content type),
      since SES's Simple content type forces a Subject field that
      shows as a blank subject line on some carrier gateways.
    - UniFi Protect's Custom Webhook has no built-in auth. The
      WEBHOOK_SECRET query-string check is a lightweight guard
      against random internet POSTs -- it is not full auth.
    - The IAM user's policy should be scoped to ses:SendEmail on
      just the verified domain identity ARN, not full SES access.

  VERSION HISTORY
    2.3 - TRIGGER_LABELS moved from an optional env var into a
          hardcoded SITE CONFIG constant. NOTIFICATION_TO replaces
          TO_EMAIL to match naming convention used elsewhere.
    2.2 - Switched from SES "Simple" content (forced a blank
          Subject header) to "Raw" MIME content with no Subject
          header at all, matching the original Gmail behavior
    2.1 - AWS_REGION and FROM_EMAIL moved from Worker variables
          into hardcoded SITE CONFIG constants
    2.0 - Switched sending provider from Gmail API (OAuth2) to
          Amazon SES (IAM access key + SigV4). Avoids Gmail's
          from-address/alias restriction entirely, since SES
          allows sending from any address on a verified domain.
          Removed OA_CLIENT_ID / OA_CLIENT_SECRET / OA_REFRESH_TOKEN.
    1.2 - Message wording moved into CONFIG.MESSAGE_FORMAT
    1.1 - Added CONFIG block for toggles (webhook secret
          enforcement, event link, debug logging) instead of
          burying behavior in code
    1.0 - Initial version
==================================================================
*/

// ==================================================================
// SITE CONFIG - values specific to this deployment. Update these
// when copying the script to a new site/domain. Credentials and
// recipient addresses still live in Worker Settings -> Variables.
// ==================================================================
const AWS_REGION = 'us-west-2'; // region the SES domain identity was verified in
const FROM_EMAIL = 'elsinore@tommysexpress.us'; // any address on the verified SES domain

// Maps UniFi Protect trigger keys to the word used in the alert
// message. Keys not listed here fall back to a title-cased version
// of the raw trigger key (e.g. "line_crossing" -> "Line Crossing").
const TRIGGER_LABELS = {
  person: 'Person',
  vehicle: 'Vehicle',
  animal: 'Animal',
  motion: 'Motion',
  ring: 'Doorbell'
};

// ==================================================================
// CONFIG - toggle behavior here.
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
  MESSAGE_FORMAT: '{trigger} detected at TX-Elsinore'
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

    let message = buildMessage(triggerKey, alarmName);

    if (CONFIG.INCLUDE_EVENT_LINK && alarm.eventLocalLink) {
      message += ` - ${alarm.eventLocalLink}`;
    }

    try {
      await sendEmailViaSES(env, message);
    } catch (err) {
      console.error('[x] Failed to send email:', err.message, '|', err.stack);
      return new Response(`Failed to send alert email: ${err.message}`, { status: 502 });
    }

    console.log(`[+] Alert sent: ${message}`);
    return new Response('OK', { status: 200 });
  }
};

// ---- Build the human-readable alert text ----
function buildMessage(triggerKey, alarmName) {
  const label = TRIGGER_LABELS[triggerKey] || titleCase(triggerKey);

  return CONFIG.MESSAGE_FORMAT
    .replace('{trigger}', label)
    .replace('{alarm}', alarmName);
}

function titleCase(str) {
  return str.replace(/[_-]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

// ==================================================================
// Amazon SES send (SigV4-signed REST call, no SDK dependency)
// ==================================================================
async function sendEmailViaSES(env, bodyText) {
  const host = `email.${AWS_REGION}.amazonaws.com`;
  const endpoint = `https://${host}/v2/email/outbound-emails`;

  const toAddresses = env.NOTIFICATION_TO.split(',').map((a) => a.trim());

  // Build a raw MIME message with NO Subject header at all -- SES's
  // "Simple" content type forces a Subject field (even a blank one
  // still shows as an empty subject line on some gateways), so Raw
  // content is used instead to match the original header-less
  // behavior from the Gmail version of this script.
  const rawLines = [
    `From: ${FROM_EMAIL}`,
    `To: ${toAddresses.join(', ')}`,
    'Content-Type: text/plain; charset="UTF-8"',
    '',
    bodyText
  ];
  const rawMessage = rawLines.join('\r\n');

  const requestBody = JSON.stringify({
    Destination: { ToAddresses: toAddresses },
    Content: {
      Raw: { Data: base64Encode(rawMessage) }
    }
  });

  const headers = await signSESRequest(env, {
    method: 'POST',
    host,
    path: '/v2/email/outbound-emails',
    region: AWS_REGION,
    body: requestBody
  });

  const res = await fetch(endpoint, {
    method: 'POST',
    headers,
    body: requestBody
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`SES API error ${res.status}: ${errText}`);
  }
}

// ---- AWS SigV4 signing ----
async function signSESRequest(env, { method, host, path, region, body }) {
  const service = 'ses';
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, ''); // e.g. 20260728T120000Z
  const dateStamp = amzDate.slice(0, 8);

  const payloadHash = await sha256Hex(body);

  const canonicalHeaders =
    `content-type:application/json\n` +
    `host:${host}\n` +
    `x-amz-date:${amzDate}\n`;
  const signedHeaders = 'content-type;host;x-amz-date';

  const canonicalRequest = [
    method,
    path,
    '', // no query string
    canonicalHeaders,
    signedHeaders,
    payloadHash
  ].join('\n');

  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    await sha256Hex(canonicalRequest)
  ].join('\n');

  const signingKey = await getSigningKey(env.AWS_SECRET_ACCESS_KEY, dateStamp, region, service);
  const signature = toHex(await hmac(signingKey, stringToSign));

  const authorizationHeader =
    `AWS4-HMAC-SHA256 Credential=${env.AWS_ACCESS_KEY_ID}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`;

  return {
    'Content-Type': 'application/json',
    'X-Amz-Date': amzDate,
    Authorization: authorizationHeader
  };
}

async function getSigningKey(secretKey, dateStamp, region, service) {
  const kDate = await hmac(new TextEncoder().encode('AWS4' + secretKey), dateStamp);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  const kSigning = await hmac(kService, 'aws4_request');
  return kSigning;
}

async function hmac(keyBytes, msg) {
  const key = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return new Uint8Array(sig);
}

async function sha256Hex(str) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(str));
  return toHex(new Uint8Array(digest));
}

function toHex(bytes) {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function base64Encode(str) {
  const bytes = new TextEncoder().encode(str);
  let binary = '';
  bytes.forEach((b) => (binary += String.fromCharCode(b)));
  return btoa(binary);
}
