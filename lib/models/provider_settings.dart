/// 宿主额度回执语义（quota 中心与模型设置页共用）。
///
/// 宿主未登录/未配置时 `usageStats.getEntitlementSnapshot` **成功返回**
/// `authenticated:true + unavailableReason:"not_configured" + quota:null`
/// （bigmodelUsageQuotaProvider.ts:287-319，开源版与官方一致）——既不是
/// `no_plan`（账号无生效套餐）也不是错误，页面须展示「登录后查看」引导。
enum EntitlementSemantic {
  /// 有 limits 数据，正常渲染。
  ok,

  /// `unavailableReason == "no_plan"`：账号无生效套餐。
  noPlan,

  /// 未配置 / 未登录：not_configured、not_authenticated，或 quota 缺失
  /// （null）且原因非 no_plan。
  notConfigured,

  /// 回执完全不可解析（空对象且无关键键）。
  unparseable,
}

/// 从 provider 视图挑首选 entitle 账号 provider（额度页与模型设置页共用）。
///
/// 排序与模型设置页连接行同序：先按「当前连接 family 的当前 kind」命中，
/// 否则回落首个 entitle provider。无可用 provider → null（调用方降级）。
ZrProvider? pickEntitlementProvider(
  ProviderSettingsView? view,
  ZrConnectionSettings? settings,
) {
  if (view == null) return null;
  final entitled = view.entitledAccountProviders;
  if (entitled.isEmpty) return null;
  final byFamily = <String, List<ZrProvider>>{};
  for (final p in view.providers) {
    final access = p.effectiveConfig?.access;
    if (access == null || !access.isAccount) continue;
    final family = access.accountType;
    final mode = access.mode;
    if (family == null ||
        family.isEmpty ||
        mode == null ||
        mode.isEmpty ||
        access.entitled != true) {
      continue;
    }
    byFamily.putIfAbsent(family, () => []).add(p);
  }
  for (final entry in byFamily.entries) {
    final current = settings?.selections[entry.key]?.kind;
    if (current == null) continue;
    for (final p in entry.value) {
      if (p.effectiveConfig?.access?.mode == current) return p;
    }
  }
  return entitled.first;
}

/// `getEntitlementSnapshot` 参数构造（额度页与模型设置页共用）。
///
/// 宿主对仅带 `includeSubscription` 的请求在账号无 entitle provider 时返回
/// `not_configured`（P0-5 实测）；带 `preferredProviderId + accountAccess`
/// 且该 provider 有 entitle 时立即返回完整 `quota.limits`。
///
/// `accountAccess` 官方 schema 为 strict：`type` / `accountType` / `mode`
/// 三字段必须齐全（P0 实测缺 `entitled` 仍返回完整快照，故 `entitled` 存在
/// 才带）。任一所需字段缺失 → **不发** `accountAccess`，降级为按
/// `preferredProviderId` 查询，并随之省略 `requirePreferredProvider`
/// （否则降级请求会被该约束判失败）。
Map<String, dynamic> entitlementParamsFor(ZrProvider provider) {
  final access = provider.effectiveConfig?.access;
  final accountAccess = _strictAccountAccess(access);
  final params = <String, dynamic>{
    'includeSubscription': true,
    'preferredProviderId': provider.providerId,
    'allowDisabledPreferredProvider': true,
    'allowEnvApiKey': false,
  };
  if (accountAccess != null) {
    params['accountAccess'] = accountAccess;
    params['requirePreferredProvider'] = true;
  }
  return params;
}

/// 三字段齐全才构造 accountAccess（`entitled` 可选，存在才带）。
Map<String, dynamic>? _strictAccountAccess(ZrProviderAccess? access) {
  if (access == null) return null;
  final accountType = access.accountType;
  final mode = access.mode;
  if (access.type.isEmpty ||
      accountType == null ||
      accountType.isEmpty ||
      mode == null ||
      mode.isEmpty) {
    return null;
  }
  return <String, dynamic>{
    'type': access.type,
    'accountType': accountType,
    'mode': mode,
    if (access.entitled != null) 'entitled': access.entitled,
  };
}

/// 宿主错误文本是否表达「未配置 / 未登录」（RPC 异常文本形态，
/// 与回执里的 unavailableReason 同义）。
bool isNotConfiguredErrorText(String message) =>
    message.contains('not_configured') ||
    message.contains('not_authenticated') ||
    message.contains('未配置') ||
    message.contains('未登录');

