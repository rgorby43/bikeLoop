import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
  _ application: UIApplication,
  didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]?
  ) -> Bool {

    if let apiKey = Bundle.main.object(
      forInfoDictionaryKey: "googleApiKey"   // 👈 key name from Info.plist
    ) as? String {
      GMSServices.provideAPIKey(apiKey)
    } else {
      // Optional but nice for debugging
      assertionFailure("⚠️ Missing Google Maps API key (googleApiKey) in Info.plist")
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}