import 'package:dio/dio.dart';

/// 更新检查（P3-5，开发计划 20261115-0901）。
///
/// 数据源：GitHub Releases（仓库 pjpv/zremote，公开 API 无需凭据）。
/// 只比较版本提示，不自动下载；网络失败静默返回 null（设置页手动触发时
/// 由调用方提示失败）。
class UpdateChecker {
  UpdateChecker({Dio? client, this.currentVersion})
    : _client = client ?? Dio();

  final Dio _client;

  /// 当前版本（如 1.7.0）；null 时视为未知、永远返回「无更新」。
  final String? currentVersion;

  static const _releasesApi =
      'https://api.github.com/repos/pjpv/zremote/releases/latest';

  Future<UpdateInfo?> checkLatest() async {
    final current = currentVersion;
    if (current == null || current.trim().isEmpty) return null;
    try {
      final resp = await _client.get<Object?>(
        _releasesApi,
        options: Options(
          responseType: ResponseType.json,
          headers: const {'Accept': 'application/vnd.github+json'},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      return parseRelease(current, resp.data);
    } on DioException {
      return null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
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
          : 'https://github.com/pjpv/zremote/releases',
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