/// 额度回执分类（quota_client 与 model_settings_page 共用同一判据）。
///
/// - 有 limits → [EntitlementSemantic.ok]
/// - `no_plan` → [EntitlementSemantic.noPlan]
/// - 其余有数据但无 limits（未配置 / 未登录 / quota 为 null）→
///   [EntitlementSemantic.notConfigured]
/// - 解析不出对象：但原始报文里出现 `authenticated` / `unavailableReason` /
///   `quota` 任一键，说明宿主已作答（未配置），否则才算 [unparseable]。
EntitlementSemantic classifyEntitlement(
  UsageEntitlement? ent, {
  Map<String, dynamic>? raw,
}) {
  if (ent != null) {
    if (ent.limits.isNotEmpty) return EntitlementSemantic.ok;
    if (ent.noPlan) return EntitlementSemantic.noPlan;
    return EntitlementSemantic.notConfigured;
  }
  final r = raw;
  if (r != null &&
      (r.containsKey('authenticated') ||
          r.containsKey('unavailableReason') ||
          r.containsKey('quota'))) {
    return EntitlementSemantic.notConfigured;
  }
  return EntitlementSemantic.unparseable;
}

class ZrProviderAccess {
  const ZrProviderAccess({
    required this.type,
    this.accountType,
    this.mode,
    this.entitled,
    this.apiKeySuffix,
    this.apiKeyManagementUrl,
  });

  final String type;

  final String? accountType;

  final String? mode;

  final bool? entitled;

  final String? apiKeySuffix;

  final String? apiKeyManagementUrl;

  bool get isAccount => type == 'zhipu-account';
  bool get isApiKey => type == 'api-key' || type == 'zhipu-coding-plan-api-key';

  static ZrProviderAccess? fromJson(Map<String, dynamic> j) {
    final type = j['type'];
    if (type is! String || type.isEmpty) return null;
    final key = j['apiKey'];
    final suffix = key is String && key.length > 6
        ? key.substring(key.length - 6)
        : null;
    return ZrProviderAccess(
      type: type,
      accountType: j['accountType'] is String
          ? j['accountType'] as String?
          : null,
      mode: j['mode'] is String ? j['mode'] as String? : null,
      entitled: j['entitled'] is bool ? j['entitled'] as bool? : null,
      apiKeySuffix: suffix,
      apiKeyManagementUrl: j['apiKeyManagementUrl'] is String
          ? j['apiKeyManagementUrl'] as String?
          : null,
    );
  }
}

class ZrEffectiveConfig {
  const ZrEffectiveConfig({
    required this.group,
    this.access,
    this.baseUrl,
    this.apiType,
  });

  final String? group;
  final ZrProviderAccess? access;

  final String? baseUrl;

  final String? apiType;

  static ZrEffectiveConfig? fromJson(Map<String, dynamic> j) {
    if (j.isEmpty) return null;
    final api = j['api'];
    final access = j['access'];
    return ZrEffectiveConfig(
      group: j['group'] is String ? j['group'] as String? : null,
      access: access is Map<String, dynamic>
          ? ZrProviderAccess.fromJson(access)
          : null,
      baseUrl: api is Map<String, dynamic> && api['baseUrl'] is String
          ? api['baseUrl'] as String?
          : null,
      apiType: api is Map<String, dynamic> && api['type'] is String
          ? api['type'] as String?
          : null,
    );
  }
}

class ZrProviderModel {
  const ZrProviderModel({
    required this.modelId,
    this.kind,
    this.builtin,
    this.selectable,
    this.executable,
    this.enabled = true,
    this.useRecommendedConfig = true,
    this.personalConfig = const {},
    this.inheritedConfig = const {},
    this.effectiveConfig = const {},
    this.issueMessage,
  });

  final String modelId;
  final String? kind;
  final bool? builtin;
  final bool? selectable;
  final bool? executable;

  final bool enabled;

  final bool useRecommendedConfig;

  final Map<String, dynamic> personalConfig;

  final Map<String, dynamic> inheritedConfig;

  final Map<String, dynamic> effectiveConfig;

  final String? issueMessage;

  bool get isBuiltin => builtin == true;

  bool get configIncomplete {
    if (contextWindow == null) return true;
    final fmt = inputFormat;
    for (final k in const [
      'supportsText',
      'supportsImage',
      'supportsVideo',
      'supportsAudio',
      'supportsPdf',
    ]) {
      if (fmt[k] == null) return true;
    }
    return _asMap(properties['outputFormat'])['supportsText'] == null;
  }

  Map<String, dynamic> get properties => _asMap(effectiveConfig['properties']);
  Map<String, dynamic> get optionSpecs => _asMap(effectiveConfig['optionSpecs']);

