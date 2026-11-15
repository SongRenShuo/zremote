import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/git_overview.dart';

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

void main() {
  group('GitOverviewClient.fetchDetail 三来源聚合', () {
    test('summary + staged + unstaged + comparison + branches 一次取全', () async {
      final bridge = ScriptedBridge(
        script: const [_summary, _staged, _unstaged, _comparison, _branches],
      );
      final detail = await GitOverviewClient(bridge.bridge).fetchDetail('/ws');

      expect(detail.status, GitOverviewStatus.ready);
      expect(detail.countOf(GitChangeSource.unstaged), 2);
      expect(detail.countOf(GitChangeSource.staged), 1);
      expect(detail.countOf(GitChangeSource.branch), 1);
      // 顶部脏数不含分支对比。
      expect(detail.dirtyCount, 3);
      // 组内按 workspaceRelativePath 字典序（b 在 c 前）。
      expect(
        detail.changesOf(GitChangeSource.unstaged).map((c) => c.displayPath),
        ['b.dart', 'c.dart'],
      );
      // numstat 行字段。
      final staged = detail.changesOf(GitChangeSource.staged).single;
      expect(staged.added, 3);
      expect(staged.removed, 1);
      expect(staged.kind, GitChangeKind.modified);
      final untracked = detail
          .changesOf(GitChangeSource.unstaged)
          .firstWhere((c) => c.displayPath == 'b.dart');
      expect(untracked.kind, GitChangeKind.added);
      expect(untracked.isUntracked, isTrue);
      // 分支对比元信息与变更。
      expect(detail.comparison, isNotNull);
      expect(detail.comparison!.baseRef, 'origin/main');
      expect(detail.comparison!.comparisonLabel, 'feat/v2 -> origin/main');
      final branchChange = detail.changesOf(GitChangeSource.branch).single;
      expect(branchChange.displayPath, 'z.dart');
      expect(branchChange.originalPath, 'old_z.dart');
      expect(branchChange.kind, GitChangeKind.renamed);
      expect(branchChange.group, 'branch');
      // 本地分支。
      expect(detail.branches.map((b) => b.name), ['main', 'feat/v2']);

      // 只读：五类取数命令，无写方法。
      final methods = bridge.commands.map((c) => c['m']).toList();
      expect(methods, [
        'getRepositorySummary',
        'getChanges',
        'getChanges',
        'getBranchComparison',
        'getLocalBranches',
      ]);
      expect(
        argsOf(bridge.commands[1]).first,
        {'workspacePath': '/ws', 'sourceId': 'staged'},
      );
    });

    test('形状漂移：缺 workspaceRelativePath 时回落 repoRelativePath/path', () async {
      final bridge = ScriptedBridge(script: const [
        _summary,
        [],
        [
          {
            'path': '/repo/legacy.dart',
            'repoRelativePath': 'legacy.dart',
            'added': 1,
            'removed': 0,
          },
        ],
        _comparison,
        _branches,
      ]);
      final detail = await GitOverviewClient(bridge.bridge).fetchDetail('/ws');
      final change = detail.changesOf(GitChangeSource.unstaged).single;
      expect(change.displayPath, 'legacy.dart');
      expect(change.kind, GitChangeKind.modified);
    });

    test('comparison 失败隔离：其余来源不受影响', () async {
      final bridge = ScriptedBridge(
        script: const [_summary, _staged, _unstaged, [], _branches],
        errors: {3: 'boom'},
      );
      final detail = await GitOverviewClient(bridge.bridge).fetchDetail('/ws');

      expect(detail.status, GitOverviewStatus.ready);
      expect(detail.comparisonFailed, isTrue);
      expect(detail.comparison, isNull);
      expect(detail.countOf(GitChangeSource.unstaged), 2);
      expect(detail.countOf(GitChangeSource.staged), 1);
      expect(detail.branches, isNotEmpty);
    });

    test('无上游：baseRef 空 + 空 changes，不算失败', () async {
      final bridge = ScriptedBridge(script: const [
        _summary,
        _staged,
        _unstaged,
        [
          {'baseRef': null, 'headRef': 'feat/v2', 'comparisonLabel': null, 'changes': []},
        ],
        _branches,
      ]);
      final detail = await GitOverviewClient(bridge.bridge).fetchDetail('/ws');
      expect(detail.comparisonFailed, isFalse);
      expect(detail.comparison, isNotNull);
      expect(detail.comparison!.hasUpstream, isFalse);
      expect(detail.countOf(GitChangeSource.branch), 0);
    });

    test('只读：所有命令方法都在读取白名单内', () async {
      final bridge = ScriptedBridge(
        script: const [_summary, _staged, _unstaged, _comparison, _branches],
      );
      final client = GitOverviewClient(bridge.bridge);
      await client.fetchDetail('/ws');
      await client.fetchDiff('/ws', 'a.dart', sourceId: 'staged');
      const readMethods = {
        'getRepositorySummary',
        'getChanges',
        'getDiff',
        'getLocalBranches',
        'getBranchComparison',
      };
      final methods = bridge.commands.map((c) => c['m']).toList();
      expect(methods.every(readMethods.contains), isTrue);
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
    });
  });

  group('GitChangeKind / GitChangeSource 解析', () {
    test('kind 别名兜底', () {
      expect(GitChangeKind.parse('added'), GitChangeKind.added);
      expect(GitChangeKind.parse('ADD'), GitChangeKind.added);
      expect(GitChangeKind.parse('a'), GitChangeKind.added);
      expect(GitChangeKind.parse('deleted'), GitChangeKind.deleted);
      expect(GitChangeKind.parse('renamed'), GitChangeKind.renamed);
      expect(GitChangeKind.parse('modified'), GitChangeKind.modified);
      expect(GitChangeKind.parse(null), GitChangeKind.modified);
      expect(GitChangeKind.parse('weird'), GitChangeKind.modified);
    });

    test('source 别名兜底', () {
      expect(GitChangeSource.parse('staged'), GitChangeSource.staged);
      expect(GitChangeSource.parse('branch'), GitChangeSource.branch);
      expect(GitChangeSource.parse('unstaged'), GitChangeSource.unstaged);
      expect(GitChangeSource.parse('last-turn'), GitChangeSource.unstaged);
      expect(GitChangeSource.parse(null), GitChangeSource.unstaged);
    });
  });

  group('parseGitDiff', () {
    test('file header / hunk 头 / 增删行分类与计数', () {
      const patch = 'diff --git a/a.dart b/a.dart\n'
          '@@ -1,2 +1,3 @@\n'
          ' context\n'
          '-old\n'
          '+new\n'
          '+added\n'
          '\\ No newline at end of file\n';
      final doc = parseGitDiff(patch);
      expect(doc.preamble, hasLength(1));
      expect(doc.hunks, hasLength(1));
      final hunk = doc.hunks.single;
      expect(hunk.header, '@@ -1,2 +1,3 @@');
      expect(hunk.oldStart, 1);
      expect(hunk.newStart, 1);
      expect(hunk.addedCount, 2);
      expect(hunk.removedCount, 1);
      expect(hunk.lines.first.type, GitDiffLineType.context);
      expect(hunk.lines.last.type, GitDiffLineType.note);
      expect(doc.lineCount, 7);
    });

    test('多 hunk 起始行号各自解析', () {
      const patch = '@@ -1 +1 @@\n-a\n+b\n@@ -10,2 +10,2 @@\n c\n-d\n+e\n';
      final doc = parseGitDiff(patch);
      expect(doc.hunks, hasLength(2));
      expect(doc.hunks[0].oldStart, 1);
      expect(doc.hunks[0].newStart, 1);
      expect(doc.hunks[1].oldStart, 10);
      expect(doc.hunks[1].newStart, 10);
      expect(doc.hunks[1].addedCount, 1);
      expect(doc.hunks[1].removedCount, 1);
    });

    test('空补丁 → 空文档', () {
      final doc = parseGitDiff('');
      expect(doc.isEmpty, isTrue);
      expect(doc.hunks, isEmpty);
    });
  });
}
