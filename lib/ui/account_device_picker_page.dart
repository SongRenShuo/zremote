import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/remote_device_client.dart';
import '../theme.dart';

/// 账号设备选择页（账户直连调研 P1）。
///
/// 只负责「选一台 → 去重判定 → 回调添加」，真正的写库/切会话由宿主
/// （账号库页）注入 [onAdd]：写库走 `deviceListProvider` 既有添加路径。
///
/// 不依赖任何当前设备：0 设备入口（账号库 `device: null`）同样可打开，
/// 系统返回键/关闭按钮走 `Navigator.pop(null)`，宿主按 null 视为取消。
class AccountDevicePickerPage extends StatelessWidget {
  const AccountDevicePickerPage({
    super.key,
    required this.accountName,
    required this.entries,
    this.existingDevices = const [],
    required this.onAdd,
  });

  final String accountName;
  final List<RemoteDeviceEntry> entries;

  /// 已存在设备（去重判定用）；0 设备入口传空表即可。
  final List<RemoteDevice> existingDevices;

  /// 写库回调；返回是否成功。[open] 为「添加并打开会话」。
  final Future<bool> Function(RemoteDevice device, {required bool open}) onAdd;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(
        title: Text(
          l10n.devicesPickerTitle,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: zt.textHi,
          ),
        ),
        centerTitle: false,
        backgroundColor: zt.bg,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: zt.hairline),
        ),
      ),
      body: SafeArea(
        top: false,
        child: entries.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    l10n.devicesPickerEmpty,
                    key: const Key('devices-picker-empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: zt.textLo),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 20),
                itemCount: entries.length + 1,
                itemBuilder: (listContext, i) {
                  if (i == 0) {
                    return _HintCard(text: l10n.devicesPickerHint);
                  }
                  final entry = entries[i - 1];
                  return _DeviceTile(
                    entry: entry,
                    onTap: () => _select(listContext, entry),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _select(BuildContext context, RemoteDeviceEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final dup = findAccountDeviceDuplicate(existingDevices, entry);
    if (dup != null) {
      final switchTo = await _confirmSwitchDuplicate(context, dup);
      if (switchTo != true || !context.mounted) return;
      Navigator.of(context).pop(
        AccountDevicePickerResult(
          deviceId: dup.device.id,
          open: true,
          duplicate: true,
        ),
      );
      return;
    }
    final open = await _confirmAdd(context, entry);
    if (open == null || !context.mounted) return;
    final device = remoteDeviceFromEntry(entry);
    var ok = false;
    try {
      ok = await onAdd(device, open: open);
    } catch (_) {
      ok = false;
    }
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!ok) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.devicesAddFailed)));
      return;
    }
    Navigator.of(context).pop(
      AccountDevicePickerResult(
        deviceId: device.id,
        open: open,
        duplicate: false,
      ),
    );
  }

  /// 返回 true=添加并打开；false=仅添加；null=取消。
  Future<bool?> _confirmAdd(
    BuildContext context,
    RemoteDeviceEntry entry,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.devicesAddConfirmTitle),
        content: Text(l10n.devicesAddConfirmBody(entry.displayName)),
        actions: [
          TextButton(
            key: const Key('devices-add-cancel'),
            onPressed: () => Navigator.pop(dialogContext, null),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('devices-add-only'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.devicesAddOnly),
          ),
          FilledButton(
            key: const Key('devices-add-open'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.devicesAddAndOpen),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmSwitchDuplicate(
    BuildContext context,
    AccountDeviceDuplicate dup,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final reason = switch (dup.kind) {
      AccountDeviceDuplicateKind.sid => l10n.devicesDuplicateReasonSid,
      AccountDeviceDuplicateKind.mid => l10n.devicesDuplicateReasonMid,
      AccountDeviceDuplicateKind.name => l10n.devicesDuplicateReasonName,
    };
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.devicesDuplicateTitle),
        content: Text(
          l10n.devicesDuplicateBody(dup.entry.displayName, reason),
        ),
        actions: [
          TextButton(
            key: const Key('devices-dup-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('devices-dup-switch'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.devicesDuplicateSwitch),
          ),
        ],
      ),
    );
  }
}

/// 选择结果：宿主据此提示 + 决定是否切会话。
@immutable
class AccountDevicePickerResult {
  const AccountDevicePickerResult({
    required this.deviceId,
    required this.open,
    required this.duplicate,
  });

  final String deviceId;

  /// 添加并打开 / 切换到已添加设备。
  final bool open;

  /// true=命中去重（deviceId 为已存在设备）；false=新添加。
  final bool duplicate;
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: zt.accentSubtle.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: zt.accentBorder.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: zt.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, height: 1.5, color: zt.textLo),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.entry, required this.onTap});

  final RemoteDeviceEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final name = entry.name.trim();
    final title = name.isNotEmpty ? name : l10n.devicesUnnamed;
    final platform = _platformLabel(l10n, entry.platform);
    final online = entry.online;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: zt.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: zt.hairline),
        ),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          onTap: onTap,
          leading: _PlatformBadge(platform: entry.platform, online: online),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: zt.textHi,
            ),
          ),
          subtitle: Text(
            _subtitle(l10n, entry, platform, online),
            style: TextStyle(fontSize: 11.5, color: zt.textTertiary),
          ),
          trailing: online
              ? Icon(Icons.chevron_right, size: 20, color: zt.textLo)
              : Text(
                  l10n.devicesOffline,
                  style: TextStyle(fontSize: 11, color: zt.textTertiary),
                ),
        ),
      ),
    );
  }

  String _subtitle(
    AppLocalizations l10n,
    RemoteDeviceEntry entry,
    String platform,
    bool online,
  ) {
    final segments = <String>[
      if (platform.isNotEmpty) platform,
      if (entry.appVersion.isNotEmpty) 'ZCode ${entry.appVersion}',
      online ? l10n.devicesOnline : l10n.devicesOffline,
    ];
    return segments.join(' · ');
  }

  String _platformLabel(AppLocalizations l10n, String platform) => switch (
      platform.toLowerCase()) {
    'darwin' => l10n.devicesPlatformMac,
    'win32' => l10n.devicesPlatformWin,
    'linux' => l10n.devicesPlatformLinux,
    '' => '',
    _ => platform,
  };
}

class _PlatformBadge extends StatelessWidget {
  const _PlatformBadge({required this.platform, required this.online});

  final String platform;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final icon = switch (platform.toLowerCase()) {
      'darwin' => Icons.laptop_mac,
      'win32' => Icons.desktop_windows,
      'linux' => Icons.computer,
      _ => Icons.devices_other,
    };
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: zt.accentSubtle,
            ),
            child: Icon(icon, size: 19, color: zt.accent),
          ),
          if (online)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: zt.live,
                  border: Border.all(color: zt.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
