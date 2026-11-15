import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/services/git_overview.dart';
import 'package:zremote/ui/git_card.dart';
import 'package:zremote/ui/git_detail_page.dart';

import 'scripted_bridge.dart';

void main() {
  testWidgets('P1-7 GitCard：分支/脏数/上下行渲染（scripted git 频道）',
      (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {
          'branchName': 'feat/v2',
          'ahead': 2,
          'behind': 1,
          'isDirty': true,
          'dirtyCount': 5,
          'isRepository': true,
        },
      ],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(
              client: GitOverviewClient(bridge.bridge),
              workspacePath: '/ws',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Git 概览'), findsOneWidget);
    expect(find.text('分支 feat/v2 · ↑2 ↓1'), findsOneWidget);
    expect(find.text('5 个改动'), findsOneWidget);
    expect(bridge.commands, hasLength(1));
    expect(bridge.commands.single['s'], 'gitService');
  });

  testWidgets('P1-7 GitCard：client 未接线 → 置灰不发包含提示', (tester) async {
    final bridge = ScriptedBridge(script: const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(workspacePath: '/ws'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.commands, isEmpty);
  });

  testWidgets('P1-7 GitCard：无会话（workspacePath 空）→ 不发包含提示',
      (tester) async {
    final bridge = ScriptedBridge(script: const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(client: GitOverviewClient(bridge.bridge)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('进入会话后显示当前工作区状态'), findsOneWidget);
    expect(bridge.commands, isEmpty);
  });

  testWidgets('P1-7 GitCard：失败原因可区分（loadFailed → 加载失败）',
      (tester) async {
    final bridge = ScriptedBridge(
      script: const [[]],
      errors: {0: 'no-services'},
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(
              client: GitOverviewClient(bridge.bridge),
              workspacePath: '/ws',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    expect(find.text('当前工作区不是 Git 仓库'), findsNothing);
    expect(bridge.commands, hasLength(1));
  });

  testWidgets('P1-7 GitCard：非仓库 → 副标题提示不是 Git 仓库', (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {'isRepository': false, 'isGitAvailable': true},
      ],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(
              client: GitOverviewClient(bridge.bridge),
              workspacePath: '/ws',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前工作区不是 Git 仓库'), findsOneWidget);
    expect(find.text('加载失败，点击重试'), findsNothing);
  });

  testWidgets('P1-7 GitCard：点击打开只读详情页', (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {
          'branchName': 'feat/v2',
          'isRepository': true,
          'isDirty': false,
        },
      ],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(
              client: GitOverviewClient(bridge.bridge),
              workspacePath: '/ws',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-overview-card')));
    await tester.pumpAndSettle();
    expect(find.text('Git 详情'), findsOneWidget);
  });

  testWidgets('P1 GitDetailPage：来源分段/分组/numstat/全屏 diff 只读渲染',
      (tester) async {
    final bridge = ScriptedBridge(script: const [
      // getRepositorySummary
      [
        {
          'branchName': 'feat/v2',
          'ahead': 2,
          'behind': 1,
          'isDirty': true,
          'isRepository': true,
          'repoRoot': '/repo',
        },
      ],
      // getChanges(staged)
      [
        {
          'path': '/repo/a.dart',
          'workspaceRelativePath': 'a.dart',
          'repoRelativePath': 'a.dart',
          'kind': 'modified',
          'section': 'staged',
          'added': 3,
          'removed': 1,
          'isStaged': true,
        },
      ],
      // getChanges(unstaged)
      [
        {
          'path': '/repo/b.dart',
          'workspaceRelativePath': 'b.dart',
          'repoRelativePath': 'b.dart',
          'kind': 'added',
          'section': 'untracked',
          'added': 10,
          'isUntracked': true,
        },
      ],
      // getBranchComparison（无上游：baseRef 空 + 空 changes）
      [
        {
          'baseRef': null,
          'headRef': 'feat/v2',
          'comparisonLabel': null,
          'changes': <Map<String, dynamic>>[],
        },
      ],
      // getLocalBranches
      [
        {
          'currentBranchName': 'feat/v2',
          'branches': [
            {'name': 'main'},
            {'name': 'feat/v2', 'isCurrent': true},
          ],
        },
      ],
      // getDiff(a.dart) 两个 hunk
      [
        {
          'path': 'a.dart',
          'availability': 'patch',
          'patch':
              'diff --git a/a.dart b/a.dart\n@@ -1,2 +1,3 @@\n context\n-old\n+new\n+added\n@@ -10,1 +10,1 @@\n-remove\n+replace\n',
        },
      ],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GitDetailPage(
          client: GitOverviewClient(bridge.bridge),
          workspacePath: '/ws',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Git 详情'), findsOneWidget);
    expect(find.text('分支 feat/v2'), findsOneWidget);
    expect(find.text('↑2 ↓1'), findsOneWidget);
    expect(find.text('本地分支'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feat/v2'), findsOneWidget);
    // 三来源分段。
    expect(find.byKey(const Key('git-source-unstaged')), findsOneWidget);
    expect(find.byKey(const Key('git-source-staged')), findsOneWidget);
    expect(find.byKey(const Key('git-source-branch')), findsOneWidget);
    // 默认未暂存来源。
    expect(find.text('未暂存'), findsOneWidget);
    expect(find.text('b.dart'), findsOneWidget);
    expect(find.text('+10 −0'), findsOneWidget);
    expect(find.text('a.dart'), findsNothing);
    expect(find.text('2 个改动'), findsOneWidget);
    // 只读：5 个取数命令，无写方法。
    expect(bridge.commands, hasLength(5));
    expect(bridge.commands[0]['m'], 'getRepositorySummary');
    expect(bridge.commands[1]['m'], 'getChanges');
    expect(bridge.commands[2]['m'], 'getChanges');
    expect(bridge.commands[3]['m'], 'getBranchComparison');
    expect(bridge.commands[4]['m'], 'getLocalBranches');

    // 切到已暂存 → 显示 staged 文件与 numstat。
    await tester.tap(find.byKey(const Key('git-source-staged')));
    await tester.pumpAndSettle();
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('+3 −1'), findsOneWidget);
    expect(find.text('b.dart'), findsNothing);

    // 点文件行 → 全屏 diff。
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('文件差异'), findsOneWidget);
    expect(find.textContaining('@@ -1,2 +1,3 @@'), findsOneWidget);
    expect(bridge.commands, hasLength(6));
    expect(bridge.commands[5]['m'], 'getDiff');
    final diffArgs = argsOf(bridge.commands[5]);
    expect((diffArgs.first as Map)['sourceId'], 'staged');
  });

  testWidgets('P1-7 GitDetailPage：无 workspace → 占位不发包', (tester) async {
    final bridge = ScriptedBridge(script: const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GitDetailPage(client: GitOverviewClient(bridge.bridge)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('进入会话后可用'), findsOneWidget);
    expect(bridge.commands, isEmpty);
  });
}
