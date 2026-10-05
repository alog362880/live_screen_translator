import ActivityKit
import Flutter
import ReplayKit
import UIKit

/// Registers every app-level (non-pub-package) method channel this app
/// uses on iOS:
///
///  - `screen_translate/live_activity`   — resolve the shared App Group
///    container path, and start/update/end the Live Activity.
///  - `screen_translate/deeplink`        — forwards the Share Extension's
///    `screentranslate://capture` handoff (see AppDelegate.swift, which
///    owns the actual `application(_:open:options:)` override and calls
///    into `notifyShareExtensionCapture()` here).
///  - `screen_translate/broadcast_picker` — triggers the system
///    RPSystemBroadcastPickerView so the user can start a ReplayKit
///    broadcast without ever leaving the app or hunting through Control
///    Center.
///
/// Conforms to `FlutterPlugin` purely to reuse its `register(with:)`
/// entry-point convention and `FlutterPluginRegistrar` (which hands back
/// the engine's `FlutterBinaryMessenger`); it is wired up manually from
/// `AppDelegate.swift` rather than through `GeneratedPluginRegistrant`,
/// since this isn't a pub package.
class ScreenTranslateChannels: NSObject, FlutterPlugin {

    static let shared = ScreenTranslateChannels()

    /// Must match the App Group configured in Xcode -> Signing &
    /// Capabilities for the Runner, BroadcastExtension, ShareExtension
    /// and ScreenTranslateWidget targets (see NOTES_XCODE_SETUP.md).
    private let appGroupId = "group.com.example.screentranslate"

    private var currentActivity: Activity<ScreenTranslateActivityAttributes>?
    private var deeplinkChannel: FlutterMethodChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()

        let liveActivityChannel = FlutterMethodChannel(
            name: "screen_translate/live_activity", binaryMessenger: messenger)
        liveActivityChannel.setMethodCallHandler { call, result in
            shared.handleLiveActivityCall(call, result: result)
        }

        let deeplinkChannel = FlutterMethodChannel(
            name: "screen_translate/deeplink", binaryMessenger: messenger)
        shared.deeplinkChannel = deeplinkChannel

        let broadcastChannel = FlutterMethodChannel(
            name: "screen_translate/broadcast_picker", binaryMessenger: messenger)
        broadcastChannel.setMethodCallHandler { call, result in
            shared.handleBroadcastPickerCall(call, result: result)
        }
    }

    // MARK: - screen_translate/deeplink

    /// Called by AppDelegate's `application(_:open:options:)` when the
    /// Share Extension hands a freshly-captured screenshot back to us.
    func notifyShareExtensionCapture() {
        deeplinkChannel?.invokeMethod("onShareExtensionCapture", arguments: nil)
    }

    // MARK: - screen_translate/live_activity

    private func handleLiveActivityCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAppGroupContainerPath":
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId)
            {
                result(url.path)
            } else {
                result(FlutterError(
                    code: "NO_APP_GROUP",
                    message: "App Group '\(appGroupId)' isn't configured for this target — "
                        + "see ios/NOTES_XCODE_SETUP.md step 1.",
                    details: nil))
            }

        case "startOrUpdateLiveActivity":
            guard let args = call.arguments as? [String: Any],
                  let summary = args["summaryText"] as? String,
                  let count = args["blockCount"] as? Int
            else {
                result(FlutterError(code: "BAD_ARGS", message: "Missing summaryText/blockCount", details: nil))
                return
            }
            startOrUpdateLiveActivity(summary: summary, count: count)
            result(nil)

        case "endLiveActivity":
            let activity = currentActivity
            currentActivity = nil
            Task { await activity?.end(nil, dismissalPolicy: .immediate) }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startOrUpdateLiveActivity(summary: String, count: Int) {
        let state = ScreenTranslateActivityAttributes.ContentState(summaryText: summary, blockCount: count)

        if let activity = currentActivity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // User has Live Activities disabled in Settings, or the app
            // hasn't requested the entitlement yet — fail silently, the
            // in-app modal overlay (translation_overlay_stack.dart) still
            // shows the result regardless of whether this succeeds.
            return
        }
        do {
            currentActivity = try Activity.request(
                attributes: ScreenTranslateActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil))
        } catch {
            // Concurrent-activity limit, user declined, etc — same
            // fallback as above.
        }
    }

    // MARK: - screen_translate/broadcast_picker

    private func handleBroadcastPickerCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "showPicker" else {
            result(FlutterMethodNotImplemented)
            return
        }
        presentBroadcastPicker()
        result(nil)
    }

    /// `RPSystemBroadcastPickerView` has no public "present
    /// programmatically" API — Apple's intended usage is to place it as
    /// an ordinary button in your UI and let the user tap it directly,
    /// which then shows a small system popover listing available
    /// broadcast extensions. Flutter has no first-party binding for
    /// hosting that UIKit view, so this adds it off-screen for one
    /// runloop turn and forwards a synthetic tap to its single internal
    /// `UIButton` — a workaround documented and used across several
    /// shipped apps, since there's no supported alternative entry point.
    private func presentBroadcastPicker() {
        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return }

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: -200, y: -200, width: 1, height: 1))
        picker.preferredExtension = broadcastExtensionBundleId
        picker.showsMicrophoneButton = false
        keyWindow.addSubview(picker)

        // Let the picker finish laying out its internal button before we
        // look for it.
        DispatchQueue.main.async {
            let button = picker.subviews.first { $0 is UIButton } as? UIButton
            button?.sendActions(for: .touchUpInside)

            // The system popover this spawns is independent OS UI and
            // keeps working once shown, so it's safe to tear the anchor
            // view down shortly after — no need to keep it alive for the
            // whole broadcast.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                picker.removeFromSuperview()
            }
        }
    }

    /// Xcode's default bundle identifier for a Broadcast Upload Extension
    /// target named "BroadcastExtension" is `<main app bundle id>
    /// .BroadcastExtension` — matches the target created per
    /// NOTES_XCODE_SETUP.md step 2. If you renamed the extension target
    /// or its bundle id diverges from this convention, hardcode the
    /// actual value here instead.
    private var broadcastExtensionBundleId: String {
        guard let mainBundleId = Bundle.main.bundleIdentifier else {
            return "com.example.screentranslate.BroadcastExtension"
        }
        return "\(mainBundleId).BroadcastExtension"
    }
}
