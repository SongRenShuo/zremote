import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/claim.dart' show parseSecOrMs;
import '../models/provider_settings.dart'
    show
        EntitlementSemantic,
        ProviderSettingsView,
        UsageEntitlement,
        ZrProvider,
        classifyEntitlement,
        entitlementParamsFor,
        pickEntitlementProvider;
import 'rpc_bridge.dart';

/// 额度中心客户端（开发计划 20261115-0901 P1-2 / P1-5）。
///
/// - 通路 A（宿主 RPC，默认）：usage-stats 频道 `getEntitlementSnapshot`
///   （先例：model_settings_page 套餐卡）与重置卡
///   `getCodingPlanUsageSnapshot` / `useCodingPlanReset`。
/// - 通路 B（直连 HTTP，dio）：zcode.z.ai `billing/balance`（Bearer JWT）与
///   bigmodel.cn `quota/limit`（Authorization 头 API key 原样，不带 Bearer）。
///   请求头全套照计划附录 A.3；`X-Device-Mid` 由调用方注入（集成时接账号库）。
///   无 token 时通路 B 优雅降级为仅通路 A。
///
/// PlanSlot 归一化移植自 zcode-switch `src-tauri/src/quota.rs`
/// （tier 归类 / 槽优先级 max>pro>lite>start>trial / 余额挂槽与「其他额度」
/// 槽 / total·used·remaining 互推补全 / TIME_LIMIT 优先主指标 /
/// nextResetTime 本地时间展示）。
const String kZaiBillingBalanceUrl =
    'https://zcode.z.ai/api/v1/zcode-plan/billing/balance';
const String kBigmodelQuotaLimitUrl =
    'https://bigmodel.cn/api/monitor/usage/quota/limit';
const String kQuotaAppVersion = '3.18.2';

class QuotaFetchException implements Exception {
  const QuotaFetchException(this.message);

  final String message;

  @override
  String toString() => 'QuotaFetchException($message)';
}

/// 重置卡宿主方法缺失（no-method / no-services）：UI 隐藏该区块。
class ResetCardUnsupportedException implements Exception {
  const ResetCardUnsupportedException(this.message);

  final String message;

  @override
  String toString() => 'ResetCardUnsupportedException($message)';
}

/// 通路 B 供票：由上层接线（集成时接账号库），无 token 时通路 B 降级。
typedef QuotaTokenProvider = Future<QuotaTokens?> Function();

class QuotaTokens {
  const QuotaTokens({this.zaiJwt, this.bigmodelApiKey});

  /// zcode.z.ai billing 接口 Bearer JWT。
  final String? zaiJwt;

  /// bigmodel.cn quota 接口原样 Authorization（API key）。
  final String? bigmodelApiKey;

  bool get isEmpty =>
      (zaiJwt == null || zaiJwt!.trim().isEmpty) &&
      (bigmodelApiKey == null || bigmodelApiKey!.trim().isEmpty);
}

enum QuotaTierCode { max, pro, lite, start, trial, other }

/// 槽优先级（quota.rs tier_rank）：max>pro>lite>start>trial>other。
int quotaTierRank(QuotaTierCode code) => switch (code) {
  QuotaTierCode.max => 5,
  QuotaTierCode.pro => 4,
  QuotaTierCode.lite => 3,
  QuotaTierCode.start => 2,
  QuotaTierCode.trial => 1,
  QuotaTierCode.other => 0,
};

const List<String> _kTrialKeywords = [
  'trial',
  'taste',
  'experience',
  'gift',
  'weekend',
  'promo',
  'activity',
  '体验',
];

/// tier 归类（quota.rs plan_tier_from_id，判定顺序按任务语义调整）：
/// plan_id + name 关键词匹配；体验族先于 pro 判定——promo 含 "pro" 前缀，
/// quota.rs 原序会把 promo 误归 Pro，开发计划 P1-2 语义为 promo→体验。
/// 返回 (展示名, 槽代码)。
({String display, QuotaTierCode code}) quotaTierOf(
  String planId,
  String? name,
) {
  final hay = '$planId ${name ?? ''}'.toLowerCase();
  if (hay.contains('max')) {
    return (display: 'Max', code: QuotaTierCode.max);
  }
  for (final k in _kTrialKeywords) {
    if (hay.contains(k)) {
      return (display: '体验', code: QuotaTierCode.trial);
    }
  }
  if (hay.contains('pro')) {
    return (display: 'Pro', code: QuotaTierCode.pro);
  }
  if (hay.contains('lite')) {
    return (display: 'Lite', code: QuotaTierCode.lite);
  }
  if (hay.contains('start')) {
    return (display: 'Start Plan', code: QuotaTierCode.start);
  }
  return (display: planId, code: QuotaTierCode.other);
}

/// level / 产品名挤 tier（quota.rs tier_from_level）：仅识别 Max/Pro/Lite。
({String display, QuotaTierCode code}) quotaTierFromLevel(String level) {
  final l = level.toLowerCase();
  if (l.contains('max')) {
    return (display: 'Max', code: QuotaTierCode.max);
  }
  if (l.contains('pro')) {
    return (display: 'Pro', code: QuotaTierCode.pro);
  }
  if (l.contains('lite')) {
    return (display: 'Lite', code: QuotaTierCode.lite);
  }
  return (display: level, code: QuotaTierCode.other);
}

