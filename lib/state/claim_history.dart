import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/claim_scheduler.dart';
import '../services/device_store.dart';

/// 领取记录来源。
enum ClaimRecordSource { auto, manual }

ClaimRecordSource claimRecordSourceOf(String name) =>
    ClaimRecordSource.values.firstWhere(
      (s) => s.name == name,
      orElse: () => ClaimRecordSource.manual,
    );

/// 阻断记录的原因解析（20261116-2341 D1）：未知名/缺失返回 null。
ClaimBlockedReason? claimBlockedReasonOf(String? name) {
  if (name == null) return null;
  for (final r in ClaimBlockedReason.values) {
    if (r.name == name) return r;
  }
  return null;
}

/// 单次领取记录（时间/套餐/结果码/结果文案/来源/权益摘要）。
/// 阻断记录（blockedReason 非 null）没有 planId/planName，只有原因与详情。
class ClaimRecord {
  const ClaimRecord({
    required this.at,
    this.planId = '',
    this.planName = '',
    this.success = false,
    this.code,
    this.message = '',
    this.source = ClaimRecordSource.manual,
    this.benefitSummary = '',
    this.blockedReason,
  });

  final DateTime at;

  final String planId;

  final String planName;

  final bool success;

  /// 业务结果码（1001-1005/3001/3007/401；网络异常为 null）。
  final int? code;

  final String message;

  final ClaimRecordSource source;

  /// 权益摘要（如 "300,000,000 Tokens"），locale 无关的纯数字格式。
  final String benefitSummary;

