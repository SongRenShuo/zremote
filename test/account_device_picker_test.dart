import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/services/remote_device_client.dart';
import 'package:zremote/state/accounts.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/account_device_picker_page.dart';
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

class _FakeDeviceClient extends RemoteDeviceClient {
  _FakeDeviceClient({this.entries = const [], this.error});

  final List<RemoteDeviceEntry> entries;
  final Object? error;

  @override
  Future<List<RemoteDeviceEntry>> listDevices(
    String jwt, {
    String? deviceMid,
  }) async {
    if (error != null) throw error!;
    return entries;
  }
}

AccountVault _newVault() => AccountVault(
  store: _MemStore(),
  uuidGen: _SeqUuid().call,
  now: () => DateTime(2026, 11, 15, 12),
);

String _b64Url(Object o) => base64Url
    .encode(utf8.encode(jsonEncode(o)))
    .replaceAll('=', '');

String _jwt(int expSec) => '${_b64Url({'alg': 'HS256'})}'
    '.${_b64Url({'exp': expSec})}.sig';

Future<Account> _seed(AccountVault vault, {String userId = 'u1'}) {
  return vault.upsertFromCredentials(
    provider: 'zai_cn',
    credentials: {
      'zcodejwttoken': _jwt(4000000000),
      'oauth:active_provider': 'zai_cn',
      'oauth:zai_cn:access_token': 'at-$userId',
      'oauth:zai_cn:user_info':
          '{"user_id":"$userId","email":"$userId@t.invalid","name":"用户-$userId"}',
    },
    name: '用户-$userId',
  );
}

final RemoteDevice _existing = RemoteDevice(
  id: 'dev-1',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {'sid': 'sid-1', 'mid': 'mid-1', 'name': 'Office'},
  label: 'Office',
  createdAt: DateTime(2026),
  kind: DeviceKind.v2,
);

