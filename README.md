# Screen Translate

Cross-platform (Windows desktop / Flutter Web / iOS) screen-capture →
OCR → AI-translation → on-screen overlay app.

Verified in this environment: `flutter pub get` resolves, `flutter
analyze` is clean, `flutter test` passes, and `flutter build web`
compiles successfully (including a Wasm dry run). `flutter build windows`
could not be verified here because the local Visual Studio install is
missing the "Desktop development with C++" workload (`flutter doctor`
flags this) — the CMake/C++ wiring is in place and should build once that
workload is installed. iOS cannot be built or verified from a Windows
host at all; it needs Xcode on macOS.

## Architecture

```
lib/
  models/
    text_block.dart        // {id, originalText, bbox, translatedText}
    capture_frame.dart      // captured image + pixel/logical size + origin
  services/
    screen_translation_service.dart   // the platform-agnostic interface
    service_factory.dart              // conditional-import platform picker
    service_stub.dart / service_io.dart / service_web.dart
    service_windows.dart              // Windows implementation
    service_ios.dart                  // iOS implementation
    ai_translation_client.dart        // text-only translate (used by iOS, after ML Kit OCR)
    ai_vision_ocr_client.dart         // combined OCR+translate via AI vision (Windows/Web)
    ocr_service_mlkit.dart            // Google ML Kit wrapper (iOS/Android only)
  state/
    translation_controller.dart       // ChangeNotifier driving the pipeline
  ui/
    floating_trigger_button.dart
    translation_overlay_stack.dart
    home_page.dart / settings_page.dart
  main.dart                            // also the desktop_multi_window overlay entrypoint

windows/runner/
  screen_capture_channel.{h,cpp}       // GDI BitBlt + WIC PNG encode, MethodChannel
  NOTES.md                             // wiring notes (already applied to this template)

web/
  screen_capture_interop.js            // reference-only; service_web.dart uses package:web instead

ios/
  BroadcastExtension/SampleHandler.swift   // ReplayKit live-capture extension
  ShareExtension/ShareViewController.swift // one-off screenshot → app handoff
  LiveActivity/*.swift                     // Dynamic Island / Lock Screen widget
  Runner/AppDelegate.swift                 // registers ScreenTranslateChannels + deep-link handoff
  Runner/ScreenTranslateChannels.swift     // all 3 app-level method channels (see below)
  NOTES_XCODE_SETUP.md                     // step-by-step: App Groups + 3 extension targets
```

`ScreenTranslationService` is the one interface the UI/state layer talks
to (`initialize`, `captureOnce`, `recognizeText`, `showOverlay`,
`hideOverlay`, `updateTargetLanguage`, `dispose`). `service_factory.dart`
picks the concrete implementation at **compile time** via Dart's
conditional-import mechanism (`dart.library.js_interop` for Web,
`dart.library.io` for native, with a runtime `Platform.isWindows` /
`Platform.isIOS` check inside `service_io.dart` since both desktop and
iOS compile under `dart:io`).

### iOS method channels (ReplayKit ↔ Live Activity)

Three channels, all registered by `ios/Runner/ScreenTranslateChannels.swift`
from `AppDelegate.swift`, cover the whole loop:

1. **`screen_translate/broadcast_picker`** (`showPicker`) — called from
   `IosScreenTranslationService.prepareCaptureSession()`, wired to the
   "Start live capture" button on the home page. Native side momentarily
   adds an off-screen `RPSystemBroadcastPickerView` and forwards a
   synthetic tap to it, since that view has no supported
   present-programmatically API — this is what makes the system broadcast
   picker reachable from Flutter without a custom `PlatformView`.
2. Once the user picks the extension from that system popover, iOS runs
   `ios/BroadcastExtension/SampleHandler.swift` as its own process; it
   writes the latest frame (throttled to 1 fps) into the shared App Group
   container. `IosScreenTranslationService.captureOnce()` reads it
   straight off disk — no channel needed there, just a shared file.
