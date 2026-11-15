import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'bevel_card.dart';
import 'section_label.dart';

/// iOS 平台限制说明卡（开发计划 20261115-0901 P5-2）。
///
/// 仅在 iOS 设备上渲染（[Platform.isIOS]）——Material 版设置页同样可见，
/// 但 Android 设备不显示；[visible] 仅供测试强制指定。
/// 三条如实告知（不冒充支持）：
/// 1. 保活前台服务：iOS 无常驻后台服务，后台保活/自动领取后台续跑不适用；
/// 2. WebView 多 Profile 隔离：iOS 系统 WebView 不支持，多账号共用登录
///    （会话页隔离降级横幅在 iOS 上抑制，事实陈述收敛到本卡——
///    见 webview_profile.dart multiProfileSupportedProvider 的 iOS 分支）；
/// 3. 通知部分能力：审批通知动作按钮为 Android 专属（见 notifier.dart
///    notificationDetailsFor 注释）。
///
/// 未验证（not run，本机无 macOS）：iOS 真机渲染随版本回归（验收清单 S3）。
class IosLimitsSection extends StatelessWidget {
  const IosLimitsSection({super.key, this.visible});

  /// null = 跟随真实平台判定；true/false 供测试注入。
  final bool? visible;

  bool get _show => visible ?? Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(l10n.platformLimitsTitle),
        BevelCard(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.platformLimitsIntro,
                style: TextStyle(fontSize: 11.5, color: zt.textLo),
              ),
              const SizedBox(height: 10),
              _LimitRow(
                icon: Icons.shield_moon_outlined,
                title: l10n.platformLimitsKeepaliveTitle,
                body: l10n.platformLimitsKeepaliveBody,
              ),
              const SizedBox(height: 8),
              _LimitRow(
                icon: Icons.people_outline,
                title: l10n.platformLimitsIsolationTitle,
                body: l10n.platformLimitsIsolationBody,
              ),
              const SizedBox(height: 8),
              _LimitRow(
                icon: Icons.notifications_active_outlined,
                title: l10n.platformLimitsNotifyTitle,
                body: l10n.platformLimitsNotifyBody,
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
