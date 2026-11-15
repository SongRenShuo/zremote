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
