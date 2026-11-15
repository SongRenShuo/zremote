import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import 'event_observer.dart';
import 'task_actions.dart';

/// 领取结果通知类型（P2-7）：成功 / 需人工验证码。
enum ClaimNotifyKind { success, captchaNeeded }

/// 通知动作按钮（P1-4）：id 回传 onDidReceiveNotificationResponse.actionId。
class NotificationActionSpec {
  const NotificationActionSpec({required this.id, required this.title});

  final String id;
  final String title;
}

class NotificationSpec {
  const NotificationSpec({
    required this.channelId,
    required this.channelName,
    required this.importance,
    required this.priority,
    required this.title,
    required this.body,
    required this.payload,
    this.actions = const [],
  });

  final String channelId;
  final String channelName;
  final Importance importance;
  final Priority priority;
  final String title;
  final String body;

  final String payload;

  /// Android 通知 action 按钮（批准/拒绝等）；空列表不带按钮。
  final List<NotificationActionSpec> actions;

  static int stableId(RemoteDevice device, ObservedEvent event) =>
      (device.id.hashCode ^
          event.type.hashCode ^
          (event.taskId?.hashCode ?? 0)) &
      0x7FFFFFFF;

  static Set<int> cancellableIds(RemoteDevice device, String taskId) => {
        stableId(
          device,
          ObservedEvent(type: 'permission_request', taskId: taskId),
        ),
        stableId(
          device,
          ObservedEvent(type: 'elicitation_request', taskId: taskId),
        ),
      };

  static NotificationSpec? from(
    RemoteDevice device,
    ObservedEvent event, [
    AppLocalizations? l10n,
  ]) {
    final l = l10n ?? l10nZh;
    final session = event.sessionTitle?.trim().isNotEmpty == true
        ? event.sessionTitle!.trim()
        : l.notifSessionFallback;
    final what = event.summary?.trim().isNotEmpty == true
        ? event.summary!.trim()
        : null;
    final label = device.displayName(l);
    switch (event.type) {
      case 'permission_request':
        return NotificationSpec(
          channelId: 'zr_perm',
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: l.notifPermTitle(label, session),
          body: what ?? l.notifPermBody,
          // P1-4：带 taskId 时 payload 用 perm 前缀（通知动作按钮路由用），
          // 点击通知本体同样落在会话页兜底路径。
          payload: _permPayload(device, event),
          actions: [
            NotificationActionSpec(
              id: TaskActionsClient.actionApprove,
              title: l.approvalNotifApprove,
            ),
            NotificationActionSpec(
              id: TaskActionsClient.actionDeny,
              title: l.approvalNotifDeny,
            ),
          ],
        );
      case 'elicitation_request':
        return NotificationSpec(
          channelId: 'zr_perm',
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: l.notifElicitTitle(label, session),
          body: what ?? l.notifElicitBody,
          payload: _permPayload(device, event),
        );
      case 'error':
        return NotificationSpec(
          channelId: 'zr_fail',
          channelName: l.notifChannelFail,
          importance: Importance.high,
          priority: Priority.high,
          title: l.notifErrorTitle(label, session),
          body: what ?? l.notifErrorBody,
          payload: device.id,
        );
      case 'completed':
        return NotificationSpec(
          channelId: 'zr_done',
          channelName: l.notifChannelDone,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          title: l.notifDoneTitle(label, session),
          body: what ?? l.notifDoneBody,
          payload: device.id,
        );
      default:
        return null;
    }
  }

  /// taskId 可得时构造 `perm:<deviceId>:<taskId>`；否则回落设备 id
  /// （老语义：点击跳设备）。
  static String _permPayload(RemoteDevice device, ObservedEvent event) {
    final taskId = event.taskId;
    if (taskId == null || taskId.isEmpty) return device.id;
    return '${TaskActionsClient.permPayloadPrefix}'
        '${device.id}:$taskId';
  }

  /// 领取结果通知（P2-7）：独立 zr_claim 渠道；payload 带 `claim:` 前缀，
  /// NotificationTap 路由据此打开对应设备的领取页。
  static NotificationSpec claimResult({
    required RemoteDevice device,
    required ClaimNotifyKind kind,
    required String planName,
    AppLocalizations? l10n,
  }) {
    final l = l10n ?? l10nZh;
    final label = device.displayName(l);
    switch (kind) {
      case ClaimNotifyKind.success:
        return NotificationSpec(
          channelId: 'zr_claim',
          channelName: l.claimAutoNotifChannel,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          title: l.claimAutoNotifSuccessTitle(label),
          body: l.claimAutoNotifSuccessBody(planName),
          payload: 'claim:${device.id}',
        );
      case ClaimNotifyKind.captchaNeeded:
        return NotificationSpec(
          channelId: 'zr_claim',
          channelName: l.claimAutoNotifChannel,
          importance: Importance.high,
          priority: Priority.high,
          title: l.claimAutoNotifCaptchaTitle(label),
          body: l.claimAutoNotifCaptchaBody,
          payload: 'claim:${device.id}',
        );
    }
  }

