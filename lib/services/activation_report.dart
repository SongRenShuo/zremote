import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

/// 激活事件前置上报（20261118-0030 F2-B，复刻 zcode-switch claim.rs）。
///
/// 服务端把限时活动套餐的「可领」资格与埋点侧 `app_launch` / `app_daily_active`
/// 激活记录绑定：未上报时 preview 返回「账号未配置套餐」（宿主实测
/// manual_claim_preview_missing_data），zcode-switch 每次 preview 前先补报
/// 两个事件即能拿到可领套餐（同账号已验证）。
///
/// 关键事实（探查确认）：`event/report` 请求**只有 Content-Type 一个头、
/// 无 Authorization**——服务端靠 body 里的 `user_id + device_mid` 关联账号，
/// 因此不需要 JWT/token。
class ActivationReporter {
  ActivationReporter({
    required Dio dio,
    required this.userId,
    required this.deviceMid,
    this.appVersion = '',
  }) : _dio = dio;

  static const _url = 'https://zcode.z.ai/api/v1/event/report';
  static const _events = <String>['app_launch', 'app_daily_active'];
  static const _screenResolution = '2560x1440';

  final Dio _dio;
  final String userId;
  final String deviceMid;
  final String appVersion;

  /// 依次上报两个激活事件；任一失败返回 false（调用方静默降级，
  /// 不阻断 preview——对齐 zcode-switch `activated=false` 语义）。
  Future<bool> report() async {
    if (userId.isEmpty || deviceMid.isEmpty) return false;
    for (final element in _events) {
      try {
        final resp = await _dio.post<dynamic>(
          _url,
          data: _body(element),
          options: Options(headers: {'Content-Type': 'application/json'}),
        );
        final data = resp.data;
        final code = data is Map ? data['code'] : null;
        if (code is num ? code != 0 : true) {
          debugPrint('[activation] $element code=$code');
          return false;
        }
      } catch (e) {
        debugPrint('[activation] $element failed: $e');
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> _body(String element) => <String, dynamic>{
    'event_id': const Uuid().v4(),
    'client_timezone': DateTime.now().timeZoneName,
    'client_language': 'zh-CN',
    'element_name': element,
    'event_region': 'app',
    'event_type': 'view',
    'event_text': '',
    'event_extra_detail': <String, dynamic>{},
    'user_id': userId,
    'screen_resolution': _screenResolution,
    'app_version': appVersion,
    'device_os_category': Platform.operatingSystem,
    'device_os_version': Platform.operatingSystemVersion,
    'device_mid': deviceMid,
    'mac_id': '',
    'marketing_params': '{}',
  };

  /// 从账号凭据解析 user_id（zcode-switch claim.rs:135-156 同源：
  /// `oauth:<provider>:user_info` JSON 里的 `id` / `user_id` 字段）。
  /// 解不出返回 null（调用方静默跳过上报）。
  static String? userIdFromCredentials(Map<String, String> credentials) {
    final provider =
        credentials['oauth:active_provider']?.trim().isNotEmpty == true
        ? credentials['oauth:active_provider']!.trim()
        : 'zai';
    final raw = credentials['oauth:$provider:user_info'] ??
        credentials['oauth:zai:user_info'];
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      for (final key in const ['id', 'user_id']) {
        final v = decoded[key];
        if (v is String && v.isNotEmpty) return v;
        if (v is num) return v.toString();
      }
      return null;
    } catch (e) {
      debugPrint('[activation] user_info parse failed: $e');
      return null;
    }
  }

  /// 当前 App 版本（package_info 初始化失败时返回空串）。
  static Future<String> currentAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '';
    }
  }
}
