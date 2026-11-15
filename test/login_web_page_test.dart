import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/services/remote_device_client.dart';
import 'package:zremote/services/zai_auth_client.dart';
import 'package:zremote/state/accounts.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/login_web_page.dart';

class _FakeHttp implements AuthHttpLayer {
  _FakeHttp(this.script);

  /// 逐条消费；条目为 [ZaiAuthException] 时抛出（模拟网络/形状错误）。
  final List<Object> script;
  int i = 0;

  @override
  Future<AuthHttpResponse> get(Uri url, {Map<String, String>? headers}) async =>
      _next();

  @override
  Future<AuthHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async => _next();

  AuthHttpResponse _next() {
    if (i >= script.length) {
      return const AuthHttpResponse(statusCode: 200);
    }
    final item = script[i++];
    if (item is AuthHttpResponse) return item;
    throw item as ZaiAuthException;
  }
}

AuthHttpResponse _resp(Map<String, dynamic> body) =>
    AuthHttpResponse(statusCode: 200, body: body);

final _initOk = _resp({
  'code': 0,
  'data': {
    'flow_id': 'flow-1',
    'authorize_url': 'https://chat.z.ai/api/oauth/authorize?x=1',
    'poll_interval_sec': 1,
  },
});

/// 已过期（用于页面加载期限兜底）。
final _initOkExpired = _resp({
  'code': 0,
  'data': {
    'flow_id': 'flow-exp',
    'authorize_url': 'https://chat.z.ai/api/oauth/authorize?x=1',
    'poll_interval_sec': 1,
    'expires_at': DateTime.now().millisecondsSinceEpoch - 1000,
  },
});

final _pollPending = _resp({
  'code': 0,
  'data': {'status': 'pending'},
});

final _pollReady = _resp({
  'code': 0,
  'data': {
    'status': 'ready',
    'token': 'jwt-ready',
    'user': {'user_id': 'u-1', 'name': '张三', 'email': 'z@t.invalid'},
    'zai': {'access_token': 'at-cn'},
  },
});

List<Object> _scriptWithPending(int pendingCount) => [
      _initOk,
      for (var i = 0; i < pendingCount; i++) _pollPending,
    ];

class _FakeController implements LoginWebController {
  _FakeController(this.loaded);

  final List<Uri> loaded;

  @override
  Future<void> loadUrl(Uri url) async => loaded.add(url);

  @override
  Future<Object?> evaluate(String script) async => '{}';
}

class _FakeGateway implements LoginWebGateway {
  void Function(Uri? url)? onLoadStart;
  void Function(Uri? url)? onLoadStop;
  void Function(bool? isForMainFrame, String description)? onReceivedError;
  void Function(bool? isForMainFrame, int? statusCode)? onReceivedHttpError;
  void Function(bool didCrash)? onRenderProcessGone;

  final loads = <Uri>[];
  final scripts = <String>[];
  String currentEntries = '{}';

  /// 停载 URL 覆写（模拟重定向到非预期 host）。
  Uri? stopOverride;

  /// 求值结果覆写；默认回 [currentEntries]。
  Object? Function(String script)? evalHandler;

  _FakeGateway bind(LoginWebGatewayCallbacks cb) {
    onLoadStart = cb.onLoadStart;
    onLoadStop = cb.onLoadStop;
    onReceivedError = cb.onReceivedError;
    onReceivedHttpError = cb.onReceivedHttpError;
    onRenderProcessGone = cb.onRenderProcessGone;
    return this;
  }

  @override
  Future<void> load(Uri url) async {
    loads.add(url);
    onLoadStart?.call(url);
    onLoadStop?.call(stopOverride ?? url);
  }

  @override
  Future<Object?> evaluate(String script) async {
    scripts.add(script);
    final handler = evalHandler;
    if (handler != null) return handler(script);
    return currentEntries;
  }
}

