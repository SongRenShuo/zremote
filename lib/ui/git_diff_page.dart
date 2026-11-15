import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/git_overview.dart';
import '../theme.dart';

/// 全屏只读 diff 页（P1 修复）：unified 视图 + 行号 + 增删行着色 +
/// 按 hunk 折叠/展开。数据来自单文件 `getDiff`（sourceId 区分
/// unstaged/staged/branch），全程只读。
///
/// 大文件降级：ZCode 桌面端在 180k 字符 / 1200 行以上改渲染原始 patch
/// （`GitPane/helpers.ts`）。移动端列表更窄、内存更敏感，这里收紧到
/// 120k 字符 / 1500 行，超过则直接展示 patch 原文，避免逐行建 widget。
/// 不做并排视图（窄屏无意义），也不做 shiki 级语法高亮（成本远高于收益，
/// 关键字高亮会引入按语言分词的开销，移动端先用行级着色）。
class GitDiffPage extends StatefulWidget {
  const GitDiffPage({
    super.key,
    required this.client,
    required this.workspacePath,
    required this.path,
    required this.sourceId,
  });

  final GitOverviewClient client;
  final String workspacePath;
  final String path;
  final String sourceId;

  /// 降级阈值（字符数 / 行数），超过即渲染 patch 原文。
  static const int maxRenderChars = 120000;
  static const int maxRenderLines = 1500;

  @override
  State<GitDiffPage> createState() => _GitDiffPageState();
}

