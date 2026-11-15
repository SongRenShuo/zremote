import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/git_overview.dart';
import '../state/automation.dart';
import '../state/claim_entry.dart';
import '../state/claim_history.dart';
import '../state/event_feed.dart';
import '../state/service_readiness.dart';
import '../theme.dart';
import 'git_card.dart';
import 'sheet_shell.dart';

Future<void> showToolboxSheet({
  required BuildContext context,
  required RemoteDevice device,
  required VoidCallback onAutomationPressed,
  required VoidCallback onClaimPressed,
  required VoidCallback onUsagePressed,
  required VoidCallback onModelSettingsPressed,
  VoidCallback? onDiagnosticsPressed,
  VoidCallback? onQuotaPressed,
  VoidCallback? onRewardsPressed,
  VoidCallback? onDesktopSettingsPressed,
  VoidCallback? onAssetsPressed,
  GitOverviewClient? gitClient,
  String? workspacePath,
}) {
  return showZrSheet<void>(
    context: context,
    builder: (sheetContext) => ToolboxSheet(
      device: device,
      onAutomationPressed: onAutomationPressed,
      onClaimPressed: onClaimPressed,
      onUsagePressed: onUsagePressed,
      onModelSettingsPressed: onModelSettingsPressed,
      onDiagnosticsPressed: onDiagnosticsPressed,
      onQuotaPressed: onQuotaPressed,
      onRewardsPressed: onRewardsPressed,
      onDesktopSettingsPressed: onDesktopSettingsPressed,
      onAssetsPressed: onAssetsPressed,
      gitClient: gitClient,
      workspacePath: workspacePath,
    ),
  );
}

/// 工具箱信息架构（P1-9）：四分组（会话操作 / 账号与套餐 / 资产 / 诊断）
/// + 本地搜索 + 「更多」折叠（≥8 个入口时默认收起低优先组）。
class ToolboxSheet extends ConsumerStatefulWidget {
  const ToolboxSheet({
    super.key,
    required this.device,
    required this.onAutomationPressed,
    required this.onClaimPressed,
    required this.onUsagePressed,
    required this.onModelSettingsPressed,
    this.onDiagnosticsPressed,
    this.onQuotaPressed,
    this.onRewardsPressed,
    this.onDesktopSettingsPressed,
    this.onAssetsPressed,
    this.gitClient,
    this.workspacePath,
  });

  final RemoteDevice device;
  final VoidCallback onAutomationPressed;
  final VoidCallback onClaimPressed;
  final VoidCallback onUsagePressed;
  final VoidCallback onModelSettingsPressed;
  final VoidCallback? onDiagnosticsPressed;

  /// 额度中心 / 福利中心入口（P1-2 / P1-3）；null 时卡片置灰。
  final VoidCallback? onQuotaPressed;
  final VoidCallback? onRewardsPressed;

  /// 桌面设置遥控（P1-6）/ 资产浏览（P1-8）；null 时置灰。
  final VoidCallback? onDesktopSettingsPressed;
  final VoidCallback? onAssetsPressed;

  /// Git 概览数据源（P1-7）；null 时 Git 卡置灰。
  final GitOverviewClient? gitClient;

  /// Git 卡的工作区路径（活动会话优先）。
  final String? workspacePath;

  @override
  ConsumerState<ToolboxSheet> createState() => _ToolboxSheetState();
}

class _ToolboxSheetState extends ConsumerState<ToolboxSheet> {
  String _query = '';
  bool _expanded = false;

  /// 折叠阈值：入口数 ≥8 时默认收起（任务 P1-9）。
  static const int collapseThreshold = 8;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final autoBoard = ref.watch(automationProvider)[widget.device.id];
    final claimReady = ref.watch(claimEntryProvider)[widget.device.id] == true;
    // P2-7：徽标扩展「今日已领 N」（读 claim_history 当日成功计数）；
    // claimReady 判定沿用现有（可领时优先展示可领徽标）。
    final todayClaimed =
        ref.watch(claimHistoryProvider)[widget.device.id]?.todayCount(
              DateTime.now(),
            ) ??
        0;
    // P1-9：审批待办徽章（permPending）。
    final permPending =
        ref.watch(eventFeedProvider)[widget.device.id]?.permPending ?? false;
    final readiness =
        ref.watch(serviceReadinessProvider)[widget.device.id] ??
        ServiceReadiness.unknown;

