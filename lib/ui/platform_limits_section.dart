import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/platform_caps.dart';
import '../theme.dart';
import 'bevel_card.dart';
import 'section_label.dart';

/// 平台限制说明卡（开发计划 20261115-0901 P5-2 初版仅 iOS；
/// 20261116-1434 P4 泛化为「各平台限制说明」，新增鸿蒙条目）。
///
/// iOS 与鸿蒙各显各自条目，Android 不显示；[visible] 仅供测试强制指定。
/// 文案如实告知（不冒充支持）；鸿蒙条目在 P6 真机走查后定稿。
class PlatformLimitsSection extends StatelessWidget {
  const PlatformLimitsSection({super.key, this.visible});

  /// null = 跟随真实平台判定；true/false 供测试注入。
  final bool? visible;

  bool get _show =>
      visible ?? (PlatformCaps.isIOS || PlatformCaps.isOhos);

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final isOhos = PlatformCaps.isOhos;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          isOhos ? l10n.platformLimitsOhosTitle : l10n.platformLimitsTitle,
        ),
        BevelCard(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isOhos
                    ? l10n.platformLimitsOhosIntro
                    : l10n.platformLimitsIntro,
                style: TextStyle(fontSize: 11.5, color: zt.textLo),
              ),
              const SizedBox(height: 10),
              _LimitRow(
                icon: Icons.shield_moon_outlined,
                title: l10n.platformLimitsKeepaliveTitle,
                body: isOhos
                    ? l10n.platformLimitsOhosKeepaliveBody
                    : l10n.platformLimitsKeepaliveBody,
              ),
              const SizedBox(height: 8),
              _LimitRow(
                icon: Icons.people_outline,
                title: l10n.platformLimitsIsolationTitle,
                body: isOhos
                    ? l10n.platformLimitsOhosIsolationBody
                    : l10n.platformLimitsIsolationBody,
              ),
              const SizedBox(height: 8),
              _LimitRow(
                icon: Icons.notifications_active_outlined,
                title: l10n.platformLimitsNotifyTitle,
                body: isOhos
                    ? l10n.platformLimitsOhosNotifyBody
                    : l10n.platformLimitsNotifyBody,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: zt.warn),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: zt.textHi,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: zt.textLo,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
