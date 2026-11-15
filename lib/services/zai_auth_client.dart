import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// zcode.z.ai OAuth CLI 通路客户端（开发计划 20261115-0901 附录 A.1/A.3）。
///
/// 形态按 P0-1 实测裁定（经验总结 20261115-0930）：原生账密登录放弃，
/// 登录在官方页完成，本客户端只负责无需验证码的四端点——
/// `cli/init`、`cli/poll`、`oauth/profile`、`oauth/revoke-all`。
class ZaiAuthProvider {
  const ZaiAuthProvider._(this.wireName, this.index);

  static const zaiCn = ZaiAuthProvider._('zai_cn', 0);
  static const zai = ZaiAuthProvider._('zai', 1);
  static const bigmodel = ZaiAuthProvider._('bigmodel', 2);

  static const values = [zaiCn, zai, bigmodel];

  /// 线上协议的 provider 名（body 与 `oauth:active_provider` 同款）。
  final String wireName;

  /// 稳定序号（UI 选择器排序用）。
  final int index;

  static ZaiAuthProvider? tryFromWire(String? raw) {
    for (final p in values) {
      if (p.wireName == raw) return p;
    }
    return null;
  }

  @override
  String toString() => wireName;
}

enum ZaiAuthErrorKind {
  /// 网络层失败（DNS/连接重置等）。
  network,

  /// 轮询总超时。
  timeout,

  /// HTTP 状态码非 2xx。
  http,

  /// 业务码非 0（`{code: !0}`）。
  api,

  /// 响应形状不可解析（字段缺失/类型漂移/authorize_url 非 https）。
  badResponse,
}

class ZaiAuthException implements Exception {
  const ZaiAuthException(
    this.kind, {
    required this.message,
    this.statusCode,
    this.apiCode,
    this.detail,
  });

  final ZaiAuthErrorKind kind;
  final String message;
  final int? statusCode;
  final int? apiCode;
  final Object? detail;

  @override
  String toString() => 'ZaiAuthException($kind, $message'
      '${statusCode == null ? '' : ', http=$statusCode'}'
      '${apiCode == null ? '' : ', code=$apiCode'})';
}

class AuthHttpResponse {
  const AuthHttpResponse({required this.statusCode, this.body});

  final int statusCode;

  /// 已解码的 JSON 对象；非对象（或无 body）为 null。
  final Map<String, dynamic>? body;
}

/// 可注入的 HTTP 层（单测用假实现，产品走 dio）。
abstract class AuthHttpLayer {
  Future<AuthHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  });

  Future<AuthHttpResponse> get(Uri url, {Map<String, String>? headers});
}

class DioAuthHttpLayer implements AuthHttpLayer {
  DioAuthHttpLayer([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<AuthHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    try {
      final r = await _dio.postUri<Object>(
        url,
        data: body,
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      return AuthHttpResponse(
        statusCode: r.statusCode ?? 0,
        body: r.data is Map<String, dynamic>
            ? Map<String, dynamic>.from(r.data as Map<String, dynamic>)
            : null,
      );
    } on DioException catch (e) {
      throw _dioError(e);
    }
  }

  @override
  Future<AuthHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    try {
      final r = await _dio.getUri<Object>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      return AuthHttpResponse(
        statusCode: r.statusCode ?? 0,
        body: r.data is Map<String, dynamic>
            ? Map<String, dynamic>.from(r.data as Map<String, dynamic>)
            : null,
      );
    } on DioException catch (e) {
      throw _dioError(e);
    }
  }

  ZaiAuthException _dioError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return ZaiAuthException(
        ZaiAuthErrorKind.timeout,
        message: 'http timeout',
        detail: e,
      );
    }
    return ZaiAuthException(
      ZaiAuthErrorKind.network,
      message: 'network failure',
      detail: e,
    );
  }
}

/// 请求头全集（附录 A.3，zcode-switch 实证缺一可能 401/风控）。
class ZaiAuthClientConfig {
  const ZaiAuthClientConfig({
    this.appVersion = kZcodeAppVersion,
    this.platform = 'android-arm64',
    this.releaseChannel = 'stable',
    this.clientLanguage = 'zh-CN',
    this.clientTimezone = 'UTC+08:00',
    this.osCategory = 'Android',
    this.osVersion = '14',
    this.deviceMid,
  });

