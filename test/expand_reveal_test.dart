import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/git_overview.dart';
import 'package:zremote/services/rpc_bridge.dart';
import 'package:zremote/services/rpc_dispatch.dart';
import 'package:zremote/state/service_readiness.dart';
import 'package:zremote/state/session_status.dart';
import 'package:zremote/ui/automation_page.dart';
import 'package:zremote/ui/bevel_card.dart';
import 'package:zremote/ui/session_panel.dart';
import 'package:zremote/ui/sheet_shell.dart';
import 'package:zremote/ui/toolbox_sheet.dart';

import 'scripted_bridge.dart';

/// 问题十八复现：折叠/限量列表展开「剩余部分」后，新出现的内容必须落在
/// 可视区内（不能依赖内容恰好不超高，也不能让用户再点一次/自己找）。
void main() {
  final device = RemoteDevice(
    id: 'd1',
    baseUrl: 'https://relay.example.com',
    params: const {'sid': 'd_test0001', 'app_version': '3.16.1'},
    label: '测试机',
    createdAt: DateTime(2026, 10, 19),
  );

  Future<void> pumpApp(
    WidgetTester tester,
    Size size,
    VoidCallback onOpen, {
    ProviderContainer? container,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final owned = container ?? ProviderContainer();
    if (container == null) addTearDown(owned.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: owned,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: onOpen,
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('工具箱「更多」展开', () {
    testWidgets('真机比例 411x914：展开后资产组与 Git 卡都落在可视区', (tester) async {
      // 真实态：未进会话时工具箱顶部多一条「请先在网页中选择电脑并进入会话」提示，
      // 新出现的剩余部分更容易跌出屏幕（修复前 Git 卡底边 931 > 914）。
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(serviceReadinessProvider.notifier)
          .report('d1', ServiceReadiness.unavailable);
      await pumpApp(tester, const Size(411, 914), () {
        final ctx = tester.state(find.byType(FilledButton)).context;
        showToolboxSheet(
          context: ctx,
          device: device,
          onAutomationPressed: () {},
          onClaimPressed: () {},
          onUsagePressed: () {},
          onModelSettingsPressed: () {},
          onAssetsPressed: () {},
          gitClient: _FakeGitClient(),
          workspacePath: r'J:\tmp\demo',
        );
      }, container: container);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // 折叠态：资产组与 Git 卡藏起，「更多」在。
      expect(find.byKey(const Key('toolbox-more')), findsOneWidget);
      expect(find.text('资产浏览'), findsNothing);
      expect(find.byKey(const Key('git-overview-card')), findsNothing);

      await tester.tap(find.byKey(const Key('toolbox-more')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final assets = find.text('资产浏览');
      final git = find.byKey(const Key('git-overview-card'));
      expect(assets, findsOneWidget);
      expect(git, findsOneWidget);
      // 新出现的「剩余部分」不得停在屏幕外（视口高 914）。
      expect(
        tester.getRect(assets).bottom,
        lessThanOrEqualTo(914),
        reason: '资产浏览出屏幕',
      );
      expect(
        tester.getRect(git).bottom,
        lessThanOrEqualTo(914),
        reason: 'Git 卡出屏幕',
      );
    });

    testWidgets('折叠态外观不回归：展开前仍只显示高优先组', (tester) async {
      await pumpApp(tester, const Size(411, 914), () {
        final ctx = tester.state(find.byType(FilledButton)).context;
        showToolboxSheet(
          context: ctx,
          device: device,
          onAutomationPressed: () {},
          onClaimPressed: () {},
          onUsagePressed: () {},
          onModelSettingsPressed: () {},
          onAssetsPressed: () {},
        );
      });
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('模型设置'), findsOneWidget);
      expect(find.text('权益中心'), findsOneWidget);
      expect(find.text('资产浏览'), findsNothing);
      expect(find.byKey(const Key('toolbox-more')), findsOneWidget);
    });
  });

  group('自动化「最近运行」展开', () {
    Map<String, dynamic> autoJson(String id) => {
      'automationId': id,
      'title': '定时-$id',
      'cronExpr': '0 9 * * *',
      'prompt': '定时回复 done',
      'workspacePath': r'J:\tmp\demo',
      'enabled': true,
      'recurring': true,
      'nextRunAt': DateTime(2026, 9, 5, 9, 0).millisecondsSinceEpoch,
      'runCount': 5,
    };

    Map<String, dynamic> runJson(String autoId, int i) => {
      'runId': '$autoId-r$i',
      'automationId': autoId,
      'outcome': i % 2 == 0 ? 'succeeded' : 'failed',
      'scheduledAt': DateTime(2026, 9, 4, 9, i).millisecondsSinceEpoch,
      'workspacePath': r'J:\tmp\demo',
    };

    Future<void> pumpPage(WidgetTester tester, Size size, int n) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final script = <List<Map<String, dynamic>>>[
        [],
        [for (var i = 0; i < n; i++) autoJson('a$i')],
        for (var i = 0; i < n; i++)
          [for (var j = 0; j < 5; j++) runJson('a$i', j)],
      ];
      final bridge = ScriptedBridge(script: script);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(sessionStatusProvider.notifier)
          .report('d1', SessionStatus.live);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AutomationPage(device: device, bridge: bridge.bridge),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('定时排程'));
      await tester.pumpAndSettle();
    }

    for (final size in const [Size(800, 1200), Size(411, 914)]) {
      testWidgets('${size.width}x${size.height}：展开最后一张计划卡的运行记录后整卡可见', (
        tester,
      ) async {
        await pumpPage(tester, size, 12);
        final card = find
            .ancestor(
              of: find.text('定时-a11'),
              matching: find.byType(BevelCard),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('定时-a11'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('最近运行').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('最近运行').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('收起运行'), findsOneWidget);
        expect(
          tester.getRect(card).bottom,
          lessThanOrEqualTo(size.height),
          reason: '展开的运行记录出屏幕',
        );
      });
    }

    testWidgets('折叠态不回归：未展开时不渲染运行记录', (tester) async {
      await pumpPage(tester, const Size(800, 1200), 3);
      expect(find.text('最近运行'), findsNWidgets(3));
      expect(find.text('收起运行'), findsNothing);
    });
  });

  group('会话面板（无折叠，回归锁）', () {
    testWidgets('120 会话经 showZrSheet(0.72) 最后一行可滚动到可见', (tester) async {
      await pumpApp(tester, const Size(411, 914), () {
        final ctx = tester.state(find.byType(FilledButton)).context;
        final sessions = List<SessionState>.generate(
          120,
          (i) => SessionState(
            sessionId: 's$i',
            title: '会话-$i',
            phase: 'running',
            lastActivityAt:
                DateTime.now().millisecondsSinceEpoch - i * 1000,
          ),
        );
        showZrSheet<void>(
          context: ctx,
          isScrollControlled: true,
          maxHeightFactor: 0.72,
          builder: (sheetContext) => SessionPanelSheet(
            sessions: sessions,
            onClose: () => Navigator.pop(sheetContext),
          ),
        );
      });
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final last = find.text('会话-119');
      await tester.scrollUntilVisible(
        last,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(914));
    });
  });
}

class _FakeDispatch implements RpcDispatch {
  @override
  int get port => 1;
  @override
  Future<void> start() async {}
  @override
  void push(Map<String, Object?> command) {}
  @override
  void dispose() {}
}

class _FakeGitClient extends GitOverviewClient {
  _FakeGitClient()
    : super(RpcBridge(deviceId: 'd1', dispatch: _FakeDispatch()));

  @override
  Future<GitOverview> fetch(String? workspacePath) async => GitOverview(
    workspacePath: workspacePath,
    branch: 'main',
    dirtyCount: 3,
    isDirty: true,
    ahead: 1,
    behind: 2,
  );
}
