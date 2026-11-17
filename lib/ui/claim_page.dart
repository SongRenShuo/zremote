import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/claim.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/claim_scheduler.dart';
import '../services/rpc_bridge.dart';
import '../services/service_probe.dart';
import '../state/claim_config.dart';
import '../state/claim_entry.dart';
import '../state/claim_history.dart';
import '../state/claim_scheduler_hub.dart';
import '../state/session_status.dart';
import '../theme.dart';
import 'bevel_card.dart';
import 'hw_chip.dart';
import 'claim_ticket_dialog.dart';
import 'showcase_bits.dart';
import 'status_led.dart';
import 'tactile_button.dart';

class ClaimPage extends ConsumerStatefulWidget {
  const ClaimPage({
    super.key,
    required this.device,
    required this.bridge,
    this.onDiagnosticsPressed,
  });

  final RemoteDevice device;
  final RpcBridge bridge;

  /// 服务不可用时的「连接诊断」出口（可诊断，不让用户灰着不知道为什么）。
  /// 缺省不显示该按钮，页面退化为纯文案指引。
  final VoidCallback? onDiagnosticsPressed;

  @override
  ConsumerState<ClaimPage> createState() => _ClaimPageState();
}

enum _ClaimPhase { loading, ready, error }

enum _ClaimErrorKind { notReady, remote, service }

class _ClaimPageState extends ConsumerState<ClaimPage> {
  _ClaimPhase _phase = _ClaimPhase.loading;
  _ClaimErrorKind _errorKind = _ClaimErrorKind.notReady;
  String _errorMessage = '';
  String? _serviceReason;
  bool _refreshing = false;
  List<ClaimPreview> _previews = const [];
  int _tabIndex = 0;

  /// 一键领取进行中（Z6 互斥：批量期间禁用其它领取入口）。
  bool _claimAllRunning = false;

  /// 立即执行一轮进行中（仅控制按钮 spinner，门控以 agent 为准）。
  bool _runNowActive = false;

  /// 自动轮冷却展示的定时刷新（快照非响应式，30s 兜底重读）。
  Timer? _snapshotTicker;

