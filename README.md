# Screen Translate

Capture your screen (or a region), read the text on it with AI vision, translate it into a language you
choose, and draw the translation directly over the original text.

| Part | What it is | Docs |
|---|---|---|
| **Flutter app** | Windows desktop, Web and iOS | this file |
| **Chrome extension** | Translate the visible tab (Manifest V3) | [chrome_extension/README.md](chrome_extension/README.md) |
| **Proxy server** | Keeps your real API keys off client devices | [proxy/README.md](proxy/README.md) |

Works with **Claude, Gemini and ChatGPT**. Use a shared proxy, or bring your own API key.

## Quick start

You need the Flutter SDK, plus the platform tooling for whichever target you run.

```bash
flutter pub get

# 1. Local secrets (git-ignored; copy each template and fill it in)
cp lib/secrets.example.dart lib/secrets.dart       # proxy URL + token for the app
cp proxy/.env.example proxy/.env                   # real provider key(s) + tokens (proxy only)

# 2. Start the proxy (needs at least one provider key in proxy/.env)
cd proxy && dart pub get && dart run bin/server.dart     # listens on :8080

# 3. Run the app
flutter run -d chrome                  # Web
flutter run -d windows                 # Windows (see requirements below)
```

`--dart-define=PROXY_URL=... --dart-define=PROXY_TOKEN=...` overrides `lib/secrets.dart`, which is useful
for CI and release builds.

**Don't want to run a proxy?** Open Settings in the app, turn on **Use my own API key**, pick a provider and
paste your key. It takes effect on the next capture, with no rebuild.

### Platform requirements

- **Windows:** Visual Studio with the **Desktop development with C++** workload.
- **Web:** nothing extra.
- **iOS:** macOS with Xcode, plus the extension targets described in [ios/NOTES_XCODE_SETUP.md](ios/NOTES_XCODE_SETUP.md).

## AI providers

Pick a provider in **Settings** (or the extension popup). Each can be reached through the proxy or directly
with your own key, and each keeps its own saved key and optional model override.

| Provider | Default model | Key from |
|---|---|---|
| Claude (Anthropic) | `claude-sonnet-5` | console.anthropic.com |
| Gemini (Google) | `gemini-2.5-flash` | aistudio.google.com |
| ChatGPT (OpenAI) | `gpt-4o-mini` | platform.openai.com |

- `lib/services/ai_config.dart` builds each provider's native request and parses its response.
- All three are asked for text boxes in one format: normalized 0–1000 `[ymin, xmin, ymax, xmax]`, converted to
  pixels locally. How accurately translations line up with the original text depends on the model, so
  placement is approximate.
- Model names change over time. Override them in Settings, or in the proxy's `ALLOWED_MODELS_*` variables.

### Proxy mode (default) vs your own key

| | Proxy | Own key |
|---|---|---|
| Real API key lives | on your proxy server only | on the user's device |
| Client carries | a revocable, rate-limited token | the real key |
| Setup | run `proxy/` and set `PROXY_URL` / `PROXY_TOKEN` | paste a key in Settings |

The proxy token is still embedded in a built app (and visible in the JavaScript on Web), so treat it as
revocable rather than secret. With your own key on Web or in the extension, the key is visible to anyone
inspecting that browser's network traffic. Give such keys a spend limit.

## Local secrets

All git-ignored, each with a committed `.example` template:

| File | Holds | Template |
|---|---|---|
| `lib/secrets.dart` | proxy URL + token for the Flutter app | `lib/secrets.example.dart` |
| `proxy/.env` | `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `PROXY_TOKENS` | `proxy/.env.example` |
| `chrome_extension/config.local.js` | default proxy URL, token and provider for the extension | `config.local.example.js` |

## How it works

```
capture ──► AI vision (OCR + translate in one call) ──► boxes → pixels ──► overlay
```

| Platform | Capture | Overlay |
|---|---|---|
| Windows | Win32 GDI full screen, or a Snipping Tool-style drag-to-select region (C++ method channel); tray icon and `Ctrl+Shift+T` global hotkey | transparent always-on-top second window |
| Web | `getDisplayMedia` via `package:web` | chips drawn over the captured frame in the page |
| iOS | ReplayKit Broadcast Upload Extension (frames shared via an App Group), or a Share Extension for one-off screenshots | in-app overlay + Live Activity (Dynamic Island / Lock Screen) |

On iOS, text is recognized on-device with Google ML Kit first, and only the text (not the image) is sent for
translation. On Windows and Web there is no bundled OCR engine, so the screenshot goes straight to the AI
model, which does both jobs in one request.

### Code structure

```
lib/
  models/       TextBlock, CaptureFrame
  services/
    screen_translation_service.dart   platform-agnostic interface the UI talks to
    service_factory.dart              picks the implementation at compile time (conditional imports)
    service_windows.dart / service_web.dart / service_ios.dart
    ai_config.dart                    providers: endpoints, headers, request bodies, response parsing
    ai_settings.dart                  runtime provider / mode / keys, persisted with shared_preferences
    ai_client.dart                    one request/response round trip + JSON cleanup
    ai_vision_ocr_client.dart         OCR + translate from an image (Windows / Web)
    ai_translation_client.dart        translate already-recognized text (iOS)
    ocr_service_mlkit.dart            Google ML Kit wrapper (iOS)
  state/        TranslationController (drives the pipeline)
  ui/           home page, settings, floating trigger button, overlay stack
windows/runner/ screen_capture_channel.{h,cpp}   GDI + WIC capture and the region picker
ios/            Broadcast / Share / Live Activity extensions, Runner/ScreenTranslateChannels.swift
proxy/          Dart proxy server (bin/, lib/, tests)
chrome_extension/
```

iOS method channels: `screen_translate/broadcast_picker` (shows the system broadcast picker),
`screen_translate/live_activity` (App Group path and Live Activity updates) and `screen_translate/deeplink`
(Share Extension handoff). Details are in [ios/NOTES_XCODE_SETUP.md](ios/NOTES_XCODE_SETUP.md) and
[windows/runner/NOTES.md](windows/runner/NOTES.md).

## Tests

```bash
flutter analyze && flutter test     # provider request/response + box-conversion tests, widget smoke test
cd proxy && dart test               # auth, rate limit, model allowlist, field stripping, routing, CORS
```

## Status

| Part | State |
|---|---|
| Dart code | `flutter analyze` clean, all tests pass |
| Web | `flutter build web` compiles |
| Proxy | tested against a fake upstream and a real server start; never run against the live provider APIs |
| Chrome extension | logic tested in headless Chrome with stubbed APIs; not yet loaded in a real Chrome |
| Windows | C++ capture and region picker wired in and the picker's Win32 code compiles standalone, but `flutter build windows` hasn't been run (the Visual Studio C++ workload was missing on the dev machine) |
| iOS | written but never built (needs macOS/Xcode) |
| Live AI calls | none made yet, so prompts, model names and overlay alignment are untested against real responses |

## Known limitations

- **Region picker DPI:** `GetDpiForSystem()` only reflects the primary monitor's scale, so a region dragged on a
  secondary monitor with a different DPI has slightly off logical sizes. Multi-monitor performance notes are in
  [windows/runner/NOTES.md](windows/runner/NOTES.md).
- **Windows trigger button:** the translated overlay is its own always-on-top window, but the trigger button
  lives in the main app window. A second small floating window would be needed for a trigger that floats over
  other apps.
- **Web:** browsers can't draw over other apps, so the result appears inside the page, over the captured frame.
- **Proxy rate limiting:** in memory and per process, so it resets on restart and isn't shared across replicas.
