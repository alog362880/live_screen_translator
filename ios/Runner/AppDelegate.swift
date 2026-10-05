import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // App-level method channels this project adds on top of the standard
    // pub-package plugins — not covered by GeneratedPluginRegistrant since
    // they don't live in a separate package. See ScreenTranslateChannels.swift.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScreenTranslateChannels")
    ScreenTranslateChannels.register(with: registrar)
  }

  /// Handles the `screentranslate://capture` deep link sent by
  /// ShareViewController.swift after it writes a screenshot into the
  /// shared App Group container (see ios/ShareExtension/).
  override func application(
    _ app: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "screentranslate", url.host == "capture" {
      ScreenTranslateChannels.shared.notifyShareExtensionCapture()
      return true
    }
    return super.application(app, open: url, options: options)
  }
}
