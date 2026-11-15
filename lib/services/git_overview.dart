import 'package:flutter/foundation.dart';

import 'rpc_bridge.dart';

/// Git 概览（开发计划 20261115-0901 P1-7）：
/// `git` 频道 `gitService.getRepositorySummary({workspacePath})`。
///
/// 形状容错（S2，开源版 GitRepositorySummary 为权威形状）：
/// 分支别名 branchName|branch|currentBranch；脏文件数
/// dirtyCount|dirtyFiles.length|changes.length，全缺时回落 isDirty 布尔
/// （count 未知显示为「有改动」）；ahead/behind 数值别名不敏感。
/// Git 概览/详情的失败原因（可区分，不再一律静默 unavailable）。
enum GitOverviewStatus { ready, noWorkspace, notRepository, loadFailed }

class GitOverview {
  const GitOverview({
    required this.workspacePath,
    this.branch,
    this.dirtyCount,
    this.isDirty = false,
    this.ahead = 0,
    this.behind = 0,
    this.isRepository = true,
    this.isGitAvailable = true,
    this.repoRoot,
    this.status = GitOverviewStatus.ready,
    this.errorMessage,
  });

  /// 宿主未进会话（无 workspacePath）时的占位。
  const GitOverview.unavailable(this.workspacePath)
    : branch = null,
      dirtyCount = null,
      isDirty = false,
      ahead = 0,
      behind = 0,
      isRepository = false,
      isGitAvailable = true,
      repoRoot = null,
      status = GitOverviewStatus.noWorkspace,
      errorMessage = null;

  /// 拉取失败（RPC 异常/超时）：保留可区分原因与可读文案。
  const GitOverview.loadFailed(this.workspacePath, this.errorMessage)
    : branch = null,
      dirtyCount = null,
      isDirty = false,
      ahead = 0,
      behind = 0,
      isRepository = false,
      isGitAvailable = true,
      repoRoot = null,
      status = GitOverviewStatus.loadFailed;

  final String? workspacePath;
  final String? branch;
  final int? dirtyCount;
  final bool isDirty;
  final int ahead;
  final int behind;
  final bool isRepository;
  final bool isGitAvailable;
  final String? repoRoot;
  final GitOverviewStatus status;
  final String? errorMessage;

  bool get hasRepo => isRepository && isGitAvailable && branch != null;

  static GitOverview fromJson(Map<String, dynamic> j, String? workspacePath) {
    String? branch;
    for (final key in const ['branchName', 'branch', 'currentBranch']) {
      final v = j[key];
      if (v is String && v.isNotEmpty) {
        branch = v;
        break;
      }
    }
    int? dirtyCount;
    for (final key in const ['dirtyCount', 'dirty_count']) {
      final v = j[key];
      if (v is num) {
        dirtyCount = v.toInt();
        break;
      }
    }
    final dirtyFiles = j['dirtyFiles'];
    if (dirtyCount == null && dirtyFiles is List) {
      dirtyCount = dirtyFiles.length;
    }
    final changes = j['changes'];
    if (dirtyCount == null && changes is List) {
      dirtyCount = changes.length;
    }
    final isRepo =
        j['isRepository'] is bool ? j['isRepository'] as bool : branch != null;
    return GitOverview(
      workspacePath: workspacePath,
      branch: branch,
      dirtyCount: dirtyCount,
      isDirty: j['isDirty'] == true || (dirtyCount ?? 0) > 0,
      ahead: _intOf(j['ahead']),
      behind: _intOf(j['behind']),
      isRepository: isRepo,
      isGitAvailable: j['isGitAvailable'] is bool
          ? j['isGitAvailable'] as bool
          : true,
      repoRoot: j['repoRoot'] is String ? j['repoRoot'] as String? : null,
      status:
          isRepo && branch != null
              ? GitOverviewStatus.ready
              : GitOverviewStatus.notRepository,
    );
  }

  static int _intOf(Object? v) => v is num ? v.toInt() : 0;
}

int _asInt(Object? v) => v is num ? v.toInt() : 0;

/// 变更来源（对齐宿主 `GitChangeSourceId` 的可渲染子集）。
/// `last-turn` 不在本期范围（无宿主契约的稳定取数入口）。
enum GitChangeSource {
  unstaged('unstaged'),
  staged('staged'),
  branch('branch');

  const GitChangeSource(this.id);

