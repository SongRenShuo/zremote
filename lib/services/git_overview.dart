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

/// 脏文件条目（getChanges 的形状容错归一）。
class GitFileChangeEntry {
  const GitFileChangeEntry({
    required this.path,
    required this.kind,
    required this.section,
    this.added = 0,
    this.removed = 0,
    this.isStaged = false,
    this.isUntracked = false,
    this.isConflicted = false,
  });

  final String path;
  final String kind;
  final String section;
  final int added;
  final int removed;
  final bool isStaged;
  final bool isUntracked;
  final bool isConflicted;

  /// 分组用：staged / unstaged / untracked / conflicted。
  String get group {
    if (isConflicted) return 'conflicted';
    if (isStaged) return 'staged';
    if (isUntracked) return 'untracked';
    return 'unstaged';
  }
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
  final GitOverviewStatus status;
  final String? errorMessage;

  bool get hasRepo =>
      status == GitOverviewStatus.ready && isRepository && branch != null;

  int get dirtyCount => changes.length;
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

  /// 只读详情：摘要（分支/ahead-behind）+ 脏文件（getChanges staged+unstaged）
  /// + 本地分支（getLocalBranches，失败不拖垮）。数据源 [GitDetail]。
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
    final out = <GitFileChangeEntry>[];
    for (final value in values) {
      if (value is! Map) continue;
      final path = _strOf(value, const ['path', 'workspaceRelativePath', 'repoRelativePath']);
      if (path == null || path.isEmpty) continue;
      out.add(GitFileChangeEntry(
        path: path,
        kind: _strOf(value, const ['kind']) ?? 'modified',
        section:
            _strOf(value, const ['section']) ?? sourceId,
        added: _asInt(value['added']),
        removed: _asInt(value['removed']),
        isStaged: value['isStaged'] == true || sourceId == 'staged',
        isUntracked: value['isUntracked'] == true,
        isConflicted: value['isConflicted'] == true,
      ));
    }
    return out;
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
