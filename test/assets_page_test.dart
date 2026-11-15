import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/assets_client.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/active_session.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/ui/assets_page.dart';

import 'scripted_bridge.dart';

RemoteDevice _device() => RemoteDevice(
      id: 'd1',
      baseUrl: 'https://relay.example.com',
      params: const {'sid': 'd_test0001', 'app_version': '3.16.1'},
      label: '测试机',
      createdAt: DateTime(2026, 10, 19),
    );

void main() {
  group('P1-8 AssetsClient.normalizeTab（S2 三类漂移成对）', () {
    test('skills 权威形状：name/description/enabled/scope', () {
      final r = AssetsClient.normalizeTab(AssetsTabKind.skills, const [
        {
          'skills': [
            {
              'id': 'pdf',
              'name': 'pdf',
              'description': 'PDF 工具',
              'enabled': true,
              'scope': 'user',
            },
            {
              'id': 'demo',
              'description': '仅 id 无 name',
              'enabled': false,
            },
          ],
        },
      ]);
      expect(r.degraded, isFalse);
      expect(r.entries, hasLength(2));
      expect(r.entries.first.name, 'pdf');
      expect(r.entries.first.description, 'PDF 工具');
      expect(r.entries.first.enabled, isTrue);
      expect(r.entries.first.badge, 'user');
      expect(r.entries[1].name, 'demo');
    });

    test('漂移 1 外壳包裹：{data:{skills:[...]}} 照常解析', () {
      final r = AssetsClient.normalizeTab(AssetsTabKind.skills, const [
        {
          'data': {
            'skills': [
              {'name': 's1'},
            ],
          },
        },
      ]);
      expect(r.degraded, isFalse);
      expect(r.entries.single.name, 's1');
    });

    test('漂移 2 字段缺失：description 缺失回落 prompt（subagents）', () {
      final r = AssetsClient.normalizeTab(AssetsTabKind.subagents, const [
        {
          'agents': [
            {'id': 'reviewer', 'prompt': '代码评审员'},
          ],
          'userAgents': [],
          'pluginAgents': [
            {'id': 'lark', 'systemPrompt': '飞书集成'},
          ],
        },
      ]);
      expect(r.entries, hasLength(2));
      expect(r.entries.first.description, '代码评审员');
      expect(r.entries[1].badge, 'plugin');
    });

    test('漂移 3 类型漂移：statuses 由 Map 变 List 仍可解析（mcp）', () {
      final asMap = AssetsClient.normalizeTab(AssetsTabKind.mcp, const [
        {
          'statuses': {
            'fetch': {
              'status': 'ready',
              'transport': 'stdio',
              'toolCount': 3,
            },
          },
        },
      ]);
      expect(asMap.entries.single.name, 'fetch');
      expect(asMap.entries.single.badge, 'ready');
      expect(asMap.entries.single.description, contains('stdio'));

      final asList = AssetsClient.normalizeTab(AssetsTabKind.mcp, const [
        {
          'statuses': [
            {'name': 'fetch', 'status': 'error', 'error': 'no config'},
          ],
        },
      ]);
      expect(asList.entries.single.name, 'fetch');
      expect(asList.entries.single.badge, 'error');
    });

    test('hooks：matcher/command/event/enabled 全链解析', () {
      final r = AssetsClient.normalizeTab(AssetsTabKind.hooks, const [
        {
          'hooks': [
            {
              'id': 'h1',
              'event': 'PreToolUse',
              'matcher': 'Bash',
              'command': 'echo hi',
              'enabled': true,
            },
          ],
          'hooksEnabled': true,
        },
      ]);
      expect(r.entries.single.name, 'Bash');
      expect(r.entries.single.description, 'echo hi');
      expect(r.entries.single.badge, 'PreToolUse');
      expect(r.entries.single.enabled, isTrue);
    });

    test('memory：顶层数组与 {workspaces:[...]} 壳两形状', () {
      final flat = AssetsClient.normalizeTab(AssetsTabKind.memory, const [
        [
          {'label': '项目 A', 'files': [1, 2, 3]},
        ],
      ]);
      expect(flat.entries.single.name, '项目 A');
      expect(flat.entries.single.description, '3 files');

      final wrapped = AssetsClient.normalizeTab(AssetsTabKind.memory, const [
        {
          'workspaces': [
            {'id': 'w2', 'files': []},
          ],
        },
      ]);
      expect(wrapped.entries.single.name, 'w2');
    });

    test('完全不像（无已知容器键）→ degraded 空列表不抛（反例对照）', () {
      for (final tab in AssetsTabKind.values) {
        final r = AssetsClient.normalizeTab(tab, const [
          {'unexpected': 'shape'},
        ]);
        expect(r.entries, isEmpty, reason: tab.name);
        expect(r.degraded, isTrue, reason: tab.name);
      }
    });

    test('commands：user/plugin/内置三容器合并', () {
      final r = AssetsClient.normalizeTab(AssetsTabKind.commands, const [
        {
          'commands': [
            {'name': 'builtin-x', 'description': '内建'},
          ],
          'userCommands': [
            {'id': 'my-cmd', 'enabled': true},
          ],
          'pluginCommands': [
            {'name': 'plugin-y'},
          ],
        },
      ]);
      expect(r.entries, hasLength(3));
      expect(r.entries[0].badge, 'builtin');
      expect(r.entries[1].name, 'my-cmd');
      expect(r.entries[1].enabled, isTrue);
      expect(r.entries[2].badge, 'plugin');
    });
  });

  group('P1-8 AssetsClient.fetchTab（scripted_bridge，每频道独立）', () {
    test('happy：频道/方法/参数三断言', () async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'skills': [
              {'name': 'pdf'},
            ],
          },
        ],
      ]);
      final r = await AssetsClient(bridge.bridge).fetchTab(
        AssetsTabKind.skills,
        workspacePath: '/w',
      );
      expect(bridge.commands, hasLength(1));
      final req = requestOf(bridge.commands.single);
      expect(req.channel, 'skills');
      expect(req.method, 'list');
      expect(req.params, {'workspacePath': '/w'});
      expect(r.entries.single.name, 'pdf');
    });

    test('no-services 降级：抛 AssetsFetchException 不拖垮调用方', () async {
      final bridge = ScriptedBridge(
        script: const [
          [],
        ],
        errors: {0: 'no-services'},
      );
      await expectLater(
        AssetsClient(bridge.bridge).fetchTab(AssetsTabKind.memory),
        throwsA(isA<AssetsFetchException>()),
      );
      expect(bridge.commands, hasLength(1));
    });

    test('空 workspace：必填四频道不发包，返回 needsWorkspace', () async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'userCommands': [
              {'id': 'deploy'},
            ],
          },
        ],
      ]);
      for (final tab in [
        AssetsTabKind.skills,
        AssetsTabKind.subagents,
        AssetsTabKind.mcp,
        AssetsTabKind.hooks,
      ]) {
        final r = await AssetsClient(bridge.bridge).fetchTab(tab);
        expect(r.needsWorkspace, isTrue, reason: tab.name);
        expect(r.entries, isEmpty, reason: tab.name);
      }
      expect(bridge.commands, isEmpty);
    });

    test('空 workspace：commands/memory 按各自签名照常调用', () async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'userCommands': [
              {'id': 'deploy'},
            ],
          },
        ],
      ]);
      final cmd = await AssetsClient(
        bridge.bridge,
      ).fetchTab(AssetsTabKind.commands);
      expect(cmd.needsWorkspace, isFalse);
      expect(cmd.entries.single.name, 'deploy');
      expect(bridge.commands, hasLength(1));
      expect(bridge.commands.single['s'], 'commandsService');
      // 参数省略 workspacePath（该频道可选）。
      expect(requestOf(bridge.commands.single).params, isEmpty);
    });
  });

  group('P1-8 AssetsPage widget（单服务失败隔离）', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      ScriptedBridge bridge,
    ) async {
      final container = ProviderContainer();
      // 活动会话工作区（skills 等 Tab 需要 workspacePath）。
      container.read(sessionIndexProvider.notifier).upsertTasks('d1', [
        SessionState(sessionId: 's1', workspacePath: '/ws/demo'),
      ]);
      container.read(activeSessionProvider.notifier).report('d1', 's1');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AssetsPage(device: _device(), bridge: bridge.bridge),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('六 Tab 渲染 + 首Tab happy + 命令参数带 workspacePath',
        (tester) async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'skills': [
              {'name': 'pdf', 'description': 'PDF 处理', 'enabled': true},
            ],
          },
        ],
      ]);
      final container = await pump(tester, bridge);
      addTearDown(container.dispose);

      expect(find.text('技能'), findsOneWidget);
      expect(find.text('命令'), findsOneWidget);
      expect(find.text('子代理'), findsOneWidget);
      expect(find.text('MCP'), findsOneWidget);
      expect(find.text('钩子'), findsOneWidget);
      expect(find.text('记忆'), findsOneWidget);

      expect(find.text('pdf'), findsOneWidget);
      expect(find.text('PDF 处理'), findsOneWidget);
      expect(bridge.commands, hasLength(1));
      final req = requestOf(bridge.commands.single);
      expect(req.channel, 'skills');
      expect(req.params, {'workspacePath': '/ws/demo'});
    });

    testWidgets('单服务失败隔离：skills 红不影响 commands Tab', (tester) async {
      final bridge = ScriptedBridge(
        script: const [
          [],
          [
            {
              'userCommands': [
                {'id': 'deploy', 'enabled': true},
              ],
            },
          ],
        ],
        errors: {0: 'no-services'},
      );
      final container = await pump(tester, bridge);
      addTearDown(container.dispose);

      // 首Tab（skills）不可用。
      expect(find.text('技能 服务不可用'), findsOneWidget);

      // 切到 commands Tab 正常渲染（隔离成立）。
      await tester.tap(find.text('命令'));
      await tester.pumpAndSettle();
      expect(find.text('deploy'), findsOneWidget);
      expect(bridge.commands, hasLength(2));
      expect(bridge.commands[1]['s'], 'commandsService');

      // 切回 skills 仍是错误态 + 可重试。
      await tester.tap(find.text('技能'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assets-tab-retry-skills')), findsOneWidget);
    });

    testWidgets('空 workspace：必填 Tab 占位「进入会话后可用」且零命令', (tester) async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'userCommands': [
              {'id': 'deploy'},
            ],
          },
        ],
      ]);
      final container = ProviderContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AssetsPage(device: _device(), bridge: bridge.bridge),
          ),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(container.dispose);

      expect(find.text('进入会话后可用'), findsWidgets);
      expect(find.text('技能 服务不可用'), findsNothing);
      expect(bridge.commands, isEmpty);

      // commands 不依赖 workspace，切过去照常拉取。
      await tester.tap(find.text('命令'));
      await tester.pumpAndSettle();
      expect(find.text('deploy'), findsOneWidget);
      expect(bridge.commands, hasLength(1));
      expect(bridge.commands.single['s'], 'commandsService');
    });

    testWidgets('workspace 由空变有：必填 Tab 自动重拉', (tester) async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'skills': [
              {'name': 'pdf'},
            ],
          },
        ],
      ]);
      final container = ProviderContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AssetsPage(device: _device(), bridge: bridge.bridge),
          ),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(container.dispose);
      expect(find.text('进入会话后可用'), findsWidgets);
      expect(bridge.commands, isEmpty);

      // 会话索引到位（workspace 由空变有）→ 页面重建 + Tab 自动重拉。
      container.read(sessionIndexProvider.notifier).upsertTasks('d1', [
        SessionState(sessionId: 's1', workspacePath: '/ws/demo'),
      ]);
      container.read(activeSessionProvider.notifier).report('d1', 's1');
      await tester.pumpAndSettle();

      expect(find.text('pdf'), findsOneWidget);
      expect(bridge.commands, hasLength(1));
      expect(bridge.commands.single['s'], 'skillsService');
      expect(
        requestOf(bridge.commands.single).params,
        {'workspacePath': '/ws/demo'},
      );
    });

    testWidgets('hostWorkspacePath 回退：sessionIndex 无 workspace 也能拉取', (tester) async {
      final bridge = ScriptedBridge(script: const [
        [
          {
            'skills': [
              {'name': 'pdf'},
            ],
          },
        ],
      ]);
      final container = ProviderContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AssetsPage(
              device: _device(),
              bridge: bridge.bridge,
              hostWorkspacePath: '/host/ws',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(container.dispose);

      expect(find.text('pdf'), findsOneWidget);
      expect(find.text('进入会话后可用'), findsNothing);
      expect(
        requestOf(bridge.commands.single).params,
        {'workspacePath': '/host/ws'},
      );
    });
  });
}
