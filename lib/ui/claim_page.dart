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
    _refresh();
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

  Future<void> _claim(ClaimPreview plan) async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy.isNotEmpty) return;
    if (ref.read(sessionStatusProvider)[widget.device.id] !=
        SessionStatus.live) {
      return;
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
        if (mounted) _snack('${l10n.claimFailedGeneric}${_msgOf(e)}');
        return;
      }
      if (!cfg.enabled || cfg.sceneId.isEmpty) {
        if (mounted) _snack(l10n.claimUnavailable);
        return;
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
          await _fallbackDialog();
          return;
        }
        verifyParam = param;
      } catch (e) {
        debugPrint('[claim] captcha verify error $e');
        await _fallbackDialog();
        return;
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
        if (mounted) _snack('${l10n.claimFailedGeneric}${_msgOf(e)}');
        return;
      }
      if (!mounted) return;

      if (outcome.success) {
        debugPrint('[claim] claim ok plan=${plan.planId}');
        _recordClaim(plan: plan, success: true, outcome: outcome);
        if (mounted) setState(() => _busy.clear());
        await showClaimTicketDialog(context, plan: plan, outcome: outcome);
        if (mounted) await _refresh();
      } else {
        debugPrint('[claim] claim fail code=${outcome.code}');
        _recordClaim(plan: plan, success: false, outcome: outcome);
        await _failureDialog(outcome);
      }
    } finally {
      hub.manualEnded(widget.device.id);
      if (mounted) setState(() => _busy.clear());
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
          if (_refreshing || _busy.isNotEmpty)
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
          if (config.enabled)
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
        ],
      ),
    );
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

  Widget _historyCard(AppLocalizations l10n, ClaimRecord record) {
    final zt = context.zt;
    final title = record.planName.isNotEmpty ? record.planName : record.planId;
    final okColor = record.success ? zt.live : zt.danger;
    final codeMessage = record.code == null
        ? null
        : _codeMessage(l10n, record.code!);
    final resultText = record.success
        ? l10n.claimHistResultOk
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
                          : Icons.error_outline,
                      size: 13,
                      color: okColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        resultText,
                        maxLines: 1,
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
    final disabled = offline || _busy.isNotEmpty || _refreshing;
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
