import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 已通知事件去重账（D3）。
///
/// 后台心跳快照（D1）与原 JS 事件链路、回前台 reload 后的 StateDiffer 补发
/// 可能对「同一个任务完成」重复产出 completed 事件。本账以
/// `deviceId:type:taskId` 为键记录最近一次通知时刻，在窗口期内抑制重复；
/// 同一 taskId 的新一轮完成（超过窗口）仍可再次通知。
///
/// 纯判定逻辑在 [NotifiedEventDeduplicator]，便于无平台依赖单测。
abstract final class NotifiedEventDeduplicator {
  /// 去重窗口：同一完成事件在该时长内的重复上报只通知一次。
  static const Duration window = Duration(minutes: 10);

  static String keyOf(String deviceId, String type, String? taskId) =>
      '$deviceId:$type:${taskId ?? '-'}';
}

/// 进程内去重状态（可单测）。
class NotifiedEventTracker {
  NotifiedEventTracker({
    Map<String, DateTime>? initial,
    DateTime Function()? now,
    Duration window = NotifiedEventDeduplicator.window,
  })  : _seen = Map<String, DateTime>.from(initial ?? const {}),
        _now = now ?? DateTime.now,
        _window = window;

  final Map<String, DateTime> _seen;
  final DateTime Function() _now;
  final Duration _window;

  /// 该键是否应通知：未在窗口内出现过才返回 true，并登记本次时刻。
  bool shouldNotify(String key) {
    final now = _now();
    _prune(now);
    final last = _seen[key];
    if (last != null && now.difference(last) < _window) return false;
    _seen[key] = now;
    return true;
  }

  void _prune(DateTime now) {
    final deadline = now.subtract(_window);
    _seen.removeWhere((_, at) => at.isBefore(deadline));
  }

  /// 序列化快照（供持久化）。
  Map<String, String> snapshot() => {
        for (final entry in _seen.entries)
          entry.key: entry.value.toIso8601String(),
      };

  /// 从持久化快照恢复。
  void restore(Map<String, String> data) {
    _seen.clear();
    data.forEach((key, value) {
      final at = DateTime.tryParse(value);
      if (at != null) _seen[key] = at;
    });
  }
}

/// 持久化包装：内存去重 + 异步落盘（进程重启后仍抑制窗口内的重复）。
class NotifiedEventStore {
  NotifiedEventStore._();

  static final NotifiedEventStore instance = NotifiedEventStore._();

  static const _key = 'zremote.notified.events';

  final NotifiedEventTracker _tracker = NotifiedEventTracker();
  bool _loaded = false;

  /// 从磁盘恢复去重账（main 启动时调用一次）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final map = jsonDecode(raw);
      if (map is Map) {
        _tracker.restore(map.map((k, v) => MapEntry('$k', '$v')));
      }
    } catch (_) {
    }
  }

  /// 是否应投递该事件（并在需要时登记 + 落盘）。
  bool shouldNotify(String deviceId, String type, String? taskId) {
    final key = NotifiedEventDeduplicator.keyOf(deviceId, type, taskId);
    final ok = _tracker.shouldNotify(key);
    if (ok) _persist();
    return ok;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_tracker.snapshot()));
    } catch (_) {
    }
  }
}
