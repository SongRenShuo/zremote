import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/state/accounts.dart';

Account _account(
  String id, {
  required DateTime createdAt,
  required DateTime updatedAt,
}) => Account(
  id: id,
  name: id,
  provider: 'zai_cn',
  credentials: {'zcodejwttoken': 'jwt-$id'},
  hash: 'hash-$id',
  virtualDeviceMid: 'mid-$id',
  createdAt: createdAt,
  updatedAt: updatedAt,
);

void main() {
  final base = DateTime(2026, 11, 16, 8);

  group('AccountsState.globalActiveAccount 选取规则', () {
    test('空库 → null', () {
      const state = AccountsState();
      expect(state.globalActiveAccount(), isNull);
    });

    test('唯一账号 → 直接用（无需设备绑定/显式选择）', () {
      final only = _account(
        'u1',
        createdAt: base,
        updatedAt: base,
      );
      final state = AccountsState(accounts: [only]);
      expect(state.globalActiveAccount()?.id, 'u1');
    });

    test('多账号 → 取最近使用（updatedAt 最大）', () {
      final older = _account(
        'u1',
        createdAt: base,
        updatedAt: base.add(const Duration(minutes: 1)),
      );
      final newer = _account(
        'u2',
        createdAt: base,
        updatedAt: base.add(const Duration(minutes: 9)),
      );
      // 列表顺序故意与规则相反，确保不是「取第一个/最后一个」。
      final state = AccountsState(accounts: [newer, older]);
      expect(state.globalActiveAccount()?.id, 'u2');
    });

    test('updatedAt 并列 → 取最近添加（createdAt 最大）', () {
      final early = _account(
        'u1',
        createdAt: base,
        updatedAt: base.add(const Duration(minutes: 5)),
      );
      final late = _account(
        'u2',
        createdAt: base.add(const Duration(days: 2)),
        updatedAt: base.add(const Duration(minutes: 5)),
      );
      final state = AccountsState(accounts: [early, late]);
      expect(state.globalActiveAccount()?.id, 'u2');
    });

    test('updatedAt/createdAt 全并列 → 确定性取列表中靠前者', () {
      final a = _account('u1', createdAt: base, updatedAt: base);
      final b = _account('u2', createdAt: base, updatedAt: base);
      final state = AccountsState(accounts: [a, b]);
      expect(state.globalActiveAccount()?.id, 'u1');
    });

    test('显式切换优先于自动规则', () {
      final older = _account(
        'u1',
        createdAt: base,
        updatedAt: base,
      );
      final newer = _account(
        'u2',
        createdAt: base,
        updatedAt: base.add(const Duration(minutes: 9)),
      );
      final state = AccountsState(
        accounts: [older, newer],
        globalActiveAccountId: 'u1',
      );
      expect(state.globalActiveAccount()?.id, 'u1');
    });

    test('显式选择已删除 → 回落自动规则', () {
      final older = _account('u1', createdAt: base, updatedAt: base);
      final newer = _account(
        'u2',
        createdAt: base,
        updatedAt: base.add(const Duration(minutes: 9)),
      );
      final state = AccountsState(
        accounts: [older, newer],
        globalActiveAccountId: 'gone',
      );
      expect(state.globalActiveAccount()?.id, 'u2');
    });

    test('copyWith 保留 globalActiveAccountId', () {
      final state = const AccountsState(globalActiveAccountId: 'u1');
      expect(state.copyWith(loaded: true).globalActiveAccountId, 'u1');
    });
  });
}
