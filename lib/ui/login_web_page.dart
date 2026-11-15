import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/account_vault.dart';
import '../services/zai_auth_client.dart';
import '../services/webview_profile.dart';
import '../state/session_status.dart';
import '../theme.dart';

/// 登录页返回结果。
enum LoginWebOutcome {
  /// 授权完成、凭据已注入。
  done,

  /// 用户选择改用既有弹窗通路（宿主页 window.open 流程）。
  fallbackPopup,

  /// 用户中途关闭。
  dismissed,
}

/// 登录 WebView 的可注入网关（测试假实现替身）。
abstract class LoginWebGateway {
  Future<void> load(Uri url);

  Future<Object?> evaluate(String script);
}

/// 网关回调集：WebView 生命周期事件统一注入（测试替身可逐个触发）。
class LoginWebGatewayCallbacks {
  const LoginWebGatewayCallbacks({
    this.onLoadStart,
    this.onLoadStop,
    this.onReceivedError,
    this.onReceivedHttpError,
    this.onRenderProcessGone,
  });

  final void Function(Uri? url)? onLoadStart;

  final void Function(Uri? url)? onLoadStop;

  /// 主文档加载失败（`isForMainFrame` 为 null/false 时调用方应忽略）。
  final void Function(bool? isForMainFrame, String description)?
      onReceivedError;

  /// 主文档 HTTP 非 2xx（仅主文档计）。
  final void Function(bool? isForMainFrame, int? statusCode)?
      onReceivedHttpError;

  final void Function(bool didCrash)? onRenderProcessGone;
}

typedef LoginGatewayFactory = LoginWebGateway Function(
  LoginWebGatewayCallbacks callbacks,
);

/// 登录控制器最小接口（生产为 InAppWebView 适配器，测试为假实现）。
@visibleForTesting
abstract class LoginWebController {
  Future<void> loadUrl(Uri url);

  Future<Object?> evaluate(String script);
}

class _InAppLoginController implements LoginWebController {
  _InAppLoginController(this._controller);

  final InAppWebViewController _controller;

  @override
  Future<void> loadUrl(Uri url) => _controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(url.toString())),
      );

  @override
  Future<Object?> evaluate(String script) =>
      _controller.evaluateJavascript(source: script);
}

/// 生产网关：绑定 InAppWebView 控制器。
///
/// P1-0：`_start` 在 `setState(authorizing)` 后同步调 [load]，此时
/// WebView 尚未 build、控制器未 attach，直接 `controller?.loadUrl` 会
/// 静默空操作。此处把 URL 记入待载队列，[attach] 到位后立即补载。
class ControllerLoginGateway implements LoginWebGateway {
  LoginWebController? _controller;
  Uri? _pendingUrl;

  /// 生产路径：绑定 InAppWebView 控制器。
  void attach(InAppWebViewController controller) {
    _controller = _InAppLoginController(controller);
    _flushPending();
  }

  /// 测试注入位：绑定假控制器。
  @visibleForTesting
  void attachController(LoginWebController controller) {
    _controller = controller;
    _flushPending();
  }

  /// 释放控制器引用（重试/失败/关闭时调用，避免复用已释放的旧控制器）。
  void reset() {
    _controller = null;
    _pendingUrl = null;
  }

  void _flushPending() {
    final pending = _pendingUrl;
    if (pending == null) return;
    final controller = _controller;
    if (controller == null) return;
    _pendingUrl = null;
    unawaited(controller.loadUrl(pending));
  }

  @override
  Future<void> load(Uri url) async {
    final controller = _controller;
    if (controller == null) {
      _pendingUrl = url;
      return;
    }
    await controller.loadUrl(url);
  }

  @override
  Future<Object?> evaluate(String script) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('login webview controller not attached');
    }
    return controller.evaluate(script);
  }
}

/// P0-1 裁定主方案：WebView 内嵌官方登录页（经验总结 20261115-0930）。
///
/// 流程：provider 选择 → cli/init 拿 authorize_url → 设备 profile 的
/// WebView 加载官方登录页 → 并行 poll 轮询 → ready 后存账号库 → 加载
/// zcode.z.ai origin → 先回读保全当前登录 → 注入五键 → pop 回会话页。
class LoginWebPage extends StatefulWidget {
  const LoginWebPage({
    super.key,
    required this.device,
    this.client,
    this.vault,
    this.gatewayFactory,
  });

