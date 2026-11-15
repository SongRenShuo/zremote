import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/quota_client.dart';
import '../services/rpc_bridge.dart';
import '../state/session_status.dart';
import '../theme.dart';
import 'bevel_card.dart';
import 'hw_chip.dart';
import 'status_led.dart';
import 'tactile_button.dart';

/// 额度中心（开发计划 20261115-0901 P1-2 / P1-5）：
/// 汇总卡 + 多套餐分组 + 模型余额行 + 下拉刷新 + 数据来源标注 + 重置卡区块。
class QuotaPage extends ConsumerStatefulWidget {
  const QuotaPage({
    super.key,
    required this.device,
    required this.bridge,
    this.tokenProvider,
    this.client,
  });

  final RemoteDevice device;
  final RpcBridge bridge;

  /// 通路 B 供票（集成时接账号库）；null 时仅通路 A。
  final QuotaTokenProvider? tokenProvider;

  /// 测试注入用；null 时按 bridge + tokenProvider 构造。
  final QuotaClient? client;

  @override
  ConsumerState<QuotaPage> createState() => _QuotaPageState();
}

enum _QuotaPhase { loading, ready, error }

class _QuotaPageState extends ConsumerState<QuotaPage> {
  _QuotaPhase _phase = _QuotaPhase.loading;
  String _errorMessage = '';
  bool _refreshing = false;

  QuotaOverview? _overview;

  bool? _resetSupported;
  ResetCardStatus? _resetStatus;
  bool _resetStatusFailed = false;
  String? _usingType;

