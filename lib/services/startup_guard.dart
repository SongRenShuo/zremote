import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage_ohos/flutter_secure_storage_ohos.dart';

import 'notified_event_store.dart';
import 'notifier.dart';

/// 启动护栏：runApp 之后才允许进行的插件初始化统一收口。
///
/// 背景（fix/hos-startup，2026-11-16 鸿蒙首屏白屏根因）：
/// 旧版 main() 在 runApp 之前依次 await NotifierService.instance.init() 与
/// DeviceStore 的 locale/biometric/keepalive/themeMode 读盘（shared_preferences /
/// flutter_secure_storage 平台通道）。在 HarmonyOS NEXT 上 stock 版插件没有
/// ohos 平台实现，通道消息发出后原生侧永不应答（VM service 取证：isolate
/// 空闲挂起、无异常、无 MissingPluginException），main() 卡死在第一个 await，
/// runApp 永不执行 → 首屏全白。Android/iOS 因插件实现健全不受影响，但该
/// 「首帧依赖插件读盘」的顺序本身就是脆弱点。
///
/// 铁律（由此文件固化）：
/// 1. main() 内 runApp 之前只允许做纯 Dart 侧装配（LogBuffer 等），禁止 await
///    任何平台通道调用；
/// 2. 插件初始化一律走 [StartupGuard.warmUp] 后台异步执行，完成后由各
///    Riverpod notifier 的 _load() 自行刷新状态（见 state/locale.dart 等）；
/// 3. 任何插件调用失败（异常或永久悬挂）不得阻塞首屏、不得让进程退出。
class StartupGuard {
  StartupGuard._();

  static bool _started = false;

  /// runApp 之后调用一次；内部全部后台异步，失败仅记日志。
  static void warmUp() {
    if (_started) return;
    _started = true;
    unawaited(_run());
  }

  static Future<void> _run() async {
    _log('background init start');
    try {
      // 通知插件初始化（注册点击/动作路由回调）。ohos 上无实现时该调用可能
      // 永不返回或抛 MissingPluginException——都不能影响 UI。
      await NotifierService.instance.init().timeout(const Duration(seconds: 8));
      _log('NotifierService.init done');
    } catch (e) {
      _log('NotifierService.init failed: $e');
    }
    try {
      await NotifiedEventStore.instance
          .load()
          .timeout(const Duration(seconds: 8));
      _log('NotifiedEventStore.load done');
    } catch (e) {
      _log('NotifiedEventStore.load failed: $e');
    }
    // 通道健康探针（车道D 走查 2026-11-17）：鸿蒙上主包
    // flutter_secure_storage 的 _selectOptions 无 ohos 分支，任何 read/write
    // 都同步抛 UnsupportedError(unsupported_platform)（hilog 证据：
    // startup-guard secure-storage probe error），且 DeviceStore.loadAll
    // 因此永远拿不到设备索引。修复=改用 vendor 包 flutter_secure_storage_ohos
    // （_selectOptions 含 Platform.operatingSystem=='ohos' 分支）。这里保留
    // 一次只读探针，通道坏时 hilog 立即可见，不给启动增加写放大。
    try {
      final back = await const FlutterSecureStorage()
          .read(key: 'zremote.diag.probe')
          .timeout(const Duration(seconds: 5));
      _log('secure-storage probe: ${back ?? "empty(null)"}');
    } catch (e) {
      _log('secure-storage probe error: $e');
    }
    _log('background init end');
  }

  static void _log(String message) {
    if (kDebugMode) {
      debugPrint('[startup-guard] $message');
    }
  }
}
