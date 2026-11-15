import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/endpoint_probe.dart';
import 'package:zremote/ui/diagnostics_page.dart';

import 'scripted_bridge.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final ResponseBody Function(Uri url) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      responder(options.uri);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status) => ResponseBody.fromString(
      jsonEncode({'data': {}}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

RemoteDevice _device() => RemoteDevice(
      id: 'd1',
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: const {'sid': 's', 'hash': 'h'},
      label: '',
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  // 诊断页 ListView 惰性构建：拉高视口让端点健康段直接可见。
  void tallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(760, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('端点探测按钮：结果渲染（client/configs 读数 + billing 跳过原因）',
      (tester) async {
    tallViewport(tester);
    final bridge = ScriptedBridge(
      script: [
        [
          {
            'keys': const ['usageStatsService'],
            'checks': const <String, dynamic>{},
          },
        ],
        [
          {'supported': true},
        ],
        [
          {'plan': 'team'},
        ],
      ],
    );
    final adapter = _FakeAdapter((url) => _json(200));
    final probe = EndpointProbe(dio: Dio()..httpClientAdapter = adapter);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DiagnosticsPage(
          device: _device(),
          bridge: bridge.bridge,
          endpointProbe: probe,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 端点健康段常驻可见，探测前无结果行。
    expect(find.text('端点健康'), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-endpoints-run')), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnostics-endpoints-run')));
    await tester.pumpAndSettle();

    // client/configs 200 读数 + billing/balance 无 token 跳过原因（l10n 文案）。
    expect(find.textContaining('client/configs'), findsOneWidget);
    expect(find.textContaining('200'), findsOneWidget);
    expect(find.textContaining('billing/balance'), findsOneWidget);
    expect(find.textContaining('跳过：无 zcode JWT'), findsOneWidget);
  });

  testWidgets('端点探测失败：错误摘要行渲染不崩', (tester) async {
    tallViewport(tester);
    final bridge = ScriptedBridge(script: const [
      [
        {'keys': <String>[], 'checks': <String, dynamic>{}},
      ],
      [],
      [],
    ]);
    final adapter = _FakeAdapter((_) => throw DioException.connectionError(
          requestOptions: RequestOptions(path: '/'),
          reason: 'connection refused',
        ));
    final probe = EndpointProbe(dio: Dio()..httpClientAdapter = adapter);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DiagnosticsPage(
          device: _device(),
          bridge: bridge.bridge,
          endpointProbe: probe,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('diagnostics-endpoints-run')));
    await tester.pumpAndSettle();

    expect(find.textContaining('client/configs'), findsOneWidget);
    expect(find.textContaining('ERR'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsOneWidget);
  });
}
