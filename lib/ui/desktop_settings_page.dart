import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/rpc_bridge.dart';
import '../theme.dart';
import 'bevel_card.dart';

/// 桌面设置遥控（开发计划 20261115-0901 P1-6）：
/// `setting` 频道（rpc_bridge 既有）`get` / `update` 白名单快捷开关。
///
/// 白名单四开关 + locale 只读；写操作先确认（改的是桌面端行为），
/// update 以 patch 对象提交（ISettingService.update 的 Partial AppSettings）。
class DesktopSettingsPage extends StatefulWidget {
  const DesktopSettingsPage({
    super.key,
    required this.device,
    required this.bridge,
  });

  final RemoteDevice device;
  final RpcBridge bridge;

  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

/// 可遥控的桌面设置白名单（key → 是否布尔开关；false 项只读展示）。
abstract final class DesktopSettingWhitelist {
  static const List<String> toggleKeys = [
    'messageStreamShowReasoning',
    'messageStreamShowTodos',
    'taskAutoArchiveEnabled',
    'keepAwakeWhileRunning',
  ];

  static const List<String> readonlyKeys = ['locale'];
}

enum _Phase { loading, ready, error, notReady }

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  _Phase _phase = _Phase.loading;
  String _errorMessage = '';
  Map<String, dynamic> _settings = const {};
  final Set<String> _writing = {};

  Future<void> _refresh() async {
    setState(() => _phase = _phase == _Phase.ready ? _phase : _Phase.loading);
    try {
      final r = await widget.bridge.call('setting', 'get');
      final j = r.firstObjectDeep;
      if (!mounted) return;
      if (j == null) {
        setState(() {
          _phase = _Phase.error;
          _errorMessage = 'setting.get: ${r.debugText()}';
        });
        return;
      }
      setState(() {
        _settings = j;
        _phase = _Phase.ready;
      });
    } on RpcRemoteException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = e.message.contains('no-services')
            ? _Phase.notReady
            : _Phase.error;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = '$e';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _toggle(String key, bool value) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.desktopSettingsConfirmTitle),
        content: Text(
          l10n.desktopSettingsConfirmBody(_settingLabel(l10n, key), value
              ? l10n.desktopSettingsValueOn
              : l10n.desktopSettingsValueOff),
        ),
        actions: [
          TextButton(
            key: const Key('desktop-setting-confirm-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('desktop-setting-confirm-ok'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.desktopSettingsConfirmAction),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _writing.add(key));
    try {
      await widget.bridge.call('setting', 'update', params: {key: value});
      if (!mounted) return;
      setState(() => _settings = {..._settings, key: value});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.desktopSettingsUpdateFailed('$e'))),
      );
      await _refresh();
    } finally {
      if (mounted) setState(() => _writing.remove(key));
    }
  }

  String _settingLabel(AppLocalizations l10n, String key) => switch (key) {
    'messageStreamShowReasoning' => l10n.desktopSettingsShowReasoning,
    'messageStreamShowTodos' => l10n.desktopSettingsShowTodos,
    'taskAutoArchiveEnabled' => l10n.desktopSettingsAutoArchive,
    'keepAwakeWhileRunning' => l10n.desktopSettingsKeepAwake,
    'locale' => l10n.desktopSettingsLocale,
    _ => key,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(
          l10n.desktopSettingsTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _Phase.notReady => _HintBody(
          icon: Icons.cloud_off_outlined,
          message: l10n.sessionNotReadyHint,
          actionLabel: l10n.rewardsRetry,
          onAction: _refresh,
        ),
        _Phase.error => _HintBody(
          icon: Icons.error_outline_rounded,
          message: _errorMessage,
          actionLabel: l10n.rewardsRetry,
          onAction: _refresh,
        ),
        _Phase.ready => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(
              children: [
                Icon(Icons.tune, size: 15, color: zt.textLo),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.desktopSettingsHint(
                      widget.device.displayName(l10n),
                    ),
                    style: TextStyle(fontSize: 11.5, color: zt.textLo),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final key in DesktopSettingWhitelist.toggleKeys)
              _SettingToggleRow(
                key: Key('desktop-setting-$key'),
                label: _settingLabel(l10n, key),
                value: _settings[key] is bool
                    ? _settings[key] as bool
                    : null,
                writing: _writing.contains(key),
                // 值未知（宿主未回该键）时不可交互，避免盲写。
                onChanged: _settings[key] is bool
                    ? (v) => _toggle(key, v)
                    : null,
              ),
            const SizedBox(height: 6),
            _ReadonlyRow(
              label: _settingLabel(l10n, 'locale'),
              value: _settings['locale'] is String
                  ? _settings['locale'] as String
                  : null,
            ),
          ],
        ),
      },
    );
  }
}

class _SettingToggleRow extends StatelessWidget {
  const _SettingToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.writing,
    this.onChanged,
  });

  final String label;
  final bool? value;
  final bool writing;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BevelCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: value == null ? zt.textLo : zt.textHi,
                ),
              ),
            ),
            if (writing)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Switch(
                value: value ?? false,
                onChanged: onChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _ReadonlyRow extends StatelessWidget {
  const _ReadonlyRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return BevelCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
          ),
          Text(
            value ?? '—',
            style: TextStyle(fontSize: 13, color: zt.textLo),
          ),
        ],
      ),
    );
  }
}

class _HintBody extends StatelessWidget {
  const _HintBody({
    required this.icon,
    required this.message,
    required this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: zt.textTertiary),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: zt.textLo),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}
