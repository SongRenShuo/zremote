import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import 'zai_auth_client.dart';

/// 账号直连设备列表客户端（账户直连调研 P1，计划 P0-8 的「设备列表只读」）。
///
/// 契约（权威源：开源 ZCode `packages/shared/src/web-remote-relay/contract.ts`
/// 与 `docs/web-remote-control/relay-v2-pairing.md`）：
///
/// - `GET https://zcode.z.ai/api/v1/remote/device`（Bearer JWT）→
///   `{code:0, msg, data:[{device_sid, device_mid, online, created_at,
///   meta:{name?, platform?, version?}}]}`。
/// - 列表按**账号**返回（服务端从 JWT 取用户），与本地配对无关；同账号
///   terminal 可对该账号任意**已注册**设备取票连接（token 绑用户+角色、
///   不绑 SID）。手机/本 App 只能列出并连接，不能凭空注册设备。
/// - 请求头全套复用 [ZaiAuthClient.headersFor]（含 `X-Device-Mid`、
///   `x-request-id`、`X-ZCode-App-Version` 等，防风控），勿自造子集。
///
/// 本文件只做**只读**列表；注册/删除等写操作属 P2，禁止在此实现。
/// 形状容错（M5）：字段别名、外壳漂移（裸数组 / `{devices:[…]}` / 单对象）
/// 一律降级解析；完全不像 → [RemoteDeviceErrorKind.badResponse]。

/// 账号下一个已注册设备的服务端记录（列表项）。
@immutable
class RemoteDeviceEntry {
  const RemoteDeviceEntry({
    required this.sid,
    required this.mid,
    this.name = '',
    this.platform = '',
    this.appVersion = '',
    this.online = false,
    this.createdAt,
  });

  /// 连接键（URL `sid`）。
  final String sid;

  /// 设备稳定标识（URL `mid`）；同 MID 重注册会换 SID。
  final String mid;

  /// 主机名（`meta.name`，别名 `name` / `device_name`）。
  final String name;

  /// 平台（`meta.platform`：darwin / win32 / linux …），仅展示。
  final String platform;

  /// ZCode 版本（`meta.version`，别名 `app_version` / `version`）。
  final String appVersion;

  /// 是否有在线连接。
  final bool online;

  /// 该 SID 的注册/启动时间（`created_at`，Unix 秒）。
  final DateTime? createdAt;

  String get displayName => name.trim().isEmpty ? mid : name.trim();

  /// 形状容错解析：别名 + `meta` 嵌套；无 `sid` 的记录不可用 → null。
  static RemoteDeviceEntry? tryParse(Map<String, dynamic> raw) {
    final meta = raw['meta'];
    final metaMap = meta is Map
        ? Map<String, dynamic>.from(meta)
        : const <String, dynamic>{};
    final sid = _firstStr(raw, const ['device_sid', 'sid']);
    if (sid == null || sid.isEmpty) return null;
    final mid = _firstStr(raw, const ['device_mid', 'mid']) ?? '';
    final name =
        _firstStr(metaMap, const ['name']) ??
        _firstStr(raw, const ['device_name', 'name']) ??
        '';
    final platform =
        _firstStr(metaMap, const ['platform']) ??
        _firstStr(raw, const ['platform']) ??
        '';
    final appVersion =
        _firstStr(metaMap, const ['version']) ??
        _firstStr(raw, const ['app_version', 'version']) ??
        '';
    return RemoteDeviceEntry(
      sid: sid,
      mid: mid,
      name: name,
      platform: platform,
      appVersion: appVersion,
      online: _isOnline(raw['online']),
      createdAt: _parseUnixSeconds(raw['created_at']),
    );
  }

  /// online 容忍 bool / 1 / 'true' / '1'。
  static bool _isOnline(Object? v) =>
      v == true || v == 1 || v == 'true' || v == '1';

  static String? _firstStr(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Unix 秒/毫秒与数字串宽松解析；无法识别 → null。
  static DateTime? _parseUnixSeconds(Object? v) {
    if (v is num) {
      if (v > 1e12) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
      if (v > 1e9) {
        return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
      }
      return null;
    }
    if (v is String) {
      final n = double.tryParse(v);
      if (n != null) return _parseUnixSeconds(n);
    }
    return null;
  }
}

/// 列表失败分类。
enum RemoteDeviceErrorKind {
  /// 401：JWT 缺失/过期/无效（未登录）。
  unauthorized,

  /// 网络层失败（DNS/连接重置/超时）。
  network,

  /// HTTP 非 2xx（非 401）。
  http,

  /// 业务码非 0（`{code: !0}`）。
  api,

  /// 响应形状不可解析。
  badResponse,
}

class RemoteDeviceException implements Exception {
  const RemoteDeviceException(
    this.kind, {
    required this.message,
    this.statusCode,
    this.apiCode,
    this.detail,
  });

