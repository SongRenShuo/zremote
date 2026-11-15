import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/quota_client.dart';
import 'package:zremote/ui/quota_page.dart';

import 'scripted_bridge.dart';

/// 可编排的假 QuotaClient：widget 测试不触网不走 RPC。
class _FakeQuotaClient extends QuotaClient {
  _FakeQuotaClient({required this.overview, this.status})
      : super(bridge: ScriptedBridge().bridge);

  final QuotaOverview? overview;
  final ResetCardStatus? status;

  int fetchCount = 0;
  int loadParamsCount = 0;
  Map<String, dynamic>? lastEntitlementParams;
  int statusCount = 0;
  final List<String> usedTypes = [];
  ResetCardUseResult useResult = const ResetCardUseResult(
    success: true,
    message: '',
  );
  Object? fetchError;
  bool supported = true;

  @override
  Future<Map<String, dynamic>?> loadEntitlementParams() async {
    loadParamsCount++;
    return null;
  }

  @override
  Future<QuotaOverview> fetch({Map<String, dynamic>? entitlementParams}) async {
    fetchCount++;
    lastEntitlementParams = entitlementParams;
    final error = fetchError;
    if (error != null) throw error;
    return overview!;
  }

  @override
  Future<bool> resetCardSupported() async => supported;

  @override
  Future<ResetCardStatus> fetchResetCardStatus() async {
    statusCount++;
    return status!;
  }

  @override
  Future<ResetCardUseResult> useResetCard(String resetType) async {
    usedTypes.add(resetType);
    return useResult;
  }
}

QuotaOverview _twoPlanOverview() {
  final maxSlot = PlanSlot(
    pid: 'coding-max',
    tierCode: QuotaTierCode.max,
    tier: 'Max',
    name: 'GLM Coding Max',
    startsAt: DateTime(2026, 11, 1),
    endsAt: DateTime(2026, 12, 1),
    total: 3000,
    used: 1200,
    remaining: 1800,
    percentUsed: 40.0,
    items: [
      QuotaItem(
        name: 'TOKENS_LIMIT',
        kind: 'prompt_count',
        window: 'hours:5',
        total: 120,
        used: 30,
        percentUsed: 25.0,
      ),
      QuotaItem(
        name: 'Max 提示额度',
        remaining: 450,
        total: 600,
        unit: 'token',
        capabilities: const ['model:GLM-5.3', 'model:GLM-5.3-Flash'],
      ),
    ],
  );
  final liteSlot = PlanSlot(
    pid: 'lite-plan',
    tierCode: QuotaTierCode.lite,
    tier: 'Lite',
    name: 'Lite 套餐',
    endsAt: DateTime(2026, 11, 20),
    items: [
      QuotaItem(
        name: 'TIME_LIMIT',
        kind: 'duration',
        window: 'weekly',
        total: 600,
        used: 570,
        percentUsed: 95.0,
      ),
    ],
  );
  return mergeQuotaParts([
    QuotaOverview(
      plans: [maxSlot, liteSlot],
      items: [...maxSlot.items, ...liteSlot.items],
      refreshedAt: DateTime(2026, 11, 15, 10, 30),
      sources: const ['zai-billing'],
    ),
  ]);
}

/// 单槽总览：主槽 percentUsed=percent（预警条判档用）。
QuotaOverview _singleSlotOverview(double percent) {
  final slot = PlanSlot(
    pid: 'coding-max',
    tierCode: QuotaTierCode.max,
    tier: 'Max',
    name: 'GLM Coding Max',
    total: 100,
    used: percent,
    remaining: 100 - percent,
    percentUsed: percent,
    items: const [],
  );
  return QuotaOverview(
    plans: [slot],
    items: const [],
    refreshedAt: DateTime(2026, 11, 15, 10, 30),
    sources: const ['host-snapshot'],
    percentUsed: percent,
    remaining: 100 - percent,
  );
}

ResetCardStatus _resetStatus() => const ResetCardStatus(
  entries: [
    ResetCardEntry(
      resetType: 'FIVE_HOURS',
      available: 2,
      expiresAt: null,
    ),
  ],
  history: [
    ResetCardHistoryEntry(resetType: 'FIVE_HOURS', usedAt: null),
  ],
  hasUnreadHistory: true,
);

