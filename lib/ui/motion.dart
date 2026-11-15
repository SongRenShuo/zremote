import 'package:flutter/material.dart';

/// 全局动效查询（P3-3/P4-6）：AnimatedContainer/转场读它换算时长与曲线。
///
/// 开关快照由 [ZrMotion.reduced] 静态位承载（appearance 状态装载/变更时
/// 推送），避免每个动效点各自订阅 provider。
abstract final class ZrMotion {
  /// 动效减弱开关（默认关闭=正常动效；appearance 状态装载/变更时推送）。
  static bool reduced = false;

  /// 正常时长（毫秒）→ 减弱时缩短到 40%。
  static Duration duration(int normalMs) => Duration(
    milliseconds: reduced ? (normalMs * 0.4).round() : normalMs,
  );

  /// 统一转场曲线：减弱时线性（无缩放/回弹）。
  static Curve get curve => reduced ? Curves.linear : Curves.easeOutCubic;

  /// 测试复位。
  static void debugReset() => reduced = false;
}
