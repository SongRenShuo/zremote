import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../models/notification_prefs.dart';
import '../services/approval_router.dart';
import '../services/deep_link.dart';
import '../services/device_import.dart';
import '../services/link_builder.dart';
import '../services/notifier.dart';
import '../services/task_actions.dart';
import '../state/accounts.dart';
import '../state/approval_center.dart';
import '../state/claim_entry.dart';
import '../state/event_feed.dart';
import '../state/keepalive.dart';
import '../state/notification_prefs.dart';
import '../state/quota_alert.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../theme.dart';
import 'manage_page.dart';
import 'quota_page.dart';
import 'settings_page.dart';
import 'session_view.dart';
import 'haptics.dart';
import 'showcase_bits.dart';
import 'status_led.dart';
import 'unread_badge.dart';

/// 宽屏双栏断点（P4-5）：≥600dp 设备列表栏 + 会话区。
const double kWideBreakpoint = 600;

/// 左栏宽度（P4-5）。
const double kRailWidth = 240;

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _pendingTapConsumed = false;

  @override
  void initState() {
    super.initState();
    NotificationTap.bind((payload) => _jumpToPayload(payload));
    // P1-4：通知动作按钮（批准/拒绝）路由。
    NotificationActionTap.bind(
      (actionId, payload) => _handleApprovalAction(actionId, payload),
    );
    // 冷启动由动作按钮拉起时 route 先于 bind 落 pending，这里补发。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = NotificationActionTap.consumePending();
      if (pending != null) {
        _handleApprovalAction(pending.actionId, pending.payload);
      }
    });
    NotifierService.instance.setLockScreenRedact(ref.read(biometricProvider));
    // P3-1：通知 gate 快照推送（类型开关 × DND × 每设备覆盖在
    // NotifierService 内统一判定）。
    NotifierService.instance.updateGates(ref.read(notificationPrefsProvider));
    // P4-1 深链导入：热启动推送 + 冷启动 initial（Dart 侧就绪后拉取）。
    DeepLinkService.listen(_handleDeepLink);
    unawaited(() async {
      final initial = await DeepLinkService.initialLink();
      if (initial != null) _handleDeepLink(initial);
    }());
  }

  @override
  void dispose() {
    NotificationTap.bind(null);
    NotificationActionTap.bind(null);
    super.dispose();
  }

  /// 深链落地：白名单提取 → 解析 → 重复则跳转，否则确认后导入。
  Future<void> _handleDeepLink(String raw) async {
    final link = extractRemoteLink(raw);
    if (link == null || !mounted) return;
    final device = LinkBuilder.parse(link);
    if (device == null) {
      _shellSnack((l10n) => l10n.deepLinkInvalid);
      return;
    }
    final dup = findDuplicateBySid(ref.read(deviceListProvider), device);
    if (dup != null) {
      _jumpTo(dup.id);
      _shellSnack((l10n) => l10n.importDuplicate(dup.displayName(l10n)));
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deepLinkImportTitle),
        content: Text(l10n.deepLinkImportBody(device.displayName(l10n))),
        actions: [
          TextButton(
            key: const Key('deeplink-import-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('deeplink-import-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.deepLinkImportTitle),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final devices = ref.read(deviceListProvider);
    await ref.read(deviceListProvider.notifier).add(device);
    ZrHaptics.success();
    ref.read(activeTabProvider.notifier).set(devices.length);
  }

  void _shellSnack(String Function(AppLocalizations l10n) message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message(AppLocalizations.of(context)!))));
  }

  void _jumpTo(String deviceId) {
    if (!mounted) return;
    final index = ref
        .read(deviceListProvider)
        .indexWhere((d) => d.id == deviceId);
    if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
  }

  /// 通知点击路由：`claim:<deviceId>`（领取结果，P2-7）→ 跳设备 +
  /// 请求打开领取页；`quota:<deviceId>`（额度预警）→ 跳设备 + 打开额度中心；
  /// `<deviceId>#<taskId>`（P4-7）→ 跳设备 + 请求定位具体会话；其余 payload
  /// 语义为设备 id（沿用既有行为）。
  void _jumpToPayload(String payload) {
    if (!mounted) return;
    final target = NotificationPayload.parse(payload);
    if (target == null) return;
    _jumpTo(target.deviceId);
    if (target.claim) {
      ref.read(claimOpenRequestProvider.notifier).request(target.deviceId);
      return;
    }
    if (target.quota) {
      _openQuotaCenter(target.deviceId);
      return;
    }
    final taskId = target.taskId;
    if (taskId != null) {
      // P4-7：session_index 已收录该 taskId 时定位；未收录（页面还没
      // 加载到）也照发——SessionView 收到后在 webview 内滚动查找。
      ref
          .read(sessionJumpRequestProvider.notifier)
          .request(target.deviceId, taskId);
    }
  }

  /// 额度预警通知点击 → 打开额度中心（桥来自会话挂桥注册；未挂桥仅切设备）。
  void _openQuotaCenter(String deviceId) {
    final devices = ref.read(deviceListProvider);
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index < 0) return;
    final bridge =
        ref.read(approvalCenterProvider.notifier).clientOf(deviceId)?.bridge;
    if (bridge == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuotaPage(
          device: devices[index],
          bridge: bridge,
          tokenProvider: () async => ticketsOfActiveAccount(
            ref.read(accountsProvider),
            devices[index],
          ).quotaTokens,
        ),
      ),
    );
  }

  /// P1-4 通知动作路由：`perm:<deviceId>:<taskId>` payload +
  /// actionId（zr-act-approve / zr-act-deny）→ 审批回执；
  /// `quota:<deviceId>` + zr-act-claim → 打开领取页；
  /// 无桥/无待办/RPC 失败 → 静默回退跳设备会话页由用户在页面内操作。
  /// 决策逻辑在 approval_route（纯函数可测），这里只执行。
  Future<void> _handleApprovalAction(String actionId, String payload) async {
    if (!mounted) return;
    final quotaId = TaskActionsClient.parseQuotaPayload(payload);
    if (quotaId != null) {
      _jumpTo(quotaId);
      ref.read(claimOpenRequestProvider.notifier).request(quotaId);
      return;
    }
    final parsed = TaskActionsClient.parsePermPayload(payload);
    final client = parsed == null
        ? null
        : ref.read(approvalCenterProvider.notifier).clientOf(parsed.deviceId);
    final pending = parsed == null
        ? null
        : ref.read(approvalCenterProvider)[parsed.deviceId]?[parsed.taskId];
    final route = approvalRouteFor(
      actionId: actionId,
      payload: payload,
      client: client,
      pending: pending,
    );
    if (route is ApprovalJump) {
      _jumpTo(route.deviceId);
      return;
    }
    final respond = route as ApprovalRespond;
    final ok = await executeApprovalRoute(respond, client);
    if (!mounted) return;
    if (!ok) _jumpTo(respond.deviceId);
  }

  void _consumePendingTap() {
    if (_pendingTapConsumed) return;
    if (ref.read(deviceListProvider).isEmpty) return;
    _pendingTapConsumed = true;
    final pending = NotificationTap.consumePending();
    if (pending != null) _jumpToPayload(pending);
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceListProvider);
    final active = ref.watch(activeTabProvider);

    ref.watch(keepAliveControllerProvider);

    ref.listen<bool>(
      biometricProvider,
      (_, next) => NotifierService.instance.setLockScreenRedact(next),
    );

    // P3-1：类型开关/DND 变更实时推送通知 gate。
    ref.listen<NotificationPrefs>(
      notificationPrefsProvider,
      (_, next) => NotifierService.instance.updateGates(next),
    );

    ref.listen(deviceListProvider, (prev, next) {
      final count = next.length + 1;
      ref.read(activeTabProvider.notifier).clampTo(count);
      if (prev != null && prev.isEmpty && next.isNotEmpty) {
        _consumePendingTap();
        ref.read(activeTabProvider.notifier).restoreLast();
      }
      // 额度预警后台节拍：有设备才启动（无设备无对象可查）。
      if (next.isNotEmpty) {
        ref.read(quotaAlertWatcherProvider.notifier).start();
      }
    });

    ref.listen(activeTabProvider, (_, next) {
      final list = ref.read(deviceListProvider);
      if (next < list.length) {
        ref.read(eventFeedProvider.notifier).clear(list[next].id);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_pendingTapConsumed) _consumePendingTap();
      NotifierService.instance.ensurePermission();
    });

    final sessionPanes = <Widget>[
      for (final d in devices)
        KeyedSubtree(
          key: ValueKey(d.id),
          child: SessionView(device: d),
        ),
    ];

    return Scaffold(
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // P4-5：≥600dp 双栏（左设备列表栏 + 右当前会话）；窄屏保持
            // IndexedStack（含 ManagePage 管理页）不变。
            final wide = constraints.maxWidth >= kWideBreakpoint;
            if (!wide) {
              return IndexedStack(
                index: active.clamp(0, devices.length),
                children: [...sessionPanes, const ManagePage()],
              );
            }
            final showSession = active < devices.length && devices.isNotEmpty;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: kRailWidth,
                  child: _WideDeviceRail(
                    devices: devices,
                    activeId: showSession ? devices[active].id : null,
                    onPick: (id) {
                      final i = devices.indexWhere((d) => d.id == id);
                      if (i >= 0) ref.read(activeTabProvider.notifier).set(i);
                    },
                  ),
                ),
                Container(width: 0.8, color: context.zt.hairline),
                Expanded(
                  child: showSession
                      ? IndexedStack(
                          index: active,
                          children: sessionPanes,
                        )
                      : _WideEmptyPane(devices: devices),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 宽屏左栏（P4-5）：设备简列（状态 LED + 未读徽章）+ 添加/设置。
class _WideDeviceRail extends ConsumerWidget {
  const _WideDeviceRail({
    required this.devices,
    required this.activeId,
    required this.onPick,
  });

  final List<RemoteDevice> devices;
  final String? activeId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final statuses = ref.watch(sessionStatusProvider);
    final feeds = ref.watch(eventFeedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Image.asset('assets/brand/mark.png', width: 20, height: 20),
              const SizedBox(width: 8),
              Text(
                'ZREMOTE',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.2,
                  color: context.zt.textHi,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: l10n.settingsEntryTitle,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsPage(),
                  ),
                ),
                icon: Icon(Icons.settings_outlined, color: context.zt.textLo),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.zt.hairline),
        Expanded(
          child: devices.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    l10n.emptyBody,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: context.zt.textLo,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: devices.length,
                  itemBuilder: (context, i) {
                    final d = devices[i];
                    final isActive = d.id == activeId;
                    return InkWell(
                      onTap: () => onPick(d.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? context.zt.accentSubtle
                              : Colors.transparent,
                          border: Border(
                            left: BorderSide(
                              width: 2.5,
                              color: isActive
                                  ? context.zt.accent
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            StatusLed(status: statuses[d.id], size: 7),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                d.displayName(l10n),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isActive
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isActive
                                      ? context.zt.accent
                                      : context.zt.textHi,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            UnreadBadge(feed: feeds[d.id]),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Divider(height: 1, color: context.zt.hairline),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      fullscreenDialog: true,
                      builder: (_) => const ScannerPage(),
                    ),
                  ),
                  icon: const Icon(Icons.qr_code_scanner, size: 16),
                  label: Text(l10n.importScanLabel),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 宽屏右侧空面板：activeTab 指向管理页（窄屏切换后旋转等场景）。
class _WideEmptyPane extends StatelessWidget {
  const _WideEmptyPane({required this.devices});

  final List<RemoteDevice> devices;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZrEmptyState(
      icon: Icons.devices_other,
      title: devices.isEmpty ? l10n.emptyTitle : l10n.uxWidePickDevice,
      message: devices.isEmpty ? l10n.emptyBody : null,
    );
  }
}
