import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/endpoint_probe.dart';
import 'package:zremote/services/quota_client.dart';

/// 端点探测的假 HttpClientAdapter：按 URL 分发 (body, statusCode)。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final ResponseBody Function(Uri url) responder;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responder(options.uri);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, [Map<String, dynamic> body = const {}]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Dio dioWith(_FakeAdapter adapter) =>
      Dio(BaseOptions(connectTimeout: const Duration(seconds: 2)))
        ..httpClientAdapter = adapter;

  group('EndpointProbe.run（P6-1）', () {
    test('无 token：仅探测 client/configs，billing/balance 跳过并记原因（零多余调用）',
        () async {
      final adapter = _FakeAdapter((url) => _json(200, {'data': {}}));
      final probe = EndpointProbe(dio: dioWith(adapter));

      final results = await probe.run();

      expect(results, hasLength(2));
      expect(results.first.label, 'client/configs');
      expect(results.first.ok, isTrue);
      expect(results.first.statusCode, 200);
      expect(results.first.elapsedMs, greaterThanOrEqualTo(0));
      expect(results.last.label, 'billing/balance');
      expect(results.last.skipped, isTrue);
      expect(results.last.skipReason, kEndpointSkipNoToken);
      // 反向验证（S2）：无 token 不发 billing 请求。
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.toString(), kEndpointClientConfigsUrl);
    });

    test('有 zai JWT：billing/balance 带 Bearer 头与 app_version 查询参数',
        () async {
      final adapter = _FakeAdapter((url) => _json(200, {'code': 200}));
      final probe = EndpointProbe(
        dio: dioWith(adapter),
        tokenProvider: () async =>
            const QuotaTokens(zaiJwt: 'jwt-test-1'),
      );

      final results = await probe.run();

      expect(results, hasLength(2));
      expect(results.last.skipped, isFalse);
      expect(results.last.ok, isTrue);
      expect(adapter.requests, hasLength(2));
      final billing = adapter.requests.last;
      expect(billing.uri.path, contains('billing/balance'));
      expect(billing.uri.queryParameters['app_version'], kQuotaAppVersion);
      expect(billing.headers['Authorization'], 'Bearer jwt-test-1');
      expect(billing.headers['User-Agent'], 'ZCode/$kQuotaAppVersion');
      expect(billing.headers['x-request-id'], isNotNull);
      // 公开端点不带 Authorization。
      expect(
        adapter.requests.first.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test('非 2xx 状态码是读数不是异常：401 记录且 ok=false', () async {
      final adapter = _FakeAdapter((url) => url.path.contains('configs')
          ? _json(200)
          : _json(401, {'code': 401, 'msg': 'unauthorized'}));
      final probe = EndpointProbe(
        dio: dioWith(adapter),
        tokenProvider: () async => const QuotaTokens(zaiJwt: 'jwt-test-1'),
      );

      final results = await probe.run();

      expect(results.last.statusCode, 401);
      expect(results.last.ok, isFalse);
      expect(results.last.error, isNull);
    });

    test('连接失败（DioException）落 error 摘要，不抛不卡', () async {
      final adapter = _FakeAdapter((_) => throw DioException.connectionError(
            requestOptions: RequestOptions(path: '/'),
            reason: 'connection refused',
          ));
      final probe = EndpointProbe(dio: dioWith(adapter));

      final results = await probe.run();

      expect(results.first.ok, isFalse);
      expect(results.first.statusCode, isNull);
      expect(results.first.error, contains('connection refused'));
      expect(results.first.elapsedMs, greaterThanOrEqualTo(0));
    });

    test('tokenProvider 抛错视同无 token（降级跳过）', () async {
      final adapter = _FakeAdapter((_) => _json(200));
      final probe = EndpointProbe(
        dio: dioWith(adapter),
        tokenProvider: () async => throw StateError('vault locked'),
      );

      final results = await probe.run();

      expect(results.last.skipped, isTrue);
      expect(adapter.requests, hasLength(1));
    });
  });

  group('endpointProbeReportLines（复制报告段）', () {
    test('ok / skip / error 三行形态', () {
      final lines = endpointProbeReportLines(const [
        EndpointProbeResult(
          label: 'client/configs',
          url: 'https://zcode.z.ai/api/v1/client/configs',
          statusCode: 200,
          elapsedMs: 143,
        ),
        EndpointProbeResult(
          label: 'billing/balance',
          url: 'https://zcode.z.ai/api/v1/zcode-plan/billing/balance',
          skipped: true,
          skipReason: kEndpointSkipNoToken,
        ),
        EndpointProbeResult(
          label: 'bigmodel/limit',
          url: 'https://bigmodel.cn/x',
          elapsedMs: 9,
          error: 'DioException: connection timeout',
        ),
      ]);
      expect(lines, contains('— 端点探测 —'));
      expect(lines, contains('client/configs 200 143ms'));
      expect(lines, contains('billing/balance SKIP no-token'));
      expect(
        lines,
        contains('bigmodel/limit ERR 9ms DioException: connection timeout'),
      );
    });

    test('空结果零输出（探测前复制报告不落段）', () {
      expect(endpointProbeReportLines(const []), isEmpty);
    });
  });
}