/// 无 plans 时的兜底 tier（quota.rs extract_plan_tier）：active 套餐关键词。
({String display, QuotaTierCode code})? planTierFromActivePlans(
  Map<String, dynamic> doc,
) {
  final raw = doc['plans'];
  if (raw is! List) return null;
  bool matches(List<String> kws) => raw.whereType<Map<String, dynamic>>().any(
    (p) =>
        (p['status'] is String
            ? (p['status'] as String).toLowerCase()
            : 'active') ==
        'active' &&
        kws.any(
          (k) =>
              '${p['plan_id'] ?? ''} ${p['name'] ?? ''}'
                  .toLowerCase()
                  .contains(k),
        ),
  );
  if (matches(const ['max'])) return (display: 'Max', code: QuotaTierCode.max);
  if (matches(const ['pro'])) return (display: 'Pro', code: QuotaTierCode.pro);
  if (matches(const ['lite'])) {
    return (display: 'Lite', code: QuotaTierCode.lite);
  }
  if (matches(const ['start-plan', 'start plan', 'start'])) {
    return (display: 'Start Plan', code: QuotaTierCode.start);
  }
  return null;
}

/// 单条额度项：窗口（bigmodel limits）或模型余额（zai balances）。
class QuotaItem {
  const QuotaItem({
    required this.name,
    this.total,
    this.used,
    this.remaining,
    this.percentUsed,
    this.serverPercentage,
    this.unit = '',
    this.kind,
    this.window,
    this.unitCode,
    this.resetAt,
    this.periodEndAt,
    this.capabilities = const [],
  });

  final String name;

  final double? total;
  final double? used;
  final double? remaining;

  /// 已用百分比 0-100（优先 used/total 推算，缺数时回落服务端 percentage）。
  final double? percentUsed;
  final double? serverPercentage;

  /// 计量单位原始串（token / 次 / 分钟 …），UI 直接展示。
  final String unit;

  /// prompt_count / duration / raw（bigmodel 窗口）。
  final String? kind;

  /// hours:N / daily / monthly / weekly / cycle。
  final String? window;
  final String? unitCode;

  /// 窗口重置时间（bigmodel nextResetTime，已转本地 DateTime）。
  final DateTime? resetAt;

  /// 余额有效期（balances 的 period_end / expires_at）。
  final DateTime? periodEndAt;

  /// balances 的 capabilities（形如 model:GLM-5.3）。
  final List<String> capabilities;

  List<String> get modelIds => [
    for (final c in capabilities)
      if (c.startsWith('model:')) c.substring('model:'.length),
  ];
}

/// 套餐槽：一个生效套餐 + 其窗口条与模型余额行。
class PlanSlot {
  const PlanSlot({
    required this.pid,
    required this.tierCode,
    this.tier,
    this.name,
    this.startsAt,
    this.endsAt,
    this.expireAt,
    this.total,
    this.used,
    this.remaining,
    this.percentUsed,
    this.items = const [],
  });

  final String pid;
  final QuotaTierCode tierCode;

  /// 展示名（Max / Pro / Lite / Start Plan / 体验 / 原始 plan_id）。
  final String? tier;
  final String? name;
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// 有效期兜底（quota.rs extract_expire：多别名键）。
  final DateTime? expireAt;

  final double? total;
  final double? used;
  final double? remaining;
  final double? percentUsed;

  final List<QuotaItem> items;

  bool get hasContent =>
      tier != null || items.isNotEmpty || total != null;
}

/// 额度总览：多源合并后的归一化结果。
class QuotaOverview {
  const QuotaOverview({
    required this.plans,
    required this.items,
    required this.refreshedAt,
    required this.sources,
    this.total,
    this.used,
    this.remaining,
    this.percentUsed,
    this.planTier,
    this.planTierCode,
    this.planExpireAt,
    this.noPlan = false,
    this.notConfigured = false,
  });

  /// 数据源码：host-snapshot / zai-billing / bigmodel-monitor。
  final List<String> sources;
  final List<PlanSlot> plans;
  final List<QuotaItem> items;
  final DateTime refreshedAt;

  final double? total;
  final double? used;
  final double? remaining;
  final double? percentUsed;
  final String? planTier;
  final QuotaTierCode? planTierCode;
  final DateTime? planExpireAt;

  /// 账号无生效套餐（通路 A no_plan 或直连「不存在 coding plan」族消息）。
  final bool noPlan;

  /// 宿主未登录 / 未配置（not_configured / not_authenticated / quota 缺失）。
  /// 与 [noPlan] 分开：这是「登录后查看」引导态，不是加载失败。
  final bool notConfigured;

  bool get isEmpty => plans.isEmpty && items.isEmpty;
  bool get hasDirectSource =>
      sources.contains('zai-billing') || sources.contains('bigmodel-monitor');

  PlanSlot? get primaryPlan {
    PlanSlot? best;
    for (final s in plans) {
      if (!s.hasContent) continue;
      if (best == null ||
          quotaTierRank(s.tierCode) > quotaTierRank(best.tierCode)) {
        best = s;
      }
    }
    return best;
  }

  /// TIME_LIMIT 优先作主指标（quota.rs：TIME_LIMIT 且有 total，否则首个有数项，
  /// 全无数据时兜底首项）。
  QuotaItem? mainItemOf(PlanSlot slot) {
    QuotaItem? firstWithData;
    for (final i in slot.items) {
      if (i.total != null || i.percentUsed != null) {
        firstWithData ??= i;
        if (i.kind == 'duration') return i;
      }
    }
    if (firstWithData != null) return firstWithData;
    if (slot.items.isNotEmpty) return slot.items.first;
    for (final i in items) {
      if (i.kind == 'duration' && (i.total != null || i.percentUsed != null)) {
        return i;
      }
    }
    return items.isEmpty ? null : items.first;
  }
}

// ---------------------------------------------------------------------------
// 时间解析（quota.rs extract_expire / fmt_reset_time 的 Dart 化）
// ---------------------------------------------------------------------------

/// 秒/毫秒数值与多种字符串形态的宽松时间解析；无法识别返回 null。
DateTime? parseQuotaDateTime(Object? v) {
  if (v is num) {
    if (v > 1e12) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    if (v > 1e9) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }
  if (v is! String) return null;
  final t = v.trim();
  if (t.isEmpty) return null;
  final asNum = double.tryParse(t);
  if (asNum != null) return parseQuotaDateTime(asNum);
  final direct = DateTime.tryParse(t);
  if (direct != null) return direct;
  if (t.length >= 16) {
    final isoish = DateTime.tryParse('${t.substring(0, 10)}T${t.substring(11)}');
    if (isoish != null) return isoish;
  }
  return null;
}

