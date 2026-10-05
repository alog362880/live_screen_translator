# iOS setup: App Groups, Broadcast/Share/Widget extension targets

Run `flutter create .` once first if `ios/Runner.xcworkspace` doesn't
exist yet, then open `ios/Runner.xcworkspace` (not `.xcodeproj`) in Xcode
for everything below.

## 1. App Group (shared container for all four targets)

1. Select the **Runner** target -> Signing & Capabilities -> **+ Capability** -> App Groups.
2. Add group `group.com.example.screentranslate` (must match `appGroupId`
   in `SampleHandler.swift`, `ShareViewController.swift`, and
   `ScreenTranslateChannels.swift` — change all three together if you
   rename it).
3. Repeat step 1-2 for every extension target added below (each needs the
   *same* App Group capability, or `containerURL(forSecurityApplicationGroupIdentifier:)`
   returns `nil` for that target).

## 2. Broadcast Upload Extension (live screen capture)

1. File > New > Target > **Broadcast Upload Extension**. Name it
   `BroadcastExtension`, uncheck "Include UI Extension" (we don't need a
   custom broadcast-start UI).
2. Delete the auto-generated `SampleHandler.swift` Xcode creates for this
   target and add this repo's `ios/BroadcastExtension/SampleHandler.swift`
   in its place (Target Membership: BroadcastExtension only).
3. Add the App Group capability to this target (step 1 above).
4. **Bundle identifier**: leave Xcode's default for this target —
   `<main app bundle id>.BroadcastExtension` (e.g.
   `com.example.screentranslate.BroadcastExtension`). This is what
   `ScreenTranslateChannels.swift`'s `broadcastExtensionBundleId`
   computes automatically (`Bundle.main.bundleIdentifier +
   ".BroadcastExtension"`); if you rename the target and its bundle id
   ends up different, hardcode the real value in that file instead.
5. **Runner needs `ReplayKit.framework` too** (not just the extension) —
   `ScreenTranslateChannels.swift` imports it to show the system picker.
   Xcode usually links it automatically from the `import`, but if the
   build fails with a ReplayKit linker error, add it explicitly: Runner
   target -> General -> Frameworks, Libraries, and Embedded Content -> +
   -> `ReplayKit.framework`.

Triggering the picker from Flutter (no native UI needed): the app calls
`MethodChannel('screen_translate/broadcast_picker').invokeMethod('showPicker')`
(wired in `IosScreenTranslationService.prepareCaptureSession()` /
`lib/services/service_ios.dart`), which `ScreenTranslateChannels.swift`
handles by momentarily adding an off-screen `RPSystemBroadcastPickerView`
and forwarding a synthetic tap to it — see that file's
`presentBroadcastPicker()` for why (there's no supported way to present
this system picker without a real, tapped, on-screen button).

## 3. Share Extension (one-off screenshot capture)

1. File > New > Target > **Share Extension** (or Action Extension if you
   want it to also appear in the Photos app's edit-action row). Name it
   `ShareExtension`.
2. Replace the generated `ShareViewController.swift` with this repo's
   `ios/ShareExtension/ShareViewController.swift`.
3. In the extension's `Info.plist`, restrict `NSExtensionActivationRule`
   to images only:
   ```xml
   <key>NSExtensionActivationSupportsImageWithMaxCount</key>
   <integer>1</integer>
   ```
4. Add the App Group capability to this target.
5. In the **Runner** target's `Info.plist`, register the
   `screentranslate://` URL scheme so the extension can hand off back to
   the app (Xcode: Runner target -> Info -> URL Types -> + -> URL Schemes: `screentranslate`).

## 4. Widget Extension with Live Activity (Dynamic Island / Lock Screen)

1. File > New > Target > **Widget Extension**, check **Include Live
   Activity**. Name it `ScreenTranslateWidget`.
2. Delete the placeholder Live Activity file it generates; add this
   repo's `ios/LiveActivity/ScreenTranslateActivityAttributes.swift` and
   `ScreenTranslateLiveActivity.swift`.
3. **Target Membership**: `ScreenTranslateActivityAttributes.swift` must
   be checked for BOTH the `Runner` target and the
   `ScreenTranslateWidget` target (File Inspector, right panel) — the app
   starts the Activity, the widget extension renders it, both need the
   type.
4. In `Runner`'s `Info.plist`, add:
   ```xml
   <key>NSSupportsLiveActivities</key>
   <true/>
   ```

## 5. Method channels

Already wired in this template — `ios/Runner/ScreenTranslateChannels.swift`
registers all three app-level channels (`screen_translate/live_activity`,
`screen_translate/deeplink`, `screen_translate/broadcast_picker`), and
`ios/Runner/AppDelegate.swift` calls `ScreenTranslateChannels.register(with:)`
from `didInitializeImplicitFlutterEngine(_:)` and forwards the Share
Extension's `screentranslate://capture` deep link into it. Nothing to
merge by hand — just make sure `ScreenTranslateChannels.swift` is added to
the **Runner** target only (Xcode adds new files to the target you have
selected when you create/import them; double-check in the File Inspector
if it doesn't compile with an "unresolved identifier" for `AppDelegate`).

This was written against the `FlutterPluginRegistry`/`FlutterPluginRegistrar`
protocols, which have been stable across Flutter iOS embeddings for years,
but the surrounding `FlutterImplicitEngineDelegate` pattern in
`AppDelegate.swift` is newer — if `engineBridge.pluginRegistry` doesn't
resolve on your installed Flutter version, check what
`GeneratedPluginRegistrant.register(with:)` is called with in your own
generated `AppDelegate.swift` (that call is regenerated fresh by `flutter
create`/`flutter pub get` and is the reliable source of truth) and pass
that same value to `ScreenTranslateChannels.register(with:)` instead.

## 6. Minimum deployment target

**iOS 16.2+**, not just 16.1 — `ScreenTranslateChannels.swift` uses the
`ActivityContent<ContentState>`-based `Activity.request(attributes:content:)`
/ `activity.update(_:)` API, which is 16.2+ (the initial 16.1 ActivityKit
API took a raw `ContentState` and is now soft-deprecated). Set
`ios/Podfile`'s `platform :ios, '16.2'` and the Runner target's Deployment
Target to match, or the Live Activity calls will fail to compile.

## 7. Testing notes

- The Broadcast Upload Extension can **only** be tested on a physical
  device or the Simulator's screen-recording picker — it does not run
  under `flutter run`'s hot reload.
- `RPSystemBroadcastPickerView` requires the app to NOT be sandboxed
  under certain corporate MDM profiles; if the picker shows no
  extensions, check the extension's bundle ID matches
  `preferredExtension` exactly (case-sensitive).
