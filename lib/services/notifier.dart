import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../models/notification_prefs.dart';
import 'event_observer.dart';
import 'quota_alert.dart';
import 'task_actions.dart';

/// 领取结果通知类型（P2-7）：成功 / 需人工验证码。
enum ClaimNotifyKind { success, captchaNeeded }

/// 通知动作按钮（P1-4）：id 回传 onDidReceiveNotificationResponse.actionId。
class NotificationActionSpec {
  const NotificationActionSpec({required this.id, required this.title});

  final String id;
  final String title;
}

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
    this.quota = false,
  });

  final String deviceId;
  final String? taskId;
  final bool claim;

  /// 额度预警 payload（`quota:<deviceId>`）→ 点击开额度中心。
  final bool quota;
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
    final quotaId = TaskActionsClient.parseQuotaPayload(payload);
    if (quotaId != null) return ZrNotificationTarget(deviceId: quotaId, quota: true);
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
    this.actions = const [],
  });

  /// 平台语义说明（P5-1）：[channelId]/[channelName]/[importance]/[priority]
  /// 均为 Android 渠道路由概念——iOS 无 channel，四字段不参与 iOS 投递；
  /// iOS 展示策略见 [notificationDetailsFor] 注释（未验证，真机回归）。

  final String channelId;
  final String channelName;
  final Importance importance;
  final Priority priority;
  final String title;
  final String body;

  final String payload;

  /// Android 通知 action 按钮（批准/拒绝等）；空列表不带按钮。
  final List<NotificationActionSpec> actions;

  /// 通知文案百分比：≥10 取整，否则一位小数（与额度页展示一致）。
  static String _fmtPercent(num v) =>
      v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

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

  /// 额度预警通知（额度消耗预警）：独立 zr_quota 渠道；payload 带 `quota:`
  /// 前缀，点击进额度中心，action「去领取」进领取页。
  ///
  /// critical 按 [claimAutoEnabled] 分支文案：自动领取已开则提示需人工，
  /// 未开则引导去领取。耗尽只提示，不自动领取。
  static NotificationSpec quotaLow({
    required RemoteDevice device,
    required QuotaAlertLevel level,
    required QuotaAlertSnapshot snapshot,
    required bool claimAutoEnabled,
    AppLocalizations? l10n,
  }) {
    final l = l10n ?? l10nZh;
    final label = device.displayName(l);
    final critical = level == QuotaAlertLevel.critical;
    final percent = _fmtPercent(snapshot.percentUsed);
    final remaining = _fmtPercent(snapshot.remainingPercent);
    final reset = snapshot.resetText ?? '';
    return NotificationSpec(
      channelId: 'zr_quota',
      channelName: l.notifChannelQuota,
      importance: critical ? Importance.high : Importance.defaultImportance,
      priority: critical ? Priority.high : Priority.defaultPriority,
      title: critical
          ? l.quotaAlertCriticalTitle(label)
          : l.quotaAlertWarnTitle(label, percent),
      body: critical
          ? (claimAutoEnabled
                ? l.quotaAlertCriticalAutoBody
                : l.quotaAlertCriticalBody(reset))
          : l.quotaAlertWarnBody(snapshot.planName, remaining, reset),
      payload: '${TaskActionsClient.quotaPayloadPrefix}${device.id}',
      actions: [
        NotificationActionSpec(
          id: TaskActionsClient.actionClaim,
          title: l.quotaAlertActionClaim,
        ),
      ],
    );
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

  /// 额度预警通知 id：同设备同档位按毫秒时间戳区分（多条提醒各占一位）。
  static int quotaStableId(
    RemoteDevice device,
    QuotaAlertLevel level,
    DateTime at,
  ) =>
      (device.id.hashCode ^
          level.name.hashCode ^
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

/// 组装双平台通知细节（P5-1）。
///
/// - Android：channel / importance / priority / 锁屏可见性 / action 按钮语义
///   全部保持既有行为不变。
/// - iOS 无 channel 概念：[NotificationSpec.channelId]/[channelName] 仅喂
///   Android 渠道路由；importance/priority 也是 Android 语义，iOS 侧**不映射**
///   打断级别（timeSensitive 需在 Xcode 声明 Time Sensitive Notifications
///   能力，本仓未配置，未声明时系统按 active 处理），前台展示与否由初始化时
///   的 defaultPresent*（banner/list/sound/badge）决定，落库细节传
///   `const DarwinNotificationDetails()` 交由初始化默认值接管。
/// - 通知 action 按钮（批准/拒绝）为 Android 专属；iOS 侧未注册
///   DarwinNotificationCategory，按钮不出现，点击通知本体仍走 payload 路由。
///
/// 未验证：本机无 macOS，iOS 分支随版本真机回归（验收清单 S3 条款）。
NotificationDetails notificationDetailsFor(
  NotificationSpec spec, {
  required bool lockEnabled,
}) =>
    NotificationDetails(
      android: AndroidNotificationDetails(
        spec.channelId,
        spec.channelName,
        importance: spec.importance,
        priority: spec.priority,
        visibility: lockScreenVisibility(lockEnabled: lockEnabled),
        actions: [
          for (final action in spec.actions)
            AndroidNotificationAction(action.id, action.title),
        ],
      ),
      iOS: const DarwinNotificationDetails(),
    );

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
      // Android 现状保留（13+ POST_NOTIFICATIONS 运行时请求）。
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      // iOS（P5-1）：alert/badge/sound 三项一次性请求；与 init 时
      // DarwinInitializationSettings 的 request* 双保险，已授权后重复调用
      // 不再弹窗（系统幂等，直接回当前状态）。
      // 未验证：本机无 macOS，随版本真机回归（验收清单 S3 条款）。
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {
    }
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          // iOS（P5-1）：初始化时请求 alert/sound/badge 权限（插件 README
          // 默认形态）；前台展示选项走 defaultPresent*——iOS 14+ 即
          // banner + list（对照插件旧 API setForegroundNotificationsPresent
          // ationOptions 的 alert:true 映射）。原生侧还需 AppDelegate 指派
          // UNUserNotificationCenter delegate（ios/Runner/AppDelegate.swift）。
          // 未验证：本机无 macOS，随版本真机回归（验收清单 S3 条款）。
          iOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestSoundPermission: true,
            requestBadgePermission: true,
            defaultPresentBanner: true,
            defaultPresentList: true,
          ),
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
        notificationDetails: notificationDetailsFor(
          spec,
          lockEnabled: _lockScreenRedact,
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
        notificationDetails: notificationDetailsFor(
          spec,
          lockEnabled: _lockScreenRedact,
        ),
        payload: spec.payload,
      );
    } catch (_) {
    }
  }

  /// 额度消耗预警：gate 走 quotaLow 开关 × DND × 每设备覆盖。
  Future<void> notifyQuotaLow({
    required RemoteDevice device,
    required QuotaAlertLevel level,
    required QuotaAlertSnapshot snapshot,
    required bool claimAutoEnabled,
    AppLocalizations? l10n,
  }) async {
    if (!_gateAllows(device, ZrNotifyCategory.quotaLow)) return;
    final spec = NotificationSpec.quotaLow(
      device: device,
      level: level,
      snapshot: snapshot,
      claimAutoEnabled: claimAutoEnabled,
      l10n: l10n,
    );
    try {
      if (!_permissionAsked) await ensurePermission();
      final id = NotificationSpec.quotaStableId(device, level, DateTime.now());
      await _plugin.show(
        id: id,
        title: spec.title,
        body: spec.body,
        notificationDetails: notificationDetailsFor(
          spec,
          lockEnabled: _lockScreenRedact,
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
