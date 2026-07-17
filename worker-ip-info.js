addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request))
})

async function handleRequest(request) {
  const country = request.cf?.country || 'Unknown';
  const city = request.cf?.city || 'Unknown';
  const region = request.cf?.region || 'Unknown';
  const timezone = request.cf?.timezone || 'Unknown';

  // Cloudflare already knows the real client IP that reached the edge -
  // use it as an immediate, no-JS-required fallback. This is the exact
  // same IP ipinfo.io would report for that protocol, so it's authoritative,
  // not a guess. Client-side probes below just add live dual-stack confirmation.
  const connectingIP = request.headers.get('CF-Connecting-IP') || '';
  const connectingIsV6 = connectingIP.includes(':');

  const ipv4Initial = (connectingIP && !connectingIsV6) ? connectingIP : 'Scanning...';
  const ipv6Initial = (connectingIP && connectingIsV6) ? connectingIP : 'Scanning...';

  const ipv4InitialClass = ipv4Initial === 'Scanning...' ? 'ip-address detecting' : 'ip-address';
  const ipv6InitialClass = ipv6Initial === 'Scanning...' ? 'ip-address detecting' : 'ip-address';

  const ipv4InitialSource = ipv4Initial === 'Scanning...' ? 'pending' : 'edge';
  const ipv6InitialSource = ipv6Initial === 'Scanning...' ? 'pending' : 'edge';

  const ipv4InitialMethod = ipv4InitialSource === 'edge' ? 'via Cloudflare edge (CF-Connecting-IP)' : '';
  const ipv6InitialMethod = ipv6InitialSource === 'edge' ? 'via Cloudflare edge (CF-Connecting-IP)' : '';

  // Cloudflare also tags every request with the ASN/org it saw for the
  // connecting IP, so the ISP name gets the same free server-side fallback
  // as the IP itself - no client fetch required for the box that matches
  // whichever protocol actually reached the edge.
  const asOrganization = request.cf?.asOrganization || '';
  const asn = request.cf?.asn ? `AS${request.cf.asn}` : '';
  const ispInitial = asOrganization ? (asn ? `${asOrganization} (${asn})` : asOrganization) : '';
  const ipv4InitialIsp = ipv4InitialSource === 'edge' ? ispInitial : '';
  const ipv6InitialIsp = ipv6InitialSource === 'edge' ? ispInitial : '';

  // Human-readable capture time in the visitor's own detected timezone,
  // with the raw ISO string kept underneath for anyone who wants exactness.
  const captureDate = new Date();
  const isoTimestamp = captureDate.toISOString();
  let readableTimestamp;
  try {
    readableTimestamp = new Intl.DateTimeFormat('en-US', {
      dateStyle: 'full',
      timeStyle: 'long',
      timeZone: timezone !== 'Unknown' ? timezone : 'UTC'
    }).format(captureDate);
  } catch (e) {
    readableTimestamp = captureDate.toUTCString();
  }

  const html = `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="shortcut icon" href="https://park.edgeintegrated.com/favicon.ico">
    <title>Public IP Details</title>
    <style>
        :root {
            --bg-dark: #0f172a;
            --bg-card: #1e293b;
            --text-main: #f1f5f9;
            --text-muted: #94a3b8;
            --accent-v4: #10b981;
            --accent-v6: #0ea5e9;
            --glow-v4: rgba(16, 185, 129, 0.2);
            --glow-v6: rgba(14, 165, 233, 0.2);
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #0f172a 0%, #020617 100%);
            color: var(--text-main);
            min-height: 100vh;
            padding: 1rem;
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .container {
            width: 100%;
            max-width: 1000px;
            background: rgba(30, 41, 59, 0.4);
            backdrop-filter: blur(16px);
            -webkit-backdrop-filter: blur(16px);
            border-radius: 24px;
            padding: 2rem;
            border: 1px solid rgba(255, 255, 255, 0.08);
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
        }

        .header {
            text-align: center;
            margin-bottom: 2rem;
        }

        .header h1 {
            font-weight: 700;
            letter-spacing: -0.5px;
            margin-bottom: 0.5rem;
            font-size: 1.5rem;
        }
        
        .header p {
            color: var(--text-muted);
            font-size: 0.9rem;
        }

        /* IP Cards Grid */
        .ip-container {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }

        .ip-section {
            background: rgba(15, 23, 42, 0.6);
            padding: 1.5rem;
            border-radius: 16px;
            text-align: center;
            transition: all 0.3s ease;
            position: relative;
            overflow: hidden;
            border: 1px solid rgba(255, 255, 255, 0.05);
            display: flex;
            flex-direction: column;
            justify-content: center;
        }

        .ip-section:hover {
            transform: translateY(-2px);
            border-color: rgba(255, 255, 255, 0.1);
        }

        .ipv4-section { border-top: 3px solid var(--accent-v4); }
        .ipv6-section { border-top: 3px solid var(--accent-v6); }

        .ip-label {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 2px;
            font-weight: 600;
            margin-bottom: 0.75rem;
            color: var(--text-muted);
        }

        .ip-address {
            font-size: 1.5rem; /* Slightly smaller base size for better fit */
            font-weight: 700;
            color: #fff;
            
            /* Critical for wrapping long IPv6 strings */
            word-break: break-all;
            white-space: normal;
            
            cursor: pointer;
            padding: 0.5rem;
            border-radius: 8px;
            transition: all 0.2s;
            line-height: 1.2;
            font-variant-numeric: tabular-nums;
        }
        
        .ipv4-section .ip-address { text-shadow: 0 0 20px var(--glow-v4); }
        .ipv6-section .ip-address { text-shadow: 0 0 20px var(--glow-v6); }

        .ip-address:hover:not(.unknown) {
            background: rgba(255, 255, 255, 0.08);
        }

        .detection-method {
            margin-top: 0.75rem;
            font-size: 0.7rem;
            color: var(--text-muted);
            font-family: monospace;
            opacity: 0.7;
        }

        .isp-value {
            margin-top: 0.4rem;
            font-size: 0.8rem;
            font-weight: 500;
            color: var(--text-main);
            opacity: 0.85;
            word-break: break-word;
        }

        /* Location Info Grid */
        .info-section {
            display: grid;
            /* Mobile First: 2 columns */
            grid-template-columns: 1fr 1fr;
            gap: 0.75rem;
            padding-top: 1.5rem;
            border-top: 1px solid rgba(255, 255, 255, 0.08);
        }

        /* Desktop: 4 columns */
        @media (min-width: 768px) {
            .info-section {
                grid-template-columns: repeat(4, 1fr);
                gap: 1rem;
            }
            .ip-address { font-size: 1.75rem; }
        }

        .info-item {
            background: rgba(255, 255, 255, 0.03);
            padding: 0.75rem;
            border-radius: 12px;
            text-align: center;
            
            /* Vertical Alignment */
            display: flex;
            flex-direction: column;
            justify-content: center;
            min-height: 80px;
        }

        .info-label {
            font-size: 0.65rem;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 0.25rem;
        }

        .info-value {
            font-size: 0.95rem;
            font-weight: 500;
            color: var(--text-main);
            
            /* Critical for Long Timezones */
            overflow-wrap: break-word;
            word-wrap: break-word;
            hyphens: auto;
            line-height: 1.3;
        }

        .timestamp {
            text-align: center;
            color: var(--text-muted);
            margin-top: 1.5rem;
            font-size: 0.8rem;
        }

        .timestamp-iso {
            margin-top: 0.25rem;
            font-size: 0.7rem;
            font-family: monospace;
            opacity: 0.6;
        }

        .detecting { animation: pulse 2s infinite; }
        .unknown { opacity: 0.5; cursor: default; }

        @keyframes pulse {
            0% { opacity: 0.3; }
            50% { opacity: 0.7; }
            100% { opacity: 0.3; }
        }

        /* Extreme Small Screen Handling */
        @media (max-width: 480px) {
            .container { padding: 1.25rem; }
            .header h1 { font-size: 1.25rem; }
            .ip-address { font-size: 1.25rem; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Connection Details</h1>
            <p>Real-time client identification</p>
        </div>
        
        <div class="ip-container">
            <div class="ip-section ipv4-section">
                <div class="ip-label">IPv4 Connectivity</div>
                <div class="${ipv4InitialClass}" id="ipv4" data-source="${ipv4InitialSource}">${ipv4Initial}</div>
                <div class="isp-value" id="ipv4-isp">${ipv4InitialIsp}</div>
                <div class="detection-method" id="ipv4-method">${ipv4InitialMethod}</div>
            </div>
            
            <div class="ip-section ipv6-section">
                <div class="ip-label">IPv6 Connectivity</div>
                <div class="${ipv6InitialClass}" id="ipv6" data-source="${ipv6InitialSource}">${ipv6Initial}</div>
                <div class="isp-value" id="ipv6-isp">${ipv6InitialIsp}</div>
                <div class="detection-method" id="ipv6-method">${ipv6InitialMethod}</div>
            </div>
        </div>
        
        <div class="info-section">
            <div class="info-item">
                <div class="info-label">Country</div>
                <div class="info-value">${country}</div>
            </div>
            <div class="info-item">
                <div class="info-label">Region</div>
                <div class="info-value">${region}</div>
            </div>
            <div class="info-item">
                <div class="info-label">City</div>
                <div class="info-value">${city}</div>
            </div>
            <div class="info-item">
                <div class="info-label">Timezone</div>
                <div class="info-value">${timezone}</div>
            </div>
        </div>
        
        <div class="timestamp">
            Captured ${readableTimestamp}
            <div class="timestamp-iso" id="timestamp">${isoTimestamp}</div>
        </div>
    </div>
    
    <script>
        async function detectIPInfo(endpoint) {
            try {
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 4000);
                
                const response = await fetch(endpoint, { signal: controller.signal });
                clearTimeout(timeout);
                
                if (!response.ok) throw new Error('Network error');
                const data = await response.json();
                if (!data.ip) throw new Error('Empty response');
                return { ip: data.ip, org: data.org || '' };
            } catch (error) {
                return { ip: 'Not Detected', org: '' };
            }
        }

        // ipinfo.io's org field looks like "AS7922 Comcast Cable Communications, LLC" -
        // strip the ASN prefix for display, it's already shown separately when we have it.
        function cleanOrg(org) {
            const cleaned = org.replace(/^AS\d+\s*/, '').trim();
            return cleaned || 'Unknown ISP';
        }

        function bindCopy(elementId) {
            const element = document.getElementById(elementId);
            if (!element || element.dataset.bound === 'true') return;
            element.dataset.bound = 'true';
            element.addEventListener('click', () => copyIP(elementId));
        }
        
        function updateIP(elementId, methodId, ispId, ip, method, org) {
            const element = document.getElementById(elementId);
            const methodElement = document.getElementById(methodId);
            const ispElement = document.getElementById(ispId);
            const hadEdgeValue = element.dataset.source === 'edge';

            element.classList.remove('detecting');

            if (ip.startsWith('Not')) {
                // Client-side probe failed (this is the tunnel/MTU/DNS-blackhole case).
                // If Cloudflare already gave us a real IP + ISP for this protocol
                // server-side, keep showing them instead of falling back to "Not Detected".
                if (hadEdgeValue) {
                    methodElement.textContent = 'via Cloudflare edge (client probe unreachable)';
                } else {
                    element.textContent = ip;
                    methodElement.textContent = 'Check network settings';
                    element.classList.add('unknown');
                    ispElement.textContent = '';
                }
                return;
            }

            // Client probe succeeded - always prefer it, it's live and specific to this request.
            element.textContent = ip;
            element.dataset.source = 'client';
            methodElement.textContent = method;
            ispElement.textContent = cleanOrg(org);
            bindCopy(elementId);
        }
        
        function copyIP(elementId) {
            const element = document.getElementById(elementId);
            const original = element.textContent;
            const successColor = elementId === 'ipv4' ? '#10b981' : '#0ea5e9';
            
            navigator.clipboard.writeText(original).then(() => {
                element.textContent = 'COPIED';
                element.style.color = successColor;
                element.style.letterSpacing = '2px';
                
                setTimeout(() => {
                    element.textContent = original;
                    element.style.color = '';
                    element.style.letterSpacing = '';
                }, 1500);
            }).catch(() => {
                const textArea = document.createElement('textarea');
                textArea.value = original;
                document.body.appendChild(textArea);
                textArea.select();
                document.execCommand('copy');
                document.body.removeChild(textArea);
            });
        }

        // Values rendered server-side from CF-Connecting-IP are already real and
        // clickable - don't make the user wait for the client probe to copy them.
        ['ipv4', 'ipv6'].forEach(id => {
            const el = document.getElementById(id);
            if (el && el.dataset.source === 'edge') bindCopy(id);
        });
        
        detectIPInfo('https://ipinfo.io/json').then(({ ip, org }) => {
            updateIP('ipv4', 'ipv4-method', 'ipv4-isp', ip, 'via ipinfo.io', org);
        });
        
        detectIPInfo('https://v6.ipinfo.io/json').then(({ ip, org }) => {
            updateIP('ipv6', 'ipv6-method', 'ipv6-isp', ip, 'via ipinfo.io', org);
        });
    </script>
</body>
</html>`;

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0'
    }
  });
}
