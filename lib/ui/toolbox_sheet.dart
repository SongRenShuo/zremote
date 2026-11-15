import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../state/automation.dart';
import '../state/claim_entry.dart';
import '../state/service_readiness.dart';
import '../theme.dart';
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
    ),
  );
}

class ToolboxSheet extends ConsumerWidget {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final autoBoard = ref.watch(automationProvider)[device.id];
    final claimReady = ref.watch(claimEntryProvider)[device.id] == true;
    final readiness =
        ref.watch(serviceReadinessProvider)[device.id] ??
        ServiceReadiness.unknown;

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
              _SheetCloseButton(
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: zt.hairline),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ToolGridCard(
                      icon: Icons.model_training_rounded,
                      title: l10n.toolboxModel,
                      subtitle: l10n.toolboxModelDesc,
                      onTap: () {
                        Navigator.pop(context);
                        onModelSettingsPressed();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ToolGridCard(
                      icon: Icons.query_stats_rounded,
                      title: l10n.toolboxUsage,
                      subtitle: l10n.toolboxUsageDesc,
                      onTap: () {
                        Navigator.pop(context);
                        onUsagePressed();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _ToolGridCard(
                      icon: Icons.auto_mode_rounded,
                      title: l10n.toolboxAutomation,
                      subtitle: l10n.toolboxAutomationDesc,
                      badgeText: (autoBoard?.queuedCount ?? 0) > 0
                          ? l10n.toolboxQueued(autoBoard!.queuedCount)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        onAutomationPressed();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ToolGridCard(
                      icon: Icons.card_giftcard_rounded,
                      title: l10n.toolboxClaim,
                      subtitle: l10n.toolboxClaimDesc,
                      enabled: claimReady,
                      badgeText: claimReady ? l10n.toolboxClaimReady : null,
                      badgeColor: zt.live,
                      onTap: () {
                        Navigator.pop(context);
                        onClaimPressed();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _ToolGridCard(
                      key: const Key('quota-toolbox-entry'),
                      icon: Icons.data_usage_rounded,
                      title: l10n.quotaToolboxTitle,
                      subtitle: l10n.quotaToolboxDesc,
                      enabled: onQuotaPressed != null,
                      onTap: () {
                        Navigator.pop(context);
                        onQuotaPressed?.call();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ToolGridCard(
                      key: const Key('rewards-toolbox-entry'),
                      icon: Icons.redeem_outlined,
                      title: l10n.rewardsToolboxTitle,
                      subtitle: l10n.rewardsToolboxDesc,
                      enabled: onRewardsPressed != null,
                      onTap: () {
                        Navigator.pop(context);
                        onRewardsPressed?.call();
                      },
                    ),
                  ),
                ],
              ),
            ],
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
                  onDiagnosticsPressed?.call();
                },
                child: Text(l10n.toolboxDiagnostics),
              ),
            ],
          ),
        ),
      ],
    );
  }
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
