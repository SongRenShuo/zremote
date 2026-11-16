import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/background_heartbeat.dart';
import 'package:zremote/services/notified_event_store.dart';

void main() {
  group('D1 后台心跳策略', () {
    test('后台态识别：paused/hidden/detached 是后台，resumed 不是', () {
      expect(BackgroundHeartbeatPolicy.isBackgrounded(AppLifecycleState.paused),
          isTrue);
      expect(BackgroundHeartbeatPolicy.isBackgrounded(AppLifecycleState.hidden),
          isTrue);
      expect(
          BackgroundHeartbeatPolicy.isBackgrounded(AppLifecycleState.detached),
          isTrue);
      expect(
          BackgroundHeartbeatPolicy.isBackgrounded(AppLifecycleState.resumed),
          isFalse);
    });

    test('shouldTick 判据：四项全满足才 true（反向验证缺一即 false）', () {
      final base = (
        keepAliveEnabled: true,
        hasDevices: true,
        lifecycle: AppLifecycleState.paused,
        sinceLastTick: BackgroundHeartbeatPolicy.interval,
      );
      expect(
        BackgroundHeartbeatPolicy.shouldTick(
          keepAliveEnabled: base.keepAliveEnabled,
          hasDevices: base.hasDevices,
          lifecycle: base.lifecycle,
          sinceLastTick: base.sinceLastTick,
        ),
        isTrue,
      );
      // 反向：关保活 / 无设备 / 前台 / 未到周期 —— 任一不满足都不唤醒。
      expect(
        BackgroundHeartbeatPolicy.shouldTick(
          keepAliveEnabled: false,
          hasDevices: base.hasDevices,
          lifecycle: base.lifecycle,
          sinceLastTick: base.sinceLastTick,
        ),
        isFalse,
      );
      expect(
        BackgroundHeartbeatPolicy.shouldTick(
          keepAliveEnabled: base.keepAliveEnabled,
          hasDevices: false,
          lifecycle: base.lifecycle,
          sinceLastTick: base.sinceLastTick,
        ),
        isFalse,
      );
      expect(
        BackgroundHeartbeatPolicy.shouldTick(
          keepAliveEnabled: base.keepAliveEnabled,
          hasDevices: base.hasDevices,
          lifecycle: AppLifecycleState.resumed,
          sinceLastTick: base.sinceLastTick,
        ),
        isFalse,
      );
      expect(
        BackgroundHeartbeatPolicy.shouldTick(
          keepAliveEnabled: base.keepAliveEnabled,
          hasDevices: base.hasDevices,
          lifecycle: base.lifecycle,
          sinceLastTick:
              BackgroundHeartbeatPolicy.interval - const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('BackgroundHeartbeat：首拍即触发，周期内不重复，回前台重置', () {
      var now = DateTime(2026, 11, 16, 12, 0);
      final hb = BackgroundHeartbeat(now: () => now);
      bool consider() => hb.consider(
            keepAliveEnabled: true,
            hasDevices: true,
            lifecycle: AppLifecycleState.paused,
          );

      expect(consider(), isTrue, reason: '首拍应触发');
      expect(consider(), isFalse, reason: '同一时刻不应重复');
      now = now.add(BackgroundHeartbeatPolicy.interval);
      expect(consider(), isTrue, reason: '到周期应再触发');

      hb.resetOnForeground(AppLifecycleState.resumed);
      expect(consider(), isTrue, reason: '回前台重置后首拍应再触发');
    });
  });

  group('D3 完成事件去重', () {
    test('窗口期内同键只放行一次，过期后再次放行', () {
      var now = DateTime(2026, 11, 16, 12, 0);
      final tracker = NotifiedEventTracker(now: () => now);
      const key = 'dev1:completed:t1';

      expect(tracker.shouldNotify(key), isTrue);
      expect(tracker.shouldNotify(key), isFalse, reason: '窗口内重复应抑制');
      now = now.add(NotifiedEventDeduplicator.window +
          const Duration(seconds: 1));
      expect(tracker.shouldNotify(key), isTrue, reason: '过期后应再放行');
    });

    test('不同设备/类型/任务互不干扰', () {
      var now = DateTime(2026, 11, 16, 12, 0);
      final tracker = NotifiedEventTracker(now: () => now);
      expect(
          tracker.shouldNotify(
              NotifiedEventDeduplicator.keyOf('d1', 'completed', 't1')),
          isTrue);
      expect(
          tracker.shouldNotify(
              NotifiedEventDeduplicator.keyOf('d2', 'completed', 't1')),
          isTrue,
          reason: '不同设备独立');
      expect(
          tracker.shouldNotify(
              NotifiedEventDeduplicator.keyOf('d1', 'error', 't1')),
          isTrue,
          reason: '不同类型独立');
      expect(
          tracker.shouldNotify(
              NotifiedEventDeduplicator.keyOf('d1', 'completed', 't2')),
          isTrue,
          reason: '不同任务独立');
    });

    test('snapshot/restore 往返保序（持久化去重账可恢复）', () {
      final now = DateTime(2026, 11, 16, 12, 0);
      final a = NotifiedEventTracker(now: () => now);
      a.shouldNotify('d1:completed:t1');
      a.shouldNotify('d2:error:t2');
      final snap = a.snapshot();

      final b = NotifiedEventTracker(now: () => now);
      b.restore(snap);
      expect(b.shouldNotify('d1:completed:t1'), isFalse,
          reason: '恢复后窗口内仍应抑制');
      expect(b.shouldNotify('d2:error:t2'), isFalse);
    });
  });
}
