import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/claim.dart';
import '../models/device.dart';
import '../services/claim_scheduler.dart';
import '../services/device_store.dart';
import '../services/notifier.dart';
import '../services/rpc_bridge.dart';
import 'claim_history.dart';

/// 自动领取装配层（P2-1）：session_view 挂桥时 attach、会话 dispose 时
/// detach；事件（成功/失败/需人工验证码）→ 历史落账 + 系统通知。
///
/// 通路 A（宿主 RPC）为主；通路 B（直连）仅接口位默认关（P2-8，
/// [DirectClaimRpcClient]），本期不接。
class ClaimSchedulerHub extends Notifier<Map<String, ClaimSchedulerAgent>> {
  @override
  Map<String, ClaimSchedulerAgent> build() => const {};

  /// 会话挂桥（onWebViewCreated）时装配代理；重复 attach 先停旧表。
  Future<void> attach(RemoteDevice device, RpcBridge bridge) async {
    detach(device.id);
    final config = await DeviceStore.instance.claimAutoConfig(device.id);
    final agent = ClaimSchedulerAgent(
      deviceId: device.id,
      client: HostClaimRpcClient(bridge),
      config: config,
      onEvent: (event) => _handleEvent(device, event),
    );
    state = {...state, device.id: agent};
    agent.start();
  }

  /// 设备移除/会话 dispose：停表（磁盘配置与历史快照保留）。
  void detach(String deviceId) {
    final agent = state[deviceId];
    if (agent == null) return;
    agent.stop();
    state = Map.of(state)..remove(deviceId);
    _blockedDedup.remove(deviceId);
  }

  /// 配置变更（claimConfigProvider 监听转发）。
  void updateConfig(String deviceId, ClaimAutoConfig config) {
    state[deviceId]?.updateConfig(config);
  }

  /// 仅设备 live 时运行轮次（sessionStatusProvider 监听转发）。
  void setLive(String deviceId, bool live) {
    state[deviceId]?.setLive(live);
  }

  /// 手动刷新/领取开始：让位 + 阻止自动 tick。
  void manualStarted(String deviceId) {
    state[deviceId]?.manualStarted();
  }

  /// 手动结束：60s 冷却后恢复自动轮。
  void manualEnded(String deviceId) {
    state[deviceId]?.manualEnded();
  }

  /// 立即执行一轮自动领取（UI「立即执行一轮」入口，20261116-2341 D1②）。
  /// 无代理（未 attach）或门控拒绝时返回 false。
  Future<bool> runNow(String deviceId) async {
    final agent = state[deviceId];
    if (agent == null) return false;
    return agent.runNow();
  }

  /// 自动轮状态快照（UI 冷却/在飞展示，D1③）；无代理返回 null。
  ClaimSchedulerSnapshot? snapshotOf(String deviceId) =>
      state[deviceId]?.snapshot();

  /// Blocked 同因去重窗口：同因在窗口内不重复落史（防 10min 冷却循环刷屏）。
  static const Duration blockedDedupWindow = Duration(hours: 1);

  final Map<String, _BlockedDedup> _blockedDedup = {};

  void _recordBlocked(
    RemoteDevice device,
    ClaimBlockedReason reason,
    String detail,
  ) {
    final last = _blockedDedup[device.id];
    final now = DateTime.now();
    if (last != null &&
        last.reason == reason &&
        now.difference(last.at) < blockedDedupWindow) {
      return; // 同因在窗口内：不重复落史。
    }
    _blockedDedup[device.id] = (reason: reason, at: now);
    ref
        .read(claimHistoryProvider.notifier)
        .record(
          device.id,
          success: false,
          message: detail,
          source: ClaimRecordSource.auto,
          blockedReason: reason,
        );
  }

  void _handleEvent(RemoteDevice device, ClaimSchedulerEvent event) {
    switch (event) {
      case ClaimAutoBlocked(:final reason, :final detail):
        _recordBlocked(device, reason, detail);
      case ClaimAutoSucceeded(:final plan):
        ref
            .read(claimHistoryProvider.notifier)
            .record(
              device.id,
              planId: plan.planId,
              planName: plan.name,
              success: true,
              benefitSummary: claimBenefitSummary(plan.entitlements),
              source: ClaimRecordSource.auto,
            );
        unawaited(
          NotifierService.instance.notifyClaim(
            device: device,
            kind: ClaimNotifyKind.success,
            planName: plan.name.isEmpty ? plan.planId : plan.name,
          ),
        );
      case ClaimAutoFailed(:final plan, :final outcome, :final error):
        ref
            .read(claimHistoryProvider.notifier)
            .record(
              device.id,
              planId: plan.planId,
              planName: plan.name,
              success: false,
              code: outcome?.code,
              message: outcome?.message ?? error,
              source: ClaimRecordSource.auto,
            );
        if (event.captchaNeeded) {
          // 3007 验证码校验失败 → 与无感失败同语义（需人工）。
          unawaited(
            NotifierService.instance.notifyClaim(
              device: device,
              kind: ClaimNotifyKind.captchaNeeded,
              planName: plan.name.isEmpty ? plan.planId : plan.name,
            ),
          );
        }
      case ClaimAutoCaptchaNeeded(:final plan):
        unawaited(
          NotifierService.instance.notifyClaim(
            device: device,
            kind: ClaimNotifyKind.captchaNeeded,
            planName: plan.name.isEmpty ? plan.planId : plan.name,
          ),
        );
    }
  }
}

final claimSchedulerHubProvider =
    NotifierProvider<ClaimSchedulerHub, Map<String, ClaimSchedulerAgent>>(
      ClaimSchedulerHub.new,
    );

/// Blocked 去重账条目（内存态，不落盘）。
typedef _BlockedDedup = ({ClaimBlockedReason reason, DateTime at});
