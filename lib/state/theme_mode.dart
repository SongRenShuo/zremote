import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

const kThemeSystem = 'system';

/// 自建主题档位（P3-3）：Material ThemeMode 不含 OLED 纯黑，
/// 由本枚举扩展第四档（Material 侧映射为 dark + 纯黑调色板）。
enum ZrThemeMode { system, light, dark, oled }

const kThemeDark = 'dark';
const kThemeLight = 'light';
const kThemeOled = 'oled';

/// 字符串档位 → 枚举（非法值回落 system；旧键 dark/light 兼容）。
ZrThemeMode zrThemeModeOf(String setting) => switch (setting) {
  kThemeDark => ZrThemeMode.dark,
  kThemeLight => ZrThemeMode.light,
  kThemeOled => ZrThemeMode.oled,
  _ => ZrThemeMode.system,
};

/// OLED 是否生效（darkTheme 调色板选择的唯一判据）。
bool isOledSetting(String setting) => setting == kThemeOled;

class ThemeModeSettingNotifier extends Notifier<String> {
  ThemeModeSettingNotifier({String? initial}) : _initial = initial;

  final String? _initial;

  @override
  String build() {
    final initial = _initial;
    if (initial != null) {
      return _valid(initial) ? initial : kThemeSystem;
    }
    _load();
    return kThemeSystem;
  }

  Future<void> _load() async {
    final value = await DeviceStore.instance.themeModeSetting();
    state = _valid(value) ? value : kThemeSystem;
  }

  static bool _valid(String v) =>
      v == kThemeSystem ||
      v == kThemeDark ||
      v == kThemeLight ||
      v == kThemeOled;

  Future<void> set(String value) async {
    if (!_valid(value)) return;
    await DeviceStore.instance.setThemeModeSetting(value);
    state = value;
  }
}

final themeModeSettingProvider =
    NotifierProvider<ThemeModeSettingNotifier, String>(
      ThemeModeSettingNotifier.new,
    );

/// Material ThemeMode 映射：oled 归入 dark（纯黑由调色板区分）。
ThemeMode resolveThemeMode(String setting) => switch (setting) {
  'dark' => ThemeMode.dark,
  'light' => ThemeMode.light,
  'oled' => ThemeMode.dark,
  _ => ThemeMode.system,
};
