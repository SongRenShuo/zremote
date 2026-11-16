import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 平台能力统一判定（P1，开发计划 20261116-1434）。
///
/// 为什么需要它：stock Flutter 3.38 **没有** `Platform.isOhos`，
/// `TargetPlatform` 也**没有** `ohos` 取值——直接写会编译失败。
/// 鸿蒙（OpenHarmony / HarmonyOS NEXT）走 CPF-Flutter 的 Flutter-OH
/// SDK 分叉，其平台上报值在分叉升级期可能变化，故收敛到本文件一处判定，
/// 其余代码一律不得散写 `Platform.isAndroid` / `defaultTargetPlatform`。
///
/// 判定优先级：
/// 1. [debugOverrideOhos]（测试/工具注入，null = 跟随真实判定）；
/// 2. [Platform.operatingSystem] 含 ohos/harmony/openharmony → 鸿蒙；
/// 3. 其余平台沿用 `defaultTargetPlatform`（**尊重测试的
///    `debugDefaultTargetPlatformOverride`**）与 `Platform.isXxx`。
///
/// Flutter-OH 分叉实测（2026-11 调研，ref `oh-3.41.9-release`）：
/// - `Platform.operatingSystem` 在鸿蒙返回 `"ohos"`；`defaultTargetPlatform`
///   返回 `TargetPlatform.ohos`（枚举存在）。
/// - `Platform.isOhos` 也存在，但 CPF-Flutter FAQ **明确不建议用**（会让
///   `flutter run/build hap/attach` 在服务端引擎产物下失败），推荐
///   `defaultTargetPlatform == TargetPlatform.ohos`。
/// - 本文件用 `operatingSystem` 字符串判定：**stock Flutter 可编译**（不引用
///   分叉独有 API），且与 FAQ 的 `operatingSystem == 'ohos'` 等价。
///
/// TODO(OH)：若后续收敛为 `defaultTargetPlatform == TargetPlatform.ohos`，
/// 需先加 stock 兼容分支（如 `kIsWeb` 之外的 `TargetPlatform` 扩展），
/// 其余 API 不变。
class PlatformCaps {
  PlatformCaps._();

  /// 测试注入用；生产恒为 null。
  static bool? debugOverrideOhos;

  /// 原始操作系统名（小写），供诊断与兜底判定。
  static String get operatingSystem => Platform.operatingSystem.toLowerCase();

  static bool _detectOhos() {
    final os = operatingSystem;
    return os.contains('ohos') ||
        os.contains('harmony') ||
        os.contains('openharmony');
  }

  /// 是否鸿蒙（OpenHarmony / HarmonyOS NEXT）。
  static bool get isOhos => debugOverrideOhos ?? _detectOhos();

  /// 是否 Android（鸿蒙优先，避免 OH 分叉误报 android）。
  static bool get isAndroid =>
      !isOhos &&
      (defaultTargetPlatform == TargetPlatform.android || Platform.isAndroid);

  /// 是否 iOS。
  static bool get isIOS =>
      !isOhos &&
      (defaultTargetPlatform == TargetPlatform.iOS || Platform.isIOS);

  /// 是否手机形态平台（Android / iOS / 鸿蒙）。
  static bool get isMobile => isAndroid || isIOS || isOhos;

  /// 短名（配额链路用）：`android` / `ios` / `ohos` / `unknown`。
  static String get osName {
    if (isOhos) return 'ohos';
    if (isIOS) return 'ios';
    if (isAndroid) return 'android';
    return 'unknown';
  }

  /// 展示名（账号授权链路用）：`Android` / `iOS` / `HarmonyOS` / `Unknown`。
  static String get osDisplayName {
    if (isOhos) return 'HarmonyOS';
    if (isIOS) return 'iOS';
    if (isAndroid) return 'Android';
    return 'Unknown';
  }

  /// 平台令牌（账号授权/配额链路用）：`android-arm64` / `ios-arm64` /
  /// `ohos-arm64` / `unknown`。
  static String get platformToken {
    if (isOhos) return 'ohos-arm64';
    if (isIOS) return 'ios-arm64';
    if (isAndroid) return 'android-arm64';
    return 'unknown';
  }
}
