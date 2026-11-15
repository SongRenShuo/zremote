import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import 'behavior.dart';

class DeviceListNotifier extends Notifier<List<RemoteDevice>> {
  @override
  List<RemoteDevice> build() {
    _load();
    return [];
  }

  Future<void> _load() async {
    state = await DeviceStore.instance.loadAll();
  }

  Future<void> add(RemoteDevice device) async {
    await DeviceStore.instance.add(device);
    state = [...state, device];
  }

  Future<void> rename(String id, String label) async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    if (target == null || label.trim().isEmpty) return;
    final updated = target.copyWith(label: label.trim());
    await DeviceStore.instance.update(updated);
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
  }

  /// P4-2 置顶：params key `pinned`='1' + 移到列表头（落盘=设备 JSON +
  /// 顺序索引）；取消置顶只清键不挪位。
  static const kPinnedParamKey = 'pinned';

  bool isPinned(RemoteDevice device) => device.params[kPinnedParamKey] == '1';

  Future<void> setPinned(String id, bool pinned) async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    if (target == null) return;
    if (isPinned(target) == pinned) return;
    // 挪位前先记住当前 activeTab 指向的设备 id（挪位后按 id 跟随修正）。
    final activeId = _activeDeviceId();
    final params = Map.of(target.params);
    if (pinned) {
      params[kPinnedParamKey] = '1';
    } else {
      params.remove(kPinnedParamKey);
    }
    final updated = RemoteDevice(
      id: target.id,
      baseUrl: target.baseUrl,
      params: params,
      label: target.label,
      createdAt: target.createdAt,
      kind: target.kind,
    );
    await DeviceStore.instance.update(updated);
    var next = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
    if (pinned) {
      // 置顶 = 移到列表头（remove-then-insert）。
      next.remove(updated);
      next.insert(0, updated);
    }
    await DeviceStore.instance.saveOrder([for (final d in next) d.id]);
    state = next;
    if (activeId != null) {
      final i = next.indexWhere((d) => d.id == activeId);
      if (i >= 0 && ref.read(activeTabProvider) != i) {
        ref.read(activeTabProvider.notifier).set(i);
      }
    }
  }

  String? _activeDeviceId() {
    final active = ref.read(activeTabProvider);
    final list = state;
    return active < list.length ? list[active].id : null;
  }

  /// P3-1 每设备通知覆盖：params key `notifyOverride`（on/off/inherit）。
  static const kNotifyOverrideParamKey = 'notifyOverride';

  Future<void> setNotifyOverride(String id, String override) async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    if (target == null) return;
    if (const ['on', 'off', 'inherit'].contains(override) == false) return;
    if (target.params[kNotifyOverrideParamKey] == override ||
        (override == 'inherit' &&
            !target.params.containsKey(kNotifyOverrideParamKey))) {
      return;
    }
    final params = Map.of(target.params);
    if (override == 'inherit') {
      params.remove(kNotifyOverrideParamKey);
    } else {
      params[kNotifyOverrideParamKey] = override;
    }
    final updated = RemoteDevice(
      id: target.id,
      baseUrl: target.baseUrl,
      params: params,
      label: target.label,
      createdAt: target.createdAt,
      kind: target.kind,
    );
    await DeviceStore.instance.update(updated);
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
  }

  Future<void> remove(String id) async {
    await DeviceStore.instance.remove(id);
    state = state.where((d) => d.id != id).toList();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= state.length) return;
    if (oldIndex == newIndex) return;

    final active = ref.read(activeTabProvider);
    final activeId = active < state.length ? state[active].id : null;

    final reordered = [...state]..removeAt(oldIndex);
    final moved = state[oldIndex];
    reordered.insert(newIndex, moved);

    await DeviceStore.instance
        .saveOrder([for (final d in reordered) d.id]);
    state = reordered;

    if (activeId != null) {
      final i = reordered.indexWhere((d) => d.id == activeId);
      if (i >= 0 && ref.read(activeTabProvider) != i) {
        ref.read(activeTabProvider.notifier).set(i);
      }
    }
  }

  Future<void> replaceLink(String id, RemoteDevice parsed) async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    if (target == null) return;
    final updated = RemoteDevice(
      id: target.id,
      baseUrl: parsed.baseUrl,
      params: parsed.params,
      label: target.label.isNotEmpty ? target.label : parsed.label,
      createdAt: target.createdAt,
      kind: parsed.kind,
    );
    await DeviceStore.instance.update(updated);
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
  }
}

final deviceListProvider =
    NotifierProvider<DeviceListNotifier, List<RemoteDevice>>(
      DeviceListNotifier.new,
    );

class ActiveTabNotifier extends Notifier<int> {
  bool _restoreDone = false;

  bool _jumpedBeforeRestore = false;

  @override
  int build() => 0;

  void set(int index) {
    final count = ref.read(deviceListProvider).length;
    if (index < 0 || index > count) return;
    state = index;
    if (index < count) {
      _jumpedBeforeRestore = true;
      unawaited(
        DeviceStore.instance.setLastDeviceId(
          ref.read(deviceListProvider)[index].id,
        ).catchError((e) {
          debugPrint('[ZR] lastDevice 落盘失败: $e');
        }),
      );
    }
  }

  Future<void> restoreLast() async {
    if (_restoreDone || _jumpedBeforeRestore) return;
    _restoreDone = true;
    // P3-4 启动恢复策略：lastDevice（现状）/first/none。
    final policy = (await DeviceStore.instance.behaviorPrefs()).restorePolicy;
    if (_jumpedBeforeRestore) return;
    if (policy == ZrRestorePolicy.none) return;
    if (policy == ZrRestorePolicy.first) {
      if (ref.read(deviceListProvider).isNotEmpty) state = 0;
      return;
    }
    final id = await DeviceStore.instance.lastDeviceId();
    if (_jumpedBeforeRestore) return;
    if (id == null) return;
    final index = ref.read(deviceListProvider).indexWhere((d) => d.id == id);
    if (index >= 0) state = index;
  }

  void clampTo(int childCount) {
    if (state >= childCount) state = childCount - 1;
    if (state < 0) state = 0;
  }
}

final activeTabProvider = NotifierProvider<ActiveTabNotifier, int>(
  ActiveTabNotifier.new,
);

class BiometricNotifier extends Notifier<bool> {
  BiometricNotifier({this.initial = false});

  final bool initial;

  @override
  bool build() {
    _load();
    return initial;
  }

  Future<void> _load() async {
    state = await DeviceStore.instance.biometricEnabled();
  }

  Future<void> set(bool value) async {
    await DeviceStore.instance.setBiometricEnabled(value);
    state = value;
  }
}

final biometricProvider = NotifierProvider<BiometricNotifier, bool>(
  BiometricNotifier.new,
);

/// 自动锁定延时（P3-8，秒；0=立即）。BiometricGate relockAfter 的数据源。
class RelockDelayNotifier extends Notifier<int> {
  RelockDelayNotifier({this.initial = 10});

  final int initial;

  @override
  int build() {
    _load();
    return initial;
  }

  Future<void> _load() async {
    state = await DeviceStore.instance.relockDelaySeconds();
  }

  Future<void> set(int seconds) async {
    if (!DeviceStore.kRelockChoices.contains(seconds)) return;
    await DeviceStore.instance.setRelockDelaySeconds(seconds);
    state = seconds;
  }
}

final relockDelayProvider = NotifierProvider<RelockDelayNotifier, int>(
  RelockDelayNotifier.new,
);