  int? get contextWindow {
    final v = properties['contextWindow'];
    return v is num && v > 0 ? v.toInt() : null;
  }

  Map<String, dynamic> get inputFormat => _asMap(properties['inputFormat']);

  List<String> get reasoningLevels {
    final lv = _asMap(optionSpecs['reasoningLevel'])['values'];
    return lv is List ? [for (final e in lv) if (e is String) e] : const [];
  }

  String? get reasoningLevelMap {
    final m = _asMap(_asMap(personalConfig['optionSpecs'])['reasoningLevel'])['map'];
    return m is String ? m : null;
  }

  static Map<String, dynamic> _asMap(Object? raw) =>
      raw is Map<String, dynamic> ? raw : const {};

  static ZrProviderModel? fromJson(Map<String, dynamic> j) {
    final id = j['modelId'];
    if (id is! String || id.isEmpty) return null;
    final cfg = j['effectiveConfig'];
    final enabled = cfg is Map<String, dynamic> ? cfg['enabled'] : null;
    final issues = j['issues'];
    final first = issues is List && issues.isNotEmpty ? issues.first : null;
    return ZrProviderModel(
      modelId: id,
      kind: j['kind'] is String ? j['kind'] as String? : null,
      builtin: j['builtin'] is bool ? j['builtin'] as bool? : null,
      selectable: j['selectable'] is bool ? j['selectable'] as bool? : null,
      executable: j['executable'] is bool ? j['executable'] as bool? : null,
      enabled: enabled is bool ? enabled : true,
      useRecommendedConfig: j['useRecommendedConfig'] is bool
          ? j['useRecommendedConfig'] as bool
          : true,
      personalConfig: _asMap(j['personalExactConfig']),
      inheritedConfig: _asMap(j['effectiveBuiltinConfig']),
      effectiveConfig: _asMap(cfg),
      issueMessage: first is Map<String, dynamic> && first['message'] is String
          ? first['message'] as String
          : null,
    );
  }
}

class ZrAccountState {
  const ZrAccountState({required this.availability});

  final String? availability;

  bool get unavailable => availability == 'unavailable';

  static ZrAccountState? fromJson(Map<String, dynamic> j) {
    if (j.isEmpty) return null;
    return ZrAccountState(
      availability: j['availability'] is String
          ? j['availability'] as String?
          : null,
    );
  }
}

class ZrProvider {
  const ZrProvider({
    required this.providerId,
    required this.enabled,
    required this.executable,
    required this.models,
    this.providerName,
    this.templateId,
    this.accountState,
    this.effectiveConfig,
    this.personalConfig = const {},
  });

  final String providerId;
  final String? providerName;
  final String? templateId;
  final bool enabled;
  final bool executable;
  final ZrAccountState? accountState;
  final ZrEffectiveConfig? effectiveConfig;
  final List<ZrProviderModel> models;

  final Map<String, dynamic> personalConfig;

  String get displayName {
    final name = providerName?.trim();
    return name != null && name.isNotEmpty ? name : providerId;
  }

  bool get isCustom => effectiveConfig?.group == 'standard-personal';

  ZrProvider withModels(List<ZrProviderModel> models) => ZrProvider(
    providerId: providerId,
    providerName: providerName,
    templateId: templateId,
    enabled: enabled,
    executable: executable,
    accountState: accountState,
    effectiveConfig: effectiveConfig,
    personalConfig: personalConfig,
    models: models,
  );

  static ZrProvider? fromJson(Map<String, dynamic> j) {
    final id = j['providerId'];
    if (id is! String || id.isEmpty) return null;
    final accountState = j['accountState'];
    final effective = j['effectiveConfig'];
    final models = j['models'];
    return ZrProvider(
      providerId: id,
      providerName: j['providerName'] is String
          ? j['providerName'] as String?
          : null,
      templateId: j['templateId'] is String ? j['templateId'] as String? : null,
      enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      executable: j['executable'] is bool ? j['executable'] as bool : true,
      accountState: accountState is Map<String, dynamic>
          ? ZrAccountState.fromJson(accountState)
          : null,
      effectiveConfig: effective is Map<String, dynamic>
          ? ZrEffectiveConfig.fromJson(effective)
          : null,
      personalConfig: _personalOverlay(j['personalConfig']),
      models: models is List
          ? [
              for (final m in models)
                if (m is Map<String, dynamic>) ZrProviderModel.fromJson(m),
            ].whereType<ZrProviderModel>().toList()
          : const [],
    );
  }

