import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

class OffPeakTask {
  const OffPeakTask({
    required this.offPeakTaskId,
    this.title = '',
    this.prompt = '',
    this.status = '',
    this.queuePosition,
    this.workspacePath = '',
    this.permissionMode = 'build',
    this.failureReason,
    this.filesChanged,
    this.queuedAt,
    this.updatedAt,
    this.historyDeletedAt,
  });

  final String offPeakTaskId;
  final String title;
  final String prompt;
  final String status;
  final int? queuePosition;
  final String workspacePath;

  final String permissionMode;

  final String? failureReason;

  final int? filesChanged;

  final DateTime? queuedAt;
  final DateTime? updatedAt;

  /// 非空表示宿主已把该任务从历史中移除；
  /// UI 以灰态展示而不是让记录凭空消失。
  final DateTime? historyDeletedAt;

  bool get historyDeleted => historyDeletedAt != null;

  static OffPeakTask? fromJson(Map<String, dynamic> j) {
    final id = j['offPeakTaskId'];
    if (id is! String || id.isEmpty) return null;
    return OffPeakTask(
      offPeakTaskId: id,
      title: j['title'] is String ? j['title'] as String : '',
      prompt: j['prompt'] is String ? j['prompt'] as String : '',
      status: j['status'] is String ? j['status'] as String : '',
      queuePosition: j['queuePosition'] is num
          ? (j['queuePosition'] as num).toInt()
          : null,
      workspacePath: j['workspacePath'] is String
          ? j['workspacePath'] as String
          : '',
      permissionMode: j['permissionMode'] is String
          ? j['permissionMode'] as String
          : 'build',
      failureReason: j['failureReason'] is String
          ? j['failureReason'] as String
          : null,
      filesChanged: j['filesChanged'] is num
          ? (j['filesChanged'] as num).toInt()
          : null,
      queuedAt: _msToDateTime(j['queuedAt']),
      updatedAt: _msToDateTime(j['updatedAt']),
      historyDeletedAt: _msToDateTime(j['historyDeletedAt']) ??
          (j['historyDeletedAt'] is String
              ? DateTime.tryParse(j['historyDeletedAt'] as String)
              : null),
    );
  }

  static DateTime? _msToDateTime(dynamic v) =>
      v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

  Map<String, dynamic> toJson() => {
    'offPeakTaskId': offPeakTaskId,
    if (title.isNotEmpty) 'title': title,
    if (prompt.isNotEmpty) 'prompt': prompt,
    if (status.isNotEmpty) 'status': status,
    if (queuePosition != null) 'queuePosition': queuePosition,
    if (workspacePath.isNotEmpty) 'workspacePath': workspacePath,
    if (permissionMode != 'build') 'permissionMode': permissionMode,
    if (failureReason != null) 'failureReason': failureReason,
    if (filesChanged != null) 'filesChanged': filesChanged,
    if (queuedAt != null) 'queuedAt': queuedAt!.millisecondsSinceEpoch,
    if (updatedAt != null) 'updatedAt': updatedAt!.millisecondsSinceEpoch,
    if (historyDeletedAt != null)
      'historyDeletedAt': historyDeletedAt!.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) =>
      other is OffPeakTask &&
      other.offPeakTaskId == offPeakTaskId &&
      other.title == title &&
      other.prompt == prompt &&
      other.status == status &&
      other.queuePosition == queuePosition &&
      other.workspacePath == workspacePath &&
      other.permissionMode == permissionMode &&
      other.failureReason == failureReason &&
      other.filesChanged == filesChanged &&
      other.queuedAt == queuedAt &&
      other.updatedAt == updatedAt &&
      other.historyDeletedAt == historyDeletedAt;

  @override
  int get hashCode => Object.hashAll([
        offPeakTaskId,
        title,
        prompt,
        status,
        queuePosition,
        workspacePath,
        permissionMode,
        failureReason,
        filesChanged,
        queuedAt,
        updatedAt,
        historyDeletedAt,
      ]);
}