class _MemStore implements SecureStringStore {
  final Map<String, String> map = {};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _FakeDeviceClient extends RemoteDeviceClient {
  _FakeDeviceClient({this.entries = const []});

  final List<RemoteDeviceEntry> entries;

  @override
  Future<List<RemoteDeviceEntry>> listDevices(
    String jwt, {
    String? deviceMid,
  }) async => entries;
}

class _StubDevices extends DeviceListNotifier {
  _StubDevices(this.initial);

  final List<RemoteDevice> initial;

  @override
  List<RemoteDevice> build() => initial;

  @override
  Future<void> add(RemoteDevice device) async {
    state = [...state, device];
  }
}

class _StubAccounts extends AccountsNotifier {
  _StubAccounts(this.initial);

  AccountsState initial;
  final List<RemoteDevice> bound = [];

  @override
  AccountsState build() => initial;

  @override
  Future<void> setActiveForDevice(RemoteDevice device, String? accountId) async {
    bound.add(device);
  }
}

class _SeqRandom implements Random {
  int v = 7;

  @override
  int nextInt(int max) {
    v = (v * 37 + 11) % 256;
    return v % max;
  }

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1000) / 1000;
}

int _uuidN = 0;

AccountVault _vault() => AccountVault(
  store: _MemStore(),
  uuidGen: () {
    _uuidN += 1;
    return 'uuid-$_uuidN';
  },
  now: () => DateTime(2026, 11, 15, 12),
  random: _SeqRandom(),
);

