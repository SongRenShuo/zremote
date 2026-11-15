import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/update_checker.dart';

/// 假 HttpClientAdapter：默认按 URL 立即回 (status, body)，
/// 也可切换到「闸门模式」——fetch 挂起直到测试 complete（用于连点/卸载用例）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.status = 200, this.body, this.rawBody});

  int status;
  Object? body;
  String? rawBody;

  /// 非 null 时 fetch 挂起，由测试用 [complete] 放行。
  Completer<ResponseBody>? gate;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final g = gate;
    if (g != null) return g.future;
    final text = rawBody ?? jsonEncode(body ?? const {});
    return ResponseBody.fromString(
      text,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// fetch 直接抛错（用于超时/网络分类）。
class _ThrowAdapter implements HttpClientAdapter {
  _ThrowAdapter(this.error);

  final Object error;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw error;

  @override
  void close({bool force = false}) {}
}

const _releaseBody = {
  'tag_name': 'v2.1.0',
  'html_url': 'https://github.com/SongRenShuo/zremote/releases/tag/v2.1.0',
  'assets': [
    {'name': 'app-release.apk', 'browser_download_url': 'https://x/apk'},
    {'name': 'zremote-ios-unsigned.ipa', 'browser_download_url': 'https://x/ipa'},
  ],
};

Dio _dio(HttpClientAdapter adapter) => Dio(BaseOptions(
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ))
  ..httpClientAdapter = adapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateChecker.parseRelease（P3-5）', () {
    const body = {
      'tag_name': 'v2.0.0',
      'html_url': 'https://github.com/SongRenShuo/zremote/releases/tag/v2.0.0',
      'assets': [
        {'name': 'app-release.apk', 'browser_download_url': 'https://x/apk'},
        {'name': 'zremote-ios-unsigned.ipa', 'browser_download_url': 'https://x/ipa'},
      ],
    };

    test('有新版本：解析 tag/apk 并比较', () {
      final info = UpdateChecker.parseRelease('1.7.0+9', body);
      expect(info, isNotNull);
      expect(info!.latestVersion, '2.0.0');
      expect(info.currentVersion, '1.7.0');
      expect(info.apkUrl, 'https://x/apk');
      expect(info.releaseUrl, contains('v2.0.0'));
    });

    test('同版本/更旧：返回 null（不提示）', () {
      expect(UpdateChecker.parseRelease('2.0.0', body), isNull);
      expect(UpdateChecker.parseRelease('3.1.4', body), isNull);
    });

    test('形状漂移容错：非 Map / 缺 tag_name / 乱版本', () {
      expect(UpdateChecker.parseRelease('1.0.0', null), isNull);
      expect(UpdateChecker.parseRelease('1.0.0', 'string'), isNull);
      expect(UpdateChecker.parseRelease('1.0.0', {'html_url': 'x'}), isNull);
      expect(
        UpdateChecker.parseRelease('1.0.0', {'tag_name': 'not-a-ver'}),
        isNull,
      );
      expect(
        UpdateChecker.parseRelease('garbage', body),
        isNull, // 当前版本不合法 → 保守无更新
      );
    });

    test('无 apk 资产时 apkUrl 为 null 但仍有 releaseUrl 兜底', () {
      final info = UpdateChecker.parseRelease('1.7.0', {
        'tag_name': 'v1.9.0',
      });
      expect(info, isNotNull);
      expect(info!.apkUrl, isNull);
      expect(info.releaseUrl, contains('releases'));
      expect(info.releaseUrl, contains('SongRenShuo/zremote'));
    });
  });

  group('compareVersions / normalizeVersion 纯函数', () {
    test('三段式比较与 v 前缀/+build 剥离', () {
      expect(UpdateChecker.normalizeVersion('v2.0.0'), '2.0.0');
      expect(UpdateChecker.normalizeVersion('1.7.0+9'), '1.7.0');
      expect(UpdateChecker.compareVersions('1.7.0', '2.0.0'), -1);
      expect(UpdateChecker.compareVersions('2.0.0', '2.0.0'), 0);
      expect(UpdateChecker.compareVersions('2.1.0', '2.0.9'), 1);
      expect(UpdateChecker.compareVersions('2.0.10', '2.0.9'), 1);
      expect(UpdateChecker.compareVersions('bad', '2.0.0'), 0); // 保守
    });
  });

  group('checkLatest 三态与失败分类（v21 修）', () {
    test('默认 API 指向本仓 SongRenShuo/zremote', () {
      expect(kUpdateRepoSlug, 'SongRenShuo/zremote');
      expect(kUpdateReleasesApi, contains('repos/SongRenShuo/zremote'));
      expect(kUpdateReleasesApi, isNot(contains('pjpv')));
    });

    test('200 有新版本 → updateAvailable(info)', () async {
      final adapter = _FakeAdapter(body: _releaseBody);
      final result = await UpdateChecker(
        client: _dio(adapter),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.isUpdateAvailable, isTrue);
      expect(result.isUpToDate, isFalse);
      expect(result.isFailed, isFalse);
      expect(result.update!.latestVersion, '2.1.0');
      expect(result.update!.currentVersion, '2.0.1');
      expect(result.update!.apkUrl, 'https://x/apk');
      expect(adapter.requests, 1);
    });

    test('200 版本相同 → upToDate（不再返回 null）', () async {
      final result = await UpdateChecker(
        client: _dio(_FakeAdapter(body: _releaseBody)),
        currentVersion: '2.1.0',
      ).checkLatest();

      expect(result.isUpToDate, isTrue);
      expect(result.update, isNull);
      expect(result.currentVersion, '2.1.0');
    });

    test('200 本地版本更新 → upToDate', () async {
      final result = await UpdateChecker(
        client: _dio(_FakeAdapter(body: _releaseBody)),
        currentVersion: '9.9.9',
      ).checkLatest();

      expect(result.isUpToDate, isTrue);
    });

    test('403 限流 → failed(rateLimited)（Dio badResponse 路径）', () async {
      final adapter = _FakeAdapter(status: 403, body: const {'message': 'rate'});
      final result = await UpdateChecker(
        client: _dio(adapter),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.isFailed, isTrue);
      expect(result.reason, UpdateFailureReason.rateLimited);
      expect(result.statusCode, 403);
    });

    test('非 2xx（Dio 放行状态码）→ failed(httpError) 带状态码', () async {
      final dio = Dio(
        BaseOptions(validateStatus: (_) => true),
      )..httpClientAdapter = _FakeAdapter(status: 500, body: const {});

      final result = await UpdateChecker(
        client: dio,
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.isFailed, isTrue);
      expect(result.reason, UpdateFailureReason.httpError);
      expect(result.statusCode, 500);
    });

    test('超时 → failed(timeout)', () async {
      final result = await UpdateChecker(
        client: _dio(
          _ThrowAdapter(
            DioException.connectionTimeout(
              requestOptions: RequestOptions(path: '/'),
              timeout: const Duration(seconds: 10),
            ),
          ),
        ),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.isFailed, isTrue);
      expect(result.reason, UpdateFailureReason.timeout);
    });

    test('接收超时 → failed(timeout)', () async {
      final result = await UpdateChecker(
        client: _dio(
          _ThrowAdapter(
            DioException.receiveTimeout(
              requestOptions: RequestOptions(path: '/'),
              timeout: const Duration(seconds: 10),
            ),
          ),
        ),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.reason, UpdateFailureReason.timeout);
    });

    test('坏 JSON → failed(badJson)', () async {
      final result = await UpdateChecker(
        client: _dio(
          _FakeAdapter(status: 200, rawBody: '<html>not json</html>'),
        ),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.isFailed, isTrue);
      expect(result.reason, UpdateFailureReason.badJson);
    });

    test('200 但响应不是对象 → failed(badJson)', () async {
      final result = await UpdateChecker(
        client: _dio(_FakeAdapter(status: 200, rawBody: '"a-string"')),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.reason, UpdateFailureReason.badJson);
    });

    test('缺 tag_name → failed(badJson)', () async {
      final result = await UpdateChecker(
        client: _dio(_FakeAdapter(body: const {'html_url': 'x'})),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.reason, UpdateFailureReason.badJson);
    });

    test('tag_name 版本号非法 → failed(badVersion)', () async {
      final result = await UpdateChecker(
        client: _dio(
          _FakeAdapter(body: const {'tag_name': 'not-a-ver'}),
        ),
        currentVersion: '2.0.1',
      ).checkLatest();

      expect(result.isFailed, isTrue);
      expect(result.reason, UpdateFailureReason.badVersion);
    });

    test('当前版本号非法 → failed(badVersion)，不发请求', () async {
      final adapter = _FakeAdapter(body: _releaseBody);
      final result = await UpdateChecker(
        client: _dio(adapter),
        currentVersion: 'garbage',
      ).checkLatest();

      expect(result.reason, UpdateFailureReason.badVersion);
      expect(adapter.requests, 0);
    });

    test('当前版本为空 → failed(badVersion)', () async {
      final result = await UpdateChecker(
        client: _dio(_FakeAdapter(body: _releaseBody)),
        currentVersion: ' ',
      ).checkLatest();

      expect(result.reason, UpdateFailureReason.badVersion);
    });

    test('baseUrl 可注入（测试桩地址）', () async {
      final adapter = _FakeAdapter(body: _releaseBody);
      final result = await UpdateChecker(
        client: _dio(adapter),
        currentVersion: '2.0.1',
        baseUrl: 'http://127.0.0.1:9/releases/latest',
      ).checkLatest();

      expect(result.isUpdateAvailable, isTrue);
    });
  });
}
