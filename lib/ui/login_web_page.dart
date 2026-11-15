import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/account_vault.dart';
import '../services/zai_auth_client.dart';
import '../services/webview_profile.dart';
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

typedef LoginGatewayFactory = LoginWebGateway Function(
  void Function(Uri? url) onLoadStop,
);

/// 生产网关：绑定 InAppWebView controller。
class _ControllerGateway implements LoginWebGateway {
  InAppWebViewController? _controller;

  void attach(InAppWebViewController controller) => _controller = controller;

  @override
  Future<void> load(Uri url) async {
    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
  }

  @override
  Future<Object?> evaluate(String script) async {
    return _controller?.evaluateJavascript(source: script);
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

  ZaiAuthClient? _client;
  AccountVault? _vault;
  LoginWebGateway? _gateway;
  _ControllerGateway? _realGateway;

  _LoginPhase _phase = _LoginPhase.selectProvider;
  ZaiAuthProvider? _pendingProvider;
  Account? _readyAccount;
  String? _errorMessage;
  int _flowEpoch = 0;
  bool _injected = false;

  ZaiAuthClient get client => _client ??= widget.client ?? ZaiAuthClient();
  AccountVault get vault => _vault ??= widget.vault ?? AccountVault.instance;

  @override
  void dispose() {
    _flowEpoch++;
    super.dispose();
  }

  LoginWebGateway _ensureGateway() {
    if (widget.gatewayFactory != null) {
      return _gateway ??= widget.gatewayFactory!(_onLoadStop);
    }
    return _realGateway ??= _ControllerGateway();
  }

  Future<void> _start(ZaiAuthProvider provider) async {
    final epoch = ++_flowEpoch;
    setState(() {
      _phase = _LoginPhase.initializing;
      _pendingProvider = provider;
      _errorMessage = null;
      _injected = false;
      _readyAccount = null;
    });
    try {
      final flow = await client.initFlow(
        provider,
        deviceMid: null,
      );
      if (!mounted || epoch != _flowEpoch) return;
      setState(() => _phase = _LoginPhase.authorizing);
      await _ensureGateway().load(flow.authorizeUrl);
      if (!mounted || epoch != _flowEpoch) return;
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
      await Future<void>.delayed(
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

  Future<void> _onReady(
    ZaiAuthProvider provider,
    AuthPollResult result,
    int epoch,
  ) async {
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
      // 注入在 onLoadStop（zcode.z.ai origin 就绪）后执行。
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

  String _nameOf(AuthPollResult result) {
    final email = result.user['email'];
    if (email is String && email.isNotEmpty) return email;
    final name = result.user['name'];
    if (name is String && name.isNotEmpty) return name;
    return _pendingProvider?.wireName ?? '';
  }

  Future<void> _onLoadStop(Uri? url) async {
    if (!mounted || _injected) return;
    if (_phase != _LoginPhase.injecting || url == null) return;
    if (url.host != _zcodeHost) return;
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
      Navigator.of(context).pop(LoginWebOutcome.done);
    } catch (e) {
      if (!mounted || epoch != _flowEpoch) return;
      _fail(ZaiAuthException(ZaiAuthErrorKind.network, message: '$e'));
    }
  }

  void _fail(ZaiAuthException e) {
    if (!mounted) return;
    setState(() {
      _phase = _LoginPhase.failed;
      _errorMessage = _messageOf(e);
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
      Navigator.of(context).pop(LoginWebOutcome.dismissed);
    }
  }

  void _close() {
    _flowEpoch++;
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
    final status = _phase == _LoginPhase.injecting
        ? l10n.loginStatusSaving
        : l10n.loginStatusAuthorize;
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
            onLoadStop: (_, url) => unawaited(_onLoadStop(url)),
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
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  key: const Key('login-status'),
                  style: TextStyle(fontSize: 12.5, color: zt.textHi),
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
            onPressed: () {
              _flowEpoch++;
              Navigator.of(context).pop(LoginWebOutcome.fallbackPopup);
            },
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
