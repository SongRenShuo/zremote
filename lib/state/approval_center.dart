import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/approval_extractor.dart';
import '../services/rpc_bridge.dart';
import '../services/task_actions.dart';

/// 审批待办中心（P1-4）：session_view 挂桥时 attach，事件流喂入
/// [ingest]；通知动作按钮（批准/拒绝）与工具箱「审批待办」徽章从这里取数。
class ApprovalCenterNotifier
    extends Notifier<Map<String, Map<String, PendingApproval>>> {
  final Map<String, TaskActionsClient> _clients = {};

  @override
  Map<String, Map<String, PendingApproval>> build() => const {};

  /// 会话挂桥（onWebViewCreated）时注册客户端；dispose 时解除。
  void attach(String deviceId, RpcBridge bridge) {
    _clients[deviceId] = TaskActionsClient(bridge);
  }

  void detach(String deviceId) {
    _clients.remove(deviceId);
    forget(deviceId);
  }

  TaskActionsClient? clientOf(String deviceId) => _clients[deviceId];

  /// 事件流喂入：请求信号覆盖同 taskId 旧值；resolved 清账。
  void ingest(String deviceId, List<ApprovalSignal> signals) {
    if (signals.isEmpty) return;
    var map = state[deviceId];
    map = Map.of(map ?? const <String, PendingApproval>{});
    var touched = false;
    for (final signal in signals) {
      final request = signal.request;
      if (request != null) {
        map[request.taskId] = request;
        touched = true;
      } else if (signal.resolvedTaskId != null) {
        touched |= map.remove(signal.resolvedTaskId) != null;
      }
    }
    if (!touched) return;
    state = {...state, deviceId: map};
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final approvalCenterProvider =
    NotifierProvider<ApprovalCenterNotifier, Map<String, Map<String, PendingApproval>>>(
      ApprovalCenterNotifier.new,
    );
