import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/services/zai_auth_client.dart';
import 'package:zremote/state/accounts.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/account_vault_page.dart';

class _MemStore implements SecureStringStore {
  final Map<String, String> map = {};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _SeqUuid {
  int n = 0;

  String call() {
    n += 1;
    return 'uuid-$n';
  }
}

class _SeqRandom implements Random {
  int v = 11;

  @override
  int nextInt(int max) {
    v = (v * 41 + 17) % 256;
    return v % max;
  }

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1000) / 1000;
}

AccountVault _newVault() => AccountVault(
  store: _MemStore(),
  uuidGen: _SeqUuid().call,
  now: () => DateTime(2026, 11, 15, 12),
  random: _SeqRandom(),
);

String _b64Url(Object o) => base64Url
    .encode(utf8.encode(jsonEncode(o)))
    .replaceAll('=', '');

String _realJwt(int expSec) => '${_b64Url({'alg': 'HS256'})}'
    '.${_b64Url({'exp': expSec})}.sig';

/// u1 过期（需重登）；u2 长期有效。
final _expExpiredSec = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch ~/
    1000;
const _expValidSec = 4000000000;

Future<Account> _seed(
  AccountVault vault, {
  required String userId,
  required int expSec,
  String provider = 'zai_cn',
  String? name,
}) {
  return vault.upsertFromCredentials(
    provider: provider,
    credentials: {
      'zcodejwttoken': _realJwt(expSec),
      'oauth:active_provider': provider,
      'oauth:$provider:access_token': 'at-$userId',
      'oauth:$provider:user_info':
          '{"user_id":"$userId","email":"$userId@t.invalid","name":"用户-$userId"}',
    },
    name: name,
  );
}

final _device = RemoteDevice(
  id: 'dev-1',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {'sid': 's1', 'app_version': '3.18.2'},
  label: '',
  createdAt: DateTime(2026),
  kind: DeviceKind.v2,
);

class _FailHttp implements AuthHttpLayer {
  @override
  Future<AuthHttpResponse> get(Uri url, {Map<String, String>? headers}) async {
    throw const ZaiAuthException(
      ZaiAuthErrorKind.network,
      message: 'no network in test',
    );
  }

