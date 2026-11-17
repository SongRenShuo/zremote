import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/log_buffer.dart';
import '../services/webview_profile.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'haptics.dart';
import 'section_label.dart';

/// 每设备 WebView 数据清除（P3-2）：Cookie 按域删除 + 缓存走该设备
/// profile 绑定的 headless WebView clearCache。
///
/// 平台限制如实告知：插件的 CookieManager 在 Android 上操作默认 profile
/// 的 cookie 存储，v2 隔离 profile 的 cookie 可能残留（页面文案提示重新
/// 登录即可重建）。
class WebViewDataCleaner {
  const WebViewDataCleaner();

  Future<void> clearForDevice(RemoteDevice device) async {
    // 1) Cookie：按设备 baseUrl 的域范围删除。
    try {
      await CookieManager.instance()
          .deleteCookies(url: WebUri(device.baseUrl));
    } catch (_) {}
    // 2) 缓存：headless WebView 绑定该设备 profile 后 clearCache。
    final done = Completer<void>();
    late final HeadlessInAppWebView headless;
    Future<void> finish(InAppWebViewController controller) async {
      try {
        // per-controller 作用域；clearAllCache 是全局清（不符合分设备语义）。
        // ignore: deprecated_member_use
        await controller.clearCache();
      } catch (_) {}
      try {
        await headless.dispose();
      } catch (_) {}
      if (!done.isCompleted) done.complete();
    }

    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(
        androidWebProfile: webProfileNameFor(device),
      ),
      onLoadStop: (controller, _) => finish(controller),
      onReceivedError: (controller, _, _) => finish(controller),
    );
    try {
      await headless.run();
      await done.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      try {
        await headless.dispose();
      } catch (_) {}
    }
  }
}

/// 数据管理页（P3-2）：分设备 WebView 数据清除 / 诊断日志导出 /
/// .zsb 账号包分组（入口由账号保险库页面承接，本页只留说明）。
class DataManagePage extends ConsumerStatefulWidget {
  const DataManagePage({super.key, this.cleaner = const WebViewDataCleaner()});

  /// 测试注入位（widget 测试替换为假实现断言调用）。
  final WebViewDataCleaner cleaner;

  @override
  ConsumerState<DataManagePage> createState() => _DataManagePageState();
}

class _DataManagePageState extends ConsumerState<DataManagePage> {
  final Set<String> _busy = {};

  Future<void> _clearDevice(RemoteDevice device) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('data-manage-clear-confirm'),
        title: Text(l10n.dataManageClearConfirmTitle),
        content: Text(
          l10n.dataManageClearConfirmBody(device.displayName(l10n)),
        ),
        actions: [
          TextButton(
            key: const Key('data-manage-clear-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('data-manage-clear-ok'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.dataManageClearAction),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    ZrHaptics.warn();
    setState(() => _busy.add(device.id));
    try {
      await widget.cleaner.clearForDevice(device);
      if (mounted) {
        ZrHaptics.success();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.dataManageClearDone)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.dataManageClearFailed)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(device.id));
      }
    }
  }

  Future<void> _exportLog() async {
    final l10n = AppLocalizations.of(context)!;
    final buffer = LogBuffer.instance;
    if (buffer.length == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.dataManageLogEmpty)));
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final file =
          '${dir.path}/zremote-log-${stamp.year}${two(stamp.month)}${two(stamp.day)}-${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}.txt';
      final text = buffer.dump();
      await File(file).writeAsString(text, flush: true);
      ZrHaptics.success();
      await SharePlus.instance.share(ShareParams(files: [XFile(file)]));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.dataManageExportFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceListProvider);
    final l10n = AppLocalizations.of(context)!;
    final logCount = LogBuffer.instance.length;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.zt.textLo),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Text(
          l10n.dataManageTitle,
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
            SectionLabel(l10n.dataManageWebviewSection),
            if (devices.isEmpty)
              _InfoCard(text: l10n.dataManageNoDevice)
            else
              for (final d in devices)
                _DeviceClearTile(
                  key: Key('data-manage-clear-${d.id}'),
                  device: d,
                  busy: _busy.contains(d.id),
                  onClear: () => _clearDevice(d),
                ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
              child: Text(
                l10n.dataManageWebviewNote,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: context.zt.textTertiary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SectionLabel(l10n.dataManageLogSection),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 18, color: context.zt.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.dataManageLogSub,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.dataManageLogCount(logCount),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: context.zt.textTertiary,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        key: const Key('data-manage-log-export'),
                        onPressed: _exportLog,
                        icon: const Icon(Icons.ios_share_rounded, size: 16),
                        label: Text(l10n.dataManageLogExport),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionLabel(l10n.dataManageZsbSection),
            _InfoCard(text: l10n.dataManageZsbSub),
          ],
        ),
      ),
    );
  }
}

class _DeviceClearTile extends StatelessWidget {
  const _DeviceClearTile({
    super.key,
    required this.device,
    required this.busy,
    required this.onClear,
  });

  final RemoteDevice device;
  final bool busy;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _Card(
      child: Row(
        children: [
          Icon(Icons.desktop_windows, size: 18, color: context.zt.textLo),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              device.displayName(l10n),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: context.zt.textHi,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if ((device.params['app_version'] ?? '').isNotEmpty) ...[
            Text(
              "v${device.params['app_version']}",
              style: TextStyle(fontSize: 10.5, color: context.zt.textLo),
            ),
            const SizedBox(width: 8),
          ],
          busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: onClear,
                  child: Text(l10n.dataManageClearAction),
                ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.zt.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.zt.hairline),
      ),
      child: child,
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.5,
          color: context.zt.textLo,
        ),
      ),
    );
  }
}
