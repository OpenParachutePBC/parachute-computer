import Cocoa
import FlutterMacOS
import FluidAudio

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Setup Parakeet method channel
    if let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let parakeetChannel = FlutterMethodChannel(
        name: "com.parachute.app/parakeet",
        binaryMessenger: flutterViewController.engine.binaryMessenger
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
    }

    super.applicationDidFinishLaunching(notification)
  }
}
