import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/webview_profile.dart';

RemoteDevice _device(
  String id, {
  DeviceKind kind = DeviceKind.v2,
}) =>
    RemoteDevice(
      id: id,
      baseUrl: 'https://zcode.z.ai/remote/v4',
      params: const {},
      label: 'TEST-DESKTOP',
      createdAt: DateTime(2026, 10, 31),
      kind: kind,
    );

void main() {
  group('webProfileNameFor', () {
    test('V2 卡返回 zr_ 前缀 profile 名', () {
      final name = webProfileNameFor(
          _device('00000000-0000-4000-8000-000000000000'));
      expect(name, 'zr_00000000-0000-4000-8000-000000000000');
    });

    test('legacy 卡返回 null（不传键，行为零变化）', () {
      expect(webProfileNameFor(_device('any-id', kind: DeviceKind.legacy)),
          isNull);
    });

    test('非法字符替换为下划线（白名单净化）', () {
      expect(
        webProfileNameFor(_device('ab/cd ef+gh')),
        'zr_ab_cd_ef_gh',
      );
    });

    test('空 id 返回 null（防御空串）', () {
      expect(webProfileNameFor(_device('')), isNull);
    });

    test('全非法字符 id：替换为下划线仍产出合法名（纯防御路径，UUID 不触发）', () {
      expect(webProfileNameFor(_device('///')), 'zr____');
    });
  });

  group('shouldShowIsolationFallback', () {
    test('V2 卡且不支持：显示横幅', () {
      expect(
        shouldShowIsolationFallback(
            kind: DeviceKind.v2, multiProfileSupported: false),
        isTrue,
      );
    });

    test('V2 卡且支持：不显示', () {
      expect(
        shouldShowIsolationFallback(
            kind: DeviceKind.v2, multiProfileSupported: true),
        isFalse,
      );
    });

    test('legacy 卡恒不显示', () {
      expect(
        shouldShowIsolationFallback(
            kind: DeviceKind.legacy, multiProfileSupported: false),
        isFalse,
      );
    });
  });

  group('settings 键透传（fork 补丁 A 门禁）', () {
    test('设值进 toMap，Java 侧可解析', () {
      final map =
          InAppWebViewSettings(androidWebProfile: 'zr_card1').toMap();
      expect(map['androidWebProfile'], 'zr_card1');
    });

    test('缺省 null：键存在、值为 null（既有行为不变）', () {
      final map = InAppWebViewSettings().toMap();
      expect(map.containsKey('androidWebProfile'), isTrue);
      expect(map['androidWebProfile'], isNull);
    });

    test('fromMap 往返保真', () {
      final restored = InAppWebViewSettings.fromMap(
          InAppWebViewSettings(androidWebProfile: 'zr_card2').toMap());
      expect(restored?.androidWebProfile, 'zr_card2');
    });
  });

  group('MULTI_PROFILE 枚举（fork 补丁 B 门禁）', () {
    test('原生值与 androidx WebViewFeature 字符串常量一致', () {
      expect(WebViewFeature.MULTI_PROFILE.toNativeValue(), 'MULTI_PROFILE');
      expect(WebViewFeature.values, contains(WebViewFeature.MULTI_PROFILE));
      expect(WebViewFeature.fromNativeValue('MULTI_PROFILE'),
          WebViewFeature.MULTI_PROFILE);
    });
  });

  group('multiProfileSupportedProvider（P5-2 iOS 横幅抑制分支）', () {
    test('iOS：返回 true（语义=抑制会话页降级警示，非实际支持）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final container = ProviderContainer();
      addTearDown(() {
        container.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
      expect(
        await container.read(multiProfileSupportedProvider.future),
        isTrue,
      );
    });

    test('iOS 分支不再触发恒显警示链（shouldShowIsolationFallback 判 false）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // 会话页横幅判定用 provider 值：iOS → true → 不显示。
      expect(
        shouldShowIsolationFallback(
          kind: DeviceKind.v2,
          multiProfileSupported: true,
        ),
        isFalse,
      );
    });

    test('Android 探测失败（测试环境无平台通道）→ false 语义保持', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final container = ProviderContainer();
      addTearDown(() {
        container.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
      expect(
        await container.read(multiProfileSupportedProvider.future),
        isFalse,
      );
    });
  });
}
