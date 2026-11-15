import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/zai_auth_client.dart';

class _Recorded {
  _Recorded(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String>? headers;
  final Object? body;
}

class _FakeHttp implements AuthHttpLayer {
  _FakeHttp(this._respond);

  final AuthHttpResponse Function(_Recorded r) _respond;
  final requests = <_Recorded>[];

  @override
  Future<AuthHttpResponse> get(Uri url, {Map<String, String>? headers}) async {
    final r = _Recorded('GET', url, headers, null);
    requests.add(r);
    return _respond(r);
  }

  @override
  Future<AuthHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final r = _Recorded('POST', url, headers, body);
    requests.add(r);
    return _respond(r);
  }
}

AuthHttpResponse _json(int status, Map<String, dynamic> body) =>
    AuthHttpResponse(statusCode: status, body: body);

const _okInit = {
  'code': 0,
  'data': {
    'flow_id': 'flow-1',
    'authorize_url': 'https://chat.z.ai/api/oauth/authorize?client_id=x',
    'expires_at': 1780000000,
    'poll_interval_sec': 3,
  },
};

ZaiAuthClient _client({
  required AuthHttpLayer http,
  String? deviceMid,
  String pollToken = 'abababababababababababababababab',
  String requestId = '00000000-0000-4000-8000-000000000001',
  DateTime Function()? now,
}) => ZaiAuthClient(
  config: ZaiAuthClientConfig(deviceMid: deviceMid),
  http: http,
  pollTokenGen: () => pollToken,
  requestIdGen: () => requestId,
  now: now,
);

