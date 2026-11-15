import 'quota_client.dart';

/// 额度预警档位：none 不报 / warn 超阈值 / critical 耗尽（固定档）。
enum QuotaAlertLevel { none, warn, critical }

/// 预警策略常量（全局单阈值 + 耗尽固定档 + 迟滞/去重）。
abstract final class QuotaAlertPolicy {
  /// 默认预警阈值（已用百分比）。
  static const int defaultThreshold = 80;

  /// 耗尽固定档：已用 ≥100% 或剩余 ≤0。
  static const double criticalPercent = 100;

  /// 迟滞区间（点）：同档重复通知需再涨 5 点；跌回阈值-5 点以下才清零重新武装。
  static const double hysteresis = 5;

  /// 同档重复提醒最小间隔。
  static const Duration sameLevelInterval = Duration(hours: 6);

  /// 阈值合法区间。
  static int clampThreshold(int v) => v.clamp(50, 100);
}

/// 从 [QuotaOverview] 提取的预警快照（纯数据，便于全矩阵单测）。
class QuotaAlertSnapshot {
  const QuotaAlertSnapshot({
    required this.percentUsed,
    required this.remainingPercent,
    required this.planName,
    required this.resetKey,
    this.remaining,
    this.resetText,
  });

  /// 主槽已用百分比（0–100，唯一跨源可比字段）。
  final double percentUsed;

  /// 剩余百分比（100-percentUsed，钳到 0–100），仅进文案。
  final double remainingPercent;

  /// 主槽原始剩余量（带单位，不可比，仅耗尽判定用）。
  final double? remaining;

  /// 主槽展示名。
  final String planName;

  /// 清零键：套餐 id + 有效期 + 窗口重置时间；变更即视为新周期。
  final String resetKey;

  /// 重置时间文案（预计 {reset} 重置）。
  final String? resetText;
}

/// 每设备持久化水位（`zremote.quotaAlert.<deviceId>`）。
class QuotaAlertWaterLevel {
  const QuotaAlertWaterLevel({
    required this.level,
    required this.percent,
    required this.alertAtMs,
    required this.resetKey,
  });

  final QuotaAlertLevel level;
  final double percent;
  final int alertAtMs;
  final String resetKey;

  Map<String, dynamic> toJson() => {
    'level': level.name,
    'percent': percent,
    'alertAtMs': alertAtMs,
    'resetKey': resetKey,
  };

  /// 容错解析（规范 M5）：缺关键键/类型漂移一律回落 null（不预警）。
  static QuotaAlertWaterLevel? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final level = switch (raw['level']) {
      'warn' => QuotaAlertLevel.warn,
      'critical' => QuotaAlertLevel.critical,
      _ => QuotaAlertLevel.none,
    };
    if (level == QuotaAlertLevel.none) return null;
    final percent = raw['percent'];
    final alertAtMs = raw['alertAtMs'];
    final resetKey = raw['resetKey'];
    if (percent is! num || alertAtMs is! num || resetKey is! String) {
      return null;
    }
    if (resetKey.isEmpty) return null;
    return QuotaAlertWaterLevel(
      level: level,
      percent: percent.toDouble(),
      alertAtMs: alertAtMs.toInt(),
      resetKey: resetKey,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuotaAlertWaterLevel &&
      other.level == level &&
      other.percent == percent &&
      other.alertAtMs == alertAtMs &&
      other.resetKey == resetKey;

  @override
  int get hashCode => Object.hash(level, percent, alertAtMs, resetKey);
}

/// 评估结果：档位 + 是否发通知 + 需要落盘的新水位（null=不改）+ 是否清零。
class QuotaAlertEvaluation {
  const QuotaAlertEvaluation({
    required this.level,
    required this.notify,
    this.waterLevel,
    this.clear = false,
  });

  final QuotaAlertLevel level;

  /// 是否发送系统通知（含升级/迟滞/6h 判定）。
  final bool notify;

  /// 需要持久化的新水位；null 表示维持原状。
  final QuotaAlertWaterLevel? waterLevel;