  /// 阻断原因（自动轮没有产生领取动作时的记录，20261116-2341 D1）。
  /// 非 null 即阻断记录：时间线渲染为阻断样式而非失败样式。
  final ClaimBlockedReason? blockedReason;

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'planId': planId,
    if (planName.isNotEmpty) 'planName': planName,
    'success': success,
    if (code != null) 'code': code,
    if (message.isNotEmpty) 'message': message,
    'source': source.name,
    if (benefitSummary.isNotEmpty) 'benefitSummary': benefitSummary,
    if (blockedReason != null) 'blockedReason': blockedReason!.name,
  };

  /// 容错解析：关键键（at/planId）缺失或类型漂移丢条目，其余字段降级（M5）。
  /// 阻断记录无 planId，凭 blockedReason 形似保留；两者皆缺则丢条目。
  static ClaimRecord? fromJson(Map<String, dynamic> j) {
    final at = j['at'];
    if (at is! num) return null;
    final blockedReason = claimBlockedReasonOf(
      j['blockedReason'] as String?,
    );
    final planIdRaw = j['planId'];
    final planId = planIdRaw is String ? planIdRaw : '';
    if (planId.isEmpty && blockedReason == null) return null;
    return ClaimRecord(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      planId: planId,
      planName: j['planName'] is String ? j['planName'] as String : '',
      success: j['success'] == true,
      code: j['code'] is num ? (j['code'] as num).toInt() : null,
      message: j['message'] is String ? j['message'] as String : '',
      source: j['source'] is String
          ? claimRecordSourceOf(j['source'] as String)
          : ClaimRecordSource.manual,
      benefitSummary: j['benefitSummary'] is String
          ? j['benefitSummary'] as String
          : '',
      blockedReason: blockedReason,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ClaimRecord &&
      other.at == at &&
      other.planId == planId &&
      other.planName == planName &&
      other.success == success &&
      other.code == code &&
      other.message == message &&
      other.source == source &&
      other.benefitSummary == benefitSummary &&
      other.blockedReason == blockedReason;

  @override
  int get hashCode => Object.hashAll([
    at,
    planId,
    planName,
    success,
    code,
    message,
    source,
    benefitSummary,
    blockedReason,
  ]);
}

/// 每设备领取历史板（快照持久化 + 最后同步时间）。
class ClaimHistoryBoard {
  const ClaimHistoryBoard({this.records = const [], this.lastSyncedAt});

  /// 最多保留条数（新记录插头部，超出裁尾）。
  static const int maxRecords = 50;

  final List<ClaimRecord> records;

  /// 最近一次写入记录的时间（离线时历史 Tab 展示最后同步）。
  final DateTime? lastSyncedAt;

  /// 有可持久化的数据（空板不落盘，避免重载清空把快照抹掉）。
  bool get hasData => records.isNotEmpty;

  /// 当日成功领取数（工具箱徽章「今日已领 N」）。
  int todayCount(DateTime now) => records
      .where(
        (r) =>
            r.success &&
            r.at.year == now.year &&
            r.at.month == now.month &&
            r.at.day == now.day,
      )
      .length;

  Map<String, dynamic> toSnapshotJson() => {
    'records': [for (final r in records) r.toJson()],
    if (lastSyncedAt != null)
      'lastSyncedAt': lastSyncedAt!.millisecondsSinceEpoch,
  };

  static ClaimHistoryBoard? fromSnapshotJson(dynamic raw) {
    if (raw is! Map) return null;
    final board = ClaimHistoryBoard(
      records: [
        for (final r in (raw['records'] as List? ?? const []))
          if (r is Map<String, dynamic>) ?ClaimRecord.fromJson(r),
      ],
      lastSyncedAt: raw['lastSyncedAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(raw['lastSyncedAt'] as int)
          : null,
    );
    return board.hasData ? board : null;
  }

  ClaimHistoryBoard copyWith({
    List<ClaimRecord>? records,
    DateTime? lastSyncedAt,
  }) => ClaimHistoryBoard(
    records: records ?? this.records,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is ClaimHistoryBoard &&
      listEquals(other.records, records) &&
      other.lastSyncedAt == lastSyncedAt;

  @override
  int get hashCode => Object.hash(Object.hashAll(records), lastSyncedAt);
}

/// 领取历史状态（P2-6）：非空才落盘（参照 automation 快照模式 P3-4 先例）。
class ClaimHistoryNotifier extends Notifier<Map<String, ClaimHistoryBoard>> {
  @override
  Map<String, ClaimHistoryBoard> build() => const {};

  ClaimHistoryBoard _boardOf(String deviceId) =>
      state[deviceId] ?? const ClaimHistoryBoard();

  Future<void>? _lastSave;

  /// 最近一次快照落盘的 future（测试用；生产侧 fire-and-forget）。
  @visibleForTesting
  Future<void> get lastSnapshotSave => _lastSave ?? Future<void>.value();

  void _put(String deviceId, ClaimHistoryBoard board) {
    if (state[deviceId] == board) return;
    state = {...state, deviceId: board};
    // P2-6：非空板落盘（复位不落盘，保留最后快照）。
    // 串行链式写入：保证最终落盘内容是最新板，不受通道完成顺序影响。
    if (board.hasData) {
      final previous = _lastSave ?? Future<void>.value();
      _lastSave = previous
          .then(
            (_) => DeviceStore.instance.saveClaimHistorySnapshot(
              deviceId,
              board,
            ),
          )
          .catchError((Object e) {
        debugPrint('[claim-history] snapshot save failed: $e');
        return;
      });
      unawaited(_lastSave);
    }
  }

  /// 页面打开时恢复上次快照（离线/断连后历史仍可查看）。
  /// 在线数据已到达（hasData）时不覆盖。
  Future<void> restoreFromStore(String deviceId) async {
    try {
      if (_boardOf(deviceId).hasData) return;
      final snapshot = await DeviceStore.instance.claimHistorySnapshot(
        deviceId,
      );
      if (snapshot == null) return;
      if (_boardOf(deviceId).hasData) return;
      _put(deviceId, snapshot);
    } catch (e) {
      debugPrint('[claim-history] snapshot restore failed: $e');
    }
  }

  /// 记一条领取结果（手动/自动共用入口），插头部、裁尾至 50 条。
  /// 阻断记录（blockedReason 非 null）无 planId，见 [ClaimRecord]。
  void record(
    String deviceId, {
    String planId = '',
    String planName = '',
    required bool success,
    int? code,
    String message = '',
    ClaimRecordSource source = ClaimRecordSource.manual,
    String benefitSummary = '',
    ClaimBlockedReason? blockedReason,
  }) {
    final board = _boardOf(deviceId);
    final entry = ClaimRecord(
      at: DateTime.now(),
      planId: planId,
      planName: planName,
      success: success,
      code: code,
      message: message,
      source: source,
      benefitSummary: benefitSummary,
      blockedReason: blockedReason,
    );
    final records = [entry, ...board.records];
    if (records.length > ClaimHistoryBoard.maxRecords) {
      records.removeRange(
        ClaimHistoryBoard.maxRecords,
        records.length,
      );
    }
    _put(
      deviceId,
      board.copyWith(records: records, lastSyncedAt: DateTime.now()),
    );
  }

  /// 设备移除/会话复位：摘除内存态（磁盘快照保留，供重新导入后回看）。
  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final claimHistoryProvider =
    NotifierProvider<ClaimHistoryNotifier, Map<String, ClaimHistoryBoard>>(
      ClaimHistoryNotifier.new,
    );
