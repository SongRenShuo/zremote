import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/approval_extractor.dart';
import 'package:zremote/services/approval_router.dart';
import 'package:zremote/services/task_actions.dart';

import 'scripted_bridge.dart';

const _permPending = PendingApproval(
  taskId: 't1',
  requestId: 'req-1',
  isElicitation: false,
  options: [
    ApprovalOption(
      optionId: 'allow',
      kind: 'allow_once',
      name: 'Allow',
      response: {'decision': 'allow'},
    ),
    ApprovalOption(
      optionId: 'reject',
      kind: 'reject',
      name: 'Deny',
      response: {'decision': 'deny'},
    ),
  ],
);

const _elicitPending = PendingApproval(
  taskId: 't1',
  requestId: 'req-2',
  isElicitation: true,
);

void main() {
  group('P1-4 approvalRouteFor：approve/deny 分支（纯函数）', () {
    test('approve → allow_once 选项回执', () {
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionApprove,
        payload: 'perm:d1:t1',
        client: _stubClient(),
        pending: _permPending,
      );
      final respond = route as ApprovalRespond;
      expect(respond.deviceId, 'd1');
      expect(respond.taskId, 't1');
      expect(respond.requestId, 'req-1');
      expect(respond.optionId, 'allow');
      expect(respond.response, {'decision': 'allow'});
    });

    test('deny → reject 选项回执', () {
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionDeny,
        payload: 'perm:d1:t1',
        client: _stubClient(),
        pending: _permPending,
      );
      final respond = route as ApprovalRespond;
      expect(respond.optionId, 'reject');
      expect(respond.response, {'decision': 'deny'});
    });

    test('elicitation：approve→accept / deny→decline', () {
      String actionOf(String actionId) =>
          (approvalRouteFor(
            actionId: actionId,
            payload: 'perm:d1:t1',
            client: _stubClient(),
            pending: _elicitPending,
          ) as ApprovalRespond).elicitationAction!;
      expect(actionOf(TaskActionsClient.actionApprove), 'accept');
      expect(actionOf(TaskActionsClient.actionDeny), 'decline');
    });
  });

  group('P1-4 回退分支（静默跳设备）', () {
    test('payload 非 perm 前缀 → 跳 payload 本体（老语义设备 id）', () {
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionApprove,
        payload: 'd-plain-id',
        client: _stubClient(),
        pending: _permPending,
      );
      expect(route, isA<ApprovalJump>());
      expect((route as ApprovalJump).deviceId, 'd-plain-id');
    });

    test('无客户端（会话未挂桥）→ 跳设备', () {
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionApprove,
        payload: 'perm:d1:t1',
        client: null,
        pending: _permPending,
      );
      expect((route as ApprovalJump).deviceId, 'd1');
    });

    test('无待办（事件流没喂到 requestId）→ 跳设备', () {
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionApprove,
        payload: 'perm:d1:t1',
        client: _stubClient(),
        pending: null,
      );
      expect((route as ApprovalJump).deviceId, 'd1');
    });

    test('待办无 requestId + approve 选项为空 → 跳设备', () {
      const bare = PendingApproval(taskId: 't1', isElicitation: false);
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionApprove,
        payload: 'perm:d1:t1',
        client: _stubClient(),
        pending: bare,
      );
      expect((route as ApprovalJump).deviceId, 'd1');
    });
  });

  group('P1-4 executeApprovalRoute：RPC 受理与失败回退读数', () {
    test('approve happy：respondPermission 发包且返回 true', () async {
      final bridge = ScriptedBridge(script: const [
        [{}],
      ]);
      final client = TaskActionsClient(bridge.bridge);
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionApprove,
        payload: 'perm:d1:t1',
        client: client,
        pending: _permPending,
      );
      expect(await executeApprovalRoute(route, client), isTrue);
      expect(bridge.commands, hasLength(1));
      final req = requestOf(bridge.commands.single);
      expect(req.method, 'respondPermission');
      expect((req.params as Map)['optionId'], 'allow');
    });

    test('RPC 失败（no-services）→ false（调用方据此跳设备兜底）', () async {
      final bridge = ScriptedBridge(
        script: const [
          [],
        ],
        errors: {0: 'no-services'},
      );
      final client = TaskActionsClient(bridge.bridge);
      final route = approvalRouteFor(
        actionId: TaskActionsClient.actionDeny,
        payload: 'perm:d1:t1',
        client: client,
        pending: _permPending,
      );
      expect(await executeApprovalRoute(route, client), isFalse);
      expect(bridge.commands, hasLength(1));
    });

    test('Jump 路线不发包恒 false', () async {
      final bridge = ScriptedBridge(script: const []);
      expect(
        await executeApprovalRoute(const ApprovalJump('d1'), null),
        isFalse,
      );
      expect(bridge.commands, isEmpty);
    });
  });
}

/// 路由决策是纯函数：客户端仅作存在性判定，不发真包。
TaskActionsClient _stubClient() => TaskActionsClient(ScriptedBridge().bridge);
