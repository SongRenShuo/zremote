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

  /// 设备领取页单独切换开关：打 locallyOverridden 标记（20261117-1230 R1）。
  /// 打标后该设备不再受全局总开关批量写入影响（"单独设置优先"）。
  Future<void> setEnabled(String deviceId, bool enabled) => _save(
    deviceId,
    (state[deviceId] ?? const ClaimAutoConfig()).copyWith(
      enabled: enabled,
      locallyOverridden: true,
    ),
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

/// 全局自动领取总开关（20261117-1230 R1 单层语义，替代 20261117-0024 的
/// 双层门控）：state = "新设备默认启停值"（默认开，升级零回归）。
/// 切换时批量写入所有设备的领取配置（跳过 locallyOverridden 的设备），
/// 不再作为运行期门控——每台设备只看自己的 enabled。
class ClaimGlobalEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void>? _lastSave;

  /// 最近一次落盘 future（测试用；生产侧 fire-and-forget）。
  @visibleForTesting
  Future<void> get lastSave => _lastSave ?? Future<void>.value();

  /// 加载全局默认值（未加载时内存态回落默认开）。
  Future<void> load() async {
    state = await DeviceStore.instance.claimGlobalEnabled();
  }

  /// 一键设置全部：批量写入所有未独立设置的设备，返回被改写 id。
  /// 调用方可用返回 id 即时同步已装配代理（R1-3）。
  Future<List<String>> applyAll(bool enabled) async {
    state = enabled;
    try {
      return await DeviceStore.instance.applyGlobalClaimDefault(enabled);
    } catch (e) {
      debugPrint('[claim-config] global apply failed: $e');
      return const <String>[];
    }
  }

  /// 兼容旧调用点：不关心受影响 id（fire-and-forget 串行落盘）。
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
