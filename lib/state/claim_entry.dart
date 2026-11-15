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

/// 「服务可用（能力）」三态：宿主是否挂载了领券服务。
///
/// 与 [ClaimEntryNotifier]（「有可领」业务态）**分离**：
/// - `unknown`：尚未探测（入口按可用处理，避免"没探测就先灰"）。
/// - `available`：`getManualClaimPlanPreviews` 可达（无券也算可用）。
/// - `unavailable`：探测结论为不可用，[ClaimServiceState.reason] 给原因码。
enum ClaimServiceStatus { unknown, available, unavailable }

/// 单设备的领券服务（能力）状态。
///
/// 原因码与 `ServiceProbe.checkClaimService` 的结论一一对应
/// （`no-method` / `no-services` / `probe-failed`），UI 据此给可读文案。
class ClaimServiceState {
  const ClaimServiceState({this.status = ClaimServiceStatus.unknown, this.reason});

  final ClaimServiceStatus status;
  final String? reason;

  bool get available => status == ClaimServiceStatus.available;

  /// 不可用且带原因码 → 卡片/页面可展示"为什么灰"。
  bool get diagnosable =>
      status == ClaimServiceStatus.unavailable && reason != null;

  @override
  bool operator ==(Object other) =>
      other is ClaimServiceState &&
      other.status == status &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(status, reason);
}

/// 领券服务（能力）状态表。只由定点服务检查（`ServiceProbe.checkClaimService`）
/// 与领券页自身的接口回写驱动，**不被"无券可领"回写**。
class ClaimServiceNotifier extends Notifier<Map<String, ClaimServiceState>> {
  @override
  Map<String, ClaimServiceState> build() => const {};

  void report(String deviceId, ClaimServiceState value) {
    if (state[deviceId] == value) return;
    state = {...state, deviceId: value};
  }

  /// 探针结论回写；可用时清空原因码。
  void mark(String deviceId, bool available, {String? reason}) => report(
    deviceId,
    ClaimServiceState(
      status: available
          ? ClaimServiceStatus.available
          : ClaimServiceStatus.unavailable,
      reason: available ? null : reason,
    ),
  );

  /// 回到未探测（页面重载/重连时复位，等待下一次探针）。
  void reset(String deviceId) => report(deviceId, const ClaimServiceState());

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final claimServiceProvider =
    NotifierProvider<ClaimServiceNotifier, Map<String, ClaimServiceState>>(
      ClaimServiceNotifier.new,
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
