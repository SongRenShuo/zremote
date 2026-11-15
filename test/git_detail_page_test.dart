import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/services/git_overview.dart';
import 'package:zremote/ui/git_detail_page.dart';
import 'package:zremote/ui/git_diff_page.dart';

import 'scripted_bridge.dart';

const _summary = [
  {
    'branchName': 'feat/v2',
    'ahead': 2,
    'behind': 1,
    'isDirty': true,
    'isRepository': true,
    'repoRoot': '/repo',
  },
];

const _staged = [
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
];

// 故意乱序：c 在前、b 在后，验证组内按 workspaceRelativePath 字典序。
const _unstaged = [
  {
    'path': '/repo/c.dart',
    'workspaceRelativePath': 'c.dart',
    'repoRelativePath': 'c.dart',
    'kind': 'modified',
    'section': 'unstaged',
    'added': 2,
    'removed': 0,
  },
  {
    'path': '/repo/b.dart',
    'workspaceRelativePath': 'b.dart',
    'repoRelativePath': 'b.dart',
    'kind': 'added',
    'section': 'untracked',
    'added': 10,
    'removed': 0,
    'isUntracked': true,
  },
];

const _comparison = [
  {
    'baseRef': 'origin/main',
    'headRef': 'feat/v2',
    'comparisonLabel': 'feat/v2 -> origin/main',
    'changes': [
      {
        'path': '/repo/z.dart',
        'workspaceRelativePath': 'z.dart',
        'repoRelativePath': 'z.dart',
        'kind': 'renamed',
        'section': 'branch',
        'originalPath': 'old_z.dart',
        'added': 1,
        'removed': 1,
      },
    ],
  },
];

const _branches = [
  {
    'currentBranchName': 'feat/v2',
    'branches': [
      {'name': 'main'},
      {'name': 'feat/v2', 'isCurrent': true},
    ],
  },
];

const _twoHunkPatch = 'diff --git a/c.dart b/c.dart\n'
    '@@ -1,2 +1,2 @@\n'
    ' context\n'
    '-old\n'
    '+new\n'
    '@@ -10,2 +10,2 @@\n'
    ' tail\n'
    '-remove\n'
    '+replace\n';