  static const kZcodeAppVersion = '3.18.2';

  final String appVersion;
  final String platform;
  final String releaseChannel;
  final String clientLanguage;
  final String clientTimezone;
  final String osCategory;
  final String osVersion;

  /// 每账号稳定值（Account.virtualDeviceMid）。
  final String? deviceMid;

  ZaiAuthClientConfig copyWith({String? deviceMid}) => ZaiAuthClientConfig(
    appVersion: appVersion,
    platform: platform,
    releaseChannel: releaseChannel,
    clientLanguage: clientLanguage,
    clientTimezone: clientTimezone,
    osCategory: osCategory,
    osVersion: osVersion,
    deviceMid: deviceMid ?? this.deviceMid,
  );

  /// 运行时解析（device_info_plus + Platform），登录链路开工前取一次。
  static Future<ZaiAuthClientConfig> resolveRuntime({String? deviceMid}) async {
    var osCategory = 'Unknown';
    var osVersion = '';
    var platform = 'unknown';
    try {
      if (Platform.isAndroid) {
        platform = 'android-arm64';
        osCategory = 'Android';
        final info = await DeviceInfoPlugin().androidInfo;
        osVersion = info.version.release;
      } else if (Platform.isIOS) {
        platform = 'ios-arm64';
        osCategory = 'iOS';
        final info = await DeviceInfoPlugin().iosInfo;
        osVersion = info.systemVersion;
      }
    } catch (e) {
      debugPrint('[zr-auth] device info resolve failed: $e');
    }
    String language = 'zh-CN';
    try {
      final locale = Platform.localeName;
      if (locale.isNotEmpty) language = locale;
    } catch (_) {}
    final offset = DateTime.now().timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return ZaiAuthClientConfig(
      platform: platform,
      clientLanguage: language,
      clientTimezone: 'UTC$sign$hh:$mm',
      osCategory: osCategory,
      osVersion: osVersion,
      deviceMid: deviceMid,
    );
  }
}

class AuthFlowInit {
  const AuthFlowInit({
    required this.flowId,
    required this.authorizeUrl,
    required this.pollToken,
    required this.pollIntervalSec,
    this.expiresAtMs,
  });

  final String flowId;
  final Uri authorizeUrl;

  /// cli/init 时生成的 32 字节 hex 随机 token，poll 鉴权复用。
  final String pollToken;
  final int? expiresAtMs;
  final int pollIntervalSec;
}

enum AuthFlowStatus { pending, failed, ready }

class AuthPollResult {
  const AuthPollResult({
    required this.status,
    this.token,
    this.user = const {},
    this.providerAccessToken,
    this.providerRefreshToken,
  });

  final AuthFlowStatus status;

  /// ready 时的 zcodejwttoken。
  final String? token;

  /// ready 时的 `{user_id, name, email, avatar}`（宽容：缺席为空表）。
  final Map<String, dynamic> user;

  final String? providerAccessToken;
  final String? providerRefreshToken;
}

class ZaiUserProfile {
  const ZaiUserProfile({
    this.userId = '',
    this.name = '',
    this.email = '',
    this.avatar = '',
  });

  final String userId;
  final String name;
  final String email;
  final String avatar;
}

class ZaiAuthClient {
  ZaiAuthClient({
    this.config = const ZaiAuthClientConfig(),
    AuthHttpLayer? http,
    String Function()? pollTokenGen,
    String Function()? requestIdGen,
    DateTime Function()? now,
  }) : _http = http ?? DioAuthHttpLayer(),
       _pollTokenGen = pollTokenGen ?? _randomPollToken,
       _requestIdGen = requestIdGen ?? const Uuid().v4,
       _now = now ?? DateTime.now;

  static const _base = 'https://zcode.z.ai';
  static const _initPath = '/api/v1/oauth/cli/init';
  static const _pollPathPrefix = '/api/v1/oauth/cli/poll/';
  static const _profilePath = '/api/v1/oauth/profile';
  static const _revokeAllPath = '/api/v1/oauth/revoke-all';

