import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/account_vault.dart';

/// 账号库 UI 状态：账号列表 + 设备在用绑定。
@immutable
class AccountsState {
  const AccountsState({
    this.accounts = const [],
    this.activeByDevice = const {},
    this.loaded = false,
  });

  final List<Account> accounts;
  final Map<String, String> activeByDevice;
  final bool loaded;

  AccountsState copyWith({
    List<Account>? accounts,
    Map<String, String>? activeByDevice,
    bool? loaded,
  }) => AccountsState(
    accounts: accounts ?? this.accounts,
    activeByDevice: activeByDevice ?? this.activeByDevice,
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
}

class AccountsNotifier extends Notifier<AccountsState> {
  @override
  AccountsState build() {
    _load();
    return const AccountsState();
  }

  AccountVault get _vault => ref.read(accountVaultOverrideProvider) ?? AccountVault.instance;

  Future<void> _load() async {
    final accounts = await _vault.loadAll();
    final active = await _vault.loadActiveBindings();
    state = AccountsState(
      accounts: accounts,
      activeByDevice: active,
      loaded: true,
    );
  }

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

  Future<Uint8List> exportBundle(String password, List<Account> accounts) =>
      _vault.exportBundle(password, accounts);

  Future<ZsbImportReport> importBundle(Uint8List bytes, String password) async {
    final report = await _vault.importBundle(bytes, password);
    await _load();
    return report;
  }
}

/// 单测注入位（生产为 null，走 [AccountVault.instance]）。
final accountVaultOverrideProvider = Provider<AccountVault?>((ref) => null);

final accountsProvider = NotifierProvider<AccountsNotifier, AccountsState>(
  AccountsNotifier.new,
);
