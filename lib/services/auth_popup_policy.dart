import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/device.dart';

/// V4/V2 远控页面登录使用 `window.open` 弹窗完成 OAuth（授权页在
/// chat.z.ai，主页面轮询票据）。本策略决定弹窗 WebView 的初始加载
/// 与自动关闭时机，纯函数以便单测。
class AuthPopupPolicy {
  /// 弹窗内 `window.open('about:blank')` 场景下 request.url 为空白页：
  /// 返回 null，让弹窗 WebView 依靠 windowId 接管，URL 由 opener 自行
  /// 导航。真实 URL 弹窗（target=_blank）返回对应请求。
  static URLRequest? initialRequestFor(CreateWindowAction action) {
    final url = action.request.url;
    if (url == null) return null;
    return validRequestFor(url.toString());
  }

  static URLRequest? validRequestFor(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'about:blank') return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return URLRequest(url: WebUri(trimmed));
  }

  /// 主页面 origin（用于弹窗自动关闭启发式）。
  static String mainOriginOf(RemoteDevice device) {
    final uri = Uri.tryParse(device.baseUrl);
    if (uri == null || uri.host.isEmpty) return '';
    final buffer = StringBuffer('${uri.scheme}://${uri.host}');
    if (uri.hasPort) buffer.write(':${uri.port}');
    return buffer.toString();
  }

  /// 弹窗导航回主应用 origin（登录完成后的回跳）→ 可自动关闭。
  static bool shouldAutoClose(Uri? popupUrl, String mainOrigin) {
    if (popupUrl == null || mainOrigin.isEmpty) return false;
    final main = Uri.tryParse(mainOrigin);
    if (main == null || main.host.isEmpty) return false;
    return popupUrl.scheme == main.scheme &&
        popupUrl.host == main.host &&
        popupUrl.port == (main.hasPort ? main.port : _defaultPort(main.scheme));
  }

  static int _defaultPort(String scheme) => scheme == 'https' ? 443 : 80;
}
