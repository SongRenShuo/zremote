import 'package:flutter/foundation.dart';

import 'rpc_bridge.dart';

/// 原生审批与快捷操作客户端（开发计划 20261115-0901 P1-4）。
///
/// 频道归属（P1-1 探针 methodChecks 已核实）：`respondPermission` /
/// `respondElicitation` / `stopGeneration` 均在 `zcodeTaskService`
/// （开源版 zcodeTaskService.ts 366-418 行签名）：
/// - respondPermission({taskId, requestId, optionId, response}) → boolean
/// - respondElicitation({taskId, requestId, action, content?}) → boolean
/// - stopGeneration({taskId}) → void
///
/// 返回值注意：宿主把 boolean 结果序列化后 RpcBridge._valuesOf 只保留
/// List/Map 形态，「未提交(false)」与「已提交(true)」在本侧不可区分——
/// 以「RPC 未抛异常」视为已受理；业务拒绝会以 RPC 错误文本抛出。
class TaskActionsClient {
  TaskActionsClient(this.bridge);

  final RpcBridge bridge;

  /// 通知动作 payload 前缀：`perm:<deviceId>:<taskId>`。
  /// deviceId 为 uuid（无冒号）；taskId 理论上可含冒号，解析按下述规则
  /// 取首段 deviceId、末段之外全部为 taskId。
  static const String permPayloadPrefix = 'perm:';

  /// Android 通知 action 按钮 id（onDidReceiveNotificationResponse.actionId）。
  static const String actionApprove = 'zr-act-approve';
  static const String actionDeny = 'zr-act-deny';

  /// 解析 `perm:<deviceId>:<taskId>`；不匹配前缀或段数不足返回 null。
  static ({String deviceId, String taskId})? parsePermPayload(String payload) {
    if (!payload.startsWith(permPayloadPrefix)) return null;
    final rest = payload.substring(permPayloadPrefix.length);
    final parts = rest.split(':');
    if (parts.length < 2) return null;
    final deviceId = parts.first;
    final taskId = parts.sublist(1).join(':');
    if (deviceId.isEmpty || taskId.isEmpty) return null;
    return (deviceId: deviceId, taskId: taskId);
  }

  /// 从权限选项中挑「批准」项：kind 含 allow/approve 优先（preferAlways
  /// 为 false 时优先非 always 的一次性授权），无匹配时回落首项。
  static ApprovalOption? pickApproveOption(List<ApprovalOption> options) {
    ApprovalOption? once;
    ApprovalOption? always;
    for (final o in options) {
      final kind = o.kind.toLowerCase();
      final isAllow = kind.contains('allow') || kind.contains('approve');
      if (!isAllow) continue;
      if (kind.contains('always')) {
        always ??= o;
      } else {
        once ??= o;
      }
    }
    return once ?? always ?? (options.isNotEmpty ? options.first : null);
  }

  /// 从权限选项中挑「拒绝」项：kind 含 deny/reject；无匹配时构造
  /// optionId=deny 的兜底拒绝（开源版 botsService.ts deny 分支同款）。
  static ApprovalOption pickDenyOption(List<ApprovalOption> options) {
    for (final o in options) {
      final kind = o.kind.toLowerCase();
      if (kind.contains('deny') || kind.contains('reject')) return o;
    }
    return const ApprovalOption(
      optionId: 'deny',
      kind: 'deny',
      name: '',
      response: <String, dynamic>{'decision': 'deny'},
    );
  }

  /// 响应权限请求。返回 true = RPC 受理（未抛异常）。
  Future<bool> respondPermission({
    required String taskId,
    required String requestId,
    required String optionId,
    Map<String, dynamic> response = const {'decision': 'allow'},
    String? workspacePath,
  }) async {
    try {
      await bridge.call(
        'zcode-task',
        'respondPermission',
        params: {
          'taskId': taskId,
          'requestId': requestId,
          'optionId': optionId,
          'response': response,
          if (workspacePath != null && workspacePath.isNotEmpty)
            'workspacePath': workspacePath,
        },
        timeout: const Duration(seconds: 15),
      );
      return true;
    } catch (e) {
      _logFailure('respondPermission', e);
      return false;
    }
  }

  /// 响应问答请求（action: accept/decline/cancel）。
  Future<bool> respondElicitation({
    required String taskId,
    required String requestId,
    required String action,
    Map<String, dynamic>? content,
    String? workspacePath,
  }) async {
    try {
      await bridge.call(
        'zcode-task',
        'respondElicitation',
        params: {
          'taskId': taskId,
          'requestId': requestId,
          'action': action,
          'content': ?content,
          if (workspacePath != null && workspacePath.isNotEmpty)
            'workspacePath': workspacePath,
        },
        timeout: const Duration(seconds: 15),
      );
      return true;
    } catch (e) {
      _logFailure('respondElicitation', e);
      return false;
    }
  }

  /// 停止正在进行的生成（会话卡「停止」按钮）。
  Future<bool> stopGeneration({required String taskId, String? workspacePath}) async {
    try {
      await bridge.call(
        'zcode-task',
        'stopGeneration',
        params: {
          'taskId': taskId,
          if (workspacePath != null && workspacePath.isNotEmpty)
            'workspacePath': workspacePath,
        },
        timeout: const Duration(seconds: 15),
      );
      return true;
    } catch (e) {
      _logFailure('stopGeneration', e);
      return false;
    }
  }

  void _logFailure(String method, Object e) {
    // 失败静默回退由调用方处理（打开会话页），这里只留诊断读数。
    if (kDebugMode) {
      debugPrint('[task-actions] $method failed: $e');
    }
  }
}

/// 一个权限选项（ZCodePermissionOption 的容错子集）。
class ApprovalOption {
  const ApprovalOption({
    required this.optionId,
    required this.kind,
    required this.name,
    this.response = const <String, dynamic>{'decision': 'allow'},
  });

  final String optionId;
  final String kind;
  final String name;

  /// 完整 response 载荷（decision/modifiedInput/…），批准时原样回传。
  final Map<String, dynamic> response;

  static ApprovalOption? fromJson(Map<String, dynamic> j) {
    final optionId = j['optionId'] is String ? j['optionId'] as String : null;
    if (optionId == null || optionId.isEmpty) return null;
    return ApprovalOption(
      optionId: optionId,
      kind: j['kind'] is String ? j['kind'] as String : '',
      name: j['name'] is String ? j['name'] as String : '',
      response: j['response'] is Map<String, dynamic>
          ? Map<String, dynamic>.of(j['response'] as Map<String, dynamic>)
          : const <String, dynamic>{'decision': 'allow'},
    );
  }
}
