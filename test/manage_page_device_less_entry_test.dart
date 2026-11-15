import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/account_vault_page.dart';
import 'package:zremote/ui/manage_page.dart';

class _EmptyDevices extends DeviceListNotifier {
  @override
  List<RemoteDevice> build() => const [];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('0 设备空态：账号库入口可打开保险库（device 为 null）', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [deviceListProvider.overrideWith(() => _EmptyDevices())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ZT.theme(Brightness.dark),
          home: const ManagePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('账号库'), findsOneWidget);
    await tester.tap(find.text('账号库'));
    await tester.pumpAndSettle();

    expect(find.byType(AccountVaultPage), findsOneWidget);
    // device 为 null：隐藏依赖 WebView controller 的「保存当前登录」。
    expect(find.byKey(const Key('acct-save-current')), findsNothing);
  });
}