Future<void> _pumpApp(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ZT.theme(Brightness.dark),
      home: home,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('AccountDevicePickerPage', () {
    testWidgets('1. 新设备：确认「添加并打开」→ onAdd(open=true) + 弹出结果', (
      tester,
    ) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      AccountDevicePickerResult? result;
      final added = <({RemoteDevice device, bool open})>[];
      nav.currentState!
          .push<AccountDevicePickerResult>(
            MaterialPageRoute<AccountDevicePickerResult>(
              builder: (_) => AccountDevicePickerPage(
                accountName: '用户-u1',
                entries: const [
                  RemoteDeviceEntry(
                    sid: 'sid-new',
                    mid: 'mid-new',
                    name: 'Office New',
                    platform: 'win32',
                    appVersion: '3.18.2',
                    online: true,
                  ),
                ],
                existingDevices: const [],
                onAdd: (device, {required open}) async {
                  added.add((device: device, open: open));
                  return true;
                },
              ),
            ),
          )
          .then((r) => result = r);
      await tester.pumpAndSettle();

      expect(find.text('Office New'), findsOneWidget);
      expect(find.text('Windows · ZCode 3.18.2 · 在线'), findsOneWidget);

      await tester.tap(find.text('Office New'));
      await tester.pumpAndSettle();
      expect(find.text('添加设备'), findsOneWidget);

      await tester.tap(find.byKey(const Key('devices-add-open')));
      await tester.pumpAndSettle();

      expect(added, hasLength(1));
      expect(added.single.open, isTrue);
      expect(added.single.device.params, {
        'sid': 'sid-new',
        'mid': 'mid-new',
        'name': 'Office New',
        'app_version': '3.18.2',
      });
      expect(added.single.device.kind, DeviceKind.v2);
      expect(result, isNotNull);
      expect(result!.duplicate, isFalse);
      expect(result!.open, isTrue);
      expect(find.byType(AccountDevicePickerPage), findsNothing);
    });

    testWidgets('2. 仅添加：onAdd(open=false)', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      final added = <({RemoteDevice device, bool open})>[];
      nav.currentState!
          .push<AccountDevicePickerResult>(
            MaterialPageRoute<AccountDevicePickerResult>(
              builder: (_) => AccountDevicePickerPage(
                accountName: '用户-u1',
                entries: const [
                  RemoteDeviceEntry(sid: 's', mid: 'm', name: 'Home'),
                ],
                existingDevices: const [],
                onAdd: (device, {required open}) async {
                  added.add((device: device, open: open));
                  return true;
                },
              ),
            ),
          );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-add-only')));
      await tester.pumpAndSettle();

      expect(added.single.open, isFalse);
    });

    testWidgets('3. 去重命中（同 MID）→ 切换结果', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      AccountDevicePickerResult? result;
      var addCalled = false;
      nav.currentState!
          .push<AccountDevicePickerResult>(
            MaterialPageRoute<AccountDevicePickerResult>(
              builder: (_) => AccountDevicePickerPage(
                accountName: '用户-u1',
                entries: const [
                  RemoteDeviceEntry(
                    sid: 'sid-new',
                    mid: 'mid-1',
                    name: 'Office',
                  ),
                ],
                existingDevices: [_existing],
                onAdd: (device, {required open}) async {
                  addCalled = true;
                  return true;
                },
              ),
            ),
          )
          .then((r) => result = r);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Office'));
      await tester.pumpAndSettle();
      expect(find.text('设备已存在'), findsOneWidget);
      expect(find.textContaining('同一设备标识'), findsOneWidget);

      await tester.tap(find.byKey(const Key('devices-dup-switch')));
      await tester.pumpAndSettle();

      expect(addCalled, isFalse);
      expect(result, isNotNull);
      expect(result!.duplicate, isTrue);
      expect(result!.deviceId, 'dev-1');
      expect(result!.open, isTrue);
    });

    testWidgets('4. 空列表 → 空态', (tester) async {
      await _pumpApp(
        tester,
        AccountDevicePickerPage(
          accountName: '用户-u1',
          entries: const [],
          existingDevices: const [],
          onAdd: (device, {required open}) async => true,
        ),
      );
      expect(find.byKey(const Key('devices-picker-empty')), findsOneWidget);
    });

    testWidgets('5. 添加失败 → toast 且不弹出', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      nav.currentState!.push<AccountDevicePickerResult>(
        MaterialPageRoute<AccountDevicePickerResult>(
          builder: (_) => AccountDevicePickerPage(
            accountName: '用户-u1',
            entries: const [RemoteDeviceEntry(sid: 's', mid: 'm', name: 'X')],
            existingDevices: const [],
            onAdd: (device, {required open}) async => false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('X'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-add-open')));
      await tester.pump();
      await tester.pump();

      expect(find.text('添加失败'), findsOneWidget);
      expect(find.byType(AccountDevicePickerPage), findsOneWidget);
    });

    testWidgets('6. 无设备独立打开：省略 existingDevices + 系统返回取消', (
      tester,
    ) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      AccountDevicePickerResult? result;
      nav.currentState!
          .push<AccountDevicePickerResult>(
            MaterialPageRoute<AccountDevicePickerResult>(
              builder: (_) => AccountDevicePickerPage(
                accountName: '用户-u1',
                entries: const [
                  RemoteDeviceEntry(sid: 's', mid: 'm', name: 'Home'),
                ],
                onAdd: (device, {required open}) async => true,
              ),
            ),
          )
          .then((r) => result = r);
      await tester.pumpAndSettle();
      expect(find.byType(AccountDevicePickerPage), findsOneWidget);

      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(AccountDevicePickerPage), findsNothing);
    });
  });

  group('AccountVaultPage 从账户添加设备入口', () {
    Future<ProviderContainer> pumpVault(
      WidgetTester tester, {
      required AccountVault vault,
      required List<RemoteDevice> devices,
      RemoteDevice? device,
      RemoteDeviceClient? deviceClient,
      Future<Map<String, String>> Function()? onCaptureCurrent,
    }) async {
      final container = ProviderContainer(
        overrides: [
          accountVaultOverrideProvider.overrideWithValue(vault),
          deviceListProvider.overrideWith(() => _StubDevices(devices)),
        ],
      );
      addTearDown(container.dispose);
      container.read(accountsProvider);
      container.read(deviceListProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ZT.theme(Brightness.dark),
            home: AccountVaultPage(
              device: device,
              onCaptureCurrent: device == null
                  ? null
                  : onCaptureCurrent ?? () async => <String, String>{},
              onApply: device == null ? null : (account) async => true,
              deviceClient: deviceClient,
              exportSink: (bytes, fileName) async {},
              importSource: () async => null,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return container;
    }

    testWidgets('6. 无账号 → 入口禁用；有全局活跃账号 → 可点（无需设备绑定）', (
      tester,
    ) async {
      final emptyVault = _newVault();
      await pumpVault(
        tester,
        vault: emptyVault,
        devices: const [],
        device: _existing,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('acct-add-device')),
            )
            .onPressed,
        isNull,
      );

      final vault2 = _newVault();
      await _seed(vault2);
      await pumpVault(
        tester,
        vault: vault2,
        devices: const [],
        device: _existing,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('acct-add-device')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('7. 完整链路：拉列表 → 选择 → 添加并打开 → 写库 + 切会话', (
      tester,
    ) async {
      final vault = _newVault();
      final account = await _seed(vault);
      await vault.setActiveForDevice('dev-1', account.id);
      final devices = <RemoteDevice>[_existing];
      final container = await pumpVault(
        tester,
        vault: vault,
        devices: devices,
        device: _existing,
        deviceClient: _FakeDeviceClient(
          entries: const [
            RemoteDeviceEntry(
              sid: 'sid-2',
              mid: 'mid-2',
              name: 'Office New',
              appVersion: '3.18.2',
              online: true,
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(const Key('acct-add-device')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountDevicePickerPage), findsOneWidget);

      await tester.tap(find.text('Office New'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-add-open')));
      await tester.pumpAndSettle();

      final stored = container.read(deviceListProvider);
      expect(stored, hasLength(2));
      expect(stored[1].params['sid'], 'sid-2');
      expect(stored[1].params['mid'], 'mid-2');
      expect(stored[1].kind, DeviceKind.v2);
      expect(container.read(activeTabProvider), 1);
      // 账号绑定到新设备，原生页可取同一账号供票。
      expect(await vault.activeAccountIdFor(stored[1].id), account.id);
    });

    testWidgets('8. 未登录（401）→ 提示重新登录', (tester) async {
      final vault = _newVault();
      final account = await _seed(vault);
      await vault.setActiveForDevice('dev-1', account.id);
      await pumpVault(
        tester,
        vault: vault,
        devices: const [],
        device: _existing,
        deviceClient: _FakeDeviceClient(
          error: const RemoteDeviceException(
            RemoteDeviceErrorKind.unauthorized,
            message: 'unauthorized',
            statusCode: 401,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('acct-add-device')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('账号登录已过期，请重新登录后再试'), findsOneWidget);
    });

    testWidgets('9. 列表为空 → 空态提示', (tester) async {
      final vault = _newVault();
      final account = await _seed(vault);
      await vault.setActiveForDevice('dev-1', account.id);
      await pumpVault(
        tester,
        vault: vault,
        devices: const [],
        device: _existing,
        deviceClient: _FakeDeviceClient(),
      );

      await tester.tap(find.byKey(const Key('acct-add-device')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('该账号下没有已注册的设备'), findsOneWidget);
    });

    testWidgets('10. 0 设备入口：可打开保险库，隐藏 WebView 动作，显示当前账号', (
      tester,
    ) async {
      final vault = _newVault();
      final account = await _seed(vault);
      await pumpVault(tester, vault: vault, devices: const [], device: null);

      expect(find.byType(AccountVaultPage), findsOneWidget);
      expect(find.text('用户-u1'), findsOneWidget);
      expect(find.byKey(const Key('acct-using-account')), findsOneWidget);
      expect(find.text('当前账号：用户-u1'), findsOneWidget);
      // 无设备：保存当前登录（依赖 WebView controller）隐藏。
      expect(find.byKey(const Key('acct-save-current')), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('acct-add-device')),
            )
            .onPressed,
        isNotNull,
      );
      // 应用菜单项隐藏，删除保留。
      await tester.tap(find.byKey(Key('acct-menu-${account.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('acct-menu-apply')), findsNothing);
      expect(find.byKey(const Key('acct-menu-delete')), findsOneWidget);
    });

    testWidgets('11. 0 设备完整链路：全局活跃账号拉列表 → 添加并打开 → 写库', (
      tester,
    ) async {
      final vault = _newVault();
      final account = await _seed(vault);
      final container = await pumpVault(
        tester,
        vault: vault,
        devices: const [],
        device: null,
        deviceClient: _FakeDeviceClient(
          entries: const [
            RemoteDeviceEntry(
              sid: 'sid-9',
              mid: 'mid-9',
              name: 'Office Nine',
              appVersion: '3.18.2',
              online: true,
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(const Key('acct-add-device')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountDevicePickerPage), findsOneWidget);

      await tester.tap(find.text('Office Nine'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-add-open')));
      await tester.pumpAndSettle();

      final stored = container.read(deviceListProvider);
      expect(stored, hasLength(1));
      expect(stored.single.params['sid'], 'sid-9');
      expect(stored.single.kind, DeviceKind.v2);
      expect(container.read(activeTabProvider), 0);
      expect(await vault.activeAccountIdFor(stored.single.id), account.id);
    });

    testWidgets('12. 当前账号可切换：菜单选择 + 恢复自动', (tester) async {
      final vault = _newVault();
      final a1 = await _seed(vault, userId: 'u1');
      final a2 = await _seed(vault, userId: 'u2');
      await pumpVault(tester, vault: vault, devices: const [], device: null);

      // 两账号同 updatedAt/createdAt → 规则取列表中靠前者。
      expect(find.text('当前账号：用户-u1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('acct-switch-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('acct-account-item-${a2.id}')));
      await tester.pumpAndSettle();
      expect(find.text('当前账号：用户-u2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('acct-switch-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('acct-account-auto')));
      await tester.pumpAndSettle();
      expect(find.text('当前账号：用户-u1'), findsOneWidget);
      expect(a1.id, isNotEmpty);
    });
  });
}