  static const pollTotalTimeout = Duration(minutes: 5);
  static const defaultPollIntervalSec = 5;

  final ZaiAuthClientConfig config;
  final AuthHttpLayer _http;
  final String Function() _pollTokenGen;
  final String Function() _requestIdGen;
  final DateTime Function() _now;

  /// 附录 A.3 头全套。`bearer` 为 pollToken 或 JWT。
  Map<String, String> headersFor({
    required String bearer,
    ZaiAuthClientConfig? configOverride,
  }) {
    final cfg = configOverride ?? config;
    return {
      'User-Agent': 'ZCode/${cfg.appVersion}',
      'HTTP-Referer': 'https://zcode.z.ai',
      'X-Title': 'Z Code@electron',
      'X-ZCode-App-Version': cfg.appVersion,
      'X-Platform': cfg.platform,
      'X-Release-Channel': cfg.releaseChannel,
      'X-Client-Language': cfg.clientLanguage,
      'X-Client-Timezone': cfg.clientTimezone,
      'X-Os-Category': cfg.osCategory,
      'X-Os-Version': cfg.osVersion,
      if (cfg.deviceMid != null && cfg.deviceMid!.isNotEmpty)
        'X-Device-Mid': cfg.deviceMid!,
      'Authorization': 'Bearer $bearer',
      'x-request-id': _requestIdGen(),
    };
  }

  /// `POST /api/v1/oauth/cli/init`：发起设备码流程。
  Future<AuthFlowInit> initFlow(
    ZaiAuthProvider provider, {
    String? deviceMid,
  }) async {
    final pollToken = _pollTokenGen();
    final cfg = _configWithMid(deviceMid);
    final r = await _http.post(
      Uri.parse('$_base$_initPath'),
      headers: headersFor(bearer: pollToken, configOverride: cfg),
      body: {'provider': provider.wireName},
    );
    final data = _envelope(r, context: 'cli/init');
    return AuthFlowInitParse.from(data, pollToken: pollToken);
  }

  /// `GET /api/v1/oauth/cli/poll/{flowId}`：单次轮询。
  Future<AuthPollResult> pollOnce(
    AuthFlowInit flow, {
    String? deviceMid,
  }) async {
    final cfg = _configWithMid(deviceMid);
    final r = await _http.get(
      Uri.parse('$_base$_pollPathPrefix${flow.flowId}'),
      headers: headersFor(bearer: flow.pollToken, configOverride: cfg),
    );
    final data = _envelope(r, context: 'cli/poll');
    return AuthPollParse.resultFrom(data);
  }

  /// 轮询至 ready/failed；按 [AuthFlowInit.pollIntervalSec] 间隔，
  /// 总超时 [timeout]（默认 5 分钟）。失败/超时抛 [ZaiAuthException]。
  Future<AuthPollResult> pollUntilReady(
    AuthFlowInit flow, {
    Duration timeout = pollTotalTimeout,
    void Function(AuthPollResult pending)? onPending,
    String? deviceMid,
  }) async {
    final deadline = _now().add(timeout);
    while (true) {
      final result = await pollOnce(flow, deviceMid: deviceMid);
      switch (result.status) {
        case AuthFlowStatus.ready:
          return result;
        case AuthFlowStatus.failed:
          throw const ZaiAuthException(
            ZaiAuthErrorKind.api,
            message: 'authorization denied (poll failed)',
          );
        case AuthFlowStatus.pending:
          onPending?.call(result);
      }
      if (!_now().isBefore(deadline)) {
        throw const ZaiAuthException(
          ZaiAuthErrorKind.timeout,
          message: 'poll deadline exceeded',
        );
      }
      final wait = Duration(
        seconds: flow.pollIntervalSec.clamp(1, 60),
      );
      final remain = deadline.difference(_now());
      await Future<void>.delayed(
        remain < wait ? remain : wait,
      );
    }
  }

