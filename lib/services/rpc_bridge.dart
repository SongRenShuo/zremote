import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'rpc_dispatch.dart';

class RpcNotReadyException implements Exception {
  const RpcNotReadyException(this.reason);

  final String reason;

  @override
  String toString() => 'RpcNotReadyException($reason)';
}

class RpcTimeoutException implements Exception {
  const RpcTimeoutException(this.label);

  final String label;

  @override
  String toString() => 'RpcTimeoutException($label)';
}

class RpcRemoteException implements Exception {
  const RpcRemoteException(this.label, this.message);

  final String label;
  final String message;

  @override
  String toString() => 'RpcRemoteException($label: $message)';
}

class RpcResponse {
  const RpcResponse({required this.id, required this.values});

  final int id;
  final List<Object?> values;

  Map<String, dynamic>? get firstObject {
    for (final value in values) {
      if (value is Map<String, dynamic>) return value;
    }
    return null;
  }

  /// firstObject 的外壳剥离版：宿主升级后返回值可能被单键包装
  /// （如 `{snapshot: {...}}`、`{view: {...}}`），这里逐层取唯一 Map 值。
  static const int _maxUnwrapDepth = 4;

  Map<String, dynamic>? get firstObjectDeep {
    for (final value in values) {
      final unwrapped = _unwrapObject(value, 0);
      if (unwrapped != null) return unwrapped;
    }
    return null;
  }

  static Map<String, dynamic>? _unwrapObject(dynamic value, int depth) {
    if (value is! Map<String, dynamic>) return null;
    if (value.isEmpty) return value;
    if (depth >= _maxUnwrapDepth) return value;
    // 单键 Map 且该键的值仍是 Map 时视为包装外壳，继续向内剥。
    if (value.length == 1) {
      final inner = value.values.first;
      if (inner is Map<String, dynamic>) {
        return _unwrapObject(inner, depth + 1);
      }
    }
    return value;
  }

  /// 原始报文片段（截断），用于解析失败时在错误态展示可读原因。
  static const int debugTextMaxChars = 300;

  String debugText() {
    String raw;
    try {
      raw = jsonEncode(values);
    } catch (_) {
      raw = '${values}';
    }
    raw = raw.replaceAll('\n', ' ');
    return raw.length <= debugTextMaxChars
        ? raw
        : raw.substring(0, debugTextMaxChars);
  }
}

class RpcBridge {
  RpcBridge({
    required this.deviceId,
    required this.dispatch,
    this.onServiceState,
  });

  final void Function(bool ready)? onServiceState;

  /// channel → 服务名候选列表（首个为主名，其余为宿主升级后的别名，
  /// 按 no-services/no-method 时依次探测）。探测成功的结果按会话缓存。
  static const Map<String, List<String>> _serviceCandidatesByChannel = {
    'off-peak-task': ['offPeakTaskService', 'offPeakQueueService'],
    'zcode-agent': ['zcodeAgentService', 'agentService', 'automationService'],
    'usage-stats': ['usageStatsService', 'usageService'],
    'zr-probe': ['__zrProbe'],
    'coding-plan-subscription': [
      'codingPlanSubscriptionService',
      'codingPlanService',
      'subscriptionService',
    ],
    'zr-captcha': ['__zrCaptcha'],
    'provider-settings': ['providerSettingsService', 'modelProviderService'],
    'model-selection': ['modelSelectionService', 'modelService'],
    'setting': ['settingService', 'settingsService'],
  };

  static const Map<String, String> _serviceByChannel = {
    for (final entry in _serviceCandidatesByChannel.entries)
      entry.key: entry.value.first,
  };

  final String deviceId;

  final RpcDispatch dispatch;

  final Map<int, Completer<RpcResponse>> _pending = {};
  int _nextId = 1;

  bool? _offPeakUpdateTwoArgs;

  final Map<String, String> _resolvedService = {};

  /// 诊断用：该 channel 当前实际使用的服务名（未解析过时返回主名）。
  String resolvedServiceOf(String channel) =>
      _resolvedService[channel] ?? _serviceByChannel[channel] ?? channel;

  void resetServiceResolution() => _resolvedService.clear();

  Future<RpcResponse> call(
    String channel,
    String method, {
    Object? params,
    Duration timeout = const Duration(seconds: 25),
  }) => callArgs(
    channel,
    method,
    args: params == null ? const [] : [params],
    timeout: timeout,
  );

