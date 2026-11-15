import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/notification_prefs.dart';
import '../state/automation.dart';
import '../state/claim_history.dart';
import 'claim_scheduler.dart';

class DeviceStore {
  DeviceStore._();

  static final DeviceStore instance = DeviceStore._();

  static const _indexKey = 'zremote.device.index';
  static const _deviceKeyPrefix = 'zremote.device.';
  static const _biometricKey = 'zremote.biometricEnabled';

  final _secure = const FlutterSecureStorage();

  Future<List<RemoteDevice>> loadAll() async {
    final indexRaw = await _secure.read(key: _indexKey);
    if (indexRaw == null) return [];
    final ids = (jsonDecode(indexRaw) as List).cast<String>();
    final devices = <RemoteDevice>[];
    for (final id in ids) {
      final raw = await _secure.read(key: _deviceKey(id));
      if (raw == null) continue;
      try {
        devices.add(
          RemoteDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } catch (_) {
      }
    }
    return devices;
  }

  Future<void> add(RemoteDevice device) async {
    final ids = await _readIndex();
    if (!ids.contains(device.id)) ids.add(device.id);
    await _secure.write(
      key: _deviceKey(device.id),
      value: jsonEncode(device.toJson()),
    );
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<void> update(RemoteDevice device) => _secure.write(
    key: _deviceKey(device.id),
    value: jsonEncode(device.toJson()),
  );

  Future<void> remove(String id) async {
    await _secure.delete(key: _deviceKey(id));
    final ids = await _readIndex();
    ids.remove(id);
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<void> saveOrder(List<String> ids) async {
    final current = await _readIndex();
    if (current.length != ids.length) return;
    final idSet = ids.toSet();
    if (idSet.length != ids.length) return;
    if (!current.toSet().containsAll(idSet)) return;
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<List<String>> _readIndex() async {
    final raw = await _secure.read(key: _indexKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  String _deviceKey(String id) => '$_deviceKeyPrefix$id';

  Future<bool> biometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_biometricKey) ?? false;
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, value);
  }

  static const _keepAliveKey = 'zremote.keepalive';

  Future<bool> keepAliveEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keepAliveKey) ?? true;
  }

  Future<void> setKeepAliveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keepAliveKey, value);
  }

  static const _localeKey = 'zremote.locale';

  Future<String> localeSetting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_localeKey) ?? 'system';
  }

  Future<void> setLocaleSetting(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, value);
  }

  static const _themeModeKey = 'zremote.themeMode';

  Future<String> themeModeSetting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_themeModeKey) ?? 'system';
  }

  Future<void> setThemeModeSetting(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, value);
  }

  static const _lastDeviceKey = 'zremote.lastDevice';

  Future<String?> lastDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastDeviceKey);
  }

  Future<void> setLastDeviceId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceKey, id);
  }

  static const _notifApprovalKey = 'zremote.notify.approval';
  static const _notifCompleteKey = 'zremote.notify.complete';
  static const _notifFailKey = 'zremote.notify.fail';

  Future<NotificationPrefs> notificationPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return NotificationPrefs(
      approval: prefs.getBool(_notifApprovalKey) ?? true,
      complete: prefs.getBool(_notifCompleteKey) ?? false,
      fail: prefs.getBool(_notifFailKey) ?? false,
    );
  }

  Future<void> setNotificationPrefs(NotificationPrefs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifApprovalKey, value.approval);
    await prefs.setBool(_notifCompleteKey, value.complete);
    await prefs.setBool(_notifFailKey, value.fail);
  }

  static const _automationSnapshotPrefix = 'zremote.automation.';

  /// 自动化面板快照（P3-4）：闲时任务/定时计划/运行历史 + 最后同步时间。
  /// 非敏感数据走 SharedPreferences；读取失败一律返回 null 由调用方降级。
  Future<AutomationBoard?> automationSnapshot(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_automationSnapshotPrefix$deviceId');
      if (raw == null || raw.isEmpty) return null;
      return AutomationBoard.fromSnapshotJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('[automation] snapshot load failed: $e');
      return null;
    }
  }

  Future<void> saveAutomationSnapshot(
    String deviceId,
    AutomationBoard board,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_automationSnapshotPrefix$deviceId',
      jsonEncode(board.toSnapshotJson()),
    );
  }

  static const _claimHistoryPrefix = 'zremote.claim.';

  /// 领取历史快照（P2-6）：记录 + 最后同步时间；非空才落盘（写入方保证）。
  Future<ClaimHistoryBoard?> claimHistorySnapshot(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_claimHistoryPrefix$deviceId');
      if (raw == null || raw.isEmpty) return null;
      return ClaimHistoryBoard.fromSnapshotJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('[claim-history] snapshot load failed: $e');
      return null;
    }
  }

  Future<void> saveClaimHistorySnapshot(
    String deviceId,
    ClaimHistoryBoard board,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_claimHistoryPrefix$deviceId',
      jsonEncode(board.toSnapshotJson()),
    );
  }

  static const _claimConfigPrefix = 'zremote.claimConfig.';

  /// 自动领取配置（P2-5）：enabled/silentStart/silentEnd；缺省=开关关 +
  /// 默认静默 23:00–08:00。读取失败回落默认配置。
  Future<ClaimAutoConfig> claimAutoConfig(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_claimConfigPrefix$deviceId');
      if (raw == null || raw.isEmpty) return const ClaimAutoConfig();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ClaimAutoConfig.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('[claim-config] load failed: $e');
    }
    return const ClaimAutoConfig();
  }

  Future<void> saveClaimAutoConfig(String deviceId, ClaimAutoConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_claimConfigPrefix$deviceId',
      jsonEncode(config.toJson()),
    );
  }
}
