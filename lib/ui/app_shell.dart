import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/notifier.dart';
import '../state/claim_entry.dart';
import '../state/event_feed.dart';
import '../state/keepalive.dart';
import '../state/session_pool.dart';
import 'manage_page.dart';
import 'session_view.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _pendingTapConsumed = false;

  @override
  void initState() {
    super.initState();
    NotificationTap.bind((payload) => _jumpToPayload(payload));
    NotifierService.instance.setLockScreenRedact(ref.read(biometricProvider));
  }

  @override
  void dispose() {
    NotificationTap.bind(null);
    super.dispose();
  }

  void _jumpTo(String deviceId) {
    if (!mounted) return;
    final index = ref
        .read(deviceListProvider)
        .indexWhere((d) => d.id == deviceId);
    if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
  }

  /// 通知点击路由：`claim:<deviceId>`（领取结果，P2-7）→ 跳设备 +
  /// 请求打开领取页；其余 payload 语义为设备 id（沿用既有行为）。
  void _jumpToPayload(String payload) {
    if (!mounted) return;
    if (payload.startsWith('claim:')) {
      final deviceId = payload.substring('claim:'.length);
      _jumpTo(deviceId);
      ref.read(claimOpenRequestProvider.notifier).request(deviceId);
      return;
    }
    _jumpTo(payload);
  }

  void _consumePendingTap() {
    if (_pendingTapConsumed) return;
    if (ref.read(deviceListProvider).isEmpty) return;
    _pendingTapConsumed = true;
    final pending = NotificationTap.consumePending();
    if (pending != null) _jumpToPayload(pending);
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceListProvider);
    final active = ref.watch(activeTabProvider);

    ref.watch(keepAliveControllerProvider);

    ref.listen<bool>(
      biometricProvider,
      (_, next) => NotifierService.instance.setLockScreenRedact(next),
    );

    ref.listen(deviceListProvider, (prev, next) {
      final count = next.length + 1;
      ref.read(activeTabProvider.notifier).clampTo(count);
      if (prev != null && prev.isEmpty && next.isNotEmpty) {
        _consumePendingTap();
        ref.read(activeTabProvider.notifier).restoreLast();
      }
    });

    ref.listen(activeTabProvider, (_, next) {
      final list = ref.read(deviceListProvider);
      if (next < list.length) {
        ref.read(eventFeedProvider.notifier).clear(list[next].id);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_pendingTapConsumed) _consumePendingTap();
      NotifierService.instance.ensurePermission();
    });

    final children = <Widget>[
      for (final d in devices)
        KeyedSubtree(
          key: ValueKey(d.id),
          child: SessionView(device: d),
        ),
      const ManagePage(),
    ];

    return Scaffold(
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: active.clamp(0, children.length - 1),
          children: children,
        ),
      ),
    );
  }
}
