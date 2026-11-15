import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/provider_settings.dart'
    show
        EntitlementSemantic,
        UsageEntitlement,
        ZrEffectiveConfig,
        ProviderSettingsView,
        ZrProvider,
        ZrProviderAccess,
        classifyEntitlement,
        entitlementParamsFor,
        pickEntitlementProvider;
import 'package:zremote/services/account_credentials.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/services/quota_client.dart';
import 'package:zremote/services/rpc_bridge.dart' show RpcRemoteException;

import 'scripted_bridge.dart';

/// 通路 B 直连的假 HttpClientAdapter：按 URL 分发 fixture。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final Map<String, dynamic> Function(Uri url) responder;
  final List<Uri> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    final body = responder(uri);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _zaiBalanceDoc() => {
  'code': 200,
  'data': {
    'plans': [
      {
        'plan_id': 'coding-plan-max-monthly',
        'name': 'GLM Coding Max',
        'status': 'active',
        'starts_at': '2026-11-01T00:00:00Z',
        'ends_at': '2026-12-01T00:00:00Z',
      },
      {
        'plan_id': 'start-plan-monthly',
        'name': 'Start Plan',
        'status': 'active',
        'starts_at': '2026-11-01T00:00:00Z',
        'ends_at': '2026-12-01T00:00:00Z',
      },
      {
        'plan_id': 'coding-plan-pro-expired',
        'name': 'GLM Coding Pro',
        'status': 'expired',
      },
    ],
    'balances': [
      {
        'plan_id': 'coding-plan-max-monthly',
        'show_name': 'Max 套餐提示',
        'meter': 'model_usage',
        'unit_type': 'token',
        'total_units': 600,
        'used_units': 150,
        'remaining_units': 450,
        'period_end': 1764547200000,
        'capabilities': ['model:GLM-5.3', 'model:GLM-5.3-Flash'],
      },
      {
        'show_name': '体验赠送额度',
        'unit_type': 'token',
        'used_units': 20,
        'remaining_units': 80,
        'expires_at': '2026-12-05 10:00:00',
      },
    ],
  },
};

Map<String, dynamic> _bigmodelLimitDoc() => {
  'code': 200,
  'data': {
    'level': 'max',
    'limits': [
      {
        'type': 'TOKENS_LIMIT',
        'unit': 3,
        'number': 5,
        'usage': 120,
        'currentValue': 30,
        'remaining': 90,
        'percentage': 25.0,
        'nextResetTime': 1762339200000,
      },
      {
        'type': 'TIME_LIMIT',
        'unit': 6,
        'usage': 3000,
        'currentValue': 1200,
        'remaining': 1800,
        'percentage': 40.0,
        'nextResetTime': 1762944000000,
      },
    ],
  },
};

Map<String, dynamic> _hostSnapshot() => {
  'generatedAt': 1762300000000,
  'quota': {
    'level': 'pro',
    'limits': [
      {
        'type': 'TOKENS_LIMIT',
        'unit': 3,
        'number': 5,
        'remaining': 70,
        'percentage': 65.0,
        'nextResetTime': '2026-11-05T12:00:00Z',
      },
      {'type': 'TIME_LIMIT', 'unit': 4, 'percentage': 80.0},
    ],
  },
  'subscription': {
    'details': [
      {'productName': 'GLM Coding Pro', 'productId': 'coding-plan-pro'},
    ],
  },
};

