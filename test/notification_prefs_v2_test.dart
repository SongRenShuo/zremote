import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/models/notification_prefs.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/services/notifier.dart';

RemoteDevice _device(String id, {Map<String, String> params = const {}}) =>
    RemoteDevice(
      id: id,
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: params,
      label: '',
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationPrefs 扩展字段默认值（P3-1）', () {
    test('claimResult 默认开，captchaManual/quotaLow 默认关，DND 默认关', () {
      const prefs = NotificationPrefs();
      expect(prefs.claimResult, isTrue);
      expect(prefs.captchaManual, isFalse);
      expect(prefs.quotaLow, isFalse);
      expect(prefs.dndEnabled, isFalse);
      expect(prefs.dndStartMinutes, 0);
      expect(prefs.dndEndMinutes, 0);
    });

    test('copyWith 全字段往返', () {
      const base = NotificationPrefs();
      final next = base.copyWith(
        claimResult: false,
        captchaManual: true,
        quotaLow: true,
        dndStartMinutes: 1380,
        dndEndMinutes: 480,
      );
      expect(next.claimResult, isFalse);
      expect(next.captchaManual, isTrue);
      expect(next.quotaLow, isTrue);
      expect(next.dndEnabled, isTrue);
    });
  });

  group('prefs 序列化往返（DeviceStore）', () {
    testWidgets('新键落盘与读出一致；旧键语义不变', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.notify.approval': false,
        'zremote.notify.complete': true,
      });
      final store = DeviceStore.instance;
      final loaded = await store.notificationPrefs();
      expect(loaded.approval, isFalse);
      expect(loaded.complete, isTrue);
      expect(loaded.fail, isFalse);
      expect(loaded.claimResult, isTrue, reason: '未落盘回落默认开');
      expect(loaded.captchaManual, isFalse);

      await store.setNotificationPrefs(
        loaded.copyWith(
          claimResult: false,
          captchaManual: true,
          quotaLow: true,
          dndStartMinutes: 1320,
          dndEndMinutes: 420,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('zremote.notify.claimResult'), isFalse);
      expect(prefs.getBool('zremote.notify.captchaManual'), isTrue);
      expect(prefs.getBool('zremote.notify.quotaLow'), isTrue);
      expect(prefs.getInt('zremote.notify.dndStart'), 1320);
      expect(prefs.getInt('zremote.notify.dndEnd'), 420);

      final round = await store.notificationPrefs();
      expect(round.claimResult, isFalse);
      expect(round.captchaManual, isTrue);
      expect(round.quotaLow, isTrue);
      expect(round.dndStartMinutes, 1320);
      expect(round.dndEndMinutes, 420);
      expect(round.dndEnabled, isTrue);
    });

    testWidgets('DND 分钟越界回落 0（与关闭同义）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'zremote.notify.dndStart': 24 * 60,
        'zremote.notify.dndEnd': -5,
      });
      final loaded = await DeviceStore.instance.notificationPrefs();
      expect(loaded.dndStartMinutes, 0);
      expect(loaded.dndEndMinutes, 0);
      expect(loaded.dndEnabled, isFalse);
    });
  });

  group('DND gate 矩阵（免打扰时段只放行审批高优）', () {
    final dnd = const NotificationPrefs(
      dndStartMinutes: 23 * 60, // 23:00
      dndEndMinutes: 8 * 60, // 08:00（跨零点）
    );
    final noDnd = const NotificationPrefs();

    test('跨零点窗口判定：窗口内/窗口外', () {
      expect(NotificationGatePolicy.inDndWindow(dnd, 23 * 60), isTrue);
      expect(NotificationGatePolicy.inDndWindow(dnd, 2 * 60), isTrue);
      expect(NotificationGatePolicy.inDndWindow(dnd, 7 * 60 + 59), isTrue);
      expect(NotificationGatePolicy.inDndWindow(dnd, 8 * 60), isFalse);
      expect(NotificationGatePolicy.inDndWindow(dnd, 22 * 60 + 59), isFalse);
      expect(NotificationGatePolicy.inDndWindow(dnd, 12 * 60), isFalse);
    });

    test('不跨零点窗口判定', () {
      const lunch = NotificationPrefs(dndStartMinutes: 720, dndEndMinutes: 810);
      expect(NotificationGatePolicy.inDndWindow(lunch, 721), isTrue);
      expect(NotificationGatePolicy.inDndWindow(lunch, 809), isTrue);
      expect(NotificationGatePolicy.inDndWindow(lunch, 720), isTrue);
      expect(NotificationGatePolicy.inDndWindow(lunch, 810), isFalse);
      expect(NotificationGatePolicy.inDndWindow(lunch, 100), isFalse);
    });

    test('DND 关闭（start==end）任何时刻都不在窗口', () {
      for (final m in [0, 300, 720, 1439]) {
        expect(NotificationGatePolicy.inDndWindow(noDnd, m), isFalse);
      }
    });

    test('DND 窗口内：approval 放行，其余全部拦截', () {
      // 03:00（窗口内）
      for (final cat in ZrNotifyCategory.values) {
        final allowed = NotificationGatePolicy.allows(
          prefs: dnd,
          deviceParams: const {},
          category: cat,
          minuteOfDay: 3 * 60,
        );
        expect(
          allowed,
          cat == ZrNotifyCategory.approval,
          reason: 'DND 内 $cat 应${cat == ZrNotifyCategory.approval ? "放行" : "拦截"}',
        );
      }
    });

    test('DND 窗口外：按类型开关', () {
      // 12:00（窗口外）
      const prefs = NotificationPrefs(claimResult: true, captchaManual: false);
      expect(
        NotificationGatePolicy.allows(
          prefs: prefs,
          deviceParams: const {},
          category: ZrNotifyCategory.claimResult,
          minuteOfDay: 12 * 60,
        ),
        isTrue,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: prefs,
          deviceParams: const {},
          category: ZrNotifyCategory.captcha,
          minuteOfDay: 12 * 60,
        ),
        isFalse,
      );
    });
  });

  group('每设备通知覆盖组合（params.notifyOverride）', () {
    test('override 解析：on/off/inherit/脏值', () {
      expect(
        NotificationGatePolicy.overrideOf(const {'notifyOverride': 'on'}),
        ZrNotifyOverride.on,
      );
      expect(
        NotificationGatePolicy.overrideOf(const {'notifyOverride': 'off'}),
        ZrNotifyOverride.off,
      );
      expect(
        NotificationGatePolicy.overrideOf(const {}),
        ZrNotifyOverride.inherit,
      );
      expect(
        NotificationGatePolicy.overrideOf(const {'notifyOverride': 'x'}),
        ZrNotifyOverride.inherit,
      );
    });

    test('off：该设备一切类别静音（含审批、含 DND 外）', () {
      final device = _device('d1', params: const {'notifyOverride': 'off'});
      for (final cat in ZrNotifyCategory.values) {
        expect(
          NotificationGatePolicy.allows(
            prefs: const NotificationPrefs(),
            deviceParams: device.params,
            category: cat,
            minuteOfDay: 12 * 60,
          ),
          isFalse,
          reason: 'off 设备 $cat 应全拦',
        );
      }
    });

    test('on：豁免全局类型开关，但不豁免 DND', () {
      final device = _device('d1', params: const {'notifyOverride': 'on'});
      const allOff = NotificationPrefs(
        approval: false,
        claimResult: false,
        captchaManual: false,
      );
      // DND 关 + 全局开关关 → on 设备照发（豁免类型开关）
      expect(
        NotificationGatePolicy.allows(
          prefs: allOff,
          deviceParams: device.params,
          category: ZrNotifyCategory.claimResult,
          minuteOfDay: 12 * 60,
        ),
        isTrue,
      );
      // DND 开 → on 设备的普通类别仍被免打扰拦截（仅审批放行）
      const dnd = NotificationPrefs(
        dndStartMinutes: 0,
        dndEndMinutes: 24 * 60 - 1,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: dnd,
          deviceParams: device.params,
          category: ZrNotifyCategory.claimResult,
          minuteOfDay: 600,
        ),
        isFalse,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: dnd,
          deviceParams: device.params,
          category: ZrNotifyCategory.approval,
          minuteOfDay: 600,
        ),
        isTrue,
      );
    });

    test('inherit（默认）：完全跟随全局开关', () {
      const prefs = NotificationPrefs(); // complete=false
      expect(
        NotificationGatePolicy.allows(
          prefs: prefs,
          deviceParams: const {'sid': 's'},
          category: ZrNotifyCategory.done,
          minuteOfDay: 0,
        ),
        isFalse,
      );
      expect(
        NotificationGatePolicy.allows(
          prefs: prefs,
          deviceParams: const {},
          category: ZrNotifyCategory.approval,
          minuteOfDay: 0,
        ),
        isTrue,
      );
    });
  });

  group('NotificationPayload（P4-7）', () {
    test('build/parse 往返：无 taskId / 有 taskId', () {
      expect(NotificationPayload.build('d1'), 'd1');
      expect(NotificationPayload.build('d1', taskId: 't9'), 'd1#t9');
      expect(NotificationPayload.parse('d1')!.deviceId, 'd1');
      expect(NotificationPayload.parse('d1')!.taskId, isNull);
      final t = NotificationPayload.parse('d1#t9')!;
      expect(t.deviceId, 'd1');
      expect(t.taskId, 't9');
      expect(t.claim, isFalse);
    });

    test('claim 前缀（L3 格式）与空值', () {
      final t = NotificationPayload.parse('claim:abc')!;
      expect(t.claim, isTrue);
      expect(t.deviceId, 'abc');
      expect(NotificationPayload.parse(''), isNull);
      expect(NotificationPayload.parse('claim:'), isNull);
    });

    test('退化形态：# 开头/# 结尾按设备 id 处理', () {
      expect(NotificationPayload.parse('#t')!.deviceId, '#t');
      final tail = NotificationPayload.parse('d1#')!;
      expect(tail.deviceId, 'd1');
      expect(tail.taskId, isNull);
    });

    test('categoryOfEvent 事件类型映射', () {
      expect(
        NotificationGatePolicy.categoryOfEvent('permission_request'),
        ZrNotifyCategory.approval,
      );
      expect(
        NotificationGatePolicy.categoryOfEvent('elicitation_request'),
        ZrNotifyCategory.approval,
      );
      expect(
        NotificationGatePolicy.categoryOfEvent('error'),
        ZrNotifyCategory.fail,
      );
      expect(
        NotificationGatePolicy.categoryOfEvent('completed'),
        ZrNotifyCategory.done,
      );
      expect(NotificationGatePolicy.categoryOfEvent('other'), isNull);
    });
  });
}