  final RemoteDevice device;

  /// 测试注入位；默认生产客户端。
  final ZaiAuthClient? client;

  /// 测试注入位；默认 [AccountVault.instance]。
  final AccountVault? vault;

  /// 测试注入位；默认绑定真实 WebView（生产路径）。
  final LoginGatewayFactory? gatewayFactory;

  @override
  State<LoginWebPage> createState() => _LoginWebPageState();
}

enum _LoginPhase {
  selectProvider,
  initializing,
  authorizing,
  injecting,
  failed,
}

class _LoginWebPageState extends State<LoginWebPage> {
  static const _zcodeHost = 'zcode.z.ai';

  /// `cli/init` 未回 `expires_at` 时的页面加载期限。
  static const _kLoadDeadlineFallback = Duration(seconds: 120);

  /// 停载后延迟探测空白页的时间。
  static const _kBlankProbeDelay = Duration(seconds: 5);

  /// 空白页只读探测脚本（M0-1：体内禁 `//` 与 `/*`）。
  static const _blankProbeScript =
      r'(function(){try{var b=document.body;var t=b?(b.textContent||""):"";'
      r'var lw=document.getElementById("loader-wrapper");'
      r'var rs=document.readyState;'
      r'var ok=(rs==="interactive"||rs==="complete")&&t.trim().length>0&&!lw;'
      r'return JSON.stringify({ready:rs,ok:ok})}catch(e){'
      r'return JSON.stringify({ready:"error",ok:false})}})()';

  ZaiAuthClient? _client;
  AccountVault? _vault;
  LoginWebGateway? _gateway;
  ControllerLoginGateway? _realGateway;

  _LoginPhase _phase = _LoginPhase.selectProvider;
  ZaiAuthProvider? _pendingProvider;
  Account? _readyAccount;
  String? _errorMessage;
  int _flowEpoch = 0;
  bool _injected = false;
  bool _injectRetryUsed = false;
  bool _webLoading = false;
  String _authorizeHost = '';

  Timer? _loadDeadlineTimer;
  Timer? _blankProbeTimer;
  Timer? _pollWaitTimer;
  Completer<void>? _pollWaitCompleter;

  ZaiAuthClient get client => _client ??= widget.client ?? ZaiAuthClient();
  AccountVault get vault => _vault ??= widget.vault ?? AccountVault.instance;