void main() {
  group('tier 归类（quota.rs plan_tier_from_id 移植）', () {
    test('max/pro/lite/start/trial 族关键词', () {
      expect(quotaTierOf('coding-plan-max', null).code, QuotaTierCode.max);
      expect(quotaTierOf('plan-x', 'Pro 月包').code, QuotaTierCode.pro);
      expect(quotaTierOf('lite-plan', null).code, QuotaTierCode.lite);
      expect(quotaTierOf('start-plan-monthly', null).code, QuotaTierCode.start);
      expect(quotaTierOf('start-plan-monthly', null).display, 'Start Plan');
      for (final kw in ['trial', 'taste', 'gift', 'weekend', 'promo', '活动体验']) {
        expect(quotaTierOf('p-$kw', null).code, QuotaTierCode.trial,
            reason: '$kw 应归体验槽');
      }
      expect(quotaTierOf('unknown-plan', null).code, QuotaTierCode.other);
      expect(quotaTierOf('unknown-plan', null).display, 'unknown-plan');
    });

    test('槽优先级 rank：max>pro>lite>start>trial>other', () {
      const order = [
        QuotaTierCode.max,
        QuotaTierCode.pro,
        QuotaTierCode.lite,
        QuotaTierCode.start,
        QuotaTierCode.trial,
        QuotaTierCode.other,
      ];
      for (var i = 1; i < order.length; i++) {
        expect(quotaTierRank(order[i - 1]), greaterThan(quotaTierRank(order[i])));
      }
    });
  });

  group('unit 语义映射（unit 3=每N小时/4=天/5=月/6=周）', () {
    test('quotaWindowCode 全矩阵', () {
      expect(quotaWindowCode(3, 5), 'hours:5');
      expect(quotaWindowCode(3, 8), 'hours:8');
      expect(quotaWindowCode(3, null), 'hours:5', reason: 'N 缺省取 5');
      expect(quotaWindowCode(4, null), 'daily');
      expect(quotaWindowCode(5, null), 'monthly');
      expect(quotaWindowCode(6, null), 'weekly');
      expect(quotaWindowCode(9, null), 'cycle');
      expect(quotaWindowCode(null, null), 'cycle', reason: 'unit 缺失兜底每周期');
    });

    test('kind 归类：TOKENS→prompt_count，TIME→duration', () {
      expect(quotaKindCode('TOKENS_LIMIT'), 'prompt_count');
      expect(quotaKindCode('TIME_LIMIT'), 'duration');
      expect(quotaKindCode('MYSTERY'), 'raw');
    });
  });

  group('normalizeZaiBalanceDoc：三接口归一化 + S2 形状漂移成对', () {
    test('正常：active 套餐建槽，balance 按 plan_id 挂槽，孤儿进「其他额度」', () {
      final ov = normalizeZaiBalanceDoc(_zaiBalanceDoc())!;
      expect(ov.plans, hasLength(3), reason: 'expired 套餐不建槽');
      // 槽排序：max > start > other
      expect(ov.plans[0].tierCode, QuotaTierCode.max);
      expect(ov.plans[0].pid, 'coding-plan-max-monthly');
      expect(ov.plans[1].tierCode, QuotaTierCode.start);
      expect(ov.plans[2].tier, '其他额度');
      // max 槽：模型余额行 + capabilities 前缀剥离
      final maxBalances = ov.plans[0].items;
      expect(maxBalances, hasLength(1));
      expect(maxBalances.first.modelIds, ['GLM-5.3', 'GLM-5.3-Flash']);
      expect(maxBalances.first.remaining, 450);
      // 孤儿余额在「其他额度」槽
      expect(ov.plans[2].items, hasLength(1));
      expect(ov.plans[2].items.first.name, '体验赠送额度');
      // 互推补全：孤儿缺 total → used+remaining
      expect(ov.plans[2].total, 100);
      expect(ov.plans[2].remaining, 80);
    });

    test('外壳包裹：data/result 双层壳照常解析（反向：剥壳逻辑缺失即失败）', () {
      final wrapped = {
        'data': {'result': _zaiBalanceDoc()['data']},
      };
      final ov = normalizeZaiBalanceDoc(wrapped);
      expect(ov, isNotNull, reason: '外壳包裹必须被 unwrap 剥掉');
      expect(ov!.plans.first.pid, 'coding-plan-max-monthly');
    });

    test('字段缺失：balance 缺 remaining → total-used 补全', () {
      final doc = {
        'data': {
          'plans': [
            {'plan_id': 'only', 'name': '唯一', 'status': 'active'},
          ],
          'balances': [
            {
              'plan_id': 'only',
              'show_name': 'n',
              'total_units': 100,
              'used_units': 30,
            },
          ],
        },
      };
      final ov = normalizeZaiBalanceDoc(doc)!;
      expect(ov.plans.single.items.single.remaining, isNull,
          reason: '条目保持原始缺数，补全发生在槽层');
      expect(ov.plans.single.remaining, 70);
      expect(ov.plans.single.percentUsed, 30.0);
    });

    test('类型漂移：数值串（含千分位）与缺失 status 均可解析', () {
      final doc = {
        'data': {
          'plans': [
            {'plan_id': 'drift', 'name': '漂移'},
          ],
          'balances': [
            {
              'plan_id': 'drift',
              'show_name': 'n',
              'total_units': '1,200',
              'used_units': '300',
              'remaining_units': 900,
              'unit_type': 5,
            },
          ],
        },
      };
      final ov = normalizeZaiBalanceDoc(doc)!;
      final item = ov.plans.single.items.single;
      expect(item.total, 1200, reason: '数值串带千分位应可解析');
      expect(item.unit, 'quota', reason: 'unit_type 类型漂移回落 quota');
      expect(ov.plans.single.tierCode, QuotaTierCode.other);
    });

    test('单套餐 + 无 plan_id 余额：挂唯一槽', () {
      final doc = {
        'plans': [
          {'plan_id': 'solo', 'name': '单', 'status': 'active'},
        ],
        'balances': [
          {'show_name': 'b1', 'total_units': 10, 'used_units': 2},
        ],
      };
      final ov = normalizeZaiBalanceDoc(doc)!;
      expect(ov.plans.single.items, hasLength(1));
      expect(ov.plans.single.items.first.name, 'b1');
    });

    test('无 plans 但有 loose 余额：兜底单槽（含 tier 关键词推断）', () {
      final doc = {
        'plans': [
          {'plan_id': 'lite-x', 'name': 'Lite', 'status': 'active'},
        ],
        'balances': [
          {'show_name': 'b1', 'total_units': 10},
        ],
      };
      final ov = normalizeZaiBalanceDoc(doc)!;
      expect(ov.plans.single.tierCode, QuotaTierCode.lite);
    });

    test('S2 反向对照：完全不像余额文档 → null 而非空壳', () {
      expect(normalizeZaiBalanceDoc({'foo': 1, 'bar': 'x'}), isNull);
      expect(normalizeZaiBalanceDoc({'data': {'code': 401}}), isNull);
      expect(normalizeZaiBalanceDoc(const {}), isNull);
    });
  });

  group('normalizeBigmodelLimitDoc', () {
    test('TIME_LIMIT 优先作主指标；nextResetTime(ms) 转本地时间', () {
      final ov = normalizeBigmodelLimitDoc(_bigmodelLimitDoc())!;
      final slot = ov.plans.single;
      expect(slot.tier, 'Max');
      // TIME_LIMIT 为主：total=3000
      expect(slot.total, 3000);
      expect(slot.used, 1200);
      expect(slot.percentUsed, 40.0);
      final items = slot.items;
      expect(items, hasLength(2));
      final tokens = items.firstWhere((i) => i.kind == 'prompt_count');
      expect(tokens.window, 'hours:5');
      final duration = items.firstWhere((i) => i.kind == 'duration');
      expect(duration.window, 'weekly');
      expect(duration.resetAt!.millisecondsSinceEpoch, 1762944000000);
    });

    test('total/used 缺失时回落服务端 percentage；串壳照常', () {
      final doc = {
        'data': {
          'limits': [
            {'type': 'TOKENS_LIMIT', 'unit': 4, 'percentage': 12.5},
          ],
        },
      };
      final ov = normalizeBigmodelLimitDoc(doc)!;
      final item = ov.plans.single.items.single;
      expect(item.percentUsed, 12.5);
      expect(item.window, 'daily');
    });

    test('S2 反向对照：limits 缺失/非列表 → null', () {
      expect(normalizeBigmodelLimitDoc({'data': {}}), isNull);
      expect(normalizeBigmodelLimitDoc({'data': {'limits': 'x'}}), isNull);
      expect(normalizeBigmodelLimitDoc({'unrelated': true}), isNull);
    });
  });

  group('normalizeHostSnapshot（通路 A）', () {
    test('limits 归一化 + tier 从 quotaLevel', () {
      final ent = hostEntitlementOf(_hostSnapshot());
      final ov = normalizeHostSnapshot(ent)!;
      final slot = ov.plans.single;
      expect(slot.tier, 'Pro');
      expect(slot.name, 'GLM Coding Pro');
      final tokens = slot.items.firstWhere((i) => i.kind == 'prompt_count');
      expect(tokens.window, 'hours:5');
      expect(tokens.percentUsed, 65.0);
      final duration = slot.items.firstWhere((i) => i.kind == 'duration');
      expect(duration.window, 'daily');
    });

    test('TIME_LIMIT 无数据时不作主指标，回落首个有数项', () {
      final ov = normalizeHostSnapshot(
        hostEntitlementOf({
          'generatedAt': 1,
          'quota': {
            'limits': [
              {'type': 'TIME_LIMIT', 'unit': 4},
              {
                'type': 'TOKENS_LIMIT',
                'unit': 3,
                'number': 5,
                'percentage': 55.0,
              },
            ],
          },
        }),
      )!;
      final main = ov.mainItemOf(ov.plans.single);
      expect(main!.kind, 'prompt_count');
      expect(main.percentUsed, 55.0);
    });
  });

  group('mergeQuotaParts（跨源去重 + 主槽指标）', () {
    test('跨源同 tier+name 去重，主指标取最高 tier 槽', () {
      final a = normalizeBigmodelLimitDoc(_bigmodelLimitDoc())!;
      final b = normalizeZaiBalanceDoc(_zaiBalanceDoc())!;
      final merged = mergeQuotaParts([a, b]);
      expect(merged.sources, ['bigmodel-monitor', 'zai-billing']);
      // max 槽为主
      expect(merged.planTierCode, QuotaTierCode.max);
      expect(merged.primaryPlan!.tierCode, QuotaTierCode.max);
      // 槽排序 max > start > other
      expect(
        merged.plans.map((p) => p.tierCode).toList(),
        containsAllInOrder([
          QuotaTierCode.max,
          QuotaTierCode.start,
          QuotaTierCode.other,
        ]),
      );
    });
  });

  group('请求头全套（附录 A.3）', () {
    final bridgeOnly = ScriptedBridge();

    QuotaClient clientOf({String? mid}) => QuotaClient(
      bridge: bridgeOnly.bridge,
      deviceMid: mid,
      osVersion: '15',
      clientTimezone: 'Asia/Shanghai',
    );

    test('zai 头全套：UA/Referer/X-Title/…/Bearer/uuid 请求号', () {
      final h1 = clientOf(mid: 'mid-1').zaiBillingHeaders('jwt-abc');
      expect(h1['User-Agent'], 'ZCode/3.18.2');
      expect(h1['HTTP-Referer'], 'https://zcode.z.ai');
      expect(h1['X-Title'], 'Z Code@electron');
      expect(h1['X-ZCode-App-Version'], '3.18.2');
      expect(h1['X-Platform'], 'android-arm64');
      expect(h1['X-Release-Channel'], 'stable');
      expect(h1['X-Client-Language'], 'zh-CN');
      expect(h1['X-Client-Timezone'], 'Asia/Shanghai');
      expect(h1['X-Os-Category'], 'android');
      expect(h1['X-Os-Version'], '15');
      expect(h1['X-Device-Mid'], 'mid-1', reason: 'X-Device-Mid 由调用方注入');
      expect(h1['Authorization'], 'Bearer jwt-abc');
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(h1['x-request-id']!),
        isTrue,
      );
      final h2 = clientOf(mid: 'mid-1').zaiBillingHeaders('jwt-abc');
      expect(h2['x-request-id'], isNot(h1['x-request-id']));
      expect(clientOf().zaiBillingHeaders('t').containsKey('X-Device-Mid'),
          isFalse, reason: '无 mid 时省略该头');
    });

    test('bigmodel 头：Authorization 原样不带 Bearer', () {
      final h = clientOf().bigmodelHeaders('key.raw');
      expect(h['Authorization'], 'key.raw');
      expect(h['Authorization']!.startsWith('Bearer'), isFalse);
      expect(h['User-Agent'], 'ZCode/3.18.2');
      expect(h.containsKey('X-Device-Mid'), isFalse);
    });
  });

  group('QuotaClient.fetch：通路 A/B 组合与降级', () {
    test('无 token 时通路 B 优雅降级：仅通路 A 一条 RPC', () async {
      final scripted = ScriptedBridge(script: [
        [_hostSnapshot()],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      final ov = await client.fetch();
      expect(scripted.commands, hasLength(1));
      expect(scripted.commands.single['s'], 'usageStatsService');
      expect(ov.sources, ['host-snapshot']);
      expect(ov.plans.single.tier, 'Pro');
    });

    test('tokenProvider 返回空 bundle 同样降级', () async {
      final scripted = ScriptedBridge(script: [
        [_hostSnapshot()],
      ]);
      var called = 0;
      final client = QuotaClient(
        bridge: scripted.bridge,
        tokenProvider: () async {
          called++;
          return const QuotaTokens();
        },
      );
      await client.fetch();
      expect(called, 1);
      expect(scripted.commands, hasLength(1));
    });

    test('双 token 三源合并：RPC + balance + limit', () async {
      final scripted = ScriptedBridge(script: [
        [_hostSnapshot()],
      ]);
      final adapter = _FakeAdapter((url) {
        if (url.path.contains('billing/balance')) return _zaiBalanceDoc();
        return _bigmodelLimitDoc();
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final client = QuotaClient(
        bridge: scripted.bridge,
        tokenProvider: () async =>
            const QuotaTokens(zaiJwt: 'jwt', bigmodelApiKey: 'key'),
        deviceMid: 'mid',
        dio: dio,
      );
      final ov = await client.fetch();
      expect(scripted.commands, hasLength(1));
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.first.queryParameters['app_version'],
        '3.18.2',
      );
      expect(ov.sources,
          containsAll(['host-snapshot', 'zai-billing', 'bigmodel-monitor']));
      expect(ov.planTierCode, QuotaTierCode.max);
    });

    test('通路 A noPlan 且无 token → noPlan 空态', () async {
      final scripted = ScriptedBridge(script: [
        [
          {
            'generatedAt': 1,
            'unavailableReason': 'no_plan',
          },
        ],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      final ov = await client.fetch();
      expect(ov.noPlan, isTrue);
      expect(ov.plans, isEmpty);
    });

    test('通路 A not_configured（authenticated:true + quota:null）→ 未配置空态，不抛',
        () async {
      final scripted = ScriptedBridge(script: [
        [
          {
            'generatedAt': 1762300000000,
            'authenticated': true,
            'unavailableReason': 'not_configured',
            'context': {'scope': 'personal'},
            'provider': null,
            'subscription': null,
            'quota': null,
            'mcpQuota': null,
          },
        ],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      final ov = await client.fetch();
      expect(ov.notConfigured, isTrue);
      expect(ov.noPlan, isFalse);
      expect(ov.plans, isEmpty);
    });

    test('通路 A not_authenticated / quota 缺失 → 未配置空态', () async {
      for (final body in [
        {'generatedAt': 1, 'unavailableReason': 'not_authenticated'},
        {'generatedAt': 1, 'quota': null},
      ]) {
        final scripted = ScriptedBridge(script: [
          [body],
        ]);
        final ov = await QuotaClient(bridge: scripted.bridge).fetch();
        expect(ov.notConfigured, isTrue, reason: '$body');
      }
    });

    test('回执完全不可解析（空对象）且无直连 → 仍抛 QuotaFetchException', () async {
      final scripted = ScriptedBridge(script: const [
        [{}],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      await expectLater(
        client.fetch(),
        throwsA(isA<QuotaFetchException>()),
      );
    });

    test('fetch(entitlementParams)：带 accountAccess 时原样下发宿主', () async {
      final scripted = ScriptedBridge(script: [
        [_hostSnapshot()],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      const params = {
        'includeSubscription': true,
        'preferredProviderId': 'p1',
        'accountAccess': {
          'type': 'zhipu-account',
          'accountType': 'zai',
          'mode': 'individual-coding-plan',
        },
      };
      await client.fetch(entitlementParams: params);
      expect(requestOf(scripted.commands.single).params, params);
    });

    group('loadEntitlementParams（providerSettings.getView → accountAccess）', () {
    test('entitle provider → 带 preferredProviderId + 完整 accountAccess', () async {
      final scripted = ScriptedBridge(script: [
        [_providerViewJson([
          _providerJson('builtin:zai-coding-plan', mode: 'individual-coding-plan'),
        ])],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      final params = await client.loadEntitlementParams();
      expect(params, isNotNull);
      expect(params!['preferredProviderId'], 'builtin:zai-coding-plan');
      expect(params['accountAccess'], {
        'type': 'zhipu-account',
        'accountType': 'zai',
        'mode': 'individual-coding-plan',
        'entitled': true,
      });
      expect(params['requirePreferredProvider'], isTrue);
      expect(requestOf(scripted.commands.single).method, 'getView');
    });

    test('access 缺 mode/accountType → 不发 accountAccess，也不附带 requirePreferredProvider',
        () async {
      final scripted = ScriptedBridge(script: [
        [_providerViewJson([
          _providerJson('p-missing', accountType: null, mode: null),
        ])],
      ]);
      final params = await QuotaClient(bridge: scripted.bridge)
          .loadEntitlementParams();
      expect(params, isNotNull);
      expect(params!.containsKey('accountAccess'), isFalse);
      expect(params.containsKey('requirePreferredProvider'), isFalse);
      expect(params['preferredProviderId'], 'p-missing');
    });

    test('无 entitle provider → null（降级为仅 includeSubscription）', () async {
      final scripted = ScriptedBridge(script: [
        [_providerViewJson([
          _providerJson('p-no', entitled: false),
        ])],
      ]);
      expect(
        await QuotaClient(bridge: scripted.bridge).loadEntitlementParams(),
        isNull,
      );
    });

    test('getView 失败 → null 降级，不抛（不阻断额度拉取）', () async {
      final scripted = ScriptedBridge(script: const [], errors: {0: 'no-services'});
      expect(
        await QuotaClient(bridge: scripted.bridge).loadEntitlementParams(),
        isNull,
      );
    });
  });

  group('classifyEntitlement / entitlementParamsFor（共用语义）', () {
    test('classifyEntitlement：ok / noPlan / notConfigured / unparseable', () {
      expect(
        classifyEntitlement(UsageEntitlement.fromJson(_hostSnapshot())),
        EntitlementSemantic.ok,
      );
      expect(
        classifyEntitlement(
          UsageEntitlement.fromJson({'unavailableReason': 'no_plan'}),
        ),
        EntitlementSemantic.noPlan,
      );
      expect(
        classifyEntitlement(
          UsageEntitlement.fromJson({
            'authenticated': true,
            'unavailableReason': 'not_configured',
            'quota': null,
          }),
        ),
        EntitlementSemantic.notConfigured,
      );
      expect(
        classifyEntitlement(null, raw: {'authenticated': true}),
        EntitlementSemantic.notConfigured,
        reason: 'quota 缺失但宿主已作答 → 未配置，不是解析失败',
      );
      expect(classifyEntitlement(null, raw: const {}), EntitlementSemantic.unparseable);
      expect(classifyEntitlement(null), EntitlementSemantic.unparseable);
    });

    test('pickEntitlementProvider：entitled 视图命中，空视图 null', () {
      final view = ProviderSettingsView.fromJson(_providerViewJson([
        _providerJson('p1', mode: 'individual-coding-plan'),
      ]))!;
      expect(pickEntitlementProvider(view, null)!.providerId, 'p1');
      expect(pickEntitlementProvider(null, null), isNull);
      expect(
        pickEntitlementProvider(
          ProviderSettingsView.fromJson(_providerViewJson([
            _providerJson('p-no', entitled: false),
          ])),
          null,
        ),
        isNull,
      );
    });

    test('entitlementParamsFor：三字段齐全才发 accountAccess', () {
      final full = entitlementParamsFor(
        _providerOf('p1', mode: 'start-plan'),
      );
      expect(full['accountAccess'], {
        'type': 'zhipu-account',
        'accountType': 'zai',
        'mode': 'start-plan',
        'entitled': true,
      });
      expect(full['requirePreferredProvider'], isTrue);

      final degraded = entitlementParamsFor(
        _providerOf('p2', accountType: null, mode: null),
      );
      expect(degraded.containsKey('accountAccess'), isFalse);
      expect(degraded.containsKey('requirePreferredProvider'), isFalse);
      expect(degraded['preferredProviderId'], 'p2');
    });
  });

  group('accountTicketsOf：账号 → 直连/福利供票矩阵（zai/zai_cn/bigmodel）', () {
    test('zai：jwt + zai access_token + active_provider', () {
      final tickets = accountTicketsOf(_account('zai', {
        'zcodejwttoken': 'jwt.z',
        'oauth:zai:access_token': 'zai-tok',
      }));
      expect(tickets.quotaTokens!.zaiJwt, 'jwt.z');
      expect(tickets.quotaTokens!.bigmodelApiKey, isNull);
      expect(tickets.rewardsCredentials.zcodeJwtToken, 'jwt.z');
      expect(tickets.rewardsCredentials.zaiAccessToken, 'zai-tok');
      expect(tickets.rewardsCredentials.activeProvider, 'zai');
      expect(tickets.isEmpty, isFalse);
    });

    test('zai_cn：access_token 落 zai_cn 槽，active_provider 跟随', () {
      final tickets = accountTicketsOf(_account('zai_cn', {
        'oauth:active_provider': 'zai_cn',
        'oauth:zai_cn:access_token': 'cn-tok',
      }));
      expect(tickets.quotaTokens, isNull, reason: '无 jwt 且无 bigmodel key');
      expect(tickets.rewardsCredentials.zaiCnAccessToken, 'cn-tok');
      expect(tickets.rewardsCredentials.activeProvider, 'zai_cn');
    });

    test('bigmodel：access_token 同时充当直连 API key', () {
      final tickets = accountTicketsOf(_account('bigmodel', {
        'oauth:bigmodel:access_token': 'bm-key',
      }));
      expect(tickets.quotaTokens!.bigmodelApiKey, 'bm-key');
      expect(tickets.quotaTokens!.zaiJwt, isNull);
      expect(tickets.rewardsCredentials.bigmodelAccessToken, 'bm-key');
      expect(tickets.rewardsCredentials.activeProvider, 'bigmodel');
    });

    test('active_provider 不受支持时回落账号 provider；未知账号 provider → null', () {
      final fallback = accountTicketsOf(_account('zai', {
        'oauth:active_provider': 'weird',
        'oauth:zai:access_token': 't',
      }));
      expect(fallback.rewardsCredentials.activeProvider, 'zai');

      final unknown = accountTicketsOf(_account('unknown', {
        'oauth:unknown:access_token': 't',
      }));
      expect(unknown.rewardsCredentials.activeProvider, isNull);
      expect(unknown.rewardsCredentials.isEmpty, isTrue);
    });

    test('空账号 → 空集合（各页降级）', () {
      expect(accountTicketsOf(null).isEmpty, isTrue);
      expect(accountTicketsOf(null).quotaTokens, isNull);
    });

    test('provider 键名矩阵：accessTokenOf 只认受支持 provider', () {
      final account = _account('zai', {
        'oauth:zai:access_token': 'a',
        'oauth:zai_cn:access_token': 'b',
        'oauth:bigmodel:access_token': 'c',
      });
      expect(accessTokenOf(account, 'zai'), 'a');
      expect(accessTokenOf(account, 'zai_cn'), 'b');
      expect(accessTokenOf(account, 'bigmodel'), 'c');
      expect(accessTokenOf(account, 'nope'), isNull);
      expect(accessTokenOf(account, null), isNull);
      expect(bigmodelApiKeyOf(account), 'c');
      expect(isSupportedAccountProvider('zai'), isTrue);
      expect(isSupportedAccountProvider('nope'), isFalse);
    });
  });

    test('通路 A 失败 + 通路 B 业务码失败 → QuotaFetchException 汇总', () async {
      final scripted = ScriptedBridge(script: const [
        [],
      ], errors: {
        0: 'usage-stats snapshot failed',
      });
      final adapter = _FakeAdapter((_) => {'code': 401, 'msg': 'unauthorized'});
      final dio = Dio()..httpClientAdapter = adapter;
      final client = QuotaClient(
        bridge: scripted.bridge,
        tokenProvider: () async => const QuotaTokens(zaiJwt: 'jwt'),
        dio: dio,
      );
      await expectLater(
        client.fetch(),
        throwsA(
          isA<QuotaFetchException>().having(
            (e) => e.message,
            'message',
            allOf(contains('401'), contains('unauthorized')),
          ),
        ),
      );
    });

    test('通路 A 失败但通路 B 成功：直连数据独立可用', () async {
      final scripted = ScriptedBridge(script: const [
        [],
      ], errors: {
        0: 'no-services: usageStatsService',
      });
      final adapter = _FakeAdapter((url) {
        if (url.path.contains('billing/balance')) return _zaiBalanceDoc();
        return {'code': 1114, 'msg': '不存在coding plan'};
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final client = QuotaClient(
        bridge: scripted.bridge,
        tokenProvider: () async => const QuotaTokens(
          zaiJwt: 'jwt',
          bigmodelApiKey: 'key',
        ),
        dio: dio,
      );
      final ov = await client.fetch();
      expect(ov.sources, ['zai-billing']);
      expect(ov.planTierCode, QuotaTierCode.max);
    });
  });

  group('重置卡（P1-5）', () {
    test('状态解析：容器形状 + 别名 + has_unread_history + history', () {
      final status = ResetCardStatus.fromJson({
        'resets': [
          {'reset_type': 'FIVE_HOURS', 'available': 2, 'expires_at': 1762339200000},
          {'reset_type': 'WEEKLY', 'count': 0},
        ],
        'has_unread_history': true,
        'history': [
          {'reset_type': 'FIVE_HOURS', 'used_at': 1762252800000},
        ],
      });
      expect(status.entries, hasLength(2));
      final five = status.entries.first;
      expect(five.isFiveHour, isTrue);
      expect(five.available, 2);
      expect(five.expiresAt!.millisecondsSinceEpoch, 1762339200000);
      expect(status.entries[1].isWeekly, isTrue);
      expect(status.entries[1].available, 0);
      expect(status.hasUnreadHistory, isTrue);
      expect(status.history.single.usedAt!.millisecondsSinceEpoch,
          1762252800000);
    });

    test('状态解析：顶层扁平形状兜底（five*/week* 数值键）', () {
      final status = ResetCardStatus.fromJson({
        'five_hour_resets_available': 1,
        'weekly_resets_left': 3,
      });
      expect(status.entries, hasLength(2));
      expect(
        status.entries.where((e) => e.isFiveHour).single.available,
        1,
      );
      expect(status.entries.where((e) => e.isWeekly).single.available, 3);
    });

    // 重置卡三个 RPC 方法都先解析 entitle provider（getView），再带
    // preferredProviderId + accountAccess 调宿主（契约 CodingPlanUsageRequest）。
    final providerView = _providerViewJson([
      _providerJson('builtin:zai-coding-plan', mode: 'individual-coding-plan'),
    ]);
    final noProviderView = _providerViewJson([
      _providerJson('p-no', entitled: false),
    ]);

    test('使用成功：幂等键 uuid v4 + 契约参数随命令下发', () async {
      final scripted = ScriptedBridge(script: [
        [providerView],
        [
          {'used': true},
        ],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      final result = await client.useResetCard('FIVE_HOURS');
      expect(result.success, isTrue, reason: '宿主成功回执为 {used: true}');
      expect(result.rateLimited, isFalse);
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(result.idempotencyKey!),
        isTrue,
      );
      expect(scripted.commands, hasLength(2));
      final request = requestOf(scripted.commands[1]);
      expect(request.channel, 'usage-stats');
      expect(request.method, 'useCodingPlanReset');
      final params = request.params as Map<String, dynamic>;
      expect(params['preferredProviderId'], 'builtin:zai-coding-plan');
      expect(params['accountAccess'], isA<Map<String, dynamic>>());
      expect(params['idempotencyKey'], result.idempotencyKey);
      expect(params['resetType'], 'FIVE_HOURS');
      expect(params.containsKey('range'), isTrue);
    });

    test('无限流：无 entitle provider → 按 no_bigmodel_api_key 失败态', () async {
      final scripted = ScriptedBridge(script: [
        [noProviderView],
      ]);
      final result = await QuotaClient(
        bridge: scripted.bridge,
      ).useResetCard('FIVE_HOURS');
      expect(result.success, isFalse);
      expect(result.message, contains('no_bigmodel_api_key'));
      expect(scripted.commands, hasLength(1), reason: '未发 reset 调用');
    });

    test('限流 3301（响应体形状）：next_try_at 倒计时读数', () async {
      final scripted = ScriptedBridge(script: [
        [providerView],
        [
          {'success': false, 'code': 3301, 'next_try_at': 1762339200000},
        ],
      ]);
      final client = QuotaClient(bridge: scripted.bridge);
      final result = await client.useResetCard('WEEKLY');
      expect(result.success, isFalse);
      expect(result.rateLimited, isTrue);
      expect(result.nextTryAt!.millisecondsSinceEpoch, 1762339200000);
    });

    test('限流 3301（RPC 异常文本形状）：正则提取 next_try_at', () async {
      final scripted = ScriptedBridge(script: [
        [providerView],
        [],
      ], errors: {
        1: 'use_coding_plan_reset rejected: code=3301, next_try_at=1731600000000',
      });
      final client = QuotaClient(bridge: scripted.bridge);
      final result = await client.useResetCard('FIVE_HOURS');
      expect(result.rateLimited, isTrue);
      expect(result.nextTryAt!.millisecondsSinceEpoch, 1731600000000);
    });

    test('resetCardSupported：无 provider/no-method/无 key → false；业务错 → true', () async {
      final noProvider = ScriptedBridge(script: [
        [noProviderView],
      ]);
      expect(
        await QuotaClient(bridge: noProvider.bridge).resetCardSupported(),
        isFalse,
        reason: '无 entitle provider 视作不支持（隐藏区块）',
      );

      final noMethod = ScriptedBridge(script: [
        [providerView],
        [],
      ], errors: {
        1: 'no-method: useCodingPlanReset',
      });
      expect(
        await QuotaClient(bridge: noMethod.bridge).resetCardSupported(),
        isFalse,
      );

      final noKey = ScriptedBridge(script: [
        [providerView],
        [],
      ], errors: {
        1: 'no_bigmodel_api_key',
      });
      expect(
        await QuotaClient(bridge: noKey.bridge).resetCardSupported(),
        isFalse,
        reason: '非 coding-plan provider 视作不支持',
      );

      final ok = ScriptedBridge(script: [
        [providerView],
        [
          {'resets': []},
        ],
      ]);
      expect(
        await QuotaClient(bridge: ok.bridge).resetCardSupported(),
        isTrue,
      );

      final bizFail = ScriptedBridge(script: [
        [providerView],
        [],
      ], errors: {
        1: 'coding_plan_reset_not_available',
      });
      expect(
        await QuotaClient(bridge: bizFail.bridge).resetCardSupported(),
        isTrue,
        reason: '方法在但业务失败 → 区块展示由状态加载兜底',
      );
    });

    test('fetchResetCardStatus：无 provider/no-method → Unsupported；RPC 错误 → 失败态', () async {
      final noProvider = ScriptedBridge(script: [
        [noProviderView],
      ]);
      await expectLater(
        QuotaClient(bridge: noProvider.bridge).fetchResetCardStatus(),
        throwsA(isA<ResetCardUnsupportedException>()),
      );

      final noMethod = ScriptedBridge(script: [
        [providerView],
        [],
      ], errors: {
        1: 'no-method: getCodingPlanUsageSnapshot',
      });
      await expectLater(
        QuotaClient(bridge: noMethod.bridge).fetchResetCardStatus(),
        throwsA(isA<ResetCardUnsupportedException>()),
      );

      final rpcError = ScriptedBridge(script: [
        [providerView],
        [],
      ], errors: {
        1: 'network down',
      });
      await expectLater(
        QuotaClient(bridge: rpcError.bridge).fetchResetCardStatus(),
        throwsA(isA<RpcRemoteException>()),
        reason: '真实 RPC 错误才走「加载失败」可重试态',
      );

      final ok = ScriptedBridge(script: [
        [providerView],
        [
          {
            'resets': [
              {'reset_type': 'FIVE_HOURS', 'available': 1},
            ],
          },
        ],
      ]);
      final status = await QuotaClient(bridge: ok.bridge).fetchResetCardStatus();
      expect(status.entries.single.available, 1);
      final request = requestOf(ok.commands[1]);
      expect(request.params, isA<Map<String, dynamic>>());
      expect(
        (request.params as Map<String, dynamic>)['preferredProviderId'],
        'builtin:zai-coding-plan',
      );
    });
  });

  test('quotaBusinessOk：code 缺失/200/0 且 success != false', () {
    expect(quotaBusinessOk({'data': 1}), isTrue);
    expect(quotaBusinessOk({'code': 200}), isTrue);
    expect(quotaBusinessOk({'code': 0}), isTrue);
    expect(quotaBusinessOk({'code': 401}), isFalse);
    expect(quotaBusinessOk({'success': false}), isFalse);
    expect(quotaBusinessOk({'code': '200'}), isTrue,
        reason: 'code 类型漂移按 quota.rs as_i64→None 宽松处理');
  });

  test('parseQuotaDateTime：秒/毫秒/ISO/空串', () {
    expect(
      parseQuotaDateTime(1762339200000)!.millisecondsSinceEpoch,
      1762339200000,
    );
    expect(
      parseQuotaDateTime(1762339200)!.millisecondsSinceEpoch,
      1762339200000,
    );
    expect(
      parseQuotaDateTime('2026-11-05T12:00:00Z')!.toUtc().toIso8601String(),
      startsWith('2026-11-05T12:00:00'),
    );
    expect(parseQuotaDateTime('2026-12-05 10:00:00'), isNotNull);
    expect(parseQuotaDateTime(''), isNull);
    expect(parseQuotaDateTime(123), isNull);
    expect(parseQuotaDateTime(null), isNull);
  });
}

/// 通路 A fixture → UsageEntitlement（复用生产模型入口）。
UsageEntitlement hostEntitlementOf(Map<String, dynamic> snapshot) =>
    UsageEntitlement.fromJson(snapshot)!;

Map<String, dynamic> _providerViewJson(List<Map<String, dynamic>> providers) => {
  'revision': 1,
  'providers': providers,
};

Map<String, dynamic> _providerJson(
  String id, {
  String type = 'zhipu-account',
  String? accountType = 'zai',
  String? mode = 'individual-coding-plan',
  bool? entitled = true,
}) {
  final access = <String, dynamic>{'type': type};
  if (accountType != null) access['accountType'] = accountType;
  if (mode != null) access['mode'] = mode;
  if (entitled != null) access['entitled'] = entitled;
  return {
    'providerId': id,
    'providerName': id,
    'executable': true,
    'enabled': true,
    'effectiveConfig': {'group': 'zai-family', 'access': access},
    'models': const [],
  };
}

ZrProvider _providerOf(
  String id, {
  String? accountType = 'zai',
  String? mode = 'individual-coding-plan',
}) => ZrProvider(
  providerId: id,
  enabled: true,
  executable: true,
  models: const [],
  effectiveConfig: ZrEffectiveConfig(
    group: 'zai-family',
    access: ZrProviderAccess(
      type: 'zhipu-account',
      accountType: accountType,
      mode: mode,
      entitled: true,
    ),
  ),
);

Account _account(String provider, Map<String, String> credentials) => Account(
  id: 'a1',
  name: provider,
  provider: provider,
  credentials: credentials,
  hash: 'h',
  virtualDeviceMid: 'mid',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);
