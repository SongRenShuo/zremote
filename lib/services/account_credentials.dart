import 'package:flutter/foundation.dart';

import '../services/account_vault.dart';
import 'quota_client.dart';
import 'rewards_bridge.dart';

/// 账号供票组装（account 车道）。
///
/// 账号库条目 = 远控页 WebView localStorage 键值仓（计划 §2.2），本文件是
/// 「账号 → 各业务供票」的唯一映射层，供 QuotaPage / RewardsPage /
/// DiagnosticsPage(EndpointProbe) 共用，避免三处各写一套键名。
///
/// provider 组装矩阵（`Account.provider` 与 `oauth:active_provider` 的 wire 名）：
/// - `zai`：zcode.z.ai 国际版，access_token 键 `oauth:zai:access_token`；
/// - `zai_cn`：zcode.z.ai 国内版，access_token 键 `oauth:zai_cn:access_token`；
/// - `bigmodel`：bigmodel.cn，access_token 键 `oauth:bigmodel:access_token`，
///   同时充当 bigmodel 直连 `quota/limit` 的 Authorization（原样，不带 Bearer）。
/// `zcodejwttoken` 与 provider 无关，是三端共用的 zcode JWT。
const Set<String> kAccountProviders = {'zai', 'zai_cn', 'bigmodel'};

/// provider → localStorage access_token 键。
String accountAccessTokenKey(String provider) => 'oauth:$provider:access_token';

/// 是否为受支持的账号 provider（未知值不参与组装，避免写出脏键）。
bool isSupportedAccountProvider(String? provider) =>
    provider != null && kAccountProviders.contains(provider);

/// 解析账号的活跃 provider：`oauth:active_provider` 优先（须受支持），
/// 回落 `Account.provider`；两者都不可识别时返回 null。
String? resolveAccountProvider(Account account) {
  final active = _nonEmpty(account.credentials['oauth:active_provider']);
  if (isSupportedAccountProvider(active)) return active;
  return isSupportedAccountProvider(account.provider) ? account.provider : null;
}

/// 取指定 provider 的 access_token（zai/zai_cn/bigmodel 三态矩阵）。
/// provider 不受支持或键缺失 → null。
String? accessTokenOf(Account account, String? provider) {
  if (!isSupportedAccountProvider(provider)) return null;
  return _nonEmpty(account.credentials[accountAccessTokenKey(provider!)]);
}

/// bigmodel 直连 API key（bigmodel provider 的 access_token）。
String? bigmodelApiKeyOf(Account account) => accessTokenOf(account, 'bigmodel');

/// 账号供票集合：直连票据 + 福利页 localStorage 五键。
@immutable
class AccountTickets {
  const AccountTickets({
    this.quotaTokens,
    this.rewardsCredentials = const RewardsCredentials(),
  });

  /// 通路 B 直连票据；无 zai JWT 且无 bigmodel key 时为 null。
  final QuotaTokens? quotaTokens;

  /// 福利中心 localStorage 五键（含 zcodejwttoken 登录门控键）。
  final RewardsCredentials rewardsCredentials;

  bool get isEmpty =>
      quotaTokens == null && rewardsCredentials.isEmpty;
}

/// 把账号凭据组装成各业务供票（null 账号 → 空集合）。
///
/// - [AccountTickets.quotaTokens]：`zaiJwt` = `zcodejwttoken`；
///   `bigmodelApiKey` = `oauth:bigmodel:access_token`（与活跃 provider 无关，
///   账号可能同时存多 provider 凭据）。
/// - [AccountTickets.rewardsCredentials]：五键按存在性收录，
///   `activeProvider` 取 [resolveAccountProvider]。
AccountTickets accountTicketsOf(Account? account) {
  if (account == null) return const AccountTickets();
  final credentials = account.credentials;
  final jwt = _nonEmpty(credentials['zcodejwttoken']);
  final bigmodelKey = _nonEmpty(credentials['oauth:bigmodel:access_token']);
  final rewards = RewardsCredentials(
    zcodeJwtToken: jwt,
    zaiAccessToken: _nonEmpty(credentials['oauth:zai:access_token']),
    zaiCnAccessToken: _nonEmpty(credentials['oauth:zai_cn:access_token']),
    bigmodelAccessToken: bigmodelKey,
    activeProvider: resolveAccountProvider(account),
  );
  return AccountTickets(
    quotaTokens: jwt == null && bigmodelKey == null
        ? null
        : QuotaTokens(zaiJwt: jwt, bigmodelApiKey: bigmodelKey),
    rewardsCredentials: rewards,
  );
}

String? _nonEmpty(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
