/* MeshCore Simulator — API helpers (vanilla JS, no build step) */

// API base URL — same origin, so empty string
const API = '';

/**
 * Fetch JSON from a URL. Throws on non-2xx responses.
 */
async function fetchJSON(url, options = {}) {
  const resp = await fetch(API + url, {
    headers: { 'Accept': 'application/json', ...options.headers },
    ...options,
  });
  if (!resp.ok) {
    let detail = resp.statusText;
    try {
      const body = await resp.json();
      detail = body.detail || body.message || JSON.stringify(body);
    } catch (_) { /* ignore parse errors */ }
    throw new Error(`${resp.status}: ${detail}`);
  }
  // 204 No Content
  if (resp.status === 204) return null;
  return resp.json();
}

/**
 * POST JSON payload and return parsed response.
 */
async function postJSON(url, data) {
  return fetchJSON(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
}

/**
 * PUT JSON payload and return parsed response.
 */
async function putJSON(url, data) {
  return fetchJSON(url, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
}

/**
 * DELETE a resource and return parsed response.
 */
async function deleteJSON(url) {
  return fetchJSON(url, { method: 'DELETE' });
}

/**
 * Connect to a Server-Sent Events endpoint.
 * @param {string} url         SSE endpoint path
 * @param {function} onMessage Called with parsed JSON data for each event
 * @param {function} onError   Called with error event on failure
 * @returns {EventSource}      The EventSource (caller can close it)
 */
function connectSSE(url, onMessage, onError) {
  const es = new EventSource(API + url);
  es.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      onMessage(data);
    } catch (e) {
      onMessage(event.data);
    }
  };
  es.onerror = (event) => {
    if (onError) onError(event);
  };
  return es;
}

/**
 * Format milliseconds as human-readable duration.
 * Examples: "1.2s", "5m 30s", "2h 15m"
 */
function formatDuration(ms) {
  if (ms == null) return '--';
  if (ms < 0) return '--';

  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) {
    if (ms < 1000) return ms + 'ms';
    return (ms / 1000).toFixed(1) + 's';
  }

  const minutes = Math.floor(seconds / 60);
  const secs = seconds % 60;
  if (minutes < 60) {
    return secs > 0 ? `${minutes}m ${secs}s` : `${minutes}m`;
  }

  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}

/**
 * Format an ISO timestamp or epoch ms as local date/time string.
 */
function formatTime(ts) {
  if (!ts) return '--';
  if (typeof ts === 'number' && ts < 1e12) ts = ts * 1000;
  const d = new Date(ts);
  if (isNaN(d.getTime())) return '--';
  return d.toLocaleString(undefined, {
    month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
}

/**
 * Get ?sim= query parameter from the current URL.
 */
function getSimId() {
  return new URLSearchParams(window.location.search).get('sim');
}

/**
 * Get ?id= query parameter from the current URL.
 */
function getConfigId() {
  return new URLSearchParams(window.location.search).get('id');
}

/**
 * Escape HTML entities for safe insertion.
 */
function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

/**
 * Truncate string to maxLen, adding ellipsis if needed.
 */
function truncate(str, maxLen = 8) {
  if (!str) return '';
  if (str.length <= maxLen) return str;
  return str.substring(0, maxLen) + '...';
}

/**
 * Connect to a WebSocket endpoint with auto-reconnect.
 * @param {string} path       WS endpoint path (e.g. "/api/interactive/abc123/ws")
 * @param {object} handlers   { onOpen, onMessage, onClose, onError }
 * @param {object} options    { reconnect: true, reconnectDelay: 2000 }
 * @returns {{ ws: WebSocket, close: function }}
 */
function connectWS(path, handlers = {}, options = {}) {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = proto + '//' + location.host + path;
  const reconnect = options.reconnect !== false;
  const delay = options.reconnectDelay || 2000;
  let closed = false;
  let ws;

  function connect() {
    ws = new WebSocket(url);
    ws.onopen = () => { if (handlers.onOpen) handlers.onOpen(ws); };
    ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (handlers.onMessage) handlers.onMessage(data, ws);
      } catch (e) {
        if (handlers.onMessage) handlers.onMessage(event.data, ws);
      }
    };
    ws.onclose = (event) => {
      if (handlers.onClose) handlers.onClose(event);
      if (reconnect && !closed) {
        setTimeout(connect, delay);
      }
    };
    ws.onerror = (event) => {
      if (handlers.onError) handlers.onError(event);
    };
  }

  connect();
  return {
    get ws() { return ws; },
    send(data) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(typeof data === 'string' ? data : JSON.stringify(data)); },
    close() { closed = true; if (ws) ws.close(); },
  };
}

/**
 * Create and return a DOM element with optional classes and text.
 */
function el(tag, classes, text) {
  const e = document.createElement(tag);
  if (classes) {
    if (Array.isArray(classes)) classes.forEach(c => e.classList.add(c));
    else e.className = classes;
  }
  if (text !== undefined) e.textContent = text;
  return e;
}