  Future<RpcResponse> callArgs(
    String channel,
    String method, {
    required List<Object?> args,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final candidates = _serviceCandidatesByChannel[channel];
    if (candidates == null) {
      throw RpcNotReadyException('unknown channel: $channel');
    }
    // 已解析成功的别名优先，其余候选按声明顺序兜底。
    final resolved = _resolvedService[channel];
    final order = [
      if (resolved != null && candidates.contains(resolved)) resolved,
      for (final candidate in candidates)
        if (candidate != resolved) candidate,
    ];
    for (var i = 0; i < order.length; i++) {
      final last = i == order.length - 1;
      try {
        return await _callService(
          channel,
          order[i],
          method,
          args,
          timeout,
          reportNoServices: last,
        );
      } on RpcRemoteException catch (e) {
        final transient =
            e.message.contains('no-services') || e.message.contains('no-method');
        if (!transient || last) {
          _resolvedService.remove(channel);
          rethrow;
        }
        if (kDebugMode) {
          debugPrint('[zr-diag] $channel.$method alias ${order[i]} -> ${e.message}');
        }
      } on TimeoutException {
        // 超时不换别名重试，直接按超时语义抛出。
        throw RpcTimeoutException('$channel.$method');
      }
    }
    throw RpcNotReadyException('no service candidate for $channel');
  }

  Future<RpcResponse> _callService(
    String channel,
    String service,
    String method,
    List<Object?> args,
    Duration timeout, {
    required bool reportNoServices,
  }) async {
    final tracksReadiness =
        channel != 'zr-probe' && channel != 'zr-captcha';
    final id = _nextId++;
    final argsJson = jsonEncode(args);
    final argsB64 = base64Encode(utf8.encode(argsJson));
    final completer = Completer<RpcResponse>();
    _pending[id] = completer;
    dispatch.push({'i': id, 's': service, 'm': method, 'a': argsB64});
    if (kDebugMode) {
      debugPrint('[zr-diag] -> $channel.$method id=$id port=${dispatch.port}');
    }
    try {
      final response = await completer.future.timeout(timeout);
      _resolvedService[channel] = service;
      if (tracksReadiness) onServiceState?.call(true);
      if (kDebugMode) {
        debugPrint(
          '[zr-diag] <- $channel.$method id=$id values=${response.values.length}',
        );
      }
      return response;
    } on RpcRemoteException catch (e) {
      if (tracksReadiness &&
          reportNoServices &&
          e.message.contains('no-services')) {
        onServiceState?.call(false);
      }
      rethrow;
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('[zr-diag] !! $channel.$method id=$id TIMEOUT');
      }
      throw RpcTimeoutException('$channel.$method');
    } finally {
      _pending.remove(id);
    }
  }

  void onSvcResult(String body) {
    try {
      final map = jsonDecode(body);
      if (map is! Map) return;
      final id = map['i'];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      if (map['ok'] == true) {
        final r = map['r'];
        completer.complete(RpcResponse(id: id, values: _valuesOf(r)));
      } else {
        completer.completeError(
          RpcRemoteException('call#$id', '${map['e'] ?? 'unknown'}'),
        );
      }
    } catch (_) {}
  }

  Future<bool> offPeakUpdateTwoArgs({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final cached = _offPeakUpdateTwoArgs;
    if (cached != null) return cached;
    try {
      await call(
        'off-peak-task',
        'getCodingPlanSupport',
        timeout: timeout,
      );
    } on RpcRemoteException catch (e) {
      if (e.message.contains('no-method')) {
        return _offPeakUpdateTwoArgs = false;
      }
      if (e.message.contains('no-services')) return false;
      return _offPeakUpdateTwoArgs = true;
    } catch (_) {
      return false;
    }
    return _offPeakUpdateTwoArgs = true;
  }

  void resetOffPeakProbe() => _offPeakUpdateTwoArgs = null;

  static List<Object?> _valuesOf(dynamic r) {
    if (r is! String || r.isEmpty || r == 'null') return const [];
    final dynamic decoded;
    try {
      decoded = jsonDecode(r);
    } catch (_) {
      return const [
        {'zrTruncated': true},
      ];
    }
    if (decoded is List) return decoded;
    if (decoded is Map) return [decoded];
    return const [];
  }

  void dispose() {
    _failAllPending(const RpcNotReadyException('bridge disposed'));
  }

  void _failAllPending(Object error) {
    if (_pending.isEmpty) return;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
