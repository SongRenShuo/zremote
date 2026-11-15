import 'package:flutter/services.dart';

/// 触感反馈统一封装（P3-3/P4-6）：内部判断开关（appearance 状态推送），
/// 关闭时零系统调用。
///
/// - tap：开关切换/普通点击；
/// - success：导入成功/领取成功等确认性动作；
/// - warn：删除确认/失败警示。
abstract final class ZrHaptics {
  /// 触感开关快照（默认开；appearance 装载/变更时推送）。
  static bool enabled = true;

  static void tap() {
    if (!enabled) return;
    HapticFeedback.selectionClick();
  }

  static void success() {
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  static void warn() {
    if (!enabled) return;
    HapticFeedback.heavyImpact();
  }
}
