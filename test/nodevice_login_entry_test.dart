import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/keepalive.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/manage_page.dart';
import 'package:zremote/ui/settings_page.dart';

class _FakeDeviceListNotifier extends DeviceListNotifier {
  _FakeDeviceListNotifier(this.initial);

  final List<RemoteDevice> initial;

  @override
  List<RemoteDevice> build() => initial;

  @override
  Future<void> add(RemoteDevice device) async {
    state = [...state, device];
  }
}

class _FakeKeepAliveNotifier extends KeepAliveEnabledNotifier {
  @override
  bool build() => false;
}

Future<void> _pumpManage(WidgetTester tester, List<RemoteDevice> devices) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  const keepaliveChannel = MethodChannel('zremote/keepalive');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, null);
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceListProvider.overrideWith(() => _FakeDeviceListNotifier(devices)),
        keepAliveEnabledProvider.overrideWith(() => _FakeKeepAliveNotifier()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ManagePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  const keepaliveChannel = MethodChannel('zremote/keepalive');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );
  const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(packageInfoChannel, (call) async => null);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(urlLauncherChannel, (call) async => true);
  addTearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(keepaliveChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
    messenger.setMockMethodCallHandler(packageInfoChannel, null);
    messenger.setMockMethodCallHandler(urlLauncherChannel, null);
  });
  PackageInfo.setMockInitialValues(
    appName: 'ZRemote',
    packageName: 'com.pjpv.zremote',
    version: '2.0.1',
    buildNumber: '9',
    buildSignature: '',
  );

  tester.view.physicalSize = const Size(760, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('l10n：login*/acct* 新增键 zh/en 对齐（反向验证非空绿）', () {
    Map<String, dynamic> load(String name) =>
        jsonDecode(File('lib/l10n/$name').readAsStringSync())
            as Map<String, dynamic>;
    final zh = load('app_zh.arb');
    final en = load('app_en.arb');
    Iterable<String> keys(Map<String, dynamic> arb) => arb.keys.where(
      (k) =>
          (k.startsWith('login') || k.startsWith('acct')) &&
          !k.startsWith('@'),
    );
    final zhKeys = keys(zh).toSet();
    final enKeys = keys(en).toSet();
    expect(zhKeys.difference(enKeys), isEmpty);
    expect(enKeys.difference(zhKeys), isEmpty);
    expect(zhKeys, containsAll(<String>[
      'loginEntryAccount',
      'loginSavedTitle',
      'loginSavedBody',
      'loginSavedBodyName',
      'loginImportDevices',
      'loginDone',
      'acctSection',
      'acctLoginSub',
      'acctLoginSubCount',
    ]));
  });

  testWidgets('空设备态：登录账号入口可达 LoginWebPage（无设备）', (tester) async {
    await _pumpManage(tester, const []);
    expect(find.byKey(const Key('empty-login-account')), findsOneWidget);

    await tester.tap(find.byKey(const Key('empty-login-account')));
    await tester.pumpAndSettle();

    expect(find.text('登录 ZCode'), findsOneWidget);
    expect(find.byKey(const Key('login-provider-zai_cn')), findsOneWidget);
  });

  testWidgets('设置页账号区：登录账号入口可达 LoginWebPage（无设备）', (
    tester,
  ) async {
    await _pumpSettings(tester);
    expect(find.text('登录账号'), findsOneWidget);

    await tester.tap(find.text('登录账号'));
    await tester.pumpAndSettle();

    expect(find.text('登录 ZCode'), findsOneWidget);
    expect(find.byKey(const Key('login-provider-zai_cn')), findsOneWidget);
  });
}
