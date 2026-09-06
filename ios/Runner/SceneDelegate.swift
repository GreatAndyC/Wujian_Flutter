import Flutter
import UIKit

final class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard
      let windowScene = scene as? UIWindowScene,
      let appDelegate = UIApplication.shared.delegate as? AppDelegate
    else {
      return
    }

    window = UIWindow(windowScene: windowScene)

    // Start the explicit engine from the scene lifecycle so iOS 26 does not
    // create a FlutterViewController before the engine has a shell.
    guard appDelegate.flutterEngine.run() else {
      return
    }

    GeneratedPluginRegistrant.register(with: appDelegate.flutterEngine)
    appDelegate.configureFlutterEngine()

    let flutterViewController = FlutterViewController(
      engine: appDelegate.flutterEngine,
      nibName: nil,
      bundle: nil
    )
    window?.rootViewController = flutterViewController
    window?.makeKeyAndVisible()

    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