final _device = RemoteDevice(
  id: 'dev-1',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {'sid': 's1', 'app_version': '3.18.2'},
  label: '',
  createdAt: DateTime(2026),
  kind: DeviceKind.v2,
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<Completer<LoginWebOutcome?>> _pumpPushed(
  WidgetTester tester, {
  required ZaiAuthClient client,
  required AccountVault vault,
  required _FakeGateway gateway,
  bool noDevice = false,
  RemoteDeviceClient? deviceClient,
}) async {
  final done = Completer<LoginWebOutcome?>();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ZT.theme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => unawaited(
                Navigator.of(context)
                    .push<LoginWebOutcome>(
                      MaterialPageRoute(
                        builder: (_) => LoginWebPage(
                          device: noDevice ? null : _device,
                          client: client,
                          vault: vault,
                          gatewayFactory: gateway.bind,
                          deviceClient: deviceClient,
                        ),
                      ),
                    )
                    .then(done.complete),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return done;
}

Widget _app(
  ZaiAuthClient client,
  AccountVault vault,
  _FakeGateway gateway, {
  bool noDevice = false,
  RemoteDeviceClient? deviceClient,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ZT.theme(Brightness.dark),
  home: LoginWebPage(
    device: noDevice ? null : _device,
    client: client,
    vault: vault,
    gatewayFactory: gateway.bind,
    deviceClient: deviceClient,
  ),
);

void main() {
  testWidgets('1. provider 选择：三入口齐全，点击进入授权态', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(http: _FakeHttp([_initOk])),
        _vault(),
        gateway,
      ),
    );
    expect(find.text('Z.ai（中国）'), findsOneWidget);
    expect(find.text('Z.ai（全球）'), findsOneWidget);
    expect(find.text('BigModel'), findsOneWidget);

    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('login-status')), findsOneWidget);
    expect(gateway.loads, hasLength(1));
    expect(
      gateway.loads.single.toString(),
      'https://chat.z.ai/api/oauth/authorize?x=1',
    );
    // 轮询脚本耗尽后进入失败态（清空 pending timer，避免测试悬挂）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
  });

  testWidgets('2. 完整成功链：init→load authorize→poll ready→存库→注入→pop done',
      (tester) async {
    final gateway = _FakeGateway();
    final vault = _vault();
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp([_initOk, _pollReady])),
      vault: vault,
      gateway: gateway,
    );

    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(gateway.loads, hasLength(2));
    expect(
      gateway.loads.first.toString(),
      'https://chat.z.ai/api/oauth/authorize?x=1',
    );
    expect(gateway.loads.last.host, 'zcode.z.ai');
    expect(gateway.scripts, hasLength(2));
    expect(gateway.scripts.last.contains('zcodejwttoken'), isTrue);

    final accounts = await vault.loadAll();
    expect(accounts, hasLength(1));
    expect(accounts.single.provider, 'zai_cn');
    expect(accounts.single.credentials['zcodejwttoken'], 'jwt-ready');
    expect(accounts.single.credentials['oauth:zai_cn:access_token'], 'at-cn');
    expect(accounts.single.name, 'z@t.invalid');
    expect(await vault.activeAccountIdFor('dev-1'), accounts.single.id);
    expect(done.isCompleted, isTrue);
    expect(await done.future, LoginWebOutcome.done);
  });

  testWidgets('3. 防丢号：注入前回读保全既有登录', (tester) async {
    final gateway = _FakeGateway()
      ..currentEntries =
          '{"zcodejwttoken":"jwt-old","oauth:active_provider":"zai"}';
    final vault = _vault();
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp([_initOk, _pollReady])),
      vault: vault,
      gateway: gateway,
    );

    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    // 旧登录保全 + 新账号 = 2 个账号；绑定仍是新账号。
    final accounts = await vault.loadAll();
    expect(accounts, hasLength(2));
    expect(
      accounts.map((a) => a.credentials['zcodejwttoken']).toSet(),
      {'jwt-old', 'jwt-ready'},
    );
    expect(
      await vault.activeAccountIdFor('dev-1'),
      accounts
          .firstWhere((a) => a.credentials['zcodejwttoken'] == 'jwt-ready')
          .id,
    );
    expect(await done.future, LoginWebOutcome.done);
  });

  testWidgets('4. 网络失败态：可读错误 + 重试 + 弹窗兜底入口', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(
          http: _FakeHttp([
            const ZaiAuthException(ZaiAuthErrorKind.network, message: 'boom'),
          ]),
        ),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-bigmodel')));
    await _settle(tester);

    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(find.text('网络异常，请检查网络后重试'), findsOneWidget);
    expect(find.byKey(const Key('login-retry')), findsOneWidget);
    expect(find.byKey(const Key('login-fallback-popup')), findsOneWidget);
  });

  testWidgets('4b. 弹窗兜底按钮 pop fallbackPopup', (tester) async {
    final gateway = _FakeGateway();
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(
        http: _FakeHttp([
          const ZaiAuthException(ZaiAuthErrorKind.network, message: 'boom'),
        ]),
      ),
      vault: _vault(),
      gateway: gateway,
    );
    await tester.tap(find.byKey(const Key('login-provider-bigmodel')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('login-fallback-popup')));
    await _settle(tester);
    expect(await done.future, LoginWebOutcome.fallbackPopup);
  });

  testWidgets('5. 轮询 failed：错误态可读（授权被拒）', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(
          http: _FakeHttp([
            _initOk,
            _resp({
              'code': 0,
              'data': {'status': 'failed'},
            }),
          ]),
        ),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(find.text('授权被拒绝或已失效，请重试'), findsOneWidget);
  });

  testWidgets('6. 授权中返回：确认放弃弹窗 → 确认后 pop dismissed', (tester) async {
    final gateway = _FakeGateway();
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp([_initOk, _pollReady])),
      vault: _vault(),
      gateway: gateway,
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump();

    // 授权进行中：点关闭 → 确认弹窗
    await tester.tap(find.byKey(const Key('login-close')));
    await _settle(tester);
    expect(find.text('放弃登录？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('login-abandon-ok')));
    await _settle(tester);
    expect(await done.future, LoginWebOutcome.dismissed);
    // 排空轮询等待 timer（epoch 已变，循环在下次 tick 退出）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  });

  test('7. P1-0：控制器未 attach 时 load 缓存，attach 后补载', () async {
    final gateway = ControllerLoginGateway();
    final loaded = <Uri>[];
    const url = 'https://chat.z.ai/api/oauth/authorize?x=1';

    // 控制器未就绪：不产生装载，URL 进入待载队列。
    await gateway.load(Uri.parse(url));
    expect(loaded, isEmpty);

    gateway.attachController(_FakeController(loaded));
    await Future<void>.delayed(Duration.zero);
    expect(loaded, hasLength(1));
    expect(loaded.single.toString(), url);

    // attach 之后的 load 直接走控制器。
    await gateway.load(Uri.parse('https://zcode.z.ai/remote/v4'));
    expect(loaded, hasLength(2));
    expect(loaded.last.toString(), 'https://zcode.z.ai/remote/v4');

    // reset 后重新回到待载态（重试路径不复用旧控制器）。
    gateway.reset();
    await gateway.load(Uri.parse('https://zcode.z.ai/remote/v4'));
    expect(loaded, hasLength(2));
  });

  testWidgets('8. 超时兜底：expires_at 到点仍 authorizing → failed（可改用弹窗）',
      (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(http: _FakeHttp([_initOkExpired, _pollPending])),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    // 到期定时器为零时长：需显式 elapse 才会触发。
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(find.text('授权超时，可重试或改用弹窗登录'), findsOneWidget);
    expect(find.byKey(const Key('login-retry')), findsOneWidget);
    expect(find.byKey(const Key('login-fallback-popup')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  });

  testWidgets('9. 主文档错误进 failed；子帧错误不误报', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(http: _FakeHttp(_scriptWithPending(4))),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();

    // 子帧错误：忽略，仍处授权态。
    gateway.onReceivedError?.call(false, 'subframe boom');
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsNothing);
    expect(find.byKey(const Key('login-status')), findsOneWidget);

    // 主文档错误：进失败态并带原因摘要。
    gateway.onReceivedError?.call(true, 'main boom');
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(
      find.text('页面加载失败（main boom），请重试或改用弹窗登录'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('10. 主文档 HTTP 错误进 failed（非 4xx/5xx 不计）', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(http: _FakeHttp(_scriptWithPending(4))),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();

    gateway.onReceivedHttpError?.call(true, 302);
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsNothing);

    gateway.onReceivedHttpError?.call(true, 500);
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(
      find.text('页面加载失败（HTTP 500），请重试或改用弹窗登录'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('11. 渲染进程消亡进 failed', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(http: _FakeHttp(_scriptWithPending(4))),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();

    gateway.onRenderProcessGone?.call(true);
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(find.text('页面渲染异常，请重试或改用弹窗登录'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('12. 空白探测：停载 5s 仍空白 → failed；脚本守 M0-1', (tester) async {
    final gateway = _FakeGateway();
    gateway.evalHandler = (script) => script.contains('loader-wrapper')
        ? '{"ready":"complete","ok":false}'
        : '{}';
    await tester.pumpWidget(
      _app(
        ZaiAuthClient(http: _FakeHttp(_scriptWithPending(7))),
        _vault(),
        gateway,
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    expect(find.text('页面未渲染，请重试或改用弹窗登录'), findsOneWidget);

    final probe = gateway.scripts.firstWhere(
      (s) => s.contains('loader-wrapper'),
    );
    expect(probe.contains('//'), isFalse);
    expect(probe.contains('/*'), isFalse);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('13. 授权页正常渲染：空白探测不误报', (tester) async {
    final gateway = _FakeGateway();
    gateway.evalHandler = (script) => script.contains('loader-wrapper')
        ? '{"ready":"complete","ok":true}'
        : '{}';
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp(_scriptWithPending(7))),
      vault: _vault(),
      gateway: gateway,
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(find.byKey(const Key('login-error-message')), findsNothing);
    expect(find.byKey(const Key('login-status')), findsOneWidget);

    // 收尾：确认放弃退出，排空轮询 timer。
    await tester.tap(find.byKey(const Key('login-close')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('login-abandon-ok')));
    await _settle(tester);
    expect(await done.future, LoginWebOutcome.dismissed);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('14. 非白名单 host：不注入凭据', (tester) async {
    final gateway = _FakeGateway()
      ..stopOverride = Uri.parse('https://evil.example/remote/v4');
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp([_initOk, _pollReady])),
      vault: _vault(),
      gateway: gateway,
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(gateway.scripts, isEmpty);
    expect(done.isCompleted, isFalse);

    // 收尾：主文档错误进失败态，排空 timer。
    gateway.onReceivedError?.call(true, 'boom');
    await tester.pump();
    expect(find.byKey(const Key('login-error-message')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('15. 加载中提供弹窗兜底出口', (tester) async {
    final gateway = _FakeGateway();
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp(_scriptWithPending(4))),
      vault: _vault(),
      gateway: gateway,
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();

    expect(
      find.byKey(const Key('login-fallback-popup-loading')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('login-fallback-popup-loading')));
    await _settle(tester);
    expect(await done.future, LoginWebOutcome.fallbackPopup);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('16. 无设备登录：入账号库、不绑设备、进 saved 态、可 pop done', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final vault = _vault();
    final done = await _pumpPushed(
      tester,
      client: ZaiAuthClient(http: _FakeHttp([_initOk, _pollReady])),
      vault: vault,
      gateway: gateway,
      noDevice: true,
    );

    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(find.byKey(const Key('login-saved-title')), findsOneWidget);
    expect(find.byKey(const Key('login-import-devices')), findsOneWidget);
    expect(find.byKey(const Key('login-done')), findsOneWidget);
    // 只装载官方授权页，不装载设备会话页（无设备可注入）。
    expect(gateway.loads, hasLength(1));

    final accounts = await vault.loadAll();
    expect(accounts, hasLength(1));
    expect(accounts.single.credentials['zcodejwttoken'], 'jwt-ready');
    // 无设备可绑：绑定表为空。
    expect(await vault.loadActiveBindings(), isEmpty);

    await tester.tap(find.byKey(const Key('login-done')));
    await _settle(tester);
    expect(await done.future, LoginWebOutcome.done);
  });

  testWidgets('17. 无设备登录后导入入口：账号无设备 → 提示且留在 saved 态', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final vault = _vault();
    await tester.pumpWidget(
      ProviderScope(
        child: _app(
          ZaiAuthClient(http: _FakeHttp([_initOk, _pollReady])),
          vault,
          gateway,
          noDevice: true,
          deviceClient: _FakeDeviceClient(),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(find.byKey(const Key('login-saved-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('login-import-devices')));
    await _settle(tester);
    expect(find.text('该账号下没有已注册的设备'), findsOneWidget);
    expect(find.byKey(const Key('login-saved-title')), findsOneWidget);
  });

  testWidgets('18. 无设备登录后导入：选设备 → 写库 + 绑账号 + pop done', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final vault = _vault();
    final devices = _StubDevices(const []);
    final accounts = _StubAccounts(const AccountsState());
    const entry = RemoteDeviceEntry(
      sid: 'sid-new',
      mid: 'mid-new',
      name: 'Office New',
      platform: 'win32',
      appVersion: '3.18.2',
      online: true,
    );
    final done = Completer<LoginWebOutcome?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceListProvider.overrideWith(() => devices),
          accountsProvider.overrideWith(() => accounts),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => unawaited(
                    Navigator.of(context)
                        .push<LoginWebOutcome>(
                          MaterialPageRoute(
                            builder: (_) => LoginWebPage(
                              client: ZaiAuthClient(
                                http: _FakeHttp([_initOk, _pollReady]),
                              ),
                              vault: vault,
                              gatewayFactory: gateway.bind,
                              deviceClient: _FakeDeviceClient(entries: [entry]),
                            ),
                          ),
                        )
                        .then(done.complete),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('login-provider-zai_cn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(find.byKey(const Key('login-saved-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('login-import-devices')));
    await tester.pumpAndSettle();
    expect(find.text('选择要添加的设备'), findsOneWidget);

    await tester.tap(find.text('Office New'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('devices-add-open')));
    await tester.pumpAndSettle();

    expect(devices.state, hasLength(1));
    expect(accounts.bound, hasLength(1));
    expect(done.isCompleted, isTrue);
    expect(await done.future, LoginWebOutcome.done);
  });
}
