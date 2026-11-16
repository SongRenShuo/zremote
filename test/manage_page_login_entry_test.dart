import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/keepalive.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/manage_page.dart';

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

RemoteDevice _device(String sid) => RemoteDevice(
      id: 'id-$sid',
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: {'sid': sid, 'hash': 'h'},
      label: '设备$sid',
      createdAt: DateTime(2026, 1, 1),
    );

Future<void> _pumpManage(WidgetTester tester, List<RemoteDevice> devices) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  const keepaliveChannel = MethodChannel('zremote/keepalive');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, null);
  });

  // 高视口：底部「接入新设备」卡无需滚动即可命中。
  tester.view.physicalSize = const Size(760, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

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

Future<void> _expectLoginPage(WidgetTester tester) async {
  expect(find.text('登录 ZCode'), findsOneWidget);
  expect(find.byKey(const Key('login-provider-zai_cn')), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('有设备：接入新设备卡的登录入口可达 LoginWebPage', (tester) async {
    await _pumpManage(tester, [_device('login1')]);

    final entry = find.byKey(const Key('add-device-login'));
    expect(entry, findsOneWidget);
    expect(find.text('已有账号？登录账号'), findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();
    await _expectLoginPage(tester);
  });

  testWidgets('有设备：顶栏 + 导入 sheet 的登录项可达 LoginWebPage', (tester) async {
    await _pumpManage(tester, [_device('login2')]);

    await tester.tap(find.byTooltip('扫码导入'));
    await tester.pumpAndSettle();

    final sheetLogin = find.byKey(const Key('import-sheet-login'));
    expect(sheetLogin, findsOneWidget);
    expect(find.text('登录账号'), findsOneWidget);

    await tester.tap(sheetLogin);
    await tester.pumpAndSettle();
    await _expectLoginPage(tester);
  });

  testWidgets('0 设备：顶栏 + 可见且 sheet 登录项可达 LoginWebPage（空态不回归）', (
    tester,
  ) async {
    await _pumpManage(tester, const []);

    expect(find.byTooltip('扫码导入'), findsOneWidget, reason: '0 设备也要有 +');
    expect(
      find.byKey(const Key('empty-login-account')),
      findsOneWidget,
      reason: '空态登录按钮不得回归',
    );

    await tester.tap(find.byTooltip('扫码导入'));
    await tester.pumpAndSettle();

    final sheetLogin = find.byKey(const Key('import-sheet-login'));
    expect(sheetLogin, findsOneWidget);

    await tester.tap(sheetLogin);
    await tester.pumpAndSettle();
    await _expectLoginPage(tester);
  });
}
