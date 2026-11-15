import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

/// 启动恢复策略（P3-4）：上次设备（现状）/ 固定首台 / 不恢复。
enum ZrRestorePolicy { lastDevice, first, none }

const kRestoreLastDevice = 'lastDevice';
const kRestoreFirst = 'first';
const kRestoreNone = 'none';

ZrRestorePolicy restorePolicyOf(String? key) => switch (key) {
  kRestoreFirst => ZrRestorePolicy.first,
  kRestoreNone => ZrRestorePolicy.none,
  _ => ZrRestorePolicy.lastDevice,
};

/// 会话行为配置（P3-4）：新任务默认权限模式 / 启动恢复 / 设备软上限。
class BehaviorPrefs {
  const BehaviorPrefs({
    this.defaultMode = 'build',
    this.restorePolicy = ZrRestorePolicy.lastDevice,
    this.softLimit = 5,
  });

  /// 新任务默认权限模式（automation_form 预填；build/guarded/plan/yolo）。
  final String defaultMode;

  final ZrRestorePolicy restorePolicy;

  /// 设备软上限（1-10；manage_page 添加超限提醒弹窗读它）。
  final int softLimit;

  BehaviorPrefs copyWith({
    String? defaultMode,
    ZrRestorePolicy? restorePolicy,
    int? softLimit,
  }) => BehaviorPrefs(
    defaultMode: defaultMode ?? this.defaultMode,
    restorePolicy: restorePolicy ?? this.restorePolicy,
    softLimit: softLimit ?? this.softLimit,
  );
}

class BehaviorNotifier extends Notifier<BehaviorPrefs> {
  BehaviorNotifier({BehaviorPrefs? initial}) : _initial = initial;

  final BehaviorPrefs? _initial;

  @override
  BehaviorPrefs build() {
    final initial = _initial;
    if (initial != null) return initial;
    _load();
    return const BehaviorPrefs();
  }

  Future<void> _load() async {
    state = await DeviceStore.instance.behaviorPrefs();
  }

  Future<void> set(BehaviorPrefs value) async {
    await DeviceStore.instance.setBehaviorPrefs(value);
    state = value;
  }

  Future<void> setDefaultMode(String mode) =>
      set(state.copyWith(defaultMode: mode));

  Future<void> setRestorePolicy(ZrRestorePolicy policy) =>
      set(state.copyWith(restorePolicy: policy));

  Future<void> setSoftLimit(int limit) =>
      set(state.copyWith(softLimit: limit.clamp(1, 10)));
}

final behaviorProvider = NotifierProvider<BehaviorNotifier, BehaviorPrefs>(
  BehaviorNotifier.new,
);
