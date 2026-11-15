import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';

const String _kProfilePrefix = 'zr_';

final RegExp _kInvalidProfileChars = RegExp(r'[^A-Za-z0-9_-]');

String? webProfileNameFor(RemoteDevice device) {
  if (device.kind != DeviceKind.v2) return null;
  final sanitized =
      device.id.replaceAll(_kInvalidProfileChars, '_');
  if (sanitized.isEmpty) return null;
  return '$_kProfilePrefix$sanitized';
}

bool shouldShowIsolationFallback({
  required DeviceKind kind,
  required bool multiProfileSupported,
}) =>
    kind == DeviceKind.v2 && !multiProfileSupported;

final multiProfileSupportedProvider = FutureProvider<bool>((ref) async {
  // P5-2 iOS 分支：返回 true 的真实语义是「会话页隔离降级横幅抑制」，
  // 并非 iOS 实际支持 MULTI_PROFILE——iOS 系统 WebView 无该概念，
  // 多账号共用登录态的事实陈述移入设置页「iOS 平台限制说明」卡
  // （ui/ios_limits_section.dart），避免会话页在 iOS 恒显 Android 语义
  // 的「本机 WebView 不支持」警示（原实现非 Android 恒 false 导致恒显）。
  if (defaultTargetPlatform == TargetPlatform.iOS) return true;
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await WebViewFeature.isFeatureSupported(
        WebViewFeature.MULTI_PROFILE);
  } catch (e) {
    debugPrint('[zr-profile] MULTI_PROFILE probe failed: $e');
    return false;
  }
});
