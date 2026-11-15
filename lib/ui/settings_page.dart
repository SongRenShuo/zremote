import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/notification_prefs.dart';
import '../services/biometric.dart';
import '../services/device_store.dart';
import '../services/keepalive.dart';
import '../services/update_checker.dart';
import '../services/webview_profile.dart';
import '../state/appearance.dart';
import '../state/app_lifecycle.dart';
import '../state/behavior.dart';
import '../state/locale.dart';
import '../state/notification_prefs.dart';
import '../state/keepalive.dart';
import '../state/session_pool.dart';
import '../state/theme_mode.dart';
import '../state/toolbox_nav.dart';
import '../theme.dart';
import 'about_page.dart';
import 'data_manage_page.dart';
import 'haptics.dart';
import 'ios_limits_section.dart';
import 'section_label.dart';
import 'sheet_shell.dart';

Future<String?> _showOptionSheet({
  required BuildContext context,
  required String title,
  required List<(String value, String label)> options,
  required String current,
}) {
  return showZrSheet<String>(
    context: context,
    builder: (sheetContext) {
      final zt = sheetContext.zt;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: zt.textHi,
              ),
            ),
          ),
          Divider(height: 1, color: zt.hairline),
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0)
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 14),
                color: zt.hairline,
              ),
            InkWell(
              onTap: () => Navigator.pop(sheetContext, options[i].$1),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Icon(
                      options[i].$1 == current
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: options[i].$1 == current ? zt.accent : zt.textLo,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        options[i].$2,
                        style: TextStyle(fontSize: 14, color: zt.textHi),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.zt.textLo),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Text(
          l10n.settingsTitle,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: context.zt.textHi,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            SectionLabel(l10n.sectionAppearance),
            const _CardGroup(
              children: [
                _LanguageTile(),
                _GroupDivider(),
                _ThemeTile(),
                _GroupDivider(),
                _FontScaleTile(),
                _GroupDivider(),
                _ReduceMotionTile(),
                _GroupDivider(),
                _HapticsTile(),
              ],
            ),
            const SizedBox(height: 16),
            SectionLabel(l10n.sectionSecurityKeepalive),
            const _CardGroup(
              children: [
                _BiometricTile(),
                _GroupDivider(),
                _RelockTile(),
                _GroupDivider(),
                _KeepAliveTile(),
                _GroupDivider(),
                _BatteryTile(),
              ],
            ),
            const SizedBox(height: 16),
            SectionLabel(l10n.sectionNotifications),
            const _NotificationCard(),
            const SizedBox(height: 16),
            SectionLabel(l10n.settingsSectionBehavior),
            const _CardGroup(
              children: [
                _DefaultModeTile(),
                _GroupDivider(),
                _RestoreTile(),
                _GroupDivider(),
                _SoftLimitTile(),
              ],
            ),
            const SizedBox(height: 16),
            SectionLabel(l10n.settingsSectionData),
            const _CardGroup(
              children: [
                _DataManageTile(),
                _GroupDivider(),
                _DiagnosticsTile(),
                _GroupDivider(),
                _UpdateTile(),
                _GroupDivider(),
                _AboutTile(),
              ],
            ),
            const SizedBox(height: 16),
            SectionLabel(l10n.settingsAdvanced),
            const _CardGroup(children: [_UaDesktopTile()]),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
              child: Text(
                l10n.settingsDiscoveryDetail,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: context.zt.textTertiary,
                ),
              ),
            ),
            // P5-2：iOS 平台限制说明卡（仅 iOS 设备渲染，非 iOS 零占位）。
            const SizedBox(height: 16),
            const IosLimitsSection(),
            const _VersionFooter(),
          ],
        ),
      ),
    );
  }
}

class _CardGroup extends StatelessWidget {
  const _CardGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.zt.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.zt.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: context.zt.hairline,
    );
  }
}

