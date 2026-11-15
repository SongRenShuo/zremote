import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notification_prefs.dart';
import '../services/device_store.dart';

class NotificationPrefsNotifier extends Notifier<NotificationPrefs> {
  @override
  NotificationPrefs build() {
    _load();
    return const NotificationPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await DeviceStore.instance.notificationPrefs();
      // 容器可能在等待期间被销毁（Riverpod 不允许写已销毁 Ref）。
      if (!ref.mounted) return;
      state = prefs;
    } catch (e) {
      if (!ref.mounted) return;
      // 存储层异常（平台通道缺失等）降级为默认开关，不炸宿主页面。
      state = const NotificationPrefs();
    }
  }

  Future<void> set(NotificationPrefs prefs) async {
    state = prefs;
    await DeviceStore.instance.setNotificationPrefs(prefs);
  }
}

final notificationPrefsProvider =
    NotifierProvider<NotificationPrefsNotifier, NotificationPrefs>(
      NotificationPrefsNotifier.new,
    );
