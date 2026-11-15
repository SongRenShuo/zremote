import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/assets_client.dart';
import '../services/rpc_bridge.dart';
import '../state/active_session.dart';
import '../state/session_index.dart';
import '../theme.dart';
import 'bevel_card.dart';

/// 资产只读浏览（开发计划 20261115-0901 P1-8）：
/// Skills / Commands / Subagents / MCP / Hooks / Memory 六 Tab；
/// 每频道独立候选独立拉取，单服务失败只红本 Tab（P1 教训：不拖垮整页）。
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key, required this.device, required this.bridge});

  final RemoteDevice device;
  final RpcBridge bridge;

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends ConsumerState<AssetsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: AssetsTabKind.values.length,
    vsync: this,
  );

  /// 当前会话 workspacePath（skills/commands/subagents/mcp/hooks 需要）。
  String? _workspacePath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_workspacePath != null) return;
    final sessions = ref.read(sessionIndexProvider)[widget.device.id];
    final activeId = ref.read(activeSessionProvider)[widget.device.id];
    _workspacePath = sessions?[activeId]?.workspacePath ??
        sessions?.values
            .map((s) => s.workspacePath)
            .nonNulls
            .firstOrNull;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _tabLabel(AppLocalizations l10n, AssetsTabKind tab) => switch (tab) {
    AssetsTabKind.skills => l10n.assetsTabSkills,
    AssetsTabKind.commands => l10n.assetsTabCommands,
    AssetsTabKind.subagents => l10n.assetsTabSubagents,
    AssetsTabKind.mcp => l10n.assetsTabMcp,
    AssetsTabKind.hooks => l10n.assetsTabHooks,
    AssetsTabKind.memory => l10n.assetsTabMemory,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(
          l10n.assetsTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final tab in AssetsTabKind.values)
              Tab(text: _tabLabel(l10n, tab)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          for (final tab in AssetsTabKind.values)
            _AssetsTabView(
              key: Key('assets-tab-${tab.name}'),
              tab: tab,
              client: AssetsClient(widget.bridge),
              workspacePath: _workspacePath,
              tabLabel: _tabLabel(l10n, tab),
            ),
        ],
      ),
    );
  }
}

enum _TabPhase { loading, ready, unavailable }

class _AssetsTabView extends StatefulWidget {
  const _AssetsTabView({
    super.key,
    required this.tab,
    required this.client,
    required this.workspacePath,
    required this.tabLabel,
  });

  final AssetsTabKind tab;
  final AssetsClient client;
  final String? workspacePath;
  final String tabLabel;

  @override
  State<_AssetsTabView> createState() => _AssetsTabViewState();
}

class _AssetsTabViewState extends State<_AssetsTabView>
    with AutomaticKeepAliveClientMixin {
  _TabPhase _phase = _TabPhase.loading;
  String _error = '';
  AssetsTabResult _result = const AssetsTabResult(entries: [], degraded: false);
  bool _fetchStarted = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fetchStarted) return;
    _fetchStarted = true;
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _phase = _TabPhase.loading);
    try {
      final result = await widget.client.fetchTab(
        widget.tab,
        workspacePath: widget.workspacePath,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _TabPhase.ready;
      });
    } on AssetsFetchException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _phase = _TabPhase.unavailable;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _phase = _TabPhase.unavailable;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    if (_phase == _TabPhase.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_phase == _TabPhase.unavailable) {
      // 单服务失败隔离：只红本 Tab，其余 Tab 不受影响。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 36, color: zt.textTertiary),
            const SizedBox(height: 10),
            Text(
              l10n.assetsTabUnavailable(widget.tabLabel),
              style: TextStyle(fontSize: 13, color: zt.textLo),
            ),
            const SizedBox(height: 4),
            Text(
              _error,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: zt.textTertiary),
            ),
            TextButton(
              key: Key('assets-tab-retry-${widget.tab.name}'),
              onPressed: _refresh,
              child: Text(l10n.rewardsRetry),
            ),
          ],
        ),
      );
    }
    final entries = _result.entries;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: entries.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 80),
                Text(
                  _result.degraded
                      ? l10n.assetsTabDegraded
                      : l10n.assetsTabEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: zt.textLo),
                ),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _AssetRow(entry: entry);
              },
            ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.entry});

  final AssetEntry entry;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final badge = entry.badge;
    final enabled = entry.enabled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BevelCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: zt.textHi,
                    ),
                  ),
                  if (entry.description != null &&
                      entry.description!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      entry.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        color: zt.textLo,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (badge != null && badge.isNotEmpty) ...[
              const SizedBox(width: 8),
              _BadgeChip(label: badge, color: zt.accent),
            ],
            if (enabled != null) ...[
              const SizedBox(width: 6),
              _BadgeChip(
                label: enabled ? 'ON' : 'OFF',
                color: enabled ? zt.live : zt.textTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