class _TileRow extends StatelessWidget {
  const _TileRow({
    required this.title,
    required this.subtitle,
    this.icon,
    this.iconColor,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: (iconColor ?? zt.accent).withValues(alpha: 0.10),
                ),
                child: Icon(icon, size: 17, color: iconColor ?? zt.accent),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: zt.textHi,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: zt.textLo),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _LanguageTile extends ConsumerWidget {
  const _LanguageTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final setting = ref.watch(localeSettingProvider);
    final current = setting == kLocaleSystem
        ? l10n.languageSystem
        : localeDisplayName(setting);
    return _TileRow(
      title: l10n.languageTitle,
      subtitle: current,
      icon: Icons.language,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final setting = ref.read(localeSettingProvider);
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.languageTitle,
      options: [
        (kLocaleSystem, l10n.languageSystem),
        for (final locale in AppLocalizations.supportedLocales)
          (locale.languageCode, localeDisplayName(locale.languageCode)),
      ],
      current: setting,
    );
    if (choice == null || choice == setting) return;
    await ref.read(localeSettingProvider.notifier).set(choice);
  }
}

class _ThemeTile extends ConsumerWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final setting = ref.watch(themeModeSettingProvider);
    final current = switch (setting) {
      kThemeDark => l10n.themeDark,
      kThemeLight => l10n.themeLight,
      kThemeOled => l10n.themeOled,
      _ => l10n.themeSystem,
    };
    return _TileRow(
      title: l10n.themeTitle,
      subtitle: current,
      icon: Icons.contrast,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final setting = ref.read(themeModeSettingProvider);
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.themeTitle,
      options: [
        (kThemeSystem, l10n.themeSystem),
        (kThemeDark, l10n.themeDark),
        (kThemeLight, l10n.themeLight),
        (kThemeOled, l10n.themeOled),
      ],
      current: setting,
    );
    if (choice == null || choice == setting) return;
    await ref.read(themeModeSettingProvider.notifier).set(choice);
  }
}

/// 字号缩放（P3-3）：0.85 / 1.0 / 1.15。
class _FontScaleTile extends ConsumerWidget {
  const _FontScaleTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scale = ref.watch(appearanceProvider).fontScale;
    final current = switch (scale) {
      ZrFontScale.small => l10n.settingsFontScaleSmall,
      ZrFontScale.large => l10n.settingsFontScaleLarge,
      _ => l10n.settingsFontScaleNormal,
    };
    return _TileRow(
      title: l10n.settingsFontScale,
      subtitle: current,
      icon: Icons.format_size,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(appearanceProvider).fontScale;
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.settingsFontScale,
      options: [
        (ZrFontScale.small.name, l10n.settingsFontScaleSmall),
        (ZrFontScale.normal.name, l10n.settingsFontScaleNormal),
        (ZrFontScale.large.name, l10n.settingsFontScaleLarge),
      ],
      current: current.name,
    );
    if (choice == null) return;
    final scale = ZrFontScale.values.firstWhere(
      (s) => s.name == choice,
      orElse: () => ZrFontScale.normal,
    );
    if (scale == current) return;
    ZrHaptics.tap();
    await ref.read(appearanceProvider.notifier).setFontScale(scale);
  }
}

/// 动效减弱（P3-3）。
class _ReduceMotionTile extends ConsumerWidget {
  const _ReduceMotionTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final value = ref.watch(appearanceProvider).reduceMotion;
    return _TileRow(
      title: l10n.settingsReduceMotion,
      subtitle: l10n.settingsReduceMotionSub,
      icon: Icons.animation,
      trailing: Switch(value: value, onChanged: (v) => _set(ref, v)),
    );
  }

  Future<void> _set(WidgetRef ref, bool v) async {
    ZrHaptics.tap();
    await ref.read(appearanceProvider.notifier).setReduceMotion(v);
  }
}

/// 触感反馈（P3-3）。
class _HapticsTile extends ConsumerWidget {
  const _HapticsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final value = ref.watch(appearanceProvider).haptics;
    return _TileRow(
      title: l10n.settingsHaptics,
      subtitle: l10n.settingsHapticsSub,
      icon: Icons.vibration,
      trailing: Switch(value: value, onChanged: (v) => _set(ref, v)),
    );
  }

  Future<void> _set(WidgetRef ref, bool v) async {
    if (v) ZrHaptics.tap();
    await ref.read(appearanceProvider.notifier).setHaptics(v);
  }
}

/// 自动锁定延时（P3-8）：立即 / 10s / 60s / 5min。
class _RelockTile extends ConsumerWidget {
  const _RelockTile();

