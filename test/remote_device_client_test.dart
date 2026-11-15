import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/remote_device_client.dart';
import 'package:zremote/services/zai_auth_client.dart';

class _FakeLayer implements RemoteDeviceHttpLayer {
  _FakeLayer(this.responder);

  final Future<RemoteDeviceHttpResponse> Function(
    Uri url,
    Map<String, String>? headers,
  ) responder;

  Uri? url;
  Map<String, String>? headers;

  @override
  Future<RemoteDeviceHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
  }) {
    this.url = url;
    this.headers = headers;
    return responder(url, headers);
  }
}

RemoteDeviceHttpResponse _ok(
  Object? body, {
  int status = 200,
}) => RemoteDeviceHttpResponse(statusCode: status, body: body);

RemoteDeviceClient _client(_FakeLayer layer) =>
    RemoteDeviceClient(http: layer);

void main() {
  group('listDevices 契约形状', () {
    test('device_sid/device_mid/meta.name/meta.version 全字段', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({
          'code': 0,
          'msg': 'ok',
          'data': [
            {
              'device_sid': 'sid-1',
              'device_mid': 'mid-1',
              'online': true,
              'created_at': 1700000000,
              'meta': {'name': 'Office', 'platform': 'win32', 'version': '3.18.2'},
            },
          ],
        }),
      );
      final list = await _client(layer).listDevices('jwt-1', deviceMid: 'acct-mid');

      expect(list, hasLength(1));
      final e = list.single;
      expect(e.sid, 'sid-1');
      expect(e.mid, 'mid-1');
      expect(e.name, 'Office');
      expect(e.platform, 'win32');
      expect(e.appVersion, '3.18.2');
      expect(e.online, isTrue);
      expect(
        e.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
      expect(layer.url.toString(), 'https://zcode.z.ai/api/v1/remote/device');
    });

    test('请求头全套：Bearer + X-Device-Mid + x-request-id + App-Version', () async {
      final layer = _FakeLayer((_, _) async => _ok({'code': 0, 'data': []}));
      await _client(layer).listDevices('jwt-1', deviceMid: 'acct-mid');

      final h = layer.headers!;
      expect(h['Authorization'], 'Bearer jwt-1');
      expect(h['X-Device-Mid'], 'acct-mid');
      expect(h['x-request-id'], isNotEmpty);
      expect(h['X-ZCode-App-Version'], isNotEmpty);
      expect(h['X-Platform'], isNotEmpty);
    });

    test('无 deviceMid 时省略 X-Device-Mid', () async {
      final layer = _FakeLayer((_, _) async => _ok({'code': 0, 'data': []}));
      await _client(layer).listDevices('jwt-1');
      expect(layer.headers!.containsKey('X-Device-Mid'), isFalse);
    });
  });

  group('形状容错', () {
    test('顶层别名 sid/mid/name/app_version', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({
          'code': 0,
          'data': [
            {
              'sid': 's2',
              'mid': 'm2',
              'name': 'Alias',
              'app_version': '3.16.1',
              'online': false,
            },
          ],
        }),
      );
      final list = await _client(layer).listDevices('jwt');
      expect(list.single.sid, 's2');
      expect(list.single.mid, 'm2');
      expect(list.single.name, 'Alias');
      expect(list.single.appVersion, '3.16.1');
      expect(list.single.online, isFalse);
    });

    test('外壳漂移：body 直接是数组', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok([
          {'device_sid': 's3', 'device_mid': 'm3'},
        ]),
      );
      final list = await _client(layer).listDevices('jwt');
      expect(list.single.sid, 's3');
    });

    test('外壳漂移：data 为 {devices:[...]} 包装', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({
          'code': 0,
          'data': {
            'devices': [
              {'device_sid': 's4', 'device_mid': 'm4'},
            ],
          },
        }),
      );
      expect((await _client(layer).listDevices('jwt')).single.sid, 's4');
    });

    test('外壳漂移：data 为单条设备对象', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({
          'code': 0,
          'data': {'device_sid': 's5', 'device_mid': 'm5'},
        }),
      );
      expect((await _client(layer).listDevices('jwt')).single.sid, 's5');
    });

    test('坏条目跳过（非 Map / 无 sid），好条目保留', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({
          'code': 0,
          'data': [
            'junk',
            {'device_mid': 'no-sid'},
            {'device_sid': 's6', 'device_mid': 'm6'},
          ],
        }),
      );
      final list = await _client(layer).listDevices('jwt');
      expect(list, hasLength(1));
      expect(list.single.sid, 's6');
    });

    test('created_at 毫秒值', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({
          'code': 0,
          'data': [
            {'device_sid': 's7', 'device_mid': 'm7', 'created_at': 1700000000000},
          ],
        }),
      );
      expect(
        (await _client(layer).listDevices('jwt')).single.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    });

    test('code:0 且无 data → 空列表', () async {
      final layer = _FakeLayer((_, _) async => _ok({'code': 0}));
      expect(await _client(layer).listDevices('jwt'), isEmpty);
    });
  });

  group('失败分类', () {
    test('401 → unauthorized', () async {
      final layer = _FakeLayer((_, _) async => _ok(null, status: 401));
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.kind,
            'kind',
            RemoteDeviceErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('500 → http', () async {
      final layer = _FakeLayer((_, _) async => _ok(null, status: 500));
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.kind,
            'kind',
            RemoteDeviceErrorKind.http,
          ),
        ),
      );
    });

    test('业务码非 0 → api + apiCode', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({'code': 1006, 'msg': 'no permission'}),
      );
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>()
              .having((e) => e.kind, 'kind', RemoteDeviceErrorKind.api)
              .having((e) => e.apiCode, 'apiCode', 1006),
        ),
      );
    });

    test('空正文 → badResponse', () async {
      final layer = _FakeLayer((_, _) async => _ok(null));
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.kind,
            'kind',
            RemoteDeviceErrorKind.badResponse,
          ),
        ),
      );
    });

    test('data 类型漂移 → badResponse', () async {
      final layer = _FakeLayer(
        (_, _) async => _ok({'code': 0, 'data': 'not-a-list'}),
      );
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.kind,
            'kind',
            RemoteDeviceErrorKind.badResponse,
          ),
        ),
      );
    });

    test('ZaiAuthException(401) 映射 unauthorized', () async {
      final layer = _FakeLayer(
        (_, _) async => throw const ZaiAuthException(
          ZaiAuthErrorKind.http,
          message: 'rejected',
          statusCode: 401,
        ),
      );
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.kind,
            'kind',
            RemoteDeviceErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('ZaiAuthException(network) 映射 network', () async {
      final layer = _FakeLayer(
        (_, _) async => throw const ZaiAuthException(
          ZaiAuthErrorKind.network,
          message: 'boom',
        ),
      );
      await expectLater(
        _client(layer).listDevices('jwt'),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.kind,
            'kind',
            RemoteDeviceErrorKind.network,
          ),
        ),
      );
    });

    test('空 jwt → unauthorized，且不发请求', () async {
      var called = false;
      final layer = _FakeLayer((_, _) async {
        called = true;
        return _ok({'code': 0, 'data': []});
      });
      await expectLater(
        _client(layer).listDevices('  '),
        throwsA(
          isA<RemoteDeviceException>().having(
            (e) => e.isUnauthorized,
            'isUnauthorized',
            isTrue,
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('remoteDeviceFromEntry 构造', () {
    test('params 带 sid/mid/name/app_version，kind v2，baseUrl 官方 V4', () {
      final device = remoteDeviceFromEntry(
        const RemoteDeviceEntry(
          sid: 'sid-1',
          mid: 'mid-1',
          name: 'Office',
          appVersion: '3.18.2',
          online: true,
        ),
        id: 'dev-1',
        now: DateTime(2026, 11, 15),
      );
      expect(device.id, 'dev-1');
      expect(device.baseUrl, 'https://zcode.z.ai/remote/v4');
      expect(device.kind, DeviceKind.v2);
      expect(device.label, 'Office');
      expect(device.params, {
        'sid': 'sid-1',
        'mid': 'mid-1',
        'name': 'Office',
        'app_version': '3.18.2',
      });
      expect(device.sid, 'sid-1');
    });

    test('name/app_version 为空时省略对应键', () {
      final device = remoteDeviceFromEntry(
        const RemoteDeviceEntry(sid: 'sid-2', mid: 'mid-2'),
        id: 'dev-2',
      );
      expect(device.params, {'sid': 'sid-2', 'mid': 'mid-2'});
      expect(device.label, '');
      expect(device.kind, DeviceKind.v2);
    });
  });

  group('findAccountDeviceDuplicate 去重', () {
    final existing = [
      RemoteDevice(
        id: 'dev-a',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'sid': 'sid-a', 'mid': 'mid-a', 'name': 'Office'},
        label: 'Office',
        createdAt: DateTime(2026),
        kind: DeviceKind.v2,
      ),
    ];

    test('同 SID → sid', () {
      final dup = findAccountDeviceDuplicate(existing, const RemoteDeviceEntry(
        sid: 'sid-a',
        mid: 'other-mid',
        name: 'Other',
      ));
      expect(dup, isNotNull);
      expect(dup!.kind, AccountDeviceDuplicateKind.sid);
      expect(dup.device.id, 'dev-a');
    });

    test('同 MID（不同 SID）→ mid', () {
      final dup = findAccountDeviceDuplicate(existing, const RemoteDeviceEntry(
        sid: 'sid-new',
        mid: 'mid-a',
        name: 'Other',
      ));
      expect(dup, isNotNull);
      expect(dup!.kind, AccountDeviceDuplicateKind.mid);
    });

    test('同名（不同 MID/SID）→ name', () {
      final dup = findAccountDeviceDuplicate(existing, const RemoteDeviceEntry(
        sid: 'sid-b',
        mid: 'mid-b',
        name: 'Office',
      ));
      expect(dup, isNotNull);
      expect(dup!.kind, AccountDeviceDuplicateKind.name);
    });

    test('完全不同 → null', () {
      expect(
        findAccountDeviceDuplicate(existing, const RemoteDeviceEntry(
          sid: 'sid-c',
          mid: 'mid-c',
          name: 'Home',
        )),
        isNull,
      );
    });

    test('空 mid 记录不参与 mid 去重', () {
      expect(
        findAccountDeviceDuplicate(existing, const RemoteDeviceEntry(
          sid: 'sid-d',
          mid: '',
          name: 'Home',
        )),
        isNull,
      );
    });
  });
}