  /// 宿主 `getChanges.sourceId` / `getDiff.sourceId` 取值。
  final String id;

  static GitChangeSource parse(Object? v) => switch ('$v') {
    'staged' => GitChangeSource.staged,
    'branch' => GitChangeSource.branch,
    _ => GitChangeSource.unstaged,
  };
}

/// 变更类型（对齐宿主 `GitChangeKind`）。
enum GitChangeKind {
  modified('modified'),
  added('added'),
  deleted('deleted'),
  renamed('renamed');

  const GitChangeKind(this.id);

  final String id;

  /// 形状容错：宿主只给四个标准值，别名兜底按 git status 单字母习惯。
  static GitChangeKind parse(Object? v) => switch (v is String ? v.toLowerCase() : '') {
    'added' || 'add' || 'a' => GitChangeKind.added,
    'deleted' || 'delete' || 'd' => GitChangeKind.deleted,
    'renamed' || 'rename' || 'r' => GitChangeKind.renamed,
    _ => GitChangeKind.modified,
  };
}

/// 脏文件条目（getChanges / getBranchComparison 的形状容错归一）。
class GitFileChangeEntry {
  const GitFileChangeEntry({
    required this.path,
    required this.kind,
    required this.section,
    this.source = GitChangeSource.unstaged,
    this.repoRelativePath,
    this.workspaceRelativePath,
    this.originalPath,
    this.added = 0,
    this.removed = 0,
    this.isStaged = false,
    this.isUntracked = false,
    this.isConflicted = false,
  });

  /// 宿主返回的绝对路径（getChanges/getBranchComparison 的 `path` 语义）。
  final String path;
  final GitChangeKind kind;
  final String section;
  final GitChangeSource source;
  final String? repoRelativePath;
  final String? workspaceRelativePath;

  /// renamed 时宿主给出的原路径（`originalPath`）。
  final String? originalPath;
  final int added;
  final int removed;
  final bool isStaged;
  final bool isUntracked;
  final bool isConflicted;

  /// 列表展示路径：优先 workspace 相对路径，回落 repo 相对路径，再回落绝对 path。
  String get displayPath => workspaceRelativePath ?? repoRelativePath ?? path;

  /// 排序键：对齐 ZCode「组内按 workspaceRelativePath 字典序」。
  String get sortPath => workspaceRelativePath ?? repoRelativePath ?? path;

  /// 分组用：branch / staged / unstaged / untracked / conflicted。
  String get group {
    if (source == GitChangeSource.branch) return 'branch';
    if (isConflicted) return 'conflicted';
    if (isStaged) return 'staged';
    if (isUntracked) return 'untracked';
    return 'unstaged';
  }
}

/// 分支对比（getBranchComparison，固定 `upstream...HEAD`）。
/// 宿主无上游时返回 baseRef=null + 空 changes，不抛错。
class GitBranchComparisonEntry {
  const GitBranchComparisonEntry({
    this.baseRef,
    this.headRef,
    this.comparisonLabel,
    this.changes = const [],
  });

  final String? baseRef;
  final String? headRef;
  final String? comparisonLabel;
  final List<GitFileChangeEntry> changes;

  bool get hasUpstream => baseRef != null && baseRef!.isNotEmpty;
}

/// 本地分支条目（getLocalBranches）。
class GitLocalBranchEntry {
  const GitLocalBranchEntry({
    required this.name,
    required this.isCurrent,
    this.upstreamName,
    this.commitHash,
  });

  final String name;
  final bool isCurrent;
  final String? upstreamName;
  final String? commitHash;
}

/// 单文件只读差异（getDiff）。
class GitDiffEntry {
  const GitDiffEntry({
    required this.path,
    required this.availability,
    this.patch,
    this.summary,
  });

  final String path;

  /// patch / binary / truncated / unavailable。
  final String availability;
  final String? patch;
  final String? summary;

  bool get hasPatch => patch != null && patch!.isNotEmpty;
}

/// 统一 diff 单行类型。
enum GitDiffLineType { fileHeader, hunkHeader, context, added, removed, note }

/// 统一 diff 单行（保留原文，渲染层再上色/加行号）。
class GitDiffLine {
  const GitDiffLine({required this.type, required this.text});

  final GitDiffLineType type;
  final String text;
}

