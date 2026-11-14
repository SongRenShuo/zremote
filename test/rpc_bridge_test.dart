import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/rpc_bridge.dart';
import 'package:zremote/services/rpc_dispatch.dart';

class _FakeDispatch implements RpcDispatch {
  final List<Map<String, Object?>> commands = [];

  @override
  int get port => 47832;

  @override
  Future<void> start() async {}

  @override
  void push(Map<String, Object?> command) => commands.add(command);

  @override
  void dispose() {}
}

({int id, String svc, String method, Object? args}) callOf(
  Map<String, Object?> command,
) {
  final args = jsonDecode(utf8.decode(base64Decode(command['a']! as String)));
  return (
    id: command['i']! as int,
    svc: command['s']! as String,
    method: command['m']! as String,
    args: args,
  );
}

void main() {
  test('call 派发：argsB64 内含 service/method/参数', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.call('zcode-agent', 'listAllAutomations');
    await pumpEventQueue();
    final c = callOf(dispatch.commands.single);
    expect(c.svc, 'zcodeAgentService');
    expect(c.method, 'listAllAutomations');
    expect(c.args, isEmpty);
    bridge.onSvcResult(
      jsonEncode({
        'i': c.id,
        'ok': true,
        'r': jsonEncode([
          {'automationId': 'a1'},
        ]),
      }),
    );
    final response = await pending;
    expect(response.id, c.id);
    expect(response.firstObject, {'automationId': 'a1'});
  });

  test('未知频道 → RpcNotReadyException（不进派发层）', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    await expectLater(
      bridge.call('no-such-channel', 'x'),
      throwsA(isA<RpcNotReadyException>()),
    );
    expect(dispatch.commands, isEmpty);
  });

  test('字符串参数（taskId）进 args 首元素；超时摘除 pending', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.call(
      'off-peak-task',
      'pauseTask',
      params: 't1',
      timeout: const Duration(milliseconds: 50),
    );
    await pumpEventQueue();
    final c = callOf(dispatch.commands.single);
    expect(c.method, 'pauseTask');
    expect(c.args, ['t1']);
    await expectLater(pending, throwsA(isA<RpcTimeoutException>()));
    bridge.onSvcResult(jsonEncode({'i': c.id, 'ok': true, 'r': 'null'}));
  });

  test('对象参数进 args 首元素；返回数组原样入 values', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.call(
      'zcode-agent',
      'createAutomation',
      params: {'title': "It's 中文", 'n': 1},
    );
    await pumpEventQueue();
    final c = callOf(dispatch.commands.single);
    expect(c.args, [
      {'title': "It's 中文", 'n': 1},
    ]);
    bridge.onSvcResult(
      jsonEncode({
        'i': c.id,
        'ok': true,
        'r': jsonEncode([
          {'automationId': 'a1'},
          {'automationId': 'a2'},
        ]),
      }),
    );
    final response = await pending;
    expect(response.values, hasLength(2));
  });

  test('host 失败（promise reject）→ RpcRemoteException 携带消息', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.call('zcode-agent', 'setAutomationEnabled');
    await pumpEventQueue();
    final c = callOf(dispatch.commands.single);
    bridge.onSvcResult(
      jsonEncode({
        'i': c.id,
        'ok': false,
        'e': 'Provided value cannot be bound to SQLite parameter 4.',
      }),
    );
    await expectLater(
      pending,
      throwsA(
        isA<RpcRemoteException>().having(
          (e) => e.message,
          'message',
          contains('SQLite'),
        ),
      ),
    );
  });

  test('void 返回（r=null）→ 空 values；截断载荷给 zrTruncated 标记', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final p1 = bridge.call('off-peak-task', 'deleteTask', params: 't9');
    await pumpEventQueue();
    final c1 = callOf(dispatch.commands[0]);
    bridge.onSvcResult(jsonEncode({'i': c1.id, 'ok': true}));
    final r1 = await p1;
    expect(r1.values, isEmpty);

    final p2 = bridge.call('off-peak-task', 'deleteTask', params: 't8');
    await pumpEventQueue();
    final c2 = callOf(dispatch.commands[1]);
    bridge.onSvcResult(
      jsonEncode({'i': c2.id, 'ok': true, 'r': '{"broken": tr'}),
    );
    final r2 = await p2;
    expect((r2.values.single as Map)['zrTruncated'], isTrue);
  });

  test('重复/无关 id 不炸：迟到回执与双重投递静默忽略', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.call('zcode-agent', 'listAllAutomations');
    await pumpEventQueue();
    final c = callOf(dispatch.commands.single);
    bridge.onSvcResult(jsonEncode({'i': 999, 'ok': true, 'r': '[]'}));
    bridge.onSvcResult(jsonEncode({'i': c.id, 'ok': true, 'r': '[]'}));
    bridge.onSvcResult(jsonEncode({'i': c.id, 'ok': true, 'r': '[]'}));
    final response = await pending;
    expect(response.values, isEmpty);
  });

  test('dispose：在途调用 fail-fast', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.call('zcode-agent', 'listAllAutomations');
    await Future<void>.delayed(Duration.zero);
    bridge.dispose();
    await expectLater(pending, throwsA(isA<RpcNotReadyException>()));
  });

  test('callArgs：多参进 args 数组（3.14 两参 updateTask）', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    final pending = bridge.callArgs(
      'off-peak-task',
      'updateTask',
      args: [
        't-1',
        {'title': '改名'},
      ],
    );
    await pumpEventQueue();
    final c = callOf(dispatch.commands.single);
    expect(c.svc, 'offPeakTaskService');
    expect(c.method, 'updateTask');
    expect(c.args, [
      't-1',
      {'title': '改名'},
    ]);
    bridge.onSvcResult(
      jsonEncode({
        'i': c.id,
        'ok': true,
        'r': jsonEncode([
          {'offPeakTaskId': 't-1'},
        ]),
      }),
    );
    final response = await pending;
    expect(response.firstObject, {'offPeakTaskId': 't-1'});
  });

  test('callArgs：未知频道同样 RpcNotReadyException', () async {
    final dispatch = _FakeDispatch();
    final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
    await expectLater(
      bridge.callArgs('no-such-channel', 'x', args: const []),
      throwsA(isA<RpcNotReadyException>()),
    );
    expect(dispatch.commands, isEmpty);
  });

  group('offPeakUpdateTwoArgs 代际探测（3.14 对齐）', () {
    test('getCodingPlanSupport 成功 → 新代（true）且缓存', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final probing = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      expect(c.svc, 'offPeakTaskService');
      expect(c.method, 'getCodingPlanSupport');
      bridge.onSvcResult(
        jsonEncode({
          'i': c.id,
          'ok': true,
          'r': jsonEncode([
            {'supported': false},
          ]),
        }),
      );
      expect(await probing, isTrue);
      expect(await bridge.offPeakUpdateTwoArgs(), isTrue);
      expect(dispatch.commands, hasLength(1));
    });

    test('host 业务报错（方法在）→ 新代（true）', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final probing = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      bridge.onSvcResult(
        jsonEncode({'i': c.id, 'ok': false, 'e': 'subscription unavailable'}),
      );
      expect(await probing, isTrue);
    });

    test('no-method → 旧代（false）且缓存（别名一并探测）', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final probing = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      // 主名 no-method → 换别名再探一次（P1-3），别名也 no-method 才判定。
      expect(dispatch.commands, hasLength(2));
      for (final command in dispatch.commands) {
        bridge.onSvcResult(
          jsonEncode({'i': callOf(command).id, 'ok': false, 'e': 'no-method'}),
        );
      }
      expect(await probing, isFalse);
      expect(await bridge.offPeakUpdateTwoArgs(), isFalse);
      expect(dispatch.commands, hasLength(2));
    });

    test('no-services（页面未就绪）→ 默认旧代且不缓存，下次再探', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final probing = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      // off-peak-task 频道有 2 个候选（P1-3），全部 no-services。
      expect(dispatch.commands, hasLength(2));
      for (final command in dispatch.commands) {
        bridge.onSvcResult(
          jsonEncode({'i': callOf(command).id, 'ok': false, 'e': 'no-services'}),
        );
      }
      expect(await probing, isFalse);
      final probing2 = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      expect(dispatch.commands, hasLength(4));
      final c2 = callOf(dispatch.commands[2]);
      bridge.onSvcResult(jsonEncode({'i': c2.id, 'ok': true, 'r': 'null'}));
      expect(await probing2, isTrue);
    });

    test('探测超时（传输层失败）→ 默认旧代且不缓存', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final probing = bridge.offPeakUpdateTwoArgs(
        timeout: const Duration(milliseconds: 50),
      );
      await pumpEventQueue();
      expect(await probing, isFalse);
      final probing2 = bridge.offPeakUpdateTwoArgs(
        timeout: const Duration(milliseconds: 50),
      );
      await pumpEventQueue();
      expect(dispatch.commands, hasLength(2));
      expect(await probing2, isFalse);
    });

    test('resetOffPeakProbe：页面重载后缓存失效重探', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final probing = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      bridge.onSvcResult(
        jsonEncode({
          'i': c.id,
          'ok': true,
          'r': jsonEncode([
            {'supported': true},
          ]),
        }),
      );
      expect(await probing, isTrue);
      bridge.resetOffPeakProbe();
      final probing2 = bridge.offPeakUpdateTwoArgs();
      await pumpEventQueue();
      // 重探：主名 no-method 后换别名再试（P1-3），共 2 条。
      expect(dispatch.commands, hasLength(3));
      for (var i = 1; i < dispatch.commands.length; i++) {
        bridge.onSvcResult(
          jsonEncode({
            'i': callOf(dispatch.commands[i]).id,
            'ok': false,
            'e': 'no-method',
          }),
        );
      }
      expect(await probing2, isFalse);
    });
  });

  group('firstObjectDeep 外壳剥离（P2-1）', () {
    test('单键 Map 包装逐层剥离', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final pending = bridge.call('usage-stats', 'getAppUsageSnapshot');
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      bridge.onSvcResult(
        jsonEncode({
          'i': c.id,
          'ok': true,
          'r': jsonEncode([
            {
              'snapshot': {
                'wrapper': {
                  'summary': {'totalTokens': 5},
                },
              },
            },
          ]),
        }),
      );
      final response = await pending;
      expect(response.firstObject, isNull);
      expect(response.firstObjectDeep, {
        'summary': {'totalTokens': 5},
      });
    });

    test('非包装对象原样返回', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final pending = bridge.call('usage-stats', 'getAppUsageSnapshot');
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      bridge.onSvcResult(
        jsonEncode({
          'i': c.id,
          'ok': true,
          'r': jsonEncode([
            {
              'summary': {'totalTokens': 1},
              'models': [],
            },
          ]),
        }),
      );
      final response = await pending;
      expect(response.firstObjectDeep, response.firstObject);
    });

    test('debugText 截断原始报文', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final pending = bridge.call('usage-stats', 'getAppUsageSnapshot');
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      final longValue = 'x' * 500;
      bridge.onSvcResult(
        jsonEncode({'i': c.id, 'ok': true, 'r': jsonEncode([longValue])}),
      );
      final response = await pending;
      expect(response.debugText().length, 300);
    });
  });

  group('服务别名解析（P1-3）', () {
    test('主名 no-services 后别名成功 → 结果缓存，下次直达别名', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final p1 = bridge.call('usage-stats', 'getAppUsageSnapshot');
      await pumpEventQueue();
      expect(callOf(dispatch.commands[0]).svc, 'usageStatsService');
      bridge.onSvcResult(
        jsonEncode({'i': callOf(dispatch.commands[0]).id, 'ok': false,
          'e': 'no-services'}),
      );
      await pumpEventQueue();
      expect(callOf(dispatch.commands[1]).svc, 'usageService');
      bridge.onSvcResult(
        jsonEncode({
          'i': callOf(dispatch.commands[1]).id,
          'ok': true,
          'r': jsonEncode([
            {'range': 'all'},
          ]),
        }),
      );
      final r1 = await p1;
      expect(r1.firstObject, {'range': 'all'});

      final p2 = bridge.call('usage-stats', 'getAppUsageSnapshot');
      await pumpEventQueue();
      expect(dispatch.commands, hasLength(3));
      expect(callOf(dispatch.commands[2]).svc, 'usageService');
      bridge.onSvcResult(
        jsonEncode({'i': callOf(dispatch.commands[2]).id, 'ok': true, 'r': '[]'}),
      );
      await p2;
      expect(bridge.resolvedServiceOf('usage-stats'), 'usageService');
    });

    test('resetServiceResolution 清除别名缓存', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      bridge.resetServiceResolution();
      expect(bridge.resolvedServiceOf('usage-stats'), 'usageStatsService');
    });

    test('业务错误（非 no-services/no-method）不触发别名探测', () async {
      final dispatch = _FakeDispatch();
      final bridge = RpcBridge(deviceId: 'd1', dispatch: dispatch);
      final pending = bridge.call('usage-stats', 'getAppUsageSnapshot');
      await pumpEventQueue();
      expect(dispatch.commands, hasLength(1));
      bridge.onSvcResult(
        jsonEncode({'i': callOf(dispatch.commands[0]).id, 'ok': false,
          'e': 'sqlite busy'}),
      );
      await expectLater(pending, throwsA(isA<RpcRemoteException>()));
      expect(dispatch.commands, hasLength(1));
    });
  });

  group('LoopbackDispatchServer（真 socket，页面侧模拟）', () {
    test('长轮询：命令即时整批送达 + 空批 CORS 头', () async {
      final server = LoopbackDispatchServer(
        hold: const Duration(milliseconds: 200),
      );
      addTearDown(server.dispose);
      await server.start();
      expect(server.port, greaterThan(0));
      final client = HttpClient();
      addTearDown(client.close);

      final poll = client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}${server.pollPath}'),
      );
      final held = await poll.then((r) => r.close()).then((r) async {
        return (r, await r.transform(const Utf8Decoder()).join());
      });
      expect(held.$2, '{"c":[]}');
      expect(held.$1.headers.value('Access-Control-Allow-Origin'), '*');

      final pendingPoll = _poll(client, server.port, server.pollPath);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      server.push({
        'i': 7,
        's': 'zcodeAgentService',
        'm': 'listAllAutomations',
        'a': 'W10=',
      });
      final body = await pendingPoll;
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final batch = decoded['c'] as List;
      expect(batch, hasLength(1));
      expect(batch.first['i'], 7);
      expect(batch.first['m'], 'listAllAutomations');
    });

    test('OPTIONS 预检：CORS + Private Network Access 放行', () async {
      final server = LoopbackDispatchServer();
      addTearDown(server.dispose);
      await server.start();
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:${server.port}${server.pollPath}'),
      );
      final response = await request.close();
      expect(response.statusCode, 204);
      expect(
        response.headers.value('Access-Control-Allow-Private-Network'),
        'true',
      );
      expect(response.headers.value('Access-Control-Allow-Origin'), '*');
    });

    test('404 兜底 + 重复 start 幂等', () async {
      final server = LoopbackDispatchServer();
      addTearDown(server.dispose);
      await server.start();
      final port = server.port;
      await server.start();
      expect(server.port, port);
      final client = HttpClient();
      addTearDown(client.close);
      final response = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/nope'))
          .then((r) => r.close());
      expect(response.statusCode, 404);
      final tokenless = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/poll'))
          .then((r) => r.close());
      expect(tokenless.statusCode, 404);
    });
  });

  group('服务就绪回调（plan 021）', () {
    test('调用成功 → onServiceState(true)', () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      final pending = bridge.call('zcode-agent', 'listAllAutomations');
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      bridge.onSvcResult(jsonEncode({'i': c.id, 'ok': true, 'r': '[]'}));
      await pending;
      expect(states, [true]);
    });

    test('no-services → onServiceState(false) 且调用方收到 RpcRemoteException',
        () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      final pending = bridge.call('zcode-agent', 'listAllAutomations');
      await pumpEventQueue();
      // 别名候选（P1-3）：所有候选都 no-services 才抛错。
      expect(dispatch.commands, hasLength(3));
      for (final command in dispatch.commands) {
        bridge.onSvcResult(
          jsonEncode({'i': callOf(command).id, 'ok': false, 'e': 'no-services'}),
        );
      }
      await expectLater(pending, throwsA(isA<RpcRemoteException>()));
      expect(states, [false]);
    });

    test('其它 host 错误不改变就绪态', () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      final pending = bridge.call('zcode-agent', 'listAllAutomations');
      await pumpEventQueue();
      final c = callOf(dispatch.commands.single);
      bridge.onSvcResult(
        jsonEncode({'i': c.id, 'ok': false, 'e': 'sqlite busy'}),
      );
      await expectLater(pending, throwsA(isA<RpcRemoteException>()));
      expect(states, isEmpty);
    });

    test('先 no-services 后成功 → false 后 true（可恢复）', () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      final p1 = bridge.call('zcode-agent', 'listAllAutomations');
      await pumpEventQueue();
      for (final command in dispatch.commands) {
        bridge.onSvcResult(
          jsonEncode({'i': callOf(command).id, 'ok': false, 'e': 'no-services'}),
        );
      }
      await expectLater(p1, throwsA(isA<RpcRemoteException>()));
      expect(states, [false]);

      final p2 = bridge.call('zcode-agent', 'listAllAutomations');
      await pumpEventQueue();
      // p1 已占 3 条命令；p2 先主名（no-services），再别名成功。
      expect(dispatch.commands, hasLength(5));
      bridge.onSvcResult(
        jsonEncode({
          'i': callOf(dispatch.commands[3]).id,
          'ok': false,
          'e': 'no-services',
        }),
      );
      bridge.onSvcResult(
        jsonEncode({'i': callOf(dispatch.commands[4]).id, 'ok': true, 'r': '[]'}),
      );
      await p2;
      // 别名成功同样上报就绪。
      expect(states, [false, true]);
    });

    test('超时不改变就绪态', () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      await expectLater(
        bridge.call(
          'zcode-agent',
          'listAllAutomations',
          timeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<RpcTimeoutException>()),
      );
      expect(states, isEmpty);
    });

    test('zr-probe 的 no-services 不触发回调（探针自行上报）', () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      final pending = bridge.callArgs('zr-probe', 'dump', args: const []);
      await pumpEventQueue();
      bridge.onSvcResult(
        jsonEncode({
          'i': callOf(dispatch.commands.single).id,
          'ok': false,
          'e': 'no-services',
        }),
      );
      await expectLater(pending, throwsA(isA<RpcRemoteException>()));
      expect(states, isEmpty);
    });

    test('zr-captcha 成功不触发回调（伪服务不证明容器在）', () async {
      final dispatch = _FakeDispatch();
      final states = <bool>[];
      final bridge = RpcBridge(
        deviceId: 'd1',
        dispatch: dispatch,
        onServiceState: states.add,
      );
      final pending = bridge.call('zr-captcha', 'run');
      await pumpEventQueue();
      bridge.onSvcResult(
        jsonEncode({
          'i': callOf(dispatch.commands.single).id,
          'ok': true,
          'r': '{"ok":true}',
        }),
      );
      await pending;
      expect(states, isEmpty);
    });
  });
}

Future<String> _poll(
  HttpClient client,
  int port,
  String pollPath,
) async {
  final request = await client.getUrl(
    Uri.parse('http://127.0.0.1:$port$pollPath'),
  );
  final response = await request.close();
  return response.transform(const Utf8Decoder()).join();
}
