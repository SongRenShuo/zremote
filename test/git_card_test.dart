import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/services/git_overview.dart';
import 'package:zremote/ui/git_card.dart';

import 'scripted_bridge.dart';

void main() {
  testWidgets('P1-7 GitCard：分支/脏数/上下行渲染（scripted git 频道）',
      (tester) async {
    final bridge = ScriptedBridge(script: const [
      [
        {
          'branchName': 'feat/v2',
          'ahead': 2,
          'behind': 1,
          'isDirty': true,
          'dirtyCount': 5,
          'isRepository': true,
        },
      ],
    ]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(
              client: GitOverviewClient(bridge.bridge),
              workspacePath: '/ws',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Git 概览'), findsOneWidget);
    expect(find.text('分支 feat/v2 · ↑2 ↓1'), findsOneWidget);
    expect(find.text('5 个改动'), findsOneWidget);
    expect(bridge.commands, hasLength(1));
    expect(bridge.commands.single['s'], 'gitService');
  });

  testWidgets('P1-7 GitCard：client 未接线 → 置灰不发包含提示', (tester) async {
    final bridge = ScriptedBridge(script: const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(workspacePath: '/ws'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.commands, isEmpty);
  });

  testWidgets('P1-7 GitCard：无会话（workspacePath 空）→ 不发包含提示',
      (tester) async {
    final bridge = ScriptedBridge(script: const []);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: GitCard(client: GitOverviewClient(bridge.bridge)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('进入会话后显示当前工作区状态'), findsOneWidget);
    expect(bridge.commands, isEmpty);
  });
}