class Automation {
  const Automation({
    required this.automationId,
    this.title = '',
    this.prompt = '',
    this.cronExpr = '',
    this.enabled = false,
    this.recurring = false,
    this.workspacePath = '',
    this.mode = '',
    this.model = '',
    this.thoughtLevel = '',
    this.nextRunAt,
    this.lastRunAt,
    this.runCount = 0,
  });

  final String automationId;
  final String title;
  final String prompt;
  final String cronExpr;
  final bool enabled;
  final bool recurring;
  final String workspacePath;
  final String mode;
  final String model;
  final String thoughtLevel;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final int runCount;

  static Automation? fromJson(Map<String, dynamic> j) {
    final id = j['automationId'];
    if (id is! String || id.isEmpty) return null;
    return Automation(
      automationId: id,
      title: j['title'] is String ? j['title'] as String : '',
      prompt: j['prompt'] is String ? j['prompt'] as String : '',
      cronExpr: j['cronExpr'] is String ? j['cronExpr'] as String : '',
      enabled: j['enabled'] == true,
      recurring: j['recurring'] == true,
      workspacePath: j['workspacePath'] is String
          ? j['workspacePath'] as String
          : '',
      mode: j['mode'] is String ? j['mode'] as String : '',
      model: j['model'] is String ? j['model'] as String : '',
      thoughtLevel: j['thoughtLevel'] is String
          ? j['thoughtLevel'] as String
          : '',
      nextRunAt: OffPeakTask._msToDateTime(j['nextRunAt']),
      lastRunAt: OffPeakTask._msToDateTime(j['lastRunAt']),
      runCount: j['runCount'] is num ? (j['runCount'] as num).toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'automationId': automationId,
    if (title.isNotEmpty) 'title': title,
    if (prompt.isNotEmpty) 'prompt': prompt,
    if (cronExpr.isNotEmpty) 'cronExpr': cronExpr,
    'enabled': enabled,
    'recurring': recurring,
    if (workspacePath.isNotEmpty) 'workspacePath': workspacePath,
    if (mode.isNotEmpty) 'mode': mode,
    if (model.isNotEmpty) 'model': model,
    if (thoughtLevel.isNotEmpty) 'thoughtLevel': thoughtLevel,
    if (nextRunAt != null) 'nextRunAt': nextRunAt!.millisecondsSinceEpoch,
    if (lastRunAt != null) 'lastRunAt': lastRunAt!.millisecondsSinceEpoch,
    'runCount': runCount,
  };

  @override
  bool operator ==(Object other) =>
      other is Automation &&
      other.automationId == automationId &&
      other.title == title &&
      other.prompt == prompt &&
      other.cronExpr == cronExpr &&
      other.enabled == enabled &&
      other.recurring == recurring &&
      other.workspacePath == workspacePath &&
      other.mode == mode &&
      other.model == model &&
      other.thoughtLevel == thoughtLevel &&
      other.nextRunAt == nextRunAt &&
      other.lastRunAt == lastRunAt &&
      other.runCount == runCount;

  @override
  int get hashCode => Object.hashAll([
        automationId,
        title,
        prompt,
        cronExpr,
        enabled,
        recurring,
        workspacePath,
        mode,
        model,
        thoughtLevel,
        nextRunAt,
        lastRunAt,
        runCount,
      ]);
}

/// 自动化运行记录（来自 listAutomationRuns / 被动喂流）。
/// 字段按宿主实际返回做容错解析，未知形状只丢字段不丢条目。
class AutomationRun {
  const AutomationRun({
    required this.runId,
    required this.automationId,
    this.title = '',
    this.prompt = '',
    this.status = '',
    this.workspacePath = '',
    this.failureReason,
    this.startedAt,
    this.endedAt,
  });

  final String runId;
  final String automationId;
  final String title;
  final String prompt;
  final String status;
  final String workspacePath;

  final String? failureReason;

  final DateTime? startedAt;
  final DateTime? endedAt;