  String _label(AppLocalizations l10n, int seconds) {
    if (seconds == 0) return l10n.settingsRelockImmediate;
    if (seconds < 60) return l10n.settingsRelockSeconds(seconds);
    return l10n.settingsRelockMinutes(seconds ~/ 60);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final seconds = ref.watch(relockDelayProvider);
    return _TileRow(
      title: l10n.settingsRelockDelay,
      subtitle: _label(l10n, seconds),
      icon: Icons.lock_clock,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(relockDelayProvider);
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.settingsRelockDelay,
      options: [
        for (final s in DeviceStore.kRelockChoices)
          ('$s', _label(l10n, s)),
      ],
      current: '$current',
    );
    if (choice == null) return;
    final seconds = int.tryParse(choice);
    if (seconds == null || seconds == current) return;
    ZrHaptics.tap();
    await ref.read(relockDelayProvider.notifier).set(seconds);
  }
}

class _BiometricTile extends ConsumerWidget {
  const _BiometricTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(biometricProvider);
    final l10n = AppLocalizations.of(context)!;
    return _TileRow(
      title: l10n.biometricLockTitle,
      subtitle: l10n.biometricLockSubtitle,
      icon: Icons.fingerprint,
      trailing: Switch(
        value: enabled,
        onChanged: (value) => _toggle(context, ref, value),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool value) async {
    final l10n = AppLocalizations.of(context)!;
    void toast(String msg) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    if (value) {
      final available = await BiometricService.instance.isAvailable();
      if (!available) {
        if (context.mounted) toast(l10n.biometricUnavailableToast);
        return;
      }
    }

    final bool ok;
    try {
      ok = await BiometricService.instance.authenticate(
        value ? l10n.biometricEnableReason : l10n.biometricDisableReason,
      );
    } on BiometricUnavailableException {
      if (!value) await ref.read(biometricProvider.notifier).set(false);
      if (context.mounted) {
        toast(
          value ? l10n.biometricNoLockToast : l10n.biometricForceDisabledToast,
        );
      }
      return;
    } catch (e) {
      if (context.mounted) toast(l10n.authIncompleteToast('$e'));
      return;
    }

    if (ok) {
      await ref.read(biometricProvider.notifier).set(value);
    }
  }
}

class _KeepAliveTile extends ConsumerWidget {
  const _KeepAliveTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(keepAliveEnabledProvider);
    final l10n = AppLocalizations.of(context)!;
    return _TileRow(
      title: l10n.keepAliveTitle,
      subtitle: enabled ? l10n.keepAliveOn : l10n.keepAliveOff,
      icon: Icons.shield_outlined,
      trailing: Switch(
        value: enabled,
        onChanged: (v) => ref.read(keepAliveEnabledProvider.notifier).set(v),
      ),
    );
  }
}

class _BatteryTile extends ConsumerStatefulWidget {
  const _BatteryTile();

  @override
  ConsumerState<_BatteryTile> createState() => _BatteryTileState();
}

class _BatteryTileState extends ConsumerState<_BatteryTile> {
  bool? _ignored;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final service = KeepAliveService.instance;
    final results = await Future.wait([
      service.isBatteryIgnored,
      service.isBlocked,
    ]);
    if (mounted) {
      setState(() {
        _ignored = results[0];
        _blocked = results[1];
      });
    }
  }

  Future<void> _request() async {
    final service = KeepAliveService.instance;
    if (_blocked) {
      await service.requestVendorExemption();
    } else {
      await service.requestBatteryExemption();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLifecycleProvider, (prev, next) {
      if (next == AppLifecycleState.resumed) _refresh();
    });
    ref.listen(keepAliveEnabledProvider, (_, _) => _refresh());
    final l10n = AppLocalizations.of(context)!;
    return _TileRow(
      title: l10n.batteryWhitelistTitle,
      subtitle: switch ((_blocked, _ignored)) {
        (true, _) => l10n.batteryBlocked,
        (_, null) => l10n.batteryChecking,
        (_, false) => l10n.batteryNotExempt,
        (_, true) => l10n.batteryExempt,
      },
      icon: _blocked ? Icons.shield_moon_outlined : Icons.battery_saver,
      iconColor: _blocked ? context.zt.danger : context.zt.accent,
      trailing: switch ((_blocked, _ignored)) {
        (_, null) => const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        (true, _) => Icon(
          Icons.warning_amber_rounded,
          size: 20,
          color: context.zt.danger,
        ),
        (_, true) => Text(
          l10n.settingsExemptBadge,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.zt.live,
          ),
        ),
        (_, false) => Icon(Icons.chevron_right, color: context.zt.textLo),
      },
      onTap: _blocked || _ignored != true ? _request : null,
    );
  }
}

