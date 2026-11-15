import 'package:dio/dio.dart';

/// 上游仓库（本仓即 pjpv/zremote 的 fork，Releases 以本仓为准）。
const kUpdateRepoSlug = 'SongRenShuo/zremote';

/// 默认 Releases/latest API。
const kUpdateReleasesApi =
    'https://api.github.com/repos/$kUpdateRepoSlug/releases/latest';

/// 失败分类：调用方按枚举映射可读文案（UI 侧 l10n）。
enum UpdateFailureReason {
  /// 连接/发送/接收超时。
  timeout,

  /// 网络层失败（DNS、连接被拒、无网等）。
  network,

  /// HTTP 403（GitHub 未认证限流）。
  rateLimited,

  /// 其他非 2xx 响应。
  httpError,

  /// 响应不是合法 JSON / 结构不符合 Releases latest。
  badJson,

  /// 版本号无法解析（当前版本或 tag_name）。
  badVersion,
}

/// 三态检查结果：[status] 决定语义，禁止用 nullable 表达「无更新 vs 失败」。
enum UpdateCheckStatus { upToDate, updateAvailable, failed }

class UpdateCheckResult {
  const UpdateCheckResult.upToDate(String this.currentVersion)
    : status = UpdateCheckStatus.upToDate,
      update = null,
      reason = null,
      statusCode = null;

  UpdateCheckResult.updateAvailable(UpdateInfo this.update)
    : status = UpdateCheckStatus.updateAvailable,
      currentVersion = update.currentVersion,
      reason = null,
      statusCode = null;

  const UpdateCheckResult.failed(this.reason, {this.statusCode})
    : status = UpdateCheckStatus.failed,
       currentVersion = null,
       update = null;

  final UpdateCheckStatus status;

  /// 当前版本（归一化后，如 2.0.1）；失败态为 null。
  final String? currentVersion;

  /// 有新版本时的信息；其余状态为 null。
  final UpdateInfo? update;

  final UpdateFailureReason? reason;

  /// 非 2xx 响应的 HTTP 状态码（仅 httpError/rateLimited 非空）。
  final int? statusCode;

  bool get isUpToDate => status == UpdateCheckStatus.upToDate;
  bool get isUpdateAvailable => status == UpdateCheckStatus.updateAvailable;
  bool get isFailed => status == UpdateCheckStatus.failed;
}

/// 更新检查（P3-5，开发计划 20261115-0901；v21 修车道）。
///
/// 数据源：GitHub Releases（仓库 [kUpdateRepoSlug]，公开 API 无需凭据）。
/// 只比较版本提示，不自动下载；结果为三态 [UpdateCheckResult]，
/// 「无更新 / 网络失败 / 形状异常」不再压成 null。
class UpdateChecker {
  UpdateChecker({Dio? client, this.currentVersion, String? baseUrl})
    : _client = client ?? Dio(),
      _baseUrl = baseUrl ?? kUpdateReleasesApi;

  final Dio _client;

  /// Releases/latest API 地址（测试可注入本地桩）。
  final String _baseUrl;

  /// 当前版本（如 2.0.1）；null/空或不可解析 → failed(badVersion)。
  final String? currentVersion;