3. **`screen_translate/live_activity`** (`getAppGroupContainerPath`,
   `startOrUpdateLiveActivity`, `endLiveActivity`) — resolves that App
   Group path, and starts/updates/ends the ActivityKit Live Activity
   (Dynamic Island / Lock Screen) once a capture has been OCR'd and
   translated. Requires iOS 16.2+ (see
   [ios/NOTES_XCODE_SETUP.md](ios/NOTES_XCODE_SETUP.md) step 6 for why
   16.1 isn't enough).
4. **`screen_translate/deeplink`** (`onShareExtensionCapture`) — the
   separate one-off path: `ios/ShareExtension/ShareViewController.swift`
   writes a screenshot to the same App Group container and opens
   `screentranslate://capture`; `AppDelegate.swift`'s
   `application(_:open:options:)` forwards that through this channel.
   `TranslationController.initialize()` wires
   `ScreenTranslationService.onExternalCaptureRequest` to
   `runCaptureAndTranslate` once, generically, so neither `main.dart` nor
   the UI layer needs an iOS-specific type check to hook this up.

Not build-verified against a real SDK — this machine has no macOS/Xcode
to compile against, and there's no way around that for iOS specifically.
Written against `FlutterPluginRegistry`/`FlutterPluginRegistrar` and
ActivityKit's `ActivityContent`-based API, both stable, documented
surfaces; see the comment in `NOTES_XCODE_SETUP.md` step 5 for the one
spot (`engineBridge.pluginRegistry`, from Flutter's newer
"implicit engine" `AppDelegate` pattern) worth double-checking against
your actual generated `AppDelegate.swift` if it doesn't compile as-is.

### Why OCR differs by platform

- **iOS**: `google_mlkit_text_recognition` runs on-device, giving
  pixel-accurate bounding boxes. Text is then sent (text-only, no image)
  to `AiTranslationClient` for translation.
- **Windows / Web**: ML Kit has no binding for either target. Rather than
  bundling Tesseract, `AiVisionOcrClient` sends the captured PNG straight
  to the AI model in one multimodal call and asks for
  `[{text, translated, bbox}]` back — one round trip, no extra native
  dependency, at the cost of boxes being the model's estimate rather than
  pixel-exact. Swap in a native OCR pass (Windows.Media.Ocr via WinRT, or
  Tesseract.js on Web) if you need exact boxes later; the
  `ScreenTranslationService` interface doesn't change either way.

## pubspec.yaml — package choices

| Package | Why |
|---|---|
| `http` | Calls to our proxy (`/proxy`), which forwards to the Claude Messages API |
| `web` | Modern typed `dart:js_interop` bindings for `getDisplayMedia` — replaces hand-written `@JS()` externs |
| `provider` | `TranslationController` (ChangeNotifier) distribution |
| `google_mlkit_text_recognition` | On-device OCR, iOS/Android only |
| `tray_manager` | Windows system tray icon + menu |
| `hotkey_manager` | Windows global hotkey (default `Ctrl+Shift+T`) |
| `window_manager` | Frameless/transparent/always-on-top window control |
| `screen_retriever` | Display bounds + logical size for coordinate mapping |
| `desktop_multi_window` | Spawns the separate transparent overlay window on Windows |
| `path_provider` | Temp file for ML Kit's file-based `InputImage` API |
| `image` | Available for raw-buffer decode if you swap the native capture format |
| `uuid` | Available for block IDs if you move off simple counters |

## Native permissions / capabilities per platform

- **Windows**: none at the OS-permission level — GDI screen capture and
  global hotkeys don't require a manifest entry. `SYSTEM_ALERT_WINDOW` is
  an **Android** concept (this app targets Windows/Web/iOS, not Android,
  per this iteration's scope) and doesn't apply here.
- **Web**: `getDisplayMedia` triggers the browser's native
  tab/window/screen picker at call time — no manifest permission, but it
  **must** be called from a user-gesture handler (already the case: the
  floating trigger's `onTap`).
- **iOS**: App Groups capability (`group.com.example.screentranslate`) on
  all four targets (Runner, BroadcastExtension, ShareExtension,
  ScreenTranslateWidget), `NSSupportsLiveActivities` in `Info.plist`, and
  the `screentranslate://` URL scheme for the Share Extension handoff.
  Full steps: [ios/NOTES_XCODE_SETUP.md](ios/NOTES_XCODE_SETUP.md).

## Running it

```bash
flutter pub get

# Windows (needs Visual Studio "Desktop development with C++" workload)
flutter run -d windows --dart-define=PROXY_URL=https://proxy.example.com --dart-define=PROXY_TOKEN=...

# Web
flutter run -d chrome --dart-define=PROXY_URL=https://proxy.example.com --dart-define=PROXY_TOKEN=...

# iOS (from macOS only, after completing ios/NOTES_XCODE_SETUP.md)
flutter run -d <device-or-simulator> --dart-define=PROXY_URL=... --dart-define=PROXY_TOKEN=...
```

The app never holds an Anthropic key. It calls the proxy in [proxy/](proxy/README.md) with a
revocable bearer token; the real key lives only on the proxy server.

**Local secrets (all git-ignored, each with a committed `.example` template):**

| File | Holds | Template |
|---|---|---|
| `lib/secrets.dart` | proxy URL + token for the Flutter app | `lib/secrets.example.dart` |
| `proxy/.env` | the real `ANTHROPIC_API_KEY` + allowed tokens | `proxy/.env.example` |
| `chrome_extension/config.local.js` | default proxy URL + token for the extension | `config.local.example.js` |

On a fresh clone, copy each template and fill it in. `--dart-define=PROXY_URL=... --dart-define=PROXY_TOKEN=...`
still overrides `lib/secrets.dart` (useful for CI/release). The token ends up embedded in the built app
(and visible in the JS on Web), so treat it as revocable rather than secret. Flutter Web also needs its
origin listed in the proxy's `ALLOWED_ORIGINS`.

**Bring your own key:** Settings also has a "Use my own Anthropic API key" toggle
(`lib/services/ai_settings.dart`, `lib/ui/settings_page.dart`) that switches a user from the
shared proxy to calling Anthropic directly with a personal key they type in — persisted locally
via `shared_preferences`, takes effect on the next capture, no rebuild needed. This skips the
proxy's rate limiting/revocability and, on Web, puts the key in a request header any network
inspector on that device can read; the in-app copy says so next to the toggle.

## Known gaps / where to extend next

- `WindowsScreenTranslationService.captureRegion()` calls
  `_captureChannel.invokeMethod('captureRegion')`, backed by
  `ScreenCaptureChannel::CaptureRegion()` in
  `windows/runner/screen_capture_channel.cpp` — a full drag-to-select
  picker (`RegionSelector`): a per-pixel-alpha layered window dims the
  whole virtual screen and punches a live "hole" over the drag rect
  (Snipping Tool-style), Esc cancels, multi-monitor bounds are clamped.
  Not build-tested end-to-end on this machine (Visual Studio's C++
  workload is incomplete here — see the top of this file); it compiles
  against the same reviewed patterns as `captureFullScreen()`. Known
  limitation: `GetDpiForSystem()` only reflects the primary monitor's
  scale factor, so a region dragged on a secondary monitor with a
  different DPI will have slightly-off `logicalWidth`/`logicalHeight` —
  see the comment in `CaptureRegion()` for the per-monitor fix. Perf notes
  for very large multi-monitor setups are in
  [windows/runner/NOTES.md](windows/runner/NOTES.md).
- The floating trigger button itself, on Windows, is described in the
  spec as living in its own always-on-top window; this starter wires the
  *overlay* (translated text) into a `desktop_multi_window` window but
  reuses the main app window for the trigger button for simplicity — spawn
  a second tiny always-on-top window the same way if you want the trigger
  itself to float over other apps too.
- Web has no OS-level "floating over other apps" concept at all (browser
  sandboxing) — captured frame + translated chips render inside the app's
  own page, per the spec's Web section.
- `AiTranslationClient` / `AiVisionOcrClient` take an `AiConfig` (proxy URL, token, model,
  default `claude-sonnet-5`). To use another provider, change the proxy's upstream, not the clients.
