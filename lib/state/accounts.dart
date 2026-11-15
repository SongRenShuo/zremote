import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/account_credentials.dart';
import '../services/account_vault.dart';

/// 账号库 UI 状态：账号列表 + 设备在用绑定 + 全局活跃账号。
@immutable
class AccountsState {
  const AccountsState({
    this.accounts = const [],
    this.activeByDevice = const {},
    this.globalActiveAccountId,
    this.loaded = false,
  });

  final List<Account> accounts;
  final Map<String, String> activeByDevice;

  /// 用户在账号库显式切换的「全局活跃账号」（会话内有效，不持久化）。
  /// null = 未显式指定，按 [globalActiveAccount] 的自动规则选取。
  final String? globalActiveAccountId;

  final bool loaded;

  AccountsState copyWith({
    List<Account>? accounts,
    Map<String, String>? activeByDevice,
    String? globalActiveAccountId,
    bool? loaded,
  }) => AccountsState(
    accounts: accounts ?? this.accounts,
    activeByDevice: activeByDevice ?? this.activeByDevice,
    globalActiveAccountId: globalActiveAccountId ?? this.globalActiveAccountId,
    loaded: loaded ?? this.loaded,
  );

  Account? activeAccountOf(RemoteDevice device) {
    final id = activeByDevice[device.id];
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 全局活跃账号（不依赖具体设备）——「从账户添加设备」的唯一账号来源。
  ///
  /// 选取规则（确定性，可测）：
  /// 1. 显式切换过（[globalActiveAccountId]）且该账号仍存在 → 用之；
  /// 2. 账号唯一 → 直接用；
  /// 3. 多账号 → 取**最近使用**（`updatedAt` 最大，凭据最近一次刷新/使用），
  ///    并列取**最近添加**（`createdAt` 最大），仍并列取列表中靠前者。
  Account? globalActiveAccount() {
    final explicit = globalActiveAccountId;
    if (explicit != null) {
      for (final a in accounts) {
        if (a.id == explicit) return a;
      }
      // 显式选择已被删除 → 回落自动规则。
    }
    if (accounts.isEmpty) return null;
    if (accounts.length == 1) return accounts.first;
    var best = accounts.first;
    for (var i = 1; i < accounts.length; i++) {
      final a = accounts[i];
      if (a.updatedAt.isAfter(best.updatedAt)) {
        best = a;
      } else if (a.updatedAt.isAtSameMomentAs(best.updatedAt) &&
          a.createdAt.isAfter(best.createdAt)) {
        best = a;
      }
    }
    return best;
  }
}

class AccountsNotifier extends Notifier<AccountsState> {
  @override
  AccountsState build() {
    _load();
    return const AccountsState();
  }

  AccountVault get _vault => ref.read(accountVaultOverrideProvider) ?? AccountVault.instance;

  Future<void> _load() async {
    try {
      final accounts = await _vault.loadAll();
      final active = await _vault.loadActiveBindings();
      state = AccountsState(
        accounts: accounts,
        activeByDevice: active,
        loaded: true,
      );
    } catch (e) {
      // 存储层异常（如平台通道缺失）降级为空库，不炸宿主页面。
      debugPrint('[zr-vault] accounts load failed: $e');
      state = state.copyWith(loaded: true);
    }
  }

  /// 外部（登录页/会话页）直接改库后的回读刷新。
  Future<void> reload() => _load();

  Future<Account?> saveFromCredentials({
    required String provider,
    required Map<String, String> credentials,
    String? name,
  }) async {
    final account = await _vault.upsertFromCredentials(
      provider: provider,
      credentials: credentials,
      name: name,
    );
    await _load();
    return account;
  }

  /// 应用前保全：回读键值保全为账号（无 token 返回 null）。
  Future<Account?> preserveRawEntries(Map<String, String> entries) async {
    final account = await _vault.preserveRawEntries(entries);
    if (account != null) await _load();
    return account;
  }

  Future<void> remove(String id) async {
    await _vault.remove(id);
    await _load();
  }

  Future<void> setActiveForDevice(RemoteDevice device, String? accountId) async {
    await _vault.setActiveForDevice(device.id, accountId);
    await _load();
  }

  /// 显式切换全局活跃账号（账号库 UI 的「当前账号」选择器）。
  /// 传 null 恢复自动规则；仅改内存态，不落盘（重启后按自动规则重算）。
  void setGlobalActiveAccount(String? accountId) {
    state = AccountsState(
      accounts: state.accounts,
      activeByDevice: state.activeByDevice,
      globalActiveAccountId: accountId,
      loaded: state.loaded,
    );
  }

  Future<Uint8List> exportBundle(String password, List<Account> accounts) =>
      _vault.exportBundle(password, accounts);

  Future<ZsbImportReport> importBundle(Uint8List bytes, String password) async {
    final report = await _vault.importBundle(bytes, password);
    await _load();
    return report;
  }
}

/// 设备在用账号的供票（quota 中心 / 福利中心 / 端点探测共用入口）。
///
/// 集成方（会话页）一行接线：
/// `ticketsOfActiveAccount(ref.read(accountsProvider), widget.device)`，
/// 未绑定/未加载/未登录时返回空集合，各页自行降级。
AccountTickets ticketsOfActiveAccount(AccountsState state, RemoteDevice device) =>
    accountTicketsOf(state.activeAccountOf(device));

/// 全局活跃账号的供票（账户设备导入等不依赖设备的入口用）。
AccountTickets ticketsOfGlobalActiveAccount(AccountsState state) =>
    accountTicketsOf(state.globalActiveAccount());

/// 单测注入位（生产为 null，走 [AccountVault.instance]）。
final accountVaultOverrideProvider = Provider<AccountVault?>((ref) => null);

final accountsProvider = NotifierProvider<AccountsNotifier, AccountsState>(
  AccountsNotifier.new,
);