  static Map<String, dynamic> _personalOverlay(Object? raw) {
    if (raw is! Map<String, dynamic>) return const {};
    final overlay = Map<String, dynamic>.from(raw);
    overlay.remove('builtinModelIds');
    overlay.remove('personalModelIds');
    return overlay;
  }
}

class ZrProviderTemplate {
  const ZrProviderTemplate({required this.templateId, required this.names});

  final String templateId;

  final Map<String, String> names;

  static const zhipuTemplateIds = <String>[
    'bigmodel-api',
    'zai-api',
    'bigmodel-standard-api',
    'zai-standard-api',
  ];

  bool get isZhipuFamily => zhipuTemplateIds.contains(templateId);

  String displayName(String locale) =>
      names[locale]?.trim().isNotEmpty == true
      ? names[locale]!.trim()
      : names['en-US']?.trim().isNotEmpty == true
      ? names['en-US']!.trim()
      : templateId;

  static ZrProviderTemplate? fromJson(Map<String, dynamic> j) {
    final id = j['templateId'];
    if (id is! String || id.isEmpty) return null;
    final raw = j['templateNameMap'];
    final names = <String, String>{};
    if (raw is Map<String, dynamic>) {
      for (final e in raw.entries) {
        if (e.value is String) names[e.key] = e.value as String;
      }
    }
    return ZrProviderTemplate(templateId: id, names: names);
  }
}

class ProviderSettingsView {
  const ProviderSettingsView({
    required this.revision,
    required this.providers,
    this.providerTemplates = const [],
  });

  final int revision;
  final List<ZrProvider> providers;

  final List<ZrProviderTemplate> providerTemplates;

  List<ZrProvider> get entitledAccountProviders => [
    for (final p in providers)
      if (p.effectiveConfig?.access?.isAccount == true &&
          p.effectiveConfig!.access!.entitled == true)
        p,
  ];

  ZrProvider? byId(String providerId) {
    for (final p in providers) {
      if (p.providerId == providerId) return p;
    }
    return null;
  }

  static ProviderSettingsView? fromJson(Map<String, dynamic> j) {
    // 别名容错：providers 缺失但对象形如视图（revision/providerTemplates 存在）
    // 时降级为空列表渲染，而不是整体报错。
    final providers = j['providers'] ?? j['providerList'];
    final looksLikeView =
        providers is List || j['revision'] != null || j['providerTemplates'] != null;
    if (!looksLikeView) return null;
    final providerList = providers is List ? providers : const [];
    final templates = j['providerTemplates'];
    return ProviderSettingsView(
      revision: j['revision'] is num ? (j['revision'] as num).toInt() : 0,
      providers: [
        for (final p in providerList)
          if (p is Map<String, dynamic>) ZrProvider.fromJson(p),
      ].whereType<ZrProvider>().toList(),
      providerTemplates: templates is List
          ? [
              for (final t in templates)
                if (t is Map<String, dynamic>) ZrProviderTemplate.fromJson(t),
            ].whereType<ZrProviderTemplate>().toList()
          : const [],
    );
  }
}

class ModelSelectionView {
  const ModelSelectionView({
    required this.revision,
    required this.providerIds,
    required this.modelCount,
  });

  final int revision;
  final List<String> providerIds;
  final int modelCount;

  static ModelSelectionView? fromJson(Map<String, dynamic> j) {
    final providers = j['providers'];
    if (providers is! List) return null;
    var models = 0;
    final ids = <String>[];
    for (final p in providers) {
      if (p is! Map<String, dynamic>) continue;
      final id = p['providerId'];
      if (id is String && id.isNotEmpty) ids.add(id);
      final ms = p['models'];
      if (ms is List) models += ms.length;
    }
    return ModelSelectionView(
      revision: j['revision'] is num ? (j['revision'] as num).toInt() : 0,
      providerIds: ids,
      modelCount: models,
    );
  }
}

class ZrConnectionSelection {
  const ZrConnectionSelection({
    required this.family,
    required this.kind,
    this.productId,
    this.organizationId,
    this.projectId,
  });

  final String family;
  final String kind;
  final String? productId;
  final String? organizationId;
  final String? projectId;

  Map<String, dynamic> toRequestJson() => {
    'kind': kind,
    if (productId != null) 'productId': productId,
    if (organizationId != null) 'organizationId': organizationId,
    if (projectId != null) 'projectId': projectId,
  };

  static ZrConnectionSelection? of(String family, dynamic j) {
    if (j is! Map<String, dynamic>) return null;
    final kind = j['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return ZrConnectionSelection(
      family: family,
      kind: kind,
      productId: j['productId'] is String ? j['productId'] as String? : null,
      organizationId: j['organizationId'] is String
          ? j['organizationId'] as String?
          : null,
      projectId: j['projectId'] is String ? j['projectId'] as String? : null,
    );
  }
}