  @override
  void dispose() {
    _flowEpoch++;
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _loadDeadlineTimer?.cancel();
    _loadDeadlineTimer = null;
    _blankProbeTimer?.cancel();
    _blankProbeTimer = null;
    _pollWaitTimer?.cancel();
    _pollWaitTimer = null;
    final completer = _pollWaitCompleter;
    _pollWaitCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  LoginWebGateway _ensureGateway() {
    if (widget.gatewayFactory != null) {
      return _gateway ??= widget.gatewayFactory!(
        LoginWebGatewayCallbacks(
          onLoadStart: _onLoadStart,
          onLoadStop: _onLoadStop,
          onReceivedError: _onReceivedError,
          onReceivedHttpError: _onReceivedHttpError,
          onRenderProcessGone: _onRenderProcessGone,
        ),
      );
    }
    return _realGateway ??= ControllerLoginGateway();
  }

  Future<void> _start(ZaiAuthProvider provider) async {
    final epoch = ++_flowEpoch;
    _realGateway?.reset();
    setState(() {
      _phase = _LoginPhase.initializing;
      _pendingProvider = provider;
      _errorMessage = null;
      _injected = false;
      _injectRetryUsed = false;
      _webLoading = false;
      _readyAccount = null;
      _authorizeHost = '';
    });
    try {
      final flow = await client.initFlow(
        provider,
        deviceMid: null,
      );
      if (!mounted || epoch != _flowEpoch) return;
      _authorizeHost = flow.authorizeUrl.host;
      setState(() => _phase = _LoginPhase.authorizing);
      await _ensureGateway().load(flow.authorizeUrl);
      if (!mounted || epoch != _flowEpoch) return;
      _armLoadDeadline(flow, epoch);
      unawaited(_pollLoop(flow, provider, epoch));
    } on ZaiAuthException catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(e);
    } catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(ZaiAuthException(ZaiAuthErrorKind.network, message: '$e'));
    }
  }

  Future<void> _pollLoop(
    AuthFlowInit flow,
    ZaiAuthProvider provider,
    int epoch,
  ) async {
    final deadline = DateTime.now().add(ZaiAuthClient.pollTotalTimeout);
    while (mounted && epoch == _flowEpoch) {
      await _delayCancellable(
        Duration(seconds: flow.pollIntervalSec.clamp(1, 60)),
      );
      if (!mounted || epoch != _flowEpoch) return;
      if (DateTime.now().isAfter(deadline)) {
        _fail(const ZaiAuthException(
          ZaiAuthErrorKind.timeout,
          message: 'poll deadline exceeded',
        ));
        return;
      }
      try {
        final result = await client.pollOnce(flow);
        if (!mounted || epoch != _flowEpoch) return;
        if (result.status == AuthFlowStatus.ready) {
          await _onReady(provider, result, epoch);
          return;
        }
        if (result.status == AuthFlowStatus.failed) {
          _fail(const ZaiAuthException(
            ZaiAuthErrorKind.api,
            message: 'authorization denied',
          ));
          return;
        }
      } on ZaiAuthException catch (e) {
        if (!mounted || epoch != _flowEpoch) return;
        _fail(e);
        return;
      }
    }
  }

  /// 可取消的等待：失败/关闭时中断轮询，避免悬挂 timer。
  Future<void> _delayCancellable(Duration duration) {
    final completer = Completer<void>();
    _pollWaitCompleter = completer;
    _pollWaitTimer = Timer(duration, () {
      _pollWaitTimer = null;
      _pollWaitCompleter = null;
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  Future<void> _onReady(
    ZaiAuthProvider provider,
    AuthPollResult result,
    int epoch,
  ) async {
    _loadDeadlineTimer?.cancel();
    _loadDeadlineTimer = null;
    setState(() => _phase = _LoginPhase.injecting);
    final credentials = <String, String>{
      'zcodejwttoken': result.token ?? '',
      'oauth:active_provider': provider.wireName,
      if (result.providerAccessToken != null)
        'oauth:${provider.wireName}:access_token': result.providerAccessToken!,
      if (result.providerRefreshToken != null)
        'oauth:${provider.wireName}:refresh_token': result.providerRefreshToken!,
      if (result.user.isNotEmpty)
        'oauth:${provider.wireName}:user_info': jsonEncode(result.user),
    };
    final name = _nameOf(result);
    try {
      final account = await vault.upsertFromCredentials(
        provider: provider.wireName,
        credentials: credentials,
        name: name,
      );
      if (!mounted || epoch != _flowEpoch) return;
      _readyAccount = account;
      await vault.setActiveForDevice(widget.device.id, account.id);
      await _ensureGateway().load(_zcodeSessionUri());
      // 注入在 onLoadStop（目标 origin 就绪）后执行。
    } on ZaiAuthException catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(e);
    } catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(ZaiAuthException(ZaiAuthErrorKind.network, message: '$e'));
    }
  }

  Uri _zcodeSessionUri() {
    final base = Uri.tryParse(widget.device.baseUrl);
    if (base != null && base.host == _zcodeHost) return base;
    return Uri.https(_zcodeHost, '/remote/v4');
  }

  /// 注入目标 origin 集合：设备 baseUrl origin ∪ zcode.z.ai。
  Set<String> _targetOrigins() {
    final origins = <String>{'https://$_zcodeHost'};
    final base = Uri.tryParse(widget.device.baseUrl);
    final origin = base == null ? null : _originOf(base);
    if (origin != null && origin.isNotEmpty) origins.add(origin);
    return origins;
  }

  String? _originOf(Uri url) {
    if (!url.hasScheme || url.host.isEmpty) return null;
    try {
      return url.origin;
    } catch (_) {
      return null;
    }
  }

  String _nameOf(AuthPollResult result) {
    final email = result.user['email'];
    if (email is String && email.isNotEmpty) return email;
    final name = result.user['name'];
    if (name is String && name.isNotEmpty) return name;
    return _pendingProvider?.wireName ?? '';
  }

  void _onLoadStart(Uri? url) {
    if (!mounted) return;
    // 新导航开始，上一轮停载探测结果失效。
    _blankProbeTimer?.cancel();
    _blankProbeTimer = null;
    setState(() => _webLoading = true);
  }

  Future<void> _onLoadStop(Uri? url) async {
    if (!mounted) return;
    setState(() => _webLoading = false);
    if (_injected || url == null) return;

    if (_phase == _LoginPhase.injecting) {
      final origin = _originOf(url);
      if (origin == null || !_targetOrigins().contains(origin)) {
        // 非预期 host：白名单语义不全开，仅允许重试注入一次。
        if (_injectRetryUsed) return;
        _injectRetryUsed = true;
        await _ensureGateway().load(_zcodeSessionUri());
        return;
      }
      await _injectCredentials();
      return;
    }

    if (_phase == _LoginPhase.authorizing &&
        _authorizeHost.isNotEmpty &&
        url.host == _authorizeHost) {
      _scheduleBlankProbe();
    }
  }

  Future<void> _injectCredentials() async {
    if (_injected || !mounted) return;
    _injected = true;
    final epoch = _flowEpoch;
    try {
      // 防丢号：注入前先回读保全当前登录。
      final raw = await _ensureGateway().evaluate(
        AccountVault.credentialReadScript(),
      );
      final entries = AccountVault.parseReadResult(
        raw is String ? raw : null,
      );
      await vault.preserveRawEntries(entries);
      final account = _readyAccount;
      if (account == null) {
        _fail(const ZaiAuthException(
          ZaiAuthErrorKind.badResponse,
          message: 'account missing after save',
        ));
        return;
      }
      final script = AccountVault.credentialInjectScript(account);
      if (script.isNotEmpty) {
        await _ensureGateway().evaluate(script);
      }
      if (!mounted || epoch != _flowEpoch) return;
      _cancelTimers();
      Navigator.of(context).pop(LoginWebOutcome.done);
    } catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(ZaiAuthException(ZaiAuthErrorKind.network, message: '$e'));
    }
  }

  void _onReceivedError(bool? isForMainFrame, String description) {
    if (!mounted) return;
    if (!PageLoadPolicy.isMainDocFailure(isForMainFrame)) return;
    final reason = description.trim().isEmpty
        ? 'load error'
        : description.trim();
    _fail(
      ZaiAuthException(ZaiAuthErrorKind.network, message: reason),
      message: AppLocalizations.of(context)!.loginErrorPageLoad(reason),
    );
  }

  void _onReceivedHttpError(bool? isForMainFrame, int? statusCode) {
    if (!mounted) return;
    if (!PageLoadPolicy.isHttpFailure(isForMainFrame, statusCode)) return;
    final reason = 'HTTP $statusCode';
    _fail(
      ZaiAuthException(ZaiAuthErrorKind.http, message: reason),
      message: AppLocalizations.of(context)!.loginErrorPageLoad(reason),
    );
  }

  void _onRenderProcessGone(bool didCrash) {
    if (!mounted) return;
    _fail(
      ZaiAuthException(
        ZaiAuthErrorKind.network,
        message: didCrash ? 'render process crashed' : 'render process gone',
      ),
      message: AppLocalizations.of(context)!.loginErrorRenderGone,
    );
  }

  /// 页面加载期限：`expires_at` 优先，缺失取 120s；到点仍 authorizing 判失败。
  void _armLoadDeadline(AuthFlowInit flow, int epoch) {
    _loadDeadlineTimer?.cancel();
    final now = DateTime.now();
    final expiresMs = flow.expiresAtMs;
    final deadline = expiresMs != null
        ? DateTime.fromMillisecondsSinceEpoch(expiresMs)
        : now.add(_kLoadDeadlineFallback);
    _loadDeadlineTimer = Timer(deadline.difference(now), () {
      if (!mounted || epoch != _flowEpoch) return;
      if (_phase != _LoginPhase.authorizing) return;
      _fail(
        const ZaiAuthException(
          ZaiAuthErrorKind.timeout,
          message: 'page load deadline exceeded',
        ),
        message: AppLocalizations.of(context)!.loginErrorTimeoutPopup,
      );
    });
  }

  void _scheduleBlankProbe() {
    _blankProbeTimer?.cancel();
    final epoch = _flowEpoch;
    _blankProbeTimer = Timer(_kBlankProbeDelay, () {
      unawaited(_runBlankProbe(epoch));
    });
  }

  Future<void> _runBlankProbe(int epoch) async {
    if (!mounted || epoch != _flowEpoch) return;
    if (_phase != _LoginPhase.authorizing) return;
    Object? raw;
    try {
      raw = await _ensureGateway().evaluate(_blankProbeScript);
    } catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(
        const ZaiAuthException(
          ZaiAuthErrorKind.badResponse,
          message: 'blank probe failed',
        ),
        message: AppLocalizations.of(context)!.loginErrorBlankPage,
      );
      return;
    }
    if (!mounted || epoch != _flowEpoch) return;
    if (_phase != _LoginPhase.authorizing) return;
    if (_parseBlankProbe(raw)) {
      _fail(
        const ZaiAuthException(
          ZaiAuthErrorKind.badResponse,
          message: 'blank page after load',
        ),
        message: AppLocalizations.of(context)!.loginErrorBlankPage,
      );
    }
  }

  /// 探测结果解析：`ok != true`（含不可解析）一律视为空白。
  bool _parseBlankProbe(Object? raw) {
    if (raw is! String) return true;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final ok = decoded['ok'];
        if (ok is bool) return !ok;
      }
    } catch (_) {}
    return true;
  }

  void _fail(ZaiAuthException e, {String? message}) {
    if (!mounted) return;
    _flowEpoch++;
    _cancelTimers();
    setState(() {
      _phase = _LoginPhase.failed;
      _errorMessage = message ?? _messageOf(e);
    });
  }

  String _messageOf(ZaiAuthException e) {
    final l10n = AppLocalizations.of(context)!;
    return switch (e.kind) {
      ZaiAuthErrorKind.network => l10n.loginErrorNetwork,
      ZaiAuthErrorKind.timeout => l10n.loginErrorTimeout,
      ZaiAuthErrorKind.http => l10n.loginErrorRejected,
      ZaiAuthErrorKind.api => l10n.loginErrorRejected,
      ZaiAuthErrorKind.badResponse => l10n.loginErrorBadResponse,
    };
  }

  void _fallbackPopup() {
    if (!mounted) return;
    _flowEpoch++;
    _cancelTimers();
    Navigator.of(context).pop(LoginWebOutcome.fallbackPopup);
  }

  Future<void> _confirmAbandon() async {
    final l10n = AppLocalizations.of(context)!;
    final abandon = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.loginCloseConfirmTitle),
        content: Text(l10n.loginCloseConfirmBody),
        actions: [
          TextButton(
            key: const Key('login-abandon-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('login-abandon-ok'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.loginAbandonConfirm),
          ),
        ],
      ),
    );
    if (abandon == true && mounted) {
      _flowEpoch++;
      _cancelTimers();
      Navigator.of(context).pop(LoginWebOutcome.dismissed);
    }
  }

  void _close() {
    _flowEpoch++;
    _cancelTimers();
    Navigator.of(context).pop(LoginWebOutcome.dismissed);
  }

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final canPop = _phase == _LoginPhase.selectProvider ||
        _phase == _LoginPhase.failed;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmAbandon());
      },
      child: Scaffold(
        backgroundColor: zt.bg,
        appBar: AppBar(
          leading: IconButton(
            key: const Key('login-close'),
            icon: const Icon(Icons.close_rounded),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: canPop
                ? _close
                : () => unawaited(_confirmAbandon()),
          ),
          title: Text(
            l10n.loginTitle,
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
          child: switch (_phase) {
            _LoginPhase.selectProvider => _buildProviderSelect(context),
            _LoginPhase.initializing => _buildStatus(
              context,
              l10n.loginStatusInit,
            ),
            _LoginPhase.authorizing ||
            _LoginPhase.injecting => _buildAuthorizeArea(context),
            _LoginPhase.failed => _buildFailed(context),
          },
        ),
      ),
    );
  }

  Widget _buildProviderSelect(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.loginSubtitle,
            style: TextStyle(fontSize: 13, color: zt.textLo),
          ),
          const SizedBox(height: 18),
          for (final (i, provider) in ZaiAuthProvider.values.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            _ProviderTile(
              provider: provider,
              onTap: () => unawaited(_start(provider)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus(BuildContext context, String text) {
    final zt = context.zt;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 14),
          Text(text, style: TextStyle(fontSize: 13, color: zt.textLo)),
        ],
      ),
    );
  }

  Widget _buildAuthorizeArea(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final status = switch (_phase) {
      _LoginPhase.injecting => l10n.loginStatusSaving,
      _LoginPhase.authorizing when _webLoading => l10n.loginStatusLoading,
      _ => l10n.loginStatusAuthorize,
    };
    _ensureGateway();
    final Widget webview = widget.gatewayFactory != null
        ? const SizedBox.expand(key: Key('login-webview-placeholder'))
        : InAppWebView(
            key: const Key('login-webview'),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              transparentBackground: false,
              useHybridComposition: false,
              androidWebProfile: webProfileNameFor(widget.device),
            ),
            onWebViewCreated: (controller) {
              _ensureGateway();
              _realGateway?.attach(controller);
            },
            onLoadStart: (_, url) => _onLoadStart(url),
            onLoadStop: (_, url) => unawaited(_onLoadStop(url)),
            onReceivedError: (_, request, error) =>
                _onReceivedError(request.isForMainFrame, error.description),
            onReceivedHttpError: (_, request, response) =>
                _onReceivedHttpError(
                  request.isForMainFrame,
                  response.statusCode,
                ),
            onRenderProcessGone: (_, detail) =>
                _onRenderProcessGone(detail.didCrash),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            color: zt.accentSubtle,
            border: Border(left: BorderSide(color: zt.accent, width: 3)),
          ),
          child: Row(
            children: [
              if (_webLoading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 14,
                  color: zt.textLo,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  key: const Key('login-status'),
                  style: TextStyle(fontSize: 12.5, color: zt.textHi),
                ),
              ),
              TextButton(
                key: const Key('login-fallback-popup-loading'),
                onPressed: _fallbackPopup,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  l10n.loginUsePopup,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: webview),
      ],
    );
  }

  Widget _buildFailed(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.error_outline_rounded, size: 40, color: zt.danger),
          const SizedBox(height: 14),
          Text(
            l10n.loginErrorTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: zt.textHi,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage ?? '',
            key: const Key('login-error-message'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: zt.textLo),
          ),
          const SizedBox(height: 22),
          FilledButton(
            key: const Key('login-retry'),
            onPressed: () {
              final p = _pendingProvider;
              if (p != null) unawaited(_start(p));
            },
            child: Text(l10n.loginRetry),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('login-fallback-popup'),
            onPressed: _fallbackPopup,
            child: Text(l10n.loginUsePopup),
          ),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.provider, required this.onTap});

  final ZaiAuthProvider provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final (label, icon) = switch (provider) {
      ZaiAuthProvider.zaiCn => (l10n.loginProviderZaiCn, Icons.public_rounded),
      ZaiAuthProvider.zai => (l10n.loginProviderZai, Icons.language_rounded),
      ZaiAuthProvider.bigmodel => (
        l10n.loginProviderBigmodel,
        Icons.business_rounded,
      ),
      _ => (provider.wireName, Icons.help_outline_rounded),
    };
    return Material(
      color: zt.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('login-provider-${provider.wireName}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: zt.hairline),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: zt.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: zt.textHi,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: zt.textLo),
            ],
          ),
        ),
      ),
    );
  }
}