  /// true 表示清空该设备的水位（迟滞重新武装）。
  final bool clear;
}

/// 纯函数预警判定：快照提取 + 档位 + 迟滞/去重。无 IO，可全矩阵单测。
abstract final class QuotaAlertEvaluator {
  /// 快照提取；不可判定（未配置/无套餐/无主槽/无 percentUsed）返回 null。
  static QuotaAlertSnapshot? snapshotOf(QuotaOverview overview) {
    if (overview.notConfigured || overview.noPlan) return null;
    final percent = overview.percentUsed;
    if (percent == null) return null;
    final primary = overview.primaryPlan;
    if (primary == null) return null;
    final main = overview.mainItemOf(primary);
    final end = primary.endsAt ?? primary.expireAt ?? overview.planExpireAt;
    final resetAt = main?.resetAt;
    final resetKey = [
      primary.pid,
      if (end != null) end.millisecondsSinceEpoch,
      if (resetAt != null) resetAt.millisecondsSinceEpoch,
    ].join('|');
    return QuotaAlertSnapshot(
      percentUsed: percent,
      remainingPercent: (100 - percent).clamp(0, 100).toDouble(),
      remaining: overview.remaining,
      planName: primary.name ?? primary.tier ?? primary.pid,
      resetKey: resetKey,
      resetText: resetAt == null ? null : formatQuotaReset(resetAt),
    );
  }

  /// 档位判定：耗尽固定档优先（≥100% 或 remaining≤0），其余按阈值。
  static QuotaAlertLevel levelOf(
    QuotaAlertSnapshot snapshot, {
    required int threshold,
  }) {
    if (snapshot.percentUsed >= QuotaAlertPolicy.criticalPercent) {
      return QuotaAlertLevel.critical;
    }
    final remaining = snapshot.remaining;
    if (remaining != null && remaining <= 0) return QuotaAlertLevel.critical;
    if (snapshot.percentUsed >= threshold) return QuotaAlertLevel.warn;
    return QuotaAlertLevel.none;
  }

  /// 迟滞/去重评估。
  ///
  /// - 快照不可判定：不报、不清水位（降级不动既有水位）；
  /// - none：跌回 `阈值-迟滞` 以下才清零重新武装；
  /// - 新周期（resetKey 变更/无历史）：立即通知；
  /// - 升级：立即通知；降级：静默更新水位（不打扰）；
  /// - 同档：再涨 ≥5 点 或 距上次通知 ≥6h 才通知。
  static QuotaAlertEvaluation evaluate({
    required QuotaAlertSnapshot? snapshot,
    required int threshold,
    QuotaAlertWaterLevel? previous,
    required DateTime now,
  }) {
    if (snapshot == null) {
      return const QuotaAlertEvaluation(level: QuotaAlertLevel.none, notify: false);
    }
    final level = levelOf(snapshot, threshold: threshold);
    if (level == QuotaAlertLevel.none) {
      final shouldClear =
          previous != null &&
          previous.level != QuotaAlertLevel.none &&
          snapshot.percentUsed <= threshold - QuotaAlertPolicy.hysteresis;
      return QuotaAlertEvaluation(
        level: QuotaAlertLevel.none,
        notify: false,
        clear: shouldClear,
      );
    }
    final previousSameCycle =
        previous != null && previous.resetKey == snapshot.resetKey;
    if (!previousSameCycle) {
      return QuotaAlertEvaluation(
        level: level,
        notify: true,
        waterLevel: _water(level, snapshot, now),
      );
    }
    if (level.index > previous.level.index) {
      return QuotaAlertEvaluation(
        level: level,
        notify: true,
        waterLevel: _water(level, snapshot, now),
      );
    }
    if (level.index < previous.level.index) {
      // 降级（如耗尽→高水位）：静默更新基线，不重复打扰。
      return QuotaAlertEvaluation(
        level: level,
        notify: false,
        waterLevel: _water(level, snapshot, now),
      );
    }
    if (snapshot.percentUsed >=
        previous.percent + QuotaAlertPolicy.hysteresis) {
      return QuotaAlertEvaluation(
        level: level,
        notify: true,
        waterLevel: _water(level, snapshot, now),
      );
    }
    if (now.millisecondsSinceEpoch - previous.alertAtMs >=
        QuotaAlertPolicy.sameLevelInterval.inMilliseconds) {
      return QuotaAlertEvaluation(
        level: level,
        notify: true,
        waterLevel: _water(level, snapshot, now),
      );
    }
    return QuotaAlertEvaluation(level: level, notify: false);
  }

  static QuotaAlertWaterLevel _water(
    QuotaAlertLevel level,
    QuotaAlertSnapshot snapshot,
    DateTime now,
  ) => QuotaAlertWaterLevel(
    level: level,
    percent: snapshot.percentUsed,
    alertAtMs: now.millisecondsSinceEpoch,
    resetKey: snapshot.resetKey,
  );

  /// 重置时间文案（绝对时间，MM-dd HH:mm）。
  static String formatQuotaReset(DateTime t) =>
      '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
