import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/services/update_checker.dart';
import 'package:zremote/ui/settings_page.dart';

/// 桩适配器：[responder] 为 null 时 fetch 挂起（闸门），由 [settle] 放行；
/// 非 null 时同步返回（可抛异常模拟超时/网络失败）。
class _StubAdapter implements HttpClientAdapter {
  int requests = 0;
  Object? Function()? responder;
  final List<Completer<ResponseBody>> _pending = [];

  bool get hasPending => _pending.isNotEmpty;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final r = responder;
    if (r == null) {
      final c = Completer<ResponseBody>();
      _pending.add(c);
      return c.future;
    }
    return r() as ResponseBody;
  }

  void settle(ResponseBody body) {
    _pending.removeAt(0).complete(body);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _release(String tag) => ResponseBody.fromString(
      jsonEncode({
        'tag_name': tag,
        'html_url': 'https://github.com/SongRenShuo/zremote/releases/tag/$tag',
        'assets': const [
          {
            'name': 'app-release.apk',
            'browser_download_url': 'https://x/apk',
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _status(int code, [Map<String, dynamic> body = const {}]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Future<void> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  const keepaliveChannel = MethodChannel('zremote/keepalive');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, null);
  });

  tester.view.physicalSize = const Size(760, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 滚动到更新检查行（ListView 惰性构建）。
Future<void> _revealUpdateTile(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.text('检查更新'),
    find.byType(ListView),
    const Offset(0, -240),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );
  const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'ZRemote',
      packageName: 'cn.song.zremote',
      version: '2.0.1',
      buildNumber: '9',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncherChannel, (call) async => true);
  });

  tearDown(() {
    updateCheckerFactory = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncherChannel, null);
  });

  group('l10n：settingsUpdate* 键 zh/en 对齐', () {
    test('前缀键集合一致且非空', () {
      Map<String, dynamic> load(String name) =>
          jsonDecode(File('lib/l10n/$name').readAsStringSync())
              as Map<String, dynamic>;

      final zh = load('app_zh.arb');
      final en = load('app_en.arb');
      Iterable<String> keys(Map<String, dynamic> arb) => arb.keys
          .where((k) => k.startsWith('settingsUpdate') && !k.startsWith('@'));

      final zhKeys = keys(zh).toSet();
      final enKeys = keys(en).toSet();
      expect(zhKeys, isNotEmpty);
      expect(zhKeys.difference(enKeys), isEmpty,
          reason: 'zh 有而 en 缺: ${zhKeys.difference(enKeys)}');
      expect(enKeys.difference(zhKeys), isEmpty,
          reason: 'en 有而 zh 缺: ${enKeys.difference(zhKeys)}');
      // 反向验证：确实存在新键（防止断言空绿）。
      expect(zhKeys, containsAll(<String>[
        'settingsUpdateUpToDate',
        'settingsUpdateFailed',
        'settingsUpdateRetry',
        'settingsUpdateReasonTimeout',
        'settingsUpdateReasonRateLimited',
        'settingsUpdateReasonHttpError',
        'settingsUpdateReasonBadJson',
        'settingsUpdateReasonBadVersion',
      ]));
    });
  });

  group('_UpdateTile 四态（v21 修）', () {
    testWidgets('已是最新：副标题 + SnackBar 明示，不再回落旧句', (tester) async {
      final adapter = _StubAdapter()
        ..responder = () => _release('v2.0.1');
      updateCheckerFactory = ({required currentVersion}) =>
          UpdateChecker(
            client: Dio()..httpClientAdapter = adapter,
            currentVersion: currentVersion,
          );

      await _pumpSettings(tester);
      await _revealUpdateTile(tester);

      expect(find.text('与 GitHub Releases 比对版本'), findsOneWidget);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(adapter.requests, 1);
      expect(find.text('已是最新（v2.0.1）'), findsWidgets);
      expect(find.text('查看发布页'), findsNothing);
      expect(find.byKey(const Key('update-checking')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有新版本：副标题 + 查看发布页 + 跳转发布 URL', (tester) async {
      final adapter = _StubAdapter()
        ..responder = () => _release('v2.1.0');
      updateCheckerFactory = ({required currentVersion}) =>
          UpdateChecker(
            client: Dio()..httpClientAdapter = adapter,
            currentVersion: currentVersion,
          );
      final launches = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(urlLauncherChannel, (call) async {
        launches.add(call);
        return true;
      });

      await _pumpSettings(tester);
      await _revealUpdateTile(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.text('发现新版本 2.1.0'), findsOneWidget);
      expect(find.text('查看发布页'), findsOneWidget);

      await tester.tap(find.text('查看发布页'));
      await tester.pump();
      expect(launches, hasLength(1));
      expect(
        launches.single.arguments['url'],
        contains('SongRenShuo/zremote/releases/tag/v2.1.0'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('检查失败：SnackBar 带原因 + 重试可用（403 限流）', (tester) async {
      final adapter = _StubAdapter()
        ..responder = () => _status(403, const {'message': 'rate limit'});
      updateCheckerFactory = ({required currentVersion}) =>
          UpdateChecker(
            client: Dio()..httpClientAdapter = adapter,
            currentVersion: currentVersion,
          );

      await _pumpSettings(tester);
      await _revealUpdateTile(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.textContaining('检查失败：请求被限流（HTTP 403）'), findsWidgets);
      expect(find.byKey(const Key('update-retry-snack')), findsOneWidget);
      expect(find.byKey(const Key('update-retry')), findsOneWidget);
      expect(adapter.requests, 1);

      // 重试：换成 200 最新 → 副标题与 SnackBar 切到「已是最新」。
      adapter.responder = () => _release('v2.0.1');
      await tester.tap(find.byKey(const Key('update-retry-snack')));
      await tester.pumpAndSettle();

      expect(adapter.requests, 2);
      expect(find.text('已是最新（v2.0.1）'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('坏 JSON 失败原因可读（非网络泛化）', (tester) async {
      final adapter = _StubAdapter()
        ..responder = () => ResponseBody.fromString(
              '<html>oops</html>',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            );
      updateCheckerFactory = ({required currentVersion}) =>
          UpdateChecker(
            client: Dio()..httpClientAdapter = adapter,
            currentVersion: currentVersion,
          );

      await _pumpSettings(tester);
      await _revealUpdateTile(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.textContaining('检查失败：响应格式异常'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('连点防重入：检查中只发一次请求', (tester) async {
      final adapter = _StubAdapter(); // 闸门模式：fetch 挂起
      updateCheckerFactory = ({required currentVersion}) =>
          UpdateChecker(
            client: Dio()..httpClientAdapter = adapter,
            currentVersion: currentVersion,
          );

      await _pumpSettings(tester);
      await _revealUpdateTile(tester);

      await tester.tap(find.text('检查更新'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.requests, 1);
      expect(find.text('检查中…'), findsOneWidget);
      expect(find.byKey(const Key('update-checking')), findsOneWidget);

      // 检查中再点（onTap 已禁用 + 状态守卫）。
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(adapter.requests, 1);

      adapter.settle(_release('v2.0.1'));
      await tester.pumpAndSettle();
      expect(find.text('已是最新（v2.0.1）'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未完成时卸载不崩（setState/mounted 守卫）', (tester) async {
      final adapter = _StubAdapter();
      updateCheckerFactory = ({required currentVersion}) =>
          UpdateChecker(
            client: Dio()..httpClientAdapter = adapter,
            currentVersion: currentVersion,
          );

      await _pumpSettings(tester);
      await _revealUpdateTile(tester);
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.hasPending, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      adapter.settle(_release('v2.0.1'));
      // 放行 dio 的 Future()/微任务链（卸载后 continuation 必须安全返回）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
