import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/deep_link.dart';

void main() {
  group('extractRemoteLink 白名单（P4-1）', () {
    const v4 =
        'https://zcode.z.ai/remote/v4?sid=d_C86Q4CvTZue7qr2utCSsvY&mid=5ef32d01&name=HQZC-01&app_version=3.18.2';
    const legacy =
        'https://zcode.z.ai/remote?sid=abcdef123456&hash=h&t=1731600000000';

    test('合法 v4 / legacy 直链放行', () {
      expect(extractRemoteLink(v4), v4);
      expect(extractRemoteLink(legacy), legacy);
      expect(extractRemoteLink('  $v4  '), v4); // 去空白
      expect(extractRemoteLink('https://zcode.z.ai/remote'), isNotNull);
      expect(extractRemoteLink('https://zcode.z.ai/remote/'), isNotNull);
    });

    test('zremote://import 包装形态解包', () {
      final wrapped = Uri.parse('zremote://import')
          .replace(queryParameters: {'url': v4}).toString();
      expect(extractRemoteLink(wrapped), v4);
    });

    test('host 白名单外拒绝', () {
      expect(
        extractRemoteLink(
          'https://evil.example.com/remote/v4?sid=x&app_version=3.18.2',
        ),
        isNull,
      );
      // Dart Uri 按 RFC3986 把 host 小写规范化，大小写不是绕过手段（与浏览器同语义）。
      expect(
        extractRemoteLink(
          'https://ZCODE.Z.AI/remote/v4?sid=x&app_version=3.18.2',
        ),
        isNotNull,
      );
    });

    test('path 前缀撞名拒绝（/remotefoo 不属于 /remote 前缀语义）', () {
      expect(
        extractRemoteLink('https://zcode.z.ai/remotefoo?sid=x'),
        isNull,
      );
      expect(
        extractRemoteLink('https://zcode.z.ai/remotev4?sid=x'),
        isNull,
      );
    });

    test('scheme 与空值拒绝', () {
      expect(extractRemoteLink(''), isNull);
      expect(extractRemoteLink('   '), isNull);
      expect(
        extractRemoteLink('http://zcode.z.ai/remote/v4?sid=x'),
        isNull,
      );
      expect(extractRemoteLink('zremote://import'), isNull); // 无 url 参数
      expect(
        extractRemoteLink('zremote://other?url=https%3A%2F%2Fzcode.z.ai%2Fremote%2Fv4%3Fsid%3Dx'),
        isNull,
      );
      // 包装内的外域目标拒。
      expect(
        extractRemoteLink(
          Uri.parse('zremote://import').replace(queryParameters: {
            'url': 'https://evil.example.com/remote/v4?sid=x',
          }).toString(),
        ),
        isNull,
      );
      expect(extractRemoteLink('not a url'), isNull);
    });
  });
}
