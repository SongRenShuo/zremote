import 'package:flutter/widgets.dart' show AppLifecycleState;

/// 后台保活心跳策略（D1）。
///
/// 完成事件通知完全寄生在「宿主 WebView 内的注入 JS 观察者」上：
/// JS 的 fetch / WebSocket / 轮询把事件经 callHandler 回传 Dart，Dart 才弹通知。
/// 切后台后 Doze / 厂商冻结 / WebView 后台节流会让 JS 停摆，导致任务完成
/// 事件根本没被观察到（回前台 reload 后靠 StateDiffer 对全量快照 diff 才补发）。
///
/// 保活前台服务只能保证 Dart 进程存活，不能保证 WebView JS 在后台继续执行。
/// 本策略在「保活开启 + 设备在线 + 应用处于后台」时，按固定周期返回 true，
/// 由会话页据此用 evaluateJavascript 主动唤醒注入 JS 的轮询，使事件链路保持活着。
///
/// 纯策略类，不持有 Timer、不触碰平台通道，便于单测。
abstract final class BackgroundHeartbeatPolicy {
  /// 后台唤醒周期。需明显短于注入 JS 的 45s revive 上限，避免轮询被判定僵死。
  static const Duration interval = Duration(seconds: 20);

  static const Set<AppLifecycleState> _backgroundStates = {
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  };

  static bool isBackgrounded(AppLifecycleState state) =>
      _backgroundStates.contains(state);

  /// 是否应执行一次后台唤醒。
  ///
  /// [keepAliveEnabled] 用户保活开关；[hasDevices] 是否有在线设备；
  /// [lifecycle] 当前生命周期；[sinceLastTick] 距上次唤醒的时长。
  static bool shouldTick({
    required bool keepAliveEnabled,
    required bool hasDevices,
    required AppLifecycleState lifecycle,
    required Duration sinceLastTick,
  }) {
    if (!keepAliveEnabled) return false;
    if (!hasDevices) return false;
    if (!isBackgrounded(lifecycle)) return false;
    return sinceLastTick >= interval;
  }
}

/// 心跳节拍器：记录上次唤醒时刻，并按 [BackgroundHeartbeatPolicy] 判定。
///
/// 由会话页在后台定时器里调用 [consider]，返回 true 时执行一次 JS 唤醒。
class BackgroundHeartbeat {
  BackgroundHeartbeat({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _lastTick;

  bool consider({
    required bool keepAliveEnabled,
    required bool hasDevices,
    required AppLifecycleState lifecycle,
  }) {
    final now = _now();
    final last = _lastTick;
    final since = last == null ? const Duration(days: 365) : now.difference(last);
    if (!BackgroundHeartbeatPolicy.shouldTick(
      keepAliveEnabled: keepAliveEnabled,
      hasDevices: hasDevices,
      lifecycle: lifecycle,
      sinceLastTick: since,
    )) {
      return false;
    }
    _lastTick = now;
    return true;
  }

  /// 回到前台时重置节拍，避免下次切后台立刻连击。
  void resetOnForeground(AppLifecycleState lifecycle) {
    if (!BackgroundHeartbeatPolicy.isBackgrounded(lifecycle)) {
      _lastTick = null;
    }
  }
}
