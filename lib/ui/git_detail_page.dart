import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/git_overview.dart';
import '../theme.dart';
import 'bevel_card.dart';

/// Git 只读详情页（P1-7 修复）：分支 / ahead-behind / 脏文件列表。
/// 数据源 `gitService.getRepositorySummary` + `getChanges`（staged+unstaged）
/// + `getLocalBranches`；点文件行按需 `getDiff` 展示只读补丁。
/// 全程只读，无任何写操作（stage/commit/push 一律不暴露）。
class GitDetailPage extends StatefulWidget {
  const GitDetailPage({
    super.key,
    required this.client,
    this.workspacePath,
  });

  final GitOverviewClient client;
  final String? workspacePath;

  @override
  State<GitDetailPage> createState() => _GitDetailPageState();
}

class _GitDetailPageState extends State<GitDetailPage> {
  GitDetail? _detail;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final detail = await widget.client.fetchDetail(widget.workspacePath);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _loading = false;
    });
  }

  Future<void> _showDiff(GitFileChangeEntry change) async {
    final l10n = AppLocalizations.of(context)!;
    final ws = widget.workspacePath?.trim() ?? '';
    if (ws.isEmpty) return;
    final source = change.isStaged ? 'staged' : 'unstaged';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _DiffSheet(
        client: widget.client,
        workspacePath: ws,
        change: change,
        sourceId: source,
        title: l10n.gitDetailDiffTitle,
        unavailable: l10n.gitDetailDiffUnavailable,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(
          l10n.gitDetailTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            key: const Key('git-detail-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: l10n.gitDetailTitle,
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _body(context, l10n, detail),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    GitDetail? detail,
  ) {
    if (_loading && detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (detail.status) {
      case GitOverviewStatus.noWorkspace:
        return _Placeholder(
          icon: Icons.account_circle_outlined,
          message: l10n.gitDetailNoWorkspace,
        );
      case GitOverviewStatus.loadFailed:
        return _Placeholder(
          icon: Icons.cloud_off_outlined,
          message: l10n.gitDetailLoadFailed(detail.errorMessage ?? ''),
          retry: l10n.rewardsRetry,
          onRetry: _refresh,
          retryKey: const Key('git-detail-retry'),
        );
      case GitOverviewStatus.notRepository:
        return _Placeholder(
          icon: Icons.call_split_rounded,
          message: l10n.gitDetailNotRepo,
        );
      case GitOverviewStatus.ready:
        return _content(context, l10n, detail);
    }
  }

  Widget _content(
    BuildContext context,
    AppLocalizations l10n,
    GitDetail detail,
  ) {
    final zt = context.zt;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          BevelCard(
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.call_split_rounded,
                      size: 16,
                      color: zt.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.gitCardBranch(detail.branch ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: zt.textHi,
                        ),
                      ),
                    ),
                    if (detail.dirtyCount > 0)
                      _Badge(
                        label: l10n.gitDetailDirtyCount(detail.dirtyCount),
                        color: zt.warn,
                      )
                    else
                      _Badge(label: l10n.gitDetailClean, color: zt.live),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.gitCardAheadBehind(detail.ahead, detail.behind),
                  style: TextStyle(fontSize: 12, color: zt.textLo),
                ),
                if (detail.repoRoot != null &&
                    detail.repoRoot!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail.repoRoot!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: zt.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (detail.branches.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SectionLabel(text: l10n.gitDetailBranches),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final b in detail.branches)
                  _BranchChip(
                    name: b.name,
                    isCurrent: b.isCurrent,
                    upstream: b.upstreamName,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          _SectionLabel(
            text:
                detail.changes.isEmpty
                    ? l10n.gitDetailNoChanges
                    : l10n.gitDetailDirtyCount(detail.dirtyCount),
          ),
          const SizedBox(height: 6),
          if (detail.changes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                l10n.gitDetailNoChanges,
                style: TextStyle(fontSize: 12.5, color: zt.textLo),
              ),
            )
          else
            for (final group in _grouped(detail.changes))
              ..._changeSection(context, l10n, zt, group),
        ],
      ),
    );
  }

  List<({String group, List<GitFileChangeEntry> items})> _grouped(
    List<GitFileChangeEntry> changes,
  ) {
    const order = ['conflicted', 'staged', 'untracked', 'unstaged'];
    final out = <({String group, List<GitFileChangeEntry> items})>[];
    for (final key in order) {
      final items = changes.where((c) => c.group == key).toList();
      if (items.isNotEmpty) out.add((group: key, items: items));
    }
    return out;
  }

  List<Widget> _changeSection(
    BuildContext context,
    AppLocalizations l10n,
    ZTPalette zt,
    ({String group, List<GitFileChangeEntry> items}) section,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Text(
          _sectionLabel(l10n, section.group),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: zt.textTertiary,
          ),
        ),
      ),
      for (final change in section.items)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: BevelCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: InkWell(
              onTap: () => _showDiff(change),
              child: Row(
                children: [
                  _Badge(
                    label: _kindLabel(l10n, change.kind),
                    color: zt.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      change.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: zt.textHi,
                      ),
                    ),
                  ),
                  if (change.added > 0 || change.removed > 0)
                    Text(
                      l10n.gitDetailLineStats(change.added, change.removed),
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: zt.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  String _sectionLabel(AppLocalizations l10n, String group) => switch (group) {
    'staged' => l10n.gitDetailSectionStaged,
    'untracked' => l10n.gitDetailSectionUntracked,
    'conflicted' => l10n.gitDetailSectionConflicted,
    _ => l10n.gitDetailSectionUnstaged,
  };

  String _kindLabel(AppLocalizations l10n, String kind) => switch (kind) {
    'added' => l10n.gitDetailKindAdded,
    'deleted' => l10n.gitDetailKindDeleted,
    'renamed' => l10n.gitDetailKindRenamed,
    _ => l10n.gitDetailKindModified,
  };
}

class _DiffSheet extends StatefulWidget {
  const _DiffSheet({
    required this.client,
    required this.workspacePath,
    required this.change,
    required this.sourceId,
    required this.title,
    required this.unavailable,
  });

  final GitOverviewClient client;
  final String workspacePath;
  final GitFileChangeEntry change;
  final String sourceId;
  final String title;
  final String unavailable;

  @override
  State<_DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends State<_DiffSheet> {
  GitDiffEntry? _diff;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final diff = await widget.client.fetchDiff(
      widget.workspacePath,
      widget.change.path,
      sourceId: widget.sourceId,
    );
    if (!mounted) return;
    setState(() {
      _diff = diff;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final diff = _diff;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: zt.textHi,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.change.path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: zt.textLo),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (diff == null || !diff.hasPatch)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  widget.unavailable,
                  style: TextStyle(fontSize: 12, color: zt.textLo),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: SelectableText(
                    diff.patch!,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      fontFamily: 'monospace',
                      color: zt.textHi,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.message,
    this.retry,
    this.onRetry,
    this.retryKey,
  });

  final IconData icon;
  final String message;
  final String? retry;
  final VoidCallback? onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: zt.textTertiary),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: zt.textLo),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            TextButton(
              key: retryKey,
              onPressed: onRetry,
              child: Text(retry!),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: context.zt.textTertiary,
      ),
    );
  }
}

class _BranchChip extends StatelessWidget {
  const _BranchChip({
    required this.name,
    required this.isCurrent,
    this.upstream,
  });

  final String name;
  final bool isCurrent;
  final String? upstream;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: isCurrent ? zt.accentSubtle : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: isCurrent ? zt.accentBorder : zt.hairline,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: isCurrent ? zt.accent : zt.textLo,
            ),
          ),
          if (isCurrent) ...[
            const SizedBox(width: 5),
            Text(
              l10n.gitDetailCurrent,
              style: TextStyle(fontSize: 9.5, color: zt.accent),
            ),
          ],
          if (upstream != null && upstream!.isNotEmpty) ...[
            const SizedBox(width: 5),
            Text(
              '↑$upstream',
              style: TextStyle(fontSize: 9.5, color: zt.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

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