Future<_FakeQuotaClient> _pumpPage(
  WidgetTester tester, {
  QuotaOverview? overview,
  ResetCardStatus? status,
  bool supported = true,
  VoidCallback? onClaimPressed,
}) async {
  final device = RemoteDevice(
    id: 'd1',
    baseUrl: 'https://relay.example.com',
    params: const {'sid': 'd_test0001', 'app_version': '3.16.1'},
    label: '测试机',
    createdAt: DateTime(2026, 10, 19),
  );
  final fake = _FakeQuotaClient(
    overview: overview ?? _twoPlanOverview(),
    status: status ?? _resetStatus(),
  )..supported = supported;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: ProviderContainer(),
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: QuotaPage(
          device: device,
          bridge: fake.bridge,
          client: fake,
          onClaimPressed: onClaimPressed,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return fake;
}

/// ListView 懒构建：滚到目标 finder 可见（重置卡区块在折叠线以下）。
Future<void> _scrollTo(WidgetTester tester, Finder finder) {
  return tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  testWidgets('多套餐分组渲染：tier 徽章/有效期/窗口条/模型余额行', (tester) async {
    await _pumpPage(tester);

    expect(find.byKey(const Key('quota-summary-card')), findsOneWidget);
    expect(find.byKey(const Key('quota-slot-0')), findsOneWidget);

    // tier 徽章：Max 主槽徽章可见；Lite 分组卡滚动后可见
    expect(find.text('Max'), findsWidgets);

    // 套餐名与有效期
    expect(find.text('GLM Coding Max'), findsWidgets);
    expect(find.textContaining('有效期'), findsWidgets);

    // 窗口条：每 5 小时（提示次数）——汇总卡主指标 + Max 分组卡各一次
    expect(find.textContaining('每 5 小时'), findsNWidgets(2));

    // 模型余额行：show_name + capabilities 前缀 + remaining/total
    expect(find.text('模型余额'), findsOneWidget);
    expect(find.text('Max 提示额度'), findsOneWidget);
    expect(find.text('GLM-5.3 · GLM-5.3-Flash'), findsOneWidget);
    expect(find.text('450 / 600'), findsOneWidget);

    // 数据来源标注（直连）+ 最后同步
    expect(find.text('直连'), findsOneWidget);
    expect(find.textContaining('最后同步'), findsOneWidget);

    // Lite 分组卡在折叠线以下：滚动后断言
    await _scrollTo(tester, find.text('Lite'));
    expect(find.byKey(const Key('quota-slot-1')), findsOneWidget);
    expect(find.textContaining('每周'), findsOneWidget);
  });

  testWidgets('汇总卡：主指标剩余百分比 + 槽卡进度文本', (tester) async {
    await _pumpPage(tester);
    // Max 槽 percentUsed=40 → 剩余 60%
    expect(find.text('剩余 60%'), findsOneWidget);
    // Max 5h 窗口剩余 75% —— 汇总卡主指标 + Max 分组卡各一次
    expect(find.text('75%'), findsNWidgets(2));

    // Lite weekly 窗口 percentUsed=95 → 剩余 5.0%（<10 保留一位）
    await _scrollTo(tester, find.text('5.0%'));
    expect(find.text('5.0%'), findsOneWidget);
  });

  testWidgets('重置卡区块：状态 + 使用确认弹窗 + 结果反馈', (tester) async {
    final fake = await _pumpPage(tester);

    await _scrollTo(tester, find.byKey(const Key('quota-reset-card')));
    expect(find.byKey(const Key('quota-reset-card')), findsOneWidget);
    expect(find.text('重置卡'), findsOneWidget);
    expect(find.text('5 小时重置卡'), findsOneWidget);
    expect(find.text('可用 2 张'), findsOneWidget);
    expect(find.text('有新记录'), findsOneWidget);
    expect(find.text('最近使用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('quota-reset-use-FIVE_HOURS')));
    await tester.pumpAndSettle();

    expect(find.text('使用重置卡'), findsOneWidget, reason: '确认弹窗标题');
    expect(find.textContaining('5 小时重置卡'), findsWidgets,
        reason: '弹窗正文点名卡种');
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.byKey(const Key('quota-reset-confirm')));
    await tester.pumpAndSettle();

    expect(fake.usedTypes, ['FIVE_HOURS']);
    expect(find.text('重置卡已使用'), findsOneWidget);
    expect(fake.fetchCount, greaterThan(1), reason: '使用成功后回读刷新');
  });

  testWidgets('重置卡限流 3301：确认后弹限流对话框与重试时间', (tester) async {
    final fake = await _pumpPage(tester);
    fake.useResult = ResetCardUseResult(
      success: false,
      message: 'too frequent',
      rateLimited: true,
      nextTryAt: DateTime(2026, 11, 15, 12, 0),
    );

    await _scrollTo(tester, find.byKey(const Key('quota-reset-use-FIVE_HOURS')));
    await tester.tap(find.byKey(const Key('quota-reset-use-FIVE_HOURS')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quota-reset-confirm')));
    await tester.pumpAndSettle();

    expect(fake.usedTypes, ['FIVE_HOURS']);
    expect(find.text('操作过于频繁'), findsOneWidget);
    expect(find.textContaining('可再试'), findsOneWidget);
    expect(find.text('重置卡已使用'), findsNothing);
  });

  testWidgets('宿主无重置卡方法（no-method）→ 区块隐藏', (tester) async {
    // M3：探针结果随页面 State 缓存，须独立 pump 新页面验证。
    await _pumpPage(tester, supported: false);
    expect(find.byKey(const Key('quota-summary-card')), findsOneWidget,
        reason: '额度主数据不受重置卡缺位影响');
    // 连续滚到列表底，确认整页不出现重置卡区块
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quota-reset-card')), findsNothing);
  });

  testWidgets('加载失败：错误视图 + 重试恢复', (tester) async {
    final fake = await _pumpPage(tester);
    fake.fetchError = const QuotaFetchException('usage-stats: boom');
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('额度数据加载失败'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);

    fake.fetchError = null;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quota-summary-card')), findsOneWidget);
  });

  testWidgets('未配置/未登录空态：登录引导而非「加载失败」', (tester) async {
    await _pumpPage(
      tester,
      overview: QuotaOverview(
        plans: const [],
        items: const [],
        refreshedAt: DateTime(2026, 11, 15),
        sources: const [],
        notConfigured: true,
      ),
      status: const ResetCardStatus(entries: [], history: []),
      supported: false,
    );
    expect(find.text('登录后查看额度'), findsOneWidget);
    expect(find.textContaining('尚未登录'), findsOneWidget);
    expect(find.text('额度数据加载失败'), findsNothing);
    expect(find.byKey(const Key('quota-slot-0')), findsNothing);
  });

  testWidgets('刷新链路：先取 providerSettings 参数再拉额度（accountAccess）', (
    tester,
  ) async {
    final fake = await _pumpPage(tester);
    expect(fake.loadParamsCount, greaterThan(0));
    expect(fake.fetchCount, greaterThan(0));
    expect(fake.lastEntitlementParams, isNull, reason: '假 client 不返回参数');
  });

  testWidgets('无套餐空态（noPlan）', (tester) async {
    await _pumpPage(
      tester,
      overview: QuotaOverview(
        plans: const [],
        items: const [],
        refreshedAt: DateTime(2026, 11, 15),
        sources: const [],
        noPlan: true,
      ),
      status: const ResetCardStatus(entries: [], history: []),
      supported: false,
    );
    expect(find.text('当前账号暂无生效套餐'), findsOneWidget);
    expect(find.byKey(const Key('quota-slot-0')), findsNothing);
  });

  testWidgets('预警条：默认 40% 不显示（未达阈值）', (tester) async {
    await _pumpPage(tester);
    expect(find.byKey(const Key('quota-alert-banner')), findsNothing);
    expect(find.byKey(const Key('quota-alert-claim')), findsNothing);
  });

  testWidgets('预警条：85% 显示黄条与用量文案', (tester) async {
    await _pumpPage(tester, overview: _singleSlotOverview(85));
    expect(find.byKey(const Key('quota-alert-banner')), findsOneWidget);
    expect(find.textContaining('85%'), findsWidgets);
    expect(find.textContaining('GLM Coding Max'), findsWidgets);
    expect(find.byKey(const Key('quota-alert-claim')), findsNothing,
        reason: '未耗尽不给「去领取」');
  });

  testWidgets('预警条：耗尽红条 + 「去领取」回调', (tester) async {
    var claimed = 0;
    await _pumpPage(
      tester,
      overview: _singleSlotOverview(100),
      onClaimPressed: () => claimed++,
    );
    expect(find.byKey(const Key('quota-alert-banner')), findsOneWidget);
    expect(find.text('额度已耗尽，需领取或等待重置'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quota-alert-claim')));
    await tester.pumpAndSettle();
    expect(claimed, 1);
  });
}
