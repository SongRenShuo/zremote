import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/claim.dart';
import 'rpc_bridge.dart';

/// 自动领取状态机常量（开发计划附录 C，zcode-switch 移植源）。
abstract final class ClaimSchedulerPolicy {
  /// 轮间隔基准 10min（±20% jitter，见 [roundIntervalJittered]）。
  static const Duration roundInterval = Duration(minutes: 10);

  /// 启动后首轮延迟 2min。
  static const Duration firstDelay = Duration(minutes: 2);

  /// 单次 claimManualPlan 结果等待 45s。
  static const Duration claimWait = Duration(seconds: 45);

  /// 单账号单轮连领上限（成功后重新 preview 继续）。
  static const int perRoundCap = 5;

  /// 手动刷新/领取时自动轮让位预算（最迟退出时限）。
  static const Duration autoAbortWait = Duration(seconds: 90);

  /// 手动操作结束后的自动轮冷却。
  static const Duration manualCooldown = Duration(seconds: 60);

  /// 其他业务码（≥1000，除 1005/3007）冷却 1h。
  static const Duration businessCodeCooldown = Duration(hours: 1);

  /// 需人工验证码冷却 1h（+ 通知）。
  static const Duration captchaCooldown = Duration(hours: 1);

  /// 其他失败（网络/超时/未知）冷却 10min。
  static const Duration genericFailureCooldown = Duration(minutes: 10);

  /// 设备非 live 时的复查间隔。
  static const Duration liveRecheck = Duration(seconds: 30);

  /// 手动操作进行中的复查间隔。
  static const Duration manualRecheck = Duration(seconds: 5);

  /// 静默时段默认 23:00–08:00（分钟数，跨天）。
  static const int defaultSilentStart = 23 * 60;

  static const int defaultSilentEnd = 8 * 60;

  /// 轮询间隔默认 10min；可配置范围 [1, 120] 分钟（20261118-0110 G1）。
  static const int defaultIntervalMinutes = 10;
  static const int minIntervalMinutes = 1;
  static const int maxIntervalMinutes = 120;

  /// 轮间隔 = 基准 ±20% jitter。基准来自每设备配置（20261118-0110 G2），
  /// 默认 10min；间隔 1min 时抖动带为 [0.8min, 1.2min]。
  static Duration roundIntervalJittered(
    math.Random random, {
    int baseMinutes = 10,
  }) {
    final baseMs = baseMinutes * 60 * 1000;
    final span = (baseMs * 0.20).round();
    final offset = (random.nextDouble() * 2 - 1) * span;
    return Duration(milliseconds: baseMs + offset.round());
  }

  /// 静默判定：start == end 视为关闭；start > end 为跨天窗口（如 23:00–08:00）。
  static bool isSilentAt(
    DateTime now, {
    required int silentStartMinutes,
    required int silentEndMinutes,
  }) {
    if (silentStartMinutes == silentEndMinutes) return false;
    final minuteOfDay = now.hour * 60 + now.minute;
    if (silentStartMinutes > silentEndMinutes) {
      return minuteOfDay >= silentStartMinutes || minuteOfDay < silentEndMinutes;
    }
    return minuteOfDay >= silentStartMinutes && minuteOfDay < silentEndMinutes;
  }

  /// 距静默窗口结束（可重新触发）的等待时长；不在静默中返回 [Duration.zero]。
  static Duration silentWait(
    DateTime now, {
    required int silentStartMinutes,
    required int silentEndMinutes,
  }) {
    if (!isSilentAt(
      now,
      silentStartMinutes: silentStartMinutes,
      silentEndMinutes: silentEndMinutes,
    )) {
      return Duration.zero;
    }
    var end = DateTime(
      now.year,
      now.month,
      now.day,
      silentEndMinutes ~/ 60,
      silentEndMinutes % 60,
    );
    if (!end.isAfter(now)) {
      // 跨天窗口（end 已过今天的点）→ 结束点在明天。
      end = end.add(const Duration(days: 1));
    }
    return end.difference(now);
  }
}

/// 每设备自动领取配置（持久化键 `zremote.claimConfig.<deviceId>`）。
/// 开关默认关（zcode-switch 同款安全默认）。
class ClaimAutoConfig {
  const ClaimAutoConfig({
    this.enabled = false,
    this.silentStartMinutes = ClaimSchedulerPolicy.defaultSilentStart,
    this.silentEndMinutes = ClaimSchedulerPolicy.defaultSilentEnd,
    this.locallyOverridden = false,
    this.intervalMinutes = ClaimSchedulerPolicy.defaultIntervalMinutes,
  });

