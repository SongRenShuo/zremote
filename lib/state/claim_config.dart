import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/claim_scheduler.dart';
import '../services/device_store.dart';

/// 每设备自动领取配置（P2-5）：`zremote.claimConfig.<deviceId>`。
/// 开关默认关（zcode-switch 同款安全默认）。
class ClaimConfigNotifier extends Notifier<Map<String, ClaimAutoConfig>> {
  @override
  Map<String, ClaimAutoConfig> build() => const {};

  /// 页面/会话按需加载（未加载设备的读数回落默认配置=关）。
  Future<void> load(String deviceId) async {
    if (state.containsKey(deviceId)) return;
    final config = await DeviceStore.instance.claimAutoConfig(deviceId);
    if (state.containsKey(deviceId)) return;
    state = {...state, deviceId: config};
  }

  Future<void> _save(String deviceId, ClaimAutoConfig config) async {
    state = {...state, deviceId: config};
    await DeviceStore.instance.saveClaimAutoConfig(deviceId, config);
  }

  Future<void> setEnabled(String deviceId, bool enabled) => _save(
    deviceId,
    (state[deviceId] ?? const ClaimAutoConfig()).copyWith(enabled: enabled),
  );

  Future<void> setSilent(String deviceId, int startMinutes, int endMinutes) =>
      _save(
        deviceId,
        (state[deviceId] ?? const ClaimAutoConfig()).copyWith(
          silentStartMinutes: startMinutes,
          silentEndMinutes: endMinutes,
        ),
      );
}

final claimConfigProvider =
    NotifierProvider<ClaimConfigNotifier, Map<String, ClaimAutoConfig>>(
      ClaimConfigNotifier.new,
    );

/// 全局自动领取总闸（20261117-0024 G1，zcode-switch auto_claim 同语义）：
/// 实际自动领取 = 全局 && 设备开关。默认开（升级零回归，计划 §3 裁定）。
class ClaimGlobalEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void>? _lastSave;

  /// 最近一次落盘 future（测试用；生产侧 fire-and-forget）。
  @visibleForTesting
  Future<void> get lastSave => _lastSave ?? Future<void>.value();

  /// 会话挂桥/页面加载时读盘（未加载时内存态回落默认开）。
  Future<void> load() async {
    state = await DeviceStore.instance.claimGlobalEnabled();
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final previous = _lastSave ?? Future<void>.value();
    _lastSave = previous
        .then((_) => DeviceStore.instance.saveClaimGlobalEnabled(enabled))
        .catchError((Object e) {
      debugPrint('[claim-config] global save failed: $e');
      return;
    });
    unawaited(_lastSave);
  }
}

final claimGlobalEnabledProvider =
    NotifierProvider<ClaimGlobalEnabledNotifier, bool>(
      ClaimGlobalEnabledNotifier.new,
    );