    final entries = <_ToolEntry>[
      _ToolEntry(
        id: 'model',
        group: _ToolGroup.sessionOps,
        icon: Icons.model_training_rounded,
        title: l10n.toolboxModel,
        subtitle: l10n.toolboxModelDesc,
        onTap: widget.onModelSettingsPressed,
      ),
      _ToolEntry(
        id: 'usage',
        group: _ToolGroup.sessionOps,
        icon: Icons.query_stats_rounded,
        title: l10n.toolboxUsage,
        subtitle: l10n.toolboxUsageDesc,
        onTap: widget.onUsagePressed,
      ),
      _ToolEntry(
        id: 'automation',
        group: _ToolGroup.sessionOps,
        icon: Icons.auto_mode_rounded,
        title: l10n.toolboxAutomation,
        subtitle: l10n.toolboxAutomationDesc,
        onTap: widget.onAutomationPressed,
        badgeText: (autoBoard?.queuedCount ?? 0) > 0
            ? l10n.toolboxQueued(autoBoard!.queuedCount)
            : null,
      ),
      _ToolEntry(
        id: 'desktop-settings',
        group: _ToolGroup.sessionOps,
        icon: Icons.tune_rounded,
        title: l10n.toolboxDesktopSettings,
        subtitle: l10n.toolboxDesktopSettingsDesc,
        onTap: widget.onDesktopSettingsPressed,
        enabled: widget.onDesktopSettingsPressed != null,
      ),
      _ToolEntry(
        id: 'quota',
        group: _ToolGroup.account,
        key: const Key('quota-toolbox-entry'),
        icon: Icons.data_usage_rounded,
        title: l10n.quotaToolboxTitle,
        subtitle: l10n.quotaToolboxDesc,
        onTap: widget.onQuotaPressed,
        enabled: widget.onQuotaPressed != null,
      ),
      _ToolEntry(
        id: 'rewards',
        group: _ToolGroup.account,
        key: const Key('rewards-toolbox-entry'),
        icon: Icons.redeem_outlined,
        title: l10n.rewardsToolboxTitle,
        subtitle: l10n.rewardsToolboxDesc,
        onTap: widget.onRewardsPressed,
        enabled: widget.onRewardsPressed != null,
      ),
      _ToolEntry(
        id: 'claim',
        group: _ToolGroup.account,
        icon: Icons.card_giftcard_rounded,
        title: l10n.toolboxClaim,
        subtitle: l10n.toolboxClaimDesc,
        onTap: widget.onClaimPressed,
        enabled: claimReady,
        badgeText: claimReady
            ? l10n.toolboxClaimReady
            : (todayClaimed > 0 ? l10n.claimHistTodayCount(todayClaimed) : null),
        badgeColor: claimReady ? zt.live : zt.accent,
      ),
      _ToolEntry(
        id: 'assets',
        group: _ToolGroup.assets,
        icon: Icons.category_outlined,
        title: l10n.assetsTitle,
        subtitle: l10n.toolboxAssetsDesc,
        onTap: widget.onAssetsPressed,
        enabled: widget.onAssetsPressed != null,
      ),
    ];

    final searching = _query.trim().isNotEmpty;
    final collapsed = !searching && !_expanded && entries.length >= collapseThreshold;
    // 折叠规则：收起时保留前两组（会话操作 + 账号与套餐，含领取就绪徽章），
    // 资产组（资产浏览 + Git 卡）藏进「更多」。
    final visibleEntries = searching
        ? [
            for (final e in entries)
              if (_matches(e)) e,
          ]
        : (collapsed
              ? [
                  for (final e in entries)
                    if (e.group != _ToolGroup.assets) e,
                ]
              : entries);
    // Git 卡（P1-7）：非搜索态跟随折叠；搜索命中也显示。
    final showGitCard = searching
        ? _matchesText(l10n.gitCardTitle, l10n.gitCardDesc)
        : !collapsed;
    final showMoreToggle = collapsed;

