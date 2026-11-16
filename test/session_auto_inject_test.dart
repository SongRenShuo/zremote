import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/state/accounts.dart';
import 'package:zremote/state/claim_entry.dart';
import 'package:zremote/state/claim_scheduler_hub.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/state/session_status.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/session_view.dart';

/// 会话页「绑定账号自动注入」回归用例（问题二十）。
///
/// 用假 [InAppWebViewPlatform] 顶替真实 WebView：记录 evaluateJavascript
/// 与 loadUrl，并可由用例主动触发 onLoadStop，从而验证
/// SessionView 的「加载后自检 → 注入 → 重载一次」链路与防循环守卫。

/// 假 WebView 状态与调用记录。
class _Sim {
  final Map<String, String> storage = {};
  final List<String> scripts = [];
  int loadUrlCount = 0;
  bool throwOnEvaluate = false;
  InAppWebViewController? controller;
  PlatformInAppWebViewWidgetCreationParams? params;

  int countOf(String script) => scripts.where((s) => s == script).length;
}

late _Sim _sim;

class _FakeController extends PlatformInAppWebViewController {
  _FakeController(super.params) : super.implementation();

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    _sim.scripts.add(source);
    if (_sim.throwOnEvaluate) throw Exception('evaluate failed');
    if (source == AccountVault.credentialReadScript()) {
      return jsonEncode({
        for (final k in AccountVault.readableKeys)
          if (_sim.storage[k] != null) k: _sim.storage[k],
      });
    }
    for (final m in RegExp(r'setItem\("([^"]*)","((?:\\.|[^"\\])*)"\)')
        .allMatches(source)) {
      _sim.storage[m.group(1)!] = jsonDecode('"${m.group(2)}"') as String;
    }
    for (final m in RegExp(r'removeItem\("([^"]*)"\)').allMatches(source)) {
      _sim.storage.remove(m.group(1));
    }
    return null;
  }

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    _sim.loadUrlCount++;
  }

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {}

  @override
  Future<void> removeAllUserScripts() async {}

  @override
  Future<void> addUserScripts({required List<UserScript> userScripts}) async {}

  @override
  Future<void> setWebContentsDebuggingEnabled(bool debuggingEnabled) async {}

  @override
  void dispose({bool isKeepAlive = false}) {}
}

class _FakeWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final convert = params.controllerFromPlatform;
      if (convert == null) return;
      final controller = convert(
        _FakeController(
          const PlatformInAppWebViewControllerCreationParams(id: 'fake'),
        ),
      );
      _sim.controller = controller as InAppWebViewController;
      _sim.params = params;
      params.onWebViewCreated?.call(controller);
    });
    return const SizedBox.expand();
  }

  @override
  void dispose() {}
}

class _FakePlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) => _FakeController(params);

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      _FakeController(
        const PlatformInAppWebViewControllerCreationParams(id: 'static'),
      );
}

class _FakeDeviceListNotifier extends DeviceListNotifier {
  _FakeDeviceListNotifier(this.initial);
  final List<RemoteDevice> initial;

  @override
  List<RemoteDevice> build() => initial;
}

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this.initial);
  final AccountsState initial;

  @override
  AccountsState build() => initial;
}

// dispose 在 Flutter 3.38 的 unmount 里已 defunct：真实 notifier 的 forget /
// detach 会写状态并通知到该元素而抛断言。这里仅把「卸载清理」静音，
// 不改变被测的自动注入行为。
class _FakeSessionStatusNotifier extends SessionStatusNotifier {
  @override
  void forget(String deviceId) {}
}

class _FakeClaimServiceNotifier extends ClaimServiceNotifier {
  @override
  void forget(String deviceId) {}
}

class _FakeClaimSchedulerHub extends ClaimSchedulerHub {
  @override
  void detach(String deviceId) {}
}

final _device = RemoteDevice(
  id: 'dev-auto',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {'sid': 'sid-auto'},
  label: '',
  createdAt: DateTime(2026),
  kind: DeviceKind.legacy,
);