  final RemoteDeviceErrorKind kind;
  final String message;
  final int? statusCode;
  final int? apiCode;
  final Object? detail;

  bool get isUnauthorized => kind == RemoteDeviceErrorKind.unauthorized;

  @override
  String toString() => 'RemoteDeviceException($kind, $message'
      '${statusCode == null ? '' : ', http=$statusCode'}'
      '${apiCode == null ? '' : ', code=$apiCode'})';
}

/// 可注入 HTTP 层（单测假实现；产品走 dio）。
abstract class RemoteDeviceHttpLayer {
  Future<RemoteDeviceHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
  });
}

class RemoteDeviceHttpResponse {
  const RemoteDeviceHttpResponse({required this.statusCode, this.body});

  final int statusCode;

  /// 已解码 JSON（Map / List / String / null）。
  final Object? body;
}

class DioRemoteDeviceHttpLayer implements RemoteDeviceHttpLayer {
  DioRemoteDeviceHttpLayer([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<RemoteDeviceHttpResponse> get(
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
      return RemoteDeviceHttpResponse(
        statusCode: r.statusCode ?? 0,
        body: r.data,
      );
    } on DioException catch (e) {
      throw RemoteDeviceException(
        RemoteDeviceErrorKind.network,
        message: 'network failure',
        detail: e,
      );
    }
  }
}

/// 账号设备列表客户端。
class RemoteDeviceClient {
  RemoteDeviceClient({ZaiAuthClient? auth, RemoteDeviceHttpLayer? http})
    : _auth = auth ?? ZaiAuthClient(),
      _http = http ?? DioRemoteDeviceHttpLayer();

  /// 与官方手机 Web 端同源同路径。
  static const baseUrl = 'https://zcode.z.ai';
  static const listPath = '/api/v1/remote/device';

  /// 构造设备时用的默认 baseUrl（官方 V2 页面）。
  static const defaultDeviceBaseUrl = 'https://zcode.z.ai/remote/v4';

  final ZaiAuthClient _auth;
  final RemoteDeviceHttpLayer _http;

  /// `GET /api/v1/remote/device`：拉取当前账号的已注册设备。
  ///
  /// [jwt] 由调用方注入（账号库 `zcodejwttoken`）；[deviceMid] 为每账号
  /// 稳定值（`Account.virtualDeviceMid`），仅用于 `X-Device-Mid` 头。
  Future<List<RemoteDeviceEntry>> listDevices(
    String jwt, {
    String? deviceMid,
  }) async {
    final token = jwt.trim();
    if (token.isEmpty) {
      throw const RemoteDeviceException(
        RemoteDeviceErrorKind.unauthorized,
        message: 'missing jwt',
      );
    }
    final cfg = (deviceMid == null || deviceMid.isEmpty)
        ? null
        : _auth.config.copyWith(deviceMid: deviceMid);
    final headers = _auth.headersFor(bearer: token, configOverride: cfg);
    final RemoteDeviceHttpResponse r;
    try {
      r = await _http.get(
        Uri.parse('$baseUrl$listPath'),
        headers: headers,
      );
    } on ZaiAuthException catch (e) {
      throw _mapAuthError(e);
    }
    return parseListResponse(r);
  }

