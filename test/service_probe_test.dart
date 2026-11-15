import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/service_probe.dart';

import 'scripted_bridge.dart';

void main() {
  Map<String, dynamic> dumpPayload({
    List<String> keys = const [
      'fileService',
      'zcodeAgentService',
      'offPeakTaskService',
      'usageStatsService',
    ],
    Map<String, Object> checks = const {},
  }) => {'keys': keys, 'checks': checks};

  test('清单单一来源：39 候选键无重复，红线服务零方法面，实调仅两个', () {
    expect(ServiceProbe.candidateKeys, hasLength(39));
    expect(ServiceProbe.candidateKeys.toSet(), hasLength(39));
    const redlines = [
      'credentialService',
      'terminalService',
      'providerProvisioningTargetService',
    ];
    for (final redline in redlines) {
      expect(ServiceProbe.candidateKeys, contains(redline));
      expect(ServiceProbe.methodChecks.containsKey(redline), isFalse);
    }
    expect(ServiceProbe.liveCalls, hasLength(2));
    expect(
      ServiceProbe.liveCalls.map((c) => '${c.service}.${c.method}').toList(),
      const [
        'offPeakTaskService.getCodingPlanSupport',
        'usageStatsService.getEntitlementSnapshot',
      ],
    );
    expect(
      ServiceProbe.methodChecks['zcodeTaskService'],
      containsAll(['respondPermission', 'respondElicitation']),
    );
    expect(
      ServiceProbe.methodChecks['windowControllerService'],
      contains('mutateTask'),
    );
    expect(ServiceProbe.methodChecks['settingService'], contains('get'));
  });

  test('P6-1 候选服务清单：24 个无重复，L2 后半八频道主名逐一在册且带方法面', () {
    expect(ServiceProbe.candidateServices, hasLength(24));
    expect(ServiceProbe.candidateServices.toSet(), hasLength(24));
    // L2 后半（P1-4/7/8）八频道为单候选，主名与 rpc_bridge 频道表追加行
    // 一一对应（L7 纪律：候选清单改动按数核对）。
    const l2SecondHalfPrimaries = [
      'zcodeTaskService',
      'gitService',
      'skillsService',
      'commandsService',
      'subagentsService',
      'mcpSyncService',
      'hooksService',
      'memoryService',
    ];
    for (final svc in l2SecondHalfPrimaries) {
      expect(ServiceProbe.candidateServices, contains(svc));
      expect(ServiceProbe.methodChecks.containsKey(svc), isTrue,
          reason: '$svc 应有方法面检查');
    }
    // 既有别名组不被增补破坏（抽三组代表）。
    expect(ServiceProbe.candidateServices, containsAll(<String>[
      'offPeakTaskService',
      'offPeakQueueService',
      'codingPlanSubscriptionService',
      'settingService',
      'settingsService',
    ]));
  });

  test('dump 成功 + 双实调 ok：命令形态与报告齐整', () async {
    final bridge = ScriptedBridge(
      script: [
        [
          dumpPayload(
            checks: {
              'usageStatsService.getEntitlementSnapshot': true,
              'windowControllerService.mutateTask': false,
              'zcodeTaskService.respondPermission': 'no-svc',
            },
          ),
        ],
        [
          {'supported': true},
        ],
        [
          {'plan': 'team'},
        ],
      ],
    );
    final report = await ServiceProbe.run(bridge.bridge);

    expect(bridge.commands, hasLength(3));
    final dumpCmd = bridge.commands[0];
    expect(dumpCmd['s'], '__zrProbe');
    expect(dumpCmd['m'], 'dump');
    final dumpArgs = argsOf(dumpCmd);
    expect(dumpArgs, hasLength(1));
    final checklist = dumpArgs.first as List;
    expect(checklist.first, {
      's': 'usageStatsService',
      'm': ServiceProbe.methodChecks['usageStatsService'],
    });
    expect(argsOf(bridge.commands[1]), isEmpty);
    expect(argsOf(bridge.commands[2]), isEmpty);
    expect(bridge.commands[1]['s'], 'offPeakTaskService');
    expect(bridge.commands[2]['s'], 'usageStatsService');

    final dump = report['dump'] as Map<String, dynamic>;
    expect(dump['ok'], isTrue);
    expect(dump['keys'], contains('usageStatsService'));
    expect((dump['missing'] as List), hasLength(35));
    expect(dump['missing'], contains('credentialService'));
    expect(dump['checks'], {
      'usageStatsService.getEntitlementSnapshot': true,
      'windowControllerService.mutateTask': false,
      'zcodeTaskService.respondPermission': 'no-svc',
    });
    final calls = report['liveCalls'] as List;
    expect(calls, hasLength(2));
    expect(calls[0]['ok'], isTrue);
    expect(calls[1]['ok'], isTrue);
    expect(report['device'], 'd1');
  });

  test('dump 失败（no-services）+ 实调 no-method：失败落进报告不抛', () async {
    final bridge = ScriptedBridge(
      script: const [
        [],
        [],
        [],
      ],
      errors: {0: 'no-services', 1: 'no-method'},
    );
    final report = await ServiceProbe.run(
      bridge.bridge,
      noServicesAttempts: 1,
    );

    final dump = report['dump'] as Map<String, dynamic>;
    expect(dump['ok'], isFalse);
    expect(dump['error'], contains('no-services'));
    final calls = report['liveCalls'] as List;
    expect(calls[0]['ok'], isFalse);
    expect(calls[0]['error'], contains('no-method'));
    expect(calls[1]['ok'], isTrue);
  });

  test('实调超时（脚本耗尽不回喂）：报告记 Timeout，不抛不卡', () async {
    final bridge = ScriptedBridge(
      script: [
        [dumpPayload()],
      ],
      respondEmptyOnExhausted: false,
    );
    final report = await ServiceProbe.run(
      bridge.bridge,
      timeout: const Duration(milliseconds: 30),
    );

    expect((report['dump'] as Map)['ok'], isTrue);
    final calls = report['liveCalls'] as List;
    expect(calls[0]['ok'], isFalse);
    expect(calls[0]['error'], contains('Timeout'));
    expect(calls[1]['ok'], isFalse);
    expect(calls[1]['error'], contains('Timeout'));
    expect(
      (calls[0]['error'] as String).length,
      lessThanOrEqualTo(ServiceProbe.errorMaxChars),
    );
  });

  test('错误文本截断 200 字符', () async {
    final bridge = ScriptedBridge(
      script: const [
        [],
      ],
      errors: {0: 'x' * 500},
    );
    final report = await ServiceProbe.run(
      bridge.bridge,
      noServicesAttempts: 1,
    );
    final dump = report['dump'] as Map<String, dynamic>;
    expect(dump['ok'], isFalse);
    expect((dump['error'] as String).length, ServiceProbe.errorMaxChars);
  });

  test('no-services 退避重试：容器晚挂载后 dump 补偿成功', () async {
    final bridge = ScriptedBridge(
      script: [
        [],
        [],
        [dumpPayload()],
        [{'supported': true}],
        [{}],
      ],
      errors: {0: 'no-services', 1: 'no-services'},
    );
    final report = await ServiceProbe.run(
      bridge.bridge,
      retryDelay: Duration.zero,
    );

    expect(bridge.commands, hasLength(5));
    expect((report['dump'] as Map)['ok'], isTrue);
    final calls = report['liveCalls'] as List;
    expect(calls[0]['ok'], isTrue);
    expect(calls[1]['ok'], isTrue);
  });

  test('实调 no-services 也重试：页面重载竞态自愈', () async {
    final bridge = ScriptedBridge(
      script: [
        [dumpPayload()],
        [],
        [{'supported': true}],
        [{}],
      ],
      errors: {1: 'no-services'},
    );
    final report = await ServiceProbe.run(
      bridge.bridge,
      retryDelay: Duration.zero,
    );

    expect(bridge.commands, hasLength(4));
    final calls = report['liveCalls'] as List;
    expect(calls[0]['ok'], isTrue);
    expect(calls[1]['ok'], isTrue);
  });

  test('no-method / 超时不消耗重试次数（一次性结论）', () async {
    final bridge = ScriptedBridge(
      script: const [
        [],
        [],
        [],
      ],
      errors: {0: 'no-method', 1: 'RpcTimeoutException: Timeout'},
    );
    final report = await ServiceProbe.run(
      bridge.bridge,
      retryDelay: Duration.zero,
    );

    expect(bridge.commands, hasLength(3));
    expect((report['dump'] as Map)['error'], contains('no-method'));
    final calls = report['liveCalls'] as List;
    expect(calls[0]['ok'], isFalse);
    expect(calls[0]['error'], contains('Timeout'));
    expect(calls[1]['ok'], isTrue);
  });

  group('checkReady（plan 021 轻量就绪检查）', () {
    test('容器在 → true，且只发一次空清单 dump', () async {
      final bridge = ScriptedBridge(
        script: [
          [
            dumpPayload(keys: const ['usageStatsService']),
          ],
        ],
      );
      expect(await ServiceProbe.checkReady(bridge.bridge), isTrue);
      expect(bridge.commands, hasLength(1));
      expect(bridge.commands.single['s'], '__zrProbe');
      expect(bridge.commands.single['m'], 'dump');
      expect(argsOf(bridge.commands.single), [
        <Object?>[],
      ]);
    });

    test('页面明确回 no-services → false', () async {
      final bridge = ScriptedBridge(
        script: const [],
        errors: {0: 'no-services'},
      );
      expect(await ServiceProbe.checkReady(bridge.bridge), isFalse);
    });

    test('超时/其它错误 → null（不能结论）', () async {
      final bridge = ScriptedBridge(
        script: const [],
        respondEmptyOnExhausted: false,
      );
      expect(
        await ServiceProbe.checkReady(
          bridge.bridge,
          timeout: const Duration(milliseconds: 50),
        ),
        isNull,
      );
    });
  });

  group('checkToolbox 定点检查（P1-4）', () {
    test('dump 可用 → 按方法检查结果逐服务判定', () async {
      final bridge = ScriptedBridge(
        script: [
          [
            dumpPayload(
              checks: {
                'usageStatsService.getAppUsageSnapshot': true,
                'usageStatsService.getEntitlementSnapshot': false,
                'codingPlanSubscriptionService.getManualClaimPlanPreviews':
                    'no-svc',
                'offPeakTaskService.list': true,
                'zcodeAgentService.listAllAutomations': false,
                'zcodeAgentService.listAutomationRuns': true,
                'providerSettingsService.getView': true,
                'modelSelectionService.getView': false,
              },
            ),
          ],
        ],
      );
      final result = await ServiceProbe.checkToolbox(bridge.bridge);
      expect(result, {
        'usageStatsService': isTrue,
        'codingPlanSubscriptionService': isFalse,
        'offPeakTaskService': isTrue,
        'zcodeAgentService': isTrue,
        'providerSettingsService': isTrue,
        'modelSelectionService': isFalse,
      });
    });

    test('dump 不可用（no-services）→ null 由调用方兜底', () async {
      final bridge = ScriptedBridge(
        script: const [],
        errors: {0: 'no-services'},
      );
      expect(await ServiceProbe.checkToolbox(bridge.bridge), isNull);
    });
  });
}
