import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/appearance.dart';
import 'package:zremote/state/keepalive.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/about_page.dart';
import 'package:zremote/ui/app_shell.dart';
import 'package:zremote/ui/data_manage_page.dart';
import 'package:zremote/ui/manage_page.dart';
import 'package:zremote/ui/settings_page.dart';
import 'package:zremote/ui/toolbox_sheet.dart';
import 'package:zremote/ui/session_panel.dart';
import 'package:zremote/services/event_observer.dart';

class _FakeDeviceListNotifier extends DeviceListNotifier {
  _FakeDeviceListNotifier(this.initial);

  final List<RemoteDevice> initial;

  @override
  List<RemoteDevice> build() => initial;

  @override
  Future<void> setPinned(String id, bool pinned) async {
    final target = state.firstWhere((d) => d.id == id);
    final params = Map.of(target.params);
    if (pinned) {
      params['pinned'] = '1';
    } else {
      params.remove('pinned');
    }
    final updated = RemoteDevice(
      id: target.id,
      baseUrl: target.baseUrl,
      params: params,
      label: target.label,
      createdAt: target.createdAt,
      kind: target.kind,
    );
    var next = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
    if (pinned) {
      next.remove(updated);
      next.insert(0, updated);
    }
    state = next;
  }

  @override
  Future<void> setNotifyOverride(String id, String override) async {
    state = [
      for (final d in state)
        if (d.id == id)
          RemoteDevice(
            id: d.id,
            baseUrl: d.baseUrl,
            params: {...d.params, 'notifyOverride': override},
            label: d.label,
            createdAt: d.createdAt,
            kind: d.kind,
          )
        else
          d,
    ];
  }
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

RemoteDevice _device(String id, {String label = ''}) => RemoteDevice(
      id: id,
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: {'sid': 's-$id', 'hash': 'h'},
      label: label,
      createdAt: DateTime(2026, 1, 1),
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<RemoteDevice> devices = const [],
  Size size = const Size(800, 1200),
}) {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // 电池豁免查询走平台通道：未 mock 会挂起（pumpAndSettle 超时）。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('设置页（P3 分组渲染）', () {
    testWidgets('新分组与新开关齐全：外观/安全/通知/行为/数据/高级', (tester) async {
      await _pump(tester, const SettingsPage());
      await tester.pumpAndSettle();
      // ListView 懒构建：首屏可见段先断言，再滚动逐段断言。
      expect(find.text('通用外观'), findsOneWidget);
      expect(find.text('字号缩放'), findsOneWidget);
      expect(find.text('动效减弱'), findsOneWidget);
      expect(find.text('触感反馈'), findsOneWidget);

      Future<void> scrollTo(String target) async {
        await tester.dragUntilVisible(
          find.text(target),
          find.byType(ListView),
          const Offset(0, -240),
        );
        await tester.pumpAndSettle();
      }

      await scrollTo('自动锁定延时');
      expect(find.text('自动锁定延时'), findsOneWidget);
      await scrollTo('自动领取结果');
      expect(find.text('需人工验证码'), findsOneWidget);
      expect(find.text('免打扰时段'), findsOneWidget);
      await scrollTo('会话行为');
      expect(find.text('新任务默认权限模式'), findsOneWidget);
      expect(find.text('启动恢复策略'), findsOneWidget);
      expect(find.text('设备数量提醒'), findsOneWidget);
      await scrollTo('数据与诊断');
      expect(find.text('数据管理'), findsOneWidget);
      expect(find.text('连接诊断'), findsOneWidget);
      expect(find.text('检查更新'), findsOneWidget);
      await scrollTo('桌面 UA 覆写（实验）');
      expect(find.text('高级'), findsOneWidget);
    });

    testWidgets('新任务默认权限模式显示中文标签（问题十五）', (tester) async {
      await _pump(tester, const SettingsPage());
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('新任务默认权限模式'),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      // 修复前直接显示枚举原文（build / BUILD）。
      expect(find.text('变更前确认'), findsOneWidget);
      expect(find.text('BUILD'), findsNothing);
      expect(find.text('build'), findsNothing);
    });

    testWidgets('主题选择含 OLED 纯黑档', (tester) async {
      await _pump(tester, const SettingsPage());
      await tester.pumpAndSettle();
      // 主题行标题「色彩主题」定位（语言行副标题同为「跟随系统」，不能按文案点）。
      await tester.tap(find.text('色彩主题'));
      await tester.pumpAndSettle();
      expect(find.text('OLED 纯黑'), findsOneWidget);
    });

    testWidgets('免打扰预设写入 prefs（22:00–07:00）', (tester) async {
      await _pump(tester, const SettingsPage());
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('免打扰时段'),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('免打扰时段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('22:00 – 07:00').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('22:00 – 07:00'), findsWidgets);
    });
  });

  group('关于页（P3-6）', () {
    testWidgets('版本/许可/链接/隐私段渲染', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'zremote',
        packageName: 'cn.song.zremote',
        version: '2.0.0',
        buildNumber: '9',
        buildSignature: '',
      );
      await _pump(tester, const AboutPage());
      await tester.pumpAndSettle();
      expect(find.textContaining('2.0.0'), findsOneWidget);
      expect(find.textContaining('9)'), findsOneWidget);
      expect(find.text('隐私声明'), findsOneWidget);
      expect(find.textContaining('本地优先'), findsOneWidget);
      expect(find.textContaining('JetBrainsMono'), findsOneWidget);
      expect(find.byKey(const Key('about-github-link')), findsOneWidget);
      expect(find.byKey(const Key('about-issues-link')), findsOneWidget);
    });
  });

  group('数据管理页（P3-2）', () {
    testWidgets('清除需确认，确认后调用 cleaner', (tester) async {
      final cleared = <String>[];
      await _pump(
        tester,
        DataManagePage(
          cleaner: _RecordingCleaner(cleared),
        ),
        devices: [_device('d1', label: '主机')],
      );
      await tester.pumpAndSettle();
      expect(find.text('WebView 数据（按设备）'), findsOneWidget);
      expect(find.text('主机'), findsOneWidget);
      // 未确认不触发（点击行内的清除按钮）
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('data-manage-clear-d1')),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('data-manage-clear-confirm')),
        findsOneWidget,
      );
      expect(cleared, isEmpty);
      await tester.tap(find.byKey(const Key('data-manage-clear-ok')));
      await tester.pumpAndSettle();
      expect(cleared, ['d1']);
      expect(find.text('已清除'), findsOneWidget);
    });

    testWidgets('取消不清除；.zsb 分组留说明', (tester) async {
      final cleared = <String>[];
      await _pump(
        tester,
        DataManagePage(cleaner: _RecordingCleaner(cleared)),
        devices: [_device('d1')],
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('data-manage-clear-d1')),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('data-manage-clear-cancel')));
      await tester.pumpAndSettle();
      expect(cleared, isEmpty);
      expect(find.text('账号包备份（.zsb）'), findsOneWidget);
      expect(find.textContaining('账号保险库'), findsOneWidget);
    });
  });

  group('设备卡长按菜单（P4-2）', () {
    testWidgets('长按弹菜单：置顶/换链/复制链接/通知覆盖/删除', (tester) async {
      await _pump(
        tester,
        const ManagePage(),
        devices: [_device('d1', label: '主机')],
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('主机'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-quick-menu-pin')), findsOneWidget);
      expect(find.byKey(const Key('device-quick-menu-replace')), findsOneWidget);
      expect(find.byKey(const Key('device-quick-menu-copy')), findsOneWidget);
      expect(find.byKey(const Key('device-quick-menu-notify')), findsOneWidget);
      expect(find.byKey(const Key('device-quick-menu-delete')), findsOneWidget);
    });

    testWidgets('置顶：设备移到列表头', (tester) async {
      await _pump(
        tester,
        const ManagePage(),
        devices: [
              _device('d1', label: '甲'),
              _device('d2', label: '乙'),
            ],
      );
      await tester.pumpAndSettle();
      final yA = tester.getTopLeft(find.text('甲')).dy;
      final yB = tester.getTopLeft(find.text('乙')).dy;
      expect(yA, lessThan(yB));

      await tester.longPress(find.text('乙'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-quick-menu-pin')));
      await tester.pumpAndSettle();

      final yA2 = tester.getTopLeft(find.text('甲')).dy;
      final yB2 = tester.getTopLeft(find.text('乙')).dy;
      expect(yB2, lessThan(yA2), reason: '置顶后乙在甲之前');
    });

    testWidgets('通知覆盖子菜单：off 写入 params 并回显', (tester) async {
      await _pump(
        tester,
        const ManagePage(),
        devices: [_device('d1', label: '主机')],
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('主机'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-quick-menu-notify')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notify-override-off')), findsOneWidget);
      await tester.tap(find.byKey(const Key('notify-override-off')));
      await tester.pumpAndSettle();

      // 再次打开长按菜单，覆盖项回显「关（静音此设备）」。
      await tester.longPress(find.text('主机'));
      await tester.pumpAndSettle();
      expect(find.textContaining('关（静音此设备）'), findsOneWidget);
    });
  });

  group('宽屏双栏（P4-5）', () {
    // 无设备场景双栏断言（避免 SessionView/WebView 平台依赖）：
    // 左栏品牌与空态文案、右栏空面板。
    testWidgets('900dp 视口：左栏品牌渲染 + 扫码入口在栏内', (tester) async {
      await _pump(
        tester,
        const AppShell(),
        size: const Size(900, 1200),
        devices: const [],
      );
      await tester.pumpAndSettle();
      expect(find.text('ZREMOTEX'), findsOneWidget);
      expect(find.text('扫码导入'), findsOneWidget, reason: '左栏底部添加入口');
      // 无设备：右栏空面板标题 = 空态标题（非「从左侧选择设备」——那是有设备时）
      expect(find.text('从左侧选择设备'), findsNothing);
    });

    testWidgets('窄视口（400dp）：无双栏，走 ManagePage 空态', (tester) async {
      await _pump(
        tester,
        const AppShell(),
        size: const Size(400, 800),
        devices: const [],
      );
      await tester.pumpAndSettle();
      expect(find.text('ZREMOTEX'), findsOneWidget, reason: '窄屏顶部品牌仍在');
      expect(find.byType(VerticalDivider), findsNothing);
      // ManagePage 空态可见（粘贴入口）
      expect(find.textContaining('粘贴'), findsWidgets);
    });
  });
group('工具箱列数自适应（P4-5）', () {
    // 注：原「宽面板 3 列 / 窄面板 2 列」网格断言随 L4×L2 后半合并被移除——
    // 工具箱主体已重构为分组 IA（P1-9：分组/搜索/折叠，纵向列表天然适配任意
    // 宽度）；宽屏布局由 app_shell ≥600dp 双栏（P4-5 主特性）承接。
    // 保留分组渲染 smoke：宽/窄两种视口下分组标题与入口均可见。
    Future<void> pumpToolbox(WidgetTester tester, Size size) async {
      await _pump(
        tester,
        Scaffold(
          body: Center(
            child: ToolboxSheet(
              device: _device('d1'),
              onAutomationPressed: () {},
              onClaimPressed: () {},
              onUsagePressed: () {},
              onModelSettingsPressed: () {},
            ),
          ),
        ),
        size: size,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('宽/窄面板分组入口均可见（分组 IA 替代列数网格）', (
      tester,
    ) async {
      await pumpToolbox(tester, const Size(900, 1200));
      expect(find.textContaining('模型'), findsWidgets);
      expect(find.textContaining('自动化'), findsWidgets);

      await pumpToolbox(tester, const Size(360, 800));
      expect(find.textContaining('模型'), findsWidgets);
      expect(find.textContaining('自动化'), findsWidgets);
    });
  });

  group('会话面板搜索与过滤（P4-3）', () {
    Future<void> pumpPanel(WidgetTester tester) async {
      await _pump(
        tester,
        Scaffold(
          body: SessionPanelSheet(
            sessions: const [
              SessionState(sessionId: 'a', title: '重构登录', phase: 'running'),
              SessionState(sessionId: 'b', title: '修 BUG', phase: 'error'),
              SessionState(
                sessionId: 'c',
                title: '文档',
                phase: 'completedSuccess',
                userInputCount: 2,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('搜索框过滤标题；无匹配显示空态', (tester) async {
      await pumpPanel(tester);
      expect(find.text('重构登录'), findsOneWidget);
      expect(find.text('修 BUG'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('session-panel-search')),
        '登录',
      );
      await tester.pump();
      expect(find.text('重构登录'), findsOneWidget);
      expect(find.text('修 BUG'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('session-panel-search')),
        '不存在',
      );
      await tester.pump();
      expect(find.text('无匹配会话'), findsOneWidget);
    });

    testWidgets('状态过滤 chip：需输入只留待输入行', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('需输入'));
      await tester.pump();
      expect(find.text('文档'), findsOneWidget);
      expect(find.text('重构登录'), findsNothing);
      expect(find.text('修 BUG'), findsNothing);
      // 全部 chip 恢复
      await tester.tap(find.text('全部'));
      await tester.pump();
      expect(find.text('重构登录'), findsOneWidget);
    });
  });
}

class _RecordingCleaner implements WebViewDataCleaner {
  _RecordingCleaner(this.cleared);

  final List<String> cleared;

  @override
  Future<void> clearForDevice(RemoteDevice device) async {
    cleared.add(device.id);
  }
}