  /// `GET /api/v1/oauth/profile`（Bearer JWT）账号资料。
  Future<ZaiUserProfile> fetchProfile(
    String jwt, {
    String? deviceMid,
  }) async {
    final cfg = _configWithMid(deviceMid);
    final r = await _http.get(
      Uri.parse('$_base$_profilePath'),
      headers: headersFor(bearer: jwt, configOverride: cfg),
    );
    final data = _envelope(r, context: 'oauth/profile');
    return ProfileParse.from(data);
  }

  /// `POST /api/v1/oauth/revoke-all`（Bearer JWT）登出全部凭据。
  Future<void> revokeAll(String jwt, {String? deviceMid}) async {
    final cfg = _configWithMid(deviceMid);
    final r = await _http.post(
      Uri.parse('$_base$_revokeAllPath'),
      headers: headersFor(bearer: jwt, configOverride: cfg),
    );
    _envelope(r, context: 'oauth/revoke-all');
  }

  ZaiAuthClientConfig _configWithMid(String? deviceMid) {
    if (deviceMid == null) return config;
    if (deviceMid == config.deviceMid) return config;
    return config.copyWith(deviceMid: deviceMid);
  }

  /// 解包 `{code, data}` 外壳（M5：区分「形似」与「不可解析」）。
  ///
  /// 外壳漂移（body 本身就是 data 形状）交由各端点 parse 判定；
  /// 此处只处理错误码与外壳存在时的 data 提取。
  @visibleForTesting
  Map<String, dynamic> envelopeOf(
    AuthHttpResponse r, {
    required String context,
  }) => _envelope(r, context: context);

  Map<String, dynamic> _envelope(AuthHttpResponse r, {required String context}) {
    if (r.statusCode >= 500) {
      throw ZaiAuthException(
        ZaiAuthErrorKind.http,
        message: '$context server error',
        statusCode: r.statusCode,
      );
    }
    if (r.statusCode >= 400) {
      throw ZaiAuthException(
        ZaiAuthErrorKind.http,
        message: '$context rejected',
        statusCode: r.statusCode,
      );
    }
    final body = r.body;
    if (body == null) {
      throw ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: '$context: body is not a json object',
        statusCode: r.statusCode,
      );
    }
    final code = body['code'];
    if (code != null && code != 0) {
      throw ZaiAuthException(
        ZaiAuthErrorKind.api,
        message: '$context api error',
        apiCode: code is int ? code : int.tryParse('$code'),
      );
    }
    final data = body['data'];
    if (data == null) return body;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw ZaiAuthException(
      ZaiAuthErrorKind.badResponse,
      message: '$context: data is not an object',
      statusCode: r.statusCode,
    );
  }

  static String _randomPollToken() {
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- JWT exp 解析（P0-7）----

  /// JWT payload.exp → 毫秒。秒值（<1e11）×1000，毫秒值原样；
  /// 非三段/坏 base64/缺 exp → null（不猜）。
  static int? parseJwtExpMs(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    final payload = _decodeBase64Url(parts[1]);
    if (payload == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payload));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final exp = decoded['exp'];
    if (exp is int) return _expToMs(exp);
    if (exp is num) return _expToMs(exp.toInt());
    if (exp is String) {
      final v = int.tryParse(exp);
      if (v != null) return _expToMs(v);
    }
    return null;
  }

  static int _expToMs(int v) => v < 100000000000 ? v * 1000 : v;

  static Uint8List? _decodeBase64Url(String s) {
    final normalized = s.replaceAll('-', '+').replaceAll('_', '_');
    final padded = normalized.length % 4 == 0
        ? normalized
        : normalized + '=' * (4 - normalized.length % 4);
    try {
      return base64.decode(padded);
    } catch (_) {
      return null;
    }
  }

  /// 30s 时钟偏移容忍的过期判定（计划 §2.2）。
  static bool isJwtExpired(
    int jwtExpAtMs, {
    DateTime? now,
    Duration skew = const Duration(seconds: 30),
  }) {
    final n = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return n >= jwtExpAtMs - skew.inMilliseconds;
  }

  /// 过期前 [window]（默认 24h）内预警。
  static bool isJwtExpiringWithin(
    int jwtExpAtMs, {
    Duration window = const Duration(hours: 24),
    DateTime? now,
    Duration skew = const Duration(seconds: 30),
  }) {
    if (isJwtExpired(jwtExpAtMs, now: now, skew: skew)) return true;
    final n = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return jwtExpAtMs - skew.inMilliseconds - n <= window.inMilliseconds;
  }
}