    String groupLabel(_ToolGroup group) => switch (group) {
      _ToolGroup.sessionOps => l10n.toolboxGroupSessionOps,
      _ToolGroup.account => l10n.toolboxGroupAccount,
      _ToolGroup.assets => l10n.toolboxGroupAssets,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: zt.accentSubtle,
                ),
                child: Icon(
                  Icons.dashboard_customize_outlined,
                  size: 17,
                  color: zt.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.toolboxTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: zt.textHi,
                  ),
                ),
              ),
              if (permPending) ...[
                Container(
                  key: const Key('toolbox-perm-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: zt.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: zt.danger.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    l10n.toolboxPermPending,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: zt.danger,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _SheetCloseButton(
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: zt.hairline),
        // P1-9：本地搜索框（过滤标题/副标题）。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: SizedBox(
            height: 34,
            child: TextField(
              key: const Key('toolbox-search'),
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 13, color: zt.textHi),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                prefixIcon: Icon(Icons.search, size: 16, color: zt.textLo),
                hintText: l10n.toolboxSearchHint,
                hintStyle: TextStyle(fontSize: 12, color: zt.textTertiary),
                filled: true,
                fillColor: zt.field,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: zt.hairline),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: zt.hairline),
                ),
              ),
            ),
          ),
        ),
        if (readiness == ServiceReadiness.unavailable)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: zt.textLo),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.sessionNotReadyHint,
                    style: TextStyle(fontSize: 11, color: zt.textLo),
                  ),
                ),
              ],
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in _ToolGroup.values) ..._groupSection(
                  label: groupLabel(group),
                  entries: [
                    for (final e in visibleEntries)
                      if (e.group == group) e,
                  ],
                  zt: zt,
                ),
                if (showGitCard)
                  GitCard(
                    client: widget.gitClient,
                    workspacePath: widget.workspacePath,
                  ),
              ],
            ),
          ),
        ),
        if (showMoreToggle)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: TextButton(
              key: const Key('toolbox-more'),
              onPressed: () => setState(() => _expanded = true),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.toolboxMore),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, size: 16),
                ],
              ),
            ),
          ),
        // 连接诊断入口（P0-1）：排障与修复验收的基础设施。
        Divider(height: 1, color: zt.hairline),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Icon(Icons.troubleshoot_outlined, size: 14, color: zt.textLo),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.toolboxDiagnosticsHint,
                  style: TextStyle(fontSize: 11, color: zt.textLo),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 30),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  widget.onDiagnosticsPressed?.call();
                },
                child: Text(l10n.toolboxDiagnostics),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _groupSection({
    required String label,
    required List<_ToolEntry> entries,
    required ZTPalette zt,
  }) {
    if (entries.isEmpty) return const [];
    final cards = <Widget>[
      for (final entry in entries)
        _ToolGridCard(
          key: entry.key ?? Key('toolbox-entry-${entry.id}'),
          icon: entry.icon,
          title: entry.title,
          subtitle: entry.subtitle,
          enabled: entry.enabled,
          badgeText: entry.badgeText,
          badgeColor: entry.badgeColor,
          onTap: () {
            Navigator.pop(context);
            entry.onTap?.call();
          },
        ),
    ];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: zt.textTertiary,
          ),
        ),
      ),
      for (var i = 0; i < cards.length; i += 2)
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < cards.length ? 10 : 0),
          child: Row(
            children: [
              Expanded(child: cards[i]),
              if (i + 1 < cards.length) ...[
                const SizedBox(width: 10),
                Expanded(child: cards[i + 1]),
              ],
            ],
          ),
        ),
      if (entries.isEmpty) const SizedBox.shrink(),
    ];
  }

  bool _matches(_ToolEntry entry) =>
      _matchesText(entry.title, entry.subtitle);

  bool _matchesText(String title, String subtitle) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return title.toLowerCase().contains(q) ||
        subtitle.toLowerCase().contains(q);
  }
}

enum _ToolGroup { sessionOps, account, assets }

class _ToolEntry {
  const _ToolEntry({
    required this.id,
    required this.group,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.key,
    this.enabled = true,
    this.badgeText,
    this.badgeColor,
  });

  final String id;
  final _ToolGroup group;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Key? key;
  final bool enabled;
  final String? badgeText;
  final Color? badgeColor;
}

class _ToolGridCard extends StatelessWidget {
  const _ToolGridCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    this.badgeText,
    this.badgeColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool enabled;
  final String? badgeText;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled ? 1.0 : 0.45,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? (enabled
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.white.withValues(alpha: 0.015))
                  : (enabled
                      ? zt.surface
                      : zt.field.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDark
                    ? (enabled
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.04))
                    : (enabled
                        ? zt.hairline
                        : zt.hairline.withValues(alpha: 0.5)),
                width: 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: enabled
                            ? zt.accentSubtle
                            : (isDark
                                ? Colors.white.withValues(alpha: 0.04)
                                : Colors.black.withValues(alpha: 0.03)),
                      ),
                      child: Icon(
                        icon,
                        size: 18,
                        color: enabled ? zt.accent : zt.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    if (badgeText != null)
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: (badgeColor ??
                                    (enabled ? zt.accent : zt.textTertiary))
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: (badgeColor ??
                                      (enabled ? zt.accent : zt.textTertiary))
                                  .withValues(alpha: 0.4),
                              width: 0.6,
                            ),
                          ),
                          child: Text(
                            badgeText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: badgeColor ??
                                  (enabled ? zt.accent : zt.textTertiary),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: enabled ? zt.textHi : zt.textLo,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.25,
                    color: enabled ? zt.textLo : zt.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetCloseButton extends StatelessWidget {
  const _SheetCloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : zt.surfaceHover,
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : zt.hairline,
            width: 0.8,
          ),
        ),
        child: Icon(Icons.close_rounded, size: 15, color: zt.textLo),
      ),
    );
  }
}