  @override
  Future<AuthHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    throw const ZaiAuthException(
      ZaiAuthErrorKind.network,
      message: 'no network in test',
    );
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required AccountVault vault,
  Future<Map<String, String>> Function()? onCaptureCurrent,
  Future<bool> Function(Account)? onApply,
  ZaiAuthClient? client,
  Future<Uint8List?> Function()? importSource,
}) async {
  final container = ProviderContainer(
    overrides: [accountVaultOverrideProvider.overrideWithValue(vault)],
  );
  addTearDown(container.dispose);
  container.read(accountsProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ZT.theme(Brightness.dark),
        home: AccountVaultPage(
          device: _device,
          onCaptureCurrent:
              onCaptureCurrent ?? () async => <String, String>{},
          onApply: onApply ?? (account) async => true,
          client: client,
          exportSink: (bytes, fileName) async {},
          importSource: importSource ?? () async => null,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

/// 驱动假时钟前进，让 .zsb PBKDF2 的 50×1ms 暂停 timer 全部到期。
Future<void> _advanceCrypto(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
}

void main() {
  testWidgets('1. 列表：名称/provider/在用/需重登徽章', (tester) async {
    final vault = _newVault();
    final active = await _seed(vault, userId: 'u1', expSec: _expExpiredSec, name: '用户-u1');
    await vault.setActiveForDevice('dev-1', active.id);
    await _seed(vault, userId: 'u2', expSec: _expValidSec, name: '二号');
    await _pump(tester, vault: vault);

    expect(find.text('用户-u1'), findsOneWidget);
    expect(find.text('二号'), findsOneWidget);
    expect(find.text('Z.ai（中国）'), findsNWidgets(2));
    expect(find.byKey(const Key('acct-badge-active')), findsOneWidget);
    expect(find.byKey(const Key('acct-badge-relogin')), findsOneWidget);
  });

  testWidgets('2. 空态：无账号提示', (tester) async {
    await _pump(tester, vault: _newVault());
    expect(find.byKey(const Key('acct-empty')), findsOneWidget);
  });

  testWidgets('3. 应用确认弹窗：确认后绑定+注入回调', (tester) async {
    final vault = _newVault();
    final account = await _seed(vault, userId: 'u1', expSec: _expValidSec, name: '用户-u1');
    final applied = <String>[];
    await _pump(
      tester,
      vault: vault,
      onApply: (a) async {
        applied.add(a.id);
        return true;
      },
    );

    await tester.tap(find.byKey(Key('acct-menu-${account.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('acct-menu-apply')));
    await tester.pump();

    expect(find.text('应用账号'), findsOneWidget);
    expect(
      find.text('将把「用户-u1」应用到当前设备并刷新页面；现有登录会先保存到账号库。'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('acct-apply-ok')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(applied, [account.id]);
    expect(await vault.activeAccountIdFor('dev-1'), account.id);
    expect(find.text('已应用，正在刷新'), findsOneWidget);
  });

  testWidgets('3b. 应用取消：不注入不绑定', (tester) async {
    final vault = _newVault();
    final account = await _seed(vault, userId: 'u1', expSec: _expValidSec, name: '用户-u1');
    var applied = 0;
    await _pump(
      tester,
      vault: vault,
      onApply: (a) async {
        applied++;
        return true;
      },
    );
    await tester.tap(find.byKey(Key('acct-menu-${account.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('acct-menu-apply')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('acct-apply-cancel')));
    await tester.pump();
    await tester.pump();
    expect(applied, 0);
    expect(await vault.activeAccountIdFor('dev-1'), isNull);
  });

  testWidgets('4. 删除确认弹窗：确认后移除', (tester) async {
    final vault = _newVault();
    final account = await _seed(vault, userId: 'u1', expSec: _expValidSec, name: '用户-u1');
    await _pump(tester, vault: vault);

    await tester.tap(find.byKey(Key('acct-menu-${account.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('acct-menu-delete')));
    await tester.pump();
    expect(find.text('删除账号？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('acct-delete-ok')));
    await tester.pump();
    await tester.pump();
    expect(find.text('用户-u1'), findsNothing);
    expect(await vault.loadAll(), isEmpty);
  });

  testWidgets('5. 保存当前登录：回读键值入库 + toast', (tester) async {
    final vault = _newVault();
    await _pump(
      tester,
      vault: vault,
      onCaptureCurrent: () async => {
        'zcodejwttoken': _realJwt(_expValidSec),
        'oauth:active_provider': 'zai',
      },
    );
    await tester.tap(find.byKey(const Key('acct-save-current')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('已保存当前登录'), findsOneWidget);
    final accounts = await vault.loadAll();
    expect(accounts, hasLength(1));
    expect(accounts.single.provider, 'zai');
  });

  testWidgets('5b. 保存当前登录：未登录 toast', (tester) async {
    await _pump(
      tester,
      vault: _newVault(),
      onCaptureCurrent: () async => <String, String>{},
    );
    await tester.tap(find.byKey(const Key('acct-save-current')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('当前设备未登录，无可保存'), findsOneWidget);
  });

  testWidgets('6. 导出→导入 .zsb 往返（替身注入）', (tester) async {
    final exportVault = _newVault();
    final account = await _seed(exportVault, userId: 'u1', expSec: _expValidSec, name: '用户-u1');
    // PBKDF2 内部有 1ms 暂停 timer，testWidgets 假时钟下会自锁——走 runAsync 真时钟。
    final bytes = await tester.runAsync(
      () => exportVault.exportBundle('secret-pass', [account]),
    );

    final importVault = _newVault();
    await _pump(
      tester,
      vault: importVault,
      importSource: () async => bytes,
    );
    await tester.tap(find.byKey(const Key('acct-import')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('acct-pwd-field')), 'secret-pass');
    await tester.tap(find.byKey(const Key('acct-pwd-ok')));
    await _advanceCrypto(tester);
    expect(find.text('导入完成：新增 1 个，跳过 0 个'), findsOneWidget);
    expect((await importVault.loadAll()), hasLength(1));
  });

  testWidgets('7. 密码过短：弹窗内联报错不放行', (tester) async {
    final exportVault = _newVault();
    final account = await _seed(exportVault, userId: 'u1', expSec: _expValidSec, name: '用户-u1');
    final bytes = await tester.runAsync(
      () => exportVault.exportBundle('secret-pass', [account]),
    );
    await _pump(
      tester,
      vault: _newVault(),
      importSource: () async => bytes,
    );
    await tester.tap(find.byKey(const Key('acct-import')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('acct-pwd-field')), '12345');
    await tester.tap(find.byKey(const Key('acct-pwd-ok')));
    await tester.pump();
    expect(find.text('密码至少 6 位'), findsOneWidget);
    expect(find.byKey(const Key('acct-pwd-field')), findsOneWidget);
  });

  testWidgets('8. 错密码导入：wrongPassword 文案', (tester) async {
    final exportVault = _newVault();
    final account = await _seed(exportVault, userId: 'u1', expSec: _expValidSec, name: '用户-u1');
    final bytes = await tester.runAsync(
      () => exportVault.exportBundle('secret-pass', [account]),
    );
    final importVault = _newVault();
    await _pump(
      tester,
      vault: importVault,
      importSource: () async => bytes,
    );
    await tester.tap(find.byKey(const Key('acct-import')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('acct-pwd-field')), 'wrong-pass');
    await tester.tap(find.byKey(const Key('acct-pwd-ok')));
    await _advanceCrypto(tester);
    expect(find.text('密码错误或文件已损坏'), findsOneWidget);
    expect((await importVault.loadAll()), isEmpty);
  });

  testWidgets('9. 账号详情：本地资料回退 + profile 拉取失败标记', (tester) async {
    final vault = _newVault();
    await _seed(vault, userId: 'u9', expSec: _expValidSec, name: '用户-u9');
    await _pump(
      tester,
      vault: vault,
      client: ZaiAuthClient(http: _FailHttp()),
    );
    await tester.tap(find.text('用户-u9'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('账号详情'), findsOneWidget);
    expect(find.text('用户-u9'), findsWidgets);
    expect(find.byKey(const Key('acct-profile-failed')), findsOneWidget);
  });
}