  /// 轮询倒计时的 1s tick（20261118-0110 G4）：仅自动领取开启时驱动刷新。
  Timer? _countdownTicker;

  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    // P2-5/P2-6：配置加载 + 历史快照恢复（离线可见最后快照）。
    unawaited(ref.read(claimConfigProvider.notifier).load(widget.device.id));
    unawaited(
      ref.read(claimHistoryProvider.notifier).restoreFromStore(
            widget.device.id,
          ),
    );
    _snapshotTicker = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (mounted) setState(() {});
      },
    );
    _countdownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final config =
          ref.read(claimConfigProvider)[widget.device.id] ??
          const ClaimAutoConfig();
      if (config.enabled) setState(() {});
    });
    _refresh();
  }

  @override
  void dispose() {
    _snapshotTicker?.cancel();
    _countdownTicker?.cancel();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted) setState(() {});
    // P2-4 手动优先：手动刷新触发 abortRequest，自动轮 ≤90s 让位；
    // 手动运行中阻止自动 tick。
    final hub = ref.read(claimSchedulerHubProvider.notifier);
    hub.manualStarted(widget.device.id);
    try {
      final r = await _callWithRetry(
        'getManualClaimPlanPreviews',
        tag: 'refresh',
      );
      final obj = r.firstObjectDeep;
      // plans 为主名，previews 为宿主升级后的可能别名。
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
      if (!mounted) return;
      setState(() {
        _previews = previews;
        _phase = _ClaimPhase.ready;
      });
      debugPrint('[claim] refresh ok plans=${previews.length}');
      // 能力与业务分离：接口通了即「服务可用」（无券也保持可用），
      // report 只影响「有可领」徽标 —— 绝不因空数组把服务置为不可用。
      ref.read(claimServiceProvider.notifier).mark(widget.device.id, true);
      ref
          .read(claimEntryProvider.notifier)
          .report(widget.device.id, previews.isNotEmpty);
    } on RpcRemoteException catch (e) {
      debugPrint('[claim] refresh remote error: ${e.message}');
      if (!mounted) return;
      // 宿主实测（2026-11-14）：账号未配置套餐时 getManualClaimPlanPreviews
      // 抛业务错 manual_claim_preview_missing_data —— 这是"无券可领"的真实
      // 业务态，展示空态而非错误页；服务本身可用。
      if (e.message.contains('manual_claim_preview_missing_data')) {
        setState(() => _phase = _ClaimPhase.ready);
        ref.read(claimServiceProvider.notifier).mark(widget.device.id, true);
        ref.read(claimEntryProvider.notifier).report(widget.device.id, false);
        return;
      }
      // 服务级错误（no-method / no-services）才写「服务不可用」；
      // 其它业务错只展示错误页，不污染能力态。
      final reason = _serviceReasonOf(e.message);
      if (reason != null) {
        _markServiceUnavailable(reason);
        return;
      }
      setState(() {
        _phase = _ClaimPhase.error;
        _errorKind = _ClaimErrorKind.remote;
        _errorMessage = e.message;
        _serviceReason = null;
      });
    } on RpcNotReadyException {
      debugPrint('[claim] refresh notReady after retries');
      _toNotReady();
    } on RpcTimeoutException {
      debugPrint('[claim] refresh timeout after retries');
      _toNotReady();
    } catch (e) {
      debugPrint('[claim] refresh unexpected error $e');
      _toNotReady();
    } finally {
      _refreshing = false;
      // P2-4：手动结束 60s 冷却后自动轮恢复。
      hub.manualEnded(widget.device.id);
      if (mounted) setState(() {});
    }
  }

  Future<RpcResponse> _callWithRetry(
    String method, {
    required String tag,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await widget.bridge.call(
          'coding-plan-subscription',
          method,
          timeout: const Duration(seconds: 10),
        );
      } on RpcRemoteException catch (e) {
        // no-method 是一次性结论（宿主有服务无此方法），不重试：
        // 别名服务大概率同样没有该方法，重试只是拖长失败路径。
        final transient = e.message.contains('no-services');
        if (!transient || attempt >= 3) rethrow;
      } on RpcNotReadyException {
        if (attempt >= 3) rethrow;
      } on RpcTimeoutException {
        if (attempt >= 3) rethrow;
      }
      debugPrint('[claim] $tag retry #$attempt in 2s');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _toNotReady() {
    if (!mounted) return;
    setState(() {
      _phase = _ClaimPhase.error;
      _errorKind = _ClaimErrorKind.notReady;
      _errorMessage = '';
      _serviceReason = null;
    });
  }

  /// 错误消息里的服务级原因码；其它错误返回 null（不能结论服务不可用）。
  static String? _serviceReasonOf(String message) {
    if (message.contains(ClaimServiceProbe.reasonNoMethod)) {
      return ClaimServiceProbe.reasonNoMethod;
    }
    if (message.contains(ClaimServiceProbe.reasonNoServices)) {
      return ClaimServiceProbe.reasonNoServices;
    }
    return null;
  }

  /// 服务不可用：写能力态（带原因）+ 页面错误态。
  /// 与「无券可领」彻底分离，绝不回写 claimEntryProvider。
  void _markServiceUnavailable(String reason) {
    debugPrint('[claim] service unavailable: $reason');
    ref
        .read(claimServiceProvider.notifier)
        .mark(widget.device.id, false, reason: reason);
    if (!mounted) return;
    setState(() {
      _phase = _ClaimPhase.error;
      _errorKind = _ClaimErrorKind.service;
      _serviceReason = reason;
      _errorMessage = '';
    });
  }

  /// 手动领取结果落历史（P2-6，来源 manual）。
  void _recordClaim({
    required ClaimPreview plan,
    required bool success,
    ClaimOutcome? outcome,
    String message = '',
  }) {
    ref
        .read(claimHistoryProvider.notifier)
        .record(
          widget.device.id,
          planId: plan.planId,
          planName: plan.name,
          success: success,
          code: outcome?.code,
          message: message.isNotEmpty ? message : outcome?.message ?? '',
          source: ClaimRecordSource.manual,
          benefitSummary: claimBenefitSummary(plan.entitlements),
        );
  }

  /// 手动领取单个套餐。
  /// [batch]（一键领取模式，20261116-2341 Z2）：无感验证失败/领取失败
  /// 不弹人工降级框与失败框，静默记失败继续下一个；成功不弹票据框。
  /// 返回该套餐是否领取成功。
  Future<bool> _claim(ClaimPreview plan, {bool batch = false}) async {
    final l10n = AppLocalizations.of(context)!;
    if (!batch && (_busy.isNotEmpty || _claimAllRunning)) return false;
    if (ref.read(sessionStatusProvider)[widget.device.id] !=
        SessionStatus.live) {
      // 非 live 不再静默 return：给出口提示（20261116-2341 §2#8）。
      if (!batch && mounted) _snack(l10n.claimDeviceNotReady);
      return false;
    }
    setState(() => _busy.add(plan.planId));
    // P2-4 手动优先：领取在途 → 自动轮让位 + 阻止 tick；结束 60s 冷却。
    final hub = ref.read(claimSchedulerHubProvider.notifier);
    hub.manualStarted(widget.device.id);
    try {
      final CaptchaConfig cfg;
      try {
        final r = await widget.bridge.call(
          'coding-plan-subscription',
          'getCaptchaConfig',
        );
        cfg = CaptchaConfig.fromJson(r.firstObject ?? const {});
      } catch (e) {
        debugPrint('[claim] captchaConfig error $e');
        if (!batch && mounted) {
          _snack('${l10n.claimFailedGeneric}${_msgOf(e)}');
        }
        return false;
      }
      if (!cfg.enabled || cfg.sceneId.isEmpty) {
        if (!batch && mounted) _snack(l10n.claimUnavailable);
        return false;
      }

      final String verifyParam;
      try {
        final r = await widget.bridge.call(
          'zr-captcha',
          'verify',
          params: {
            'sceneId': cfg.sceneId,
            'prefix': cfg.prefix,
            'region': cfg.region,
            'timeoutMs': 8000,
          },
          timeout: const Duration(seconds: 20),
        );
        final v = r.firstObject;
        final param = v?['param'];
        if (v == null || v['ok'] != true || param is! String || param.isEmpty) {
          if (batch) {
            // 批量模式静默降级（Z2）：记失败继续下一个，不弹人工框。
            _recordClaim(
              plan: plan,
              success: false,
              message: l10n.claimCaptchaFallbackTitle,
            );
            return false;
          }
          await _fallbackDialog();
          return false;
        }
        verifyParam = param;
      } catch (e) {
        debugPrint('[claim] captcha verify error $e');
        if (batch) {
          _recordClaim(
            plan: plan,
            success: false,
            message: l10n.claimCaptchaFallbackTitle,
          );
          return false;
        }
        await _fallbackDialog();
        return false;
      }

      final ClaimOutcome outcome;
      try {
        final r = await widget.bridge.call(
          'coding-plan-subscription',
          'claimManualPlan',
          params: {
            'planId': plan.planId,
            'captchaVerifyParam': verifyParam,
            if (cfg.region.isNotEmpty) 'captchaRegion': cfg.region,
          },
        );
        outcome = ClaimOutcome.fromJson(r.firstObject ?? const {});
      } catch (e) {
        debugPrint('[claim] claimManualPlan error $e');
        _recordClaim(plan: plan, success: false, message: e.toString());
        if (!batch && mounted) {
          _snack('${l10n.claimFailedGeneric}${_msgOf(e)}');
        }
        return false;
      }
      if (!mounted) return false;

      if (outcome.success) {
        debugPrint('[claim] claim ok plan=${plan.planId}');
        _recordClaim(plan: plan, success: true, outcome: outcome);
        if (!batch) {
          if (mounted) setState(() => _busy.clear());
          await showClaimTicketDialog(context, plan: plan, outcome: outcome);
          if (mounted) await _refresh();
        }
        return true;
      } else {
        debugPrint('[claim] claim fail code=${outcome.code}');
        _recordClaim(plan: plan, success: false, outcome: outcome);
        if (!batch) await _failureDialog(outcome);
        return false;
      }
    } finally {
      hub.manualEnded(widget.device.id);
      if (mounted) setState(() => _busy.remove(plan.planId));
    }
  }

  /// 一键领取（20261116-2341 D2，zcode-switch Z1 精华）：
  /// 串行逐套餐走既有领取链路；单个失败不中断整批；结束汇总 + 刷新。
  Future<void> _claimAll() async {
    if (_claimAllRunning || _busy.isNotEmpty || _refreshing) return;
    final plans = List<ClaimPreview>.of(_previews);
    if (plans.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    _claimAllRunning = true;
    if (mounted) setState(() {});
    final hub = ref.read(claimSchedulerHubProvider.notifier);
    hub.manualStarted(widget.device.id);
    var ok = 0;
    var fail = 0;
    try {
      for (final plan in plans) {
        if (!mounted) break;
        // 设备中途掉线即停（后续套餐统一按失败计不合适，直接中止整批）。
        if (ref.read(sessionStatusProvider)[widget.device.id] !=
            SessionStatus.live) {
          break;
        }
        if (await _claim(plan, batch: true)) {
          ok++;
        } else {
          fail++;
        }
      }
      if (mounted) {
        _snack(l10n.claimBatchSummary(ok, fail));
        if (ok > 0) await _refresh();
      }
    } finally {
      _claimAllRunning = false;
      hub.manualEnded(widget.device.id);
      if (mounted) setState(() {});
    }
  }

  /// 立即执行一轮自动领取（20261116-2341 D4）：清冷却越过首轮延迟。
  Future<void> _runAutoNow() async {
    if (_runNowActive) return;
    final l10n = AppLocalizations.of(context)!;
    _runNowActive = true;
    if (mounted) setState(() {});
    try {
      final hub = ref.read(claimSchedulerHubProvider.notifier);
      final triggered = await hub.runNow(widget.device.id);
      if (!triggered && mounted) _snack(l10n.claimRunNowRejected);
    } finally {
      _runNowActive = false;
      if (mounted) setState(() {});
    }
  }

  static String _msgOf(Object e) =>
      e is RpcRemoteException && e.message.isNotEmpty ? '（${e.message}）' : '';

  Future<void> _fallbackDialog() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.claimCaptchaFallbackTitle),
        content: Text(l10n.claimCaptchaFallbackBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.claimGotIt),
          ),
        ],
      ),
    );
  }

  Future<void> _failureDialog(ClaimOutcome outcome) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();
    final code = outcome.code;
    final mapped = code == null ? null : _codeMessage(l10n, code);
    final main = mapped ??
        (outcome.message.isNotEmpty
            ? outcome.message
            : l10n.claimFailedGeneric);

    String? retry;
    if (code == 1005) {
      final at = outcome.failureEndsAt;
      if (at != null) {
        final now = DateTime.now();
        final sameDay =
            at.year == now.year && at.month == now.month && at.day == now.day;
        retry = sameDay
            ? l10n.claimRetryAt(ClaimFormat.dateTime(at, locale))
            : l10n.claimRetryTomorrow;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.claimFailedTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(main),
            // Z5 结构化 detail：业务码已映射时附服务端原始 message，便于排查。
            if (mapped != null &&
                outcome.message.isNotEmpty &&
                outcome.message != mapped) ...[
              const SizedBox(height: 6),
              Text(
                outcome.message,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (retry != null) ...[
              const SizedBox(height: 8),
              Text(
                retry,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.claimGotIt),
          ),
        ],
      ),
    );
  }

  static String? _codeMessage(AppLocalizations l10n, int code) =>
      switch (code) {
        1001 => l10n.claimCode1001,
        1002 => l10n.claimCode1002,
        1003 => l10n.claimCode1003,
        1004 => l10n.claimCode1004,
        1005 => l10n.claimCode1005,
        3001 => l10n.claimCode3001,
        3007 => l10n.claimCode3007,
        401 => l10n.claimCode401,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status = ref.watch(sessionStatusProvider)[widget.device.id];
    final offline = status != SessionStatus.live;

    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusLed(status: status, size: 8, showGlow: true),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.device.displayName(l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('claim-all-btn'),
            icon: _claimAllRunning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.done_all_rounded),
            tooltip: l10n.claimBatchAction,
            onPressed:
                offline || _busy.isNotEmpty || _refreshing || _claimAllRunning
                ? null
                : _claimAll,
          ),
          if (_refreshing || _busy.isNotEmpty || _claimAllRunning)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.claimRefresh,
              onPressed: _refresh,
            ),
        ],
        bottom:
            offline
                ? PreferredSize(
                  preferredSize: const Size.fromHeight(36),
                  child: Container(
                    width: double.infinity,
                    color: context.zt.danger.withValues(alpha: 0.10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: context.zt.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.claimDeviceNotReady,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.zt.textLo,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                : null,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: ZrSegmented(
              segments: [
                ('plans', l10n.claimAutoTabLabel),
                ('hist', l10n.claimHistTabLabel),
              ],
              active: _tabIndex == 0 ? 'plans' : 'hist',
              onChanged: (value) => setState(
                () => _tabIndex = value == 'plans' ? 0 : 1,
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tabIndex,
              children: [_plansTab(l10n, status, offline), _historyTab(l10n)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _plansTab(
    AppLocalizations l10n,
    SessionStatus? status,
    bool offline,
  ) => Column(
    children: [
      _autoCard(l10n),
      Expanded(
        child: switch (_phase) {
          _ClaimPhase.loading => const Center(
            child: CircularProgressIndicator(),
          ),
          _ClaimPhase.error => _errorView(l10n, offline),
          _ClaimPhase.ready =>
            _previews.isEmpty
                ? _emptyView(l10n)
                : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _scopeRow(l10n, status),
                    for (final plan in _previews)
                      _planCard(l10n, plan, offline),
                  ],
                ),
        },
      ),
    ],
  );

  Widget _scopeRow(AppLocalizations l10n, SessionStatus? status) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ZrScopeDock(
        label: l10n.claimScopeLabel,
        name: widget.device.displayName(l10n),
        dotColor: status == SessionStatus.live
            ? context.zt.live
            : context.zt.danger,
      ),
    );
  }

  static String _hhmm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  /// P2-4/P2-5：顶部「自动领取」开关 + 静默时段设置入口。
  Widget _autoCard(AppLocalizations l10n) {
    final config =
        ref.watch(claimConfigProvider)[widget.device.id] ??
        const ClaimAutoConfig();
    final zt = context.zt;
    final subtitle = !config.enabled
        ? l10n.claimAutoHint
        : config.silentEnabled
        ? l10n.claimAutoSilentSummary(
            _hhmm(config.silentStartMinutes),
            _hhmm(config.silentEndMinutes),
          )
        : l10n.claimAutoSilentOff;
    return BevelCard(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: zt.accentSubtle,
                ),
                child: Icon(
                  Icons.auto_mode_rounded,
                  size: 17,
                  color: config.enabled ? zt.live : zt.textTertiary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.claimAutoTitle,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: zt.textLo),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const Key('claim-auto-switch'),
                value: config.enabled,
                onChanged: (value) => ref
                    .read(claimConfigProvider.notifier)
                    .setEnabled(widget.device.id, value),
              ),
            ],
          ),
          if (config.enabled) ...[
            InkWell(
              key: const Key('claim-auto-silent-entry'),
              borderRadius: BorderRadius.circular(8),
              onTap: _editSilentHours,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
                child: Row(
                  children: [
                    Icon(Icons.bedtime_outlined, size: 14, color: zt.textLo),
                    const SizedBox(width: 6),
                    Text(
                      l10n.claimAutoSilentEntry,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: zt.textLo,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      config.silentEnabled
                          ? '${_hhmm(config.silentStartMinutes)}–'
                                '${_hhmm(config.silentEndMinutes)}'
                          : l10n.claimAutoSilentOff,
                      style: zrMono(fontSize: 11, color: zt.textTertiary),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 16, color: zt.textLo),
                  ],
                ),
              ),
            ),
            _runNowRow(l10n),
            // 倒计时 + 进度条（20261118-0110 G4）：下次检查可见。
            _countdownRow(l10n),
          ],
          Text(
            l10n.claimAutoSessionHint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: zt.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 轮询倒计时行（20261118-0110 G4）：下次检查倒计时 + 进度条；
  /// 轮在飞 / 冷却 / 静默时分别显示对应状态（优先级：在飞 > 冷却 > 静默 > 倒计时）。
  Widget _countdownRow(AppLocalizations l10n) {
    final zt = context.zt;
    final snapshot = ref
        .read(claimSchedulerHubProvider.notifier)
        .snapshotOf(widget.device.id);
    if (snapshot == null) return const SizedBox.shrink();
    final now = DateTime.now();

    String? statusText;
    double? progress;
    if (snapshot.roundInFlight) {
      statusText = l10n.claimCheckingNow;
    } else {
      final cooldown = snapshot.cooldownUntil;
      if (cooldown != null && cooldown.isAfter(now)) {
        statusText = l10n.claimWaitingCooldown(_hhmmOfDay(cooldown));
      } else {
        final silentWait = ClaimSchedulerPolicy.silentWait(
          now,
          silentStartMinutes:
              ref.watch(claimConfigProvider)[widget.device.id]?.silentStartMinutes ??
              ClaimSchedulerPolicy.defaultSilentStart,
          silentEndMinutes:
              ref.watch(claimConfigProvider)[widget.device.id]?.silentEndMinutes ??
              ClaimSchedulerPolicy.defaultSilentEnd,
        );
        if (silentWait > Duration.zero) {
          statusText = l10n.claimWaitingSilent(
            _hhmmOfDay(now.add(silentWait)),
          );
        } else {
          final next = snapshot.nextRoundAt;
          if (next != null && next.isAfter(now)) {
            final remaining = next.difference(now);
            final total = Duration(
              minutes: snapshot.intervalMinutes,
            );
            final elapsed = total - remaining;
            progress = (elapsed.inMilliseconds / total.inMilliseconds)
                .clamp(0.0, 1.0);
            statusText = l10n.claimNextCheckIn(_mmss(remaining));
          }
        }
      }
    }
    if (statusText == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 14, color: zt.textLo),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: zrMono(fontSize: 11.5, color: zt.textLo),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (progress != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                key: const Key('claim-countdown-progress'),
                value: progress,
                minHeight: 3,
                backgroundColor: zt.hairline,
                valueColor: AlwaysStoppedAnimation(zt.accent),
              ),
            ),
        ],
      ),
    );
  }

  /// 剩余时长 mm:ss（超 1h 显示 h:mm:ss）。
  static String _mmss(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:$two($m):$two($s)' : '${two(m)}:$two($s)';
  }

  /// 「立即执行一轮」行（20261116-2341 D4）：清冷却立即跑一轮；
  /// 冷却中/在飞展示调度器快照读数（D1③）。
  Widget _runNowRow(AppLocalizations l10n) {
    final zt = context.zt;
    final snapshot = ref
        .read(claimSchedulerHubProvider.notifier)
        .snapshotOf(widget.device.id);
    final now = DateTime.now();
    final cooldown = snapshot?.cooldownUntil;
    final cooling =
        cooldown != null && cooldown.isAfter(now) && !(snapshot?.roundInFlight ?? false);
    final running = snapshot?.roundInFlight ?? false;
    final statusText = running
        ? l10n.claimAutoRoundRunning
        : cooling
        ? l10n.claimAutoCooldown(_hhmmOfDay(cooldown))
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 10, 6),
      child: Row(
        children: [
          TactileButton(
            key: const Key('claim-run-now-btn'),
            height: 32,
            icon: _runNowActive || running
                ? SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: zt.accent,
                    ),
                  )
                : Icon(Icons.play_arrow_rounded, size: 16, color: zt.accent),
            label: l10n.claimRunNowAction,
            onPressed: _runNowActive || running ? null : _runAutoNow,
          ),
          if (statusText != null) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: zrMono(fontSize: 11, color: zt.textLo),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 冷却截止时刻的 HH:mm（当天内）或 MM-DD HH:mm（跨天）。
  static String _hhmmOfDay(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? '${two(at.hour)}:${two(at.minute)}'
        : '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }

  /// 静默时段设置底部弹层（开始/结束时间选择 + 关闭/恢复默认）。
  Future<void> _editSilentHours() async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
        builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          // 弹层非 build 上下文，用 read + setSheetState 驱动刷新。
          final config =
              ref.read(claimConfigProvider)[widget.device.id] ??
              const ClaimAutoConfig();
          final zt = sheetContext.zt;
          Future<void> pick(bool isStart) async {
            final initial = isStart
                ? config.silentStartMinutes
                : config.silentEndMinutes;
            final picked = await showTimePicker(
              context: sheetContext,
              initialTime: TimeOfDay(
                hour: initial ~/ 60,
                minute: initial % 60,
              ),
            );
            if (picked == null) return;
            final minutes = picked.hour * 60 + picked.minute;
            await ref
                .read(claimConfigProvider.notifier)
                .setSilent(
                  widget.device.id,
                  isStart ? minutes : config.silentStartMinutes,
                  isStart ? config.silentEndMinutes : minutes,
                );
            setSheetState(() {});
          }

          Widget timeRow(String label, int minutes, bool isStart) => InkWell(
            key: Key(isStart ? 'claim-auto-silent-start' : 'claim-auto-silent-end'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => pick(isStart),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: zt.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: zt.hairline),
              ),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: zt.textHi,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _hhmm(minutes),
                    style: zrMono(fontSize: 14, color: zt.accent),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: zt.textTertiary,
                  ),
                ],
              ),
            ),
          );

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.bedtime_outlined,
                        size: 18,
                        color: zt.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.claimAutoSilentSheetTitle,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: zt.textHi,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.claimAutoSilentSheetHint,
                    style: TextStyle(fontSize: 12, color: zt.textLo),
                  ),
                  const SizedBox(height: 14),
                  timeRow(
                    l10n.claimAutoSilentStart,
                    config.silentStartMinutes,
                    true,
                  ),
                  const SizedBox(height: 8),
                  timeRow(
                    l10n.claimAutoSilentEnd,
                    config.silentEndMinutes,
                    false,
                  ),
                  const SizedBox(height: 14),
                  // 轮询间隔选择（20261118-0110 G4）：1–120 分钟可选。
                  Text(
                    l10n.claimIntervalEntry,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: zt.textHi,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.claimIntervalSheetHint,
                    style: TextStyle(fontSize: 12, color: zt.textLo),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final m in const [
                        1,
                        2,
                        5,
                        10,
                        15,
                        30,
                        60,
                        120,
                      ])
                        ChoiceChip(
                          key: Key('claim-interval-$m'),
                          label: Text(l10n.claimIntervalMinutesValue(m)),
                          selected: config.intervalMinutes == m,
                          onSelected: (_) async {
                            await ref
                                .read(claimConfigProvider.notifier)
                                .setInterval(widget.device.id, m);
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    key: const Key('claim-auto-silent-toggle'),
                    onPressed: () async {
                      if (config.silentEnabled) {
                        await ref
                            .read(claimConfigProvider.notifier)
                            .setSilent(widget.device.id, 0, 0);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      } else {
                        await ref
                            .read(claimConfigProvider.notifier)
                            .setSilent(
                              widget.device.id,
                              ClaimSchedulerPolicy.defaultSilentStart,
                              ClaimSchedulerPolicy.defaultSilentEnd,
                            );
                        setSheetState(() {});
                      }
                    },
                    child: Text(
                      config.silentEnabled
                          ? l10n.claimAutoSilentDisable
                          : l10n.claimAutoSilentReset,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 历史 Tab（P2-6）：时间线列表，来源徽章 auto/manual，失败原因着色。
  Widget _historyTab(AppLocalizations l10n) {
    final board = ref.watch(claimHistoryProvider)[widget.device.id];
    final records = board?.records ?? const <ClaimRecord>[];
    final zt = context.zt;
    if (records.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: zt.accentSubtle,
                  border: Border.all(color: zt.accentBorder, width: 1.2),
                ),
                child: Icon(
                  Icons.history_rounded,
                  size: 32,
                  color: zt.accent,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                l10n.claimHistEmpty,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: zt.textHi,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.claimHistEmptyHint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: zt.textLo),
              ),
            ],
          ),
        ),
      );
    }
    final synced = board?.lastSyncedAt;
    final locale = Localizations.localeOf(context).toString();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (synced != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.schedule, size: 12, color: zt.textTertiary),
                const SizedBox(width: 4),
                Text(
                  l10n.claimHistLastSynced(ClaimFormat.dateTime(synced, locale)),
                  style: zrMono(fontSize: 11, color: zt.textTertiary),
                ),
              ],
            ),
          ),
        ZrSectionHead(title: l10n.claimHistCount(records.length)),
        const SizedBox(height: 8),
        for (final record in records) _historyCard(l10n, record),
      ],
    );
  }

  /// 阻断记录的原因 → 可读文案（20261116-2341 D1/D3；20261118-0030 F3 补宿主后台）。
  String _blockedText(AppLocalizations l10n, ClaimBlockedReason reason) =>
      switch (reason) {
        ClaimBlockedReason.previewError => l10n.claimBlockedPreviewError,
        ClaimBlockedReason.captchaConfigError => l10n.claimBlockedCaptchaConfig,
        ClaimBlockedReason.activityClosed => l10n.claimBlockedActivityClosed,
        ClaimBlockedReason.noPlans => l10n.claimBlockedNoPlans,
        ClaimBlockedReason.accountNotConfigured =>
          l10n.claimBlockedAccountNotConfigured,
        ClaimBlockedReason.hostBackgroundUnavailable =>
          l10n.claimBlockedHostBackground,
      };

  Widget _historyCard(AppLocalizations l10n, ClaimRecord record) {
    final zt = context.zt;
    final blocked = record.blockedReason;
    final title = blocked != null
        ? _blockedText(l10n, blocked)
        : record.planName.isNotEmpty
        ? record.planName
        : record.planId;
    // 阻断记录是"状态"而非"失败"：中性色，不用危险红。
    final okColor = record.success
        ? zt.live
        : blocked != null
        ? zt.textLo
        : zt.danger;
    final codeMessage = record.code == null
        ? null
        : _codeMessage(l10n, record.code!);
    final resultText = record.success
        ? l10n.claimHistResultOk
        : blocked != null
        ? (record.message.isNotEmpty ? record.message : l10n.claimHistResultFail)
        : codeMessage ??
              (record.message.isNotEmpty
                  ? record.message
                  : l10n.claimHistResultFail);
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: zt.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: zt.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${two(record.at.hour)}:${two(record.at.minute)}',
                  style: zrMono(
                    fontSize: 13,
                    weight: FontWeight.w700,
                    color: zt.textHi,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${two(record.at.month)}-${two(record.at.day)}',
                  style: zrMono(fontSize: 10, color: zt.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: zt.textHi,
                        ),
                      ),
                    ),
                    _sourceBadge(l10n, record.source),
                  ],
                ),
                if (record.benefitSummary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    record.benefitSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: zrMono(fontSize: 11, color: zt.textLo),
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      record.success
                          ? Icons.check_circle_outline
                          : record.blockedReason != null
                          ? Icons.info_outline
                          : Icons.error_outline,
                      size: 13,
                      color: okColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        resultText,
                        // F4（20261118-0030）：阻断详情（如完整 RPC 错误）可读
                        // 到 3 行，不再单行截断看不全。
                        maxLines: record.blockedReason != null ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: okColor,
                        ),
                      ),
                    ),
                    if (record.code != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '#${record.code}',
                        style: zrMono(fontSize: 10, color: zt.textTertiary),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceBadge(AppLocalizations l10n, ClaimRecordSource source) {
    final zt = context.zt;
    final isAuto = source == ClaimRecordSource.auto;
    final color = isAuto ? zt.live : zt.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.6),
      ),
      child: Text(
        isAuto ? l10n.claimHistSourceAuto : l10n.claimHistSourceManual,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// 服务不可用原因码 → 可读文案（原因码来自 [ClaimServiceProbe]）。
  String _serviceReasonText(AppLocalizations l10n) => switch (_serviceReason) {
    ClaimServiceProbe.reasonNoMethod => l10n.claimServiceNoMethod,
    ClaimServiceProbe.reasonNoServices => l10n.claimServiceNoServices,
    _ => l10n.claimServiceProbeFailed,
  };

  Widget _errorView(AppLocalizations l10n, bool offline) {
    final kind = _errorKind;
    final remote = kind == _ClaimErrorKind.remote;
    final service = kind == _ClaimErrorKind.service;
    final notReadyText =
        offline ? l10n.claimDeviceNotReady : l10n.claimServiceUnavailable;
    final zt = context.zt;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: zt.accentSubtle,
                border: Border.all(color: zt.accentBorder, width: 1.2),
              ),
              child: Icon(
                remote ? Icons.error_outline : Icons.cloud_off_outlined,
                size: 32,
                color: zt.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              remote
                  ? l10n.claimFailedGeneric
                  : (service ? _serviceReasonText(l10n) : notReadyText),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.zt.textHi,
              ),
            ),
            if (remote && _errorMessage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _errorMessage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.zt.textLo),
              ),
            ],
            // 可诊断：服务不可用必须给出"去哪查"，而不是灰着不知道原因。
            if (service) ...[
              const SizedBox(height: 6),
              Text(
                l10n.claimServiceUnavailableHint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.zt.textLo),
              ),
            ],
            const SizedBox(height: 16),
            TactileButton(label: l10n.claimRefresh, onPressed: _refresh),
            if (service && widget.onDiagnosticsPressed != null) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const Key('claim-service-diagnostics'),
                onPressed: widget.onDiagnosticsPressed,
                child: Text(l10n.toolboxDiagnostics),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyView(AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: context.zt.accentSubtle,
                border: Border.all(color: context.zt.accentBorder, width: 1.2),
              ),
              child: Icon(Icons.redeem_outlined, size: 32, color: context.zt.accent),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.claimEmpty,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.zt.textHi,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.claimEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.zt.textLo),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planCard(AppLocalizations l10n, ClaimPreview plan, bool offline) {
    final busyThis = _busy.contains(plan.planId);
    final disabled =
        offline || _busy.isNotEmpty || _refreshing || _claimAllRunning;
    final quotaUnits = _tokenUnits(plan);
    final zt = context.zt;

    return BevelCard(
      accent: true,
      radius: 20,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HwChip(
                text: plan.planId.toUpperCase(),
                color: zt.accent,
                icon: Icon(Icons.verified_outlined, size: 12, color: zt.accent),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.claimLimitedTag,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: zt.warn,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            plan.name.isEmpty ? plan.planId : plan.name,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              height: 1.15,
              color: zt.textHi,
            ),
          ),
          const SizedBox(height: 14),
          if (quotaUnits != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  quotaUnits,
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w900,
                    fontFamily: kMonoFamily,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: -1.2,
                    color: zt.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'TOKENS',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    fontFamily: kMonoFamily,
                    color: zt.textLo,
                  ),
                ),
              ],
            ),
          ] else if (plan.description.isNotEmpty) ...[
            Text(
              plan.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.4, color: zt.textLo),
            ),
          ],
          if (quotaUnits != null && plan.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              plan.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: zt.textLo),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: TactileButton(
              variant: TactileVariant.primary,
              height: 44,
              icon: busyThis
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: zt.onAccent,
                      ),
                    )
                  : const Icon(Icons.card_giftcard, size: 18),
              label: busyThis ? l10n.claimActionBusy : l10n.claimAction,
              onPressed: disabled ? null : () => _claim(plan),
            ),
          ),
        ],
      ),
    );
  }

  static String? _tokenUnits(ClaimPreview plan) {
    var total = 0;
    var found = false;
    for (final e in plan.entitlements) {
      if (e.unitType == 'token' &&
          e.meter == 'model_usage' &&
          e.units != null) {
        total += e.units!.toInt();
        found = true;
      }
    }
    if (!found) return null;
    final digits = total.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      final remain = digits.length - 1 - i;
      if (remain > 0 && remain % 3 == 0) buffer.write(',');
    }
    return buffer.toString();
  }
}
