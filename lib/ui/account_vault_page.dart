import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/account_vault.dart';
import '../services/zai_auth_client.dart';
import '../state/accounts.dart';
import '../theme.dart';

/// 账号库页面（P0-5/P0-6/P0-8）。
///
/// WebView 依赖经回调注入：`onCaptureCurrent` 回读当前设备 localStorage，
/// `onApply` 注入并刷新（由会话页提供 controller 通道）。
class AccountVaultPage extends ConsumerStatefulWidget {
  const AccountVaultPage({
    super.key,
    required this.device,
    required this.onCaptureCurrent,
    required this.onApply,
    this.client,
    this.exportSink,
    this.importSource,
  });

  final RemoteDevice device;

  /// 回读当前设备登录键值（防丢号保全与「保存当前登录」共用）。
  final Future<Map<String, String>> Function() onCaptureCurrent;

  /// 注入账号到设备 WebView 并 reload；返回是否成功。
  final Future<bool> Function(Account account) onApply;

  /// 账号资料拉取客户端（测试注入）。
  final ZaiAuthClient? client;

  /// .zsb 导出出口（默认写临时文件并调系统分享；测试录音替身）。
  final Future<void> Function(Uint8List bytes, String fileName)? exportSink;

  /// .zsb 导入入口（默认 file_picker 选文件；测试替身）。
  final Future<Uint8List?> Function()? importSource;

  @override
  ConsumerState<AccountVaultPage> createState() => _AccountVaultPageState();
}

class _AccountVaultPageState extends ConsumerState<AccountVaultPage> {
  bool _busy = false;