/// 一个 hunk：`@@ -old,count +new,count @@` 及其后续行。
class GitDiffHunk {
  const GitDiffHunk({
    required this.header,
    required this.oldStart,
    required this.newStart,
    required this.lines,
  });

  final String header;
  final int oldStart;
  final int newStart;
  final List<GitDiffLine> lines;

  int get addedCount =>
      lines.where((l) => l.type == GitDiffLineType.added).length;
  int get removedCount =>
      lines.where((l) => l.type == GitDiffLineType.removed).length;
}

/// 解析后的统一 diff 文档（只读渲染用，不做语法高亮）。
class GitDiffDocument {
  const GitDiffDocument({
    required this.preamble,
    required this.hunks,
  });

  /// 首个 hunk 之前的 file header 行（diff --git / index / --- / +++ 等）。
  final List<GitDiffLine> preamble;
  final List<GitDiffHunk> hunks;

  bool get isEmpty => preamble.isEmpty && hunks.isEmpty;

  int get lineCount => preamble.length +
      hunks.fold(0, (sum, h) => sum + 1 + h.lines.length);
}

/// 解析 unified diff 补丁为可折叠 hunk 列表。
///
/// 只按行首字符分类（` `/`+`/`-`/`\`），hunk 头用正则取起始行号；
/// 解析失败的行按 [GitDiffLineType.note] 原样保留，不丢内容。
GitDiffDocument parseGitDiff(String patch) {
  final preamble = <GitDiffLine>[];
  final hunks = <GitDiffHunk>[];
  GitDiffHunk? current;
  final headerRe = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  if (patch.trim().isEmpty) return GitDiffDocument(preamble: preamble, hunks: hunks);
  // 末尾换行会产生一个空行，它不是 diff 内容，去掉再解析。
  final lines = patch.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  for (final raw in lines) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final match = headerRe.firstMatch(line);
    if (match != null) {
      current = GitDiffHunk(
        header: line,
        oldStart: int.parse(match.group(1)!),
        newStart: int.parse(match.group(2)!),
        lines: <GitDiffLine>[],
      );
      hunks.add(current);
      continue;
    }
    if (current == null) {
      preamble.add(GitDiffLine(type: GitDiffLineType.fileHeader, text: line));
      continue;
    }
    final type = switch (line.isEmpty ? '' : line[0]) {
      '+' => GitDiffLineType.added,
      '-' => GitDiffLineType.removed,
      ' ' => GitDiffLineType.context,
      r'\' => GitDiffLineType.note,
      _ => GitDiffLineType.note,
    };
    current.lines.add(GitDiffLine(type: type, text: line));
  }
  return GitDiffDocument(preamble: preamble, hunks: hunks);
}

/// Git 只读详情页数据（摘要 + 脏文件 + 本地分支）。
class GitDetail {
  const GitDetail({
    required this.status,
    this.workspacePath,
    this.branch,
    this.ahead = 0,
    this.behind = 0,
    this.isRepository = true,
    this.isGitAvailable = true,
    this.repoRoot,
    this.changes = const [],
    this.branches = const [],
    this.comparison,
    this.comparisonFailed = false,
    this.errorMessage,
  });

  final String? workspacePath;
  final String? branch;
  final int ahead;
  final int behind;
  final bool isRepository;
  final bool isGitAvailable;
  final String? repoRoot;
  final List<GitFileChangeEntry> changes;
  final List<GitLocalBranchEntry> branches;

  /// 分支对比（upstream...HEAD）；无上游/无差异时为 baseRef 空的条目，
  /// 拉取失败时为 null 且 [comparisonFailed]=true。
  final GitBranchComparisonEntry? comparison;
  final bool comparisonFailed;
  final GitOverviewStatus status;
  final String? errorMessage;

  bool get hasRepo =>
      status == GitOverviewStatus.ready && isRepository && branch != null;

  /// 脏文件数（不含分支对比，分支对比是另一维度）。
  int get dirtyCount =>
      changesOf(GitChangeSource.unstaged).length +
      changesOf(GitChangeSource.staged).length;

  /// 单来源变更，组内按 workspaceRelativePath 字典序（对齐 ZCode）。
  List<GitFileChangeEntry> changesOf(GitChangeSource source) {
    final list = changes.where((c) => c.source == source).toList()
      ..sort((a, b) => a.sortPath.compareTo(b.sortPath));
    return list;
  }