  static AutomationRun? fromJson(Map<String, dynamic> j) {
    final runId = j['runId'];
    final automationId = j['automationId'];
    if (runId is! String || runId.isEmpty) return null;
    if (automationId is! String || automationId.isEmpty) return null;
    return AutomationRun(
      runId: runId,
      automationId: automationId,
      title: j['title'] is String ? j['title'] as String : '',
      prompt: j['prompt'] is String ? j['prompt'] as String : '',
      // 宿主实测（2026-11-14 CDP）：状态字段是 outcome（succeeded/failed）
      // + dispatchStatus（queued/dispatched），无 status/displayStatus。
      status: _statusOf(j),
      workspacePath: j['workspacePath'] is String
          ? j['workspacePath'] as String
          : (j['workspaceKey'] is String ? j['workspaceKey'] as String : ''),
      failureReason:
          j['failureReason'] is String ? j['failureReason'] as String : null,
      // 宿主实测：时间是 scheduledAt（排程触发），非 startedAt。
      startedAt: _msToDateTime(
        j['startedAt'] ?? j['scheduledAt'] ?? j['queuedAt'] ?? j['createdAt'],
      ),
      endedAt: _msToDateTime(j['endedAt'] ?? j['updatedAt'] ?? j['finishedAt']),
    );
  }

  static DateTime? _msToDateTime(dynamic v) =>
      v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

  /// 宿主字段映射：outcome(succeeded/failed) 为主，兼容旧 status/displayStatus；
  /// succeeded 归一为 completed 以复用状态徽章词汇。
  static String _statusOf(Map<String, dynamic> j) {
    final raw = (j['outcome'] ?? j['status'] ?? j['displayStatus']) is String
        ? (j['outcome'] ?? j['status'] ?? j['displayStatus']) as String
        : '';
    switch (raw) {
      case 'succeeded':
        return 'completed';
      case '':
        final dispatch = j['dispatchStatus'];
        return dispatch is String ? dispatch : '';
      default:
        return raw;
    }
  }

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'automationId': automationId,
    if (title.isNotEmpty) 'title': title,
    if (prompt.isNotEmpty) 'prompt': prompt,
    if (status.isNotEmpty) 'status': status,
    if (workspacePath.isNotEmpty) 'workspacePath': workspacePath,
    if (failureReason != null) 'failureReason': failureReason,
    if (startedAt != null) 'startedAt': startedAt!.millisecondsSinceEpoch,
    if (endedAt != null) 'endedAt': endedAt!.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) =>
      other is AutomationRun &&
      other.runId == runId &&
      other.automationId == automationId &&
      other.title == title &&
      other.prompt == prompt &&
      other.status == status &&
      other.workspacePath == workspacePath &&
      other.failureReason == failureReason &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt;

  @override
  int get hashCode => Object.hashAll([
        runId,
        automationId,
        title,
        prompt,
        status,
        workspacePath,
        failureReason,
        startedAt,
        endedAt,
      ]);
}

class AutomationBoard {
  const AutomationBoard({
    this.subscribed = false,
    this.offPeak = const [],
    this.automations = const [],
    this.runs = const [],
    this.recentProjects = const [],
    this.lastSyncedAt,
  });

  final bool subscribed;

  final List<OffPeakTask> offPeak;
  final List<Automation> automations;
  final List<AutomationRun> runs;
  final List<String> recentProjects;

  /// 最近一次成功拉取自动化数据的时间（离线时历史 Tab 展示最后快照）。
  final DateTime? lastSyncedAt;

  int get queuedCount =>
      offPeak.where((t) => t.status == 'queued' && !t.historyDeleted).length;

  /// 有可持久化的数据（空面板不落盘，避免重载清空把快照抹掉）。
  bool get hasData =>
      offPeak.isNotEmpty || automations.isNotEmpty || runs.isNotEmpty;

  List<AutomationRun> runsOf(String automationId) => [
    for (final run in runs)
      if (run.automationId == automationId) run,
  ];

