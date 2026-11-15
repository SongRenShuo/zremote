import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/models/notification_prefs.dart';
import 'package:zremote/services/notifier.dart';
import 'package:zremote/services/quota_alert.dart';
import 'package:zremote/services/quota_client.dart';
import 'package:zremote/services/task_actions.dart';
import 'package:zremote/state/notification_prefs.dart';
import 'package:zremote/state/quota_alert.dart';

RemoteDevice _device(String id) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {'sid': 's', 'hash': 'h'},
  label: '',
  createdAt: DateTime(2026, 1, 1),
);

/// 单槽总览：主槽 percentUsed=percent，remaining 独立可配。
QuotaOverview _overview(
  double? percent, {
  double? remaining,
  bool noPlan = false,
  bool notConfigured = false,
  List<PlanSlot>? plans,
}) {
  final slot = PlanSlot(
    pid: 'coding-max',
    tierCode: QuotaTierCode.max,
    tier: 'Max',
    name: 'GLM Coding Max',
    total: 100,
    used: percent,
    remaining: remaining ?? (percent == null ? null : 100 - percent),
    percentUsed: percent,
    items: const [],
  );
  return QuotaOverview(
    plans: plans ?? [slot],
    items: const [],
    refreshedAt: DateTime(2026, 11, 15),
    sources: const ['host-snapshot'],
    percentUsed: percent,
    remaining: remaining,
    noPlan: noPlan,
    notConfigured: notConfigured,
  );
}

QuotaAlertSnapshot _snapshot(double percent, {double? remaining}) =>
    QuotaAlertSnapshot(
      percentUsed: percent,
      remainingPercent: (100 - percent).clamp(0, 100).toDouble(),
      remaining: remaining,
      planName: 'GLM Coding Max',
      resetKey: 'coding-max',
      resetText: '11-20 08:00',
    );

