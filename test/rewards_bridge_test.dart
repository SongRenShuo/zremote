import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/account_credentials.dart';
import 'package:zremote/services/account_vault.dart';
import 'package:zremote/services/rewards_bridge.dart';

Account _account(String provider, Map<String, String> credentials) => Account(
  id: 'a1',
  name: provider,
  provider: provider,
  credentials: credentials,
  hash: 'h',
  virtualDeviceMid: 'mid',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('URL 构造与主题映射', () {
    test('dark → zai-dark，light → zai-light', () {
      expect(rewardsThemeParam(Brightness.dark), 'zai-dark');
      expect(rewardsThemeParam(Brightness.light), 'zai-light');
    });

    test('URL：/cn/rewards + embedded=app + 主题参数', () {
      final dark = rewardsPageUri(brightness: Brightness.dark);
      expect(dark.scheme, 'https');
      expect(dark.host, 'zcode.z.ai');
      expect(dark.path, '/cn/rewards');
      expect(dark.queryParameters['embedded'], 'app');
      expect(dark.queryParameters['theme'], 'zai-dark');

      final light = rewardsPageUri(brightness: Brightness.light);
      expect(light.queryParameters['theme'], 'zai-light');
      expect(light.toString(),
          'https://zcode.z.ai/cn/rewards?embedded=app&theme=zai-light');
    });
  });

  group('origin 白名单（移植 rewardsEmbedded 语义）', () {
    test('zcode.z.ai 域内 https 放行', () {
      expect(isAllowedRewardsNavigation(Uri.parse('https://zcode.z.ai/cn/rewards')), isTrue);
      expect(isAllowedRewardsNavigation(Uri.parse('https://zcode.z.ai')), isTrue);
      expect(isAllowedRewardsNavigation(Uri.parse('https://api.zcode.z.ai/x')), isTrue,
          reason: '子域属于域内');
    });

    test('恶意/外域反例全部拦截（S2 反向验证）', () {
      expect(isAllowedRewardsNavigation(Uri.parse('https://evil.com/cn/rewards')), isFalse);
      expect(
        isAllowedRewardsNavigation(
          Uri.parse('https://zcode.z.ai.evil.com/cn/rewards'),
        ),
        isFalse,
        reason: '后缀伪装域必须拦截',
      );
      expect(isAllowedRewardsNavigation(Uri.parse('http://zcode.z.ai/cn/rewards')),
          isFalse, reason: '非 https 拦截');
      expect(isAllowedRewardsNavigation(Uri.parse('https://chat.z.ai/oauth')), isFalse,
          reason: '姊妹域不在白名单');
      expect(isAllowedRewardsNavigation(Uri.parse('ftp://zcode.z.ai/x')), isFalse);
      expect(isAllowedRewardsNavigation(Uri.parse('about:blank')), isFalse);
      expect(isAllowedRewardsNavigation(Uri.parse('javascript:alert(1)')), isFalse);
    });

    test('外域转交判定：http/https 可外开，其余 scheme 拦截', () {
      expect(shouldOpenRewardsUrlExternally(Uri.parse('https://evil.com')), isTrue);
      expect(shouldOpenRewardsUrlExternally(Uri.parse('http://example.com')), isTrue);
      expect(shouldOpenRewardsUrlExternally(Uri.parse('intent://x')), isFalse);
      expect(shouldOpenRewardsUrlExternally(Uri.parse('mailto:a@b.c')), isFalse);
    });
  });

  group('localStorage 供票注入脚本（M0-1 铁律）', () {
    final full = const RewardsCredentials(
      zcodeJwtToken: 'jwt.abc.def',
      zaiAccessToken: 'zai-tok',
      zaiCnAccessToken: 'zai-cn-tok',
      bigmodelAccessToken: 'bm-tok',
      activeProvider: 'zai',
    );

    test('零注释序列：无裸 //（:// 除外）且无 /*（M0-1 判据）', () {
      final script = rewardsTokenInjectionScript(full);
      expect(script, isNotEmpty);
      for (
        var i = script.indexOf('//');
        i >= 0;
        i = script.indexOf('//', i + 1)
      ) {
        expect(
          i > 0 && script[i - 1] == ':',
          isTrue,
          reason: '注入脚本内出现裸 //（offset $i）',
        );
      }
      expect(script.contains('/' '*'), isFalse);
    });

    test('五键齐全（全凭据）', () {
      final script = rewardsTokenInjectionScript(full);
      expect(script.contains('zcodejwttoken'), isTrue);
      expect(script.contains('oauth:zai:access_token'), isTrue);
      expect(script.contains('oauth:zai_cn:access_token'), isTrue);
      expect(script.contains('oauth:bigmodel:access_token'), isTrue);
      expect(script.contains('oauth:active_provider'), isTrue);
      expect(script.contains('jwt.abc.def'), isTrue);
      expect(script.contains('zai-cn-tok'), isTrue);
    });

    test('缺省凭据只注入存在的键；全空返回空串', () {
      final partial = rewardsTokenInjectionScript(
        const RewardsCredentials(zaiAccessToken: 'only-zai'),
      );
      expect(partial.contains('oauth:zai:access_token'), isTrue);
      expect(partial.contains('zcodejwttoken'), isFalse);
      expect(partial.contains('oauth:bigmodel:access_token'), isFalse);
      expect(
        rewardsTokenInjectionScript(const RewardsCredentials()),
        isEmpty,
      );
    });

    test('括号配平 + 引号闭合（字符串感知）', () {
      final script = rewardsTokenInjectionScript(full);
      var brace = 0, paren = 0, bracket = 0;
      var inSingle = false, inDouble = false;
      for (var i = 0; i < script.length; i++) {
        final c = script[i];
        if (inSingle || inDouble) {
          if (c == r'\') {
            i++;
            continue;
          }
          if (inSingle && c == "'") inSingle = false;
          if (inDouble && c == '"') inDouble = false;
          continue;
        }
        if (c == "'") {
          inSingle = true;
        } else if (c == '"') {
          inDouble = true;
        } else if (c == '{') {
          brace++;
        } else if (c == '}') {
          brace--;
        } else if (c == '(') {
          paren++;
        } else if (c == ')') {
          paren--;
        } else if (c == '[') {
          bracket++;
        } else if (c == ']') {
          bracket--;
        }
      }
      expect(inSingle, isFalse, reason: '存在未闭合的单引号字符串');
      expect(inDouble, isFalse, reason: '存在未闭合的双引号字符串');
      expect(brace, 0, reason: '花括号不配平');
      expect(paren, 0, reason: '圆括号不配平');
      expect(bracket, 0, reason: '方括号不配平');
    });

    test('值中的斜杠被转义：即使 token 含 // 也不触发 M0-1 判据', () {
      final hostile = rewardsTokenInjectionScript(
        const RewardsCredentials(zcodeJwtToken: 'a//b/*c'),
      );
      expect(hostile.contains('//'), isFalse);
      expect(hostile.contains('/' '*'), isFalse);
    });

    test('RewardsCredentials.isEmpty 判定', () {
      expect(const RewardsCredentials().isEmpty, isTrue);
      expect(full.isEmpty, isFalse);
      expect(const RewardsCredentials(zaiAccessToken: 'x').isEmpty, isFalse);
    });

    test('window.zcodeBridge 最小就绪态：getAuthState → ready + provider + revision', () {
      final script = rewardsTokenInjectionScript(full);
      expect(script, contains('zcodeBridge'));
      expect(script, contains('getAuthState'));
      expect(script, contains('"ready"'));
      expect(script, contains('provider:'));
      expect(script, contains('revision:1'));
      expect(script.contains('//'), isFalse, reason: 'bridge 定义不得引入注释序列');
    });

    test('无 active_provider 时不写 provider 键', () {
      final script = rewardsTokenInjectionScript(
        const RewardsCredentials(zcodeJwtToken: 'jwt-only'),
      );
      expect(script, contains('zcodejwttoken'));
      expect(script.contains('provider:'), isFalse);
    });
  });

  group('账号 → 福利页供票（account_credentials 接线，登录门控键）', () {
    test('zai 账号：注入含 zcodejwttoken + zai access_token + active_provider', () {
      final tickets = accountTicketsOf(_account('zai', {
        'zcodejwttoken': 'jwt.abc.def',
        'oauth:zai:access_token': 'zai-tok',
        'oauth:active_provider': 'zai',
      }));
      final script = rewardsTokenInjectionScript(tickets.rewardsCredentials);
      expect(script, contains('zcodejwttoken'), reason: '官方登录门控键');
      expect(script, contains('jwt.abc.def'));
      expect(script, contains('oauth:zai:access_token'));
      expect(script, contains('zai-tok'));
      expect(script, contains('oauth:active_provider'));
    });

    test('zai_cn / bigmodel 各自落对应键（provider 组装矩阵）', () {
      final cn = rewardsTokenInjectionScript(
        accountTicketsOf(_account('zai_cn', {
          'oauth:active_provider': 'zai_cn',
          'oauth:zai_cn:access_token': 'cn-tok',
        })).rewardsCredentials,
      );
      expect(cn, contains('oauth:zai_cn:access_token'));
      expect(cn, contains('cn-tok'));

      final bm = rewardsTokenInjectionScript(
        accountTicketsOf(_account('bigmodel', {
          'oauth:active_provider': 'bigmodel',
          'oauth:bigmodel:access_token': 'bm-tok',
        })).rewardsCredentials,
      );
      expect(bm, contains('oauth:bigmodel:access_token'));
      expect(bm, contains('bm-tok'));
    });

    test('无 zcodejwttoken 的账号：脚本不含该键（页面自展示登录态）', () {
      final script = rewardsTokenInjectionScript(
        accountTicketsOf(_account('zai_cn', {
          'oauth:zai_cn:access_token': 'cn-tok',
        })).rewardsCredentials,
      );
      expect(script.contains('zcodejwttoken'), isFalse);
      expect(script, isNotEmpty, reason: '仍有 access_token 可注入');
    });

    test('空账号 → 空集合 → 空脚本（跳过注入）', () {
      final tickets = accountTicketsOf(null);
      expect(tickets.rewardsCredentials.isEmpty, isTrue);
      expect(rewardsTokenInjectionScript(tickets.rewardsCredentials), isEmpty);
    });
  });
}
