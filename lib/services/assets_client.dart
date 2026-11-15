import 'package:flutter/foundation.dart';

import 'rpc_bridge.dart';

/// 资产只读浏览（开发计划 20261115-0901 P1-8）：
/// Skills / Commands / Subagents / MCP / Hooks / Memory 六个 Tab，
/// 每频道独立候选（skillsService / commandsService / subagentsService /
/// mcpSyncService / hooksService / memoryService），单服务缺失只影响本 Tab。
///
/// 形状容错（S2）：名称 name|id、描述 description|prompt|systemPrompt、
/// 状态 enabled|status；容器键按各服务返回（skills/commands+userCommands+
/// pluginCommands/agents+userAgents+pluginAgents/statuses/hooks/顶层数组）
/// 逐别名探测，全部失配时按空列表降级不抛。
enum AssetsTabKind { skills, commands, subagents, mcp, hooks, memory }

class AssetEntry {
  const AssetEntry({
    required this.name,
    this.description,
    this.badge,
    this.enabled,
  });

  final String name;
  final String? description;

  /// 状态徽章原文（scope 来源 / MCP status / hook event）。
  final String? badge;

  /// null = 未知（不显示开关态徽章）。
  final bool? enabled;
}

class AssetsTabResult {
  const AssetsTabResult({
    required this.entries,
    required this.degraded,
    this.needsWorkspace = false,
  });

  final List<AssetEntry> entries;

  /// 响应可解析但形状对不上（空列表降级）时为 true，UI 展示降级提示。
  final bool degraded;

  /// 宿主签名要求 workspacePath 必填（skills/subagents/mcp/hooks），
  /// 空参时客户端不发包，UI 走「进入会话后可用」占位而非报错。
  final bool needsWorkspace;
}

class AssetsFetchException implements Exception {
  const AssetsFetchException(this.tab, this.message);

  final AssetsTabKind tab;
  final String message;

  @override
  String toString() => 'AssetsFetchException(${tab.name}: $message)';
}

abstract final class AssetsTabSpec {
  static const Map<AssetsTabKind, ({String channel, String method})> calls = {
    AssetsTabKind.skills: (channel: 'skills', method: 'list'),
    AssetsTabKind.commands: (channel: 'commands', method: 'list'),
    AssetsTabKind.subagents: (channel: 'subagents', method: 'list'),
    AssetsTabKind.mcp: (channel: 'mcp', method: 'listWorkspaceMcpServerStatuses'),
    AssetsTabKind.hooks: (channel: 'hooks', method: 'loadHooks'),
    AssetsTabKind.memory: (channel: 'memory', method: 'listProjectMemories'),
  };

  /// 宿主签名中 workspacePath **必填**的频道：空参直接抛错，客户端须不发包。
  /// commands 的 workspacePath 可选（缺则回用户级数据）、memory 无参，
  /// 二者按各自签名照常调用。
  static const Set<AssetsTabKind> _workspaceRequired = {
    AssetsTabKind.skills,
    AssetsTabKind.subagents,
    AssetsTabKind.mcp,
    AssetsTabKind.hooks,
  };

  static bool requiresWorkspace(AssetsTabKind tab) =>
      _workspaceRequired.contains(tab);
}

class AssetsClient {
  AssetsClient(this.bridge);

  final RpcBridge bridge;

  /// 错误文案最长保留字符数（超出截断，保证错误态可读不撑爆布局）。
  static const int maxErrorChars = 160;

  Future<AssetsTabResult> fetchTab(
    AssetsTabKind tab, {
    String? workspacePath,
  }) async {
    final call = AssetsTabSpec.calls[tab]!;
    final ws = workspacePath?.trim() ?? '';
    // 必填 workspace 的四频道：空参时宿主直接抛错，这里不发包，返回可识别的
    // 「需要 workspace」结果，UI 走占位（与官方手机 UI 的空 workspace 守卫一致）。
    if (ws.isEmpty && AssetsTabSpec.requiresWorkspace(tab)) {
      return const AssetsTabResult(
        entries: [],
        degraded: false,
        needsWorkspace: true,
      );
    }
    final params = <String, dynamic>{
      if (ws.isNotEmpty) 'workspacePath': ws,
    };
    try {
      final r = await bridge.call(call.channel, call.method, params: params);
      return normalizeTab(tab, r.values);
    } on RpcRemoteException catch (e) {
      throw AssetsFetchException(tab, _clip(e.message));
    } on RpcTimeoutException catch (e) {
      throw AssetsFetchException(tab, _clip('$e'));
    } catch (e) {
      throw AssetsFetchException(tab, _clip('$e'));
    }
  }

