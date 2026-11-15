class NotificationPrefs {
  const NotificationPrefs({
    this.approval = true,
    this.complete = false,
    this.fail = false,
    this.claimResult = true,
    this.captchaManual = false,
    this.quotaLow = false,
    this.quotaAlertThreshold = 80,
    this.dndStartMinutes = 0,
    this.dndEndMinutes = 0,
  });

  final bool approval;

  final bool complete;

  final bool fail;

  /// 自动领取结果（P3-1，L3 zr_claim 渠道 success kind）。
  final bool claimResult;

  /// 需人工验证码（P3-1，L3 zr_claim 渠道 captchaNeeded kind）。
  final bool captchaManual;

  /// 额度消耗预警开关（额度中心/设置页共用）。
  final bool quotaLow;

  /// 额度预警阈值（已用百分比，默认 80；耗尽固定 100%）。
  final int quotaAlertThreshold;

  /// 免打扰起始（一天内分钟数，0-1439）。start==end 表示关闭（默认）。
  final int dndStartMinutes;

  /// 免打扰结束（一天内分钟数，0-1439）。跨零点窗口（如 23:00-08:00）
  /// 由 start>end 表达。
  final int dndEndMinutes;

  bool get dndEnabled => dndStartMinutes != dndEndMinutes;

  NotificationPrefs copyWith({
    bool? approval,
    bool? complete,
    bool? fail,
    bool? claimResult,
    bool? captchaManual,
    bool? quotaLow,
    int? quotaAlertThreshold,
    int? dndStartMinutes,
    int? dndEndMinutes,
  }) => NotificationPrefs(
    approval: approval ?? this.approval,
    complete: complete ?? this.complete,
    fail: fail ?? this.fail,
    claimResult: claimResult ?? this.claimResult,
    captchaManual: captchaManual ?? this.captchaManual,
    quotaLow: quotaLow ?? this.quotaLow,
    quotaAlertThreshold: quotaAlertThreshold ?? this.quotaAlertThreshold,
    dndStartMinutes: dndStartMinutes ?? this.dndStartMinutes,
    dndEndMinutes: dndEndMinutes ?? this.dndEndMinutes,
  );

  bool enabled(String eventType) => switch (eventType) {
    'permission_request' || 'elicitation_request' => approval,
    'completed' => complete,
    'error' => fail,
    _ => false,
  };
}