Widget wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<void> pumpDetail(
  WidgetTester tester,
  ScriptedBridge bridge,
) async {
  await tester.pumpWidget(
    wrap(GitDetailPage(
      client: GitOverviewClient(bridge.bridge),
      workspacePath: '/ws',
    )),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('来源分段计数 + 组内字典序 + numstat 行渲染', (tester) async {
    final bridge = ScriptedBridge(
      script: const [_summary, _staged, _unstaged, _comparison, _branches],
    );
    await pumpDetail(tester, bridge);

    // 三段计数（分段控件各带文件数）。
    expect(find.descendant(
      of: find.byKey(const Key('git-source-unstaged')),
      matching: find.text('2'),
    ), findsOneWidget);
    expect(find.descendant(
      of: find.byKey(const Key('git-source-staged')),
      matching: find.text('1'),
    ), findsOneWidget);
    expect(find.descendant(
      of: find.byKey(const Key('git-source-branch')),
      matching: find.text('1'),
    ), findsOneWidget);

    // 默认未暂存：组内按 workspaceRelativePath 排序（b 在 c 前）。
    final bDy = tester.getTopLeft(find.text('b.dart')).dy;
    final cDy = tester.getTopLeft(find.text('c.dart')).dy;
    expect(bDy, lessThan(cDy));
    expect(find.text('+10 −0'), findsOneWidget);
    expect(find.text('+2 −0'), findsOneWidget);

    // 切到已暂存：staged 文件与 numstat。
    await tester.tap(find.byKey(const Key('git-source-staged')));
    await tester.pumpAndSettle();
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('+3 −1'), findsOneWidget);
    expect(find.text('b.dart'), findsNothing);

    // 切到分支对比：comparison label + 变更文件。
    await tester.tap(find.byKey(const Key('git-source-branch')));
    await tester.pumpAndSettle();
    expect(find.text('对比 feat/v2 -> origin/main'), findsOneWidget);
    expect(find.text('z.dart'), findsOneWidget);
    expect(find.text('+1 −1'), findsOneWidget);
  });

  testWidgets('全屏 diff：行号 + 增删着色 + 按 hunk 折叠/展开', (tester) async {
    final bridge = ScriptedBridge(script: const [
      _summary,
      _staged,
      _unstaged,
      _comparison,
      _branches,
      [
        {
          'path': 'c.dart',
          'availability': 'patch',
          'patch': _twoHunkPatch,
        },
      ],
    ]);
    await pumpDetail(tester, bridge);

    await tester.tap(find.text('c.dart'));
    await tester.pumpAndSettle();

    // 全屏页 + 两个 hunk 头 + 增删行原文。
    expect(find.text('文件差异'), findsOneWidget);
    expect(find.text('@@ -1,2 +1,2 @@'), findsOneWidget);
    expect(find.text('@@ -10,2 +10,2 @@'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
    expect(find.text('-remove'), findsOneWidget);
    // 行号：第一个 hunk 起始 1/1。
    expect(find.text('1'), findsWidgets);

    // 折叠第一个 hunk → 其行隐藏，第二个 hunk 不受影响。
    await tester.tap(find.byKey(const Key('git-diff-hunk-0')));
    await tester.pumpAndSettle();
    expect(find.text('-old'), findsNothing);
    expect(find.text('-remove'), findsOneWidget);

    // 全部折叠 → 两个 hunk 的行都隐藏；再全部展开恢复。
    await tester.tap(find.byKey(const Key('git-diff-collapse-all')));
    await tester.pumpAndSettle();
    expect(find.text('-remove'), findsNothing);
    await tester.tap(find.byKey(const Key('git-diff-collapse-all')));
    await tester.pumpAndSettle();
    expect(find.text('-old'), findsOneWidget);
    expect(find.text('-remove'), findsOneWidget);
  });

  testWidgets('大文件降级：超阈值显示原始补丁，不渲染 hunk', (tester) async {
    final bigPatch = '@@ -1 +1 @@\n${'+x' * 70000}';
    final bridge = ScriptedBridge(script: [
      _summary,
      _staged,
      _unstaged,
      _comparison,
      _branches,
      [
        {
          'path': 'c.dart',
          'availability': 'patch',
          'patch': bigPatch,
        },
      ],
    ]);
    await pumpDetail(tester, bridge);
    await tester.tap(find.text('c.dart'));
    await tester.pumpAndSettle();

    expect(find.textContaining('原始补丁'), findsOneWidget);
    expect(find.text('@@ -1 +1 @@'), findsNothing);
    expect(find.byKey(const Key('git-diff-hunk-0')), findsNothing);
    expect(bigPatch.length, greaterThan(GitDiffPage.maxRenderChars));
  });

  testWidgets('comparison 失败隔离：分支段提示，其余来源不受影响', (tester) async {
    final bridge = ScriptedBridge(
      script: const [_summary, _staged, _unstaged, [], _branches],
      errors: {3: 'boom'},
    );
    await pumpDetail(tester, bridge);

    expect(find.text('b.dart'), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-source-branch')));
    await tester.pumpAndSettle();
    expect(find.text('无法获取分支对比'), findsOneWidget);
    expect(find.text('z.dart'), findsNothing);
  });

  testWidgets('只读：详情页与 diff 页只发读取方法', (tester) async {
    final bridge = ScriptedBridge(script: const [
      _summary,
      _staged,
      _unstaged,
      _comparison,
      _branches,
      [
        {
          'path': 'b.dart',
          'availability': 'patch',
          'patch': '@@ -1 +1 @@\n-old\n+new\n',
        },
      ],
    ]);
    await pumpDetail(tester, bridge);
    await tester.tap(find.text('b.dart'));
    await tester.pumpAndSettle();

    final methods = bridge.commands.map((c) => c['m']).toList();
    expect(methods, hasLength(6));
    expect(methods, everyElement(isIn(const [
      'getRepositorySummary',
      'getChanges',
      'getLocalBranches',
      'getBranchComparison',
      'getDiff',
    ])));
    for (final forbidden in const [
      'stagePaths',
      'unstagePaths',
      'discardPaths',
      'commit',
      'push',
      'switchBranch',
      'createBranchAndSwitch',
    ]) {
      expect(methods, isNot(contains(forbidden)));
    }
    // diff 取数带 sourceId（未暂存）。
    expect(
      (argsOf(bridge.commands[5]).first as Map)['sourceId'],
      'unstaged',
    );
  });
}
