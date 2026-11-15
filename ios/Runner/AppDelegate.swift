import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications（P5-1，v22.3.3 README iOS setup 要求）：
    // 前台展示与点击/动作回调依赖 UNUserNotificationCenter delegate；插件经
    // addApplicationDelegate 注册生命周期回调，但 center.delegate 须由宿主
    // 显式指派（FlutterAppDelegate 已实现 UNUserNotificationCenterDelegate，
    // 交回 self 即可）。插件本体仍由 GeneratedPluginRegistrant 自动注册，
    // 此处不重复注册；Info.plist 无需追加注册段（v22 README 无此要求）。
    // 未验证：本机无 macOS，随版本真机回归（验收清单 S3 条款）。
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
