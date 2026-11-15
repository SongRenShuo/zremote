import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/git_overview.dart';
import '../theme.dart';
import 'bevel_card.dart';
import 'git_diff_page.dart';

/// Git 只读详情页（P1 修复）：来源分段（未暂存 / 已暂存 / 分支对比）+
/// 分组脏文件列表（路径 / kind / ±行数）+ 全屏只读 diff。
/// 数据源 `gitService.getRepositorySummary` + `getChanges`（staged+unstaged）
/// + `getBranchComparison` + `getLocalBranches`，一次聚合、按源隔离失败；
/// 点文件行 push [GitDiffPage]。全程只读，无任何写操作。
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
  GitChangeSource _source = GitChangeSource.unstaged;

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

  Future<void> _openDiff(GitFileChangeEntry change) async {
    final ws = widget.workspacePath?.trim() ?? '';
    if (ws.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GitDiffPage(
          client: widget.client,
          workspacePath: ws,
          path: change.path,
          sourceId: change.source.id,
        ),
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
          _SourceSelector(
            detail: detail,
            selected: _source,
            onSelect: (source) => setState(() => _source = source),
          ),
          const SizedBox(height: 10),
          ..._sourceSection(context, l10n, zt, detail),
        ],
      ),
    );
  }

  List<Widget> _sourceSection(
    BuildContext context,
    AppLocalizations l10n,
    ZTPalette zt,
    GitDetail detail,
  ) {
    final count = detail.countOf(_source);
    final label = switch (_source) {
      GitChangeSource.unstaged => l10n.gitDetailSourceUnstaged,
      GitChangeSource.staged => l10n.gitDetailSourceStaged,
      GitChangeSource.branch => l10n.gitDetailSourceBranch,
    };
    return [
      _SectionLabel(text: '$label · ${l10n.gitDetailSourceCount(count)}'),
      const SizedBox(height: 6),
      if (_source == GitChangeSource.branch) ...[
        _BranchMeta(detail: detail),
        const SizedBox(height: 6),
      ],
      if (count == 0)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _source == GitChangeSource.branch
                ? l10n.gitDetailComparisonEmpty
                : l10n.gitDetailNoChanges,
            style: TextStyle(fontSize: 12.5, color: zt.textLo),
          ),
        )
      else
        for (final group in _grouped(detail, _source))
          ..._changeSection(context, l10n, zt, group),
    ];
  }

  List<({String group, List<GitFileChangeEntry> items})> _grouped(
    GitDetail detail,
    GitChangeSource source,
  ) {
    final order = switch (source) {
      GitChangeSource.staged => const ['staged'],
      GitChangeSource.branch => const ['branch'],
      GitChangeSource.unstaged => const ['conflicted', 'untracked', 'unstaged'],
    };
    final items = detail.changesOf(source);
    final out = <({String group, List<GitFileChangeEntry> items})>[];
    for (final key in order) {
      final list = items.where((c) => c.group == key).toList();
      if (list.isNotEmpty) out.add((group: key, items: list));
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
              key: Key('git-change-${change.source.id}-${change.sortPath}'),
              onTap: () => _openDiff(change),
              child: Row(
                children: [
                  _Badge(
                    label: _kindLabel(l10n, change.kind),
                    color: zt.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      change.displayPath,
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
    'branch' => l10n.gitDetailSectionBranch,
    _ => l10n.gitDetailSectionUnstaged,
  };

  String _kindLabel(AppLocalizations l10n, GitChangeKind kind) => switch (kind) {
    GitChangeKind.added => l10n.gitDetailKindAdded,
    GitChangeKind.deleted => l10n.gitDetailKindDeleted,
    GitChangeKind.renamed => l10n.gitDetailKindRenamed,
    GitChangeKind.modified => l10n.gitDetailKindModified,
  };
}

/// 来源分段选择：未暂存 / 已暂存 / 分支对比，各段带文件数。
class _SourceSelector extends StatelessWidget {
  const _SourceSelector({
    required this.detail,
    required this.selected,
    required this.onSelect,
  });

  final GitDetail detail;
  final GitChangeSource selected;
  final ValueChanged<GitChangeSource> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = [
      (
        source: GitChangeSource.unstaged,
        label: l10n.gitDetailSourceUnstaged,
        count: detail.countOf(GitChangeSource.unstaged),
      ),
      (
        source: GitChangeSource.staged,
        label: l10n.gitDetailSourceStaged,
        count: detail.countOf(GitChangeSource.staged),
      ),
      (
        source: GitChangeSource.branch,
        label: l10n.gitDetailSourceBranch,
        count: detail.countOf(GitChangeSource.branch),
      ),
    ];
    return Row(
      children: [
        for (final item in items)
          Expanded(
            child: _SourceSegment(
              key: Key('git-source-${item.source.id}'),
              label: item.label,
              count: item.count,
              selected: item.source == selected,
              onTap: () => onSelect(item.source),
            ),
          ),
      ],
    );
  }
}

class _SourceSegment extends StatelessWidget {
  const _SourceSegment({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? zt.accentSubtle : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? zt.accentBorder : zt.hairline,
              width: 0.8,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? zt.accent : zt.textLo,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: selected ? zt.accent : zt.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分支对比元信息：对比标签（固定 upstream...HEAD）/ 无上游 / 拉取失败。
class _BranchMeta extends StatelessWidget {
  const _BranchMeta({required this.detail});

  final GitDetail detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final comparison = detail.comparison;
    final String text;
    if (detail.comparisonFailed) {
      text = l10n.gitDetailComparisonUnavailable;
    } else if (comparison == null || !comparison.hasUpstream) {
      text = l10n.gitDetailComparisonNoUpstream;
    } else {
      text = l10n.gitDetailComparisonLabel(
        comparison.comparisonLabel ?? '${comparison.baseRef}...${comparison.headRef}',
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: zt.hairline, width: 0.8),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: zt.textTertiary),
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
