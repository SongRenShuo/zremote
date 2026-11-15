import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/claim.dart';
import 'package:zremote/services/claim_scheduler.dart';
import 'package:zremote/services/rpc_bridge.dart';

import 'scripted_bridge.dart';

/// 可注入假时钟。
class _FakeClock {
  _FakeClock(this._now);

  DateTime _now;

  DateTime now() => _now;
}

/// 可注入假延迟：advance 按截止时间顺序完成等待者。
class _FakeDelay {
  _FakeDelay(this._clock);

  final _FakeClock _clock;

  final List<({Completer<void> completer, DateTime deadline, int seq})>
  _waiters = [];

  int _seq = 0;

  Future<void> call(Duration d) {
    final completer = Completer<void>();
    _waiters.add((
      completer: completer,
      deadline: _clock.now().add(d),
      seq: _seq++,
    ));
    return completer.future;
  }
}

class _FakeClaimClient implements ClaimRpcClient {
  List<ClaimPreview> previews = [];
  Object? previewError;
  CaptchaConfig config = const CaptchaConfig(
    enabled: true,
    region: 'cn',
    prefix: 'p',
    sceneId: 's',
  );
  String? verifyParam = 'vp';
  ClaimOutcome? nextOutcome;
  Object? claimError;
  Completer<void>? holdClaim;

  int previewCalls = 0;
  int configCalls = 0;
  int verifyCalls = 0;
  int claimCalls = 0;
  final List<String> claimedPlanIds = [];
  final List<String> claimVerifyParams = [];

  @override
  Future<List<ClaimPreview>> fetchPreviews() async {
    previewCalls++;
    if (previewError != null) throw previewError!;
    return previews;
  }

  @override
  Future<CaptchaConfig> fetchCaptchaConfig() async {
    configCalls++;
    return config;
  }

  @override
  Future<String?> verifyCaptcha(CaptchaConfig config) async {
    verifyCalls++;
    return verifyParam;
  }

  @override
  Future<ClaimOutcome> claim({
    required String planId,
    required String captchaVerifyParam,
    String? captchaRegion,
  }) async {
    claimCalls++;
    claimedPlanIds.add(planId);
    claimVerifyParams.add(captchaVerifyParam);
    final hold = holdClaim;
    if (hold != null) await hold.future;
    if (claimError != null) throw claimError!;
    final outcome = nextOutcome;
    if (outcome != null) return outcome;
    return const ClaimOutcome(success: true);
  }
}

class _Harness {
  _Harness(DateTime startAt) : clock = _FakeClock(startAt);

  final _FakeClock clock;

  late final _FakeDelay delay = _FakeDelay(clock);

  final client = _FakeClaimClient();

  final events = <ClaimSchedulerEvent>[];

  late ClaimSchedulerAgent agent;

  ClaimPreview plan([String id = 'plan-a']) => ClaimPreview(
    planId: id,
    name: '周末体验包',
    entitlements: const [
      ClaimEntitlement(
        showName: 'GLM-4.6',
        units: 300000000,
        unitType: 'token',
        meter: 'model_usage',
      ),
    ],
  );

  ClaimSchedulerAgent makeAgent({
    ClaimAutoConfig config = const ClaimAutoConfig(enabled: true),
  }) {
    agent = ClaimSchedulerAgent(
      deviceId: 'd1',
      client: client,
      config: config,
      now: clock.now,
      delay: delay.call,
      random: math.Random(42),
      onEvent: events.add,
    );
    return agent;
  }

  /// 推进假时钟并按截止顺序完成到点等待者。
  Future<void> advance(Duration d) async {
    clock._now = clock.now().add(d);
    while (true) {
      final now = clock.now();
      final ready =
          delay._waiters.where((w) => !w.deadline.isAfter(now)).toList()
            ..sort((a, b) => a.seq.compareTo(b.seq));
      if (ready.isEmpty) break;
      for (final w in ready) {
        delay._waiters.remove(w);
        w.completer.complete();
      }
      await pumpEventQueue();
    }
  }
}

