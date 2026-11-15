import 'approval_extractor.dart';
import 'task_actions.dart';

/// P1-4 通知动作路由决策（纯函数，便于成对断言）：
/// 由 actionId + payload + 当前可用的客户端/待办，产出「回执」或
/// 「跳设备兜底」两种路线；app_shell 只负责执行。
sealed class ApprovalRoute {
  const ApprovalRoute();
}

/// 静默回退：跳到设备会话页由用户在页面内操作
/// （payload 非 perm 前缀 / 无桥 / 无待办 / 选项缺失）。
class ApprovalJump extends ApprovalRoute {
  const ApprovalJump(this.deviceId);

  final String deviceId;
}

/// RPC 回执路线（respondPermission / respondElicitation）。
class ApprovalRespond extends ApprovalRoute {
  const ApprovalRespond({
    required this.deviceId,
    required this.taskId,
    required this.requestId,
    required this.isElicitation,
    this.optionId,
    this.response,
    this.elicitationAction,
  });

  final String deviceId;
  final String taskId;
  final String requestId;
  final bool isElicitation;

  /// permission 路线的选项回执。
  final String? optionId;
  final Map<String, dynamic>? response;

  /// elicitation 路线的 accept/decline。
  final String? elicitationAction;
}

/// 路由决策：approve/deny 分支与全部回退条件。
/// - payload 非 `perm:` 前缀 → 按 payload 当设备 id 跳（老语义）。
/// - 无客户端（会话未挂桥）/ 无待办 / requestId 未知 → 跳设备。
/// - approve 且权限选项全空（无 allow 族可挑）→ 跳设备。
ApprovalRoute approvalRouteFor({
  required String actionId,
  required String payload,
  required TaskActionsClient? client,
  required PendingApproval? pending,
}) {
  final parsed = TaskActionsClient.parsePermPayload(payload);
  if (parsed == null) return ApprovalJump(payload);
  if (client == null || pending == null || pending.requestId == null) {
    return ApprovalJump(parsed.deviceId);
  }
  final requestId = pending.requestId!;
  final approve = actionId == TaskActionsClient.actionApprove;
  if (pending.isElicitation) {
    return ApprovalRespond(
      deviceId: parsed.deviceId,
      taskId: parsed.taskId,
      requestId: requestId,
      isElicitation: true,
      elicitationAction: approve ? 'accept' : 'decline',
    );
  }
  if (approve) {
    final option = TaskActionsClient.pickApproveOption(pending.options);
    if (option == null) return ApprovalJump(parsed.deviceId);
    return ApprovalRespond(
      deviceId: parsed.deviceId,
      taskId: parsed.taskId,
      requestId: requestId,
      isElicitation: false,
      optionId: option.optionId,
      response: option.response,
    );
  }
  final option = TaskActionsClient.pickDenyOption(pending.options);
  return ApprovalRespond(
    deviceId: parsed.deviceId,
    taskId: parsed.taskId,
    requestId: requestId,
    isElicitation: false,
    optionId: option.optionId,
    response: option.response,
  );
}

/// 执行路线：返回 true = RPC 受理；失败/路线为跳转时返回 false
/// （调用方据此决定是否跳设备兜底；Jump 路线本身也返回 false 并由
/// 调用方直接跳转）。
Future<bool> executeApprovalRoute(
  ApprovalRoute route,
  TaskActionsClient? client,
) async {
  if (route is ApprovalJump) return false;
  if (client == null || route is! ApprovalRespond) return false;
  if (route.isElicitation) {
    return client.respondElicitation(
      taskId: route.taskId,
      requestId: route.requestId,
      action: route.elicitationAction ?? 'accept',
    );
  }
  final optionId = route.optionId;
  if (optionId == null) return false;
  return client.respondPermission(
    taskId: route.taskId,
    requestId: route.requestId,
    optionId: optionId,
    response: route.response ?? const {'decision': 'allow'},
  );
}
