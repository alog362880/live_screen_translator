// Service worker: orchestrates capture -> (crop) -> AI OCR+translate -> render.
// Mirrors lib/services/ai_vision_ocr_client.dart from the Flutter app.

importScripts('providers.js'); // self.PROVIDERS: claude / gemini / openai
// Optional git-ignored defaults (copy config.local.example.js). Missing file is fine.
try { importScripts('config.local.js'); } catch (_) {}
const LOCAL = self.LOCAL_CONFIG || {};

const DEFAULTS = {
  provider: LOCAL.provider || 'claude',
  proxyUrl: LOCAL.proxyUrl || '', // our proxy (see /proxy); it holds the real provider keys
  proxyToken: LOCAL.proxyToken || '',
  useOwnKey: false, // opt-in "bring your own key" mode — see popup.html's toggle
  keys: { ...(LOCAL.personalApiKey ? { claude: LOCAL.personalApiKey } : {}), ...(LOCAL.keys || {}) },
  models: LOCAL.models || {}, // optional per-provider model override
  targetLanguage: 'English',
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getSettings() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  // Empty/false stored values mean "unset", so they don't mask the local defaults.
  for (const k of Object.keys(stored)) if (stored[k] === '' || stored[k] === false) delete stored[k];
  const merged = { ...DEFAULTS, ...stored };
  // Per-provider maps merge key by key so one saved key doesn't hide the others.
  merged.keys = { ...DEFAULTS.keys, ...(stored.keys || {}) };
  merged.models = { ...DEFAULTS.models, ...(stored.models || {}) };
  for (const m of [merged.keys, merged.models]) for (const k of Object.keys(m)) if (!m[k]) delete m[k];
  if (!self.PROVIDERS[merged.provider]) merged.provider = 'claude';
  return merged;
}

/// Mirrors lib/services/ai_config.dart: the shared proxy (default) or the
/// user's own key for the chosen provider, called directly.
function requestFor(settings, b64) {
  const p = self.PROVIDERS[settings.provider];
  const model = (settings.models[settings.provider] || '').trim() || p.defaultModel;
  if (settings.useOwnKey) {
    return {
      p,
      url: p.directUrl(model),
      headers: p.directHeaders(settings.keys[settings.provider]),
      model,
    };
  }
  return {
    p,
    url: settings.proxyUrl.replace(/\/+$/, '') + p.proxyPath(model),
    headers: { 'content-type': 'application/json', authorization: `Bearer ${settings.proxyToken}` },
    model,
  };
}

async function ensureContent(tabId) {
  // Injected on demand (activeTab) instead of a broad <all_urls> content script.
  await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
}

function notify(tabId, text, kind = 'info') {
  return chrome.tabs.sendMessage(tabId, { type: 'status', text, kind }).catch(() => {});
}

async function cropDataUrl(dataUrl, rectPx) {
  const blob = await (await fetch(dataUrl)).blob();
  const bmp = await createImageBitmap(blob);
  const x = Math.max(0, Math.round(rectPx.x));
  const y = Math.max(0, Math.round(rectPx.y));
  const w = Math.min(bmp.width - x, Math.round(rectPx.w));
  const h = Math.min(bmp.height - y, Math.round(rectPx.h));
  const canvas = new OffscreenCanvas(w, h);
  canvas.getContext('2d').drawImage(bmp, x, y, w, h, 0, 0, w, h);
  const out = await canvas.convertToBlob({ type: 'image/png' });
  return { blob: out, width: w, height: h };
}

