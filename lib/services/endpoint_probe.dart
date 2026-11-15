import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'quota_client.dart'
    show
        QuotaTokenProvider,
        QuotaTokens,
        kZaiBillingBalanceUrl,
        kQuotaAppVersion;

/// 端点健康探测（开发计划 20261115-0901 P6-1）。
///
/// 诊断页「端点探测」按钮直连两类端点，报告各端点耗时/状态码/错误摘要，
/// 结果并入「复制报告」文本：
/// 1. `GET https://zcode.z.ai/api/v1/client/configs`——无鉴权公开接口
///    （计划附录 A.1，验证码配置来源），任何网络/区域问题都会在此显形；
/// 2. `GET .../billing/balance`（可选）——需 zai JWT；无 token 时**跳过并
///    记录原因**（账号库 L1 车道合入前 tokenProvider 恒 null，属预期降级）。
///
/// 请求头为探测子集（附录 A.3 的最简满足），完整头全集归
/// [QuotaClient.zaiBillingHeaders]——探测只关心连通性，不关心业务形状。
class EndpointProbeResult {
  const EndpointProbeResult({
    required this.label,
    required this.url,
    this.skipped = false,
    this.skipReason,
    this.statusCode,
    this.elapsedMs = 0,
    this.error,
  });

  /// 展示名（如 `client/configs`）。
  final String label;
  final String url;
  final bool skipped;
  final String? skipReason;
  final int? statusCode;
  final int elapsedMs;
  final String? error;

  bool get ok => !skipped && statusCode != null && statusCode! ~/ 100 == 2;
}

const String kEndpointClientConfigsUrl =
    'https://zcode.z.ai/api/v1/client/configs';

/// 跳过原因稳定码（UI 层 l10n 映射用）：无 zai JWT。
const String kEndpointSkipNoToken = 'no-token';

/// 端点探测报告行（复制报告文本并入段）。
String endpointProbeReportLines(List<EndpointProbeResult> results) {
  if (results.isEmpty) return '';
  final buffer = StringBuffer('— 端点探测 —');
  for (final r in results) {
    if (r.skipped) {
      buffer.writeln();
      buffer.write('  ${r.label} SKIP ${r.skipReason}');
    } else if (r.ok) {
      buffer.writeln();
      buffer.write('  ${r.label} ${r.statusCode} ${r.elapsedMs}ms');
    } else {
      buffer.writeln();
      buffer.write(
        '  ${r.label} ${r.statusCode ?? 'ERR'} ${r.elapsedMs}ms ${r.error ?? ''}',
      );
    }
  }
  return buffer.toString();
}

class EndpointProbe {
  EndpointProbe({
    this.tokenProvider,
    this.dio,
    this.timeout = const Duration(seconds: 10),
  });

  /// zai JWT 供票（与 QuotaClient 同源接线位）；null/空票据时
  /// billing/balance 跳过并记 [kEndpointSkipNoToken]。
  final QuotaTokenProvider? tokenProvider;

  /// 测试注入用；null 时按默认超时构造。
  final Dio? dio;
  final Duration timeout;
  final Uuid _uuid = Uuid();

  late final Dio _dio = dio ??
      Dio(
        BaseOptions(
          connectTimeout: timeout,
          receiveTimeout: timeout,
          // 端点探测禁重定向跟随（30x 也算健康读数，不静默追跳）。
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );

  Map<String, String> _probeHeaders({String? bearerJwt}) => {
        'User-Agent': 'ZCode/$kQuotaAppVersion',
        'HTTP-Referer': 'https://zcode.z.ai',
        'X-Title': 'Z Code@electron',
        'X-ZCode-App-Version': kQuotaAppVersion,
        'x-request-id': _uuid.v4(),
        if (bearerJwt != null && bearerJwt.isNotEmpty)
          'Authorization': 'Bearer $bearerJwt',
      };

  Future<List<EndpointProbeResult>> run() async {
    final results = <EndpointProbeResult>[
      await _probe(
        label: 'client/configs',
        url: kEndpointClientConfigsUrl,
        headers: _probeHeaders(),
      ),
    ];

    final tokens = await _tokensOrNull();
    final jwt = tokens?.zaiJwt?.trim() ?? '';
    if (jwt.isEmpty) {
      results.add(
        const EndpointProbeResult(
          label: 'billing/balance',
          url: kZaiBillingBalanceUrl,
          skipped: true,
          skipReason: kEndpointSkipNoToken,
        ),
      );
    } else {
      results.add(
        await _probe(
          label: 'billing/balance',
          url: '$kZaiBillingBalanceUrl?app_version=$kQuotaAppVersion',
          headers: _probeHeaders(bearerJwt: jwt),
        ),
      );
    }
    return results;
  }

  Future<QuotaTokens?> _tokensOrNull() async {
    final provider = tokenProvider;
    if (provider == null) return null;
    try {
      return await provider();
    } catch (e) {
      debugPrint('[endpoint-probe] token provider failed: $e');
      return null;
    }
  }

  Future<EndpointProbeResult> _probe({
    required String label,
    required String url,
    required Map<String, String> headers,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final response = await _dio.get<Object?>(url,
          options: Options(
            headers: headers,
            responseType: ResponseType.plain,
            // 探测语义：任何状态码都是读数（含 4xx/5xx/30x），
            // 不抛不追跳；注入裸 Dio 时同样生效。
            validateStatus: (_) => true,
            followRedirects: false,
          ));
      sw.stop();
      return EndpointProbeResult(
        label: label,
        url: url,
        statusCode: response.statusCode,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return EndpointProbeResult(
        label: label,
        url: url,
        elapsedMs: sw.elapsedMilliseconds,
        error: _clip(e.toString()),
      );
    }
  }

  static String _clip(String text) => text.length <= 200
      ? text
      : text.substring(0, 200);
}
