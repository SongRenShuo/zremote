import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../services/notifier.dart';
import '../services/quota_alert.dart';
import '../services/quota_client.dart';
import 'accounts.dart';
import 'approval_center.dart';
import 'notification_prefs.dart';
import 'session_pool.dart';
import 'session_status.dart';

/// 额度预警状态层：per-device 水位 + 全局阈值，页面刷新与后台节拍共用
/// [evaluateDevice]。判据/迟滞全在纯函数 [QuotaAlertEvaluator]，本类只做
/// 持久化与通知发送。
class QuotaAlertNotifier extends Notifier<Map<String, QuotaAlertWaterLevel>> {
  @override
  Map<String, QuotaAlertWaterLevel> build() => const {};

  /// 评估一次额度总览：开关关/不可判定一律不报；命中则落水位并发通知。
  ///
  /// 返回评估结果供调用方（页面/测试）读数；持久化与通知异常一律吞掉
  /// （预警是增强功能，不阻断额度拉取主链路）。
  Future<QuotaAlertEvaluation> evaluateDevice(
    RemoteDevice device,
    QuotaOverview overview, {
    DateTime? now,
  }) async {
    const degraded = QuotaAlertEvaluation(
      level: QuotaAlertLevel.none,
      notify: false,
    );
    try {
      final prefs = ref.read(notificationPrefsProvider);
      if (!prefs.quotaLow) return degraded;
      final snapshot = QuotaAlertEvaluator.snapshotOf(overview);
      if (snapshot == null) return degraded;
      final previous = state[device.id] ?? await _load(device.id);
      final evaluation = QuotaAlertEvaluator.evaluate(
        snapshot: snapshot,
        threshold: prefs.quotaAlertThreshold,
        previous: previous,
        now: now ?? DateTime.now(),
      );
      if (evaluation.clear) {
        await _save(device.id, null);
        state = Map.of(state)..remove(device.id);
      } else if (evaluation.waterLevel != null) {
        await _save(device.id, evaluation.waterLevel!);
        state = {...state, device.id: evaluation.waterLevel!};
      }
      if (evaluation.notify) {
        final claimAuto = await DeviceStore.instance.claimAutoConfig(device.id);
        await NotifierService.instance.notifyQuotaLow(
          device: device,
          level: evaluation.level,
          snapshot: snapshot,
          claimAutoEnabled: claimAuto.enabled,
        );
      }
      return evaluation;
    } catch (e) {
      debugPrint('[quota-alert] evaluate failed: $e');
      return degraded;
    }
  }

  Future<QuotaAlertWaterLevel?> _load(String deviceId) async {
    try {
      return await DeviceStore.instance.quotaAlertWaterLevel(deviceId);
    } catch (e) {
      debugPrint('[quota-alert] water level load failed: $e');
      return null;
    }
  }

  Future<void> _save(String deviceId, QuotaAlertWaterLevel? level) async {
    try {
      await DeviceStore.instance.saveQuotaAlertWaterLevel(deviceId, level);
    } catch (e) {
      debugPrint('[quota-alert] water level save failed: $e');
    }
  }
}

final quotaAlertProvider =
    NotifierProvider<QuotaAlertNotifier, Map<String, QuotaAlertWaterLevel>>(
      QuotaAlertNotifier.new,
    );

/// 后台节拍（额度预警）：低频 sweep，仅设备 live 且会话已挂桥时拉取评估。
///
/// 默认 30min 一轮（可关：不调用 [start] 即不跑）；由 app_shell 在有设备后
/// 启动。额度主链路仍以「每次成功 fetch 后评估」为准，本节拍是后台补充。
class QuotaAlertWatcher extends Notifier<bool> {
  Timer? _timer;

  @override
  bool build() {
    // 销毁只停表，不改 state（onDispose 期间禁止写状态）。
    ref.onDispose(_cancelTimer);
    return false;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 启动周期 sweep；重复调用为 no-op（已运行）。
  void start({
    Duration period = const Duration(minutes: 30),
    DateTime Function()? now,
  }) {
    if (_timer != null) return;
    _timer = Timer.periodic(period, (_) => unawaited(sweep()));
    state = true;
    // 立即跑一轮（首帧后），不等整个周期。
    unawaited(sweep(now: now));
  }

  void stop() {
    _cancelTimer();
    state = false;
  }

  /// 单轮 sweep：遍历 live 设备，逐台拉取并评估。单台失败不影响其余。
  Future<void> sweep({DateTime Function()? now}) async {
    try {
      if (!ref.read(notificationPrefsProvider).quotaLow) return;
      final devices = ref.read(deviceListProvider);
      if (devices.isEmpty) return;
      final statuses = ref.read(sessionStatusProvider);
      final accounts = ref.read(accountsProvider);
      for (final device in devices) {
        if (statuses[device.id] != SessionStatus.live) continue;
        final bridge = ref
            .read(approvalCenterProvider.notifier)
            .clientOf(device.id)
            ?.bridge;
        if (bridge == null) continue;
        try {
          final tokens = ticketsOfActiveAccount(accounts, device).quotaTokens;
          final client = QuotaClient(
            bridge: bridge,
            tokenProvider: () async => tokens,
          );
          final params = await client.loadEntitlementParams();
          final overview = await client.fetch(entitlementParams: params);
          await ref
              .read(quotaAlertProvider.notifier)
              .evaluateDevice(device, overview, now: now?.call());
        } catch (e) {
          debugPrint('[quota-alert] sweep ${device.id} failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[quota-alert] sweep failed: $e');
    }
  }
}

final quotaAlertWatcherProvider =
    NotifierProvider<QuotaAlertWatcher, bool>(QuotaAlertWatcher.new);