/// 各端点响应解析（独立类以便单测直接喂 data 形状）。
class AuthFlowInitParse {
  static AuthFlowInit from(Map<String, dynamic> data, {required String pollToken}) {
    final flowId = data['flow_id'];
    if (flowId is! String || flowId.isEmpty) {
      throw const ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'cli/init: flow_id missing or not a string',
      );
    }
    final urlRaw = data['authorize_url'];
    if (urlRaw is! String || urlRaw.isEmpty) {
      throw const ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'cli/init: authorize_url missing',
      );
    }
    final uri = Uri.tryParse(urlRaw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'cli/init: authorize_url not parseable: $urlRaw',
      );
    }
    if (uri.scheme != 'https') {
      throw ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'cli/init: authorize_url must be https, got ${uri.scheme}',
      );
    }
    final expiresAt = data['expires_at'];
    int? expiresAtMs;
    if (expiresAt is int) {
      expiresAtMs = expiresAt < 100000000000 ? expiresAt * 1000 : expiresAt;
    } else if (expiresAt is num) {
      expiresAtMs = expiresAt.toInt();
    }
    final intervalRaw = data['poll_interval_sec'];
    var interval = ZaiAuthClient.defaultPollIntervalSec;
    if (intervalRaw is int) interval = intervalRaw;
    if (intervalRaw is num) interval = intervalRaw.toInt();
    return AuthFlowInit(
      flowId: flowId,
      authorizeUrl: uri,
      pollToken: pollToken,
      expiresAtMs: expiresAtMs,
      pollIntervalSec:
          interval <= 0 ? ZaiAuthClient.defaultPollIntervalSec : interval,
    );
  }
}

class AuthPollParse {
  static AuthPollResult resultFrom(Map<String, dynamic> data) {
    final statusRaw = data['status'];
    if (statusRaw is! String) {
      throw const ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'cli/poll: status missing or not a string',
      );
    }
    final status = switch (statusRaw) {
      'pending' => AuthFlowStatus.pending,
      'failed' => AuthFlowStatus.failed,
      'ready' => AuthFlowStatus.ready,
      _ => throw ZaiAuthException(
          ZaiAuthErrorKind.badResponse,
          message: 'cli/poll: unknown status "$statusRaw"',
        ),
    };
    if (status != AuthFlowStatus.ready) {
      return AuthPollResult(status: status);
    }
    final token = data['token'];
    if (token is! String || token.isEmpty) {
      throw const ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'cli/poll: ready without token',
      );
    }
    final user = data['user'] is Map
        ? Map<String, dynamic>.from(data['user'] as Map)
        : const <String, dynamic>{};
    String? access;
    String? refresh;
    final zai = data['zai'];
    if (zai is Map) {
      final t = zai['access_token'];
      if (t is String && t.isNotEmpty) access = t;
    }
    final bigmodel = data['bigmodel'];
    if (bigmodel is Map) {
      final t = bigmodel['access_token'];
      if (t is String && t.isNotEmpty) access = t;
      final rt = bigmodel['refresh_token'];
      if (rt is String && rt.isNotEmpty) refresh = rt;
    }
    return AuthPollResult(
      status: status,
      token: token,
      user: user,
      providerAccessToken: access,
      providerRefreshToken: refresh,
    );
  }
}

class ProfileParse {
  static ZaiUserProfile from(Map<String, dynamic> data) {
    final userRaw = data['user'];
    if (userRaw is! Map) {
      throw const ZaiAuthException(
        ZaiAuthErrorKind.badResponse,
        message: 'oauth/profile: user missing or not an object',
      );
    }
    final user = Map<String, dynamic>.from(userRaw);
    return ZaiUserProfile(
      userId: _str(user['user_id']),
      name: _str(user['name']),
      email: _str(user['email']),
      avatar: _str(user['avatar']),
    );
  }

  static String _str(Object? v) => v is String ? v : '';
}