void main() {
  group('纯策略函数', () {
    test('轮间隔 jitter 恒在 [8min, 12min]', () {
      final random = math.Random(7);
      for (var i = 0; i < 500; i++) {
        final d = ClaimSchedulerPolicy.roundIntervalJittered(random);
        expect(
          d.inMilliseconds,
          allOf(
            greaterThanOrEqualTo(const Duration(minutes: 8).inMilliseconds),
            lessThanOrEqualTo(const Duration(minutes: 12).inMilliseconds),
          ),
        );
      }
    });

    test('附录 C 常量锁', () {
      expect(ClaimSchedulerPolicy.roundInterval, const Duration(minutes: 10));
      expect(ClaimSchedulerPolicy.firstDelay, const Duration(minutes: 2));
      expect(ClaimSchedulerPolicy.claimWait, const Duration(seconds: 45));
      expect(ClaimSchedulerPolicy.perRoundCap, 5);
      expect(ClaimSchedulerPolicy.autoAbortWait, const Duration(seconds: 90));
      expect(ClaimSchedulerPolicy.manualCooldown, const Duration(seconds: 60));
      expect(ClaimSchedulerPolicy.defaultSilentStart, 23 * 60);
      expect(ClaimSchedulerPolicy.defaultSilentEnd, 8 * 60);
    });

    test('静默跨天窗口 23:00–08:00 边界', () {
      bool at(int h, int m) => ClaimSchedulerPolicy.isSilentAt(
        DateTime(2026, 11, 15, h, m),
        silentStartMinutes: 23 * 60,
        silentEndMinutes: 8 * 60,
      );

      expect(at(22, 59), isFalse);
      expect(at(23, 0), isTrue);
      expect(at(23, 59), isTrue);
      expect(at(0, 0), isTrue);
      expect(at(7, 59), isTrue);
      expect(at(8, 0), isFalse);
      expect(at(12, 0), isFalse);
    });

    test('静默不跨天窗口 00:00–06:00 边界', () {
      bool at(int h, int m) => ClaimSchedulerPolicy.isSilentAt(
        DateTime(2026, 11, 15, h, m),
        silentStartMinutes: 0,
        silentEndMinutes: 6 * 60,
      );

      expect(at(0, 0), isTrue);
      expect(at(3, 0), isTrue);
      expect(at(5, 59), isTrue);
      expect(at(6, 0), isFalse);
      expect(at(23, 0), isFalse);
    });

    test('start == end 视为关闭静默；跨天 silentWait 到次日窗口尾', () {
      expect(
        ClaimSchedulerPolicy.isSilentAt(
          DateTime(2026, 11, 15, 23, 30),
          silentStartMinutes: 480,
          silentEndMinutes: 480,
        ),
        isFalse,
      );
      expect(
        ClaimSchedulerPolicy.silentWait(
          DateTime(2026, 11, 15, 23, 30),
          silentStartMinutes: 23 * 60,
          silentEndMinutes: 8 * 60,
        ),
        const Duration(hours: 8, minutes: 30),
      );
      expect(
        ClaimSchedulerPolicy.silentWait(
          DateTime(2026, 11, 15, 3, 0),
          silentStartMinutes: 0,
          silentEndMinutes: 6 * 60,
        ),
        const Duration(hours: 3),
      );
    });

    test('冷却决策矩阵（附录 C）', () {
      final now = DateTime(2026, 11, 15, 12);

      // 1005 → 服务端 ends_at 精确冷却。
      final endsAt = now.add(const Duration(hours: 3));
      expect(
        ClaimCooldownDecision.of(code: 1005, failureEndsAt: endsAt, now: now)
            .cooldown,
        const Duration(hours: 3),
      );
      // 1005 缺 ends_at / ends_at 已过 → 回落 1h / 零冷却。
      expect(
        ClaimCooldownDecision.of(code: 1005, now: now).cooldown,
        const Duration(hours: 1),
      );
      expect(
        ClaimCooldownDecision.of(
          code: 1005,
          failureEndsAt: now.subtract(const Duration(minutes: 1)),
          now: now,
        ).cooldown,
        Duration.zero,
      );
      // 3007 → 1h + 需人工。
      final captcha = ClaimCooldownDecision.of(code: 3007, now: now);
      expect(captcha.cooldown, const Duration(hours: 1));
      expect(captcha.captchaNeeded, isTrue);
      // 其他业务码 ≥1000 → 1h。
      for (final code in [1001, 1002, 1003, 1004, 3001]) {
        expect(
          ClaimCooldownDecision.of(code: code, now: now).cooldown,
          const Duration(hours: 1),
          reason: 'code $code',
        );
      }
      // 其他失败（401/未知码）→ 10min。
      for (final code in [401, 500, null]) {
        expect(
          ClaimCooldownDecision.of(code: code, now: now).cooldown,
          const Duration(minutes: 10),
          reason: 'code $code',
        );
      }
    });
  });

  group('调度代理', () {
    test('开关默认关 → start 零调用（反向验证）', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.makeAgent(config: const ClaimAutoConfig(enabled: false));
      h.agent.start();
      await h.advance(const Duration(hours: 24));
      expect(h.client.previewCalls, 0);
      expect(h.client.claimCalls, 0);
    });

    test('updateConfig 开关往返：关 → 停表零调用；重开 → 首轮 2min', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [];
      final agent = h.makeAgent();
      agent.start();
      await h.advance(const Duration(minutes: 2));
      expect(h.client.previewCalls, 1);

      agent.updateConfig(const ClaimAutoConfig(enabled: false));
      await h.advance(const Duration(hours: 24));
      expect(h.client.previewCalls, 1, reason: '关闭后零调用');

      agent.updateConfig(const ClaimAutoConfig(enabled: true));
      await h.advance(const Duration(minutes: 2));
      expect(h.client.previewCalls, 2, reason: '重开后首轮 2min');
    });

    test('首轮 2min + 轮间隔 jitter ∈ [8,12]min（边界探测）', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [];
      h.makeAgent();
      h.agent.start();

      await h.advance(const Duration(minutes: 1, seconds: 59));
      expect(h.client.previewCalls, 0, reason: '首轮前不触发');
      await h.advance(const Duration(seconds: 1));
      expect(h.client.previewCalls, 1, reason: '首轮 2min');

      await h.advance(const Duration(minutes: 7, seconds: 59));
      expect(h.client.previewCalls, 1, reason: '间隔下界 8min 内不触发');
      await h.advance(const Duration(minutes: 4, seconds: 1));
      expect(h.client.previewCalls, 2, reason: '间隔上界 12min 内必触发');
    });

    test('连领上限 5：成功后重新 preview，第 5 次后收轮', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 5);
      expect(h.client.previewCalls, 5, reason: '每次成功后重新 preview');
      expect(h.events, hasLength(5));
      expect(h.events.every((e) => e is ClaimAutoSucceeded), isTrue);
      expect(h.agent.cooldownUntil, isNull, reason: '连领封顶不冷却');
    });

    test('1005 → 冷却读服务端 ends_at（精确到点恢复）', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.client.nextOutcome = ClaimOutcome(
        success: false,
        code: 1005,
        failureEndsAt: DateTime(2026, 11, 15, 15, 2),
      );
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 1);
      expect(h.agent.cooldownUntil, DateTime(2026, 11, 15, 15, 2));

      await h.advance(const Duration(hours: 2, minutes: 58));
      expect(h.client.claimCalls, 1, reason: '冷却未到不重试');
      await h.advance(const Duration(minutes: 2, seconds: 1));
      expect(h.client.claimCalls, 2, reason: '到点恢复');
    });

    test('其他业务码 1003 → 1h 冷却', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.client.nextOutcome = const ClaimOutcome(success: false, code: 1003);
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 1);
      expect(
        h.agent.cooldownUntil,
        DateTime(2026, 11, 15, 13, 2),
        reason: '1003 冷却 1h',
      );
      final fail = h.events.single;
      expect(fail, isA<ClaimAutoFailed>());
      expect((fail as ClaimAutoFailed).captchaNeeded, isFalse);

      await h.advance(const Duration(minutes: 59, seconds: 59));
      expect(h.client.claimCalls, 1);
      await h.advance(const Duration(seconds: 2));
      expect(h.client.claimCalls, 2);
    });

    test('3007 验证码校验失败 → 1h + captchaNeeded 事件', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.client.nextOutcome = const ClaimOutcome(success: false, code: 3007);
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 1);
      expect(
        h.agent.cooldownUntil,
        DateTime(2026, 11, 15, 13, 2),
        reason: '3007 冷却 1h',
      );
      final fail = h.events.single as ClaimAutoFailed;
      expect(fail.captchaNeeded, isTrue);
    });

    test('无感验证失败 → 不发 claim（红线）+ 1h 冷却 + 需人工事件', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.client.verifyParam = null;
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 0, reason: '无 captchaVerifyParam 不发 claim');
      expect(
        h.agent.cooldownUntil,
        DateTime(2026, 11, 15, 13, 2),
        reason: '需人工验证码冷却 1h',
      );
      expect(h.events.single, isA<ClaimAutoCaptchaNeeded>());
    });

    test('claim 抛错（网络/超时）→ 10min 冷却 + 失败事件', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.client.claimError = const RpcTimeoutException('claim');
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 1);
      expect(
        h.agent.cooldownUntil,
        DateTime(2026, 11, 15, 12, 12),
        reason: '普通失败冷却 10min',
      );
      final fail = h.events.single as ClaimAutoFailed;
      expect(fail.outcome, isNull);
      await h.advance(const Duration(minutes: 10, seconds: 1));
      expect(h.client.claimCalls, 2, reason: '10min 后恢复');
    });

    test('preview 抛错 → 10min 冷却且零 claim', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previewError = const RpcRemoteException('x', 'boom');
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.previewCalls, 1);
      expect(h.client.claimCalls, 0);
      expect(h.agent.cooldownUntil, DateTime(2026, 11, 15, 12, 12));
      expect(h.events, isEmpty);
    });

    test('preview 业务空（manual_claim_preview_missing_data 由客户端归一）',
        () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [];
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.previewCalls, 1);
      expect(h.agent.cooldownUntil, isNull, reason: '无券可领不冷却');
    });

    test('静默跨天 23:00–08:00：23:30 启动 → 次日 08:00 才跑', () async {
      final h = _Harness(DateTime(2026, 11, 15, 23, 30));
      h.client.previews = [];
      h.makeAgent();
      h.agent.start();

      await h.advance(const Duration(minutes: 2));
      expect(h.client.previewCalls, 0, reason: '23:32 静默中');
      await h.advance(const Duration(hours: 8, minutes: 27));
      expect(
        h.client.previewCalls,
        0,
        reason: '次日 07:59 仍静默（end 不含）',
      );
      await h.advance(const Duration(minutes: 1));
      expect(h.client.previewCalls, 1, reason: '08:00 恢复');
    });

    test('静默不跨天 00:00–06:00：06:00 恢复', () async {
      final h = _Harness(DateTime(2026, 11, 16, 3));
      h.client.previews = [];
      h.makeAgent(
        config: const ClaimAutoConfig(
          enabled: true,
          silentStartMinutes: 0,
          silentEndMinutes: 6 * 60,
        ),
      );
      h.agent.start();

      await h.advance(const Duration(minutes: 2));
      await h.advance(const Duration(hours: 2, minutes: 57));
      expect(h.client.previewCalls, 0, reason: '05:59 静默');
      await h.advance(const Duration(minutes: 1));
      expect(h.client.previewCalls, 1, reason: '06:00 恢复');
    });

    test('静默关闭（start==end）→ 深夜照跑', () async {
      final h = _Harness(DateTime(2026, 11, 15, 23, 30));
      h.client.previews = [];
      h.makeAgent(
        config: const ClaimAutoConfig(
          enabled: true,
          silentStartMinutes: 0,
          silentEndMinutes: 0,
        ),
      );
      h.agent.start();
      await h.advance(const Duration(minutes: 2));
      expect(h.client.previewCalls, 1);
    });

    test('手动让位：在飞 claim 完成后退出，不追加 preview/claim', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [h.plan()];
      h.client.holdClaim = Completer<void>();
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));

      expect(h.client.claimCalls, 1, reason: '首轮 claim 在飞');
      h.agent.manualStarted(); // 手动操作开始 → 请求让位 + 阻止 tick。
      h.client.holdClaim!.complete();
      await pumpEventQueue();

      expect(h.client.previewCalls, 1, reason: '让位后不重新 preview');
      expect(h.client.claimCalls, 1);
      expect(h.events.single, isA<ClaimAutoSucceeded>());

      await h.advance(const Duration(hours: 1));
      expect(h.client.claimCalls, 1, reason: '手动运行中自动 tick 被阻止');
    });

    test('手动运行中阻止 tick；手动结束 60s 冷却后恢复', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [];
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));
      expect(h.client.previewCalls, 1);

      h.agent.manualStarted();
      await h.advance(const Duration(minutes: 30));
      expect(h.client.previewCalls, 1, reason: '手动运行中不跑轮');

      h.agent.manualEnded();
      await h.advance(const Duration(seconds: 30));
      expect(h.client.previewCalls, 1, reason: '手动结束 60s 冷却内');
      await h.advance(const Duration(minutes: 1));
      expect(h.client.previewCalls, 2, reason: '冷却后恢复');
    });

    test('非 live 阻止轮次；恢复 live 后 30s 内续跑', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [];
      h.makeAgent();
      h.agent.setLive(false);
      h.agent.start();
      await h.advance(const Duration(hours: 1));
      expect(h.client.previewCalls, 0);

      h.agent.setLive(true);
      await h.advance(const Duration(seconds: 31));
      expect(h.client.previewCalls, 1);
    });

    test('stop() 后零调用', () async {
      final h = _Harness(DateTime(2026, 11, 15, 12));
      h.client.previews = [];
      h.makeAgent();
      h.agent.start();
      await h.advance(const Duration(minutes: 2));
      expect(h.client.previewCalls, 1);

      h.agent.stop();
      await h.advance(const Duration(hours: 24));
      expect(h.client.previewCalls, 1);
    });
  });

  group('HostClaimRpcClient（通路 A）', () {
    test('红线：无 captchaVerifyParam 本地拒绝，零派发', () async {
      final bridge = ScriptedBridge(script: const []);
      final client = HostClaimRpcClient(bridge.bridge);
      await expectLater(
        client.claim(planId: 'p', captchaVerifyParam: ''),
        throwsArgumentError,
      );
      expect(bridge.commands, isEmpty);
    });

    test('preview 业务错 manual_claim_preview_missing_data → 空列表', () async {
      final bridge = ScriptedBridge(
        script: const [[]],
        errors: {0: 'manual_claim_preview_missing_data'},
      );
      final client = HostClaimRpcClient(bridge.bridge);
      expect(await client.fetchPreviews(), isEmpty);
    });

    test('preview 解析 + priority 降序排序', () async {
      final bridge = ScriptedBridge(script: [
        [
          {
            'plans': [
              {
                'planId': 'low',
                'name': 'L',
                'priority': 1,
              },
              {
                'planId': 'high',
                'name': 'H',
                'priority': 9,
              },
            ],
          },
        ],
      ]);
      final client = HostClaimRpcClient(bridge.bridge);
      final previews = await client.fetchPreviews();
      expect(previews.map((p) => p.planId), ['high', 'low']);
    });

    test('claim 参数形状对齐手动链路（planId/verifyParam/region）', () async {
      final bridge = ScriptedBridge(script: [
        [
          {'success': true},
        ],
      ]);
      final client = HostClaimRpcClient(bridge.bridge);
      final outcome = await client.claim(
        planId: 'plan-a',
        captchaVerifyParam: 'vp',
        captchaRegion: 'cn',
      );
      expect(outcome.success, isTrue);
      final r = requestOf(bridge.commands.single);
      expect(r.channel, 'coding-plan-subscription');
      expect(r.method, 'claimManualPlan');
      expect(r.params, {
        'planId': 'plan-a',
        'captchaVerifyParam': 'vp',
        'captchaRegion': 'cn',
      });
    });

    test('无感验证 ok=false → null（不发 claim）', () async {
      final bridge = ScriptedBridge(script: [
        const [
          {'ok': false, 'reason': 'timeout'},
        ],
      ]);
      final client = HostClaimRpcClient(bridge.bridge);
      expect(await client.verifyCaptcha(
        const CaptchaConfig(
          enabled: true,
          region: 'cn',
          prefix: 'p',
          sceneId: 's',
        ),
      ), isNull);
    });
  });

  group('P2-8 通路 B 实验位（默认关）', () {
    test('experimentalDefault 关闭 + 四方法均未实现（护栏）', () async {
      expect(DirectClaimRpcClient.experimentalDefault, isFalse);
      final client = DirectClaimRpcClient();
      await expectLater(
        client.fetchPreviews(),
        throwsUnsupportedError,
      );
      await expectLater(
        client.claim(planId: 'p', captchaVerifyParam: 'vp'),
        throwsUnsupportedError,
      );
    });
  });
}