final _account = Account(
  id: 'acc-1',
  name: '账号一',
  provider: 'zai',
  credentials: const {
    'zcodejwttoken': 'jwt-1',
    'oauth:active_provider': 'zai',
    'oauth:zai:access_token': 'at-1',
  },
  hash: 'hash-1',
  virtualDeviceMid: 'mid-1',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// 设备已绑定账号的账号库状态。
AccountsState _boundState() => AccountsState(
      accounts: [_account],
      activeByDevice: {_device.id: _account.id},
      loaded: true,
    );

Future<void> _pump(WidgetTester tester, AccountsState state) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = const Size(500, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceListProvider.overrideWith(() => _FakeDeviceListNotifier([_device])),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier(state)),
        sessionStatusProvider.overrideWith(_FakeSessionStatusNotifier.new),
        claimServiceProvider.overrideWith(_FakeClaimServiceNotifier.new),
        claimSchedulerHubProvider.overrideWith(_FakeClaimSchedulerHub.new),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ZT.theme(Brightness.dark),
        home: SessionView(device: _device),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
  expect(_sim.controller, isNotNull, reason: '假 WebView 控制器应已就绪');
}

/// 主动触发一次页面加载完成（等价 onLoadStop 回调）。
Future<void> _loadStop(WidgetTester tester) async {
  final params = _sim.params;
  final controller = _sim.controller;
  expect(params, isNotNull);
  expect(controller, isNotNull);
  params!.onLoadStop?.call(controller, null);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

/// 清理：先推进假时钟消化领券探针超时，再卸载树并让回环服务器关闭，
/// 避免测试结束时残留 Timer。
Future<void> _teardown(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    _sim = _Sim();
    InAppWebViewPlatform.instance = _FakePlatform();
  });

  testWidgets('绑定账号 + localStorage 空 → 注入一次并 reload，再加载不重复注入', (
    tester,
  ) async {
    await _pump(tester, _boundState());
    final readScript = AccountVault.credentialReadScript();
    final injectScript = AccountVault.credentialInjectScript(_account);
    final loadsBefore = _sim.loadUrlCount;

    await _loadStop(tester);

    expect(_sim.countOf(readScript), 1, reason: '应回读一次凭据仓');
    expect(_sim.countOf(injectScript), 1, reason: '缺票应注入绑定账号凭据');
    expect(_sim.loadUrlCount, loadsBefore + 1, reason: '注入后应重载一次');
    expect(_sim.storage['zcodejwttoken'], 'jwt-1', reason: '注入脚本应写入票');

    // 模拟重载完成：防循环守卫应让第二次自检直接跳过（不再回读/注入）。
    await _loadStop(tester);
    expect(_sim.countOf(readScript), 1, reason: '一次性标志应跳过回读');
    expect(_sim.countOf(injectScript), 1, reason: '不得重复注入');
    expect(_sim.loadUrlCount, loadsBefore + 1, reason: '不得再次重载');

    await _teardown(tester);
  });

  testWidgets('localStorage 已有 zcodejwttoken → 不注入不重载', (tester) async {
    await _pump(tester, _boundState());
    _sim.storage['zcodejwttoken'] = 'existing';
    final loadsBefore = _sim.loadUrlCount;

    await _loadStop(tester);

    expect(_sim.countOf(AccountVault.credentialInjectScript(_account)), 0);
    expect(_sim.loadUrlCount, loadsBefore);

    await _teardown(tester);
  });

  testWidgets('无绑定账号 → 不回读不注入', (tester) async {
    await _pump(
      tester,
      AccountsState(accounts: [_account], loaded: true),
    );
    final loadsBefore = _sim.loadUrlCount;

    await _loadStop(tester);

    expect(_sim.scripts, isNot(contains(AccountVault.credentialReadScript())));
    expect(_sim.countOf(AccountVault.credentialInjectScript(_account)), 0);
    expect(_sim.loadUrlCount, loadsBefore);

    await _teardown(tester);
  });

  testWidgets('evaluate 失败 → 静默跳过，不注入不崩', (tester) async {
    await _pump(tester, _boundState());
    _sim.throwOnEvaluate = true;
    final loadsBefore = _sim.loadUrlCount;

    await _loadStop(tester);

    expect(_sim.countOf(AccountVault.credentialInjectScript(_account)), 0);
    expect(_sim.loadUrlCount, loadsBefore);
    expect(find.byType(SessionView), findsOneWidget);

    await _teardown(tester);
  });
}