  final bool enabled;

  /// 静默窗口开始（当天分钟数，默认 23*60）。
  final int silentStartMinutes;

  /// 静默窗口结束（当天分钟数，默认 8*60，不含）。
  final int silentEndMinutes;

  /// 用户在该设备领取页单独切换过开关（20261117-1230 R1）。
  /// true = 设备自己说了算，全局总开关批量写入时跳过此设备。
  /// 缺省 false：旧数据与新设备默认都跟随全局。
  final bool locallyOverridden;

  /// 轮询间隔基准（分钟，20261118-0110 G1）：默认 10，clamp [1,120]。
  /// 实际间隔 = 基准 ±20% 抖动。
  final int intervalMinutes;

  /// start == end 表示关闭静默时段。
  bool get silentEnabled => silentStartMinutes != silentEndMinutes;

  ClaimAutoConfig copyWith({
    bool? enabled,
    int? silentStartMinutes,
    int? silentEndMinutes,
    bool? locallyOverridden,
    int? intervalMinutes,
  }) => ClaimAutoConfig(
    enabled: enabled ?? this.enabled,
    silentStartMinutes: silentStartMinutes ?? this.silentStartMinutes,
    silentEndMinutes: silentEndMinutes ?? this.silentEndMinutes,
    locallyOverridden: locallyOverridden ?? this.locallyOverridden,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'silentStart': silentStartMinutes,
    'silentEnd': silentEndMinutes,
    'locallyOverridden': locallyOverridden,
    'intervalMinutes': intervalMinutes,
  };

  /// 容错解析：字段缺失/类型漂移回落默认值（规范 M5）。
  static ClaimAutoConfig fromJson(Map<String, dynamic> j) => ClaimAutoConfig(
    enabled: j['enabled'] == true,
    silentStartMinutes:
        j['silentStart'] is num
        ? (j['silentStart'] as num).toInt().clamp(0, 24 * 60 - 1)
        : ClaimSchedulerPolicy.defaultSilentStart,
    silentEndMinutes:
        j['silentEnd'] is num
        ? (j['silentEnd'] as num).toInt().clamp(0, 24 * 60 - 1)
        : ClaimSchedulerPolicy.defaultSilentEnd,
    locallyOverridden: j['locallyOverridden'] == true,
    intervalMinutes:
        j['intervalMinutes'] is num
        ? (j['intervalMinutes'] as num).toInt().clamp(1, 120)
        : ClaimSchedulerPolicy.defaultIntervalMinutes,
  );

  @override
  bool operator ==(Object other) =>
      other is ClaimAutoConfig &&
      other.enabled == enabled &&
      other.silentStartMinutes == silentStartMinutes &&
      other.silentEndMinutes == silentEndMinutes &&
      other.locallyOverridden == locallyOverridden &&
      other.intervalMinutes == intervalMinutes;

  @override
  int get hashCode => Object.hash(
    enabled,
    silentStartMinutes,
    silentEndMinutes,
    locallyOverridden,
    intervalMinutes,
  );
}

/// 领取链路 RPC 门面（通路 A 宿主 RPC / 通路 B 直连实验位共用接口）。
abstract class ClaimRpcClient {
  /// 可领套餐预览（已按 priority 降序、planId 升序排序）。
  Future<List<ClaimPreview>> fetchPreviews();

  Future<CaptchaConfig> fetchCaptchaConfig();

  /// 无感验证；返回 null 表示需要人工（后台不可交互，不发 claim）。
  Future<String?> verifyCaptcha(CaptchaConfig config);

  Future<ClaimOutcome> claim({
    required String planId,
    required String captchaVerifyParam,
    String? captchaRegion,
  });
}

/// 账号未配置套餐（宿主业务错 manual_claim_preview_missing_data 的
/// 结构化形态）：自动轮按"业务态"干净收轮，不冷却。
class ClaimPreviewMissingData implements Exception {
  const ClaimPreviewMissingData();

  @override
  String toString() => 'manual_claim_preview_missing_data';
}