class _GitDiffPageState extends State<GitDiffPage> {
  GitDiffEntry? _diff;
  GitDiffDocument? _doc;
  bool _loading = true;
  final Set<int> _collapsed = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final diff = await widget.client.fetchDiff(
      widget.workspacePath,
      widget.path,
      sourceId: widget.sourceId,
    );
    if (!mounted) return;
    setState(() {
      _diff = diff;
      _doc = diff.hasPatch ? parseGitDiff(diff.patch!) : null;
      _loading = false;
    });
  }

  bool get _allCollapsed {
    final doc = _doc;
    if (doc == null || doc.hunks.isEmpty) return false;
    for (var i = 0; i < doc.hunks.length; i++) {
      if (!_collapsed.contains(i)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final diff = _diff;
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.gitDetailDiffTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            Text(
              widget.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('git-diff-collapse-all'),
            icon: Icon(_allCollapsed ? Icons.unfold_more : Icons.unfold_less),
            tooltip: _allCollapsed
                ? l10n.gitDiffExpandAll
                : l10n.gitDiffCollapseAll,
            onPressed: doc == null || doc.hunks.isEmpty
                ? null
                : () => setState(() {
                    if (_allCollapsed) {
                      _collapsed.clear();
                    } else {
                      _collapsed.addAll(List<int>.generate(doc.hunks.length, (i) => i));
                    }
                  }),
          ),
        ],
      ),
      body: _body(context, l10n, diff, doc),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    GitDiffEntry? diff,
    GitDiffDocument? doc,
  ) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (diff == null || !diff.hasPatch) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            l10n.gitDetailDiffUnavailable,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.zt.textLo),
          ),
        ),
      );
    }
    final patch = diff.patch!;
    final lineCount = patch.split('\n').length;
    if (patch.length > GitDiffPage.maxRenderChars ||
        lineCount > GitDiffPage.maxRenderLines) {
      return _rawPatch(context, l10n, patch, lineCount);
    }
    if (doc == null || doc.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            l10n.gitDetailDiffUnavailable,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.zt.textLo),
          ),
        ),
      );
    }
    return _diffView(context, doc);
  }

  /// 大文件降级：原始 patch 文本（可选中复制），附降级原因。
  Widget _rawPatch(
    BuildContext context,
    AppLocalizations l10n,
    String patch,
    int lineCount,
  ) {
    final zt = context.zt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            l10n.gitDiffTooLarge(lineCount),
            style: TextStyle(fontSize: 11.5, color: zt.warn),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            child: SelectableText(
              patch,
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
    );
  }

  Widget _diffView(BuildContext context, GitDiffDocument doc) {
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in doc.preamble)
                _fileHeaderRow(context, line),
              for (var i = 0; i < doc.hunks.length; i++) ...[
                _hunkHeader(context, i, doc.hunks[i]),
                if (!_collapsed.contains(i))
                  for (final numbered in _numberLines(doc.hunks[i]))
                    _lineRow(context, numbered),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<_NumberedLine> _numberLines(GitDiffHunk hunk) {
    var oldNo = hunk.oldStart;
    var newNo = hunk.newStart;
    final out = <_NumberedLine>[];
    for (final line in hunk.lines) {
      switch (line.type) {
        case GitDiffLineType.context:
          out.add(_NumberedLine(line, oldNo, newNo));
          oldNo++;
          newNo++;
        case GitDiffLineType.added:
          out.add(_NumberedLine(line, null, newNo));
          newNo++;
        case GitDiffLineType.removed:
          out.add(_NumberedLine(line, oldNo, null));
          oldNo++;
        case GitDiffLineType.fileHeader:
        case GitDiffLineType.hunkHeader:
        case GitDiffLineType.note:
          out.add(_NumberedLine(line, null, null));
      }
    }
    return out;
  }

  Widget _fileHeaderRow(BuildContext context, GitDiffLine line) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 1, 8, 1),
      child: Text(
        line.text.isEmpty ? ' ' : line.text,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontSize: 11,
          height: 1.3,
          fontFamily: 'monospace',
          color: zt.textTertiary,
        ),
      ),
    );
  }

  Widget _hunkHeader(BuildContext context, int index, GitDiffHunk hunk) {
    final zt = context.zt;
    final collapsed = _collapsed.contains(index);
    return InkWell(
      key: Key('git-diff-hunk-$index'),
      onTap: () => setState(() {
        if (collapsed) {
          _collapsed.remove(index);
        } else {
          _collapsed.add(index);
        }
      }),
      child: Container(
        color: zt.surfaceHi,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          // 横向滚动区内宽度无界：只能 shrink-wrap，禁用 Expanded。
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 16,
              color: zt.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              hunk.header,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: zt.accent,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '+${hunk.addedCount} −${hunk.removedCount}',
              style: TextStyle(
                fontSize: 10,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: zt.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineRow(BuildContext context, _NumberedLine numbered) {
    final zt = context.zt;
    final line = numbered.line;
    final Color? background;
    final Color foreground;
    switch (line.type) {
      case GitDiffLineType.added:
        background = zt.live.withValues(alpha: 0.14);
        foreground = zt.live;
      case GitDiffLineType.removed:
        background = zt.danger.withValues(alpha: 0.14);
        foreground = zt.danger;
      case GitDiffLineType.hunkHeader:
        background = zt.surfaceHi;
        foreground = zt.textHi;
      case GitDiffLineType.context:
      case GitDiffLineType.fileHeader:
      case GitDiffLineType.note:
        background = null;
        foreground = zt.textHi;
    }
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _gutter(context, numbered.oldNo),
          _gutter(context, numbered.newNo),
          const SizedBox(width: 6),
          Text(
            line.text.isEmpty ? ' ' : line.text,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              fontFamily: 'monospace',
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gutter(BuildContext context, int? number) {
    final zt = context.zt;
    return SizedBox(
      width: 32,
      child: Text(
        number?.toString() ?? '',
        textAlign: TextAlign.right,
        softWrap: false,
        style: TextStyle(
          fontSize: 10,
          height: 1.3,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: zt.textTertiary,
        ),
      ),
    );
  }
}

class _NumberedLine {
  const _NumberedLine(this.line, this.oldNo, this.newNo);

  final GitDiffLine line;
  final int? oldNo;
  final int? newNo;
}
