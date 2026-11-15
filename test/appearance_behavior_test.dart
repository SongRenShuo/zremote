import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/state/appearance.dart';
import 'package:zremote/state/behavior.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/state/theme_mode.dart';
import 'package:zremote/ui/haptics.dart';
import 'package:zremote/ui/motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ZrMotion.debugReset();
    ZrHaptics.enabled = true;
  });

  group('ZrThemeMode 迁移（P3-3 OLED）', () {
    test('旧键 dark/light/system 兼容读取，新键 oled 合法', () {
      final container = ProviderContainer(
        overrides: [
          themeModeSettingProvider.overrideWith(
            () => ThemeModeSettingNotifier(initial: 'dark'),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(themeModeSettingProvider), 'dark');

      final oled = ProviderContainer(
        overrides: [
          themeModeSettingProvider.overrideWith(
            () => ThemeModeSettingNotifier(initial: 'oled'),
          ),
        ],
      );
      addTearDown(oled.dispose);
      expect(oled.read(themeModeSettingProvider), 'oled');
    });

    test('脏值回落 system；set 拒绝非法值', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          themeModeSettingProvider.overrideWith(
            () => ThemeModeSettingNotifier(initial: 'zai-dark'),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(themeModeSettingProvider), kThemeSystem);
      await container.read(themeModeSettingProvider.notifier).set('blue');
      expect(container.read(themeModeSettingProvider), kThemeSystem);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('zremote.themeMode'), isNull);
    });

    test('resolveThemeMode：oled 归入 dark（纯黑由调色板区分）', () {
      expect(resolveThemeMode('oled'), ThemeMode.dark);
      expect(resolveThemeMode('dark'), ThemeMode.dark);
      expect(resolveThemeMode('light'), ThemeMode.light);
      expect(resolveThemeMode('system'), ThemeMode.system);
      expect(resolveThemeMode('garbage'), ThemeMode.system);
    });

    test('枚举映射与 isOledSetting', () {
      expect(zrThemeModeOf('system'), ZrThemeMode.system);
      expect(zrThemeModeOf('oled'), ZrThemeMode.oled);
      expect(zrThemeModeOf(''), ZrThemeMode.system);
      expect(isOledSetting('oled'), isTrue);
      expect(isOledSetting('dark'), isFalse);
    });
  });

  group('外观状态往返（字号/动效/触感）', () {
    testWidgets('懒加载读存储 + set 落盘 + 静态位同步', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.appearance.fontScale': '1.15',
        'zremote.appearance.reduceMotion': true,
        'zremote.appearance.haptics': false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 装载前默认（build 同步返回默认）。
      expect(container.read(appearanceProvider).fontScale, ZrFontScale.normal);
      await tester.pump();
      final loaded = container.read(appearanceProvider);
      expect(loaded.fontScale, ZrFontScale.large);
      expect(loaded.reduceMotion, isTrue);
      expect(loaded.haptics, isFalse);
      // 静态快照同步（ZrMotion/ZrHaptics）。
      expect(ZrMotion.reduced, isTrue);
      expect(ZrHaptics.enabled, isFalse);

      await container
          .read(appearanceProvider.notifier)
          .setFontScale(ZrFontScale.small);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('zremote.appearance.fontScale'), '0.85');
      expect(container.read(appearanceProvider).fontScale, ZrFontScale.small);
      expect(ZrMotion.reduced, isTrue);

      await container.read(appearanceProvider.notifier).setReduceMotion(false);
      expect(ZrMotion.reduced, isFalse);
      await container.read(appearanceProvider.notifier).setHaptics(true);
      expect(ZrHaptics.enabled, isTrue);
    });

    test('ZrFontScale.ofKey 脏值回落 normal', () {
      expect(ZrFontScale.ofKey('0.85'), ZrFontScale.small);
      expect(ZrFontScale.ofKey('1.0'), ZrFontScale.normal);
      expect(ZrFontScale.ofKey('1.15'), ZrFontScale.large);
      expect(ZrFontScale.ofKey('2.0'), ZrFontScale.normal);
      expect(ZrFontScale.ofKey(null), ZrFontScale.normal);
    });

    test('ZrMotion 时长换算：正常原样，减弱 40%', () {
      ZrMotion.reduced = false;
      expect(ZrMotion.duration(200), const Duration(milliseconds: 200));
      ZrMotion.reduced = true;
      expect(ZrMotion.duration(200), const Duration(milliseconds: 80));
      expect(ZrMotion.duration(90), const Duration(milliseconds: 36));
    });
  });

  group('行为配置往返（P3-4）', () {
    testWidgets('脏值回落默认 + set 往返落盘', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.behavior.defaultMode': 'yolo',
        'zremote.behavior.restore': 'first',
        'zremote.behavior.softLimit': 8,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(behaviorProvider).defaultMode, 'build');
      await tester.pump();
      final loaded = container.read(behaviorProvider);
      expect(loaded.defaultMode, 'yolo');
      expect(loaded.restorePolicy, ZrRestorePolicy.first);
      expect(loaded.softLimit, 8);

      await container.read(behaviorProvider.notifier).setSoftLimit(99);
      expect(container.read(behaviorProvider).softLimit, 10, reason: 'clamp');
      await container.read(behaviorProvider.notifier).setSoftLimit(0);
      expect(container.read(behaviorProvider).softLimit, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('zremote.behavior.softLimit'), 1);

      await container
          .read(behaviorProvider.notifier)
          .setRestorePolicy(ZrRestorePolicy.none);
      expect(
        prefs.getString('zremote.behavior.restore'),
        'none',
      );
    });

    testWidgets('非法 mode / 越界 softLimit 落盘值回落', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.behavior.defaultMode': 'edit',
        'zremote.behavior.softLimit': 42,
      });
      final loaded = await DeviceStore.instance.behaviorPrefs();
      expect(loaded.defaultMode, 'build');
      expect(loaded.softLimit, 10);
    });

    test('restorePolicyOf 映射', () {
      expect(restorePolicyOf('lastDevice'), ZrRestorePolicy.lastDevice);
      expect(restorePolicyOf('first'), ZrRestorePolicy.first);
      expect(restorePolicyOf('none'), ZrRestorePolicy.none);
      expect(restorePolicyOf(null), ZrRestorePolicy.lastDevice);
      expect(restorePolicyOf('x'), ZrRestorePolicy.lastDevice);
    });
  });

  group('自动锁定延时（P3-8）', () {
    testWidgets('选择集 {0,10,60,300}；非法拒绝；缺省 10', (tester) async {
      expect(DeviceStore.kRelockChoices, [0, 10, 60, 300]);
      SharedPreferences.setMockInitialValues({
        'zremote.biometric.relockDelay': 37,
      });
      expect(await DeviceStore.instance.relockDelaySeconds(), 10);
      await DeviceStore.instance.setRelockDelaySeconds(60);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('zremote.biometric.relockDelay'), 60);

      final container = ProviderContainer(
        overrides: [
          relockDelayProvider.overrideWith(() => RelockDelayNotifier(initial: 5)),
        ],
      );
      addTearDown(container.dispose);
      // build 同步值 5；_load 异步落定后为存储值 60（37 非法→写回 60 生效值）。
      expect(container.read(relockDelayProvider), 5);
      await tester.pump();
      expect(container.read(relockDelayProvider), 60);
      await container.read(relockDelayProvider.notifier).set(5);
      expect(container.read(relockDelayProvider), 60, reason: '非选择集拒绝');
      await container.read(relockDelayProvider.notifier).set(300);
      expect(container.read(relockDelayProvider), 300);
    });
  });
}
