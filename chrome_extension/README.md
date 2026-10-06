# Screen Translate - Chrome extension

Manifest V3 port of the Flutter app's Web flow, but simpler: no
`getDisplayMedia` picker, since extensions can capture the visible tab directly.

## Install (unpacked)

1. Open `chrome://extensions`, enable **Developer mode**.
2. **Load unpacked** and select this `chrome_extension/` folder.
3. Optional: `cp config.local.example.js config.local.js` (git-ignored) and fill it in to prefill the popup.
4. Click the extension icon, enter your proxy URL and token (see [../proxy](../proxy/README.md)),
   pick a target language. Chrome will ask once to allow access to the proxy's origin only.

## Use

- **Translate tab** (or `Ctrl+Shift+T`): captures the visible viewport and overlays translations.
- **Select region** (or `Ctrl+Shift+Y`): drag a box; only that area is translated.
- `Esc` dismisses the overlay. Hover a chip to see the original text.
- Rebind shortcuts at `chrome://extensions/shortcuts`.

## How it works

`background.js` (service worker) -> `chrome.tabs.captureVisibleTab` -> optional crop
(`OffscreenCanvas`) -> one vision call to the provider you choose (Claude, Gemini or ChatGPT, via the proxy or your own key;
`providers.js`) returning `[{text, translated, box_2d}]` (same prompt as `lib/services/ai_vision_ocr_client.dart`),
converted from normalized coordinates to pixels -> `content.js` draws chips in a
Shadow DOM at `bbox / devicePixelRatio` so page CSS can't affect them.
`content.js` is injected on demand via `activeTab`, and host access is requested at runtime for just the proxy's origin.

## Caveats

- The extension holds only a proxy URL and bearer token (stored unencrypted in `chrome.storage.local`),
  never an Anthropic key, by default. The token is revocable and rate-limited server-side.
- The popup's "Use my own API key" checkbox switches to calling the chosen provider directly with a
  personal key you paste in (one saved per provider) — still stored unencrypted in `chrome.storage.local`, but now it IS the
  real key, sent straight from your browser. Off by default; opt in only if you'd rather not run a
  proxy and are fine with the key being extractable from this browser profile.
- Bounding boxes are the model's estimate, so chips can be a few pixels off.
- Only the visible viewport is captured (no full-page scroll capture), and `chrome://` pages and
  the Web Store can't be captured.
- Not tested inside a real Chrome extension host here. Only manifest JSON validity and JS syntax
  were checked, so load it unpacked and check the service worker console if something fails.
