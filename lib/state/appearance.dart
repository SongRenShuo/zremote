import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';
import '../ui/haptics.dart';
import '../ui/motion.dart';

/// 字号缩放档位（P3-3）：0.85 / 1.0 / 1.15。
enum ZrFontScale {
  small('0.85', 0.85),
  normal('1.0', 1.0),
  large('1.15', 1.15);

  const ZrFontScale(this.key, this.factor);

  /// 持久化键值（与 SharedPreferences 存储同源）。
  final String key;
  final double factor;

  static ZrFontScale ofKey(String? key) => switch (key) {
    '0.85' => ZrFontScale.small,
    '1.15' => ZrFontScale.large,
    _ => ZrFontScale.normal,
  };
}

/// 外观增强状态（P3-3）：字号缩放 / 动效减弱 / 触感反馈。
///
/// OLED 纯黑主题独立走 themeMode（ZrThemeMode.oled，见 theme_mode.dart）。
class AppearancePrefs {
  const AppearancePrefs({
    this.fontScale = ZrFontScale.normal,
    this.reduceMotion = false,
    this.haptics = true,
  });

  final ZrFontScale fontScale;
  final bool reduceMotion;
  final bool haptics;

  AppearancePrefs copyWith({
    ZrFontScale? fontScale,
    bool? reduceMotion,
    bool? haptics,
  }) => AppearancePrefs(
    fontScale: fontScale ?? this.fontScale,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    haptics: haptics ?? this.haptics,
  );
}

class AppearanceNotifier extends Notifier<AppearancePrefs> {
  AppearanceNotifier({AppearancePrefs? initial}) : _initial = initial;

  final AppearancePrefs? _initial;

  @override
  AppearancePrefs build() {
    final initial = _initial;
    if (initial != null) {
      _syncStatics(initial);
      return initial;
    }
    _load();
    return const AppearancePrefs();
  }

  Future<void> _load() async {
    final prefs = await DeviceStore.instance.appearancePrefs();
    _syncStatics(prefs);
    state = prefs;
  }

  Future<void> set(AppearancePrefs value) async {
    _syncStatics(value);
    await DeviceStore.instance.setAppearancePrefs(value);
    state = value;
  }

  Future<void> setFontScale(ZrFontScale scale) =>
      set(state.copyWith(fontScale: scale));

  Future<void> setReduceMotion(bool value) =>
      set(state.copyWith(reduceMotion: value));

  Future<void> setHaptics(bool value) => set(state.copyWith(haptics: value));

  /// 全局静态快照（ZrMotion/ZrHaptics 不订阅 provider，读静态位）。
  static void _syncStatics(AppearancePrefs prefs) {
    ZrMotion.reduced = prefs.reduceMotion;
    ZrHaptics.enabled = prefs.haptics;
  }
}

final appearanceProvider =
    NotifierProvider<AppearanceNotifier, AppearancePrefs>(
      AppearanceNotifier.new,
    );