  late final QuotaClient _client =
      widget.client ??
      QuotaClient(
        bridge: widget.bridge,
        tokenProvider: widget.tokenProvider,
      );

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted) setState(() {});
    try {
      final overview = await _client.fetch();
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _phase = _QuotaPhase.ready;
      });
      debugPrint(
        '[quota] refresh ok plans=${overview.plans.length} '
        'sources=${overview.sources.join("+")}',
      );
      await _refreshResetCard();
    } on QuotaFetchException catch (e) {
      debugPrint('[quota] refresh failed: ${e.message}');
      if (!mounted) return;
      setState(() {
        _phase = _QuotaPhase.error;
        _errorMessage = e.message;
      });
    } catch (e) {
      debugPrint('[quota] refresh error $e');
      if (!mounted) return;
      setState(() {
        _phase = _QuotaPhase.error;
        _errorMessage = '$e';
      });
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshResetCard() async {
    try {
      final supported = _resetSupported ??= await _client.resetCardSupported();
      if (!mounted || !supported) return;
      final status = await _client.fetchResetCardStatus();
      if (!mounted) return;
      setState(() {
        _resetStatus = status;
        _resetStatusFailed = false;
      });
    } on ResetCardUnsupportedException {
      // 探针 no-method：宿主无重置卡方法 → 隐藏该区块（P1-5）。
      if (mounted) setState(() => _resetSupported = false);
    } catch (e) {
      debugPrint('[quota] reset card degraded: $e');
      if (mounted) setState(() => _resetStatusFailed = true);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _useCard(ResetCardEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final name = _resetCardName(l10n, entry);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.quotaResetCardConfirmTitle),
        content: Text(l10n.quotaResetCardConfirmBody(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('quota-reset-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.quotaResetCardConfirmAction),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _usingType = entry.resetType);
    try {
      final result = await _client.useResetCard(entry.resetType);
      if (!mounted) return;
      if (result.success) {
        debugPrint(
          '[quota] reset card used type=${entry.resetType} '
          'key=${result.idempotencyKey}',
        );
        _snack(l10n.quotaResetCardUsed);
        await _refreshResetCard();
        await _refresh();
      } else if (result.rateLimited) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.quotaResetCardRateLimited),
            content: Text(
              result.nextTryAt == null
                  ? result.message
                  : l10n.quotaResetCardRetryAt(_fmtDateTime(result.nextTryAt!)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.claimGotIt),
              ),
            ],
          ),
        );
      } else {
        _snack(
          '${l10n.quotaResetCardUseFailed}'
          '${result.message.isEmpty ? '' : '（${result.message}）'}',
        );
      }
    } finally {
      if (mounted) setState(() => _usingType = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status = ref.watch(sessionStatusProvider)[widget.device.id];

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
          if (_refreshing)
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
              tooltip: l10n.quotaRefresh,
              onPressed: _refresh,
            ),
        ],
      ),
      body: switch (_phase) {
        _QuotaPhase.loading => const Center(child: CircularProgressIndicator()),
        _QuotaPhase.error => _errorView(l10n),
        _QuotaPhase.ready => RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _summaryCard(l10n),
              const SizedBox(height: 8),
              _sourceRow(l10n),
              const SizedBox(height: 12),
              for (var i = 0; i < _overview!.plans.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _slotCard(l10n, _overview!.plans[i], i),
              ],
              if (_resetSupported == true) ...[
                const SizedBox(height: 16),
                _resetCardBlock(l10n),
              ],
            ],
          ),
        ),
      },
    );
  }

  Widget _errorView(AppLocalizations l10n) {
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
                Icons.error_outline,
                size: 32,
                color: zt.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.quotaLoadFailed,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: zt.textHi,
              ),
            ),
            if (_errorMessage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _errorMessage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: zt.textLo),
              ),
            ],
            const SizedBox(height: 16),
            TactileButton(label: l10n.quotaRefresh, onPressed: _refresh),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(AppLocalizations l10n) {
    final overview = _overview!;
    final zt = context.zt;
    if (overview.noPlan || overview.plans.isEmpty) {
      return BevelCard(
        key: const Key('quota-summary-card'),
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(Icons.inbox_outlined, size: 22, color: zt.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.quotaNoPlan,
                  style: TextStyle(fontSize: 13.5, color: zt.textLo),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final primary = overview.primaryPlan;
    final slot = primary ?? overview.plans.first;
    final main = overview.mainItemOf(slot);
    final remainingPercent = slot.percentUsed == null
        ? null
        : (100 - slot.percentUsed!).clamp(0, 100);
    return BevelCard(
      key: const Key('quota-summary-card'),
      accent: true,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (slot.tier != null) ...[
                  HwChip(text: slot.tier!, color: zt.accent),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    slot.name ?? slot.tier ?? l10n.quotaTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: zt.textHi,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (remainingPercent != null)
                  Text(
                    l10n.quotaRemainingPercent(_fmtPercent(remainingPercent)),
                    style: zrMono(
                      fontSize: 13,
                      weight: FontWeight.w700,
                      color: remainingPercent >= 20 ? zt.live : zt.danger,
                    ),
                  ),
              ],
            ),
            if (_validityText(l10n, slot) case final validity?) ...[
              const SizedBox(height: 6),
              Text(
                validity,
                style: TextStyle(fontSize: 11.5, color: zt.textTertiary),
              ),
            ],
            if (main != null) ...[
              const SizedBox(height: 12),
              _windowRow(l10n, main, emphasized: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(AppLocalizations l10n) {
    final overview = _overview!;
    final zt = context.zt;
    final labels = [
      if (overview.sources.contains('host-snapshot')) l10n.quotaSourceHost,
      if (overview.hasDirectSource) l10n.quotaSourceDirect,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          for (final label in labels) ...[
            HwChip(text: label, color: zt.textTertiary),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          Text(
            l10n.quotaLastSync(_fmtClock(overview.refreshedAt)),
            style: TextStyle(fontSize: 10.5, color: zt.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _slotCard(AppLocalizations l10n, PlanSlot slot, int index) {
    final zt = context.zt;
    final windows = [
      for (final i in slot.items)
        if (i.kind != null) i,
    ];
    final balances = [
      for (final i in slot.items)
        if (i.kind == null) i,
    ];
    return BevelCard(
      key: Key('quota-slot-$index'),
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (slot.tier != null) ...[
                  HwChip(
                    text: slot.tier!,
                    color: slot.tierCode == QuotaTierCode.trial
                        ? zt.warn
                        : zt.accent,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    slot.name ?? l10n.quotaTierOther,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: zt.textHi,
                    ),
                  ),
                ),
              ],
            ),
            if (_validityText(l10n, slot) case final validity?) ...[
              const SizedBox(height: 4),
              Text(
                validity,
                style: TextStyle(fontSize: 11, color: zt.textTertiary),
              ),
            ],
            for (final w in windows) ...[
              const SizedBox(height: 10),
              _windowRow(l10n, w),
            ],
            if (balances.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                l10n.quotaModelBalanceTitle,
                style: zrMono(
                  fontSize: 11,
                  weight: FontWeight.w600,
                  color: zt.textLo,
                ),
              ),
              for (final b in balances) ...[
                const SizedBox(height: 6),
                _balanceRow(b),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 窗口条：标签 + 剩余百分比 + 进度条 + 重置时间/倒计时。
  Widget _windowRow(
    AppLocalizations l10n,
    QuotaItem item, {
    bool emphasized = false,
  }) {
    final zt = context.zt;
    final remaining = item.percentUsed == null
        ? null
        : (100 - item.percentUsed!).clamp(0, 100);
    final label = _windowLabel(l10n, item);
    final resetText = _resetText(l10n, item.resetAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: emphasized ? 12.5 : 12,
                  color: zt.textLo,
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (resetText != null)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  resetText,
                  style: zrMono(fontSize: 10.5, color: zt.textTertiary),
                ),
              ),
            Text(
              remaining == null ? '--' : '${_fmtPercent(remaining)}%',
              style: zrMono(
                fontSize: emphasized ? 13 : 12.5,
                weight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: zt.hairline,
            ),
            child: remaining == null
                ? null
                : Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (remaining / 100).clamp(0.0, 1.0),
                      heightFactor: 1.0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: _percentColor(zt, remaining),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// 模型余额行：show_name + capabilities 的 model:GLM-x 前缀 + remaining/total。
  Widget _balanceRow(QuotaItem item) {
    final zt = context.zt;
    final models = item.modelIds;
    final value = item.total == null
        ? _fmtNum(item.remaining)
        : '${_fmtNum(item.remaining)} / ${_fmtNum(item.total)}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: zt.textHi),
              ),
              if (models.isNotEmpty)
                Text(
                  models.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: zrMono(fontSize: 10, color: zt.textTertiary),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (item.periodEndAt != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              _fmtDate(item.periodEndAt!),
              style: zrMono(fontSize: 10, color: zt.textTertiary),
            ),
          ),
        Text(
          value,
          style: zrMono(
            fontSize: 12,
            weight: FontWeight.w600,
            color: zt.textHi,
          ),
        ),
      ],
    );
  }

  Widget _resetCardBlock(AppLocalizations l10n) {
    final zt = context.zt;
    final status = _resetStatus;
    return BevelCard(
      key: const Key('quota-reset-card'),
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.restart_alt_outlined, size: 15, color: zt.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.quotaResetCardTitle,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: zt.textHi,
                    ),
                  ),
                ),
                if (status?.hasUnreadHistory == true)
                  HwChip(text: l10n.quotaResetCardUnread, color: zt.warn),
              ],
            ),
            if (_resetStatusFailed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.quotaResetCardStatusFailed,
                  style: TextStyle(fontSize: 11.5, color: zt.warn),
                ),
              )
            else if (status == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              for (final entry in status.entries)
                _resetEntryRow(l10n, entry),
              if (status.history.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.quotaResetCardHistory,
                  style: zrMono(
                    fontSize: 11,
                    weight: FontWeight.w600,
                    color: zt.textLo,
                  ),
                ),
                for (final h in status.history.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Text(
                          h.usedAt == null ? '--' : _fmtDateTime(h.usedAt!),
                          style: zrMono(fontSize: 10.5, color: zt.textTertiary),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            h.resetType,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: zt.textLo,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _resetEntryRow(AppLocalizations l10n, ResetCardEntry entry) {
    final zt = context.zt;
    final busy = _usingType == entry.resetType;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _resetCardName(l10n, entry),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: zt.textHi,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.available > 0
                      ? l10n.quotaResetCardAvailable(entry.available)
                      : l10n.quotaResetCardNone,
                  style: TextStyle(
                    fontSize: 11,
                    color: entry.available > 0 ? zt.textLo : zt.textTertiary,
                  ),
                ),
                if (entry.expiresAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l10n.quotaResetCardExpires(_fmtDateTime(entry.expiresAt!)),
                      style: TextStyle(fontSize: 10.5, color: zt.textTertiary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 32,
            child: TactileButton(
              key: Key('quota-reset-use-${entry.resetType}'),
              label: busy ? l10n.quotaResetCardUseBusy : l10n.quotaResetCardUse,
              onPressed:
                  entry.available > 0 && _usingType == null
                  ? () => _useCard(entry)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  String _resetCardName(AppLocalizations l10n, ResetCardEntry entry) {
    if (entry.isFiveHour) return l10n.quotaResetCardFiveHour;
    if (entry.isWeekly) return l10n.quotaResetCardWeekly;
    return l10n.quotaResetCardGeneric;
  }

  String? _validityText(AppLocalizations l10n, PlanSlot slot) {
    final start = slot.startsAt;
    final end = slot.endsAt ?? slot.expireAt;
    if (start != null && end != null) {
      return l10n.quotaValidityRange('${_fmtDate(start)} ~ ${_fmtDate(end)}');
    }
    if (end != null) return l10n.quotaValidityUntil(_fmtDate(end));
    if (start != null) return l10n.quotaValidityUntil(_fmtDate(start));
    return null;
  }

  String _windowLabel(AppLocalizations l10n, QuotaItem item) {
    final period = _periodLabel(l10n, item.window);
    return switch (item.kind) {
      'prompt_count' => l10n.quotaWindowPromptCount(period),
      'duration' => l10n.quotaWindowDuration(period),
      _ => l10n.quotaWindowRaw(item.name, period),
    };
  }

  String _periodLabel(AppLocalizations l10n, String? window) {
    final w = window ?? '';
    if (w.startsWith('hours:')) {
      final n = int.tryParse(w.substring(6)) ?? 5;
      return l10n.quotaPeriodHours(n);
    }
    return switch (w) {
      'daily' => l10n.quotaPeriodDaily,
      'monthly' => l10n.quotaPeriodMonthly,
      'weekly' => l10n.quotaPeriodWeekly,
      _ => l10n.quotaPeriodCycle,
    };
  }

  String? _resetText(AppLocalizations l10n, DateTime? resetAt) {
    if (resetAt == null) return null;
    final diff = resetAt.difference(DateTime.now());
    if (diff.isNegative || diff.inMinutes <= 0) {
      return l10n.quotaResetsAt(_fmtClock(resetAt));
    }
    if (diff.inHours > 0) {
      return l10n.quotaResetInHm(diff.inHours, diff.inMinutes % 60);
    }
    return l10n.quotaResetInM(diff.inMinutes);
  }

  static Color _percentColor(ZTPalette zt, num remaining) =>
      remaining >= 50 ? zt.live : remaining >= 20 ? zt.warn : zt.danger;

  static String _fmtPercent(num v) =>
      v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static String _fmtNum(double? v) {
    if (v == null) return '--';
    if (v == v.roundToDouble()) {
      final digits = v.round().toString();
      final buffer = StringBuffer();
      for (var i = 0; i < digits.length; i++) {
        buffer.write(digits[i]);
        final remain = digits.length - 1 - i;
        if (remain > 0 && remain % 3 == 0) buffer.write(',');
      }
      return buffer.toString();
    }
    return v.toStringAsFixed(1);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtDate(DateTime t) => '${_two(t.month)}-${_two(t.day)}';

  static String _fmtClock(DateTime t) =>
      '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

  static String _fmtDateTime(DateTime t) => _fmtClock(t);
}