  /// 解包列表响应（公开以便单测直接喂形状）。
  ///
  /// 容错三类外壳漂移：裸数组、`data` 为单对象 / `{devices:[…]}` 包装、
  /// 字段别名；完全不像 → [RemoteDeviceErrorKind.badResponse]。
  static List<RemoteDeviceEntry> parseListResponse(RemoteDeviceHttpResponse r) {
    if (r.statusCode == 401) {
      throw const RemoteDeviceException(
        RemoteDeviceErrorKind.unauthorized,
        message: 'device list rejected: unauthorized',
        statusCode: 401,
      );
    }
    if (r.statusCode >= 400) {
      throw RemoteDeviceException(
        RemoteDeviceErrorKind.http,
        message: 'device list http error',
        statusCode: r.statusCode,
      );
    }
    final decoded = _decodeBody(r.body);
    if (decoded is List) return _parseEntries(decoded);
    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);
      final code = _asInt(map['code']);
      if (code != null && code != 0) {
        throw RemoteDeviceException(
          RemoteDeviceErrorKind.api,
          message: 'device list api error',
          apiCode: code,
        );
      }
      final data = map['data'];
      if (data is List) return _parseEntries(data);
      if (data is Map) {
        final dataMap = Map<String, dynamic>.from(data);
        for (final k in const ['devices', 'list', 'items', 'records']) {
          final inner = dataMap[k];
          if (inner is List) return _parseEntries(inner);
        }
        // 单对象漂移：`data` 本身就是一条设备记录。
        final single = RemoteDeviceEntry.tryParse(dataMap);
        if (single != null) return [single];
        throw RemoteDeviceException(
          RemoteDeviceErrorKind.badResponse,
          message: 'device list: data is not a device array',
          statusCode: r.statusCode,
        );
      }
      // `code:0` 且无 data：按空列表处理（账号下无设备）。
      if (data == null) return const [];
      throw RemoteDeviceException(
        RemoteDeviceErrorKind.badResponse,
        message: 'device list: data has unexpected type',
        statusCode: r.statusCode,
      );
    }
    throw RemoteDeviceException(
      RemoteDeviceErrorKind.badResponse,
      message: 'device list: body is not json',
      statusCode: r.statusCode,
    );
  }

  static List<RemoteDeviceEntry> _parseEntries(List raw) {
    final entries = <RemoteDeviceEntry>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final entry = RemoteDeviceEntry.tryParse(Map<String, dynamic>.from(e));
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  /// 业务码容忍 int / num / 数字串；不可解析 → null（不当失败）。
  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static Object? _decodeBody(Object? body) {
    if (body is String) {
      final t = body.trim();
      if (t.isEmpty) return null;
      try {
        return jsonDecode(t);
      } catch (_) {
        return null;
      }
    }
    return body;
  }

  static RemoteDeviceException _mapAuthError(ZaiAuthException e) {
    if (e.kind == ZaiAuthErrorKind.http && e.statusCode == 401) {
      return RemoteDeviceException(
        RemoteDeviceErrorKind.unauthorized,
        message: e.message,
        statusCode: 401,
        detail: e,
      );
    }
    if (e.kind == ZaiAuthErrorKind.api) {
      return RemoteDeviceException(
        RemoteDeviceErrorKind.api,
        message: e.message,
        apiCode: e.apiCode,
        detail: e,
      );
    }
    if (e.kind == ZaiAuthErrorKind.badResponse) {
      return RemoteDeviceException(
        RemoteDeviceErrorKind.badResponse,
        message: e.message,
        detail: e,
      );
    }
    return RemoteDeviceException(
      RemoteDeviceErrorKind.network,
      message: e.message,
      detail: e,
    );
  }
}

/// 把服务端记录构造成 App 设备（kind v2，官方 V2 页）。
///
/// params 带 `sid` / `mid` / `name` / `app_version`（后两者有值才写），
/// 与官方手机 Web 端 `admit()` 回写 URL 的键一致。
RemoteDevice remoteDeviceFromEntry(
  RemoteDeviceEntry entry, {
  String? id,
  DateTime? now,
  String baseUrl = RemoteDeviceClient.defaultDeviceBaseUrl,
}) {
  final name = entry.name.trim();
  final params = <String, String>{'sid': entry.sid, 'mid': entry.mid};
  if (name.isNotEmpty) params['name'] = name;
  if (entry.appVersion.isNotEmpty) {
    params['app_version'] = entry.appVersion;
  }
  return RemoteDevice(
    id: id ?? const Uuid().v4(),
    baseUrl: baseUrl,
    params: params,
    label: name,
    createdAt: now ?? DateTime.now(),
    kind: DeviceKind.v2,
  );
}

/// 去重判定：同 SID（必然同设备）→ 同 MID（同电脑重注册换 SID）→
/// 同名（展示层去重提示）。命中返回已存在的设备与理由。
enum AccountDeviceDuplicateKind { sid, mid, name }

@immutable
class AccountDeviceDuplicate {
  const AccountDeviceDuplicate({
    required this.device,
    required this.kind,
    required this.entry,
  });

  final RemoteDevice device;
  final AccountDeviceDuplicateKind kind;
  final RemoteDeviceEntry entry;
}

AccountDeviceDuplicate? findAccountDeviceDuplicate(
  List<RemoteDevice> existing,
  RemoteDeviceEntry entry,
) {
  for (final d in existing) {
    if (entry.sid.isNotEmpty && d.sid == entry.sid) {
      return AccountDeviceDuplicate(
        device: d,
        kind: AccountDeviceDuplicateKind.sid,
        entry: entry,
      );
    }
  }
  if (entry.mid.isNotEmpty) {
    for (final d in existing) {
      final mid = d.params['mid'] ?? '';
      if (mid.isNotEmpty && mid == entry.mid) {
        return AccountDeviceDuplicate(
          device: d,
          kind: AccountDeviceDuplicateKind.mid,
          entry: entry,
        );
      }
    }
  }
  final name = entry.name.trim();
  if (name.isNotEmpty) {
    for (final d in existing) {
      if (d.label.trim() == name) {
        return AccountDeviceDuplicate(
          device: d,
          kind: AccountDeviceDuplicateKind.name,
          entry: entry,
        );
      }
    }
  }
  return null;
}
