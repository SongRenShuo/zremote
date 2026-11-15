import 'package:flutter/foundation.dart';

import 'rpc_bridge.dart';

/// Git 概览（开发计划 20261115-0901 P1-7）：
/// `git` 频道 `gitService.getRepositorySummary({workspacePath})`。
///
/// 形状容错（S2，开源版 GitRepositorySummary 为权威形状）：
/// 分支别名 branchName|branch|currentBranch；脏文件数
/// dirtyCount|dirtyFiles.length|changes.length，全缺时回落 isDirty 布尔
/// （count 未知显示为「有改动」）；ahead/behind 数值别名不敏感。
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
  });

  /// 宿主未进会话（无 workspacePath）或未开通 git 服务时的占位。
  const GitOverview.unavailable(this.workspacePath)
    : branch = null,
      dirtyCount = null,
      isDirty = false,
      ahead = 0,
      behind = 0,
      isRepository = false,
      isGitAvailable = true,
      repoRoot = null;

  final String? workspacePath;
  final String? branch;
  final int? dirtyCount;
  final bool isDirty;
  final int ahead;
  final int behind;
  final bool isRepository;
  final bool isGitAvailable;
  final String? repoRoot;

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
    return GitOverview(
      workspacePath: workspacePath,
      branch: branch,
      dirtyCount: dirtyCount,
      isDirty: j['isDirty'] == true || (dirtyCount ?? 0) > 0,
      ahead: _intOf(j['ahead']),
      behind: _intOf(j['behind']),
      isRepository: j['isRepository'] is bool
          ? j['isRepository'] as bool
          : branch != null,
      isGitAvailable: j['isGitAvailable'] is bool
          ? j['isGitAvailable'] as bool
          : true,
      repoRoot: j['repoRoot'] is String ? j['repoRoot'] as String? : null,
    );
  }

  static int _intOf(Object? v) => v is num ? v.toInt() : 0;
}

class GitOverviewClient {
  GitOverviewClient(this.bridge);

  final RpcBridge bridge;

  /// workspacePath 为空 → unavailable 占位（不发包）。
  Future<GitOverview> fetch(String? workspacePath) async {
    final ws = workspacePath?.trim() ?? '';
    if (ws.isEmpty) return GitOverview.unavailable(workspacePath);
    try {
      final r = await bridge.call(
        'git',
        'getRepositorySummary',
        params: {'workspacePath': ws},
        timeout: const Duration(seconds: 10),
      );
      return GitOverview.fromJson(r.firstObjectDeep ?? const {}, ws);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[git] getRepositorySummary degraded: $e');
      }
      return GitOverview.unavailable(workspacePath);
    }
  }
}
