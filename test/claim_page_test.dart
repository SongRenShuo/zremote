import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/claim.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/claim_scheduler.dart';
import 'package:zremote/services/service_probe.dart';
import 'package:zremote/state/claim_config.dart';
import 'package:zremote/state/claim_entry.dart';
import 'package:zremote/state/claim_history.dart';
import 'package:zremote/state/session_status.dart';
import 'package:zremote/ui/claim_page.dart';
import 'package:zremote/ui/claim_ticket_dialog.dart';
import 'package:zremote/ui/tactile_button.dart';
import 'package:zremote/ui/session_view.dart'
    show ClaimEntryButton;
import 'package:zremote/theme.dart';

import 'scripted_bridge.dart';

void main() {
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
      {
        'showName': 'GLM-4.6',
        'units': 300000000,
        'unitType': 'token',
        'meter': 'model_usage',
      },
      {
        'showName': 'GLM-4.6',
        'grantUnits': 60000000,
        'unitType': 'token',
        'period': 'daily',
      },
    ],
  };

  Map<String, dynamic> previewsResponse(List<Map<String, dynamic>> plans) =>
      {'serverTime': 1780000000000, 'plans': plans};

  const configJson = {
    'enabled': true,
    'region': 'cn',
    'prefix': 'p',
    'sceneId': 's',
  };
  const verifyOk = {'ok': true, 'param': 'vp'};
  const outcomeOk = {
    'success': true,
    'serverTime': 1780000000000,
    'startsAt': 1779900000,
    'endsAt': 1790000000,
  };

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required ScriptedBridge bridge,
    SessionStatus status = SessionStatus.live,
    VoidCallback? onDiagnosticsPressed,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionStatusProvider.notifier).report('d1', status);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ClaimPage(
            device: device,
            bridge: bridge.bridge,
            onDiagnosticsPressed: onDiagnosticsPressed,
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('1. 空 plans：空态 + 歧义副文案，不闪卡片', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([])],
    ]);
    await pumpPage(tester, bridge: bridge);
    expect(find.text('暂无可领活动'), findsOneWidget);
    expect(find.textContaining('已领过'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('2. 非空 previews：hero 票面（名称/描述/大面额读数 + TOKENS）', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
    ]);
    await pumpPage(tester, bridge: bridge);
    expect(find.text('周末体验包'), findsOneWidget);
    expect(find.text('3 亿 Token 体验额度'), findsOneWidget);
    expect(find.text('300,000,000'), findsOneWidget);
    expect(find.text('TOKENS'), findsOneWidget);
    expect(find.text('领取'), findsOneWidget);
  });

  testWidgets('2b. 票面读数回归锁：字色 == ZT.dark.accent + 等宽字族', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
    ]);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(sessionStatusProvider.notifier)
        .report('d1', SessionStatus.live);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ZT.theme(Brightness.dark),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ClaimPage(device: device, bridge: bridge.bridge),
        ),
      ),
    );
    await tester.pump();

    final quota = tester.widget<Text>(find.text('300,000,000'));
    expect(quota.style?.color, ZT.dark.accent);
    expect(quota.style?.fontFamily, kMonoFamily);
  });

  testWidgets('3. 领取全链成功：params + busy 视觉锁 + 票券 + 关闭后刷新 + 入口回写', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson(id: 'plan-a'), planJson(id: 'plan-b')])],
      [configJson],
      [verifyOk],
      [outcomeOk],
      [previewsResponse([])],
    ]);
    final container = await pumpPage(tester, bridge: bridge);
    expect(bridge.commands, hasLength(1));

    await tester.tap(find.text('领取').first);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    final restored = tester.widget<TactileButton>(
      find.widgetWithText(TactileButton, '领取').first,
    );
    expect(restored.onPressed, isNotNull, reason: '成功后卡片不应残留禁用');
    expect(bridge.commands, hasLength(4));

    final request = requestOf(bridge.commands[3]);
    expect(request.channel, 'coding-plan-subscription');
    expect(request.method, 'claimManualPlan');
    expect(request.params, {
      'planId': 'plan-a',
      'captchaVerifyParam': 'vp',
      'captchaRegion': 'cn',
    });

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(find.text('周末体验包 领取成功'), findsOneWidget);
    expect(find.textContaining('300,000,000'), findsNWidgets(3));
    expect(find.textContaining('Tokens'), findsWidgets);
    expect(find.text('GLM-4.6 3亿 Tokens'), findsOneWidget);
    expect(find.textContaining('每日'), findsOneWidget);
    expect(find.textContaining('有效期至'), findsOneWidget);
    expect(find.text('ZRemote'), findsOneWidget);
    expect(find.byIcon(Icons.replay), findsOneWidget);
    expect(find.byIcon(Icons.share), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);

    expect(bridge.commands, hasLength(4));

    await tester.tap(find.text('知道了'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(bridge.commands, hasLength(5));
    expect(requestOf(bridge.commands[4]).method, 'getManualClaimPlanPreviews');
    expect(find.text('暂无可领活动'), findsOneWidget);
    expect(container.read(claimEntryProvider)['d1'], false);
  });

  testWidgets('3c. 链路中段 busy 锁：config/verify 在途时 spinner + 其他卡禁用', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson(id: 'plan-a'), planJson(id: 'plan-b')])],
      [configJson],
    ]);
    await pumpPage(tester, bridge: bridge);
    await tester.tap(find.text('领取').first);
    await tester.pump();

    expect(bridge.commands, hasLength(3));
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    final other = tester.widget<TactileButton>(
      find.widgetWithText(TactileButton, '领取'),
    );
    expect(other.onPressed, isNull, reason: '中段其他卡应禁用（页级单飞）');

    await tester.pump(const Duration(seconds: 25));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('需要完成验证'), findsOneWidget);
  });

  testWidgets('3d. 刷新重试：no-services 瞬时 → 退避后成功（2026-09-13 复盘回归锁）',
      (tester) async {
    final bridge = ScriptedBridge(
      // 脚本按命令序号索引：0-2 为首试的主名+两别名（全部 no-services），
      // 3 为退避后重试的主名成功响应。
      script: [
        [], [], [],
        [previewsResponse([planJson()])],
      ],
      errors: {0: 'no-services', 1: 'no-services', 2: 'no-services'},
    );
    await pumpPage(tester, bridge: bridge);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(bridge.commands, hasLength(3));
    expect(bridge.commands[1]['s'], 'codingPlanService');
    expect(bridge.commands[2]['s'], 'subscriptionService');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('周末体验包'), findsOneWidget);
    expect(bridge.commands, hasLength(4));
  });

  testWidgets('3b. 入口显隐（rev 5）：report true → Badge 礼物图标；reset → 消失', (tester) async {    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ClaimEntryButton(deviceId: 'd1', onPressed: () {}),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('claim-entry-on')), findsNothing);

    container.read(claimEntryProvider.notifier).report('d1', true);
    await tester.pump(const Duration(milliseconds: 130));
    expect(find.byIcon(Icons.card_giftcard), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);

    container.read(claimEntryProvider.notifier).reset('d1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byIcon(Icons.card_giftcard), findsNothing);
    expect(find.byKey(const ValueKey('claim-entry-on')), findsNothing);
  });

  Future<void> pumpClaimChain(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('4. 1003 已领取：失败对话框（标题 + code 文案 + 知道了）', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
      [configJson],
      [verifyOk],
      const [
        {'success': false, 'code': 1003},
      ],
    ]);
    await pumpPage(tester, bridge: bridge);
    await tester.tap(find.text('领取'));
    await pumpClaimChain(tester);
    expect(find.text('领取失败'), findsOneWidget);
    expect(find.text('该套餐已经领取过'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
  });

  testWidgets('4b. 1005 同日：claimRetryAt + 当天人类时间（秒-ms 容错回归锁）', (tester) async {
    final now = DateTime.now();
    final laterToday = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1))
        .subtract(const Duration(minutes: 1));
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
      [configJson],
      [verifyOk],
      [
        {
          'success': false,
          'code': 1005,
          'failureEndsAt': laterToday.millisecondsSinceEpoch ~/ 1000,
        },
      ],
    ]);
    await pumpPage(tester, bridge: bridge);
    await tester.tap(find.text('领取'));
    await pumpClaimChain(tester);
    expect(find.text('今日领取名额已用完'), findsOneWidget);
    expect(find.textContaining('后可再试'), findsOneWidget);
    expect(find.textContaining(laterToday.year.toString()), findsOneWidget);
    expect(find.textContaining('1970'), findsNothing);
    expect(
      find.textContaining((laterToday.millisecondsSinceEpoch ~/ 1000).toString()),
      findsNothing,
    );
  });

  testWidgets('4b. 1005 跨日：claimRetryTomorrow', (tester) async {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day).add(
      const Duration(days: 1),
    );
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
      [configJson],
      [verifyOk],
      [
        {
          'success': false,
          'code': 1005,
          'failureEndsAt': tomorrow.millisecondsSinceEpoch ~/ 1000,
        },
      ],
    ]);
    await pumpPage(tester, bridge: bridge);
    await tester.tap(find.text('领取'));
    await pumpClaimChain(tester);
    expect(find.text('明日可再试'), findsOneWidget);
  });

  testWidgets('5. 无感失败：fallback 对话框含「返回」导航指引 + 无 claimManualPlan 派发', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
      [configJson],
      const [
        {'ok': false, 'reason': 'timeout'},
      ],
    ]);
    await pumpPage(tester, bridge: bridge);
    await tester.tap(find.text('领取'));
    await pumpClaimChain(tester);
    expect(find.text('需要完成验证'), findsOneWidget);
    expect(find.textContaining('返回'), findsOneWidget);
    expect(bridge.commands, hasLength(3));
    expect(
      [for (final c in bridge.commands) requestOf(c)]
          .where((r) => r.method == 'claimManualPlan'),
      isEmpty,
    );
  });

  testWidgets('6. enabled=false：无 verify 派发 + claimUnavailable SnackBar（官方同语义）', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
      const [
        {'enabled': false},
      ],
    ]);
    await pumpPage(tester, bridge: bridge);
    await tester.tap(find.text('领取'));
    await tester.pump();
    await tester.pump();
    expect(bridge.commands, hasLength(2));
    expect(
      [for (final c in bridge.commands) requestOf(c)]
          .where((r) => r.method == 'verify'),
      isEmpty,
    );
    expect(find.text('活动暂不可领'), findsOneWidget);
  });

  testWidgets('7. 离线禁用：卡片照常渲染，领取按钮 onPressed 为 null', (tester) async {
    final bridge = ScriptedBridge(script: [
      [previewsResponse([planJson()])],
    ]);
    await pumpPage(tester, bridge: bridge, status: SessionStatus.error);
    expect(find.text('周末体验包'), findsOneWidget);
    expect(find.textContaining('设备未就绪'), findsOneWidget);
    final button = tester.widget<TactileButton>(
      find.widgetWithText(TactileButton, '领取'),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('领取'));
    await tester.pump();
    expect(bridge.commands, hasLength(1));
  });

  final ticketPlan = ClaimPreview(
    planId: 'plan-a',
    name: '周末体验包',
    entitlements: [
      const ClaimEntitlement(
        showName: 'GLM-4.6',
        units: 300000000,
        unitType: 'token',
        meter: 'model_usage',
      ),
    ],
  );
  const ticketOutcome = ClaimOutcome(
    success: true,
    serverTime: 1780000000000,
  );

  Future<void> pumpTicket(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final c = child ?? const SizedBox.shrink();
          if (!disableAnimations) return c;
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: c,
          );
        },
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showClaimTicketDialog(
                  context,
                  plan: ticketPlan,
                  outcome: ticketOutcome,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  testWidgets('票券：入场动画结束态——金额/权益/打孔 CustomPaint/无分享', (tester) async {
    await pumpTicket(tester);
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    expect(find.textContaining('300,000,000'), findsOneWidget);
    expect(find.textContaining('3亿'), findsOneWidget);
    expect(find.textContaining('有效期至'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byIcon(Icons.replay), findsOneWidget);
    expect(find.byIcon(Icons.share), findsNothing);
    expect(find.text('ZRemote'), findsOneWidget);
  });

  testWidgets('票券：disableAnimations 静态直显（一帧即完成态，无入场动画）', (tester) async {
    await pumpTicket(tester, disableAnimations: true);
    await tester.pump();
    expect(find.textContaining('300,000,000'), findsOneWidget);
    expect(find.textContaining('周末体验包 领取成功'), findsOneWidget);
    expect(find.textContaining('已可使用'), findsOneWidget);
  });

  testWidgets('票券：点击左右半卡触发翻转（转完回正，金额仍在）', (tester) async {
    await pumpTicket(tester);
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    final cardCenter = tester.getCenter(find.textContaining('300,000,000'));
    await tester.tapAt(Offset(cardCenter.dx - 60, cardCenter.dy));
    await tester.pump(const Duration(milliseconds: 720));
    await tester.pump();
    expect(find.textContaining('300,000,000'), findsOneWidget);
    await tester.tapAt(Offset(cardCenter.dx + 60, cardCenter.dy));
    await tester.pump(const Duration(milliseconds: 720));
    await tester.pump();
    expect(find.textContaining('300,000,000'), findsOneWidget);
  });

  group('票券打孔几何常量链（评审 I#1 回归锁）', () {
    test('圆心距底恒 48px（官方 mask calc(100% - 48px)）', () {
      expect(
        ticketBottomPad +
            ticketValidityRow +
            ticketDividerGap +
            ticketHoleDiameter / 2,
        ticketHoleCenterFromBottom,
      );
    });

    test('gap 反推锚点 = 3（48 - 16 - 18 - 11）', () {
      expect(ticketDividerGap, 3.0);
    });

    test('bleed 同源 = 票面水平 padding 16', () {
      expect(ticketHPad, 16.0);
    });
  });
  testWidgets('业务错 manual_claim_preview_missing_data → 空态而非错误页（宿主实测）',
      (tester) async {
    final bridge = ScriptedBridge(
      script: const [[]],
      errors: {0: 'manual_claim_preview_missing_data'},
    );
    await pumpPage(tester, bridge: bridge);
    await tester.pump();

    expect(find.text('暂无可领活动'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
  });

  group('状态机矩阵：服务可用 × 有可领 × 无券 × 异常', () {
    testWidgets('空 plans：服务可用保持 true，只有「有可领」徽标变 false（不锁死入口）',
        (tester) async {
      final bridge = ScriptedBridge(script: [
        [previewsResponse([])],
      ]);
      final container = await pumpPage(tester, bridge: bridge);
      await tester.pump();

      expect(find.text('暂无可领活动'), findsOneWidget);
      expect(container.read(claimEntryProvider)['d1'], isFalse);
      expect(
        container.read(claimServiceProvider)['d1']?.available,
        isTrue,
        reason: '空数组是业务态，不得把服务可用置为不可用（缺陷根因回归锁）',
      );
      expect(container.read(claimServiceProvider)['d1']?.reason, isNull);
    });

    testWidgets('manual_claim_preview_missing_data：服务可用保持 true（不是服务故障）',
        (tester) async {
      final bridge = ScriptedBridge(
        script: const [[]],
        errors: {0: 'manual_claim_preview_missing_data'},
      );
      final container = await pumpPage(tester, bridge: bridge);
      await tester.pump();

      expect(container.read(claimServiceProvider)['d1']?.available, isTrue);
      expect(container.read(claimEntryProvider)['d1'], isFalse);
    });

    testWidgets('no-method：一次性结论不重试 + 服务不可用 + 原因文案 + 诊断入口',
        (tester) async {
      final bridge = ScriptedBridge(
        script: const [[]],
        errors: {0: 'no-method'},
      );
      var diagnostics = 0;
      final container = await pumpPage(
        tester,
        bridge: bridge,
        onDiagnosticsPressed: () => diagnostics++,
      );
      await tester.pump();

      expect(bridge.commands, hasLength(1), reason: 'no-method 不重试');
      expect(
        container.read(claimServiceProvider)['d1']?.available,
        isFalse,
      );
      expect(
        container.read(claimServiceProvider)['d1']?.reason,
        ClaimServiceProbe.reasonNoMethod,
      );
      // 服务不可用不回写「有可领」徽标。
      expect(container.read(claimEntryProvider)['d1'], isNull);
      expect(find.text('远端未提供领券服务，请升级远端后重试'), findsOneWidget);
      expect(find.byKey(const Key('claim-service-diagnostics')), findsOneWidget);

      await tester.tap(find.byKey(const Key('claim-service-diagnostics')));
      await tester.pump();
      expect(diagnostics, 1);
    });

    testWidgets('no-services 重试耗尽 → 服务不可用 + no-services 原因', (tester) async {
      final bridge = ScriptedBridge(
        script: const [],
        // 3 服务候选 × 3 次尝试，逐条喂 no-services。
        errors: {for (var i = 0; i < 9; i++) i: 'no-services'},
      );
      final container = await pumpPage(tester, bridge: bridge);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      // M2/L7：候选数 × 重试次数 = 3 服务候选 × 3 次尝试。
      expect(bridge.commands, hasLength(9), reason: 'no-services 仍按候选重试');
      expect(
        container.read(claimServiceProvider)['d1']?.reason,
        ClaimServiceProbe.reasonNoServices,
      );
      expect(find.text('远端领券服务未就绪，请确认已连接并进入会话'),
          findsOneWidget);
    });

    testWidgets('其它远端业务错：展示错误页但不污染服务可用态', (tester) async {
      final bridge = ScriptedBridge(
        script: const [[]],
        errors: {0: 'manual_claim_preview_denied'},
      );
      final container = await pumpPage(tester, bridge: bridge);
      await tester.pump();

      expect(container.read(claimServiceProvider)['d1'], isNull);
      expect(find.text('领取失败，请稍后重试'), findsOneWidget);
      expect(find.textContaining('连接诊断'), findsNothing);
    });
  });

  group('一键领取 + 立即执行（20261116-2341）', () {
    testWidgets('batch：两套餐串行领取成功 + 汇总 snack + 领到后刷新', (
      tester,
    ) async {
      final bridge = ScriptedBridge(script: [
        [previewsResponse([planJson(id: 'plan-a'), planJson(id: 'plan-b')])],
        [configJson],
        [verifyOk],
        [outcomeOk],
        [configJson],
        [verifyOk],
        [outcomeOk],
        [previewsResponse([])],
      ]);
      await pumpPage(tester, bridge: bridge);
      expect(find.byKey(const Key('claim-all-btn')), findsOneWidget);

      await tester.tap(find.byKey(const Key('claim-all-btn')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(requestOf(bridge.commands[3]).method, 'claimManualPlan');
      expect(requestOf(bridge.commands[3]).params, {
        'planId': 'plan-a',
        'captchaVerifyParam': 'vp',
        'captchaRegion': 'cn',
      });
      expect(requestOf(bridge.commands[6]).params, {
        'planId': 'plan-b',
        'captchaVerifyParam': 'vp',
        'captchaRegion': 'cn',
      });
      expect(find.textContaining('领取完成'), findsOneWidget);
      // 批量模式（Z2）不弹人工降级框/票据框。
      expect(find.text('需要完成验证'), findsNothing);
      expect(bridge.commands, hasLength(8), reason: '领到后刷新');
    });

    testWidgets('batch：第二个无感失败 → 不弹框记失败继续，汇总 成功1/失败1', (
      tester,
    ) async {
      final bridge = ScriptedBridge(script: [
        [previewsResponse([planJson(id: 'plan-a'), planJson(id: 'plan-b')])],
        [configJson],
        [verifyOk],
        [outcomeOk],
        [configJson],
        [{'ok': false, 'reason': 'timeout'}],
        [previewsResponse([planJson(id: 'plan-a')])],
      ]);
      await pumpPage(tester, bridge: bridge);

      await tester.tap(find.byKey(const Key('claim-all-btn')));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(bridge.commands, hasLength(7), reason: 'plan-b 无感失败后不发 claim');
      expect(find.textContaining('成功 1，失败 1'), findsOneWidget);
      expect(find.text('需要完成验证'), findsNothing, reason: 'Z2 静默降级');
    });

    testWidgets('run-now：开关开启后可见；无代理点击 → 拒绝 snack（门控）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final bridge = ScriptedBridge(script: [
        [previewsResponse([])],
      ]);
      final container = await pumpPage(tester, bridge: bridge);
      expect(find.byKey(const Key('claim-run-now-btn')), findsNothing);

      await container
          .read(claimConfigProvider.notifier)
          .setEnabled('d1', true);
      await tester.pump();
      expect(find.byKey(const Key('claim-run-now-btn')), findsOneWidget);

      // 会话未挂桥（hub 无代理）→ runNow 拒绝并给出提示。
      await tester.tap(find.byKey(const Key('claim-run-now-btn')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('无法立即执行'), findsOneWidget);
    });

    testWidgets('阻断记录渲染：历史 tab 阻断文案 + 详情 + 自动徽章', (tester) async {
      final bridge = ScriptedBridge(script: [
        [previewsResponse([])],
      ]);
      final container = await pumpPage(tester, bridge: bridge);
      container.read(claimHistoryProvider.notifier).record(
            'd1',
            success: false,
            source: ClaimRecordSource.auto,
            blockedReason: ClaimBlockedReason.previewError,
            message: 'boom detail',
          );
      await tester.tap(find.text('历史'));
      await tester.pump();

      expect(find.text('自动轮被阻断：可领列表获取失败'), findsOneWidget);
      expect(find.text('boom detail'), findsOneWidget);
      expect(find.text('自动'), findsOneWidget);
    });

    testWidgets('单层语义：设备开关独立控制「立即执行」显示（无全局提示）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final bridge = ScriptedBridge(script: [
        [previewsResponse([])],
      ]);
      final container = await pumpPage(tester, bridge: bridge);
      // 设备开关关 → 无立即执行行。
      expect(find.byKey(const Key('claim-run-now-btn')), findsNothing);

      await container
          .read(claimConfigProvider.notifier)
          .setEnabled('d1', true);
      await tester.pump();
      expect(find.byKey(const Key('claim-run-now-btn')), findsOneWidget);
      // 全局提示层已移除（单层语义）。
      expect(find.byKey(const Key('claim-global-off-hint')), findsNothing);
    });
  });
}
