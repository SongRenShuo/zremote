import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/git_overview.dart';
import '../theme.dart';
import 'git_detail_page.dart';

/// Git 概览卡（P1-7）：分支 / 脏文件数 / ahead-behind，工具箱资产组内嵌。
/// client 为 null（未接线）或未进会话（workspacePath 为空）时置灰提示；
/// 点按刷新。数据经 [GitOverview.fromJson] 形状容错。
class GitCard extends StatefulWidget {
  const GitCard({super.key, this.client, this.workspacePath});

  final GitOverviewClient? client;

  /// 当前会话工作区（session_index 活动会话 workspacePath）。
  final String? workspacePath;

  @override
  State<GitCard> createState() => _GitCardState();
}

class _GitCardState extends State<GitCard> {
  GitOverview? _overview;
  bool _loading = false;
  bool _fetched = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fetched) return;
    _fetched = true;
    _refresh();
  }

  @override
  void didUpdateWidget(covariant GitCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换会话 / workspace 由空变有 → 重新拉取概览。
    if ((oldWidget.workspacePath ?? '') != (widget.workspacePath ?? '')) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _loading = true);
    final overview = await client.fetch(widget.workspacePath);
    if (!mounted) return;
    setState(() {
      _overview = overview;
      _loading = false;
    });
  }

  Future<void> _openDetail() async {
    final client = widget.client;
    if (client == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GitDetailPage(
          client: client,
          workspacePath: widget.workspacePath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final overview = _overview;
    final client = widget.client;
    final enabled = client != null;
    final hasRepo = overview != null && overview.hasRepo;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('git-overview-card'),
        onTap: enabled ? _openDetail : null,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled ? 1.0 : 0.45,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.04)
                  : zt.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : zt.hairline,
                width: 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: enabled
                            ? zt.accentSubtle
                            : Colors.white.withValues(alpha: 0.04),
                      ),
                      child: Icon(
                        Icons.call_split_rounded,
                        size: 18,
                        color: enabled ? zt.accent : zt.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.gitCardTitle,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: enabled ? zt.textHi : zt.textLo,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _subtitle(l10n, overview),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              height: 1.25,
                              color: zt.textLo,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_loading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (hasRepo && overview.isDirty)
                      _GitBadge(
                        label: overview.dirtyCount == null
                            ? l10n.gitCardDirtyUnknown
                            : l10n.gitCardDirty(overview.dirtyCount!),
                        color: zt.warn,
                      )
                    else if (hasRepo)
                      _GitBadge(
                        label: l10n.gitCardClean,
                        color: zt.live,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(AppLocalizations l10n, GitOverview? overview) {
    if (widget.client == null) return l10n.gitCardDesc;
    if (overview == null) return l10n.gitCardDesc;
    // 失败原因可区分：无会话 / 非仓库 / 加载失败 / 正常。
    switch (overview.status) {
      case GitOverviewStatus.noWorkspace:
        return l10n.gitCardNoSession;
      case GitOverviewStatus.loadFailed:
        return l10n.gitCardLoadFailed;
      case GitOverviewStatus.notRepository:
        return l10n.gitCardNoRepo;
      case GitOverviewStatus.ready:
        break;
    }
    if (!overview.hasRepo) {
      return overview.workspacePath == null || overview.workspacePath!.isEmpty
          ? l10n.gitCardNoSession
          : l10n.gitCardNoRepo;
    }
    final parts = <String>[
      l10n.gitCardBranch(overview.branch ?? ''),
      if (overview.ahead > 0 || overview.behind > 0)
        l10n.gitCardAheadBehind(overview.ahead, overview.behind),
    ];
    return parts.join(' · ');
  }
}

class _GitBadge extends StatelessWidget {
  const _GitBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
