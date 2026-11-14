import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/auth_popup_policy.dart';
import '../services/webview_profile.dart';
import '../theme.dart';

/// 登录授权弹窗页：承载页面 `window.open` 创建的 OAuth 窗口。
///
/// 带 `windowId` 创建时插件会消费 WebViewTransport，使 opener 拿到真实
/// window 句柄（页面随后把弹窗导航到 chat.z.ai 授权页）；登录完成靠主页
/// 面轮询感知，本页只负责渲染与关闭。
class AuthPopupPage extends StatefulWidget {
  const AuthPopupPage({
    super.key,
    required this.device,
    required this.windowId,
    this.initialRequest,
  });

  final RemoteDevice device;
  final int? windowId;
  final URLRequest? initialRequest;

  @override
  State<AuthPopupPage> createState() => _AuthPopupPageState();
}

class _AuthPopupPageState extends State<AuthPopupPage> {
  static const _autoCloseDelay = Duration(milliseconds: 800);

  String get _mainOrigin => AuthPopupPolicy.mainOriginOf(widget.device);

  Timer? _autoClose;
  bool _closed = false;

  @override
  void dispose() {
    _autoClose?.cancel();
    super.dispose();
  }

  void _close() {
    if (!mounted || _closed) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  void _scheduleAutoClose() {
    if (_closed) return;
    _autoClose?.cancel();
    _autoClose = Timer(_autoCloseDelay, _close);
  }

  void _onPopupNavigation(Uri? url) {
    if (AuthPopupPolicy.shouldAutoClose(url, _mainOrigin)) {
      _scheduleAutoClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: _close,
        ),
        title: Text(
          l10n.authPopupTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: zt.textHi,
          ),
        ),
        centerTitle: false,
        backgroundColor: zt.bg,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: zt.hairline),
        ),
      ),
      body: SafeArea(
        top: false,
        child: InAppWebView(
          windowId: widget.windowId,
          initialUrlRequest: widget.initialRequest,
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            transparentBackground: false,
            useHybridComposition: false,
            androidWebProfile: webProfileNameFor(widget.device),
          ),
          onCloseWindow: (_) => _close(),
          onLoadStart: (_, url) => _onPopupNavigation(url),
          onUpdateVisitedHistory: (_, url, _) => _onPopupNavigation(url),
        ),
      ),
    );
  }
}
