import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/approval_extractor.dart';
import 'package:zremote/state/approval_center.dart';

void main() {
  group('P1-4 ApprovalExtractor（被动喂流，S2 双形状成对）', () {
    test('权威形状：permission_request 带 requestId 与选项集', () {
      const body = '''
{
  "event": "permission_request",
  "taskId": "t1",
  "requestId": "req-1",
  "title": "Bash",
  "description": "rm -rf build",
  "options": [
    {"optionId": "allow", "kind": "allow_once", "name": "允许",
     "response": {"decision": "allow"}},
    {"optionId": "deny", "kind": "reject", "name": "拒绝",
     "response": {"decision": "deny"}}
  ]
}
''';
      final signals = ApprovalExtractor.parseMessage(body);
      expect(signals, hasLength(1));
      final request = signals.single.request!;
      expect(request.taskId, 't1');
      expect(request.requestId, 'req-1');
      expect(request.isElicitation, isFalse);
      expect(request.options, hasLength(2));
      expect(request.options.first.optionId, 'allow');
      expect(request.options.first.response, {'decision': 'allow'});
    });

    test('漂移 1 外壳包裹：payload 壳内嵌请求仍可提取', () {
      final signals = ApprovalExtractor.parseRoot({
        'payload': {
          'data': {
            'type': 'permission_request',
            'task_id': 't2',
            'requestId': 'req-2',
            'options': ['yes', 'no'],
          },
        },
      });
      final request = signals.single.request!;
      expect(request.taskId, 't2');
      expect(request.requestId, 'req-2');
      // 字符串选项 → optionId/kind/name 同源。
      expect(request.options.map((o) => o.optionId), ['yes', 'no']);
    });

    test('漂移 2 字段缺失：requestId 缺失时仍产出请求（选项为空）', () {
      final signals = ApprovalExtractor.parseRoot({
        'event': 'permission_request',
        'taskId': 't3',
      });
      final request = signals.single.request!;
      expect(request.requestId, isNull);
      expect(request.options, isEmpty);
    });

    test('漂移 3 别名：toolCallId 兜底 + elicitation_request 识别', () {
      final signals = ApprovalExtractor.parseRoot({
        'type': 'elicitation_request',
        'taskId': 't4',
        'toolCallId': 'tc-9',
        'message': '选择部署目标',
      });
      final request = signals.single.request!;
      expect(request.isElicitation, isTrue);
      expect(request.requestId, 'tc-9');
      expect(request.summary, '选择部署目标');
    });

    test('resolved 族（含 permission_response 别名）产生清账信号', () {
      for (final type in [
        'permission_resolved',
        'elicitation_resolved',
        'permission_response',
        'elicitation_response',
      ]) {
        final signals = ApprovalExtractor.parseRoot({
          'event': type,
          'taskId': 't5',
          'requestId': 'req-5',
        });
        expect(signals.single.resolvedTaskId, 't5', reason: type);
      }
    });

    test('非审批事件与无 taskId 请求不产信号', () {
      expect(ApprovalExtractor.parseRoot({'event': 'completed'}), isEmpty);
      expect(
        ApprovalExtractor.parseRoot({'event': 'permission_request'}),
        isEmpty,
      );
      expect(ApprovalExtractor.parseMessage('not json'), isEmpty);
    });
  });

  group('P1-4 ApprovalCenterNotifier（喂流 → 通知动作取数）', () {
    test('请求覆盖同 taskId，resolved 清账，forget 清设备', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(approvalCenterProvider.notifier);

      notifier.ingest('d1', [
        ApprovalSignal.request(
          PendingApproval(
            taskId: 't1',
            requestId: 'r1',
            isElicitation: false,
            options: const [],
          ),
        ),
      ]);
      expect(container.read(approvalCenterProvider)['d1']?['t1']?.requestId,
          'r1');

      // 同 taskId 新请求覆盖（requestId 更新）。
      notifier.ingest('d1', [
        ApprovalSignal.request(
          PendingApproval(taskId: 't1', requestId: 'r2', isElicitation: false),
        ),
      ]);
      expect(container.read(approvalCenterProvider)['d1']?['t1']?.requestId,
          'r2');

      notifier.ingest('d1', const [ApprovalSignal.resolved('t1')]);
      expect(container.read(approvalCenterProvider)['d1'], isEmpty);

      notifier.ingest('d1', [
        ApprovalSignal.request(
          PendingApproval(taskId: 't2', requestId: 'r3', isElicitation: false),
        ),
      ]);
      notifier.forget('d1');
      expect(container.read(approvalCenterProvider).containsKey('d1'),
          isFalse);
    });
  });
}