  Future<UpdateCheckResult> checkLatest() async {
    final current = currentVersion;
    if (current == null || current.trim().isEmpty) {
      return const UpdateCheckResult.failed(UpdateFailureReason.badVersion);
    }
    final cur = normalizeVersion(current);
    if (cur == null) {
      return const UpdateCheckResult.failed(UpdateFailureReason.badVersion);
    }
    try {
      final resp = await _client.get<Object?>(
        _baseUrl,
        options: Options(
          responseType: ResponseType.json,
          headers: const {'Accept': 'application/vnd.github+json'},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final code = resp.statusCode ?? 200;
      if (code != 200) {
        return UpdateCheckResult.failed(
          code == 403
              ? UpdateFailureReason.rateLimited
              : UpdateFailureReason.httpError,
          statusCode: code,
        );
      }
      final body = resp.data;
      if (body is! Map) {
        return const UpdateCheckResult.failed(UpdateFailureReason.badJson);
      }
      final tag = body['tag_name'];
      if (tag is! String || tag.trim().isEmpty) {
        return const UpdateCheckResult.failed(UpdateFailureReason.badJson);
      }
      final latest = normalizeVersion(tag);
      if (latest == null) {
        return const UpdateCheckResult.failed(UpdateFailureReason.badVersion);
      }
      final info = parseRelease(cur, body);
      if (info == null) return UpdateCheckResult.upToDate(cur);
      return UpdateCheckResult.updateAvailable(info);
    } on DioException catch (e) {
      // dio 会把 JSON 解码失败包成 type=unknown、error=FormatException。
      final inner = e.error;
      if (inner is FormatException) {
        return const UpdateCheckResult.failed(UpdateFailureReason.badJson);
      }
      return _classifyDio(e);
    } on FormatException {
      return const UpdateCheckResult.failed(UpdateFailureReason.badJson);
    } on ArgumentError {
      return const UpdateCheckResult.failed(UpdateFailureReason.badJson);
    }
  }

  static UpdateCheckResult _classifyDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const UpdateCheckResult.failed(UpdateFailureReason.timeout);
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return UpdateCheckResult.failed(
          code == 403
              ? UpdateFailureReason.rateLimited
              : UpdateFailureReason.httpError,
          statusCode: code,
        );
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        return const UpdateCheckResult.failed(UpdateFailureReason.network);
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
        return const UpdateCheckResult.failed(UpdateFailureReason.network);
      case DioExceptionType.unknown:
        return e.error is FormatException
            ? const UpdateCheckResult.failed(UpdateFailureReason.badJson)
            : const UpdateCheckResult.failed(UpdateFailureReason.network);
    }
  }

  /// 纯函数：解析 Releases/latest 响应并比较版本；无更新/形状不对返回 null。
  static UpdateInfo? parseRelease(String current, Object? body) {
    if (body is! Map) return null;
    final tag = body['tag_name'];
    final url = body['html_url'];
    if (tag is! String || tag.trim().isEmpty) return null;
    final latest = normalizeVersion(tag);
    final cur = normalizeVersion(current);
    if (latest == null || cur == null) return null;
    if (compareVersions(cur, latest) >= 0) return null;
    String? apk;
    final assets = body['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is Map &&
            a['name'] is String &&
            a['browser_download_url'] is String) {
          final name = a['name'] as String;
          if (name.endsWith('.apk')) {
            apk = a['browser_download_url'] as String;
            break;
          }
        }
      }
    }
    return UpdateInfo(
      currentVersion: cur,
      latestVersion: latest,
      releaseUrl: url is String
          ? url
          : 'https://github.com/$kUpdateRepoSlug/releases',
      apkUrl: apk,
    );
  }

  /// v1.2.3 / 1.2.3+9 → 1.2.3（剥 v 前缀与 +build 元数据）。
  static String? normalizeVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    if (!_versionLike(s)) return null;
    return s;
  }

  /// -1 a<b / 0 相等 / 1 a>b；解析失败按相等处理（保守不提示更新）。
  /// 只比较 major.minor.patch（预发布/后缀忽略——本仓 tag 皆为三段式）。
  static int compareVersions(String a, String b) {
    final pa = _triple(a);
    final pb = _triple(b);
    if (pa == null || pb == null) return 0;
    for (var i = 0; i < 3; i++) {
      if (pa[i]! < pb[i]!) return -1;
      if (pa[i]! > pb[i]!) return 1;
    }
    return 0;
  }

  static List<int?>? _triple(String v) {
    final head = v.split(RegExp('[-+]')).first;
    final parts = head.split('.');
    if (parts.length != 3) return null;
    final out = <int?>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }

  static bool _versionLike(String s) => _triple(s) != null;
}

class UpdateInfo {
  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    this.apkUrl,
  });

  final String currentVersion;
  final String latestVersion;
  final String releaseUrl;
  final String? apkUrl;
}
