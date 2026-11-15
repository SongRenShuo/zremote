import 'dart:convert';

import 'package:flutter/material.dart' show Brightness;

/// 福利中心桥（开发计划 20261115-0901 P1-3）。
///
/// - URL 构造：`https://zcode.z.ai/cn/rewards?embedded=app&theme=zai-dark|zai-light`
///   （主题跟随 App themeMode，正式版桌面 webview 桥同款）。
/// - origin 白名单：只允许 zcode.z.ai 域内导航（移植正式版 rewardsEmbedded
///   的白名单语义），外域由 UI 走 url_launcher 打开或拦截。
/// - localStorage 供票注入脚本：五键（zcodejwttoken / oauth:zai:access_token /
///   oauth:zai_cn:access_token / oauth:bigmodel:access_token /
///   oauth:active_provider）。
///   **M0-1 铁律**：注入脚本体内禁止 `//` 与 `/*` 注释序列（`://` 除外），
///   解释性注释一律写在 Dart 侧；test/rewards_bridge_test.dart 校验
///   零注释序列、五键齐全、括号配平。
const String kRewardsPageOrigin = 'https://zcode.z.ai';
const String kRewardsPagePath = '/cn/rewards';

/// 福利页凭据：远控页凭据仓 = WebView localStorage（计划 §2.2）。
/// 集成时由上层接账号库（L1 车道 account_vault）供票。
class RewardsCredentials {
  const RewardsCredentials({
    this.zcodeJwtToken,
    this.zaiAccessToken,
    this.zaiCnAccessToken,
    this.bigmodelAccessToken,
    this.activeProvider,
  });

  final String? zcodeJwtToken;
  final String? zaiAccessToken;
  final String? zaiCnAccessToken;
  final String? bigmodelAccessToken;
  final String? activeProvider;

  bool get isEmpty =>
      zcodeJwtToken == null &&
      zaiAccessToken == null &&
      zaiCnAccessToken == null &&
      bigmodelAccessToken == null &&
      activeProvider == null;
}

typedef RewardsCredentialsProvider = Future<RewardsCredentials?> Function();

/// 主题参数映射：App 深色 → zai-dark，浅色 → zai-light。
String rewardsThemeParam(Brightness brightness) =>
    brightness == Brightness.dark ? 'zai-dark' : 'zai-light';

/// 构造福利页 URL（embedded=app + 主题参数）。
Uri rewardsPageUri({required Brightness brightness}) => Uri.parse(
  '$kRewardsPageOrigin$kRewardsPagePath?embedded=app&theme='
  '${rewardsThemeParam(brightness)}',
);

/// origin 白名单：仅 zcode.z.ai 域内（含子域）且 https 的导航放行。
bool isAllowedRewardsNavigation(Uri uri) {
  if (!uri.isScheme('https')) return false;
  final host = uri.host.toLowerCase();
  return host == 'zcode.z.ai' || host.endsWith('.zcode.z.ai');
}

/// 是否适合转交外部浏览器（http/https 外域；其余 scheme 一律拦截）。
bool shouldOpenRewardsUrlExternally(Uri uri) =>
    uri.isScheme('https') || uri.isScheme('http');

/// localStorage 供票注入脚本（文档起始前注入，页面脚本即取即用）。
///
/// 空凭据返回空串（跳过注入，由福利页自展示登录态）。
/// 注意：值文本里的 `/` 与 `*` 一律转义为 `\u002f` / `\u002a`
/// （JSON/JS 合法转义，语义不变），保证任何凭据值都不会让脚本体内
/// 出现 `//` 或 `/*` 序列（M0-1 判据结构性成立）。
String rewardsTokenInjectionScript(RewardsCredentials credentials) {
  final entries = <List<String>>[
    if (credentials.zcodeJwtToken != null)
      ['zcodejwttoken', credentials.zcodeJwtToken!],
    if (credentials.zaiAccessToken != null)
      ['oauth:zai:access_token', credentials.zaiAccessToken!],
    if (credentials.zaiCnAccessToken != null)
      ['oauth:zai_cn:access_token', credentials.zaiCnAccessToken!],
    if (credentials.bigmodelAccessToken != null)
      ['oauth:bigmodel:access_token', credentials.bigmodelAccessToken!],
    if (credentials.activeProvider != null)
      ['oauth:active_provider', credentials.activeProvider!],
  ];
  if (entries.isEmpty) return '';
  final pairs = entries
      .map((e) => '[${_jsString(e[0])},${_jsString(e[1])}]')
      .join(',');
  return '(function(){var m=[$pairs];'
      'try{for(var i=0;i<m.length;i++){'
      'window.localStorage.setItem(m[i][0],m[i][1]);}}catch(e){}})();';
}

String _jsString(String value) =>
    jsonEncode(value).replaceAll('/', r'\u002f').replaceAll('*', r'\u002a');
