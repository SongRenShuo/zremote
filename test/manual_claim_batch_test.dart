import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/claim.dart';
import 'package:zremote/services/claim_scheduler.dart';
import 'package:zremote/services/manual_claim_batch.dart';

class _FakeClient implements ClaimRpcClient {
  _FakeClient({
    this.previews = const [],
    this.config = const CaptchaConfig(
      enabled: true,
      region: 'cn',
      prefix: 'p',
      sceneId: 's',
    ),
    this.verifyParam = 'vp',
    this.failPlanIds = const {},
    this.throwPlanIds = const {},
  });

  final List<ClaimPreview> previews;
  final CaptchaConfig config;
  final String? verifyParam;
  final Set<String> failPlanIds;
  final Set<String> throwPlanIds;

  final claimed = <String>[];
  final failed = <String>[];

  @override
  Future<List<ClaimPreview>> fetchPreviews() async => previews;

  @override
  Future<CaptchaConfig> fetchCaptchaConfig() async => config;

  @override
  Future<String?> verifyCaptcha(CaptchaConfig config) async => verifyParam;

  @override
  Future<ClaimOutcome> claim({
    required String planId,
    required String captchaVerifyParam,
    String? captchaRegion,
  }) async {
    if (throwPlanIds.contains(planId)) {
      throw StateError('rpc boom');
    }
    if (failPlanIds.contains(planId)) {
      return ClaimOutcome(success: false, code: 1003, message: 'claimed');
    }
    claimed.add(planId);
    return const ClaimOutcome(success: true);
  }
}

ClaimPreview _plan(String id) => ClaimPreview(planId: id, name: id);

void main() {
  test('runAll：全部成功 → (N,0) + onClaimed 逐条回调', () async {
    final client = _FakeClient(previews: [_plan('a'), _plan('b')]);
    final claimedEvents = <String>[];
    final runner = ManualClaimRunner(
      deviceId: 'd1',
      client: client,
      onClaimed: (plan, outcome) => claimedEvents.add(plan.planId),
    );
    final (ok, fail) = await runner.runAll(client.previews);
    expect(ok, 2);
    expect(fail, 0);
    expect(claimedEvents, ['a', 'b']);
  });

  test('runAll：部分业务失败不中断 → 继续领下一个', () async {
    final client = _FakeClient(
      previews: [_plan('a'), _plan('b'), _plan('c')],
      failPlanIds: {'b'},
    );
    final failedEvents = <String>[];
    final runner = ManualClaimRunner(
      deviceId: 'd1',
      client: client,
      onFailed: (plan, message, code) => failedEvents.add(plan.planId),
    );
    final (ok, fail) = await runner.runAll(client.previews);
    expect(ok, 2, reason: 'a/c 成功');
    expect(fail, 1);
    expect(failedEvents, ['b']);
    expect(client.claimed, ['a', 'c']);
  });

  test('runAll：RPC 抛错单条吞掉不中断整批', () async {
    final client = _FakeClient(
      previews: [_plan('a'), _plan('b')],
      throwPlanIds: {'a'},
    );
    final runner = ManualClaimRunner(deviceId: 'd1', client: client);
    final (ok, fail) = await runner.runAll(client.previews);
    expect(ok, 1, reason: 'b 仍被领取');
    expect(fail, 1);
  });

  test('runAll：验证码需人工（verifyParam=null）→ 静默记失败继续，不发 claim',
      () async {
    final client = _FakeClient(
      previews: [_plan('a'), _plan('b')],
      verifyParam: null,
    );
    final runner = ManualClaimRunner(deviceId: 'd1', client: client);
    final (ok, fail) = await runner.runAll(client.previews);
    expect(ok, 0);
    expect(fail, 2);
    expect(client.claimed, isEmpty, reason: '无 verifyParam 不发 claim（红线）');
  });

  test('runAll：活动未开（cfg.enabled=false）→ 记失败继续', () async {
    final client = _FakeClient(
      previews: [_plan('a')],
      config: const CaptchaConfig(enabled: false),
    );
    final runner = ManualClaimRunner(deviceId: 'd1', client: client);
    final (ok, fail) = await runner.runAll(client.previews);
    expect(ok, 0);
    expect(fail, 1);
  });

  test('fetchAndRunAll：无券 → (0,0)（无失败）', () async {
    final client = _FakeClient(previews: const []);
    final runner = ManualClaimRunner(deviceId: 'd1', client: client);
    final (ok, fail) = await runner.fetchAndRunAll();
    expect(ok, 0);
    expect(fail, 0);
  });

  test('汇总结果：totalClaimed / totalFailed 累加', () {
    final result = ManualClaimBatchResult(
      results: [
        const ManualClaimDeviceResult(deviceId: 'd1', claimed: 2, failed: 1),
        const ManualClaimDeviceResult(deviceId: 'd2', claimed: 1, failed: 0),
        const ManualClaimDeviceResult(deviceId: 'd3', reason: 'notLive'),
      ],
      skipped: 1,
    );
    expect(result.totalClaimed, 3);
    expect(result.totalFailed, 1);
    expect(result.skipped, 1);
  });
}