DateTime _now() => DateTime(2026, 11, 15, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('判据与降级（快照提取）', () {
    test('未配置 / 无套餐 / 无 percentUsed / 无主槽 → 不可判定', () {
      expect(QuotaAlertEvaluator.snapshotOf(_overview(50, notConfigured: true)), isNull);
      expect(QuotaAlertEvaluator.snapshotOf(_overview(50, noPlan: true)), isNull);
      expect(QuotaAlertEvaluator.snapshotOf(_overview(null)), isNull);
      expect(
        QuotaAlertEvaluator.snapshotOf(
          _overview(50, plans: const []),
        ),
        isNull,
      );
    });

    test('耗尽固定档优先：percentUsed≥100 或 remaining≤0', () {
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(100), threshold: 80),
        QuotaAlertLevel.critical,
      );
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(120), threshold: 80),
        QuotaAlertLevel.critical,
      );
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(50, remaining: 0), threshold: 80),
        QuotaAlertLevel.critical,
      );
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(50, remaining: -3), threshold: 80),
        QuotaAlertLevel.critical,
      );
    });
  });

  group('阈值矩阵（默认 80）', () {
    test('79 → none；80 → warn；90/95/99.9 → warn', () {
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(79.9), threshold: 80),
        QuotaAlertLevel.none,
      );
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(80), threshold: 80),
        QuotaAlertLevel.warn,
      );
      for (final p in [90.0, 95.0, 99.9]) {
        expect(
          QuotaAlertEvaluator.levelOf(_snapshot(p), threshold: 80),
          QuotaAlertLevel.warn,
        );
      }
    });

    test('自定义阈值 70：69 → none，70 → warn', () {
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(69), threshold: 70),
        QuotaAlertLevel.none,
      );
      expect(
        QuotaAlertEvaluator.levelOf(_snapshot(70), threshold: 70),
        QuotaAlertLevel.warn,
      );
    });
  });

  group('迟滞与去重', () {
    test('首报 85 → 通知并落水位；同档 86/89 → 抑制；90（+5）→ 通知', () {
      final first = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(85),
        threshold: 80,
        now: _now(),
      );
      expect(first.notify, isTrue);
      expect(first.level, QuotaAlertLevel.warn);
      expect(first.waterLevel?.percent, 85);

      final second = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(86),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 1)),
      );
      expect(second.notify, isFalse);

      final third = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(89.9),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 2)),
      );
      expect(third.notify, isFalse);

      final fourth = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(90),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 3)),
      );
      expect(fourth.notify, isTrue);
      expect(fourth.waterLevel?.percent, 90);
    });

    test('同档 6h 后重复提醒', () {
      final first = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(85),
        threshold: 80,
        now: _now(),
      );
      final later = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(85),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(hours: 6)),
      );
      expect(later.notify, isTrue);
      expect(
        later.waterLevel?.alertAtMs,
        _now().add(const Duration(hours: 6)).millisecondsSinceEpoch,
      );
    });

    test('升级立即通知（warn→critical 不等 5 点/6h）', () {
      final warn = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(82),
        threshold: 80,
        now: _now(),
      );
      final critical = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(100),
        threshold: 80,
        previous: warn.waterLevel,
        now: _now().add(const Duration(seconds: 30)),
      );
      expect(critical.notify, isTrue);
      expect(critical.level, QuotaAlertLevel.critical);
    });

    test('降级静默更新基线（critical→warn 不通知）', () {
      final critical = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(100),
        threshold: 80,
        now: _now(),
      );
      final warn = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(96),
        threshold: 80,
        previous: critical.waterLevel,
        now: _now().add(const Duration(minutes: 1)),
      );
      expect(warn.notify, isFalse);
      expect(warn.waterLevel?.level, QuotaAlertLevel.warn);
      expect(warn.waterLevel?.percent, 96);
    });

    test('resetKey 变更 → 新周期立即通知', () {
      final first = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(85),
        threshold: 80,
        now: _now(),
      );
      final nextCycle = QuotaAlertEvaluator.evaluate(
        snapshot: QuotaAlertSnapshot(
          percentUsed: 85,
          remainingPercent: 15,
          planName: 'GLM Coding Max',
          resetKey: 'coding-max|1763300000000',
        ),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 1)),
      );
      expect(nextCycle.notify, isTrue);
      expect(nextCycle.waterLevel?.resetKey, contains('1763300000000'));
    });

    test('迟滞清零：跌回阈值-5 以下清空；未跌破则保留', () {
      final first = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(85),
        threshold: 80,
        now: _now(),
      );
      final keep = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(78),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 1)),
      );
      expect(keep.clear, isFalse);
      expect(keep.notify, isFalse);

      final clear = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(74.9),
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 2)),
      );
      expect(clear.clear, isTrue);

      // 清零后再次越线 → 立即通知（重新武装）。
      final rearm = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(81),
        threshold: 80,
        now: _now().add(const Duration(minutes: 3)),
      );
      expect(rearm.notify, isTrue);
    });

    test('降级不清水位（不可判定维持既有水位）', () {
      final first = QuotaAlertEvaluator.evaluate(
        snapshot: _snapshot(85),
        threshold: 80,
        now: _now(),
      );
      final degraded = QuotaAlertEvaluator.evaluate(
        snapshot: null,
        threshold: 80,
        previous: first.waterLevel,
        now: _now().add(const Duration(minutes: 1)),
      );
      expect(degraded.notify, isFalse);
      expect(degraded.clear, isFalse);
      expect(degraded.waterLevel, isNull);
    });
  });

  group('水位持久化形状（M5 容错）', () {
    test('JSON 往返', () {
      final level = QuotaAlertWaterLevel(
        level: QuotaAlertLevel.warn,
        percent: 85,
        alertAtMs: 1762000000000,
        resetKey: 'coding-max',
      );
      final parsed = QuotaAlertWaterLevel.fromJson(level.toJson());
      expect(parsed, level);
    });

    test('脏值回落 null：缺键/类型漂移/空 resetKey', () {
      expect(QuotaAlertWaterLevel.fromJson({'level': 'warn'}), isNull);
      expect(
        QuotaAlertWaterLevel.fromJson({
          'level': 'warn',
          'percent': 'x',
          'alertAtMs': 1,
          'resetKey': 'k',
        }),
        isNull,
      );
      expect(
        QuotaAlertWaterLevel.fromJson({
          'level': 'warn',
          'percent': 80,
          'alertAtMs': 1,
          'resetKey': '',
        }),
        isNull,
      );
      expect(
        QuotaAlertWaterLevel.fromJson({'level': 'other'}),
        isNull,
      );
    });
  });

  group('通知 spec 与 payload', () {
    test('warn：zr_quota 通道 + quota: payload + 去领取 action', () {
      final spec = NotificationSpec.quotaLow(
        device: _device('dev-1'),
        level: QuotaAlertLevel.warn,
        snapshot: _snapshot(85),
        claimAutoEnabled: false,
      );
      expect(spec.channelId, 'zr_quota');
      expect(spec.payload, 'quota:dev-1');
      expect(spec.actions, hasLength(1));
      expect(spec.actions.single.id, TaskActionsClient.actionClaim);
      expect(spec.importance, Importance.defaultImportance);
      expect(spec.title, contains('85%'));
      expect(spec.body, contains('GLM Coding Max'));
      expect(spec.body, contains('15%'));
    });

    test('critical：high importance + 按 claimConfig 分支文案', () {
      final auto = NotificationSpec.quotaLow(
        device: _device('dev-1'),
        level: QuotaAlertLevel.critical,
        snapshot: _snapshot(100),
        claimAutoEnabled: true,
      );
      expect(auto.importance, Importance.high);
      expect(auto.body, '自动领取未成功，需人工领取');
      expect(auto.payload, 'quota:dev-1');

      final manual = NotificationSpec.quotaLow(
        device: _device('dev-1'),
        level: QuotaAlertLevel.critical,
        snapshot: _snapshot(100),
        claimAutoEnabled: false,
      );
      expect(manual.body, contains('去领取'));
      expect(manual.body, contains('11-20 08:00'));
    });

    test('payload 解析：quota: 前缀 → quota 标记 + 设备 id', () {
      final target = NotificationPayload.parse('quota:dev-9')!;
      expect(target.quota, isTrue);
      expect(target.deviceId, 'dev-9');
      expect(target.claim, isFalse);
      expect(TaskActionsClient.parseQuotaPayload('quota:'), isNull);
      expect(TaskActionsClient.parseQuotaPayload('dev-9'), isNull);
    });
  });

  group('gate 矩阵（quotaLow × DND × override）', () {
    const dnd = NotificationPrefs(
      quotaLow: true,
      dndStartMinutes: 23 * 60,
      dndEndMinutes: 8 * 60,
    );

    test('开关关 → 一律不报', () {
      expect(
        NotificationGatePolicy.allows(
          prefs: const NotificationPrefs(quotaLow: false),
          deviceParams: const {},
          category: ZrNotifyCategory.quotaLow,
          minuteOfDay: 12 * 60,
        ),
        isFalse,
      );
    });

    test('DND 窗口内拦截（quotaLow 非审批高优）', () {
      expect(
        NotificationGatePolicy.allows(
          prefs: dnd,
          deviceParams: const {},
          category: ZrNotifyCategory.quotaLow,
          minuteOfDay: 3 * 60,
        ),
        isFalse,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: dnd,
          deviceParams: const {},
          category: ZrNotifyCategory.quotaLow,
          minuteOfDay: 12 * 60,
        ),
        isTrue,
      );
    });

    test('override=off 静音；on 豁免类型开关但不豁免 DND', () {
      expect(
        NotificationGatePolicy.allows(
          prefs: const NotificationPrefs(quotaLow: true),
          deviceParams: const {'notifyOverride': 'off'},
          category: ZrNotifyCategory.quotaLow,
          minuteOfDay: 12 * 60,
        ),
        isFalse,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: const NotificationPrefs(quotaLow: false),
          deviceParams: const {'notifyOverride': 'on'},
          category: ZrNotifyCategory.quotaLow,
          minuteOfDay: 12 * 60,
        ),
        isTrue,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: dnd,
          deviceParams: const {'notifyOverride': 'on'},
          category: ZrNotifyCategory.quotaLow,
          minuteOfDay: 3 * 60,
        ),
        isFalse,
      );
    });
  });

  group('QuotaAlertNotifier.evaluateDevice', () {
    test('开关关 → 不评估、不落水位', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          notificationPrefsProvider.overrideWith(
            () => _FixedPrefsNotifier(
              const NotificationPrefs(quotaLow: false),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(notificationPrefsProvider).quotaLow, isFalse);
      final result = await container
          .read(quotaAlertProvider.notifier)
          .evaluateDevice(_device('d1'), _overview(95));
      expect(result.notify, isFalse);
      expect(container.read(quotaAlertProvider), isEmpty);
    });

    test('开关开 + 越线 → 落水位；迟滞抑制第二次', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          notificationPrefsProvider.overrideWith(
            () => _FixedPrefsNotifier(
              const NotificationPrefs(quotaLow: true, quotaAlertThreshold: 80),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(notificationPrefsProvider).quotaLow, isTrue);
      final notifier = container.read(quotaAlertProvider.notifier);
      final first = await notifier.evaluateDevice(
        _device('d1'),
        _overview(85),
        now: _now(),
      );
      expect(first.notify, isTrue);
      expect(container.read(quotaAlertProvider).containsKey('d1'), isTrue);

      final second = await notifier.evaluateDevice(
        _device('d1'),
        _overview(86),
        now: _now().add(const Duration(minutes: 1)),
      );
      expect(second.notify, isFalse, reason: '同档未涨 5 点且未到 6h');
    });
  });

  group('QuotaAlertWatcher', () {
    test('无设备时 sweep 直接返回（不触 RPC）', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          notificationPrefsProvider.overrideWith(
            () => _FixedPrefsNotifier(
              const NotificationPrefs(quotaLow: true),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(quotaAlertWatcherProvider.notifier).sweep();
      expect(container.read(quotaAlertWatcherProvider), isFalse);
    });
  });
}

/// 固定开关状态的 prefs Notifier（规避 DeviceStore 异步加载时序）。
class _FixedPrefsNotifier extends NotificationPrefsNotifier {
  _FixedPrefsNotifier(this.value);

  final NotificationPrefs value;

  @override
  NotificationPrefs build() => value;
}
