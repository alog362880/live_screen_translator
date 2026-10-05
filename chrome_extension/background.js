// Service worker: orchestrates capture -> (crop) -> AI OCR+translate -> render.
// Mirrors lib/services/ai_vision_ocr_client.dart from the Flutter app.

// Optional git-ignored defaults (copy config.local.example.js). Missing file is fine.
try { importScripts('config.local.js'); } catch (_) {}
const LOCAL = self.LOCAL_CONFIG || {};

const DEFAULTS = {
  proxyUrl: LOCAL.proxyUrl || '', // our proxy (see /proxy); it holds the real Anthropic key
  proxyToken: LOCAL.proxyToken || '',
  useOwnKey: false, // opt-in "bring your own key" mode — see popup.html's toggle
  personalApiKey: LOCAL.personalApiKey || '',
  targetLanguage: 'English',
  model: 'claude-sonnet-5',
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getSettings() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  // Empty/false stored values mean "unset", so they don't mask the local defaults.
  for (const k of Object.keys(stored)) if (stored[k] === '' || stored[k] === false) delete stored[k];
  return { ...DEFAULTS, ...stored };
}

/// Mirrors lib/services/ai_config.dart's two AiConfig modes: the shared
/// proxy (default) or the user's own Anthropic key, called directly.
function endpointFor(settings) {
  if (settings.useOwnKey) {
    return {
      url: 'https://api.anthropic.com/v1/messages',
      headers: {
        'content-type': 'application/json',
        'x-api-key': settings.personalApiKey,
        'anthropic-version': '2023-06-01',
        'anthropic-dangerous-direct-browser-access': 'true',
      },
    };
  }
  return {
    url: `${settings.proxyUrl.replace(/\/+$/, '')}/v1/messages`,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${settings.proxyToken}`,
    },
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

async function extractAndTranslate({ base64, width, height, settings }) {
  const prompt =
    `Find every piece of legible on-screen text in this image. For each, return its ` +
    `bounding box in pixel coordinates of the ORIGINAL image (width=${width}, ` +
    `height=${height}) and its translation into ${settings.targetLanguage}.\n\n` +
    `Return ONLY a JSON array, no commentary, each item shaped exactly as:\n` +
    `{"text": "...", "translated": "...", "bbox": [left, top, width, height]}\n` +
    `Skip text already in ${settings.targetLanguage}.`;

  const { url, headers } = endpointFor(settings);
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: settings.model,
      max_tokens: 4096,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: 'image/png', data: base64 } },
            { type: 'text', text: prompt },
          ],
        },
      ],
    }),
  });
  const via = settings.useOwnKey ? 'Anthropic' : 'Proxy';
  if (res.status === 401) throw new Error(`${via} rejected the ${settings.useOwnKey ? 'API key' : 'token'} (401).`);
  if (res.status === 429) throw new Error(`Rate limited by ${via.toLowerCase()}; retry shortly.`);
  if (!res.ok) throw new Error(`${via} ${res.status}: ${(await res.text()).slice(0, 300)}`);

  const data = await res.json();
  const raw = data.content?.[0]?.text ?? '[]';
  // Models sometimes wrap JSON in a code fence despite instructions.
  const cleaned = raw.trim().replace(/^```json|^```|```$/g, '').trim();
  return JSON.parse(cleaned);
}

async function run(tab, mode) {
  const tabId = tab.id;
  try {
    const settings = await getSettings();
    if (settings.useOwnKey ? !settings.personalApiKey : !settings.proxyUrl || !settings.proxyToken) {
      throw new Error(
        settings.useOwnKey
          ? 'Set your Anthropic API key in the extension popup first.'
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
