import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/update_checker.dart';

void main() {
  group('UpdateChecker.parseRelease（P3-5）', () {
    const body = {
      'tag_name': 'v2.0.0',
      'html_url': 'https://github.com/pjpv/zremote/releases/tag/v2.0.0',
      'assets': [
        {'name': 'app-release.apk', 'browser_download_url': 'https://x/apk'},
        {'name': 'zremote-ios-unsigned.ipa', 'browser_download_url': 'https://x/ipa'},
      ],
    };

    test('有新版本：解析 tag/apk 并比较', () {
      final info = UpdateChecker.parseRelease('1.7.0+9', body);
      expect(info, isNotNull);
      expect(info!.latestVersion, '2.0.0');
      expect(info.currentVersion, '1.7.0');
      expect(info.apkUrl, 'https://x/apk');
      expect(info.releaseUrl, contains('v2.0.0'));
    });

    test('同版本/更旧：返回 null（不提示）', () {
      expect(UpdateChecker.parseRelease('2.0.0', body), isNull);
      expect(UpdateChecker.parseRelease('3.1.4', body), isNull);
    });

    test('形状漂移容错：非 Map / 缺 tag_name / 乱版本', () {
      expect(UpdateChecker.parseRelease('1.0.0', null), isNull);
      expect(UpdateChecker.parseRelease('1.0.0', 'string'), isNull);
      expect(UpdateChecker.parseRelease('1.0.0', {'html_url': 'x'}), isNull);
      expect(
        UpdateChecker.parseRelease('1.0.0', {'tag_name': 'not-a-ver'}),
        isNull,
      );
      expect(
        UpdateChecker.parseRelease('garbage', body),
        isNull, // 当前版本不合法 → 保守无更新
      );
    });

    test('无 apk 资产时 apkUrl 为 null 但仍有 releaseUrl 兜底', () {
      final info = UpdateChecker.parseRelease('1.7.0', {
        'tag_name': 'v1.9.0',
      });
      expect(info, isNotNull);
      expect(info!.apkUrl, isNull);
      expect(info.releaseUrl, contains('releases'));
    });
  });

  group('compareVersions / normalizeVersion 纯函数', () {
    test('三段式比较与 v 前缀/+build 剥离', () {
      expect(UpdateChecker.normalizeVersion('v2.0.0'), '2.0.0');
      expect(UpdateChecker.normalizeVersion('1.7.0+9'), '1.7.0');
      expect(UpdateChecker.compareVersions('1.7.0', '2.0.0'), -1);
      expect(UpdateChecker.compareVersions('2.0.0', '2.0.0'), 0);
      expect(UpdateChecker.compareVersions('2.1.0', '2.0.9'), 1);
      expect(UpdateChecker.compareVersions('2.0.10', '2.0.9'), 1);
      expect(UpdateChecker.compareVersions('bad', '2.0.0'), 0); // 保守
    });
  });
}
