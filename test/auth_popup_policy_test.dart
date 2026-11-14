import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/auth_popup_policy.dart';

void main() {
  group('AuthPopupPolicy.initialRequestFor', () {
    CreateWindowAction actionOf(String? url) => CreateWindowAction(
      windowId: 1,
      request: URLRequest(url: url == null ? null : WebUri(url)),
      isForMainFrame: true,
      hasGesture: true,
      isDialog: false,
    );

    test('window.open(about:blank)：返回 null，交由 windowId 接管', () {
      expect(
        AuthPopupPolicy.initialRequestFor(actionOf('about:blank')),
        isNull,
      );
    });

    test('空 URL：返回 null', () {
      expect(AuthPopupPolicy.initialRequestFor(actionOf(null)), isNull);
      expect(AuthPopupPolicy.initialRequestFor(actionOf('')), isNull);
      expect(AuthPopupPolicy.initialRequestFor(actionOf('   ')), isNull);
    });

    test('真实 URL（target=_blank 场景）：返回对应请求', () {
      final r = AuthPopupPolicy.initialRequestFor(
        actionOf('https://chat.z.ai/login?next=%2F'),
      );
      expect(r, isNotNull);
      expect(r!.url.toString(), 'https://chat.z.ai/login?next=%2F');
    });

    test('非 http(s) scheme 与无 host 的 URL：返回 null', () {
      expect(AuthPopupPolicy.initialRequestFor(actionOf('file:///a.html')), isNull);
      expect(
        AuthPopupPolicy.initialRequestFor(actionOf('javascript:void(0)')),
        isNull,
      );
      expect(
        AuthPopupPolicy.initialRequestFor(actionOf('https:///path-only')),
        isNull,
      );
    });
  });

  group('AuthPopupPolicy.mainOriginOf', () {
    test('取 baseUrl 的 origin（含非默认端口）', () {
      final d = RemoteDevice(
        id: 'd1',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'sid': 's'},
        label: '',
        createdAt: DateTime(2026),
      );
      expect(AuthPopupPolicy.mainOriginOf(d), 'https://zcode.z.ai');
    });
  });

  group('AuthPopupPolicy.shouldAutoClose', () {
    const origin = 'https://zcode.z.ai';

    test('弹窗回到主应用 origin：关闭', () {
      expect(
        AuthPopupPolicy.shouldAutoClose(
          Uri.parse('https://zcode.z.ai/remote/v4?sid=x'),
          origin,
        ),
        isTrue,
      );
      expect(
        AuthPopupPolicy.shouldAutoClose(Uri.parse('https://zcode.z.ai'), origin),
        isTrue,
      );
    });

    test('授权页（chat.z.ai）与空白页：不关闭', () {
      expect(
        AuthPopupPolicy.shouldAutoClose(
          Uri.parse('https://chat.z.ai/api/oauth/authorize?x=1'),
          origin,
        ),
        isFalse,
      );
      expect(
        AuthPopupPolicy.shouldAutoClose(Uri.parse('about:blank'), origin),
        isFalse,
      );
    });

    test('scheme 或端口不一致：不关闭', () {
      expect(
        AuthPopupPolicy.shouldAutoClose(
          Uri.parse('http://zcode.z.ai/remote/v4'),
          origin,
        ),
        isFalse,
      );
    });

    test('origin 为空或 URL 为空：不关闭', () {
      expect(AuthPopupPolicy.shouldAutoClose(null, origin), isFalse);
      expect(
        AuthPopupPolicy.shouldAutoClose(Uri.parse('https://zcode.z.ai'), ''),
        isFalse,
      );
    });
  });
}