/// 多别名有效期键兜底（quota.rs extract_expire 的 KEYS 表）。
const List<String> _kExpireKeys = [
  'nextRenewTime',
  'expireTime',
  'expire_time',
  'endTime',
  'end_time',
  'expireAt',
  'expiredTime',
  'validEndTime',
  'expires_at',
  'expiresAt',
  'expired_at',
  'period_end',
];

DateTime? _extractExpire(Map<String, dynamic> j) {
  for (final k in _kExpireKeys) {
    final at = parseQuotaDateTime(j[k]);
    if (at != null) return at;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 外壳剥离（quota.rs unwrap：最多 4 层 data/result 单键包装）
// ---------------------------------------------------------------------------

Map<String, dynamic> unwrapQuotaDoc(Map<String, dynamic> doc) {
  var cur = doc;
  for (var i = 0; i < 4; i++) {
    final data = cur['data'];
    if (data is Map<String, dynamic>) {
      cur = data;
      continue;
    }
    final result = cur['result'];
    if (result is Map<String, dynamic>) {
      cur = result;
      continue;
    }
    break;
  }
  return cur;
}

/// 业务成功判定（quota.rs business_ok）：code 缺失/200/0 且 success != false。
bool quotaBusinessOk(Map<String, dynamic> doc) {
  final code = doc['code'];
  final success = doc['success'];
  final codeOk =
      code is! num || code == 200 || code == 0;
  return codeOk && success != false;
}

String quotaBizErrorText(Map<String, dynamic> doc) {
  final msg = const ['msg', 'message', 'error']
      .map((k) => doc[k])
      .whereType<String>()
      .firstOrNull;
  return 'code=${doc['code'] ?? '?'}${msg == null ? '' : ' $msg'}';
}

// ---------------------------------------------------------------------------
// 归一化：通路 A 宿主快照
// ---------------------------------------------------------------------------

/// 通路 A：宿主 getEntitlementSnapshot（复用 UsageEntitlement 模型）。
/// 形似但字段缺失 → 降级空项；完全不像（null）→ null。
QuotaOverview? normalizeHostSnapshot(UsageEntitlement ent) {
  if (ent.limits.isEmpty) return null;
  final items = <QuotaItem>[];
  for (final l in ent.limits) {
    final type = (l.type ?? l.meter ?? '').toUpperCase();
    final window = quotaWindowCode(l.unit, l.number);
    final percentUsed = l.percentage == null
        ? null
        : (l.percentage!).clamp(0, 100).toDouble();
    items.add(
      QuotaItem(
        name: type,
        kind: quotaKindCode(type),
        window: window,
        total: null,
        used: null,
        remaining: l.remaining == null ? null : (l.remaining!).toDouble(),
        percentUsed: percentUsed,
        serverPercentage: l.percentage == null
            ? null
            : (l.percentage!).toDouble(),
        resetAt: parseQuotaDateTime(l.nextResetTime),
      ),
    );
  }
  final tier = ent.quotaLevel == null
      ? null
      : quotaTierFromLevel(ent.quotaLevel!);
  var main = items.where((i) => i.kind == 'duration').firstOrNull;
  main ??= items.first;
  return QuotaOverview(
    plans: [
      PlanSlot(
        pid: ent.planProductId ?? 'host',
        tierCode: tier?.code ?? QuotaTierCode.other,
        tier: tier?.display,
        name: ent.planName,
        expireAt: null,
        total: main.total,
        used: main.used,
        remaining: main.remaining,
        percentUsed: main.percentUsed,
        items: items,
      ),
    ],
    items: items,
    refreshedAt: DateTime.fromMillisecondsSinceEpoch(
      ent.generatedAt > 0
          ? ent.generatedAt
          : DateTime.now().millisecondsSinceEpoch,
    ),
    sources: const ['host-snapshot'],
  );
}

// ---------------------------------------------------------------------------
// 归一化：通路 B-1 zai billing/balance（quota.rs normalize_balance 移植）
// ---------------------------------------------------------------------------

/// balances 按 plan_id 挂槽；无 plan_id 且仅 1 槽挂唯一槽；孤儿进「其他额度」槽。
QuotaOverview? normalizeZaiBalanceDoc(Map<String, dynamic> doc) {
  final balance = unwrapQuotaDoc(doc);
  final rawPlans = balance['plans'];
  final rawBalances = balance['balances'];
  if (rawPlans is! List && rawBalances is! List) return null;

  var slots = <PlanSlot>[
    if (rawPlans is List)
      for (final p in rawPlans)
        if (p is Map<String, dynamic> &&
            (p['status'] is! String ||
                (p['status'] as String).toLowerCase() == 'active'))
          _planSlotOf(p),
  ];

  final anyPid = rawBalances is List &&
      rawBalances
          .whereType<Map<String, dynamic>>()
          .any((b) => _balancePlanIdOf(b) != null);

  final loose = <QuotaItem>[];
  if (rawBalances is List) {
    for (final raw in rawBalances) {
      if (raw is! Map<String, dynamic>) continue;
      final item = _balanceItemOf(raw);
      final bpid = _balancePlanIdOf(raw);
      var targetIndex = -1;
      if (bpid != null && bpid.isNotEmpty) {
        for (var i = 0; i < slots.length; i++) {
          if (slots[i].pid == bpid) {
            targetIndex = i;
            break;
          }
        }
      } else if (slots.length == 1 && !anyPid) {
        targetIndex = 0;
      }
      if (targetIndex >= 0) {
        final target = slots[targetIndex];
        slots[targetIndex] = PlanSlot(
          pid: target.pid,
          tierCode: target.tierCode,
          tier: target.tier,
          name: target.name,
          startsAt: target.startsAt,
          endsAt: target.endsAt,
          expireAt: target.expireAt ?? item.periodEndAt,
          total: target.total,
          used: target.used,
          remaining: target.remaining,
          percentUsed: target.percentUsed,
          items: [...target.items, item],
        );
      } else {
        loose.add(item);
      }
    }
  }

  if (slots.isEmpty && loose.isNotEmpty) {
    final tier = planTierFromActivePlans(balance);
    slots = [
      PlanSlot(
        pid: '',
        tierCode: tier?.code ?? QuotaTierCode.other,
        tier: tier?.display,
        items: loose,
      ),
    ];
  } else if (slots.isNotEmpty && loose.isNotEmpty) {
    slots = [
      ...slots,
      PlanSlot(
        pid: '',
        tierCode: QuotaTierCode.other,
        tier: '其他额度',
        items: loose,
      ),
    ];
  }

  if (slots.isEmpty) return null;

  slots = [for (final s in slots) _completeSlot(s)];
  slots.sort((a, b) {
    final c = quotaTierRank(b.tierCode).compareTo(quotaTierRank(a.tierCode));
    return c != 0 ? c : a.pid.compareTo(b.pid);
  });

  return QuotaOverview(
    plans: slots,
    items: [for (final s in slots) ...s.items],
    refreshedAt: DateTime.now(),
    sources: const ['zai-billing'],
  );
}

PlanSlot _planSlotOf(Map<String, dynamic> p) {
  final pid = p['plan_id'] is String ? p['plan_id'] as String : '';
  final name = p['name'] is String ? p['name'] as String? : null;
  final tier = quotaTierOf(pid, name);
  return PlanSlot(
    pid: pid,
    tierCode: tier.code,
    tier: tier.display,
    name: (name == null || name.trim().isEmpty) ? pid : name,
    startsAt: parseQuotaDateTime(p['starts_at']),
    endsAt: parseQuotaDateTime(p['ends_at']),
    expireAt: _extractExpire(p),
  );
}

String? _balancePlanIdOf(Map<String, dynamic> b) {
  for (final k in const ['plan_id', 'planId', 'entitlement_id']) {
    final v = b[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

QuotaItem _balanceItemOf(Map<String, dynamic> b) {
  final total = _numOf(b['total_units']);
  final used = _numOf(b['used_units']);
  final remaining = _numOf(b['remaining_units']) ?? _numOf(b['available_units']);
  final caps = b['capabilities'];
  return QuotaItem(
    name: const ['show_name', 'name', 'entitlement_id', 'plan_id']
        .map((k) => b[k])
        .whereType<String>()
        .firstOrNull ??
        'Unknown',
    total: total,
    used: used,
    remaining: remaining,
    percentUsed: switch ((total, used)) {
      (double t, double u) when t > 0 => (u / t * 100).clamp(0, 100).toDouble(),
      _ => null,
    },
    unit: (b['unit_type'] ?? b['meter']) is String
        ? (b['unit_type'] ?? b['meter']) as String
        : 'quota',
    periodEndAt:
        parseQuotaDateTime(b['period_end']) ??
        parseQuotaDateTime(b['expires_at']),
    capabilities: [
      if (caps is List) for (final c in caps) if (c is String) c,
    ],
  );
}

/// total/used/remaining 三者互推补全（quota.rs normalize_balance 尾段）。
PlanSlot _completeSlot(PlanSlot s) {
  if (s.items.isEmpty && s.total == null) return s;
  double? sum(double? Function(QuotaItem) f) {
    var found = false;
    var total = 0.0;
    for (final i in s.items) {
      final v = f(i);
      if (v != null) {
        found = true;
        total += v;
      }
    }
    return found ? total : null;
  }

  final itemsTotal = sum((i) => i.total);
  final itemsUsed = sum((i) => i.used);
  final itemsRemaining = sum((i) => i.remaining);
  var total = s.total ?? itemsTotal;
  var used = s.used ?? itemsUsed;
  var remaining = s.remaining ?? itemsRemaining;
  total ??= used != null && remaining != null ? used + remaining : null;
  used ??= total != null && remaining != null ? (total - remaining) : null;
  if (used != null && used < 0) used = 0;
  remaining ??= total != null && used != null ? (total - used) : null;
  if (remaining != null && remaining < 0) remaining = 0;
  final double? percentUsed = switch ((total, used)) {
    (double t, double u) when t > 0 => (u / t * 100).clamp(0, 100).toDouble(),
    _ => s.percentUsed,
  };
  return PlanSlot(
    pid: s.pid,
    tierCode: s.tierCode,
    tier: s.tier,
    name: s.name,
    startsAt: s.startsAt,
    endsAt: s.endsAt,
    expireAt: s.expireAt,
    total: total,
    used: used,
    remaining: remaining,
    percentUsed: percentUsed,
    items: s.items,
  );
}

// ---------------------------------------------------------------------------
// 归一化：通路 B-2 bigmodel quota/limit（quota.rs normalize_quota_limit 移植）
// ---------------------------------------------------------------------------

/// bigmodel 窗口归一化：unit 3=每N小时(N=number，默认5)/4=每天/5=每月/6=每周。
QuotaOverview? normalizeBigmodelLimitDoc(Map<String, dynamic> doc) {
  final data = unwrapQuotaDoc(doc);
  final rawLimits = data['limits'];
  if (rawLimits is! List) return null;

  final items = <QuotaItem>[];
  QuotaItem? main;
  for (final raw in rawLimits) {
    if (raw is! Map<String, dynamic>) continue;
    final type = raw['type'] is String ? raw['type'] as String : '';
    final total = _numOf(raw['usage']);
    final used = _numOf(raw['currentValue']);
    final remaining = _numOf(raw['remaining']);
    final percentage = _numOf(raw['percentage']);
    double? serverPercentUsed;
    if (percentage case final double p?) {
      serverPercentUsed = p.clamp(0, 100).toDouble();
    }
    final item = QuotaItem(
      name: type,
      total: total,
      used: used,
      remaining: remaining,
      percentUsed: switch ((total, used)) {
        (double t, double u) when t > 0 => (u / t * 100).clamp(0, 100).toDouble(),
        _ => serverPercentUsed,
      },
      serverPercentage: percentage,
      kind: quotaKindCode(type),
      window: quotaWindowCode(
        raw['unit'] is num ? raw['unit'] as num : null,
        raw['number'] is num ? raw['number'] as num : null,
      ),
      unitCode: quotaUnitCode(type),
      unit: quotaUnitLabel(type),
      resetAt: raw['nextResetTime'] is num && (raw['nextResetTime'] as num) > 0
          ? parseQuotaDateTime(raw['nextResetTime'])
          : null,
    );
    if (type == 'TIME_LIMIT' && total != null) {
      main ??= item;
    }
    items.add(item);
  }
  if (items.isEmpty) return null;

  main ??= items.where((i) => i.total != null).firstOrNull ?? items.first;
  final level = data['level'];
  final tier = level is String && level.isNotEmpty
      ? quotaTierFromLevel(level)
      : null;
  return QuotaOverview(
    plans: [
      PlanSlot(
        pid: 'bigmodel',
        tierCode: tier?.code ?? QuotaTierCode.other,
        tier: tier?.display,
        total: main.total,
        used: main.used,
        remaining: main.remaining,
        percentUsed: main.percentUsed,
        items: items,
      ),
    ],
    items: items,
    refreshedAt: DateTime.now(),
    sources: const ['bigmodel-monitor'],
  );
}

/// kind 归类：TOKENS_LIMIT→prompt_count，TIME_LIMIT→duration，其余 raw。
String quotaKindCode(String type) {
  final t = type.toUpperCase();
  if (t.contains('TOKENS')) return 'prompt_count';
  if (t.contains('TIME')) return 'duration';
  return 'raw';
}

String? quotaUnitCode(String type) => switch (quotaKindCode(type)) {
  'prompt_count' => 'count',
  'duration' => 'minutes',
  _ => null,
};

String quotaUnitLabel(String type) => switch (quotaKindCode(type)) {
  'prompt_count' => '次',
  'duration' => '分钟',
  _ => '',
};

/// unit/number → 窗口码（hours:N / daily / monthly / weekly / cycle）。
/// unit 未知/缺失 → cycle（quota.rs unit_label 的兜底分支）。
String quotaWindowCode(num? unit, num? number) {
  if (unit == null) return 'cycle';
  return switch (unit.toInt()) {
    3 => 'hours:${(number ?? 5).toInt()}',
    4 => 'daily',
    5 => 'monthly',
    6 => 'weekly',
    _ => 'cycle',
  };
}

// ---------------------------------------------------------------------------
// 多源合并（quota.rs merge_parts 移植）
// ---------------------------------------------------------------------------

QuotaOverview mergeQuotaParts(List<QuotaOverview> parts) {
  final slots = <PlanSlot>[];
  final slotSource = <String>[];
  final sources = <String>[];
  var refreshed = DateTime.fromMillisecondsSinceEpoch(0);
  for (final p in parts) {
    for (final s in p.sources) {
      if (!sources.contains(s)) sources.add(s);
    }
    if (p.refreshedAt.isAfter(refreshed)) refreshed = p.refreshedAt;
    for (final s in p.plans) {
      // 跨源去重：同 tier+name 且双方都有条目 → 后到者跳过。
      final dup = slotSource.asMap().entries.any((e) {
        final other = slots[e.key];
        return e.value != p.sources.first &&
            other.tierCode == s.tierCode &&
            other.name == s.name &&
            other.items.isNotEmpty &&
            s.items.isNotEmpty;
      });
      if (!dup) {
        slots.add(s);
        slotSource.add(p.sources.first);
      }
    }
  }
  slots.sort((a, b) {
    final c = quotaTierRank(b.tierCode).compareTo(quotaTierRank(a.tierCode));
    return c != 0 ? c : a.pid.compareTo(b.pid);
  });
  final primary = QuotaOverview(
    plans: slots,
    items: [for (final s in slots) ...s.items],
    refreshedAt: refreshed,
    sources: sources,
  ).primaryPlan;
  return QuotaOverview(
    plans: slots,
    items: [for (final s in slots) ...s.items],
    refreshedAt: refreshed,
    sources: sources,
    total: primary?.total,
    used: primary?.used,
    remaining: primary?.remaining,
    percentUsed: primary?.percentUsed,
    planTier: primary?.tier,
    planTierCode: primary?.tierCode,
    planExpireAt: primary?.expireAt ?? primary?.endsAt,
  );
}

double? _numOf(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(',', ''));
  return null;
}

// ---------------------------------------------------------------------------
// 重置卡（P1-5）
// ---------------------------------------------------------------------------

/// 一类重置卡（5 小时 / 周）。
class ResetCardEntry {
  const ResetCardEntry({
    required this.resetType,
    required this.available,
    this.expiresAt,
  });

  /// 服务端原始 reset_type（如 FIVE_HOURS / WEEKLY）。
  final String resetType;
  final int available;
  final DateTime? expiresAt;

  bool get isFiveHour {
    final t = resetType.toLowerCase();
    return t.contains('hour') || t.contains('5h') || t.contains('five');
  }

  bool get isWeekly => resetType.toLowerCase().contains('week');
}

class ResetCardHistoryEntry {
  const ResetCardHistoryEntry({required this.resetType, this.usedAt});

  final String resetType;
  final DateTime? usedAt;
}

class ResetCardStatus {
  const ResetCardStatus({
    required this.entries,
    required this.history,
    this.hasUnreadHistory = false,
  });

  final List<ResetCardEntry> entries;
  final List<ResetCardHistoryEntry> history;
  final bool hasUnreadHistory;

  /// 形状漂移容错解析（宿主形状以 P1-1 实测为准，别名兜底）：
  /// 容器键 resets/cards/opportunities/reset_cards/items；条目内
  /// reset_type|resetType|type + available|count|remaining +
  /// expires_at|expiredAt|expire_time；顶层 five*/week* 数值键兜底。
  static ResetCardStatus fromJson(Map<String, dynamic> j) {
    final entries = <ResetCardEntry>[];
    const containerKeys = [
      'resets',
      'cards',
      'reset_cards',
      'resetCards',
      'opportunities',
      'items',
    ];
    for (final key in containerKeys) {
      final raw = j[key];
      if (raw is! List) continue;
      for (final e in raw) {
        if (e is! Map<String, dynamic>) continue;
        final type = const ['reset_type', 'resetType', 'type']
            .map((k) => e[k])
            .whereType<String>()
            .firstOrNull;
        if (type == null || type.isEmpty) continue;
        final available =
            const ['available', 'count', 'remaining', 'left', 'available_count']
                .map((k) => e[k])
                .whereType<num>()
                .firstOrNull
                ?.toInt() ??
            0;
        final expiresAt = const [
          'expires_at',
          'expiredAt',
          'expire_time',
          'expiresAt',
          'valid_until',
        ].map((k) => parseQuotaDateTime(e[k])).whereType<DateTime>().firstOrNull;
        entries.add(
          ResetCardEntry(
            resetType: type,
            available: available,
            expiresAt: expiresAt,
          ),
        );
      }
      if (entries.isNotEmpty) break;
    }
    if (entries.isEmpty) {
      // 顶层扁平形状兜底：five_hour_resets_available / weekly_resets_left …
      for (final e in j.entries) {
        final k = e.key.toLowerCase();
        if (e.value is! num) continue;
        if (k.contains('five') || k.contains('hour')) {
          entries.add(
            ResetCardEntry(
              resetType: 'FIVE_HOURS',
              available: (e.value as num).toInt(),
            ),
          );
        } else if (k.contains('week')) {
          entries.add(
            ResetCardEntry(
              resetType: 'WEEKLY',
              available: (e.value as num).toInt(),
            ),
          );
        }
      }
    }

    final history = <ResetCardHistoryEntry>[];
    for (final key in const ['history', 'records', 'recent', 'recent_resets']) {
      final raw = j[key];
      if (raw is! List) continue;
      for (final e in raw) {
        if (e is! Map<String, dynamic>) continue;
        history.add(
          ResetCardHistoryEntry(
            resetType: const ['reset_type', 'resetType', 'type']
                .map((k) => e[k])
                .whereType<String>()
                .firstOrNull ??
                '',
            usedAt: const [
              'used_at',
              'usedAt',
              'createdAt',
              'created_at',
              'time',
              'reset_at',
            ].map((k) => parseSecOrMs(e[k])).whereType<DateTime>().firstOrNull,
          ),
        );
      }
      if (history.isNotEmpty) break;
    }

    return ResetCardStatus(
      entries: entries,
      history: history,
      hasUnreadHistory:
          j['has_unread_history'] == true || j['hasUnreadHistory'] == true,
    );
  }
}

class ResetCardUseResult {
  const ResetCardUseResult({
    required this.success,
    required this.message,
    this.rateLimited = false,
    this.nextTryAt,
    this.idempotencyKey,
  });

  final bool success;
  final String message;

  /// 业务码 3301：限流，配合 nextTryAt 倒计时。
  final bool rateLimited;
  final DateTime? nextTryAt;
  final String? idempotencyKey;

  static ResetCardUseResult fromResponse(
    Map<String, dynamic> j,
    String idempotencyKey,
  ) {
    final code = j['code'] is num ? (j['code'] as num).toInt() : null;
    // 宿主成功回执为 {used: true}（CodingPlanResetUseResult）；旧形状
    // {success: true} 兼容保留。
    final success =
        (j['used'] == true || j['success'] == true) && code != 3301;
    return ResetCardUseResult(
      success: success,
      message: j['message'] is String ? j['message'] as String : '',
      rateLimited: code == 3301,
      nextTryAt: parseSecOrMs(j['next_try_at']) ??
          parseSecOrMs(j['nextTryAt']),
      idempotencyKey: idempotencyKey,
    );
  }

  /// 宿主把业务错误抛成 RPC 异常文本时的兜底：识别 3301 与 next_try_at 读数。
  static ResetCardUseResult fromErrorText(
    String text,
    String idempotencyKey,
  ) {
    final rateLimited = text.contains('3301');
    DateTime? nextTryAt;
    final match = RegExp(
      r'next_try_at["\s:=]+(\d{10,14})',
    ).firstMatch(text);
    if (match != null) {
      nextTryAt = parseSecOrMs(int.parse(match.group(1)!));
    }
    return ResetCardUseResult(
      success: false,
      message: text,
      rateLimited: rateLimited,
      nextTryAt: nextTryAt,
      idempotencyKey: idempotencyKey,
    );
  }
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

class QuotaClient {
  QuotaClient({
    required this.bridge,
    this.tokenProvider,
    this.deviceMid,
    this.appVersion = kQuotaAppVersion,
    String? platform,
    String? osCategory,
    this.osVersion,
    this.clientLanguage = 'zh-CN',
    this.clientTimezone,
    this.dio,
  }) : platform = platform ??
           (defaultTargetPlatform == TargetPlatform.iOS
               ? 'ios-arm64'
               : 'android-arm64'),
       osCategory = osCategory ??
           (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');

  final RpcBridge bridge;
  final QuotaTokenProvider? tokenProvider;

  /// 每账号稳定值（附录 A.3）；null 时省略该头。
  final String? deviceMid;
  final String appVersion;
  final String platform;
  final String osCategory;
  final String? osVersion;
  final String clientLanguage;
  final String? clientTimezone;

  final Dio? dio;
  final Uuid _uuid = Uuid();
  late final Dio _dio = dio ?? Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  /// zcode.z.ai 直连请求头全套（附录 A.3；quota.rs zai_headers 移植）。
  Map<String, String> zaiBillingHeaders(String jwt) => {
    'User-Agent': 'ZCode/$appVersion',
    'HTTP-Referer': 'https://zcode.z.ai',
    'X-Title': 'Z Code@electron',
    'X-ZCode-App-Version': appVersion,
    'X-Platform': platform,
    'X-Release-Channel': 'stable',
    'X-Client-Language': clientLanguage,
    'X-Client-Timezone': clientTimezone ?? 'unknown',
    'X-Os-Category': osCategory,
    if (osVersion != null && osVersion!.isNotEmpty) 'X-Os-Version': osVersion!,
    if (deviceMid != null && deviceMid!.isNotEmpty) 'X-Device-Mid': deviceMid!,
    'Authorization': 'Bearer $jwt',
    'x-request-id': _uuid.v4(),
  };

  /// bigmodel 直连头：Authorization 头 API key 原样，不带 Bearer。
  Map<String, String> bigmodelHeaders(String apiKey) => {
    'Authorization': apiKey,
    'User-Agent': 'ZCode/$appVersion',
    'x-request-id': _uuid.v4(),
  };

  /// 额度页通路 A 参数装载：取 `providerSettings.getView` 挑 entitle
  /// provider，带 `preferredProviderId + accountAccess`（P0-5 实测：仅
  /// `includeSubscription` 时宿主返回 `not_configured`）。
  ///
  /// 视图不可用 / 无 entitle provider → null（调用方降级为仅
  /// `includeSubscription`）。异常一律吞掉降级，不阻断额度拉取。
  Future<Map<String, dynamic>?> loadEntitlementParams() async {
    final provider = await _entitlementProvider();
    return provider == null ? null : entitlementParamsFor(provider);
  }

  /// 挑 entitle provider（额度/重置卡共用）：视图不可用 / 无候选 → null。
  Future<ZrProvider?> _entitlementProvider() async {
    try {
      final r = await bridge.call(
        'provider-settings',
        'getView',
        timeout: const Duration(seconds: 15),
      );
      final view = ProviderSettingsView.fromJson(r.firstObjectDeep ?? const {});
      return pickEntitlementProvider(view, null);
    } catch (e) {
      debugPrint('[quota] provider view degraded: $e');
      return null;
    }
  }

  /// 重置卡请求参数（宿主 `CodingPlanUsageRequest` 契约）：
  /// `range` + `preferredProviderId` + `accountAccess`。
  ///
  /// 宿主 `getCodingPlanUsageSnapshot` / `useCodingPlanReset` 要求
  /// `preferredProviderId` 指向 coding-plan provider 且带 `accountAccess`，
  /// 缺失会抛 `no_bigmodel_api_key`（实测「重置卡状态加载失败」根因）。
  /// 无 entitle provider / 未配置 → null，调用方按「不支持」处理。
  Future<Map<String, dynamic>?> _resetCardParams() async {
    final provider = await _entitlementProvider();
    if (provider == null) return null;
    final params = entitlementParamsFor(provider);
    final access = params['accountAccess'];
    return <String, dynamic>{
      'range': 'today',
      'preferredProviderId': params['preferredProviderId'],
      if (access is Map<String, dynamic>) 'accountAccess': access,
    };
  }

  /// 重置卡「不支持」错误族：方法缺失 / 无服务 / 无 coding-plan key /
  /// 未配置 / 无套餐。命中即隐藏区块，而不是展示「加载失败」。
  static bool _isUnsupportedResetError(String message) {
    return message.contains('no-method') ||
        message.contains('no-services') ||
        message.contains('no_bigmodel_api_key') ||
        message.contains('coding_plan_api_key_required') ||
        message.contains('not_configured') ||
        message.contains('no_plan');
  }

  /// 汇总拉取：通路 A（宿主快照）+ 通路 B（无 token 时优雅降级）。
  ///
  /// [entitlementParams] 由 [loadEntitlementParams] 提供；null 时仅带
  /// `includeSubscription`（无 providerSettings 的宿主/降级路径）。
  Future<QuotaOverview> fetch({Map<String, dynamic>? entitlementParams}) async {
    final parts = <QuotaOverview>[];
    final errors = <String>[];
    var sawNoPlan = false;
    var sawNotConfigured = false;

    try {
      final r = await bridge.call(
        'usage-stats',
        'getEntitlementSnapshot',
        params: entitlementParams ?? const {'includeSubscription': true},
      );
      final raw = r.firstObjectDeep ?? const <String, dynamic>{};
      final ent = UsageEntitlement.fromJson(raw);
      switch (classifyEntitlement(ent, raw: raw)) {
        case EntitlementSemantic.ok:
          final part = normalizeHostSnapshot(ent!);
          if (part != null) parts.add(part);
        case EntitlementSemantic.noPlan:
          sawNoPlan = true;
        case EntitlementSemantic.notConfigured:
          // 宿主未登录/未配置：成功回执但 quota 为 null，不算加载失败。
          sawNotConfigured = true;
        case EntitlementSemantic.unparseable:
          errors.add('host snapshot unparseable: ${r.debugText()}');
      }
    } on RpcRemoteException catch (e) {
      if (_isNoPlanMessage(e.message)) {
        sawNoPlan = true;
      } else {
        errors.add('usage-stats: ${e.message}');
      }
    } catch (e) {
      errors.add('usage-stats: $e');
    }

    final tokens = await _tokensOrNull();
    if (tokens != null) {
      final jwt = tokens.zaiJwt?.trim() ?? '';
      if (jwt.isNotEmpty) {
        try {
          final doc = await _getJson(
            '$kZaiBillingBalanceUrl?app_version=$appVersion',
            zaiBillingHeaders(jwt),
          );
          if (doc != null && quotaBusinessOk(doc)) {
            final part = normalizeZaiBalanceDoc(doc);
            final hasPlan =
                part?.plans.isNotEmpty == true ||
                part?.plans.any((p) => p.tier != null) == true;
            if (part != null && hasPlan) {
              parts.add(part);
            } else if (part != null) {
              sawNoPlan = true;
            }
          } else if (doc != null) {
            errors.add('billing/balance ${quotaBizErrorText(doc)}');
          }
        } catch (e) {
          errors.add('billing/balance: $e');
        }
      }
      final apiKey = tokens.bigmodelApiKey?.trim() ?? '';
      if (apiKey.isNotEmpty) {
        try {
          final doc = await _getJson(
            kBigmodelQuotaLimitUrl,
            bigmodelHeaders(apiKey),
          );
          if (doc != null && quotaBusinessOk(doc)) {
            final part = normalizeBigmodelLimitDoc(doc);
            if (part != null) parts.add(part);
          } else if (doc != null) {
            final text = quotaBizErrorText(doc);
            if (_isNoPlanMessage(text)) {
              sawNoPlan = true;
            } else {
              errors.add('quota/limit $text');
            }
          }
        } catch (e) {
          errors.add('quota/limit: $e');
        }
      }
    }

    if (parts.isEmpty) {
      if (sawNoPlan) {
        return QuotaOverview(
          plans: const [],
          items: const [],
          refreshedAt: DateTime.now(),
          sources: const [],
          noPlan: true,
        );
      }
      if (sawNotConfigured) {
        // 未配置/未登录空态：页面展示「登录后查看」引导，而非加载失败。
        return QuotaOverview(
          plans: const [],
          items: const [],
          refreshedAt: DateTime.now(),
          sources: const [],
          notConfigured: true,
        );
      }
      throw QuotaFetchException(
        errors.isEmpty ? 'quota fetch failed' : errors.join('; '),
      );
    }
    return mergeQuotaParts(parts);
  }

  /// 「不存在 coding plan / 没有资格」族消息视为无套餐（quota.rs is_no_plan_message）。
  static bool _isNoPlanMessage(String msg) =>
      msg.contains('不存在coding plan') ||
      msg.contains('没有资格') ||
      msg.contains('no_plan');

  Future<QuotaTokens?> _tokensOrNull() async {
    final provider = tokenProvider;
    if (provider == null) return null;
    try {
      final tokens = await provider();
      if (tokens == null || tokens.isEmpty) return null;
      return tokens;
    } catch (e) {
      debugPrint('[quota] token provider degraded: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getJson(
    String url,
    Map<String, String> headers,
  ) async {
    final resp = await _dio.get<Object?>(
      url,
      options: Options(headers: headers, responseType: ResponseType.json),
    );
    final data = resp.data;
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.trim().isEmpty) return null;
    if (data is String) {
      final decoded = jsonDecode(data);
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    return null;
  }

  // ---- 重置卡（P1-5）------------------------------------------------------

  /// 探测宿主重置卡是否可用：无 provider/未配置、no-method/no-services、
  /// 无 coding-plan key 一律视为**不支持**（UI 隐藏区块）；其余错误按
  /// 「方法在、状态加载失败」处理。
  Future<bool> resetCardSupported() async {
    final params = await _resetCardParams();
    if (params == null) return false;
    try {
      await bridge.call(
        'usage-stats',
        'getCodingPlanUsageSnapshot',
        params: params,
        timeout: const Duration(seconds: 6),
      );
      return true;
    } on RpcRemoteException catch (e) {
      return !_isUnsupportedResetError(e.message);
    } catch (_) {
      return false;
    }
  }

  /// 重置卡状态：可用数、过期时间、最近使用记录、has_unread_history。
  /// 无 provider/未配置 → [ResetCardUnsupportedException]（隐藏区块）；
  /// 真实网络/RPC 错误原样抛出（页面展示失败态可重试）。
  Future<ResetCardStatus> fetchResetCardStatus() async {
    final params = await _resetCardParams();
    if (params == null) {
      throw const ResetCardUnsupportedException('no entitle provider');
    }
    try {
      final r = await bridge.call(
        'usage-stats',
        'getCodingPlanUsageSnapshot',
        params: params,
        timeout: const Duration(seconds: 10),
      );
      return ResetCardStatus.fromJson(r.firstObjectDeep ?? const {});
    } on RpcRemoteException catch (e) {
      if (_isUnsupportedResetError(e.message)) {
        throw ResetCardUnsupportedException(e.message);
      }
      rethrow;
    }
  }

  /// 使用重置卡：请求形状按宿主契约 `CodingPlanResetUseRequest`
  /// （preferredProviderId + accountAccess + idempotencyKey + resetType）；
  /// 3301 限流带 next_try_at。
  Future<ResetCardUseResult> useResetCard(String resetType) async {
    final key = _uuid.v4();
    final params = await _resetCardParams();
    if (params == null) {
      return ResetCardUseResult.fromErrorText('no_bigmodel_api_key', key);
    }
    try {
      final r = await bridge.call(
        'usage-stats',
        'useCodingPlanReset',
        params: {
          ...params,
          'idempotencyKey': key,
          'resetType': resetType,
        },
        timeout: const Duration(seconds: 15),
      );
      return ResetCardUseResult.fromResponse(
        r.firstObjectDeep ?? const {},
        key,
      );
    } on RpcRemoteException catch (e) {
      return ResetCardUseResult.fromErrorText(e.message, key);
    }
  }
}
