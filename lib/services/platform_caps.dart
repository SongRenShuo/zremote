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
/// TODO(OH)：Flutter-OH 分叉若后续提供官方 `Platform.isOhos`，
/// 把 `_detectOhos` 收敛为单一来源，其余 API 不变。
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