/// 通路 A：宿主 RPC（默认）。方法与参数形状对齐 claim_page 手动链路。
class HostClaimRpcClient implements ClaimRpcClient {
  HostClaimRpcClient(this._bridge);

  final RpcBridge _bridge;

  @override
  Future<List<ClaimPreview>> fetchPreviews() async {
    late final RpcResponse r;
    try {
      r = await _bridge.call(
        'coding-plan-subscription',
        'getManualClaimPlanPreviews',
        timeout: const Duration(seconds: 10),
      );
    } on RpcRemoteException catch (e) {
      // 宿主实测（2026-11-14）：账号未配置套餐抛业务错
      // manual_claim_preview_missing_data —— 视为"无券可领"而非失败。
      // 结构化抛出（20261116-2341）：自动轮据此落"未绑套餐"阻断记录，
      // 与普通"无券"区分（补救路径不同：绑套餐 vs 等放券）。
      if (e.message.contains('manual_claim_preview_missing_data')) {
        throw const ClaimPreviewMissingData();
      }
      rethrow;
    }
    final obj = r.firstObjectDeep;
    final rawPlans = obj?['plans'] ?? obj?['previews'];
    final previews = <ClaimPreview>[
      if (rawPlans is List)
        for (final p in rawPlans)
          if (p is Map<String, dynamic>) ?ClaimPreview.fromJson(p),
    ];
    previews.sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      return byPriority != 0 ? byPriority : a.planId.compareTo(b.planId);
    });
    return previews;
  }

  @override
  Future<CaptchaConfig> fetchCaptchaConfig() async {
    final r = await _bridge.call('coding-plan-subscription', 'getCaptchaConfig');
    return CaptchaConfig.fromJson(r.firstObject ?? const {});
  }

  @override
  Future<String?> verifyCaptcha(CaptchaConfig config) async {
    try {
      final r = await _bridge.call(
        'zr-captcha',
        'verify',
        params: {
          'sceneId': config.sceneId,
          'prefix': config.prefix,
          'region': config.region,
          'timeoutMs': 8000,
        },
        timeout: const Duration(seconds: 20),
      );
      final v = r.firstObject;
      final param = v?['param'];
      if (v == null || v['ok'] != true || param is! String || param.isEmpty) {
        return null;
      }
      return param;
    } catch (_) {
      // 无感失败 → 需人工（不自动弹框——后台不可交互）。
      return null;
    }
  }

  @override
  Future<ClaimOutcome> claim({
    required String planId,
    required String captchaVerifyParam,
    String? captchaRegion,
  }) async {
    // 红线：无 captchaVerifyParam 不发 claimManualPlan（本地拒绝）。
    if (captchaVerifyParam.isEmpty) {
      throw ArgumentError.value(
        captchaVerifyParam,
        'captchaVerifyParam',
        '红线：无验证码参数不发 claimManualPlan',
      );
    }
    final r = await _bridge.call(
      'coding-plan-subscription',
      'claimManualPlan',
      params: {
        'planId': planId,
        'captchaVerifyParam': captchaVerifyParam,
        if (captchaRegion != null && captchaRegion.isNotEmpty)
          'captchaRegion': captchaRegion,
      },
      timeout: ClaimSchedulerPolicy.claimWait,
    );
    return ClaimOutcome.fromJson(r.firstObject ?? const {});
  }
}

/// 通路 B（直连 HTTP）实验位（P2-8）：**默认关闭，本期不实现直连**。
///
/// 上线路径预留：离线直连 `billing/preview` + `billing/claim`（JWT 取自
/// 注入时缓存），`requestVerificationClaimHeaders` 预留空实现位（正式版
/// 可能注入签名头，R4）。启用前须补直连请求头全套（附录 A）与风控评估。
class DirectClaimRpcClient implements ClaimRpcClient {
  DirectClaimRpcClient();

  /// 实验位默认关闭：本期不接直连，接入方须先补附录 A 头全套与风控评估。
  static const bool experimentalDefault = false;

  @override
  Future<List<ClaimPreview>> fetchPreviews() async =>
      throw UnsupportedError('P2-8 通路 B 实验位：默认关闭，本期未实现直连');

  @override
  Future<CaptchaConfig> fetchCaptchaConfig() async =>
      throw UnsupportedError('P2-8 通路 B 实验位：默认关闭，本期未实现直连');

