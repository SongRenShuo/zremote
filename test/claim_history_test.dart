import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/services/claim_scheduler.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/state/claim_config.dart';
import 'package:zremote/state/claim_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late ClaimHistoryNotifier notifier;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    notifier = container.read(claimHistoryProvider.notifier);
    addTearDown(container.dispose);
  });

  ClaimRecord record(
    DateTime at, {
    String planId = 'plan-a',
    bool success = true,
    int? code,
    ClaimRecordSource source = ClaimRecordSource.auto,
  }) => ClaimRecord(
    at: at,
    planId: planId,
    planName: '周末体验包',
    success: success,
    code: code,
    source: source,
    benefitSummary: '300,000,000 Tokens',
  );

  group('P2-6 快照持久化三态', () {
    test('落盘：record → 磁盘往返一致（含 lastSyncedAt）', () async {
      notifier.record(
        'd1',
        planId: 'plan-a',
        planName: '周末体验包',
        success: true,
        source: ClaimRecordSource.auto,
        benefitSummary: '300,000,000 Tokens',
      );
      await notifier.lastSnapshotSave;

      final snapshot = await DeviceStore.instance.claimHistorySnapshot('d1');
      expect(snapshot, isNotNull);
      expect(snapshot!.records, hasLength(1));
      final r = snapshot.records.single;
      expect(r.planId, 'plan-a');
      expect(r.planName, '周末体验包');
      expect(r.success, isTrue);
      expect(r.source, ClaimRecordSource.auto);
      expect(r.benefitSummary, '300,000,000 Tokens');
      expect(snapshot.lastSyncedAt, isNotNull);
    });

    test('非空才落盘（反向验证）：零记录时磁盘键不存在', () async {
      // 什么都不记 → 没有任何落盘写入。
      expect(await DeviceStore.instance.claimHistorySnapshot('d1'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('zremote.claim.d1'), isFalse);
    });

    test('复位：forget 摘内存态，磁盘快照保留', () async {
      notifier.record('d1', planId: 'plan-a', success: true);
      await notifier.lastSnapshotSave;
      notifier.forget('d1');
      await notifier.lastSnapshotSave;

      expect(container.read(claimHistoryProvider).containsKey('d1'), isFalse);
      final snapshot = await DeviceStore.instance.claimHistorySnapshot('d1');
      expect(snapshot, isNotNull, reason: '复位不抹磁盘快照');
      expect(snapshot!.records.single.planId, 'plan-a');
    });

    test('恢复：restoreFromStore 空板拉快照；在线数据已到不覆盖', () async {
      final seed = ClaimHistoryBoard(
        records: [
          record(DateTime(2026, 11, 15, 9), planId: 'seed-plan'),
        ],
        lastSyncedAt: DateTime(2026, 11, 15, 9),
      );
      await DeviceStore.instance.saveClaimHistorySnapshot('d1', seed);

      await notifier.restoreFromStore('d1');
      await pumpEventQueue();
      var board = container.read(claimHistoryProvider)['d1']!;
      expect(board.records.single.planId, 'seed-plan');

      notifier.record('d1', planId: 'live-plan', success: true);
      board = container.read(claimHistoryProvider)['d1']!;
      expect(board.records.first.planId, 'live-plan');
      await notifier.restoreFromStore('d1');
      await pumpEventQueue();
      expect(
        container.read(claimHistoryProvider)['d1']!.records.first.planId,
        'live-plan',
        reason: '在线数据不被快照覆盖',
      );
    });

    test('裁尾：上限 50 条，新记录插头部', () async {
      notifier.record('d1', planId: 'first', success: true);
      for (var i = 0; i < ClaimHistoryBoard.maxRecords; i++) {
        notifier.record('d1', planId: 'p$i', success: true);
      }
      final board = container.read(claimHistoryProvider)['d1']!;
      expect(board.records.length, ClaimHistoryBoard.maxRecords);
      expect(board.records.first.planId, 'p${ClaimHistoryBoard.maxRecords - 1}');
      expect(
        board.records.any((r) => r.planId == 'first'),
        isFalse,
        reason: '最早一条被裁掉',
      );
    });

    test('坏 JSON → null 降级不抛；形状漂移丢条目不丢板', () async {
      SharedPreferences.setMockInitialValues({'zremote.claim.d1': 'not-json{'});
      expect(await DeviceStore.instance.claimHistorySnapshot('d1'), isNull);

      SharedPreferences.setMockInitialValues({
        'zremote.claim.d1': '{"records": [42, {"at": "x", "planId": "p"}, '
            '{"at": 1788570000000, "planId": "ok"}]}',
      });
      final board = await DeviceStore.instance.claimHistorySnapshot('d1');
      expect(board, isNotNull);
      expect(board!.records, hasLength(1));
      expect(board.records.single.planId, 'ok');
    });
  });

  group('今日计数（工具箱徽章）', () {
    test('只数当日成功；跨天/失败不计', () {
      final now = DateTime(2026, 11, 15, 15);
      final board = ClaimHistoryBoard(
        records: [
          record(now.subtract(const Duration(hours: 1)), planId: 'a'),
          record(now.subtract(const Duration(hours: 2)), planId: 'b'),
          record(now.subtract(const Duration(hours: 3)), planId: 'c',
              success: false, code: 1003),
          record(now.subtract(const Duration(days: 1)), planId: 'old'),
          record(now.subtract(const Duration(days: 2)), planId: 'older'),
        ],
      );
      expect(board.todayCount(now), 2);
    });
  });

  group('P2-5 配置持久化（zremote.claimConfig.<deviceId>）', () {
    test('默认：开关关 + 静默 23:00–08:00', () async {
      final config = await DeviceStore.instance.claimAutoConfig('d1');
      expect(config.enabled, isFalse);
      expect(config.silentStartMinutes, 23 * 60);
      expect(config.silentEndMinutes, 8 * 60);
      expect(config.silentEnabled, isTrue);
    });

    test('往返：改开关/静默时段 → 回读一致', () async {
      await DeviceStore.instance.saveClaimAutoConfig(
        'd1',
        const ClaimAutoConfig(
          enabled: true,
          silentStartMinutes: 0,
          silentEndMinutes: 6 * 60,
        ),
      );
      final config = await DeviceStore.instance.claimAutoConfig('d1');
      expect(config.enabled, isTrue);
      expect(config.silentStartMinutes, 0);
      expect(config.silentEndMinutes, 6 * 60);
    });

    test('容错（M5）：部分字段/坏 JSON → 缺省回落不抛', () async {
      SharedPreferences.setMockInitialValues({
        'zremote.claimConfig.d1': '{"enabled": true}',
      });
      var config = await DeviceStore.instance.claimAutoConfig('d1');
      expect(config.enabled, isTrue);
      expect(config.silentStartMinutes, 23 * 60, reason: '缺失回落默认');

      SharedPreferences.setMockInitialValues({
        'zremote.claimConfig.d1': '{"enabled": "yes", "silentStart": -40, '
            '"silentEnd": 99999}',
      });
      config = await DeviceStore.instance.claimAutoConfig('d1');
      expect(config.enabled, isFalse, reason: '类型漂移回落默认关');
      expect(config.silentStartMinutes, 0, reason: '负值钳到 0');
      expect(config.silentEndMinutes, 24 * 60 - 1, reason: '超界钳到 23:59');
    });

    test('ClaimConfigNotifier：开关与静默写入 provider + 落盘', () async {
      final configNotifier = container.read(claimConfigProvider.notifier);
      await configNotifier.load('d1');
      expect(
        container.read(claimConfigProvider)['d1'],
        const ClaimAutoConfig(),
      );

      await configNotifier.setEnabled('d1', true);
      expect(container.read(claimConfigProvider)['d1']!.enabled, isTrue);
      await configNotifier.setSilent('d1', 0, 6 * 60);
      expect(
        container.read(claimConfigProvider)['d1'],
        const ClaimAutoConfig(
          enabled: true,
          silentStartMinutes: 0,
          silentEndMinutes: 6 * 60,
        ),
      );
      final stored = await DeviceStore.instance.claimAutoConfig('d1');
      expect(stored.enabled, isTrue);
      expect(stored.silentEndMinutes, 6 * 60);
    });
  });
}