void main() {
  group('initFlow：请求构造与头全套断言', () {
    test('POST cli/init，Bearer=pollToken，body.provider=wire 名，A.3 头全集', () async {
      final http = _FakeHttp((_) => _json(200, _okInit));
      final client = _client(http: http, deviceMid: 'mid-uuid-1');
      final flow = await client.initFlow(ZaiAuthProvider.zaiCn);

      final r = http.requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://zcode.z.ai/api/v1/oauth/cli/init');
      expect(r.body, {'provider': 'zai_cn'});
      final h = r.headers!;
      expect(h['Authorization'], 'Bearer abababababababababababababababab');
      expect(h['User-Agent'], 'ZCode/3.18.2');
      expect(h['HTTP-Referer'], 'https://zcode.z.ai');
      expect(h['X-Title'], 'Z Code@electron');
      expect(h['X-ZCode-App-Version'], '3.18.2');
      expect(h['X-Platform'], 'android-arm64');
      expect(h['X-Release-Channel'], 'stable');
      expect(h['X-Client-Language'], 'zh-CN');
      expect(h['X-Client-Timezone'], 'UTC+08:00');
      expect(h['X-Os-Category'], 'Android');
      expect(h['X-Os-Version'], '14');
      expect(h['X-Device-Mid'], 'mid-uuid-1');
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(h['x-request-id']!),
        isTrue,
      );

      expect(flow.flowId, 'flow-1');
      expect(flow.authorizeUrl.scheme, 'https');
      expect(flow.pollToken, 'abababababababababababababababab');
      expect(flow.pollIntervalSec, 3);
      expect(flow.expiresAtMs, 1780000000000);
    });

    test('三 provider wire 名：zai_cn / zai / bigmodel', () async {
      final http = _FakeHttp((_) => _json(200, _okInit));
      final client = _client(http: http);
      await client.initFlow(ZaiAuthProvider.zaiCn);
      await client.initFlow(ZaiAuthProvider.zai);
      await client.initFlow(ZaiAuthProvider.bigmodel);
      expect(
        http.requests.map((r) => (r.body as Map)['provider']).toList(),
        ['zai_cn', 'zai', 'bigmodel'],
      );
    });

    test('无 deviceMid 时不带 X-Device-Mid 头', () async {
      final http = _FakeHttp((_) => _json(200, _okInit));
      await _client(http: http).initFlow(ZaiAuthProvider.zai);
      expect(http.requests.single.headers!.containsKey('X-Device-Mid'), isFalse);
    });
  });

  group('initFlow：authorize_url 校验与漂移 fixture', () {
    Future<AuthFlowInit> initWith(Map<String, dynamic> data) {
      final http = _FakeHttp((_) => _json(200, {'code': 0, 'data': data}));
      return _client(http: http).initFlow(ZaiAuthProvider.zai);
    }

    test('authorize_url 为 http → 拒绝（S2 反向：摘掉校验此例必红）', () {
      expect(
        () => initWith({
          'flow_id': 'f',
          'authorize_url': 'http://chat.z.ai/authorize',
        }),
        throwsA(
          isA<ZaiAuthException>()
              .having((e) => e.kind, 'kind', ZaiAuthErrorKind.badResponse),
        ),
      );
    });

    test('authorize_url 为 javascript: → 拒绝', () {
      expect(
        () => initWith({
          'flow_id': 'f',
          'authorize_url': 'javascript:alert(1)',
        }),
        throwsA(isA<ZaiAuthException>()),
      );
    });

    test('外壳漂移：data 缺席但 body 自带 flow_id/authorize_url → 仍可解析', () async {
      final http = _FakeHttp(
        (_) => _json(200, {
          'flow_id': 'f2',
          'authorize_url': 'https://chat.z.ai/a',
        }),
      );
      final flow = await _client(http: http).initFlow(ZaiAuthProvider.zai);
      expect(flow.flowId, 'f2');
    });

    test('字段缺失：flow_id/authorize_url 任一缺失 → badResponse', () {
      expect(
        () => initWith({'authorize_url': 'https://chat.z.ai/a'}),
        throwsA(
          isA<ZaiAuthException>().having(
            (e) => e.kind,
            'kind',
            ZaiAuthErrorKind.badResponse,
          ),
        ),
      );
      expect(
        () => initWith({'flow_id': 'f'}),
        throwsA(isA<ZaiAuthException>()),
      );
    });

    test('类型漂移：flow_id 为数字 / authorize_url 为数字 → badResponse', () {
      expect(
        () => initWith({'flow_id': 42, 'authorize_url': 'https://a.b/c'}),
        throwsA(isA<ZaiAuthException>()),
      );
      expect(
        () => initWith({'flow_id': 'f', 'authorize_url': 7}),
        throwsA(isA<ZaiAuthException>()),
      );
    });

    test('poll_interval_sec 缺席 → 默认 5；非正数 → 默认 5', () async {
      final a = await initWith({
        'flow_id': 'f',
        'authorize_url': 'https://chat.z.ai/a',
      });
      expect(a.pollIntervalSec, 5);
      final b = await initWith({
        'flow_id': 'f',
        'authorize_url': 'https://chat.z.ai/a',
        'poll_interval_sec': 0,
      });
      expect(b.pollIntervalSec, 5);
    });
  });

  group('pollOnce / pollUntilReady', () {
    AuthFlowInit flowOf() => AuthFlowInit(
      flowId: 'flow-9',
      authorizeUrl: Uri.parse('https://chat.z.ai/a'),
      pollToken: 'cd' * 16,
      pollIntervalSec: 1,
    );

    test('GET poll/{flowId}，Bearer 复用 pollToken', () async {
      final http = _FakeHttp(
        (_) => _json(200, {
          'code': 0,
          'data': {'status': 'pending'},
        }),
      );
      await _client(http: http).pollOnce(flowOf());
      final r = http.requests.single;
      expect(r.method, 'GET');
      expect(
        r.url.toString(),
        'https://zcode.z.ai/api/v1/oauth/cli/poll/flow-9',
      );
      expect(r.headers!['Authorization'], 'Bearer ${'cd' * 16}');
    });

    test('ready：token/user/zai access_token 齐回', () async {
      final http = _FakeHttp(
        (_) => _json(200, {
          'status': 'ready',
          'token': 'jwt-abc',
          'user': {'user_id': 'u1', 'name': '张三', 'email': 'z@t.invalid'},
          'zai': {'access_token': 'at-1'},
        }),
      );
      final r = await _client(http: http).pollOnce(flowOf());
      expect(r.status, AuthFlowStatus.ready);
      expect(r.token, 'jwt-abc');
      expect(r.user['user_id'], 'u1');
      expect(r.providerAccessToken, 'at-1');
      expect(r.providerRefreshToken, isNull);
    });

    test('ready + bigmodel：access/refresh 双回', () async {
      final http = _FakeHttp(
        (_) => _json(200, {
          'status': 'ready',
          'token': 'jwt-abc',
          'bigmodel': {'access_token': 'at-2', 'refresh_token': 'rt-2'},
        }),
      );
      final r = await _client(http: http).pollOnce(flowOf());
      expect(r.providerAccessToken, 'at-2');
      expect(r.providerRefreshToken, 'rt-2');
      expect(r.user, isEmpty);
    });

    test('failed → pollUntilReady 抛 api；pending→ready 正常收敛', () async {
      final seq = [
        _json(200, {
          'code': 0,
          'data': {'status': 'pending'},
        }),
        _json(200, {
          'code': 0,
          'data': {'status': 'ready', 'token': 'jwt-x'},
        }),
      ];
      var i = 0;
      final http = _FakeHttp((_) => seq[i++]);
      final r = await _client(http: http).pollUntilReady(flowOf());
      expect(r.token, 'jwt-x');
      expect(http.requests, hasLength(2));

      final failed = _FakeHttp(
        (_) => _json(200, {
          'code': 0,
          'data': {'status': 'failed'},
        }),
      );
      await expectLater(
        _client(http: failed).pollUntilReady(flowOf()),
        throwsA(
          isA<ZaiAuthException>().having(
            (e) => e.kind,
            'kind',
            ZaiAuthErrorKind.api,
          ),
        ),
      );
    });

    test('ready 但 token 缺失 → badResponse（M5：形似但不完整报错不吞）', () {
      final http = _FakeHttp(
        (_) => _json(200, {
          'code': 0,
          'data': {'status': 'ready'},
        }),
      );
      expect(
        () => _client(http: http).pollOnce(flowOf()),
        throwsA(
          isA<ZaiAuthException>().having(
            (e) => e.kind,
            'kind',
            ZaiAuthErrorKind.badResponse,
          ),
        ),
      );
    });

    test('status 类型漂移（数字）/未知值 → badResponse', () {
      final http = _FakeHttp(
        (_) => _json(200, {
          'code': 0,
          'data': {'status': 1},
        }),
      );
      expect(
        () => _client(http: http).pollOnce(flowOf()),
        throwsA(isA<ZaiAuthException>()),
      );
      final http2 = _FakeHttp(
        (_) => _json(200, {
          'code': 0,
          'data': {'status': 'expired'},
        }),
      );
      expect(
        () => _client(http: http2).pollOnce(flowOf()),
        throwsA(isA<ZaiAuthException>()),
      );
    });
  });

  group('profile / revoke-all', () {
    test('profile：Bearer JWT，user 资料四字段', () async {
      final http = _FakeHttp(
        (_) => _json(200, {
          'code': 0,
          'data': {
            'user': {
              'user_id': 'u9',
              'name': 'Li',
              'email': 'li@t.invalid',
              'avatar': 'https://cdn.example.invalid/a.png',
            },
          },
        }),
      );
      final p = await _client(http: http).fetchProfile('jwt-1');
      expect(http.requests.single.headers!['Authorization'], 'Bearer jwt-1');
      expect(p.userId, 'u9');
      expect(p.email, 'li@t.invalid');
      expect(p.avatar, 'https://cdn.example.invalid/a.png');
    });

    test('profile 外壳漂移：body 直接是 user 形状 → 可解析', () async {
      final http = _FakeHttp(
        (_) => _json(200, {
          'user': {'user_id': 'u9'},
        }),
      );
      final p = await _client(http: http).fetchProfile('jwt-1');
      expect(p.userId, 'u9');
      expect(p.name, '');
    });

    test('profile 字段缺失（无 user 键）→ badResponse', () {
      final http = _FakeHttp((_) => _json(200, {'code': 0, 'data': {}}));
      expect(
        () => _client(http: http).fetchProfile('jwt-1'),
        throwsA(isA<ZaiAuthException>()),
      );
    });

    test('revoke-all：POST，2xx 即成功', () async {
      final http = _FakeHttp((_) => _json(200, {'code': 0}));
      await _client(http: http).revokeAll('jwt-2');
      final r = http.requests.single;
      expect(r.method, 'POST');
      expect(
        r.url.toString(),
        'https://zcode.z.ai/api/v1/oauth/revoke-all',
      );
      expect(r.headers!['Authorization'], 'Bearer jwt-2');
    });
  });

  group('错误分类', () {
    test('HTTP 500/401 → http kind（带状态码）', () {
      for (final status in [500, 401]) {
        final http = _FakeHttp((_) => _json(status, {'code': 0}));
        expect(
          () => _client(http: http).initFlow(ZaiAuthProvider.zai),
          throwsA(
            isA<ZaiAuthException>()
                .having((e) => e.kind, 'kind', ZaiAuthErrorKind.http)
                .having((e) => e.statusCode, 'statusCode', status),
          ),
        );
      }
    });

    test('业务码非 0 → api kind', () {
      final http = _FakeHttp((_) => _json(200, {'code': 40101, 'msg': 'x'}));
      expect(
        () => _client(http: http).initFlow(ZaiAuthProvider.zai),
        throwsA(
          isA<ZaiAuthException>()
              .having((e) => e.kind, 'kind', ZaiAuthErrorKind.api)
              .having((e) => e.apiCode, 'apiCode', 40101),
        ),
      );
    });

    test('body 非 JSON 对象 → badResponse', () {
      final http = _FakeHttp((_) => const AuthHttpResponse(statusCode: 200));
      expect(
        () => _client(http: http).initFlow(ZaiAuthProvider.zai),
        throwsA(
          isA<ZaiAuthException>().having(
            (e) => e.kind,
            'kind',
            ZaiAuthErrorKind.badResponse,
          ),
        ),
      );
    });
  });

  group('JWT exp 解析（秒/毫秒边界）', () {
    String jwtOf(Map<String, dynamic> payload) {
      String b64(List<int> bytes) =>
          base64Url.encode(bytes).replaceAll('=', '');
      return [
        b64(utf8.encode('{"alg":"HS256","typ":"JWT"}')),
        b64(utf8.encode(jsonEncode(payload))),
        'sig',
      ].join('.');
    }

    test('秒值 → ×1000', () {
      expect(ZaiAuthClient.parseJwtExpMs(jwtOf({'exp': 1731628800})), 1731628800000);
    });

    test('毫秒值 → 原样', () {
      expect(
        ZaiAuthClient.parseJwtExpMs(jwtOf({'exp': 1731628800000})),
        1731628800000,
      );
    });

    test('exp 为字符串数字 → 可解析', () {
      expect(ZaiAuthClient.parseJwtExpMs(jwtOf({'exp': '1731628800'})), 1731628800000);
    });

    test('缺 exp / exp 非数字 → null；两段式/坏 base64 → null', () {
      expect(ZaiAuthClient.parseJwtExpMs(jwtOf({'iat': 1})), isNull);
      expect(ZaiAuthClient.parseJwtExpMs(jwtOf({'exp': 'soon'})), isNull);
      expect(ZaiAuthClient.parseJwtExpMs('not.a'), isNull);
      expect(ZaiAuthClient.parseJwtExpMs('a.!!!.c'), isNull);
      expect(ZaiAuthClient.parseJwtExpMs('x.y.z.w'), isNull);
    });

    test('isJwtExpired：30s 偏移容忍', () {
      final now = DateTime(2026, 11, 15, 12);
      final expAt = now.millisecondsSinceEpoch;
      expect(ZaiAuthClient.isJwtExpired(expAt + 20000, now: now), isTrue);
      expect(ZaiAuthClient.isJwtExpired(expAt + 40000, now: now), isFalse);
    });

    test('isJwtExpiringWithin：24h 窗口内外', () {
      final now = DateTime(2026, 11, 15, 12);
      final expAt = now.millisecondsSinceEpoch;
      expect(
        ZaiAuthClient.isJwtExpiringWithin(
          expAt + const Duration(hours: 23).inMilliseconds,
          now: now,
        ),
        isTrue,
      );
      expect(
        ZaiAuthClient.isJwtExpiringWithin(
          expAt + const Duration(hours: 25).inMilliseconds,
          now: now,
        ),
        isFalse,
      );
      expect(
        ZaiAuthClient.isJwtExpiringWithin(expAt - 60000, now: now),
        isTrue,
      );
    });
  });

  test('ZaiAuthProvider wire 名回解', () {
    expect(ZaiAuthProvider.tryFromWire('zai_cn'), ZaiAuthProvider.zaiCn);
    expect(ZaiAuthProvider.tryFromWire('bigmodel'), ZaiAuthProvider.bigmodel);
    expect(ZaiAuthProvider.tryFromWire('nope'), isNull);
  });
}
