import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/ui/desktop_settings_page.dart';

import 'scripted_bridge.dart';

RemoteDevice _device() => RemoteDevice(
      id: 'd1',
      baseUrl: 'https://relay.example.com',
      params: const {'sid': 'd_test0001', 'app_version': '3.16.1'},
      label: '测试机',
      createdAt: DateTime(2026, 10, 19),
    );

Future<ScriptedBridge> _pumpPage(
  WidgetTester tester,
  ScriptedBridge bridge,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DesktopSettingsPage(device: _device(), bridge: bridge.bridge),
    ),
  );
  await tester.pumpAndSettle();
  return bridge;
}


Finder _reasoningSwitch(WidgetTester tester) => find.descendant(
      of: find.byKey(const Key('desktop-setting-messageStreamShowReasoning')),
      matching: find.byType(Switch),
    );

void main() {
  testWidgets('P1-6 get 命令断言：白名单四开关 + locale 只读', (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {
          'messageStreamShowReasoning': true,
          'messageStreamShowTodos': false,
          'taskAutoArchiveEnabled': true,
          'keepAwakeWhileRunning': false,
          'locale': 'zh-CN',
          'providerFamilyDomain': 'zai',
        },
      ],
    ]);
    await _pumpPage(tester, bridge);

    expect(bridge.commands, hasLength(1));
    final req = requestOf(bridge.commands.single);
    expect(req.channel, 'setting');
    expect(req.method, 'get');

    expect(find.text('消息流显示思考过程'), findsOneWidget);
    expect(find.text('消息流显示 TODO'), findsOneWidget);
    expect(find.text('任务自动归档'), findsOneWidget);
    expect(find.text('运行时保持唤醒'), findsOneWidget);
    expect(find.text('界面语言（只读）'), findsOneWidget);
    expect(find.text('zh-CN'), findsOneWidget);

    // 白名单外键不渲染。
    expect(find.text('providerFamilyDomain'), findsNothing);

    final reasoningSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('desktop-setting-messageStreamShowReasoning')),
        matching: find.byType(Switch),
      ),
    );
    expect(reasoningSwitch.value, isTrue);
    final todosSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('desktop-setting-messageStreamShowTodos')),
        matching: find.byType(Switch),
      ),
    );
    expect(todosSwitch.value, isFalse);
  });

  testWidgets('P1-6 确认弹窗 → update patch 命令（取消不发）', (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {
          'messageStreamShowReasoning': false,
          'locale': 'zh-CN',
        },
      ],
      [],
    ]);
    await _pumpPage(tester, bridge);

    // 取消：不发 update。
    await tester.tap(_reasoningSwitch(tester));
    await tester.pumpAndSettle();
    expect(find.text('修改桌面端设置'), findsOneWidget);
    await tester.tap(find.byKey(const Key('desktop-setting-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(bridge.commands, hasLength(1));

    // 确认：update 以 {key: value} patch 提交。
    await tester.tap(_reasoningSwitch(tester));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop-setting-confirm-ok')));
    await tester.pumpAndSettle();
    expect(bridge.commands, hasLength(2));
    final req = requestOf(bridge.commands[1]);
    expect(req.method, 'update');
    expect(req.params, {'messageStreamShowReasoning': true});
    // 成功后本地态翻转（无需二次 get）。
    final reasoningSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('desktop-setting-messageStreamShowReasoning')),
        matching: find.byType(Switch),
      ),
    );
    expect(reasoningSwitch.value, isTrue);
  });

  testWidgets('P1-6 值未知的开关置灰不可交互', (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {'locale': 'zh-CN'},
      ],
    ]);
    await _pumpPage(tester, bridge);
    final sw = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('desktop-setting-keepAwakeWhileRunning')),
        matching: find.byType(Switch),
      ),
    );
    expect(sw.onChanged, isNull);
    expect(sw.value, isFalse);
  });

  testWidgets('P1-6 no-services → 未就绪态 + 重试（L7：双候选各试一次）',
      (tester) async {
    final bridge = ScriptedBridge(
      script: const [
        [],
        // setting 频道两候选（settingService/settingsService）各试一次。
        [],
        [
          {
            'messageStreamShowReasoning': true,
            'locale': 'zh-CN',
          },
        ],
      ],
      errors: {0: 'no-services', 1: 'no-services'},
    );
    await _pumpPage(tester, bridge);
    expect(find.text('请先在网页中选择电脑并进入会话'), findsOneWidget);
    expect(find.text('消息流显示思考过程'), findsNothing);
    // 两候选都拒绝后才落 notReady。
    expect(bridge.commands, hasLength(2));

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(bridge.commands, hasLength(3));
    expect(bridge.commands[2]['s'], 'settingService');
    expect(find.text('消息流显示思考过程'), findsOneWidget);
  });
}
