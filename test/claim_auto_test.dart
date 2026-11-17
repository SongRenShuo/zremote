import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/claim_scheduler.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/services/notifier.dart';
import 'package:zremote/state/claim_config.dart';
import 'package:zremote/state/claim_entry.dart';
import 'package:zremote/state/claim_history.dart';
import 'package:zremote/state/claim_scheduler_hub.dart';
import 'package:zremote/state/session_status.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/claim_page.dart';
import 'package:zremote/ui/toolbox_sheet.dart';

import 'scripted_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final device = RemoteDevice(
    id: 'd1',
    baseUrl: 'https://relay.example.com',
    params: const {'sid': 'sid-abcdef123456', 'hash': 'h'},
    label: '工作机',
    createdAt: DateTime(2026, 9, 1),
  );

  Map<String, dynamic> planJson({String id = 'plan-a'}) => {
    'planId': id,
    'name': '周末体验包',
    'description': '3 亿 Token 体验额度',
    'priority': 10,
    'entitlements': [
      {'showName': 'GLM-4.6', 'units': 300000000, 'unitType': 'token',
       'meter': 'model_usage'},
    ],
  };

  Map<String, dynamic> previewsResponse() =>
      {'serverTime': 1780000000000, 'plans': [planJson()]};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    ScriptedBridge? bridge,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionStatusProvider.notifier).report('d1', SessionStatus.live);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ClaimPage(
            device: device,
            bridge: (bridge ??
                    ScriptedBridge(script: [
                      [previewsResponse()],
                    ]))
                .bridge,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  group('P2-4 自动领取开关', () {
    testWidgets('默认关；打开 → provider + 磁盘持久化 + UI 同步', (tester) async {
      final container = await pumpPage(tester);
      await tester.pump(const Duration(milliseconds: 300));

      final initial = tester.widget<Switch>(
        find.byKey(const Key('claim-auto-switch')),
      );
      expect(initial.value, isFalse, reason: '开关默认关（安全默认）');

      await tester.tap(find.byKey(const Key('claim-auto-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(claimConfigProvider)['d1']!.enabled, isTrue);
      final restored = tester.widget<Switch>(
        find.byKey(const Key('claim-auto-switch')),
      );
      expect(restored.value, isTrue);
      final stored = await DeviceStore.instance.claimAutoConfig('d1');
      expect(stored.enabled, isTrue, reason: '配置落盘 zremote.claimConfig.d1');
    });

    testWidgets('静默时段入口：默认 23:00–08:00；弹层关闭静默 → 未启用 + 落盘',
        (tester) async {
      final container = await pumpPage(tester);
      await tester.pump(const Duration(milliseconds: 300));

      // 打开自动领取后出现静默入口。
      await tester.tap(find.byKey(const Key('claim-auto-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('23:00–08:00'), findsNWidgets(2),
          reason: '副标题摘要 + 入口行当前值');

      await tester.tap(find.byKey(const Key('claim-auto-silent-entry')));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('静默时段'), findsWidgets);
      expect(find.text('开始时间'), findsOneWidget);
      expect(find.text('结束时间'), findsOneWidget);
      expect(find.text('23:00'), findsOneWidget);
      expect(find.text('08:00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('claim-auto-silent-toggle')));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('静默时段未启用'), findsWidgets);
      final stored = await DeviceStore.instance.claimAutoConfig('d1');
      expect(stored.enabled, isTrue);
      expect(stored.silentEnabled, isFalse, reason: 'start==end 表示关闭静默');
      expect(container.read(claimConfigProvider)['d1']!.silentEnabled, isFalse);
    });
  });

  group('P2-6 历史 Tab', () {
    testWidgets('空态：暂无领取记录', (tester) async {
      await pumpPage(tester);
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('历史'));
      await tester.pump();
      expect(find.text('暂无领取记录'), findsOneWidget);
    });

    testWidgets('记录渲染：时间线 + 来源徽章 + 成功/失败着色 + 码徽标',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final history = container.read(claimHistoryProvider.notifier);
      history
        ..record(
          'd1',
          planId: 'plan-ok',
          planName: '周末体验包',
          success: true,
          source: ClaimRecordSource.auto,
          benefitSummary: '300,000,000 Tokens',
        )
        ..record(
          'd1',
          planId: 'plan-fail',
          planName: '深夜福利包',
          success: false,
          code: 1003,
          source: ClaimRecordSource.manual,
        );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ClaimPage(device: device, bridge: ScriptedBridge(script: const [
              [
                {'plans': []},
              ],
            ]).bridge),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('历史'));
      await tester.pump();
      expect(find.text('共 2 条'), findsOneWidget);
      expect(find.text('周末体验包'), findsOneWidget);
      expect(find.text('深夜福利包'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
      expect(find.text('手动'), findsOneWidget);
      expect(find.text('已到账'), findsOneWidget);
      expect(find.text('该套餐已经领取过'), findsOneWidget);
      expect(find.text('#1003'), findsOneWidget);
      expect(find.text('300,000,000 Tokens'), findsOneWidget);

      // 失败文案着色 danger（默认亮色主题回落 ZT.light）。
      final failText = tester.widget<Text>(find.text('该套餐已经领取过'));
      expect(failText.style?.color, ZT.light.danger);
      final okText = tester.widget<Text>(find.text('已到账'));
      expect(okText.style?.color, ZT.light.live);
    });

    testWidgets('手动领取成功 → 落历史（来源 manual）+ 徽章计数', (tester) async {
      final bridge = ScriptedBridge(script: [
        [previewsResponse()],
        const [
          {'enabled': true, 'region': 'cn', 'prefix': 'p', 'sceneId': 's'},
        ],
        const [
          {'ok': true, 'param': 'vp'},
        ],
        const [
          {
            'success': true,
            'serverTime': 1780000000000,
            'startsAt': 1779900000,
            'endsAt': 1790000000,
          },
        ],
        [
          {'plans': []},
        ],
      ]);
      final container = await pumpPage(tester, bridge: bridge);
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('领取').first);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();

      final board = container.read(claimHistoryProvider)['d1'];
      expect(board, isNotNull);
      expect(board!.records, hasLength(1));
      expect(board.records.single.planId, 'plan-a');
      expect(board.records.single.source, ClaimRecordSource.manual);
      expect(board.records.single.success, isTrue);
      expect(board.records.single.benefitSummary, '300,000,000 Tokens');
      expect(board.todayCount(DateTime.now()), 1);
    });
  });

  group('P2-7 工具箱徽章', () {
    Future<void> pumpSheet(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ToolboxSheet(
                device: device,
                onAutomationPressed: () {},
                onClaimPressed: () {},
                onUsagePressed: () {},
                onModelSettingsPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('今日已领 N：无可领时读当日成功计数', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final history = container.read(claimHistoryProvider.notifier);
      history
        ..record('d1', planId: 'a', success: true)
        ..record('d1', planId: 'b', success: true)
        ..record('d1', planId: 'c', success: false, code: 1003);
      await pumpSheet(tester, container);
      expect(find.text('今日已领 2'), findsOneWidget);
    });

    testWidgets('可领优先：claimReady 时徽标仍为「有可领」（判定沿用现有）',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(claimHistoryProvider.notifier).record(
            'd1',
            planId: 'a',
            success: true,
          );
      container.read(claimEntryProvider.notifier).report('d1', true);
      await pumpSheet(tester, container);
      expect(find.text('有可领'), findsOneWidget);
      expect(find.text('今日已领 1'), findsNothing);
    });
  });

  group('P2-7 通知', () {
    test('claimResult 成功：zr_claim 渠道 + payload 前缀 + 标题带设备', () {
      final spec = NotificationSpec.claimResult(
        device: device,
        kind: ClaimNotifyKind.success,
        planName: '周末体验包',
      );
      expect(spec.channelId, 'zr_claim');
      expect(spec.payload, 'claim:d1');
      expect(spec.title, contains('工作机'));
      expect(spec.body, contains('周末体验包'));
    });

    test('claimResult 需人工验证码：高优先级 + 引导文案', () {
      final spec = NotificationSpec.claimResult(
        device: device,
        kind: ClaimNotifyKind.captchaNeeded,
        planName: '周末体验包',
      );
      expect(spec.channelId, 'zr_claim');
      expect(spec.importance, Importance.high);
      expect(spec.payload, 'claim:d1');
      expect(spec.title, contains('需人工验证码'));
    });

    test('claimStableId：同设备不同时刻可区分', () {
      final a = NotificationSpec.claimStableId(
        device,
        ClaimNotifyKind.success,
        DateTime(2026, 11, 15, 12),
      );
      final b = NotificationSpec.claimStableId(
        device,
        ClaimNotifyKind.success,
        DateTime(2026, 11, 15, 12, 0, 1),
      );
      expect(a, isNot(b));
    });
  });

  group('通知路由 + 装配层', () {
    test('ClaimOpenRequestNotifier：request → 消费清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(claimOpenRequestProvider.notifier);
      expect(container.read(claimOpenRequestProvider), isNull);
      notifier.request('d1');
      expect(container.read(claimOpenRequestProvider), 'd1');
      notifier.consume();
      expect(container.read(claimOpenRequestProvider), isNull);
    });

    test('ClaimSchedulerHub：attach 装配代理（默认关不启动）+ detach 摘除',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hub = container.read(claimSchedulerHubProvider.notifier);

      final bridge = ScriptedBridge(script: const []);
      await hub.attach(device, bridge.bridge);
      final agent = container.read(claimSchedulerHubProvider)['d1'];
      expect(agent, isNotNull);
      expect(agent!.started, isFalse, reason: '默认关：attach 不启动循环');

      hub.updateConfig('d1', const ClaimAutoConfig(enabled: true));
      expect(agent.started, isTrue);
      hub.updateConfig('d1', const ClaimAutoConfig(enabled: false));
      expect(agent.started, isFalse, reason: '关闭 → 停表');

      hub.detach('d1');
      expect(container.read(claimSchedulerHubProvider).containsKey('d1'), isFalse);
    });

    test('Blocked 落史：runNow preview 抛错 → 历史阻断记录；同因去重不刷屏',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hub = container.read(claimSchedulerHubProvider.notifier);

      // errors 覆盖别名重试的全部命令槽（L7：候选数 × 重试次数），
      // 否则耗尽回空会被当成"无券"阻断而非 preview 异常。
      final bridge = ScriptedBridge(
        script: const [],
        errors: {for (var i = 0; i < 12; i++) i: 'boom'},
      );
      await hub.attach(device, bridge.bridge);
      hub.updateConfig('d1', const ClaimAutoConfig(enabled: true));
      expect(await hub.runNow('d1'), isTrue);

      final board = container.read(claimHistoryProvider)['d1'];
      expect(board, isNotNull);
      expect(board!.records, hasLength(1));
      expect(
        board.records.single.blockedReason,
        ClaimBlockedReason.previewError,
      );
      expect(board.records.single.success, isFalse);
      expect(board.records.single.source, ClaimRecordSource.auto);
      expect(board.records.single.message, contains('boom'));

      // 同因在 1h 窗口内再跑一轮：去重，不新增记录（防冷却循环刷屏）。
      expect(await hub.runNow('d1'), isTrue);
      expect(container.read(claimHistoryProvider)['d1']!.records, hasLength(1));
    });

    test('detach 清去重账：重新 attach 后同因可再记', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hub = container.read(claimSchedulerHubProvider.notifier);

      await hub.attach(
        device,
        ScriptedBridge(
          script: const [],
          errors: {for (var i = 0; i < 12; i++) i: 'boom'},
        ).bridge,
      );
      hub.updateConfig('d1', const ClaimAutoConfig(enabled: true));
      expect(await hub.runNow('d1'), isTrue);
      expect(container.read(claimHistoryProvider)['d1']!.records, hasLength(1));

      hub.detach('d1');
      await hub.attach(
        device,
        ScriptedBridge(
          script: const [],
          errors: {for (var i = 0; i < 12; i++) i: 'boom-2'},
        ).bridge,
      );
      hub.updateConfig('d1', const ClaimAutoConfig(enabled: true));
      expect(await hub.runNow('d1'), isTrue);
      expect(
        container.read(claimHistoryProvider)['d1']!.records,
        hasLength(2),
        reason: 'detach 清账后同因可再记',
      );
    });

    test('无代理 runNow → false；快照无代理 → null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hub = container.read(claimSchedulerHubProvider.notifier);
      expect(await hub.runNow('none'), isFalse);
      expect(hub.snapshotOf('none'), isNull);
    });

    test('snapshotOf：代理存在时暴露冷却与启用态', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hub = container.read(claimSchedulerHubProvider.notifier);

      await hub.attach(device, ScriptedBridge(script: const []).bridge);
      final s = hub.snapshotOf('d1');
      expect(s, isNotNull);
      expect(s!.enabled, isFalse, reason: '默认关');
      expect(s.cooldownUntil, isNull);
      expect(s.roundInFlight, isFalse);
    });

    test('单层语义：agent 只看设备 enabled，无运行期全局门（attach 照跑）',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hub = container.read(claimSchedulerHubProvider.notifier);

      await hub.attach(device, ScriptedBridge(script: const []).bridge);
      hub.updateConfig('d1', const ClaimAutoConfig(enabled: true));
      final agent = container.read(claimSchedulerHubProvider)['d1']!;
      expect(agent.started, isTrue, reason: '设备开关开即跑');
      expect(agent.enabled, isTrue);

      hub.updateConfig('d1', const ClaimAutoConfig(enabled: false));
      expect(agent.started, isFalse, reason: '设备开关关即停');

      hub.detach('d1');
    });
  });
}