  @override
  Future<String?> verifyCaptcha(CaptchaConfig config) async =>
      throw UnsupportedError('P2-8 通路 B 实验位：默认关闭，本期未实现直连');

  @override
  Future<ClaimOutcome> claim({
    required String planId,
    required String captchaVerifyParam,
    String? captchaRegion,
  }) async => throw UnsupportedError('P2-8 通路 B 实验位：默认关闭，本期未实现直连');
}

/// 冷却决策（纯函数）：按附录 C 矩阵分类。
class ClaimCooldownDecision {
  const ClaimCooldownDecision({required this.cooldown, this.captchaNeeded = false});

  /// 冷却时长；[Duration.zero] 表示无需冷却。
  final Duration cooldown;

  /// 需人工验证码（1h + 通知）。
  final bool captchaNeeded;

  static ClaimCooldownDecision of({
    int? code,
    DateTime? failureEndsAt,
    required DateTime now,
  }) {
    // 1005 今日名额尽 → 服务端 ends_at 精确冷却；ends_at 已过 → 立即可再试；
    // 缺失 ends_at 回落 1h。
    if (code == 1005) {
      if (failureEndsAt != null) {
        return failureEndsAt.isAfter(now)
            ? ClaimCooldownDecision(cooldown: failureEndsAt.difference(now))
            : const ClaimCooldownDecision(cooldown: Duration.zero);
      }
      return const ClaimCooldownDecision(
        cooldown: ClaimSchedulerPolicy.businessCodeCooldown,
      );
    }
    // 3007 验证码校验失败 → 需人工，1h + 通知。
    if (code == 3007) {
      return const ClaimCooldownDecision(
        cooldown: ClaimSchedulerPolicy.captchaCooldown,
        captchaNeeded: true,
      );
    }
    // 其他业务码（≥1000）→ 1h。
    if (code != null && code >= 1000) {
      return const ClaimCooldownDecision(
        cooldown: ClaimSchedulerPolicy.businessCodeCooldown,
      );
    }
    // 其他失败（401/网络/超时/未知）→ 10min。
    return const ClaimCooldownDecision(
      cooldown: ClaimSchedulerPolicy.genericFailureCooldown,
    );
  }
}

/// 调度器对外事件（历史落账 / 通知的输入）。
sealed class ClaimSchedulerEvent {
  const ClaimSchedulerEvent();
}

class ClaimAutoSucceeded extends ClaimSchedulerEvent {
  const ClaimAutoSucceeded({required this.plan, required this.outcome});

  final ClaimPreview plan;

  final ClaimOutcome outcome;
}

class ClaimAutoFailed extends ClaimSchedulerEvent {
  const ClaimAutoFailed({
    required this.plan,
    this.outcome,
    this.error = '',
    this.captchaNeeded = false,
  });

  final ClaimPreview plan;

  final ClaimOutcome? outcome;

  /// RPC 抛错（无业务 outcome）时的错误描述。
  final String error;

  final bool captchaNeeded;
}

class ClaimAutoCaptchaNeeded extends ClaimSchedulerEvent {
  const ClaimAutoCaptchaNeeded({required this.plan});

  final ClaimPreview plan;
}

/// 自动轮被阻断的原因（20261116-2341 D1：静默失败可见化）。
enum ClaimBlockedReason {
  /// preview RPC 异常（网络/超时/服务错误）。
  previewError,

  /// 验证码配置 RPC 异常。
  captchaConfigError,

  /// 活动暂不可领（验证码通道未开 / sceneId 空）。
  activityClosed,

  /// 无券可领（preview 空列表）。
  noPlans,

  /// 账号未配置套餐（manual_claim_preview_missing_data）。
  accountNotConfigured,

  /// 宿主后台已释放通道（ChannelClient is disposed，L39 宿主侧限制）：
  /// 前台打开设备页面后自动恢复。落史降频（6h 窗口，20261118-0030 F3）。
  hostBackgroundUnavailable,
}

/// 自动轮阻断事件：本轮没有产生任何领取动作的原因。
/// 装配层（hub）落历史并同因去重，替代原先只 debugPrint 的静默路径。
class ClaimAutoBlocked extends ClaimSchedulerEvent {
  const ClaimAutoBlocked({required this.reason, this.detail = ''});

  final ClaimBlockedReason reason;

