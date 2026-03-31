import Flutter
import UIKit
import FluidAudio

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Setup Parakeet method channel
    let controller = window?.rootViewController as! FlutterViewController
    let parakeetChannel = FlutterMethodChannel(
      name: "com.parachute.app/parakeet",
      binaryMessenger: controller.binaryMessenger
    )

    parakeetChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "initialize":
        let args = call.arguments as? [String: Any]
        let versionString = args?["version"] as? String ?? "v3"
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3
        ParakeetBridge.shared.initialize(version: version, result: result)

      case "transcribe":
        guard let args = call.arguments as? [String: Any],
              let audioPath = args["audioPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing audioPath", details: nil))
          return
        }
        ParakeetBridge.shared.transcribe(audioPath: audioPath, result: result)

      case "isReady":
        ParakeetBridge.shared.isReady(result: result)

      case "getModelInfo":
        ParakeetBridge.shared.getModelInfo(result: result)

      case "areModelsDownloaded":
        ParakeetBridge.shared.areModelsDownloaded(result: result)

      // Speaker diarization methods
      case "initializeDiarizer":
        ParakeetBridge.shared.initializeDiarizer(result: result)

      case "diarizeAudio":
        guard let args = call.arguments as? [String: Any],
              let audioPath = args["audioPath"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing audioPath", details: nil))
          return
        }
        ParakeetBridge.shared.diarizeAudio(audioPath: audioPath, result: result)

      case "isDiarizerReady":
        ParakeetBridge.shared.isDiarizerReady(result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