  static String _clip(String message) {
    final flat = message.replaceAll('\n', ' ').trim();
    return flat.length <= maxErrorChars ? flat : '${flat.substring(0, maxErrorChars)}…';
  }

  // ---- 归一化（形状容错）----------------------------------------------

  /// 按 Tab 归一化；响应完全不像（无任何已知容器键）→ degraded 空列表。
  @visibleForTesting
  static AssetsTabResult normalizeTab(AssetsTabKind tab, List<Object?> values) {
    switch (tab) {
      case AssetsTabKind.skills:
        return _fromDocContainers(tab, values, const [
          'skills',
          'items',
        ]);
      case AssetsTabKind.commands:
        return _commandsOf(values);
      case AssetsTabKind.subagents:
        return _subagentsOf(values);
      case AssetsTabKind.mcp:
        return _mcpOf(values);
      case AssetsTabKind.hooks:
        return _hooksOf(values);
      case AssetsTabKind.memory:
        return _memoryOf(values);
    }
  }

  static AssetsTabResult _fromDocContainers(
    AssetsTabKind tab,
    List<Object?> values,
    List<String> containerKeys,
  ) {
    for (final doc in _docsOf(values)) {
      for (final key in containerKeys) {
        final raw = doc[key];
        if (raw is! List) continue;
        return AssetsTabResult(
          entries: [for (final e in raw) if (e is Map) ?_entryOf(e)],
          degraded: false,
        );
      }
    }
    return const AssetsTabResult(entries: [], degraded: true);
  }

  /// 候选文档集合：顶层数组里的每个 Map + 其 data/result 单键壳
  /// （最多剥两层，外壳包裹漂移 S2-1）。
  static Iterable<Map<String, dynamic>> _docsOf(List<Object?> values) sync* {
    for (final value in values) {
      if (value is! Map<String, dynamic>) continue;
      yield value;
      for (final shellKey in const ['data', 'result']) {
        final inner = value[shellKey];
        if (inner is Map<String, dynamic>) {
          yield inner;
          for (final shellKey2 in const ['data', 'result']) {
            final inner2 = inner[shellKey2];
            if (inner2 is Map<String, dynamic>) yield inner2;
          }
        }
      }
    }
  }

  static AssetsTabResult _commandsOf(List<Object?> values) {
    final out = <AssetEntry>[];
    var sawContainer = false;
    for (final value in _docsOf(values)) {
      for (final entry in const [
        ('commands', 'builtin'),
        ('userCommands', 'user'),
        ('pluginCommands', 'plugin'),
      ]) {
        final raw = value[entry.$1];
        if (raw is! List) continue;
        sawContainer = true;
        for (final e in raw) {
          if (e is! Map) continue;
          final item = _entryOf(e, badgeOverride: entry.$2);
          if (item != null) out.add(item);
        }
      }
    }
    if (!sawContainer) return const AssetsTabResult(entries: [], degraded: true);
    return AssetsTabResult(entries: out, degraded: false);
  }

  static AssetsTabResult _subagentsOf(List<Object?> values) {
    final out = <AssetEntry>[];
    var sawContainer = false;
    for (final value in _docsOf(values)) {
      for (final entry in const [
        ('agents', null),
        ('userAgents', 'user'),
        ('pluginAgents', 'plugin'),
      ]) {
        final raw = value[entry.$1];
        if (raw is! List) continue;
        sawContainer = true;
        for (final e in raw) {
          if (e is! Map) continue;
          final item = _entryOf(e, badgeOverride: entry.$2);
          if (item != null) out.add(item);
        }
      }
    }
    if (!sawContainer) return const AssetsTabResult(entries: [], degraded: true);
    return AssetsTabResult(entries: out, degraded: false);
  }

  static AssetsTabResult _mcpOf(List<Object?> values) {
    for (final value in _docsOf(values)) {
      final statuses = value['statuses'];
      if (statuses is Map) {
        final out = <AssetEntry>[];
        for (final name in statuses.keys) {
          final raw = statuses[name];
          if (raw is! Map) continue;
          out.add(AssetEntry(
            name: '$name',
            description: _mcpDescription(raw),
            badge: _strOf(raw, const ['status']),
          ));
        }
        return AssetsTabResult(entries: out, degraded: false);
      }
      // 形状漂移兜底：直接给数组。
      if (statuses is List) {
        return AssetsTabResult(
          entries: [for (final e in statuses) if (e is Map) ?_entryOf(e)],
          degraded: false,
        );
      }
    }
    return const AssetsTabResult(entries: [], degraded: true);
  }