class _NotificationCard extends ConsumerWidget {
  const _NotificationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(notificationPrefsProvider);
    final notifier = ref.read(notificationPrefsProvider.notifier);
    final l10n = AppLocalizations.of(context)!;

    Widget tile(
      String title,
      String subtitle,
      bool value,
      ValueChanged<bool> onChanged,
    ) => _TileRow(
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        onChanged: (v) {
          ZrHaptics.tap();
          onChanged(v);
        },
      ),
    );

    return _CardGroup(
      children: [
        tile(
          l10n.notifApprovalTitle,
          l10n.notifApprovalSubtitle,
          prefs.approval,
          (v) => notifier.set(prefs.copyWith(approval: v)),
        ),
        const _GroupDivider(),
        tile(
          l10n.notifCompleteTitle,
          l10n.notifCompleteSubtitle,
          prefs.complete,
          (v) => notifier.set(prefs.copyWith(complete: v)),
        ),
        const _GroupDivider(),
        tile(
          l10n.notifFailTitle,
          l10n.notifFailSubtitle,
          prefs.fail,
          (v) => notifier.set(prefs.copyWith(fail: v)),
        ),
        const _GroupDivider(),
        // P3-1 新类型：自动领取结果 / 需人工验证码 / 额度耗尽（占位）。
        tile(
          l10n.settingsNotifClaimResult,
          l10n.settingsNotifClaimResultSub,
          prefs.claimResult,
          (v) => notifier.set(prefs.copyWith(claimResult: v)),
        ),
        const _GroupDivider(),
        tile(
          l10n.settingsNotifCaptcha,
          l10n.settingsNotifCaptchaSub,
          prefs.captchaManual,
          (v) => notifier.set(prefs.copyWith(captchaManual: v)),
        ),
        const _GroupDivider(),
        tile(
          l10n.settingsNotifQuotaLow,
          l10n.settingsNotifQuotaLowSub,
          prefs.quotaLow,
          (v) => notifier.set(prefs.copyWith(quotaLow: v)),
        ),
        if (prefs.quotaLow) ...[
          const _GroupDivider(),
          _QuotaThresholdTile(prefs: prefs),
        ],
        const _GroupDivider(),
        _DndTile(prefs: prefs),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.notifFootnote,
              style: TextStyle(
                fontSize: 11,
                color: context.zt.textTertiary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 免打扰时段（P3-1）：预设档（关闭 / 22:00–07:00 / 23:00–08:00 /
/// 12:00–13:30）；时段内仅审批类高优放行。
class _DndTile extends ConsumerWidget {
  const _DndTile({required this.prefs});

  final NotificationPrefs prefs;

  static String _hhmm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = prefs.dndEnabled
        ? l10n.settingsNotifDndValue(
            _hhmm(prefs.dndStartMinutes),
            _hhmm(prefs.dndEndMinutes),
          )
        : l10n.settingsNotifDndOff;
    return _TileRow(
      title: l10n.settingsNotifDnd,
      subtitle: '$subtitle · ${l10n.settingsNotifDndHint}',
      icon: Icons.do_not_disturb_on_outlined,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final currentKey = prefs.dndEnabled
        ? '${prefs.dndStartMinutes}-${prefs.dndEndMinutes}'
        : 'off';
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.settingsNotifDnd,
      options: [
        ('off', l10n.settingsNotifDndOff),
        ('1320-420', l10n.settingsNotifDndValue('22:00', '07:00')),
        ('1380-480', l10n.settingsNotifDndValue('23:00', '08:00')),
        ('720-810', l10n.settingsNotifDndValue('12:00', '13:30')),
      ],
      current: currentKey,
    );
    if (choice == null) return;
    if (choice == 'off') {
      await ref
          .read(notificationPrefsProvider.notifier)
          .set(prefs.copyWith(dndStartMinutes: 0, dndEndMinutes: 0));
      return;
    }
    final parts = choice.split('-');
    final start = int.tryParse(parts[0]);
    final end = int.tryParse(parts[1]);
    if (start == null || end == null) return;
    ZrHaptics.tap();
    await ref
        .read(notificationPrefsProvider.notifier)
        .set(prefs.copyWith(dndStartMinutes: start, dndEndMinutes: end));
  }
}

/// 额度预警阈值滑杆（额度消耗预警）：50–100%，步进 1；拖动结束才落盘。
class _QuotaThresholdTile extends ConsumerStatefulWidget {
  const _QuotaThresholdTile({required this.prefs});

  final NotificationPrefs prefs;

  @override
  ConsumerState<_QuotaThresholdTile> createState() => _QuotaThresholdTileState();
}

class _QuotaThresholdTileState extends ConsumerState<_QuotaThresholdTile> {
  late double _value = widget.prefs.quotaAlertThreshold.toDouble();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
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
                  color: zt.warn.withValues(alpha: 0.10),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 17,
                  color: zt.warn,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsNotifQuotaThreshold,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      l10n.settingsNotifQuotaThresholdSub,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: zt.textLo,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '${_value.round()}%',
                style: zrMono(
                  fontSize: 13,
                  weight: FontWeight.w700,
                  color: zt.textHi,
                ),
              ),
            ],
          ),
          Slider(
            key: const Key('quota-threshold-slider'),
            value: _value,
            min: 50,
            max: 100,
            divisions: 50,
            label: '${_value.round()}%',
            onChanged: (v) => setState(() => _value = v),
            onChangeEnd: (v) {
              ZrHaptics.tap();
              ref
                  .read(notificationPrefsProvider.notifier)
                  .set(widget.prefs.copyWith(quotaAlertThreshold: v.round()));
            },
          ),
        ],
      ),
    );
  }
}

