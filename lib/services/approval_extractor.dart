import 'dart:convert';

import 'task_actions.dart';

/// 审批待办的被动事件流提取器（P1-4）。
///
/// 与 EventParser（event_observer.dart，注入 JS 红线不改）平行的一层：
/// 从同一条 zrEvents 报文里额外提取 `permission_request` /
/// `elicitation_request` 的 requestId 与选项集（通知动作按钮回执需要），
/// 以及 `permission_resolved` / `elicitation_resolved`（含
/// permission_response / elicitation_response 别名）的清理信号。
///
/// 形状容错（S2）：requestId 别名 requestId|request_id|toolCallId；
/// 选项容器 options|permissionOptions；选项可为对象（optionId/kind/name/
/// response）或字符串（整体当 optionId）；taskId 别名 taskId|task_id。
abstract final class ApprovalExtractor {
  static const int _maxDepth = 4;

  /// 单条信号：请求（带 requestId 与选项）或已解决（按 taskId 清账）。
  static List<ApprovalSignal> parseMessage(String body) {
    dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<ApprovalSignal> parseRoot(dynamic root) {
    final out = <ApprovalSignal>[];
    _walk(root, 0, out);
    return out;
  }

  static void _walk(dynamic node, int depth, List<ApprovalSignal> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      final signal = _signalOf(node);
      if (signal != null) out.add(signal);
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static ApprovalSignal? _signalOf(Map<dynamic, dynamic> node) {
    String? type;
    for (final key in const ['event', 'type']) {
      final value = node[key];
      if (value is String) {
        type = value;
        break;
      }
    }
    if (type == null) return null;
    final taskId = _taskIdOf(node);
    switch (type) {
      case 'permission_request':
      case 'elicitation_request':
        if (taskId == null) return null;
        return ApprovalSignal.request(
          PendingApproval(
            taskId: taskId,
            requestId: _requestIdOf(node),
            isElicitation: type == 'elicitation_request',
            title: _firstString(node, const ['title', 'kind', 'toolName']),
            summary: _firstString(
              node,
              const ['description', 'message', 'header'],
            ),
            options: _optionsOf(node),
          ),
        );
      case 'permission_resolved':
      case 'elicitation_resolved':
      case 'permission_response':
      case 'elicitation_response':
        if (taskId == null) return null;
        return ApprovalSignal.resolved(taskId);
    }
    return null;
  }

  static String? _taskIdOf(Map<dynamic, dynamic> node) => _firstString(
    node,
    const ['taskId', 'task_id'],
  );

  static String? _requestIdOf(Map<dynamic, dynamic> node) => _firstString(
    node,
    const ['requestId', 'request_id', 'toolCallId', 'tool_call_id'],
  );

  static String? _firstString(Map<dynamic, dynamic> node, List<String> keys) {
    for (final key in keys) {
      final value = node[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  static List<ApprovalOption> _optionsOf(Map<dynamic, dynamic> node) {
    for (final key in const ['options', 'permissionOptions']) {
      final raw = node[key];
      if (raw is! List) continue;
      final out = <ApprovalOption>[];
      for (final entry in raw) {
        if (entry is Map<String, dynamic>) {
          final option = ApprovalOption.fromJson(entry);
          if (option != null) out.add(option);
        } else if (entry is String && entry.isNotEmpty) {
          out.add(ApprovalOption(optionId: entry, kind: entry, name: entry));
        }
      }
      return out;
    }
    return const [];
  }
}

/// 一条审批流信号：新请求或已解决。
class ApprovalSignal {
  const ApprovalSignal.request(PendingApproval this.request)
    : resolvedTaskId = null;

  const ApprovalSignal.resolved(String this.resolvedTaskId) : request = null;

  final PendingApproval? request;
  final String? resolvedTaskId;
}

/// 一条待审批请求（通知动作按钮回执所需的最小字段）。
class PendingApproval {
  const PendingApproval({
    required this.taskId,
    required this.isElicitation,
    this.requestId,
    this.title,
    this.summary,
    this.options = const [],
  });

  final String taskId;
  final String? requestId;
  final bool isElicitation;
  final String? title;
  final String? summary;
  final List<ApprovalOption> options;
}