  /// 异常详情（仅 *_error 类原因携带）。
  final String detail;
}

/// 自动轮状态快照（UI 展示冷却/在飞/启用态，D1③）。
class ClaimSchedulerSnapshot {
  const ClaimSchedulerSnapshot({
    required this.enabled,
    required this.roundInFlight,
    required this.running,
    this.cooldownUntil,
    this.manualCooldownUntil,
    this.nextRoundAt,
    this.intervalMinutes = 10,
  });

  final bool enabled;

  final bool roundInFlight;

  /// 循环是否已启动（false = 停表/未启动）。
  final bool running;

  /// 失败冷却截止（null = 无冷却）。
  final DateTime? cooldownUntil;

  /// 手动操作冷却截止（null = 无冷却）。
  final DateTime? manualCooldownUntil;

  /// 下次轮询时刻（20261118-0110 G3）：null = 未启动 / 轮次在飞。
  final DateTime? nextRoundAt;

  /// 轮询间隔基准（分钟，倒计时进度条分母用）。
  final int intervalMinutes;
}

/// 自动领取调度代理（纯逻辑，时钟/延迟/RPC 全注入，可全矩阵单测）。
///
/// 生命周期由装配层（claim_scheduler_hub）驱动：attach 时创建并按配置
/// start，设备移除/会话 dispose 时 stop。Android 后台续跑依托保活前台
/// 服务（实测读数验证），iOS 不承诺。
class ClaimSchedulerAgent {
  ClaimSchedulerAgent({
    required this.deviceId,
    required ClaimRpcClient client,
    ClaimAutoConfig config = const ClaimAutoConfig(),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    math.Random? random,
    this.onEvent,
    this.beforePreview,
  }) : _client = client,
       _config = config,
       _nowFunc = now ?? DateTime.now,
       _delayFunc = delay ?? Future<void>.delayed,
       _random = random ?? math.Random();

  final String deviceId;

  final ClaimRpcClient _client;

  ClaimAutoConfig _config;

  final DateTime Function() _nowFunc;

  final Future<void> Function(Duration) _delayFunc;

  final math.Random _random;

  /// 事件回调（成功/失败/需人工验证码）；装配层负责历史与通知。
  final void Function(ClaimSchedulerEvent event)? onEvent;

  /// 每轮 preview 前的激活钩子（20261118-0030 F2：上报 app_launch/
  /// app_daily_active 让服务端出可领套餐）。异常由装配层静默吞掉，
  /// 不阻断轮次。
  final Future<void> Function()? beforePreview;

  bool _started = false;
  bool _roundInFlight = false;
  bool _live = true;
  bool _manualActive = false;
  bool _abortRequested = false;

  /// 代际令牌：stop/重启后旧循环在下一个检查点退出（防双循环）。
  int _generation = 0;

  DateTime? _cooldownUntil;

  DateTime? _manualCooldownUntil;

  int _roundsRun = 0;

  /// 下次轮询时刻（20261118-0110 G3）：null = 未启动 / 轮次在飞 / 已停表。
  DateTime? _nextRoundAt;

  DateTime _now() => _nowFunc();

  Future<void> _delay(Duration d) => _delayFunc(d);

  /// 当前冷却截止（测试/诊断读数）。
  @visibleForTesting
  DateTime? get cooldownUntil => _cooldownUntil;

  @visibleForTesting
  DateTime? get manualCooldownUntil => _manualCooldownUntil;

  @visibleForTesting
  int get roundsRun => _roundsRun;

  @visibleForTesting
  bool get started => _started;

  /// 自动领取是否已启用（UI「立即执行」入口的可用判据）。
  bool get enabled => _config.enabled;

  /// 当前是否有轮次在飞。
  bool get roundInFlight => _roundInFlight;

  /// UI 展示用状态快照（冷却截止/在飞/启用态/下次轮询，20261116-2341 D1③
  /// + 20261118-0110 G3）。
  ClaimSchedulerSnapshot snapshot() => ClaimSchedulerSnapshot(
    enabled: _config.enabled,
    roundInFlight: _roundInFlight,
    running: _started,
    cooldownUntil: _cooldownUntil,
    manualCooldownUntil: _manualCooldownUntil,
    nextRoundAt: _started ? _nextRoundAt : null,
    intervalMinutes: _config.intervalMinutes,
  );