  static String _mcpDescription(Map<dynamic, dynamic> raw) {
    final transport = _strOf(raw, const ['transport']);
    final toolCount = raw['toolCount'];
    final error = _strOf(raw, const ['error']);
    final parts = [
      ?transport,
      if (toolCount is num) '${toolCount.toInt()} tools',
      if (error != null && error.isNotEmpty) error,
    ];
    return parts.isEmpty ? '' : parts.join(' · ');
  }

  static AssetsTabResult _hooksOf(List<Object?> values) {
    for (final value in _docsOf(values)) {
      final raw = value['hooks'];
      if (raw is List) {
        final out = <AssetEntry>[];
        for (final e in raw) {
          if (e is! Map) continue;
          final event = _strOf(e, const ['event', 'type']);
          final matcher = _strOf(e, const ['matcher']);
          final command = _strOf(e, const ['command']);
          final name = matcher ?? _strOf(e, const ['id']) ?? event ?? '';
          if (name.isEmpty) continue;
          out.add(AssetEntry(
            name: name,
            description: command ?? '',
            badge: event,
            enabled: e['enabled'] is bool ? e['enabled'] as bool : null,
          ));
        }
        return AssetsTabResult(entries: out, degraded: false);
      }
    }
    return const AssetsTabResult(entries: [], degraded: true);
  }

  /// 记忆 Tab 归一化。
  ///
  /// 契约（开源=官方）：`memoryService.listProjectMemories()` 返回
  /// `ProjectMemoryWorkspaceSummary[]`（`{id,label,updatedAt,files[]}`）。
  /// RPC 回包经 `_valuesOf` 解包后 `values` **就是顶层数组本身**，元素是
  /// summary 的 Map——旧实现只找「数组里嵌数组」，导致恒降级为
  /// 「响应形状不识别」（2026-11-15 真机问题十二）。
  static AssetsTabResult _memoryOf(List<Object?> values) {
    // 空回包＝无内容，不是形状不符（否则空记忆库会显示「响应形状不识别」）。
    if (values.isEmpty) return const AssetsTabResult(entries: [], degraded: false);
    // 形态 A：顶层即摘要数组（元素为 Map 且含 label/name/id）。
    final direct = _memoryEntriesOf(values);
    if (direct != null) return AssetsTabResult(entries: direct, degraded: false);
    // 形态 B：某元素是嵌套数组（旧形态，兼容保留）。
    for (final value in values) {
      if (value is! List) continue;
      final nested = _memoryEntriesOf(value);
      if (nested != null) return AssetsTabResult(entries: nested, degraded: false);
    }
    // 形态 C：外壳包裹 {workspaces|memories: [...]}（含 data/result 壳）。
    for (final value in _docsOf(values)) {
      for (final key in const ['workspaces', 'memories']) {
        final raw = value[key];
        if (raw is List) {
          return _memoryOf([raw]);
        }
      }
    }
    return const AssetsTabResult(entries: [], degraded: true);
  }

  /// 仅当列表里至少有一个元素是「含 label/name/id 的 Map」时视为摘要数组，
  /// 返回条目；否则 null（让调用方继续尝试其他形态）。
  static List<AssetEntry>? _memoryEntriesOf(List<Object?> list) {
    var sawSummary = false;
    final out = <AssetEntry>[];
    for (final e in list) {
      if (e is! Map) continue;
      final name = _strOf(e, const ['label', 'name', 'id']);
      if (name == null) continue;
      sawSummary = true;
      final files = e['files'];
      out.add(AssetEntry(
        name: name,
        description: files is List ? '${files.length} files' : '',
      ));
    }
    return sawSummary ? out : null;
  }

  static AssetEntry? _entryOf(
    Map<dynamic, dynamic> e, {
    String? badgeOverride,
  }) {
    final name = _strOf(e, const ['name', 'id']);
    if (name == null || name.isEmpty) return null;
    return AssetEntry(
      name: name,
      description: _strOf(
        e,
        const ['description', 'prompt', 'systemPrompt', 'body'],
      ),
      badge: badgeOverride ?? _strOf(e, const ['scope', 'source', 'status']),
      enabled: e['enabled'] is bool ? e['enabled'] as bool : null,
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
