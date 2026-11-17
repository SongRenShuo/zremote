import 'package:flutter/foundation.dart';

import '../models/claim.dart';
import 'claim_scheduler.dart';

/// 全局一键手动领取的单台执行结果（context-free，供 UI 汇总展示）。
class ManualClaimDeviceResult {
  const ManualClaimDeviceResult({
    required this.deviceId,
    this.claimed = 0,
    this.failed = 0,
    this.reason = '',
  });

  final String deviceId;

  /// 该设备成功领取的套餐数。
  final int claimed;

  /// 该设备失败/需人工的套餐数。
  final int failed;

  /// 未就绪原因（非 live / 未装配 / 无券 / 异常）；空串表示该设备已执行。
  final String reason;

  bool get executed => reason.isEmpty;
}

/// 全局一键手动领取的结果汇总。
class ManualClaimBatchResult {
  const ManualClaimBatchResult({
    this.results = const [],
    this.skipped = 0,
  });

  final List<ManualClaimDeviceResult> results;

  /// 因非 live / 未装配被跳过的设备数。
  final int skipped;

  int get totalClaimed =>
      results.fold(0, (sum, r) => sum + r.claimed);

  int get totalFailed =>
      results.fold(0, (sum, r) => sum + r.failed);

  /// 无券/未绑套餐的设备数（业务态，非失败——20261118-0030 F1 分档呈现）。
  int get totalNoPlans =>
      results.where((r) => r.reason == 'noPlans').length;
}

/// 单台设备的手动领取执行器（20261117-1230 全局一键领取）。
///
/// 与 claim_page._claimAll 同语义（逐套餐全量领、验证码无感失败静默记失败
/// 继续、单失败不中断），但**不依赖 BuildContext**——用注入的 [ClaimRpcClient]
/// 走三段 RPC（getCaptchaConfig → verify → claimManualPlan），结果由回调落账，
/// 便于跨设备批量与单测。
class ManualClaimRunner {
  ManualClaimRunner({
    required this.deviceId,
    required ClaimRpcClient client,
    this.onClaimed,
    this.onFailed,
  }) : _client = client;

  final String deviceId;
  final ClaimRpcClient _client;

  /// 领取成功回调（落历史 manual / 发通知，由装配层提供）。
  final void Function(ClaimPreview plan, ClaimOutcome outcome)? onClaimed;

  /// 领取失败回调（含验证码需人工；由装配层落历史）。
  final void Function(ClaimPreview plan, String message, int? code)? onFailed;

  /// 对给定 previews 串行领取全部套餐，返回 (成功数, 失败数)。
  Future<(int, int)> runAll(List<ClaimPreview> previews) async {
    var ok = 0;
    var fail = 0;
    for (final plan in previews) {
      try {
        final cfg = await _client.fetchCaptchaConfig();
        if (!cfg.enabled || cfg.sceneId.isEmpty) {
          fail++;
          onFailed?.call(plan, 'activityUnavailable', null);
          continue;
        }
        final param = await _client.verifyCaptcha(cfg);
        if (param == null || param.isEmpty) {
          // 无感失败 → 静默记失败继续（对齐 batch 语义，不弹人工框）。
          fail++;
          onFailed?.call(plan, 'captchaInteractiveRequired', null);
          continue;
        }
        final outcome = await _client.claim(
          planId: plan.planId,
          captchaVerifyParam: param,
          captchaRegion: cfg.region.isEmpty ? null : cfg.region,
        );
        if (outcome.success) {
          ok++;
          onClaimed?.call(plan, outcome);
        } else {
          fail++;
          onFailed?.call(plan, outcome.message, outcome.code);
        }
      } catch (e) {
        fail++;
        debugPrint('[claim-batch] $deviceId ${plan.planId} failed: $e');
        onFailed?.call(plan, e.toString(), null);
      }
    }
    return (ok, fail);
  }

  /// 先拉预览再领取全部。
  /// 返回 (成功数, 失败数, 备注)：备注空串 = 正常执行；
  /// `noPlans` = 账号无券/未绑套餐（业务态，非失败——对齐自动轮"干净收轮"）；
  /// `error:<detail>` = preview 拉取异常（20261118-0030 F1：此前被 catch 吞成
  /// 0/0 导致汇总误导性全零）。
  Future<(int, int, String)> fetchAndRunAll() async {
    final List<ClaimPreview> previews;
    try {
      previews = await _client.fetchPreviews();
    } on ClaimPreviewMissingData {
      return (0, 0, 'noPlans');
    } catch (e) {
      debugPrint('[claim-batch] $deviceId fetchPreviews failed: $e');
      return (0, 0, 'error:$e');
    }
    final (ok, fail) = await runAll(previews);
    return (ok, fail, '');
  }
}
