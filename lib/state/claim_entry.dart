import 'package:flutter_riverpod/flutter_riverpod.dart';

class ClaimEntryNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void report(String deviceId, bool visible) {
    if (state[deviceId] == visible) return;
    state = {...state, deviceId: visible};
  }

  void reset(String deviceId) => report(deviceId, false);

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final claimEntryProvider =
    NotifierProvider<ClaimEntryNotifier, Map<String, bool>>(
      ClaimEntryNotifier.new,
    );

/// 领取结果通知点击 → 打开对应设备领取页的请求（P2-7 通知路由）。
/// app_shell 发起（payload `claim:<deviceId>`），目标 SessionView 消费。
class ClaimOpenRequestNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void request(String deviceId) {
    if (state == deviceId) return;
    state = deviceId;
  }

  void consume() => state = null;
}

final claimOpenRequestProvider =
    NotifierProvider<ClaimOpenRequestNotifier, String?>(
      ClaimOpenRequestNotifier.new,
    );