/// 会话行为（P3-4）。
class _DefaultModeTile extends ConsumerWidget {
  const _DefaultModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final mode = ref.watch(behaviorProvider).defaultMode;
    return _TileRow(
      title: l10n.settingsBehaviorDefaultMode,
      subtitle: l10n.settingsBehaviorDefaultModeSub,
      icon: Icons.tune_rounded,
      trailing: Text(
        mode,
        style: zrMono(fontSize: 12, color: context.zt.textLo),
      ),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(behaviorProvider).defaultMode;
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.settingsBehaviorDefaultMode,
      options: [
        for (final m in kBehaviorModes) (m, m.toUpperCase()),
      ],
      current: current,
    );
    if (choice == null || choice == current) return;
    ZrHaptics.tap();
    await ref.read(behaviorProvider.notifier).setDefaultMode(choice);
  }
}

class _RestoreTile extends ConsumerWidget {
  const _RestoreTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final policy = ref.watch(behaviorProvider).restorePolicy;
    final current = switch (policy) {
      ZrRestorePolicy.first => l10n.settingsRestoreFirst,
      ZrRestorePolicy.none => l10n.settingsRestoreNone,
      _ => l10n.settingsRestoreLastDevice,
    };
    return _TileRow(
      title: l10n.settingsBehaviorRestore,
      subtitle: current,
      icon: Icons.restart_alt,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(behaviorProvider).restorePolicy.name;
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.settingsBehaviorRestore,
      options: [
        (kRestoreLastDevice, l10n.settingsRestoreLastDevice),
        (kRestoreFirst, l10n.settingsRestoreFirst),
        (kRestoreNone, l10n.settingsRestoreNone),
      ],
      current: current,
    );
    if (choice == null) return;
    final policy = restorePolicyOf(choice);
    if (policy.name == current) return;
    ZrHaptics.tap();
    await ref.read(behaviorProvider.notifier).setRestorePolicy(policy);
  }
}

class _SoftLimitTile extends ConsumerWidget {
  const _SoftLimitTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final limit = ref.watch(behaviorProvider).softLimit;
    return _TileRow(
      title: l10n.settingsBehaviorSoftLimit,
      subtitle: l10n.settingsBehaviorSoftLimitSub(limit),
      icon: Icons.device_hub_outlined,
      trailing: Text(
        '$limit',
        style: zrMono(fontSize: 12, color: context.zt.textLo),
      ),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final current = '${ref.read(behaviorProvider).softLimit}';
    final choice = await _showOptionSheet(
      context: context,
      title: l10n.settingsBehaviorSoftLimit,
      options: [for (var n = 1; n <= 10; n++) ('$n', '$n')],
      current: current,
    );
    if (choice == null) return;
    final limit = int.tryParse(choice);
    if (limit == null || '$limit' == current) return;
    ZrHaptics.tap();
    await ref.read(behaviorProvider.notifier).setSoftLimit(limit);
  }
}

