import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/ui/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keepaliveChannel = MethodChannel('zremote/keepalive');
  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );

  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          packageInfoChannel,
          (call) async => {
            'appName': 'ZRemote',
            'packageName': 'cn.song.zremote',
            'version': '1.4.0',
            'buildNumber': '7',
            'buildSignature': '',
          },
        );
    addTearDown(() {
      for (final c in [keepaliveChannel, packageInfoChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(c, null);
      }
      tester.view.reset();
    });
    tester.view.physicalSize = const Size(760, 3200);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页「活动自动领取」分组含全局一键手动领取按钮，点击出汇总 snack', (
    tester,
  ) async {
    await pumpSettings(tester);

    final title = find.text('一键领取所有设备');
    expect(title, findsOneWidget, reason: 'tile 存在');
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();

    await tester.tap(title);
    await tester.pumpAndSettle();

    // 空设备态：claimAllLive 遍历 0 台 → 汇总 0/0/0。
    expect(
      find.textContaining('领取完成：成功 0，失败 0，跳过 0 台设备'),
      findsOneWidget,
    );
  });
}
