import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/claim.dart';
import '../models/device.dart';
import '../services/activation_report.dart';
import '../services/claim_scheduler.dart';
import '../services/device_store.dart';
import '../services/manual_claim_batch.dart';
import '../services/notifier.dart';
import '../services/rpc_bridge.dart';
import 'accounts.dart';
import 'approval_center.dart';
import 'claim_history.dart';
import 'session_status.dart';

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
      // F2（20261118-0030）：每轮 preview 前先激活（服务端"看到活跃"才出
      // 可领套餐）；无绑定账号/无 user_id/上报失败均静默跳过。
      beforePreview: () => _reportActivationFor(
        device,
        ref.read(accountsProvider),
      ),
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

  /// 全局一键手动领取（20261117-1230）：遍历所有 live 且已装配的设备，
  /// 逐台领取其全部可领套餐。参照 quota_alert sweep 模式——单台失败不中断，
  /// 非 live / 未装配跳过并计数。结果由 UI SnackBar 汇总。
  ///
  /// 领取走 HostClaimRpcClient 三段 RPC（与单设备手动领取同语义），
  /// 不复用 runNow（后者是自动轮语义，只领 previews.first 至上限）。
  Future<ManualClaimBatchResult> claimAllLive() async {
    // 磁盘真值兜底（20261118-0030 F1④）：DeviceListNotifier 首次 read 可能
    // 还是空列表（build 同步返回 []，_load 异步填数），导致误导性 0/0/0。
    final devices = await DeviceStore.instance.loadAll();
    final statuses = ref.read(sessionStatusProvider);
    final accountsState = ref.read(accountsProvider);
    final result = <ManualClaimDeviceResult>[];
    var skipped = 0;
    for (final device in devices) {
      if (statuses[device.id] != SessionStatus.live) {
        skipped++;
        result.add(
          ManualClaimDeviceResult(deviceId: device.id, reason: 'notLive'),
        );
        continue;
      }
      final bridge = ref
          .read(approvalCenterProvider.notifier)
          .clientOf(device.id)
          ?.bridge;
      if (bridge == null) {
        skipped++;
        result.add(
          ManualClaimDeviceResult(deviceId: device.id, reason: 'notAttached'),
        );
        continue;
      }
      // 手动让位：阻止自动轮与手动批次并发。
      manualStarted(device.id);
      try {
        // 激活前置（20261118-0030 F2）：服务端"看到活跃"才出可领套餐；
        // 上报失败静默跳过，不阻断预览。
        await _reportActivationFor(device, accountsState);
        final runner = ManualClaimRunner(
          deviceId: device.id,
          client: HostClaimRpcClient(bridge),
          onClaimed: (plan, outcome) {
            ref
                .read(claimHistoryProvider.notifier)
                .record(
                  device.id,
                  planId: plan.planId,
                  planName: plan.name,
                  success: true,
                  code: outcome.code,
                  message: outcome.message,
                  source: ClaimRecordSource.manual,
                  benefitSummary: claimBenefitSummary(plan.entitlements),
                );
          },
          onFailed: (plan, message, code) {
            ref
                .read(claimHistoryProvider.notifier)
                .record(
                  device.id,
                  planId: plan.planId,
                  planName: plan.name,
                  success: false,
                  code: code,
                  message: message,
                  source: ClaimRecordSource.manual,
                );
          },
        );
        final (ok, fail, note) = await runner.fetchAndRunAll();
        result.add(
          ManualClaimDeviceResult(
            deviceId: device.id,
            claimed: ok,
            failed: fail,
            reason: note,
          ),
        );
      } catch (e) {
        debugPrint('[claim-batch] device ${device.id} failed: $e');
        // F1：异常设备计入失败（此前吞成 claimed=0/failed=0 致汇总全零误导）。
        result.add(
          ManualClaimDeviceResult(
            deviceId: device.id,
            failed: 1,
            reason: 'error:${e.toString()}',
          ),
        );
      } finally {
        manualEnded(device.id);
      }
    }
    return ManualClaimBatchResult(results: result, skipped: skipped);
  }

  /// 对设备的绑定账号上报激活事件（F2-B）；无绑定账号/无 user_id/上报失败
  /// 均静默跳过（不阻断预览）。
  Future<void> _reportActivationFor(
    RemoteDevice device,
    AccountsState accountsState,
  ) async {
    try {
      final account = accountsState.activeAccountOf(device);
      if (account == null) return;
      final userId = ActivationReporter.userIdFromCredentials(
        account.credentials,
      );
      if (userId == null || userId.isEmpty) return;
      final mid = await DeviceStore.instance.ensureDeviceMid(account.id);
      final reporter = ActivationReporter(
        dio: Dio(),
        userId: userId,
        deviceMid: mid,
        appVersion: await ActivationReporter.currentAppVersion(),
      );
      await reporter.report();
    } catch (e) {
      debugPrint('[claim-batch] activation ${device.id} skipped: $e');
    }
  }

  /// Blocked 同因去重窗口：同因在窗口内不重复落史（防 10min 冷却循环刷屏）。
  static const Duration blockedDedupWindow = Duration(hours: 1);

  /// 宿主后台释放通道（hostBackgroundUnavailable）的降频窗口（F3）：
  /// 属宿主侧限制非 App 可修复，6h 内同类只落一条。
  static const Duration hostBackgroundDedupWindow = Duration(hours: 6);

  final Map<String, _BlockedDedup> _blockedDedup = {};

  void _recordBlocked(
    RemoteDevice device,
    ClaimBlockedReason reason,
    String detail,
  ) {
    final last = _blockedDedup[device.id];
    final now = DateTime.now();
    final window = reason == ClaimBlockedReason.hostBackgroundUnavailable
        ? hostBackgroundDedupWindow
        : blockedDedupWindow;
    if (last != null &&
        last.reason == reason &&
        now.difference(last.at) < window) {
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
