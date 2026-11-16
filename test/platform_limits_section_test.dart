import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/services/platform_caps.dart';
import 'package:zremote/ui/platform_limits_section.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ListView(children: [child])),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformLimitsSection（P5-2 iOS / P4 鸿蒙 能力说明卡）', () {
    testWidgets('visible:true 渲染三条限制说明（保活/隔离/通知）', (tester) async {
      await tester.pumpWidget(_wrap(const PlatformLimitsSection(visible: true)));
      await tester.pumpAndSettle();

      expect(find.text('iOS 平台限制说明'), findsOneWidget);
      expect(find.text('保活前台服务'), findsOneWidget);
      expect(find.text('多账号 Cookie 隔离'), findsOneWidget);
      expect(find.text('通知部分能力'), findsOneWidget);
      // 事实陈述在卡内（iOS 暂不支持多 Profile → 共用登录态）。
      expect(
        find.textContaining('iOS 系统 WebView 暂不支持多 Profile'),
        findsOneWidget,
      );
      // 审批动作按钮 Android 专属的说明。
      expect(find.textContaining('Android 专属'), findsOneWidget);
    });

    testWidgets('visible:false 零渲染（Android 设备不显示）', (tester) async {
      await tester.pumpWidget(
        _wrap(const PlatformLimitsSection(visible: false)),
      );
      await tester.pumpAndSettle();

      expect(find.text('iOS 平台限制说明'), findsNothing);
      expect(find.text('鸿蒙平台限制说明'), findsNothing);
      expect(find.text('保活前台服务'), findsNothing);
    });

    testWidgets('默认 visible=null 跟随宿主平台（Windows 测试宿主=不显示）',
        (tester) async {
      await tester.pumpWidget(_wrap(const PlatformLimitsSection()));
      await tester.pumpAndSettle();

      // 测试宿主非 iOS/鸿蒙：与 Android 设备同路径，零占位。
      expect(find.text('iOS 平台限制说明'), findsNothing);
      expect(find.text('鸿蒙平台限制说明'), findsNothing);
    });

    testWidgets('鸿蒙平台（注入）显示鸿蒙条目，不显示 iOS 文案', (tester) async {
      PlatformCaps.debugOverrideOhos = true;
      addTearDown(() => PlatformCaps.debugOverrideOhos = null);
      await tester.pumpWidget(_wrap(const PlatformLimitsSection()));
      await tester.pumpAndSettle();

      expect(find.text('鸿蒙平台限制说明'), findsOneWidget);
      expect(find.text('iOS 平台限制说明'), findsNothing);
      expect(find.text('保活前台服务'), findsOneWidget);
      expect(find.textContaining('HarmonyOS NEXT'), findsOneWidget);
    });
  });
}