  Map<String, dynamic> toSnapshotJson() => {
    'offPeak': [for (final t in offPeak) t.toJson()],
    'automations': [for (final a in automations) a.toJson()],
    'runs': [for (final r in runs) r.toJson()],
    if (lastSyncedAt != null)
      'lastSyncedAt': lastSyncedAt!.millisecondsSinceEpoch,
  };

  static AutomationBoard? fromSnapshotJson(dynamic raw) {
    if (raw is! Map) return null;
    final board = AutomationBoard(
      offPeak: [
        for (final t in (raw['offPeak'] as List? ?? const []))
          if (t is Map<String, dynamic>) ?OffPeakTask.fromJson(t),
      ],
      automations: [
        for (final a in (raw['automations'] as List? ?? const []))
          if (a is Map<String, dynamic>) ?Automation.fromJson(a),
      ],
      runs: [
        for (final r in (raw['runs'] as List? ?? const []))
          if (r is Map<String, dynamic>) ?AutomationRun.fromJson(r),
      ],
      lastSyncedAt: raw['lastSyncedAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(raw['lastSyncedAt'] as int)
          : null,
    );
    return board.hasData || board.lastSyncedAt != null ? board : null;
  }

  AutomationBoard copyWith({
    bool? subscribed,
    List<OffPeakTask>? offPeak,
    List<Automation>? automations,
    List<AutomationRun>? runs,
    List<String>? recentProjects,
    DateTime? lastSyncedAt,
  }) => AutomationBoard(
    subscribed: subscribed ?? this.subscribed,
    offPeak: offPeak ?? this.offPeak,
    automations: automations ?? this.automations,
    runs: runs ?? this.runs,
    recentProjects: recentProjects ?? this.recentProjects,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is AutomationBoard &&
      other.subscribed == subscribed &&
      listEquals(other.offPeak, offPeak) &&
      listEquals(other.automations, automations) &&
      listEquals(other.runs, runs) &&
      listEquals(other.recentProjects, recentProjects) &&
      other.lastSyncedAt == lastSyncedAt;

  @override
  int get hashCode => Object.hash(
        subscribed,
        Object.hashAll(offPeak),
        Object.hashAll(automations),
        Object.hashAll(runs),
        Object.hashAll(recentProjects),
        lastSyncedAt,
      );
}

class AutomationNotifier extends Notifier<Map<String, AutomationBoard>> {
  @override
  Map<String, AutomationBoard> build() => const {};

  AutomationBoard _boardOf(String deviceId) =>
      state[deviceId] ?? const AutomationBoard();

  Future<void>? _lastSave;

  /// 最近一次快照落盘的 future（测试用；生产侧 fire-and-forget）。
  @visibleForTesting
  Future<void> get lastSnapshotSave => _lastSave ?? Future<void>.value();

  void _put(String deviceId, AutomationBoard board) {
    if (state[deviceId] == board) return;
    state = {...state, deviceId: board};
    // P3-4：非空面板落盘（清空/重载复位不落盘，保留最后快照）。
    // 串行链式写入：保证最终落盘内容是最新面板，不受通道完成顺序影响。
    if (board.hasData) {
      final previous = _lastSave ?? Future<void>.value();
      _lastSave = previous
          .then((_) => DeviceStore.instance.saveAutomationSnapshot(
                deviceId,
                board,
              ))
          .catchError((Object e) {
        debugPrint('[automation] snapshot save failed: $e');
        return;
      });
      unawaited(_lastSave);
    }
  }

  /// 页面打开时恢复上次快照（离线/断连后历史仍可查看）。
  /// 在线数据已到达（hasData）时不覆盖。
  Future<void> restoreFromStore(String deviceId) async {
    try {
      if (_boardOf(deviceId).hasData) return;
      final snapshot =
          await DeviceStore.instance.automationSnapshot(deviceId);
      if (snapshot == null) return;
      if (_boardOf(deviceId).hasData) return;
      _put(deviceId, snapshot);
    } catch (e) {
      debugPrint('[automation] snapshot restore failed: $e');
    }
  }

  void reportSubscribed(String deviceId, bool subscribed) {
    final board = _boardOf(deviceId);
    if (subscribed) {
      _put(deviceId, board.copyWith(subscribed: true));
    } else {
      _put(
        deviceId,
        board.copyWith(subscribed: false, offPeak: const [], automations: const []),
      );
    }
  }

  void replaceOffPeak(String deviceId, List<Map<String, dynamic>> raw) {
    final tasks = <OffPeakTask>[
      for (final item in raw) ?OffPeakTask.fromJson(item),
    ];
    _put(deviceId, _boardOf(deviceId).copyWith(offPeak: tasks));
  }

  void replaceAutomations(String deviceId, List<Map<String, dynamic>> raw) {
    final automations = <Automation>[
      for (final item in raw) ?Automation.fromJson(item),
    ];
    _put(deviceId, _boardOf(deviceId).copyWith(automations: automations));
  }

  void upsertOffPeak(String deviceId, Map<String, dynamic> raw) {
    final task = OffPeakTask.fromJson(raw);
    if (task == null) return;
    final board = _boardOf(deviceId);
    final tasks = [...board.offPeak];
    final index = tasks.indexWhere((t) => t.offPeakTaskId == task.offPeakTaskId);
    if (index >= 0) {
      tasks[index] = task;
    } else {
      tasks.insert(0, task);
    }
    _put(deviceId, board.copyWith(offPeak: tasks));
  }

  void upsertAutomation(String deviceId, Map<String, dynamic> raw) {
    final auto = Automation.fromJson(raw);
    if (auto == null) return;
    final board = _boardOf(deviceId);
    final automations = [...board.automations];
    final index = automations.indexWhere(
      (a) => a.automationId == auto.automationId,
    );
    if (index >= 0) {
      automations[index] = auto;
    } else {
      automations.insert(0, auto);
    }
    _put(deviceId, board.copyWith(automations: automations));
  }

  void removeOffPeak(String deviceId, String id) {
    final board = _boardOf(deviceId);
    if (!board.offPeak.any((t) => t.offPeakTaskId == id)) return;
    _put(
      deviceId,
      board.copyWith(
        offPeak: board.offPeak
            .where((t) => t.offPeakTaskId != id)
            .toList(),
      ),
    );
  }

  void removeAutomation(String deviceId, String id) {
    final board = _boardOf(deviceId);
    if (!board.automations.any((a) => a.automationId == id)) return;
    _put(
      deviceId,
      board.copyWith(
        automations: board.automations
            .where((a) => a.automationId != id)
            .toList(),
      ),
    );
  }

  /// 整体替换运行历史（拉取/喂流快照）。
  void replaceRuns(String deviceId, List<Map<String, dynamic>> raw) {
    final runs = <AutomationRun>[
      for (final item in raw) ?AutomationRun.fromJson(item),
    ];
    _put(
      deviceId,
      _boardOf(deviceId)
          .copyWith(runs: runs, lastSyncedAt: DateTime.now()),
    );
  }

  /// 单条运行记录更新（喂流增量）。
  void upsertRun(String deviceId, Map<String, dynamic> raw) {
    final run = AutomationRun.fromJson(raw);
    if (run == null) return;
    final board = _boardOf(deviceId);
    final runs = [...board.runs];
    final index = runs.indexWhere((r) => r.runId == run.runId);
    if (index >= 0) {
      runs[index] = run;
    } else {
      runs.insert(0, run);
    }
    _put(deviceId, board.copyWith(runs: runs, lastSyncedAt: DateTime.now()));
  }

  /// 拉取成功（哪怕部分数据源失败）时刷新最后同步时间。
  void reportSynced(String deviceId) {
    _put(deviceId, _boardOf(deviceId).copyWith(lastSyncedAt: DateTime.now()));
  }

  void reportProjects(String deviceId, List<String> projects) {
    _put(deviceId, _boardOf(deviceId).copyWith(recentProjects: projects));
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final automationProvider =
    NotifierProvider<AutomationNotifier, Map<String, AutomationBoard>>(
      AutomationNotifier.new,
    );