/// 数据与诊断（P3-2/P3-5/P3-6/P3-7 入口）。
class _DataManageTile extends StatelessWidget {
  const _DataManageTile();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _TileRow(
      title: l10n.settingsDataManage,
      subtitle: l10n.settingsDataManageSub,
      icon: Icons.storage,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const DataManagePage()),
      ),
    );
  }
}

class _DiagnosticsTile extends ConsumerWidget {
  const _DiagnosticsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final devices = ref.watch(deviceListProvider);
    final hasDevice = devices.isNotEmpty;
    return _TileRow(
      title: l10n.settingsDiagnosticsEntry,
      subtitle: hasDevice
          ? l10n.settingsDiagnosticsSub
          : l10n.settingsDiagnosticsNoDevice,
      icon: Icons.troubleshoot_outlined,
      onTap: hasDevice
          ? () {
              final active = ref.read(activeTabProvider);
              final device =
                  active < devices.length ? devices[active] : devices.first;
              ref
                  .read(diagnosticsOpenRequestProvider.notifier)
                  .request(device.id);
              Navigator.of(context).pop();
            }
          : null,
    );
  }
}

class _AboutTile extends StatelessWidget {
  const _AboutTile();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _TileRow(
      title: l10n.settingsAbout,
      subtitle: l10n.settingsAboutSub,
      icon: Icons.info_outline,
      trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AboutPage()),
      ),
    );
  }
}

/// 更新检查（P3-5 接 UI）：GitHub Releases latest 比对，只提示不强更。
class _UpdateTile extends ConsumerStatefulWidget {
  const _UpdateTile();

  @override
  ConsumerState<_UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends ConsumerState<_UpdateTile> {
  bool _checking = false;
  UpdateInfo? _update;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final update = await UpdateChecker(currentVersion: info.version)
          .checkLatest();
      if (!mounted) return;
      setState(() => _update = update);
    } catch (_) {
      if (mounted) setState(() => _update = null);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final update = _update;
    final subtitle = _checking
        ? l10n.settingsUpdateChecking
        : (update == null
            ? l10n.settingsUpdateCheckSub
            : l10n.settingsUpdateAvailable(update.latestVersion));
    return _TileRow(
      title: l10n.settingsUpdateCheck,
      subtitle: subtitle,
      icon: Icons.system_update_alt,
      trailing: _checking
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (update == null
              ? Icon(Icons.chevron_right, color: context.zt.textLo)
              : TextButton(
                  onPressed: () => _openRelease(update.releaseUrl),
                  child: Text(l10n.settingsUpdateOpenRelease),
                )),
      onTap: _checking ? null : _check,
    );
  }

  Future<void> _openRelease(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// 高级区（P3-7）：WebView 桌面 UA 覆写实验开关。
class _UaDesktopTile extends ConsumerWidget {
  const _UaDesktopTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final value = ref.watch(uaDesktopProvider);
    return _TileRow(
      title: l10n.settingsUaDesktop,
      subtitle: l10n.settingsUaDesktopSub,
      icon: Icons.science_outlined,
      iconColor: context.zt.warn,
      trailing: Switch(
        value: value,
        onChanged: (v) {
          ZrHaptics.tap();
          ref.read(uaDesktopProvider.notifier).set(v);
        },
      ),
    );
  }
}

class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  static final _info = PackageInfo.fromPlatform();
  static const _repoUrl = 'https://github.com/pjpv/zremote';

  Future<void> _openRepo() async {
    try {
      await launchUrl(
        Uri.parse(_repoUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox(height: 40);
        return Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 20),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      'ZRemote',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'v${info.version}',
                      style: zrMono(
                        fontSize: 11,
                        weight: FontWeight.w400,
                        letterSpacing: 0.4,
                        color: context.zt.textLo,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _openRepo,
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.verified_outlined,
                          size: 13,
                          color: context.zt.accent,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '${AppLocalizations.of(context)!.repoPrefix}: github.com/pjpv/zremote',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                            color: context.zt.accent,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Icon(
                          Icons.open_in_new_outlined,
                          size: 12,
                          color: context.zt.accent,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
