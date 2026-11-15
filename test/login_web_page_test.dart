import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/services/zai_auth_client.dart';
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

final _pollReady = _resp({
  'code': 0,
  'data': {
    'status': 'ready',
    'token': 'jwt-ready',
    'user': {'user_id': 'u-1', 'name': '张三', 'email': 'z@t.invalid'},
    'zai': {'access_token': 'at-cn'},
  },
});

class _FakeGateway implements LoginWebGateway {
  void Function(Uri? url)? onLoadStop;

  final loads = <Uri>[];
  final scripts = <String>[];
  String currentEntries = '{}';

  @override
  Future<void> load(Uri url) async {
    loads.add(url);
    onLoadStop?.call(url);
  }

  @override
  Future<Object?> evaluate(String script) async {
    scripts.add(script);
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
                          device: _device,
                          client: client,
                          vault: vault,
                          gatewayFactory: (onLoadStop) {
                            gateway.onLoadStop = onLoadStop;
                            return gateway;
                          },
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

void main() {
  testWidgets('1. provider 选择：三入口齐全，点击进入授权态', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ZT.theme(Brightness.dark),
        home: LoginWebPage(
          device: _device,
          client: ZaiAuthClient(http: _FakeHttp([_initOk])),
          vault: _vault(),
          gatewayFactory: (onLoadStop) {
            gateway.onLoadStop = onLoadStop;
            return gateway;
          },
        ),
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
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ZT.theme(Brightness.dark),
        home: LoginWebPage(
          device: _device,
          client: ZaiAuthClient(
            http: _FakeHttp([
              const ZaiAuthException(ZaiAuthErrorKind.network, message: 'boom'),
            ]),
          ),
          vault: _vault(),
          gatewayFactory: (onLoadStop) {
            gateway.onLoadStop = onLoadStop;
            return gateway;
          },
        ),
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
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ZT.theme(Brightness.dark),
        home: LoginWebPage(
          device: _device,
          client: ZaiAuthClient(
            http: _FakeHttp([
              _initOk,
              _resp({
                'code': 0,
                'data': {'status': 'failed'},
              }),
            ]),
          ),
          vault: _vault(),
          gatewayFactory: (onLoadStop) {
            gateway.onLoadStop = onLoadStop;
            return gateway;
          },
        ),
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
}