class ZrConnectionSettings {
  const ZrConnectionSettings({
    this.familyDomain,
    required this.selections,
    required this.rawSelections,
  });

  final String? familyDomain;

  final Map<String, ZrConnectionSelection> selections;

  final Map<String, dynamic> rawSelections;

  static ZrConnectionSettings fromJson(Map<String, dynamic> j) {
    final domain = j['providerFamilyDomain'];
    final raw = j['providerFamilyConnectionSelections'];
    final rawMap = raw is Map<String, dynamic>
        ? Map<String, dynamic>.of(raw)
        : <String, dynamic>{};
    final parsed = <String, ZrConnectionSelection>{};
    for (final entry in rawMap.entries) {
      final sel = ZrConnectionSelection.of(entry.key, entry.value);
      if (sel != null) parsed[entry.key] = sel;
    }
    return ZrConnectionSettings(
      familyDomain: domain is String && domain.isNotEmpty ? domain : null,
      selections: parsed,
      rawSelections: rawMap,
    );
  }
}

class ZrQuotaLimit {
  const ZrQuotaLimit({
    required this.type,
    this.unit,
    this.number,
    this.remaining,
    this.percentage,
    this.nextResetTime,
    this.meter,
  });

  final String? type;
  final num? unit;
  final num? number;
  final num? remaining;

  final num? percentage;
  final String? nextResetTime;
  final String? meter;

  static ZrQuotaLimit? fromJson(Map<String, dynamic> j) {
    if (j.isEmpty) return null;
    return ZrQuotaLimit(
      type: j['type'] is String ? j['type'] as String? : null,
      unit: j['unit'] is num ? j['unit'] as num? : null,
      number: j['number'] is num ? j['number'] as num? : null,
      remaining: j['remaining'] is num ? j['remaining'] as num? : null,
      percentage: j['percentage'] is num ? j['percentage'] as num? : null,
      nextResetTime: j['nextResetTime'] is String
          ? j['nextResetTime'] as String?
          : null,
      meter: j['meter'] is String ? j['meter'] as String? : null,
    );
  }
}

class UsageEntitlement {
  const UsageEntitlement({
    required this.generatedAt,
    required this.limits,
    this.planName,
    this.planProductId,
    this.quotaLevel,
    this.mcpUsedPercentage,
    this.unavailableReason,
  });

  final int generatedAt;

  final String? planName;
  final String? planProductId;

  final String? quotaLevel;

  final num? mcpUsedPercentage;
  final String? unavailableReason;
  final List<ZrQuotaLimit> limits;

  bool get noPlan => unavailableReason == 'no_plan';

  static UsageEntitlement? fromJson(Map<String, dynamic> j) {
    if (j.isEmpty) return null;
    final quota = j['quota'];
    final subscription = j['subscription'];
    final mcpQuota = j['mcpQuota'];
    final aggregate = mcpQuota is Map<String, dynamic>
        ? mcpQuota['aggregate']
        : null;
    String? planName;
    String? planProductId;
    if (subscription is Map<String, dynamic>) {
      final details = subscription['details'];
      if (details is List && details.isNotEmpty) {
        final first = details.first;
        if (first is Map<String, dynamic>) {
          final name = first['productName'];
          final pid = first['productId'];
          planName = name is String && name.trim().isNotEmpty
              ? name.trim()
              : pid is String
              ? pid
              : null;
          planProductId = pid is String ? pid : null;
        }
      }
    }
    final quotaMap = quota is Map<String, dynamic> ? quota : const {};
    final limits = quotaMap['limits'];
    final level = quotaMap['level'];
    final generatedAt = j['generatedAt'];
    return UsageEntitlement(
      generatedAt: generatedAt is num ? generatedAt.toInt() : 0,
      planName: planName,
      planProductId: planProductId,
      quotaLevel: level is String && level.isNotEmpty ? level : null,
      mcpUsedPercentage: aggregate is Map<String, dynamic>
          ? aggregate['percentage'] is num
                ? aggregate['percentage'] as num?
                : null
          : null,
      unavailableReason: j['unavailableReason'] is String
          ? j['unavailableReason'] as String?
          : null,
      limits: limits is List
          ? [
              for (final l in limits)
                if (l is Map<String, dynamic>) ZrQuotaLimit.fromJson(l),
            ].whereType<ZrQuotaLimit>().toList()
          : const [],
    );
  }
}
