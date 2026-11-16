import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/platform_caps.dart';

void main() {
  group('PlatformCaps（P1 平台能力抽象）', () {
    tearDown(() => PlatformCaps.debugOverrideOhos = null);

    test('未知/桌面宿主：非手机形态，令牌与短名如实', () {
      PlatformCaps.debugOverrideOhos = false;
      // 测试宿主是 Windows：android/iOS 均不成立（defaultTargetPlatform 可能被
      // 测试框架置为 android，故这里只断言 ohos 相关与一致性）。
      expect(PlatformCaps.isOhos, isFalse);
      expect(PlatformCaps.osName, isNot('ohos'));
      expect(PlatformCaps.platformToken, isNot('ohos-arm64'));
      expect(PlatformCaps.osDisplayName, isNot('HarmonyOS'));
    });

    test('注入 ohos：判定优先，android/iOS 让位', () {
      PlatformCaps.debugOverrideOhos = true;
      expect(PlatformCaps.isOhos, isTrue);
      expect(PlatformCaps.isAndroid, isFalse);
      expect(PlatformCaps.isIOS, isFalse);
      expect(PlatformCaps.isMobile, isTrue);
      expect(PlatformCaps.osName, 'ohos');
      expect(PlatformCaps.osDisplayName, 'HarmonyOS');
      expect(PlatformCaps.platformToken, 'ohos-arm64');
    });

    test('注入 ohos 时 operatingSystem 读数不受影响（仅判定被覆盖）', () {
      final before = PlatformCaps.operatingSystem;
      PlatformCaps.debugOverrideOhos = true;
      expect(PlatformCaps.operatingSystem, before);
      expect(Platform.operatingSystem.toLowerCase(), before);
    });

    test('真实探测：宿主 operatingSystem 不含 ohos/harmony → 非鸿蒙', () {
      // 直接验证探测逻辑本身（不依赖注入），避免 stock Flutter 无 isOhos 的坑。
      final os = Platform.operatingSystem.toLowerCase();
      final detected = os.contains('ohos') ||
          os.contains('harmony') ||
          os.contains('openharmony');
      expect(PlatformCaps.debugOverrideOhos ?? detected, PlatformCaps.isOhos);
      // 本测试在 Windows/macOS/Linux 宿主跑，必然非鸿蒙。
      expect(detected, isFalse);
    });

    test('iOS 覆盖：尊重 defaultTargetPlatform（测试框架注入）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      PlatformCaps.debugOverrideOhos = false;
      expect(PlatformCaps.isIOS, isTrue);
      expect(PlatformCaps.isAndroid, isFalse);
      expect(PlatformCaps.osName, 'ios');
      expect(PlatformCaps.platformToken, 'ios-arm64');
    });

    test('Android 覆盖：尊重 defaultTargetPlatform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      PlatformCaps.debugOverrideOhos = false;
      expect(PlatformCaps.isAndroid, isTrue);
      expect(PlatformCaps.isIOS, isFalse);
      expect(PlatformCaps.osName, 'android');
      expect(PlatformCaps.platformToken, 'android-arm64');
    });
  });
}