  /// 立即执行一轮（UI「立即执行一轮」入口，20261116-2341 D1②）：
  /// 清除失败冷却并越过首轮延迟，立即跑一轮。
  ///
  /// 门控保留：未启用 / 设备非 live / 手动操作进行中 /
  /// 已有轮次在飞时不触发（返回 false）。与在飞自动循环互斥由
  /// [_roundInFlight] 保证；循环若在门控等待中，其醒来后照常检查门
  /// （冷却已被清，直接跑轮）。
  Future<bool> runNow() async {
    if (!_config.enabled) return false;
    if (!_live) return false;
    if (_manualActive) return false;
    if (_roundInFlight) return false;
    _cooldownUntil = null;
    await _runRound(_generation);
    return true;
  }

  void start() {
    if (_started) return;
    if (!_config.enabled) return; // 开关默认关：未启用不启动（零调用）。
    _started = true;
    final gen = ++_generation;
    unawaited(_runLoop(gen));
  }

  void stop() {
    _started = false;
    _nextRoundAt = null;
    _generation++; // 在飞循环/轮次在下一个检查点退出。
  }

  /// 配置更新：开 → 启动（首轮 2min 重计）；关 → 停表。
  void updateConfig(ClaimAutoConfig config) {
    _config = config;
    if (config.enabled) {
      start(); // 已在跑为 no-op；停表后重开则重启循环。
    } else {
      stop();
    }
  }

  /// 仅设备 live 时运行轮次（装配层接 sessionStatusProvider）。
  void setLive(bool live) => _live = live;

  /// 手动刷新/领取请求让位：在飞轮次在 ≤90s 内退出（步骤间检查 abort，
  /// 单步最迟 claimWait 45s + 配置/验证 ≤20s，预算内退出）。
  void requestAbort() {
    if (_roundInFlight) _abortRequested = true;
  }

  /// 手动操作开始：阻止后续自动 tick + 请求在飞轮让位。
  void manualStarted() {
    _manualActive = true;
    requestAbort();
  }

  /// 手动操作结束：60s 冷却后自动轮恢复。
  void manualEnded() {
    _manualActive = false;
    _manualCooldownUntil = _now().add(ClaimSchedulerPolicy.manualCooldown);
  }

  Future<void> _runLoop(int gen) async {
    _nextRoundAt = _now().add(ClaimSchedulerPolicy.firstDelay);
    await _delay(ClaimSchedulerPolicy.firstDelay);
    while (_generation == gen) {
      final gate = _gateWait();
      if (gate != null) {
        _nextRoundAt = _now().add(gate);
        await _delay(gate);
        continue;
      }
      _nextRoundAt = null; // 轮次即将在飞。
      await _runRound(gen);
      if (_generation != gen) break;
      final interval = ClaimSchedulerPolicy.roundIntervalJittered(
        _random,
        baseMinutes: _config.intervalMinutes,
      );
      _nextRoundAt = _now().add(interval);
      await _delay(interval);
    }
  }

  /// 门控等待：null = 可跑轮次；否则等到该门最早可能打开的时刻。
  Duration? _gateWait() {
    final now = _now();
    if (!_live) return ClaimSchedulerPolicy.liveRecheck;
    if (_manualActive) return ClaimSchedulerPolicy.manualRecheck;
    // runNow 触发的轮次在飞 → 循环让位复查（防双轮并发，20261116-2341 R3）。
    if (_roundInFlight) return ClaimSchedulerPolicy.manualRecheck;
    final manualCd = _manualCooldownUntil;
    if (manualCd != null && now.isBefore(manualCd)) {
      return manualCd.difference(now);
    }
    final cd = _cooldownUntil;
    if (cd != null && now.isBefore(cd)) {
      return cd.difference(now);
    }
    final silentWait = ClaimSchedulerPolicy.silentWait(
      now,
      silentStartMinutes: _config.silentStartMinutes,
      silentEndMinutes: _config.silentEndMinutes,
    );
    if (silentWait > Duration.zero) return silentWait;
    return null;
  }

