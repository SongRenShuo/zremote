import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await WebViewFeature.isFeatureSupported(
        WebViewFeature.MULTI_PROFILE);
  } catch (e) {
    debugPrint('[zr-profile] MULTI_PROFILE probe failed: $e');
    return false;
  }
});

/// P3-7 WebView UA 覆写（实验位）：设置页开关，session_view 构造
/// InAppWebViewSettings 时读取应用。默认关（不覆写，跟随系统 WebView）。
const String _kUaDesktopKey = 'zremote.webview.uaDesktop';

/// 覆写用的桌面 Chrome UA（Windows 固定串，实验用）。
const String kDesktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 开关开 → 返回覆写 UA；关 → null（跟随默认）。
String? desktopUaFor(bool enabled) => enabled ? kDesktopUa : null;

class UaDesktopNotifier extends Notifier<bool> {
  UaDesktopNotifier({bool? initial}) : _initial = initial;

  final bool? _initial;

  @override
  bool build() {
    final initial = _initial;
    if (initial != null) return initial;
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kUaDesktopKey) ?? false;
  }

  Future<void> set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUaDesktopKey, value);
    state = value;
  }
}

final uaDesktopProvider = NotifierProvider<UaDesktopNotifier, bool>(
  UaDesktopNotifier.new,
);
