import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/appearance.dart';
import 'package:zremote/state/keepalive.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/state/toolbox_nav.dart';
import 'package:zremote/ui/diagnostics_page.dart';
import 'package:zremote/ui/settings_page.dart';

import 'scripted_bridge.dart';

/// 回归用例：设置页「连接诊断」的调用顺序。
///
/// 旧实现先 `request()` 再 `Navigator.pop()`：Riverpod 的 `ref.listen`
/// 同步派发 → SessionView 立刻 push 诊断页 → 紧随的 pop 弹掉的是诊断页，
/// 设置页留在原地（点击无反应）。本用例用 [_DiagHost] 模拟 SessionView
/// 的消费者，断言点击后诊断页在栈顶且设置页出栈。
class _FakeDeviceListNotifier extends DeviceListNotifier {
  _FakeDeviceListNotifier(this.initial);
  final List<RemoteDevice> initial;
  @override
  List<RemoteDevice> build() => initial;
}

class _FakeKeepAliveNotifier extends KeepAliveEnabledNotifier {
  @override
  bool build() => false;
}

class _FakeAppearance extends AppearanceNotifier {
  @override
  AppearancePrefs build() => const AppearancePrefs();
}

const keepaliveChannel = MethodChannel('zremote/keepalive');

RemoteDevice _device(String id) => RemoteDevice(
      id: id,
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: {'sid': 's-$id', 'hash': 'h'},
      label: '',
      createdAt: DateTime(2026, 1, 1),
    );

/// 模拟 SessionView：监听诊断请求 → 消费 → 打开诊断页。
class _DiagHost extends ConsumerStatefulWidget {
  const _DiagHost({required this.device, this.consume = true});
  final RemoteDevice device;

  /// false 时只模拟「无消费者」（不监听、不消费）。
  final bool consume;

  @override
  ConsumerState<_DiagHost> createState() => _DiagHostState();
}

class _DiagHostState extends ConsumerState<_DiagHost> {
  @override
  Widget build(BuildContext context) {
    if (widget.consume) {
      ref.listen(diagnosticsOpenRequestProvider, (prev, next) {
        if (next == null || next.deviceId != widget.device.id) return;
        ref.read(diagnosticsOpenRequestProvider.notifier).consume();
        final bridge = ScriptedBridge(script: const [
          [
            {
              'keys': ['usageStatsService'],
              'checks': <String, dynamic>{},
            },
          ],
          [
            {'supported': true},
          ],
          [
            {'plan': 'team'},
          ],
        ]);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DiagnosticsPage(
              device: widget.device,
              bridge: bridge.bridge,
            ),
          ),
        );
      });
    }
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
          ),
          child: const Text('open-settings'),
        ),
      ),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<RemoteDevice> devices = const [],
  Size size = const Size(400, 1200),
}) {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, null);
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        keepAliveEnabledProvider.overrideWith(() => _FakeKeepAliveNotifier()),
        appearanceProvider.overrideWith(() => _FakeAppearance()),
        deviceListProvider.overrideWith(
          () => _FakeDeviceListNotifier(devices),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
}

Future<void> _openSettingsAndTapDiagnostics(WidgetTester tester) async {
  await tester.tap(find.text('open-settings'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsPage), findsOneWidget);
  await tester.dragUntilVisible(
    find.text('连接诊断'),
    find.byType(ListView),
    const Offset(0, -240),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('连接诊断'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点击连接诊断：诊断页入栈且设置页出栈（旧顺序必失败）', (
    tester,
  ) async {
    final device = _device('d1');
    await _pump(tester, _DiagHost(device: device), devices: [device]);
    await tester.pumpAndSettle();

    await _openSettingsAndTapDiagnostics(tester);

    expect(find.byType(DiagnosticsPage), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);
    // 有消费者 → 不弹「无消费者」提示。
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('无消费者（宽屏管理页场景）：设置页出栈且弹提示', (tester) async {
    final device = _device('d1');
    await _pump(
      tester,
      _DiagHost(device: device, consume: false),
      devices: [device],
    );
    await tester.pumpAndSettle();

    await _openSettingsAndTapDiagnostics(tester);

    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(DiagnosticsPage), findsNothing);
    expect(
      find.text('暂无可打开诊断的设备会话，请先进入设备会话'),
      findsOneWidget,
    );
  });

  testWidgets('无设备：入口不可点且副标题如实说明', (tester) async {
    final device = _device('d1');
    await _pump(tester, _DiagHost(device: device), devices: []);
    await tester.pumpAndSettle();

    await tester.tap(find.text('open-settings'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('连接诊断'),
      find.byType(ListView),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无已绑定设备'), findsOneWidget);
    final tile = tester.widget<InkWell>(
      find.ancestor(
        of: find.text('连接诊断'),
        matching: find.byType(InkWell),
      ),
    );
    expect(tile.onTap, isNull);
    // 点击不产生任何导航。
    await tester.tap(find.text('连接诊断'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
  });
}