async function blobToBase64(blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

// Boxes are requested as normalized 0-1000 [ymin, xmin, ymax, xmax] (Gemini's
// native format; resolution-independent for the others) and converted to the
// pixel [left, top, width, height] that content.js expects.
function parseBlocks(raw, width, height) {
  let text = raw.trim().replace(/^```(?:json)?|```$/g, '').trim();
  const start = text.indexOf('['), end = text.lastIndexOf(']');
  if (start >= 0 && end > start) text = text.slice(start, end + 1);
  return JSON.parse(text)
    .filter((it) => Array.isArray(it.box_2d) && it.box_2d.length === 4)
    .map((it) => {
      const [ymin, xmin, ymax, xmax] = it.box_2d;
      return {
        text: it.text ?? '',
        translated: it.translated ?? it.text ?? '',
        bbox: [
          (xmin / 1000) * width,
          (ymin / 1000) * height,
          ((xmax - xmin) / 1000) * width,
          ((ymax - ymin) / 1000) * height,
        ],
      };
    });
}

async function extractAndTranslate({ base64, width, height, settings }) {
  const lang = settings.targetLanguage;
  const prompt =
    `Find every piece of legible on-screen text in this image. For each, return the original ` +
    `text, its translation into ${lang}, and its bounding box as "box_2d": [ymin, xmin, ymax, ` +
    `xmax] with each value normalized to the range 0-1000 relative to the image (0,0 is ` +
    `top-left; 1000,1000 is bottom-right). Skip text already in ${lang}.

` +
    `Return ONLY a JSON array, no commentary, each item shaped exactly as:
` +
    `{"text": "...", "translated": "...", "box_2d": [ymin, xmin, ymax, xmax]}`;

  const { p, url, headers, model } = requestFor(settings, base64);
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(p.body(model, prompt, base64)),
  });
  const via = settings.useOwnKey ? p.label : 'Proxy';
  if (res.status === 401 || res.status === 403) {
    throw new Error(`${via} rejected the ${settings.useOwnKey ? 'API key' : 'token'} (${res.status}).`);
  }
  if (res.status === 429) throw new Error(`Rate limited by ${via}; retry shortly.`);
  if (!res.ok) throw new Error(`${via} ${res.status}: ${(await res.text()).slice(0, 300)}`);

  return parseBlocks(p.extract(await res.json()), width, height);
}

async function run(tab, mode) {
  const tabId = tab.id;
  try {
    const settings = await getSettings();
    const own = settings.useOwnKey;
    if (own ? !settings.keys[settings.provider] : !settings.proxyUrl || !settings.proxyToken) {
      throw new Error(
        own
          ? `Set your ${self.PROVIDERS[settings.provider].label} API key in the extension popup first.`
          : 'Set the proxy URL and token in the extension popup first.',
      );
    }
    await ensureContent(tabId);

    let rect = null; // CSS px within the viewport
    if (mode === 'region') {
      rect = await chrome.tabs.sendMessage(tabId, { type: 'pickRegion' });
      if (!rect) return; // cancelled
      await sleep(120); // let the selection overlay disappear before capture
    }

    const { dpr } = await chrome.tabs.sendMessage(tabId, { type: 'viewport' });
    await notify(tabId, 'Capturing…');
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });

    let blob, width, height;
    if (rect) {
      ({ blob, width, height } = await cropDataUrl(dataUrl, {
        x: rect.x * dpr, y: rect.y * dpr, w: rect.w * dpr, h: rect.h * dpr,
      }));
    } else {
      blob = await (await fetch(dataUrl)).blob();
      const bmp = await createImageBitmap(blob);
      width = bmp.width;
      height = bmp.height;
    }

    await notify(tabId, 'Translating…');
    const blocks = await extractAndTranslate({
      base64: await blobToBase64(blob), width, height, settings,
    });

    await chrome.tabs.sendMessage(tabId, {
      type: 'render',
      blocks,
      // bbox is in captured-image pixels; content script works in CSS px.
      scale: 1 / dpr,
      offset: { x: rect?.x ?? 0, y: rect?.y ?? 0 },
    });
  } catch (e) {
    await notify(tabId, e.message || String(e), 'error');
  }
}

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (!tab?.id) return;
  if (command === 'translate-visible') run(tab, 'full');
  if (command === 'translate-region') run(tab, 'region');
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'getSettings') {
    getSettings().then(sendResponse);
    return true; // async response
  }
  if (msg.type === 'translate') {
    chrome.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
      if (tab) run(tab, msg.mode);
    });
    sendResponse({ ok: true });
  }
});
