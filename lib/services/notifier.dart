import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../models/notification_prefs.dart';
import 'event_observer.dart';

/// 领取结果通知类型（P2-7）：成功 / 需人工验证码。
enum ClaimNotifyKind { success, captchaNeeded }

/// 通知类别（P3-1 gate 矩阵输入）：审批类在免打扰时段仍放行（高优）。
enum ZrNotifyCategory { approval, fail, done, claimResult, captcha, quotaLow }

/// 每设备通知覆盖（RemoteDevice.params key `notifyOverride`，P3-1）。
enum ZrNotifyOverride { on, off, inherit }

/// 纯函数 gate（P3-1）：类型开关 × 免打扰时段 × 每设备覆盖三层的合并判定。
///
/// 语义（settings 页与本文档同源）：
/// - override=off：该设备完全静音（一切类别都拦，包括审批）；
/// - override=on：该设备豁免全局类型开关，但**不豁免免打扰时段**；
/// - override=inherit（默认）：按全局类型开关；
/// - 免打扰（dndStart!=dndEnd）：时段内仅 approval 放行。
abstract final class NotificationGatePolicy {
  static ZrNotifyOverride overrideOf(Map<String, String> params) {
    return switch (params['notifyOverride']) {
      'on' => ZrNotifyOverride.on,
      'off' => ZrNotifyOverride.off,
      _ => ZrNotifyOverride.inherit,
    };
  }

  static bool typeAllowed(NotificationPrefs prefs, ZrNotifyCategory category) =>
      switch (category) {
        ZrNotifyCategory.approval => prefs.approval,
        ZrNotifyCategory.fail => prefs.fail,
        ZrNotifyCategory.done => prefs.complete,
        ZrNotifyCategory.claimResult => prefs.claimResult,
        ZrNotifyCategory.captcha => prefs.captchaManual,
        ZrNotifyCategory.quotaLow => prefs.quotaLow,
      };

  /// 免打扰窗口判定（支持跨零点，如 23:00-08:00 由 start>end 表达）。
  static bool inDndWindow(NotificationPrefs prefs, int minuteOfDay) {
    if (!prefs.dndEnabled) return false;
    final start = prefs.dndStartMinutes;
    final end = prefs.dndEndMinutes;
    if (start > end) {
      return minuteOfDay >= start || minuteOfDay < end;
    }
    return minuteOfDay >= start && minuteOfDay < end;
  }

  static bool allows({
    required NotificationPrefs prefs,
    required Map<String, String> deviceParams,
    required ZrNotifyCategory category,
    required int minuteOfDay,
  }) {
    final override = overrideOf(deviceParams);
    if (override == ZrNotifyOverride.off) return false;
    if (inDndWindow(prefs, minuteOfDay) &&
        category != ZrNotifyCategory.approval) {
      return false;
    }
    if (override == ZrNotifyOverride.on) return true;
    return typeAllowed(prefs, category);
  }

  static ZrNotifyCategory? categoryOfEvent(String eventType) =>
      switch (eventType) {
        'permission_request' || 'elicitation_request' =>
          ZrNotifyCategory.approval,
        'error' => ZrNotifyCategory.fail,
        'completed' => ZrNotifyCategory.done,
        _ => null,
      };
}

/// 通知 payload 解析（P4-7）：三种历史格式统一收敛到目标结构。
///
/// - `claim:<deviceId>`（L3 领取结果）；
/// - `<deviceId>`（L1 起最简格式）；
/// - `<deviceId>#<taskId>`（P4-7 带 taskId 定位具体会话）。
class ZrNotificationTarget {
  const ZrNotificationTarget({
    required this.deviceId,
    this.taskId,
    this.claim = false,
  });

  final String deviceId;
  final String? taskId;
  final bool claim;
}

abstract final class NotificationPayload {
  static String build(String deviceId, {String? taskId}) =>
      taskId == null || taskId.isEmpty ? deviceId : '$deviceId#$taskId';

  static ZrNotificationTarget? parse(String payload) {
    if (payload.isEmpty) return null;
    if (payload.startsWith('claim:')) {
      final id = payload.substring('claim:'.length);
      if (id.isEmpty) return null;
      return ZrNotificationTarget(deviceId: id, claim: true);
    }
    final hash = payload.indexOf('#');
    if (hash <= 0) return ZrNotificationTarget(deviceId: payload);
    final id = payload.substring(0, hash);
    final task = payload.substring(hash + 1);
    if (id.isEmpty || task.isEmpty) {
      return ZrNotificationTarget(deviceId: id.isEmpty ? payload : id);
    }
    return ZrNotificationTarget(deviceId: id, taskId: task);
  }
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
  });

  final String channelId;
  final String channelName;
  final Importance importance;
  final Priority priority;
  final String title;
  final String body;

  final String payload;

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
          payload: NotificationPayload.build(
            device.id,
            taskId: event.taskId,
          ),
        );
      case 'elicitation_request':
        return NotificationSpec(
          channelId: 'zr_perm',
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: l.notifElicitTitle(label, session),
          body: what ?? l.notifElicitBody,
          payload: NotificationPayload.build(
            device.id,
            taskId: event.taskId,
          ),
        );
      case 'error':
        return NotificationSpec(
          channelId: 'zr_fail',
          channelName: l.notifChannelFail,
          importance: Importance.high,
          priority: Priority.high,
          title: l.notifErrorTitle(label, session),
          body: what ?? l.notifErrorBody,
          payload: NotificationPayload.build(
            device.id,
            taskId: event.taskId,
          ),
        );
      case 'completed':
        return NotificationSpec(
          channelId: 'zr_done',
          channelName: l.notifChannelDone,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          title: l.notifDoneTitle(label, session),
          body: what ?? l.notifDoneBody,
          payload: NotificationPayload.build(
            device.id,
            taskId: event.taskId,
          ),
        );
      default:
        return null;
    }
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
  NotificationPrefs _gates = const NotificationPrefs();

  void setLockScreenRedact(bool value) => _lockScreenRedact = value;

  /// P3-1 gate 快照：设置页/app_shell 装配时推送
  /// （notificationPrefsProvider 监听转发；不推送则按默认开关）。
  void updateGates(NotificationPrefs prefs) => _gates = prefs;

  int _minuteOfDay(DateTime now) => now.hour * 60 + now.minute;

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
        onDidReceiveNotificationResponse: (response) =>
            NotificationTap.route(response.payload),
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
    // P3-1 gate：类型开关 × 免打扰 × 每设备覆盖（快照未推送时按默认值）。
    final category = NotificationGatePolicy.categoryOfEvent(event.type);
    if (category == null) return;
    if (!_gateAllows(device, category)) return;
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
    // P3-1 gate：成功→claimResult 开关；需人工→captchaManual 开关。
    final category = kind == ClaimNotifyKind.success
        ? ZrNotifyCategory.claimResult
        : ZrNotifyCategory.captcha;
    if (!_gateAllows(device, category)) return;
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

  bool _gateAllows(RemoteDevice device, ZrNotifyCategory category) {
    final now = DateTime.now();
    return NotificationGatePolicy.allows(
      prefs: _gates,
      deviceParams: device.params,
      category: category,
      minuteOfDay: _minuteOfDay(now),
    );
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