  int countOf(GitChangeSource source) =>
      changes.where((c) => c.source == source).length;
}

class GitOverviewClient {
  GitOverviewClient(this.bridge);

  final RpcBridge bridge;

  static const Duration _timeout = Duration(seconds: 10);

  /// workspacePath 为空 → noWorkspace 占位（不发包）。
  /// 失败 → loadFailed（可区分原因 + 可读文案），不再静默 unavailable。
  Future<GitOverview> fetch(String? workspacePath) async {
    final ws = workspacePath?.trim() ?? '';
    if (ws.isEmpty) return GitOverview.unavailable(workspacePath);
    try {
      final r = await bridge.call(
        'git',
        'getRepositorySummary',
        params: {'workspacePath': ws},
        timeout: _timeout,
      );
      return GitOverview.fromJson(r.firstObjectDeep ?? const {}, ws);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[git] getRepositorySummary failed: $e');
      }
      return GitOverview.loadFailed(workspacePath, _clip('$e'));
    }
  }

  /// 只读详情：一次聚合拉取 = 摘要（分支/ahead-behind）+ staged/unstaged
  /// 脏文件 + 分支对比（upstream...HEAD）+ 本地分支。每个数据源独立
  /// try/catch 隔离，任一源失败不拖垮其余源（[GitDetail] 为数据源）。
  Future<GitDetail> fetchDetail(String? workspacePath) async {
    final ws = workspacePath?.trim() ?? '';
    if (ws.isEmpty) {
      return const GitDetail(status: GitOverviewStatus.noWorkspace);
    }
    try {
      final summaryResp = await bridge.call(
        'git',
        'getRepositorySummary',
        params: {'workspacePath': ws},
        timeout: _timeout,
      );
      final summary = GitOverview.fromJson(
        summaryResp.firstObjectDeep ?? const {},
        ws,
      );
      final changes = <GitFileChangeEntry>[];
      // 单源失败隔离：staged/unstaged 各自兜底，不因一个失败丢掉另一个。
      for (final source in const ['staged', 'unstaged']) {
        try {
          final r = await bridge.call(
            'git',
            'getChanges',
            params: {'workspacePath': ws, 'sourceId': source},
            timeout: _timeout,
          );
          changes.addAll(_changesOf(r.values, source));
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[git] getChanges($source) failed: $e');
          }
        }
      }
      // 失败（null）与「无上游」（baseRef 空的条目）区分：失败时 UI 提示重试。
      final comparison = await _comparisonOrNull(ws);
      final comparisonFailed = comparison == null;
      // 分支对比变更并入总表，来源标记为 branch，供来源分段计数/排序。
      if (comparison != null) changes.addAll(comparison.changes);
      var branches = const <GitLocalBranchEntry>[];
      try {
        final r = await bridge.call(
          'git',
          'getLocalBranches',
          params: {'workspacePath': ws},
          timeout: _timeout,
        );
        branches = _branchesOf(r.values);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[git] getLocalBranches failed: $e');
        }
      }
      return GitDetail(
        workspacePath: ws,
        branch: summary.branch,
        ahead: summary.ahead,
        behind: summary.behind,
        isRepository: summary.isRepository,
        isGitAvailable: summary.isGitAvailable,
        repoRoot: summary.repoRoot,
        changes: changes,
        branches: branches,
        comparison: comparison,
        comparisonFailed: comparisonFailed,
        status: summary.status,
        errorMessage: summary.errorMessage,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[git] fetchDetail failed: $e');
      }
      return GitDetail(
        workspacePath: workspacePath,
        status: GitOverviewStatus.loadFailed,
        errorMessage: _clip('$e'),
      );
    }
  }

  /// 分支对比（getBranchComparison，固定 upstream...HEAD）。
  /// 失败返回 null（与「无上游」区分：无上游返回 baseRef 空的条目）。
  Future<GitBranchComparisonEntry?> fetchComparison(String workspacePath) async {
    final ws = workspacePath.trim();
    if (ws.isEmpty) return null;
    try {
      final r = await bridge.call(
        'git',
        'getBranchComparison',
        params: {'workspacePath': ws},
        timeout: _timeout,
      );
      return _comparisonOf(r.firstObjectDeep ?? const {});
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[git] getBranchComparison failed: $e');
      }
      return null;
    }
  }

  Future<GitBranchComparisonEntry?> _comparisonOrNull(String ws) =>
      fetchComparison(ws);

  /// 单文件只读差异（getDiff）。失败返回 availability=unavailable。
  Future<GitDiffEntry> fetchDiff(
    String workspacePath,
    String path, {
    String sourceId = 'unstaged',
  }) async {
    final ws = workspacePath.trim();
    if (ws.isEmpty) {
      return GitDiffEntry(
        path: path,
        availability: 'unavailable',
      );
    }
    try {
      final r = await bridge.call(
        'git',
        'getDiff',
        params: {'workspacePath': ws, 'path': path, 'sourceId': sourceId},
        timeout: _timeout,
      );
      return _diffOf(r.firstObjectDeep ?? const {}, path);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[git] getDiff($path) failed: $e');
      }
      return GitDiffEntry(path: path, availability: 'unavailable');
    }
  }

  static String _clip(String message) {
    final flat = message.replaceAll('\n', ' ').trim();
    return flat.length <= 160 ? flat : '${flat.substring(0, 160)}…';
  }

  static List<GitFileChangeEntry> _changesOf(
    List<Object?> values,
    String sourceId,
  ) {
    final source = GitChangeSource.parse(sourceId);
    final out = <GitFileChangeEntry>[];
    for (final value in values) {
      if (value is! Map) continue;
      final entry = _changeOf(value, source);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  /// 单条变更的形状容错归一：path 缺失跳过；kind/section 缺省回落。
  static GitFileChangeEntry? _changeOf(Map value, GitChangeSource source) {
    final path = _strOf(
      value,
      const ['path', 'workspaceRelativePath', 'repoRelativePath'],
    );
    if (path == null) return null;
    return GitFileChangeEntry(
      path: path,
      kind: GitChangeKind.parse(value['kind']),
      section: _strOf(value, const ['section']) ?? source.id,
      source: source,
      repoRelativePath: _strOf(value, const ['repoRelativePath']),
      workspaceRelativePath: _strOf(
        value,
        const ['workspaceRelativePath'],
      ),
      originalPath: _strOf(value, const ['originalPath']),
      added: _asInt(value['added']),
      removed: _asInt(value['removed']),
      isStaged: value['isStaged'] == true || source == GitChangeSource.staged,
      isUntracked: value['isUntracked'] == true,
      isConflicted: value['isConflicted'] == true,
    );
  }

  /// 分支对比形状容错：外壳可能包一层 `{comparison: {...}}`，
  /// 但 firstObjectDeep 已剥单键外壳；这里再兜一层 changes 缺失。
  static GitBranchComparisonEntry _comparisonOf(Map<String, dynamic> j) {
    final raw = j['changes'];
    final changes = <GitFileChangeEntry>[];
    if (raw is List) {
      changes.addAll(_changesOf(raw, GitChangeSource.branch.id));
    }
    String? str(List<String> keys) => _strOf(j, keys);
    return GitBranchComparisonEntry(
      baseRef: str(const ['baseRef', 'base']),
      headRef: str(const ['headRef', 'head']),
      comparisonLabel: str(const ['comparisonLabel', 'label']),
      changes: changes,
    );
  }

  static List<GitLocalBranchEntry> _branchesOf(List<Object?> values) {
    for (final value in values) {
      if (value is! Map) continue;
      final raw = value['branches'];
      if (raw is! List) continue;
      final currentName = _strOf(value, const ['currentBranchName']);
      final out = <GitLocalBranchEntry>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final name = _strOf(e, const ['name']);
        if (name == null || name.isEmpty) continue;
        out.add(GitLocalBranchEntry(
          name: name,
          isCurrent:
              e['isCurrent'] == true ||
              (currentName != null && name == currentName),
          upstreamName: _strOf(e, const ['upstreamName']),
          commitHash: _strOf(e, const ['commitHash']),
        ));
      }
      return out;
    }
    return const [];
  }

  static GitDiffEntry _diffOf(Map<String, dynamic> j, String fallbackPath) {
    final availability =
        _strOf(j, const ['availability']) ?? 'unavailable';
    return GitDiffEntry(
      path: _strOf(j, const ['path']) ?? fallbackPath,
      availability: availability,
      patch: _strOf(j, const ['patch']),
      summary: _strOf(j, const ['summary']),
    );
  }

  static String? _strOf(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final v = map[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }
}
