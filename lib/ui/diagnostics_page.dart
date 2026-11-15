import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/endpoint_probe.dart';
import '../services/quota_client.dart' show QuotaTokenProvider;
import '../services/rpc_bridge.dart';
import '../services/service_probe.dart';
import '../theme.dart';
import 'bevel_card.dart';
import 'section_label.dart';

/// 连接诊断页（P0-1）：一键执行 ServiceProbe，把宿主注册表
/// keys / 缺失候选服务 / 方法检查 / 实调用结果完整呈现，支持复制报告。
/// 这是工具箱四入口排障与修复验收的基础设施。
/// P6-1 扩容：新增「端点健康」段（client/configs 直连探测 +
/// billing/balance 可选带 token 探测），结果并入复制报告。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({
    super.key,
    required this.device,
    required this.bridge,
    this.endpointProbe,
    this.tokenProvider,
  });

  final RemoteDevice device;
  final RpcBridge bridge;

  /// 测试注入用；null 时按 [tokenProvider] 构造 EndpointProbe。
  final EndpointProbe? endpointProbe;

  /// zai JWT 供票（账号库接线位）；null/空票据时 billing/balance 跳过。
  final QuotaTokenProvider? tokenProvider;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool _running = false;
  Map<String, Object?>? _report;
  String? _runError;

  List<EndpointProbeResult>? _endpoints;
  bool _endpointsRunning = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final report = await ServiceProbe.run(widget.bridge);
      if (!mounted) return;
      setState(() => _report = report);
    } catch (e) {
      if (!mounted) return;
      setState(() => _runError = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runEndpoints() async {
    if (_endpointsRunning) return;
    setState(() => _endpointsRunning = true);
    try {
      final probe = widget.endpointProbe ??
          EndpointProbe(tokenProvider: widget.tokenProvider);
      final results = await probe.run();
      if (!mounted) return;
      setState(() => _endpoints = results);
    } catch (e) {
      if (!mounted) return;
      setState(() => _endpoints = [
        EndpointProbeResult(
          label: 'client/configs',
          url: kEndpointClientConfigsUrl,
          error: e.toString(),
        ),
      ]);
    } finally {
      if (mounted) setState(() => _endpointsRunning = false);
    }
  }

  void _copyReport() {
    final report = _report;
    if (report == null) return;
    final text = _reportText(report);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.diagnosticsCopied)),
    );
  }

  String _reportText(Map<String, Object?> report) {
    final buffer = StringBuffer()
      ..writeln('zremote 连接诊断报告')
      ..writeln('时间: ${report['at']}')
      ..writeln('设备: ${report['device']}');
    final dump = report['dump'];
    if (dump is Map<String, Object?>) {
      buffer
        ..writeln('dump ok: ${dump['ok']}')
        ..writeln('dump error: ${dump['error']}');
      final keys = dump['keys'];
      if (keys is List) {
        buffer.writeln('服务注册表(${keys.length}): ${keys.join(', ')}');
      }
      final missing = dump['missing'];
      if (missing is List && missing.isNotEmpty) {
        buffer.writeln('缺失服务: ${missing.join(', ')}');
      }
      final candidateMissing = _missingCandidates(keys);
      if (candidateMissing.isNotEmpty) {
        buffer.writeln('缺失候选(含别名): ${candidateMissing.join(', ')}');
      }
      final checks = dump['checks'];
      if (checks is Map) {
        buffer.writeln('— 方法检查 —');
        for (final entry in checks.entries) {
          buffer.writeln('  ${entry.key} = ${entry.value}');
        }
      }
    }
    final calls = report['liveCalls'];
    if (calls is List) {
      buffer.writeln('— 实调用 —');
      for (final call in calls) {
        if (call is Map) {
          buffer.writeln(
            '  ${call['service']}.${call['method']} '
            'ok=${call['ok']} err=${call['error']}',
          );
        }
      }
    }
    // P6-1：端点探测结果并入复制报告（探测过才落段）。
    final endpoints = _endpoints;
    if (endpoints != null && endpoints.isNotEmpty) {
      buffer
        ..writeln()
        ..write(endpointProbeReportLines(endpoints));
    }
    return buffer.toString();
  }

  List<String> _missingCandidates(dynamic keys) {
    final keySet = {
      if (keys is List) for (final k in keys) if (k is String) k,
    };
    return [
      for (final candidate in ServiceProbe.candidateServices)
        if (!keySet.contains(candidate)) candidate,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final dump = _report?['dump'];
    final keys = dump is Map ? dump['keys'] : null;
    final keyList = [
      if (keys is List) for (final k in keys) if (k is String) k,
    ];
    final missing = _missingCandidates(keys);
    final checks = dump is Map ? dump['checks'] : null;
    final checkEntries = checks is Map ? checks.entries.toList() : null;
    final calls = _report?['liveCalls'];

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.diagnosticsTitle),
        actions: [
          if (_report != null)
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              tooltip: l10n.diagnosticsCopy,
              onPressed: _copyReport,
            ),
          IconButton(
            icon: _running
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.refresh),
            tooltip: l10n.diagnosticsRun,
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_runError != null)
            BevelCard(
              margin: const EdgeInsets.only(bottom: 12),
              child: Text(
                _runError!,
                style: TextStyle(fontSize: 12, color: zt.danger),
              ),
            ),
          if (_report == null && _runError == null && _running)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: CircularProgressIndicator(),
              ),
            ),
          if (_report != null) ...[
            BevelCard(
              margin: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(
                    keyList.isEmpty
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_done_outlined,
                    size: 20,
                    color: keyList.isEmpty ? zt.danger : zt.live,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      keyList.isEmpty
                          ? l10n.diagnosticsNoRegistry
                          : l10n.diagnosticsRegistryCount(keyList.length),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: keyList.isEmpty ? zt.danger : zt.textHi,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (keyList.isNotEmpty) ...[
              SectionLabel(l10n.diagnosticsKeysTitle),
              BevelCard(
                margin: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final key in keyList)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: zt.surfaceHi,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          key,
                          style: zrMono(fontSize: 11, color: zt.textLo),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (missing.isNotEmpty) ...[
              SectionLabel(l10n.diagnosticsMissingTitle),
              BevelCard(
                margin: const EdgeInsets.only(bottom: 12),
                child: Text(
                  missing.join('\n'),
                  style: zrMono(fontSize: 11.5, color: zt.warn),
                ),
              ),
            ],
            if (checkEntries != null && checkEntries.isNotEmpty) ...[
              SectionLabel(l10n.diagnosticsChecksTitle),
              BevelCard(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in checkEntries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              entry.value == true
                                  ? Icons.check_circle_outline
                                  : Icons.remove_circle_outline,
                              size: 14,
                              color: entry.value == true
                                  ? zt.live
                                  : (entry.value == 'no-svc'
                                      ? zt.textTertiary
                                      : zt.warn),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${entry.key}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: zrMono(
                                  fontSize: 11.5,
                                  color: zt.textLo,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${entry.value}',
                              style: zrMono(
                                fontSize: 11,
                                color: entry.value == true
                                    ? zt.live
                                    : zt.warn,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (calls is List && calls.isNotEmpty) ...[
              SectionLabel(l10n.diagnosticsLiveCallsTitle),
              BevelCard(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final call in calls)
                      if (call is Map)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                call['ok'] == true
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                size: 14,
                                color: call['ok'] == true
                                    ? zt.live
                                    : zt.danger,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${call['service']}.${call['method']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: zrMono(
                                    fontSize: 11.5,
                                    color: zt.textLo,
                                  ),
                                ),
                              ),
                              if (call['error'] is String &&
                                  (call['error'] as String).isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    call['error'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: zt.danger,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ],
          // P6-1：端点健康段（不依赖宿主桥，独立可跑）。
          SectionLabel(l10n.diagnosticsEndpointsTitle),
          BevelCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('diagnostics-endpoints-run'),
                    onPressed: _endpointsRunning ? null : _runEndpoints,
                    icon: _endpointsRunning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.travel_explore_outlined, size: 18),
                    label: Text(
                      _endpointsRunning
                          ? l10n.diagnosticsEndpointsRunning
                          : l10n.diagnosticsEndpointsRun,
                    ),
                  ),
                ),
                for (final r in _endpoints ?? const <EndpointProbeResult>[])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          r.skipped
                              ? Icons.remove_circle_outline
                              : (r.ok
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline),
                          size: 14,
                          color: r.skipped
                              ? zt.textTertiary
                              : (r.ok ? zt.live : zt.danger),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            r.skipped
                                ? '${r.label} · ${l10n.diagnosticsEndpointSkipNoToken}'
                                : '${r.label} · ${r.statusCode ?? 'ERR'} · ${r.elapsedMs} ms'
                                    '${r.error != null && r.error!.isNotEmpty ? '\n${r.error}' : ''}',
                            style: zrMono(fontSize: 11.5, color: zt.textLo),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