  /// 领取通知 id：同设备同 kind 按毫秒时间戳区分（多条成功各占一位）。
  static int claimStableId(
    RemoteDevice device,
    ClaimNotifyKind kind,
    DateTime at,
  ) =>
      (device.id.hashCode ^
          kind.name.hashCode ^
          at.millisecondsSinceEpoch.hashCode) &
      0x7FFFFFFF;
}

abstract final class NotificationTap {
  static String? _pending;
  static void Function(String deviceId)? _onTap;

  static void bind(void Function(String deviceId)? onTap) => _onTap = onTap;

  static void route(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final onTap = _onTap;
    if (onTap != null) {
      onTap(payload);
    } else {
      _pending = payload;
    }
  }

  static String? consumePending() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}

/// 通知动作按钮路由（P1-4）：actionId（zr-act-*）+ 通知 payload。
/// 与 [NotificationTap] 平行；绑定晚于动作到达时落 pending。
abstract final class NotificationActionTap {
  static ({String actionId, String payload})? _pending;
  static void Function(String actionId, String payload)? _onAction;

  static void bind(void Function(String actionId, String payload)? onAction) =>
      _onAction = onAction;

  static void route(String? actionId, String? payload) {
    if (actionId == null || actionId.isEmpty) return;
    final body = payload ?? '';
    final onAction = _onAction;
    if (onAction != null) {
      onAction(actionId, body);
    } else {
      _pending = (actionId: actionId, payload: body);
    }
  }

  static ({String actionId, String payload})? consumePending() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}

NotificationVisibility lockScreenVisibility({required bool lockEnabled}) =>
    lockEnabled ? NotificationVisibility.private : NotificationVisibility.public;

class NotifierService {
  NotifierService._();

  static final NotifierService instance = NotifierService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;
  bool _permissionAsked = false;
  bool _lockScreenRedact = false;

  void setLockScreenRedact(bool value) => _lockScreenRedact = value;

  Future<void> ensurePermission() async {
    if (_permissionAsked) return;
    _permissionAsked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
    }
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          // P1-4：动作按钮按下（actionId 非空）走动作路由；
          // 通知本体点击仍走 NotificationTap（payload 语义路由）。
          final actionId = response.actionId;
          if (actionId != null && actionId.isNotEmpty) {
            NotificationActionTap.route(actionId, response.payload);
            return;
          }
          NotificationTap.route(response.payload);
        },
      );
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        NotificationTap.route(details?.notificationResponse?.payload);
      }
    } catch (_) {
    }
  }

  Future<void> notifyFrom(
    RemoteDevice device,
    ObservedEvent event, {
    AppLocalizations? l10n,
  }) async {
    final spec = NotificationSpec.from(device, event, l10n);
    if (spec == null) return;
    try {
      if (!_permissionAsked) await ensurePermission();
      final id = NotificationSpec.stableId(device, event);
      await _plugin.show(
        id: id,
        title: spec.title,
        body: spec.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            spec.channelId,
            spec.channelName,
            importance: spec.importance,
            priority: spec.priority,
            visibility: lockScreenVisibility(lockEnabled: _lockScreenRedact),
            actions: [
              for (final action in spec.actions)
                AndroidNotificationAction(action.id, action.title),
            ],
          ),
        ),
        payload: spec.payload,
      );
    } catch (_) {
    }
  }

  Future<void> notifyClaim({
    required RemoteDevice device,
    required ClaimNotifyKind kind,
    required String planName,
    AppLocalizations? l10n,
  }) async {
    final spec = NotificationSpec.claimResult(
      device: device,
      kind: kind,
      planName: planName,
      l10n: l10n,
    );
    try {
      if (!_permissionAsked) await ensurePermission();
      final id = NotificationSpec.claimStableId(device, kind, DateTime.now());
      await _plugin.show(
        id: id,
        title: spec.title,
        body: spec.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            spec.channelId,
            spec.channelName,
            importance: spec.importance,
            priority: spec.priority,
            visibility: lockScreenVisibility(lockEnabled: _lockScreenRedact),
          ),
        ),
        payload: spec.payload,
      );
    } catch (_) {
    }
  }

  Future<void> cancelPending(RemoteDevice device, String taskId) async {
    for (final id in NotificationSpec.cancellableIds(device, taskId)) {
      try {
        await _plugin.cancel(id: id);
      } catch (_) {
      }
    }
  }
}
