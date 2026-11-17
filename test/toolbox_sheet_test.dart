import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/service_probe.dart';
import 'package:zremote/state/claim_entry.dart';
import 'package:zremote/state/claim_history.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/service_readiness.dart';
import 'package:zremote/ui/toolbox_sheet.dart';

void main() {
  final device = RemoteDevice(
    id: 'd1',
    baseUrl: 'https://relay.example.com',
    params: const {'sid': 'd_test0001', 'app_version': '3.16.1'},
    label: '测试机',
    createdAt: DateTime(2026, 10, 19),
  );

  Future<void> pumpSheet(
    WidgetTester tester,
    ProviderContainer container, {
    VoidCallback? onAssetsPressed,
    VoidCallback? onDesktopSettingsPressed,
  }) async {
    // 工具箱内容较高：抬升测试视口避免「更多」按钮落在 600px 视口外。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolboxSheet(
                device: device,
                onAutomationPressed: () {},
                onClaimPressed: () {},
                onUsagePressed: () {},
                onModelSettingsPressed: () {},
                onAssetsPressed: onAssetsPressed,
                onDesktopSettingsPressed: onDesktopSettingsPressed,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('unavailable 显示就绪提示，转 ready 后消失', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(serviceReadinessProvider.notifier)
        .report('d1', ServiceReadiness.unavailable);

    await pumpSheet(tester, container);
    expect(find.text('请先在网页中选择电脑并进入会话'), findsOneWidget);

    container
        .read(serviceReadinessProvider.notifier)
        .report('d1', ServiceReadiness.ready);
    await tester.pump();
    expect(find.text('请先在网页中选择电脑并进入会话'), findsNothing);
  });

  testWidgets('unknown 不显示提示（legacy 首连行为不变）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpSheet(tester, container);
    expect(find.text('请先在网页中选择电脑并进入会话'), findsNothing);
  });

  testWidgets('三张常驻卡保持可点（点按走复查，不因提示锁死）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(serviceReadinessProvider.notifier)
        .report('d1', ServiceReadiness.unavailable);
    await pumpSheet(tester, container);

    InkWell inkFor(String title) => tester.widget<InkWell>(
      find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first,
    );
    expect(inkFor('模型设置').onTap, isNotNull);
    expect(inkFor('用量统计').onTap, isNotNull);
    expect(inkFor('自动化调度').onTap, isNotNull);
    // 能力态未探测（unknown）不按不可用处理：入口仍可点，由页面给结论。
    expect(inkFor('权益中心').onTap, isNotNull);
  });

  group('权益中心：enabled 只看「服务可用」，徽标只看「有可领/今日已领」', () {
    InkWell claimInk(WidgetTester tester) => tester.widget<InkWell>(
      find.ancestor(
        of: find.text('权益中心'),
        matching: find.byType(InkWell),
      ).first,
    );

    testWidgets('服务可用 + 有可领 → 可点 + 「有可领」徽标', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(claimServiceProvider.notifier).mark('d1', true);
      container.read(claimEntryProvider.notifier).report('d1', true);
      await pumpSheet(tester, container);

      expect(claimInk(tester).onTap, isNotNull);
      expect(find.text('有可领'), findsOneWidget);
    });

    testWidgets('回归锁：report(false)（无券）不锁死入口，徽标转「今日已领」',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(claimServiceProvider.notifier).mark('d1', true);
      container.read(claimEntryProvider.notifier).report('d1', false);
      container
          .read(claimHistoryProvider.notifier)
          .record('d1', planId: 'a', success: true);
      await pumpSheet(tester, container);

      // 本次修复的根因：旧实现 enabled=claimReady，空 plans 一回写就永灰。
      expect(claimInk(tester).onTap, isNotNull);
      expect(find.text('今日已领 1'), findsOneWidget);
      expect(find.text('有可领'), findsNothing);
    });

    testWidgets('服务不可用（no-method）→ 置灰 + 副标题给原因', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(claimServiceProvider.notifier)
          .mark('d1', false, reason: ClaimServiceProbe.reasonNoMethod);
      container.read(claimEntryProvider.notifier).report('d1', true);
      await pumpSheet(tester, container);

      expect(claimInk(tester).onTap, isNull);
      expect(find.text('远端未提供领券服务，请升级远端后重试'), findsOneWidget);
      // 徽标仍在（业务态独立），只是不可点。
      expect(find.text('有可领'), findsOneWidget);
    });

    testWidgets('服务不可用（probe-failed）→ 置灰 + 通用原因文案', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(claimServiceProvider.notifier)
          .mark('d1', false, reason: ClaimServiceProbe.reasonProbeFailed);
      await pumpSheet(tester, container);

      expect(claimInk(tester).onTap, isNull);
      expect(find.text('领券服务状态未能确认，可稍候重试'), findsOneWidget);
    });

    testWidgets('服务恢复可用 → 卡片重新可点（不被一次结论锁死）', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final service = container.read(claimServiceProvider.notifier);
      service.mark('d1', false, reason: ClaimServiceProbe.reasonNoServices);
      await pumpSheet(tester, container);
      expect(claimInk(tester).onTap, isNull);

      service.mark('d1', true);
      await tester.pumpAndSettle();
      expect(claimInk(tester).onTap, isNotNull);
      expect(find.text('活动礼包与算力领取'), findsOneWidget);
    });
  });

  testWidgets('P1-2/P1-3：额度中心与福利中心入口卡（回调缺省置灰）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpSheet(tester, container);

    // 未接线（回调 null）时渲染但置灰
    final quotaCard = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('quota-toolbox-entry')),
        matching: find.byType(InkWell),
      ),
    );
    expect(quotaCard.onTap, isNull);
    expect(find.text('额度中心'), findsOneWidget);
    expect(find.text('福利中心'), findsOneWidget);

    // 接线后可点，点按先关面板再触发回调
    var quotaTaps = 0;
    var rewardsTaps = 0;
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
              onQuotaPressed: () => quotaTaps++,
              onRewardsPressed: () => rewardsTaps++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('quota-toolbox-entry')));
    await tester.pumpAndSettle();
    expect(quotaTaps, 1);
    expect(rewardsTaps, 0);
  });

  group('P1-9 信息架构：分组 / 搜索 / 折叠', () {
    testWidgets('四分组标签渲染，新增桌面设置入口接线可点', (tester) async {
      var desktopTaps = 0;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(
        tester,
        container,
        onDesktopSettingsPressed: () => desktopTaps++,
      );

      expect(find.text('会话操作'), findsOneWidget);
      expect(find.text('账号与套餐'), findsOneWidget);
      expect(find.text('桌面设置'), findsOneWidget);
      // 折叠态资产组整组隐藏，展开后标签与入口齐现。
      expect(find.text('资产'), findsNothing);
      await tester.tap(find.byKey(const Key('toolbox-more')));
      await tester.pumpAndSettle();
      expect(find.text('资产'), findsOneWidget);
      expect(find.text('资产浏览'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toolbox-entry-desktop-settings')));
      await tester.pumpAndSettle();
      expect(desktopTaps, 1);
    });

    testWidgets('≥8 入口默认折叠：资产组藏进「更多」，展开后可见', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container, onAssetsPressed: () {});

      // 折叠态：资产浏览与 Git 卡不可见，「更多」按钮在。
      expect(find.byKey(const Key('toolbox-more')), findsOneWidget);
      expect(find.text('资产浏览'), findsNothing);
      expect(find.byKey(const Key('git-overview-card')), findsNothing);
      // 高优先组完整可见（含领取就绪徽章位）。
      expect(find.text('权益中心'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toolbox-more')));
      await tester.pumpAndSettle();
      expect(find.text('资产浏览'), findsOneWidget);
      expect(find.byKey(const Key('git-overview-card')), findsOneWidget);
      expect(find.byKey(const Key('toolbox-more')), findsNothing);
    });

    testWidgets('搜索本地过滤：命中显示全部匹配，无命中清空', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container, onAssetsPressed: () {});

      await tester.enterText(
        find.byKey(const Key('toolbox-search')),
        '资产',
      );
      await tester.pumpAndSettle();
      // 搜索态不折叠：资产浏览可见，其余入口被过滤。
      expect(find.text('资产浏览'), findsOneWidget);
      expect(find.text('模型设置'), findsNothing);
      expect(find.text('额度中心'), findsNothing);

      await tester.enterText(find.byKey(const Key('toolbox-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('资产浏览'), findsNothing);
      expect(find.text('模型设置'), findsNothing);
    });

    testWidgets('permPending 审批待办徽章（event_feed 驱动）', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container);
      expect(find.byKey(const Key('toolbox-perm-badge')), findsNothing);

      container
          .read(eventFeedProvider.notifier)
          .ingest('d1', const ObservedEvent(type: 'permission_request', taskId: 's1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toolbox-perm-badge')), findsOneWidget);
      expect(find.text('审批待办'), findsOneWidget);
    });
  });

  group('最近使用记忆（车道 F）', () {
    testWidgets('读取持久化最近使用 → 顶部独立组，原分组不再重复', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.toolbox.recent': ['usage', 'quota'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container, onAssetsPressed: () {});

      expect(find.text('最近使用'), findsOneWidget);
      final yRecent = tester.getTopLeft(find.text('最近使用')).dy;
      final ySessionOps = tester.getTopLeft(find.text('会话操作')).dy;
      expect(yRecent, lessThan(ySessionOps));

      // 入口只在最近组出现一次（从原分组移除）。
      expect(find.text('用量统计'), findsOneWidget);
      expect(find.text('额度中心'), findsOneWidget);
    });

    testWidgets('点按入口写入最近使用：前置 + 去重', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.toolbox.recent': ['model', 'usage'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container);

      await tester.tap(find.byKey(const Key('toolbox-entry-usage')));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('zremote.toolbox.recent'), ['usage', 'model']);
    });

    testWidgets('最近使用上限 4 条（旧的被挤掉）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.toolbox.recent': ['model', 'usage', 'automation', 'quota'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container, onDesktopSettingsPressed: () {});

      await tester.tap(
        find.byKey(const Key('toolbox-entry-desktop-settings')),
      );
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('zremote.toolbox.recent'), [
        'desktop-settings',
        'model',
        'usage',
        'automation',
      ]);
    });

    testWidgets('搜索态不显示最近使用组（结果按原分组）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.toolbox.recent': ['usage'],
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpSheet(tester, container);
      expect(find.text('最近使用'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('toolbox-search')), '模型');
      await tester.pumpAndSettle();

      expect(find.text('最近使用'), findsNothing);
      expect(find.text('模型设置'), findsOneWidget);
    });
  });
}
