import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "com.wujian.app.icheck/file_saver"
  private var pendingResult: FlutterResult?
  private var pickerDelegate: FileSavePickerDelegate?

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result) ?? result(
        FlutterError(code: "unavailable", message: "App delegate is unavailable.", details: nil)
      )
    }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  fileprivate func completeSave(success: Bool) {
    pendingResult?(success)
    pendingResult = nil
    pickerDelegate = nil
  }

  fileprivate func failSave(_ code: String, _ message: String) {
    pendingResult?(FlutterError(code: code, message: message, details: nil))
    pendingResult = nil
    pickerDelegate = nil
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "saveFile" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard pendingResult == nil else {
      result(
        FlutterError(code: "busy", message: "Another file save is already in progress.", details: nil)
      )
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let path = arguments["path"] as? String,
      let fileName = arguments["fileName"] as? String,
      !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      result(
        FlutterError(code: "invalid_args", message: "Missing file path or file name.", details: nil)
      )
      return
    }

    let sourceUrl = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: sourceUrl.path) else {
      result(
        FlutterError(code: "missing_file", message: "File does not exist.", details: nil)
      )
      return
    }

    guard let presenter = topViewController() else {
      result(
        FlutterError(code: "unavailable", message: "No active view controller is available.", details: nil)
      )
      return
    }

    let tempDirectory = FileManager.default.temporaryDirectory
    let exportUrl = tempDirectory.appendingPathComponent(fileName)
    try? FileManager.default.removeItem(at: exportUrl)

    do {
      try FileManager.default.copyItem(at: sourceUrl, to: exportUrl)
    } catch {
      result(
        FlutterError(code: "copy_failed", message: error.localizedDescription, details: nil)
      )
      return
    }

    pendingResult = result
    let picker = UIDocumentPickerViewController(url: exportUrl, in: .exportToService)
    let delegate = FileSavePickerDelegate(appDelegate: self, exportedUrl: exportUrl)
    picker.delegate = delegate
    picker.modalPresentationStyle = .formSheet
    pickerDelegate = delegate
    presenter.present(picker, animated: true)
  }

  private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let root = base ?? activeRootViewController()
    if let navigationController = root as? UINavigationController {
      return topViewController(base: navigationController.visibleViewController)
    }
    if let tabBarController = root as? UITabBarController {
      return topViewController(base: tabBarController.selectedViewController)
    }
    if let presentedViewController = root?.presentedViewController {
      return topViewController(base: presentedViewController)
    }
    return root
  }

  private func activeRootViewController() -> UIViewController? {
    if let windowScene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    {
      if let keyWindow = windowScene.windows.first(where: \.isKeyWindow) {
        return keyWindow.rootViewController
      }
      return windowScene.windows.first?.rootViewController
    }

    return window?.rootViewController
  }
}

private final class FileSavePickerDelegate: NSObject, UIDocumentPickerDelegate {
  private weak var appDelegate: AppDelegate?
  private let exportedUrl: URL

  init(appDelegate: AppDelegate, exportedUrl: URL) {
    self.appDelegate = appDelegate
    self.exportedUrl = exportedUrl
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    cleanup()
    appDelegate?.completeSave(success: false)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    cleanup()
    appDelegate?.completeSave(success: true)
  }

  private func cleanup() {
    try? FileManager.default.removeItem(at: exportedUrl)
  }
}
