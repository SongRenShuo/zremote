import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/rewards_bridge.dart';
import '../services/webview_profile.dart';
import '../theme.dart';
import 'tactile_button.dart';

/// 福利中心内嵌页（开发计划 20261115-0901 P1-3）：
/// zcode.z.ai/cn/rewards?embedded=app 全屏 WebView + localStorage 供票注入；
/// origin 白名单外域转 url_launcher；不注入 EventObserver/RPC hook。
class RewardsPage extends StatefulWidget {
  const RewardsPage({super.key, required this.device, this.credentialsProvider});

  final RemoteDevice device;

  /// 供票（集成时接账号库）；null/空时跳过注入，由页面自展示登录态。
  final RewardsCredentialsProvider? credentialsProvider;

  @override
  State<RewardsPage> createState() => _RewardsPageState();
}

class _RewardsPageState extends State<RewardsPage> {
  RewardsCredentials _credentials = const RewardsCredentials();
  bool _preparing = true;
  bool _loading = true;
  bool _failed = false;
  Key _webKey = const Key('rewards-web');
  Uri _uri = rewardsPageUri(brightness: Brightness.dark);

  InAppWebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // 主题跟随 App themeMode（经 MaterialApp 已解析的 brightness）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _uri = rewardsPageUri(brightness: _brightness));
    });
    final provider = widget.credentialsProvider;
    if (provider != null) {
      try {
        final creds = await provider();
        if (creds != null && mounted) {
          setState(() => _credentials = creds);
        }
      } catch (_) {
        // 供票失败按无凭据处理（页面自展示登录态）。
      }
    }
    if (mounted) setState(() => _preparing = false);
  }

  Brightness get _brightness => Theme.of(context).brightness;

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
      _webKey = UniqueKey();
    });
  }

  Future<void> _openExternally() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = _controller;
    final uri = controller == null ? _uri : await controller.getUrl() ?? _uri;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        _snack(l10n.rewardsExternalFail);
      }
    } catch (_) {
      if (mounted) _snack(l10n.rewardsExternalFail);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.rewardsTitle),
        actions: [
          if (_loading && !_failed)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.rewardsRetry,
              onPressed: _failed ? _retry : () => _controller?.reload(),
            ),
          IconButton(
            key: const Key('rewards-open-external'),
            icon: const Icon(Icons.open_in_new_rounded),
            tooltip: l10n.rewardsOpenExternal,
            onPressed: _openExternally,
          ),
        ],
      ),
      body: _preparing
          ? const Center(child: CircularProgressIndicator())
          : _failed
          ? _errorView(l10n)
          : Stack(
              children: [
                InAppWebView(
                  key: _webKey,
                  initialUrlRequest: URLRequest(url: WebUri.uri(_uri)),
                  initialUserScripts: _userScripts(),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    supportZoom: false,
                    supportMultipleWindows: false,
                    androidWebProfile: webProfileNameFor(widget.device),
                  ),
                  shouldOverrideUrlLoading: _onNavigate,
                  onLoadStart: (controller, uri) {
                    if (mounted) {
                      setState(() {
                        _loading = true;
                        _failed = false;
                      });
                    }
                  },
                  onLoadStop: (controller, uri) {
                    if (mounted) setState(() => _loading = false);
                  },
                  onReceivedError: (_, request, error) {
                    if (request.isForMainFrame != true) return;
                    if (mounted) {
                      setState(() {
                        _failed = true;
                        _loading = false;
                      });
                    }
                  },
                  onRenderProcessGone: (_, detail) {
                    debugPrint('[rewards] rendererGone detail=$detail');
                    if (mounted) {
                      setState(() {
                        _failed = true;
                        _loading = false;
                      });
                    }
                  },
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    debugPrint('[rewards] webview created dev=${widget.device.id}');
                  },
                ),
              ],
            ),
    );
  }

  UnmodifiableListView<UserScript> _userScripts() {
    final source = rewardsTokenInjectionScript(_credentials);
    if (source.isEmpty) return UnmodifiableListView(const <UserScript>[]);
    return UnmodifiableListView([
      UserScript(
        source: source,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ]);
  }

  Future<NavigationActionPolicy> _onNavigate(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;
    if (isAllowedRewardsNavigation(uri)) return NavigationActionPolicy.ALLOW;
    // 外域：url_launcher 打开；打不开则拦截。
    if (shouldOpenRewardsUrlExternally(uri)) {
      try {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return NavigationActionPolicy.CANCEL;
      } catch (_) {
        // 落到拦截分支。
      }
      if (mounted) _snack(AppLocalizations.of(context)!.rewardsExternalFail);
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.CANCEL;
  }

  Widget _errorView(AppLocalizations l10n) {
    final zt = context.zt;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: zt.accentSubtle,
                border: Border.all(color: zt.accentBorder, width: 1.2),
              ),
              child: Icon(
                Icons.cloud_off_outlined,
                size: 32,
                color: zt.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.rewardsLoadFailed,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: zt.textHi,
              ),
            ),
            const SizedBox(height: 16),
            TactileButton(label: l10n.rewardsRetry, onPressed: _retry),
          ],
        ),
      ),
    );
  }
}
