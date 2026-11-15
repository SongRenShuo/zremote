import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/git_overview.dart';
import 'package:zremote/services/task_actions.dart';

import 'scripted_bridge.dart';

void main() {
  group('P1-4 zcode-task 频道（scripted_bridge，L7：单候选一次成形）', () {
    test('respondPermission happy：命令形态与受理语义', () async {
      final bridge = ScriptedBridge(script: const [
        [{}],
      ]);
      final client = TaskActionsClient(bridge.bridge);
      final ok = await client.respondPermission(
        taskId: 't1',
        requestId: 'r1',
        optionId: 'allow',
        response: const {'decision': 'allow'},
      );
      expect(ok, isTrue);
      // 单候选：no-services 不触发别名轮询，命令数恒为 1。
      expect(bridge.commands, hasLength(1));
      final req = requestOf(bridge.commands.single);
      expect(req.channel, 'zcode-task');
      expect(req.method, 'respondPermission');
      expect(req.params, {
        'taskId': 't1',
        'requestId': 'r1',
        'optionId': 'allow',
        'response': {'decision': 'allow'},
      });
    });

    test('respondElicitation happy：accept/decline 参数形状', () async {
      final bridge = ScriptedBridge(script: const [
        [{}],
      ]);
      final client = TaskActionsClient(bridge.bridge);
      final ok = await client.respondElicitation(
        taskId: 't2',
        requestId: 'r2',
        action: 'decline',
      );
      expect(ok, isTrue);
      final req = requestOf(bridge.commands.single);
      expect(req.method, 'respondElicitation');
      expect(req.params, {
        'taskId': 't2',
        'requestId': 'r2',
        'action': 'decline',
        // content 为 null 时省略（null-aware 元素）。
      });
    });

    test('stopGeneration happy + workspacePath 透传', () async {
      final bridge = ScriptedBridge(script: const [
        [],
      ]);
      final client = TaskActionsClient(bridge.bridge);
      final ok = await client.stopGeneration(taskId: 't3', workspacePath: '/w');
      expect(ok, isTrue);
      final req = requestOf(bridge.commands.single);
      expect(req.method, 'stopGeneration');
      expect(req.params, {'taskId': 't3', 'workspacePath': '/w'});
    });

    test('no-services 降级：受理失败不换别名，命令数仍 1', () async {
      final bridge = ScriptedBridge(script: const [
        [],
      ], errors: {0: 'no-services'});
      final client = TaskActionsClient(bridge.bridge);
      final ok = await client.stopGeneration(taskId: 't4');
      expect(ok, isFalse);
      expect(bridge.commands, hasLength(1));
      expect(bridge.commands.single['s'], 'zcodeTaskService');
    });
  });

  group('P1-4 payload 解析纯函数', () {
    test('perm:<deviceId>:<taskId> 解析', () {
      final parsed = TaskActionsClient.parsePermPayload('perm:d-uuid:t-123');
      expect(parsed!.deviceId, 'd-uuid');
      expect(parsed.taskId, 't-123');
    });

    test('taskId 含冒号：首段 deviceId、其余归 taskId', () {
      final parsed = TaskActionsClient.parsePermPayload('perm:dev:task:a:b');
      expect(parsed!.deviceId, 'dev');
      expect(parsed.taskId, 'task:a:b');
    });

    test('非 perm 前缀 / 段数不足 → null', () {
      expect(TaskActionsClient.parsePermPayload('claim:d1'), isNull);
      expect(TaskActionsClient.parsePermPayload('perm:onlydevice'), isNull);
      expect(TaskActionsClient.parsePermPayload('perm::t1'), isNull);
      expect(TaskActionsClient.parsePermPayload('perm:d1:'), isNull);
    });
  });

  group('P1-4 选项挑选（开源版 permissionWorkflowSettings 同族规则）', () {
    const options = [
      ApprovalOption(
        optionId: 'allow-once',
        kind: 'allow_once',
        name: 'Allow once',
        response: {'decision': 'allow'},
      ),
      ApprovalOption(
        optionId: 'allow-always',
        kind: 'allow_always',
        name: 'Always allow',
        response: {'decision': 'allow', 'permissionUpdates': []},
      ),
      ApprovalOption(
        optionId: 'deny',
        kind: 'reject',
        name: 'Deny',
        response: {'decision': 'deny'},
      ),
    ];

    test('approve：一次性授权优先于 always', () {
      final picked = TaskActionsClient.pickApproveOption(options);
      expect(picked!.optionId, 'allow-once');
    });

    test('approve：无 allow 族时回落首项', () {
      final onlyDeny = options.sublist(2);
      expect(TaskActionsClient.pickApproveOption(onlyDeny)!.optionId, 'deny');
    });

    test('approve：空列表 → null（调用方走回退）', () {
      expect(TaskActionsClient.pickApproveOption(const []), isNull);
    });

    test('deny：reject/deny 命中', () {
      expect(TaskActionsClient.pickDenyOption(options).optionId, 'deny');
    });

    test('deny：无拒绝项 → 构造 optionId=deny 兜底（botsService 同款）', () {
      final picked = TaskActionsClient.pickDenyOption(options.sublist(0, 2));
      expect(picked.optionId, 'deny');
      expect(picked.response, {'decision': 'deny'});
    });
  });

  group('P1-7 git 频道（scripted_bridge）', () {
    test('happy：getRepositorySummary 命令与权威形状解析', () async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'workspacePath': '/w',
            'repoRoot': '/w',
            'branchName': 'main',
            'trackingBranchName': 'origin/main',
            'ahead': 2,
            'behind': 1,
            'isDirty': true,
            'isGitAvailable': true,
            'isRepository': true,
          },
        ],
      ]);
      final overview = await GitOverviewClient(bridge.bridge).fetch('/w');
      expect(bridge.commands, hasLength(1));
      final req = requestOf(bridge.commands.single);
      expect(req.channel, 'git');
      expect(req.method, 'getRepositorySummary');
      expect(req.params, {'workspacePath': '/w'});
      expect(overview.hasRepo, isTrue);
      expect(overview.branch, 'main');
      expect(overview.isDirty, isTrue);
      expect(overview.ahead, 2);
      expect(overview.behind, 1);
    });

    test('no-services 降级：unavailable 占位不抛，命令数 1', () async {
      final bridge = ScriptedBridge(script: const [
        [],
      ], errors: {0: 'no-services'});
      final overview = await GitOverviewClient(bridge.bridge).fetch('/w');
      expect(overview.hasRepo, isFalse);
      expect(bridge.commands, hasLength(1));
    });

    test('无 workspacePath：不发包直接占位', () async {
      final bridge = ScriptedBridge(script: const []);
      final overview = await GitOverviewClient(bridge.bridge).fetch(null);
      expect(overview.hasRepo, isFalse);
      expect(overview.workspacePath, isNull);
      expect(bridge.commands, isEmpty);
    });
  });

  group('P1-7 GitOverview 双形状容错（S2 三类漂移成对）', () {
    test('漂移 1 外壳包裹：{summary:{...}} 单键壳经 firstObjectDeep 剥壳',
        () async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'summary': {
              'branchName': 'dev',
              'isDirty': false,
              'isRepository': true,
            },
          },
        ],
      ]);
      final o = await GitOverviewClient(bridge.bridge).fetch('/w');
      expect(o.branch, 'dev');
      expect(o.hasRepo, isTrue);
    });

    test('漂移 2 字段缺失：branch/currentBranch 别名与 dirtyFiles.length 计数', () {
      final o = GitOverview.fromJson(const {
        'currentBranch': 'feat/x',
        'dirtyFiles': [
          {'path': 'a.dart'},
          {'path': 'b.dart'},
        ],
        'isRepository': true,
      }, '/w');
      expect(o.branch, 'feat/x');
      expect(o.dirtyCount, 2);
      expect(o.isDirty, isTrue);
    });

    test('漂移 2 字段缺失：仅 isDirty 布尔（计数未知）', () {
      final o = GitOverview.fromJson(const {
        'branch': 'main',
        'isDirty': true,
      }, '/w');
      expect(o.dirtyCount, isNull);
      expect(o.isDirty, isTrue);
      expect(o.hasRepo, isTrue);
    });

    test('漂移 3 类型漂移：ahead 字符串数值与 isRepository 缺省回落', () {
      final o = GitOverview.fromJson(const {
        'branchName': 'main',
        'ahead': '3',
        'isDirty': false,
      }, '/w');
      // 类型漂移（字符串数值）读不出 → 兜底 0，不抛。
      expect(o.ahead, 0);
      // isRepository 缺省时按有分支判定（反例：无 branch 且无 isRepository
      // → hasRepo false，同一容错分支的对照）。
      expect(o.hasRepo, isTrue);
      final noBranch = GitOverview.fromJson(const {'isDirty': false}, '/w');
      expect(noBranch.hasRepo, isFalse);
    });
  });
}