  ZaiAuthClient get _client => widget.client ?? ZaiAuthClient();

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveCurrent() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final entries = await widget.onCaptureCurrent();
      if (!mounted) return;
      if (entries['zcodejwttoken'] == null ||
          (entries['zcodejwttoken'] ?? '').isEmpty) {
        _toast(l10n.acctNothingToSave);
        return;
      }
      final account = await ref
          .read(accountsProvider.notifier)
          .preserveRawEntries(entries);
      if (!mounted) return;
      _toast(account == null ? l10n.acctNothingToSave : l10n.acctSavedToast);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyAccount(Account account) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.acctApplyConfirmTitle),
        content: Text(l10n.acctApplyConfirmBody(account.name)),
        actions: [
          TextButton(
            key: const Key('acct-apply-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('acct-apply-ok'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.acctApply),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      // 防丢号：应用前先保全当前登录。
      final entries = await widget.onCaptureCurrent();
      await ref.read(accountsProvider.notifier).preserveRawEntries(entries);
      await ref
          .read(accountsProvider.notifier)
          .setActiveForDevice(widget.device, account.id);
      final applied = await widget.onApply(account);
      if (!mounted) return;
      _toast(applied ? l10n.acctApplyDone : l10n.acctApplyFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount(Account account) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.acctDeleteConfirmTitle),
        content: Text(l10n.acctDeleteConfirmBody(account.name)),
        actions: [
          TextButton(
            key: const Key('acct-delete-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('acct-delete-ok'),
            style: FilledButton.styleFrom(
              backgroundColor: context.zt.danger,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.acctDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(accountsProvider.notifier).remove(account.id);
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    final accounts = ref.read(accountsProvider).accounts;
    final password = await _askPassword(l10n.acctExportPwdTitle);
    if (password == null || !mounted) return;
    try {
      final bytes = await ref
          .read(accountsProvider.notifier)
          .exportBundle(password, accounts);
      final sink = widget.exportSink ?? _shareExport;
      await sink(bytes, 'zremote-accounts.zsb');
    } on ZsbFormatException {
      if (!mounted) return;
      _toast(l10n.acctPwdTooShort);
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  /// 默认导出出口：临时目录落文件后走系统分享面板。
  Future<void> _shareExport(Uint8List bytes, String fileName) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}$fileName',
    );
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)]),
    );
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context)!;
    final source = widget.importSource ?? _pickImportFile;
    final bytes = await source();
    if (bytes == null || !mounted) return;
    final password = await _askPassword(l10n.acctImportPwdTitle);
    if (password == null || !mounted) return;
    try {
      final report = await ref
          .read(accountsProvider.notifier)
          .importBundle(bytes, password);
      if (!mounted) return;
      _toast(l10n.acctImportReport(report.added.length, report.skipped.length));
    } on ZsbFormatException catch (e) {
      if (!mounted) return;
      _toast(e.wrongPassword ? l10n.acctImportWrongPwd : l10n.acctImportBadFile);
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  Future<String?> _askPassword(String title) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(title),
            content: TextField(
              key: const Key('acct-pwd-field'),
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.acctPwdHint,
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                key: const Key('acct-pwd-cancel'),
                onPressed: () => Navigator.pop(dialogContext, null),
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                key: const Key('acct-pwd-ok'),
                onPressed: () {
                  if (controller.text.length < 6) {
                    setDialogState(() => error = l10n.acctPwdTooShort);
                    return;
                  }
                  Navigator.pop(dialogContext, controller.text);
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 默认导入入口：系统文件选择器取单文件。
  Future<Uint8List?> _pickImportFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zsb'],
    );
    if (picked == null) return null;
    final path = picked.path;
    if (path != null) return File(path).readAsBytes();
    return picked.readAsBytes();
  }

  Future<void> _showDetail(Account account) async {
    final l10n = AppLocalizations.of(context)!;
    var profile = <String, String>{};
    var profileFailed = false;
    final jwt = account.jwt;
    if (jwt != null && jwt.isNotEmpty) {
      try {
        final p = await _client.fetchProfile(jwt);
        profile = {
          'email': p.email,
          'name': p.name,
        };
      } catch (_) {
        profileFailed = true;
      }
    }
    if (!mounted) return;
    final fallbackName = _fallbackIdentity(account);
    final zt = context.zt;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: zt.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.acctDetailTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: zt.textHi,
                ),
              ),
              const SizedBox(height: 12),
              _DetailRow(
                label: l10n.acctDetailName,
                value: (profile['name']?.isNotEmpty ?? false)
                    ? profile['name']!
                    : fallbackName,
              ),
              _DetailRow(
                label: l10n.acctDetailEmail,
                value: (profile['email']?.isNotEmpty ?? false)
                    ? profile['email']!
                    : l10n.acctUnknown,
              ),
              _DetailRow(
                label: l10n.acctDetailProvider,
                value: _providerLabel(l10n, account.provider),
              ),
              _DetailRow(
                label: l10n.acctDetailAdded,
                value: _formatDate(account.createdAt),
              ),
              _DetailRow(
                label: l10n.acctDetailExpires,
                value: account.jwtExpAtMs == null
                    ? l10n.acctUnknown
                    : _formatDate(
                        DateTime.fromMillisecondsSinceEpoch(
                          account.jwtExpAtMs!,
                        ),
                      ),
              ),
              if (profileFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.acctProfileFailed,
                    key: const Key('acct-profile-failed'),
                    style: TextStyle(fontSize: 12, color: zt.warn),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _providerLabel(AppLocalizations l10n, String provider) => switch (
      ZaiAuthProvider.tryFromWire(provider)) {
    ZaiAuthProvider.zaiCn => l10n.loginProviderZaiCn,
    ZaiAuthProvider.zai => l10n.loginProviderZai,
    ZaiAuthProvider.bigmodel => l10n.loginProviderBigmodel,
    _ => provider,
  };

  String _fallbackIdentity(Account account) {
    final identity = AccountIdentity.of(account);
    if (identity.username.isNotEmpty) return identity.username;
    if (identity.email.isNotEmpty) return identity.email;
    return account.name;
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(accountsProvider);
    final activeId = state.activeByDevice[widget.device.id];
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(
        title: Text(
          l10n.acctVaultTitle,
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
        child: state.accounts.isEmpty
            ? Center(
                child: Text(
                  l10n.acctEmpty,
                  key: const Key('acct-empty'),
                  style: TextStyle(fontSize: 13, color: zt.textLo),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(top: 6, bottom: 12),
                itemCount: state.accounts.length,
                itemBuilder: (listContext, i) {
                  final account = state.accounts[i];
                  final isActive = account.id == activeId;
                  return _AccountTile(
                    account: account,
                    isActive: isActive,
                    providerLabel: _providerLabel(l10n, account.provider),
                    fallbackName: _fallbackIdentity(account),
                    busy: _busy,
                    onTap: () => unawaited(_showDetail(account)),
                    onApply: () => unawaited(_applyAccount(account)),
                    onDelete: () => unawaited(_deleteAccount(account)),
                  );
                },
              ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('acct-save-current'),
                  onPressed: _busy ? null : () => unawaited(_saveCurrent()),
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(l10n.acctSaveCurrent),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      key: const Key('acct-export'),
                      onPressed: () => unawaited(_export()),
                      icon: const Icon(Icons.file_upload_outlined, size: 18),
                      label: Text(l10n.acctExport),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      key: const Key('acct-import'),
                      onPressed: () => unawaited(_import()),
                      icon: const Icon(Icons.file_download_outlined, size: 18),
                      label: Text(l10n.acctImport),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: zt.textLo),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isActive,
    required this.providerLabel,
    required this.fallbackName,
    required this.busy,
    required this.onTap,
    required this.onApply,
    required this.onDelete,
  });

  final Account account;
  final bool isActive;
  final String providerLabel;
  final String fallbackName;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onApply;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    final displayName = account.name.isNotEmpty ? account.name : fallbackName;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? zt.accentSubtle : zt.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? zt.accentBorder : zt.hairline,
          ),
        ),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          onTap: onTap,
          leading: _Avatar(text: displayName),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: zt.textHi,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                providerLabel,
                style: TextStyle(fontSize: 11, color: zt.textLo),
              ),
              if (account.needsRelogin) ...[
                const SizedBox(width: 6),
                _Badge(
                  key: const Key('acct-badge-relogin'),
                  text: l10n.acctNeedsRelogin,
                  color: zt.warn,
                ),
              ],
              if (isActive) ...[
                const SizedBox(width: 6),
                _Badge(
                  key: const Key('acct-badge-active'),
                  text: l10n.acctActiveBadge,
                  color: zt.accent,
                ),
              ],
            ],
          ),
          subtitle: account.jwtExpAtMs == null
              ? null
              : Text(
                _expiresText(context, account),
                style: TextStyle(fontSize: 11.5, color: zt.textTertiary),
              ),
          trailing: PopupMenuButton<String>(
            key: Key('acct-menu-${account.id}'),
            enabled: !busy,
            onSelected: (action) {
              if (action == 'apply') onApply();
              if (action == 'delete') onDelete();
            },
            itemBuilder: (menuContext) => [
              PopupMenuItem(
                key: const Key('acct-menu-apply'),
                value: 'apply',
                child: Text(l10n.acctApply),
              ),
              PopupMenuItem(
                key: const Key('acct-menu-delete'),
                value: 'delete',
                child: Text(l10n.acctDelete),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _expiresText(BuildContext context, Account account) {
    final l10n = AppLocalizations.of(context)!;
    final d = DateTime.fromMillisecondsSinceEpoch(account.jwtExpAtMs!);
    final ymd =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${l10n.acctDetailExpires}: $ymd';
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final trimmed = text.trim();
    final ch = trimmed.isEmpty ? '?' : trimmed.substring(0, 1);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: zt.accentSubtle,
        shape: BoxShape.circle,
        border: Border.all(color: zt.accentBorder),
      ),
      child: Text(
        ch.toUpperCase(),
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: zt.accent,
        ),
      ),
    );
  }
}
