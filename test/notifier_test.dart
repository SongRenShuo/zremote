import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/notifier.dart';
import 'package:zremote/services/task_actions.dart';

RemoteDevice _device(String id) => RemoteDevice(
      id: id,
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: {'sid': 's', 'hash': 'h'},
      label: '',
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  group('P1-4 通知动作按钮与 perm payload', () {
    test('permission_request：payload=perm 前缀 + 批准/拒绝双 action', () {
      final spec = NotificationSpec.from(
        _device('dev-1'),
        const ObservedEvent(type: 'permission_request', taskId: 'task-9'),
      )!;
      expect(spec.payload, 'perm:dev-1:task-9');
      expect(spec.actions, hasLength(2));
      expect(spec.actions[0].id, TaskActionsClient.actionApprove);
      expect(spec.actions[1].id, TaskActionsClient.actionDeny);
    });

    test('elicitation_request：perm payload 但无动作按钮（需输入，仅点击）',
        () {
      final spec = NotificationSpec.from(
        _device('dev-1'),
        const ObservedEvent(type: 'elicitation_request', taskId: 'task-9'),
      )!;
      expect(spec.payload, 'perm:dev-1:task-9');
      expect(spec.actions, isEmpty);
    });

    test('taskId 缺失：回落设备 id 老语义（点击跳设备）', () {
      final spec = NotificationSpec.from(
        _device('dev-1'),
        const ObservedEvent(type: 'permission_request'),
      )!;
      expect(spec.payload, 'dev-1');
      // 动作按钮仍给（路由解析失败即回退跳设备）。
      expect(spec.actions, hasLength(2));
    });
  });

  group('P1-4 NotificationActionTap 路由', () {
    test('绑定前 route 落 pending，绑定后 consumePending 补发', () {
      NotificationActionTap.bind(null);
      NotificationActionTap.route('zr-act-approve', 'perm:d:t');
      final pending = NotificationActionTap.consumePending();
      expect(pending!.actionId, 'zr-act-approve');
      expect(pending.payload, 'perm:d:t');
      // 消费一次后不再有。
      expect(NotificationActionTap.consumePending(), isNull);

      final routed = <({String actionId, String payload})>[];
      NotificationActionTap.bind((actionId, payload) {
        routed.add((actionId: actionId, payload: payload));
      });
      NotificationActionTap.route('zr-act-deny', 'perm:d:t');
      expect(routed, hasLength(1));
      expect(routed.single.actionId, 'zr-act-deny');
      NotificationActionTap.bind(null);
    });

    test('空 actionId 不路由（通知本体点击走 NotificationTap）', () {
      final routed = <({String actionId, String payload})>[];
      NotificationActionTap.bind((actionId, payload) {
        routed.add((actionId: actionId, payload: payload));
      });
      NotificationActionTap.route(null, 'perm:d:t');
      NotificationActionTap.route('', 'perm:d:t');
      expect(routed, isEmpty);
      NotificationActionTap.bind(null);
    });
  });

  group('NotificationSpec.cancellableIds', () {
    test('恰为该会话审批/追问两类通知位 id（三元稳定同款算法）', () {
      final device = _device('d1');
      final ids = NotificationSpec.cancellableIds(device, 'sess_b');

      final perm = NotificationSpec.stableId(
        device,
        const ObservedEvent(type: 'permission_request', taskId: 'sess_b'),
      );
      final elicit = NotificationSpec.stableId(
        device,
        const ObservedEvent(type: 'elicitation_request', taskId: 'sess_b'),
      );
      expect(ids, {perm, elicit});
      expect(ids, hasLength(2));
    });

    test('不同会话/不同设备的 id 不同（撤回不误伤）', () {
      final a = NotificationSpec.cancellableIds(_device('d1'), 'sess_a');
      final b = NotificationSpec.cancellableIds(_device('d1'), 'sess_b');
      final c = NotificationSpec.cancellableIds(_device('d2'), 'sess_a');
      expect(a.intersection(b), isEmpty);
      expect(a.intersection(c), isEmpty);
    });

    test('完成/失败通知不在撤回集——语义独立', () {
      final device = _device('d1');
      final ids = NotificationSpec.cancellableIds(device, 'sess_b');
      final done = NotificationSpec.stableId(
        device,
        const ObservedEvent(type: 'completed', taskId: 'sess_b'),
      );
      expect(ids.contains(done), isFalse);
    });
  });

  group('锁屏可见性', () {
    test('生物锁开启 → private（锁屏不露正文）', () {
      expect(
        lockScreenVisibility(lockEnabled: true),
        NotificationVisibility.private,
      );
    });

    test('生物锁关闭 → public（完整展示）', () {
      expect(
        lockScreenVisibility(lockEnabled: false),
        NotificationVisibility.public,
      );
    });
  });
}