  Future<void> _runRound(int gen) async {
    _roundsRun++;
    _roundInFlight = true;
    try {
      // F2（20261118-0030）：每轮 preview 前先激活（服务端"看到活跃"才出
      // 可领套餐）。钩子异常静默吞掉，不影响轮次。
      try {
        await beforePreview?.call();
      } catch (e) {
        debugPrint('[claim-auto] $deviceId activation skipped: $e');
      }
      var claimed = 0;
      while (_generation == gen &&
          !_abortRequested &&
          claimed < ClaimSchedulerPolicy.perRoundCap) {
        final List<ClaimPreview> previews;
        try {
          previews = await _client.fetchPreviews();
        } on ClaimPreviewMissingData {
          // 账号未配置套餐：业务态，干净收轮（不冷却）+ 阻断记录。
          onEvent?.call(
            const ClaimAutoBlocked(
              reason: ClaimBlockedReason.accountNotConfigured,
            ),
          );
          return;
        } catch (e) {
          _cooldownUntil = _now().add(
            ClaimSchedulerPolicy.genericFailureCooldown,
          );
          debugPrint('[claim-auto] $deviceId preview error: $e');
          // F3（20261118-0030）：宿主后台释放通道（L39 宿主侧限制）单独归类，
          // 供落史降频与恢复指引；其他异常仍按 previewError。
          final detail = e.toString();
          final reason = detail.contains('ChannelClient is disposed')
              ? ClaimBlockedReason.hostBackgroundUnavailable
              : ClaimBlockedReason.previewError;
          onEvent?.call(
            ClaimAutoBlocked(reason: reason, detail: detail),
          );
          return;
        }
        if (previews.isEmpty) {
          // 无券可领，干净收轮（不冷却）+ 阻断记录（D1：不再静默）。
          onEvent?.call(
            const ClaimAutoBlocked(reason: ClaimBlockedReason.noPlans),
          );
          return;
        }
        final plan = previews.first;

        final CaptchaConfig cfg;
        try {
          cfg = await _client.fetchCaptchaConfig();
        } catch (e) {
          _cooldownUntil = _now().add(
            ClaimSchedulerPolicy.genericFailureCooldown,
          );
          debugPrint('[claim-auto] $deviceId captchaConfig error: $e');
          onEvent?.call(
            ClaimAutoBlocked(
              reason: ClaimBlockedReason.captchaConfigError,
              detail: e.toString(),
            ),
          );
          return;
        }
        if (!cfg.enabled || cfg.sceneId.isEmpty) {
          // 活动暂不可领（验证码通道未开）→ 按普通失败冷却 + 阻断记录。
          _cooldownUntil = _now().add(
            ClaimSchedulerPolicy.genericFailureCooldown,
          );
          onEvent?.call(
            const ClaimAutoBlocked(reason: ClaimBlockedReason.activityClosed),
          );
          return;
        }

        final param = await _client.verifyCaptcha(cfg);
        if (param == null || param.isEmpty) {
          // 无感失败 → 需人工：1h 冷却 + 通知（不自动弹人工框——后台不可交互）。
          _cooldownUntil = _now().add(ClaimSchedulerPolicy.captchaCooldown);
          onEvent?.call(ClaimAutoCaptchaNeeded(plan: plan));
          return;
        }

        final ClaimOutcome outcome;
        try {
          outcome = await _client.claim(
            planId: plan.planId,
            captchaVerifyParam: param,
            captchaRegion: cfg.region.isEmpty ? null : cfg.region,
          );
        } catch (e) {
          _cooldownUntil = _now().add(
            ClaimSchedulerPolicy.genericFailureCooldown,
          );
          debugPrint('[claim-auto] $deviceId claim error: $e');
          onEvent?.call(
            ClaimAutoFailed(plan: plan, error: e.toString()),
          );
          return;
        }
        if (outcome.success) {
          claimed++;
          onEvent?.call(ClaimAutoSucceeded(plan: plan, outcome: outcome));
          continue; // 成功后重新 preview 继续。
        }
        final decision = ClaimCooldownDecision.of(
          code: outcome.code,
          failureEndsAt: outcome.failureEndsAt,
          now: _now(),
        );
        if (decision.cooldown > Duration.zero) {
          _cooldownUntil = _now().add(decision.cooldown);
        } else {
          _cooldownUntil = null;
        }
        onEvent?.call(
          ClaimAutoFailed(
            plan: plan,
            outcome: outcome,
            captchaNeeded: decision.captchaNeeded,
          ),
        );
        return; // 冷却生效，收轮。
      }
    } finally {
      _roundInFlight = false;
      _abortRequested = false;
    }
  }
}
