import 'dart:convert';

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

    test('阻断记录（blockedReason，无 planId）：落盘往返保留（20261116-2341）',
        () async {
      notifier.record(
        'd1',
        success: false,
        source: ClaimRecordSource.auto,
        blockedReason: ClaimBlockedReason.activityClosed,
        message: 'detail-x',
      );
      await notifier.lastSnapshotSave;
      final saved = await DeviceStore.instance.claimHistorySnapshot('d1');
      expect(saved, isNotNull);
      expect(saved!.records, hasLength(1));
      final r = saved.records.single;
      expect(r.blockedReason, ClaimBlockedReason.activityClosed);
      expect(r.message, 'detail-x');
      expect(r.planId, isEmpty);
      expect(r.source, ClaimRecordSource.auto);
      expect(r.success, isFalse);

      // 形状漂移（M5）：blockedReason 未知名 + 空 planId → 丢条目不抛。
      SharedPreferences.setMockInitialValues({
        'zremote.claim.d1': '{"records": ['
            '{"at": 1788570000000, "blockedReason": "unknown-x"}, '
            '{"at": 1788570000000, "blockedReason": "noPlans"}]}',
      });
      final board = await DeviceStore.instance.claimHistorySnapshot('d1');
      expect(board!.records, hasLength(1));
      expect(board.records.single.blockedReason, ClaimBlockedReason.noPlans);
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
          locallyOverridden: true,
        ),
        reason: 'setEnabled 打独立标记（20261117-1230 R1）',
      );
      final stored = await DeviceStore.instance.claimAutoConfig('d1');
      expect(stored.enabled, isTrue);
      expect(stored.silentEndMinutes, 6 * 60);
    });

    test('全局总闸（zremote.claimGlobal）：默认开 + 往返 + 脏值回落开（M5）',
        () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await DeviceStore.instance.claimGlobalEnabled(),
        isTrue,
        reason: '无键 → 默认开（升级零回归）',
      );

      await DeviceStore.instance.saveClaimGlobalEnabled(false);
      expect(await DeviceStore.instance.claimGlobalEnabled(), isFalse);

      SharedPreferences.setMockInitialValues({
        'zremote.claimGlobal': 'garbage',
      });
      expect(
        await DeviceStore.instance.claimGlobalEnabled(),
        isTrue,
        reason: '脏值 → 回落开',
      );
    });

    test('ClaimGlobalEnabledNotifier：setEnabled 即时态 + 落盘 + load 回读',
        () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(claimGlobalEnabledProvider.notifier);
      expect(container.read(claimGlobalEnabledProvider), isTrue);

      await notifier.setEnabled(false);
      expect(container.read(claimGlobalEnabledProvider), isFalse);
      await notifier.lastSave;
      expect(await DeviceStore.instance.claimGlobalEnabled(), isFalse);

      // 新容器模拟重启：load 读盘回读 false。
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final notifier2 = container2.read(claimGlobalEnabledProvider.notifier);
      await notifier2.load();
      expect(container2.read(claimGlobalEnabledProvider), isFalse);
    });

    test('一键批量：仅覆盖未独立设置的设备（locallyOverridden 反向验证）',
        () async {
      SharedPreferences.setMockInitialValues({
        'zremote.claimConfig.d-follow': jsonEncode(
          const ClaimAutoConfig(enabled: true).toJson(),
        ),
        'zremote.claimConfig.d-indep': jsonEncode(
          const ClaimAutoConfig(
            enabled: true,
            locallyOverridden: true,
          ).toJson(),
        ),
      });
      final changed = await DeviceStore.instance.applyGlobalClaimDefault(
        false,
        deviceIds: ['d-follow', 'd-indep'],
      );
      expect(changed, ['d-follow'], reason: '仅未独立设置的设备被改写');

      final follow = await DeviceStore.instance.claimAutoConfig('d-follow');
      expect(follow.enabled, isFalse, reason: '跟随设备被一键关');
      expect(follow.locallyOverridden, isFalse);

      final indep = await DeviceStore.instance.claimAutoConfig('d-indep');
      expect(indep.enabled, isTrue, reason: '独立设备不被覆盖');
      expect(indep.locallyOverridden, isTrue);

      expect(await DeviceStore.instance.claimGlobalEnabled(), isFalse);
    });

    test('设备页 setEnabled 打独立标记；setSilent 不打标', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final cfg = c.read(claimConfigProvider.notifier);
      await cfg.load('d1');
      await cfg.setEnabled('d1', true);
      expect(
        c.read(claimConfigProvider)['d1']!.locallyOverridden,
        isTrue,
        reason: '设备单独切开关 → 打标',
      );

      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      final cfg2 = c2.read(claimConfigProvider.notifier);
      await cfg2.load('d2');
      await cfg2.setSilent('d2', 0, 360);
      expect(
        c2.read(claimConfigProvider)['d2']!.locallyOverridden,
        isFalse,
        reason: '仅改静默时段不视为独立覆盖',
      );
    });

    test('新设备继承全局默认值；已有配置不被覆盖', () async {
      SharedPreferences.setMockInitialValues({});
      await DeviceStore.instance.saveClaimGlobalEnabled(false);

      await DeviceStore.instance.initClaimConfigForNewDevice('new-1');
      final inherited = await DeviceStore.instance.claimAutoConfig('new-1');
      expect(inherited.enabled, isFalse, reason: '继承全局默认关');
      expect(inherited.locallyOverridden, isFalse);

      // 已有配置（且独立设置过）不被覆盖。
      await DeviceStore.instance.saveClaimAutoConfig(
        'new-1',
        const ClaimAutoConfig(enabled: true, locallyOverridden: true),
      );
      await DeviceStore.instance.saveClaimGlobalEnabled(true);
      await DeviceStore.instance.initClaimConfigForNewDevice('new-1');
      final kept = await DeviceStore.instance.claimAutoConfig('new-1');
      expect(kept.enabled, isTrue, reason: '已有配置不被初始化覆盖');
      expect(kept.locallyOverridden, isTrue);
    });
  });
}
