import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/models/device.dart';
import 'package:zremote/services/account_vault.dart';

class _MemStore implements SecureStringStore {
  final Map<String, String> map = {};
  final List<String> writeOrder = [];

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async {
    map[key] = value;
    writeOrder.add(key);
  }

  @override
  Future<void> delete(String key) async => map.remove(key);
}

String _fakeJwt({int? expSec}) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return [
    b64({'alg': 'HS256'}),
    b64({'exp': expSec ?? 1893456000}),
    'sig',
  ].join('.');
}

Map<String, String> _creds({
  String provider = 'zai_cn',
  String? userId,
  String? email,
  String? name,
  String jwt = 'jwt-base',
}) {
  final userInfo = <String, String>{};
  if (userId != null) userInfo['user_id'] = userId;
  if (email != null) userInfo['email'] = email;
  if (name != null) userInfo['name'] = name;
  return {
    'zcodejwttoken': jwt,
    'oauth:active_provider': provider,
    'oauth:$provider:access_token': 'at-$provider',
    if (userInfo.isNotEmpty)
      'oauth:$provider:user_info': jsonEncode(userInfo),
  };
}

AccountVault _vault({_MemStore? store}) => AccountVault(
  store: store ?? _MemStore(),
  uuidGen: _SeqUuid().v4,
  now: () => DateTime(2026, 11, 15, 12),
  random: Random(7),
);

class _SeqUuid {
  int n = 0;

  String v4() {
    n += 1;
    return 'uuid-$n';
  }
}

void main() {
  group('canonical 序列化与 hash', () {
    test('键排序后编码：插入序不影响 canonical JSON', () {
      final a = {'b': '2', 'a': '1', 'c': '3'};
      final b = {'c': '3', 'a': '1', 'b': '2'};
      expect(
        AccountVault.canonicalCredentialsJson(a),
        AccountVault.canonicalCredentialsJson(b),
      );
      expect(
        AccountVault.canonicalCredentialsJson(a),
        '{"a":"1","b":"2","c":"3"}',
      );
    });

    test('web-remote-control:* 键不参与 hash（S2 反向：摘掉排除此例必红）', () async {
      final base = _creds();
      final withNoise = {...base, 'web-remote-control:flags': 'abc'};
      final h1 = await AccountVault.computeHash(base);
      final h2 = await AccountVault.computeHash(withNoise);
      expect(h1, h2);
      // 排除逻辑失效时（把 web-remote-control:* 键也算进去），
      // canonical JSON 必然不同 → hash 必然不等——本断言即反向验证。
      final allIn = <String, String>{...base, 'web-remote-control:flags': 'abc'}
        ..addAll({});
      final keys = allIn.keys.toList()..sort();
      final d = await Sha256().hash(utf8.encode(jsonEncode({for (final k in keys) k: allIn[k]})));
      final hAll = d.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hAll, isNot(h1));
    });

    test('hash 为 64 位 hex', () async {
      final h = await AccountVault.computeHash(_creds());
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
    });
  });

  group('身份匹配矩阵', () {
    test('同 user_id → 命中保 id 合并凭据', () async {
      final store = _MemStore();
      final vault = _vault(store: store);
      final a1 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-77', email: 'a@t.invalid'),
      );
      final a2 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-77', email: 'other@t.invalid'),
        name: '改名',
      );
      expect(a2.id, a1.id);
      expect(a2.name, '改名');
      final all = await vault.loadAll();
      expect(all, hasLength(1));
      expect(all.single.credentials['zcodejwttoken'], a2.credentials['zcodejwttoken']);
    });

    test('同 email（user_id 不同）→ 命中', () async {
      final vault = _vault();
      await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-1', email: 'same@t.invalid'),
      );
      final a2 = await vault.upsertFromCredentials(
        provider: 'zai',
        credentials: _creds(provider: 'zai', userId: 'u-2', email: 'same@t.invalid'),
      );
      final all = await vault.loadAll();
      expect(all, hasLength(1));
      expect(all.single.id, a2.id);
    });

    test('provider+username 命中（无 user_id 无 email）', () async {
      final vault = _vault();
      await vault.upsertFromCredentials(
        provider: 'bigmodel',
        credentials: _creds(provider: 'bigmodel', name: 'nick'),
      );
      await vault.upsertFromCredentials(
        provider: 'bigmodel',
        credentials: _creds(provider: 'bigmodel', name: 'nick', jwt: 'jwt-2'),
      );
      expect((await vault.loadAll()), hasLength(1));
    });

    test('同 username 不同 provider → 不命中（S2 反向：身份检查摘掉必红）', () async {
      final vault = _vault();
      await vault.upsertFromCredentials(
        provider: 'bigmodel',
        credentials: _creds(provider: 'bigmodel', name: 'nick'),
      );
      await vault.upsertFromCredentials(
        provider: 'zai',
        credentials: _creds(provider: 'zai', name: 'nick'),
      );
      expect((await vault.loadAll()), hasLength(2));
    });

    test('全新身份 → 新建；同 hash 直接命中', () async {
      final vault = _vault();
      final creds = _creds(userId: 'u-9');
      final a1 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: creds,
      );
      final a2 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: Map.of(creds),
      );
      expect(a2.id, a1.id);
      final a3 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-10'),
      );
      expect(a3.id, isNot(a1.id));
      expect((await vault.loadAll()), hasLength(2));
    });

    test('fallback 命名：email → username → provider', () async {
      final vault = _vault();
      final a1 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-1', email: 'e@t.invalid'),
      );
      expect(a1.name, 'e@t.invalid');
      final a2 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-2', name: 'nn'),
      );
      expect(a2.name, 'nn');
      final a3 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-3'),
      );
      expect(a3.name, 'zai_cn');
    });
  });

  group('存储与保全序', () {
    test('写入序：索引先于条目（防丢号保全序）', () async {
      final store = _MemStore();
      final vault = _vault(store: store);
      await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-1'),
      );
      final iIdx = store.writeOrder.indexOf('zremote.account.index');
      final iEntry = store.writeOrder.indexOf('zremote.account.uuid-1');
      expect(iIdx, isNonNegative);
      expect(iEntry, isNonNegative);
      expect(iIdx, lessThan(iEntry));
    });

    test('loadAll：条目缺失/坏 JSON 跳过不炸', () async {
      final store = _MemStore();
      final vault = _vault(store: store);
      await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-1'),
      );
      await store.write('zremote.account.uuid-2', 'not-json');
      final all = await vault.loadAll();
      expect(all, hasLength(1));
    });

    test('remove 同步清绑定', () async {
      final store = _MemStore();
      final vault = _vault(store: store);
      final a = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-1'),
      );
      await vault.setActiveForDevice('dev-1', a.id);
      expect(await vault.activeAccountIdFor('dev-1'), a.id);
      await vault.remove(a.id);
      expect(await vault.activeAccountIdFor('dev-1'), isNull);
      expect(await vault.loadAll(), isEmpty);
    });

    test('preserveRawEntries：无 token/无 provider 返回 null；有则入库', () async {
      final vault = _vault();
      expect(await vault.preserveRawEntries({}), isNull);
      expect(
        await vault.preserveRawEntries({'zcodejwttoken': 'x'}),
        isNull,
      );
      final a = await vault.preserveRawEntries(_creds(userId: 'u-p'));
      expect(a, isNotNull);
      expect((await vault.loadAll()), hasLength(1));
    });

    test('jwtExpAtMs 从 zcodejwttoken 解析并落库', () async {
      final vault = _vault();
      final a = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(jwt: _fakeJwt(expSec: 1893456000)),
      );
      expect(a.jwtExpAtMs, 1893456000000);
    });

    test('Account.toJson/fromJson 往返 + 坏形状 null', () {
      final account = Account(
        id: 'i',
        name: 'n',
        provider: 'zai',
        credentials: const {'zcodejwttoken': 'j'},
        hash: 'h',
        jwtExpAtMs: 123,
        virtualDeviceMid: 'm',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );
      final back = Account.fromJson(account.toJson());
      expect(back!.id, 'i');
      expect(back.provider, 'zai');
      expect(back.jwtExpAtMs, 123);
      expect(Account.fromJson({'id': 1}), isNull);
      expect(Account.fromJson({'id': 'i', 'provider': 'zai', 'credentials': 3, 'hash': 'h'}), isNull);
    });
  });

  group('.zsb 导出导入往返', () {
    test('往返：加解密互逆 + 外层形状断言', () async {
      final store = _MemStore();
      final vault = _vault(store: store);
      final a1 = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-1', email: 'one@t.invalid'),
        name: '一号',
      );
      final a2 = await vault.upsertFromCredentials(
        provider: 'bigmodel',
        credentials: _creds(provider: 'bigmodel', userId: 'u-2'),
        name: '二号',
      );
      final bytes = await vault.exportBundle('secret-pass', [a1, a2]);
      final outer = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(outer['format'], 'zsw-accounts-bundle');
      expect(outer['version'], 1);
      final kdf = outer['kdf'] as Map<String, dynamic>;
      expect(kdf['algo'], 'pbkdf2-hmac-sha256');
      expect(kdf['iters'], 100000);
      expect(base64.decode(kdf['salt'] as String), hasLength(16));
      final cipher = outer['cipher'] as Map<String, dynamic>;
      expect(cipher['algo'], 'aes-256-gcm');
      expect(base64.decode(cipher['nonce'] as String), hasLength(12));
      expect(base64.decode(cipher['tag'] as String), hasLength(16));
      expect((cipher['data'] as String).isNotEmpty, isTrue);

      // 空库导入 → 2 added。
      final freshVault = _vault();
      final report = await freshVault.importBundle(bytes, 'secret-pass');
      expect(report.added, ['一号', '二号']);
      expect(report.skipped, isEmpty);
      final bytesText = utf8.decode(bytes);
      expect(bytesText.contains(a1.virtualDeviceMid), isFalse);
      expect(bytesText.contains(a1.id), isFalse);
      expect(bytesText.contains(a1.hash), isFalse);
      final loaded = await freshVault.loadAll();
      expect(loaded, hasLength(2));
      expect(loaded.first.credentials['zcodejwttoken'], a1.jwt);
      expect(loaded.first.virtualDeviceMid, isNotEmpty);
    });

    test('错密码 → wrongPassword 标记的失败', () async {
      final vault = _vault();
      final bytes = await vault.exportBundle('right-pass', []);
      final fresh = _vault();
      await expectLater(
        fresh.importBundle(bytes, 'wrong-pass'),
        throwsA(
          isA<ZsbFormatException>().having((e) => e.wrongPassword, 'wrongPassword', isTrue),
        ),
      );
    });

    test('密码 <6 位导出拒绝', () async {
      final vault = _vault();
      await expectLater(
        vault.exportBundle('12345', []),
        throwsA(isA<ZsbFormatException>()),
      );
    });

    test('重复导入按身份去重：added/skipped 报告', () async {
      final vault = _vault();
      final a = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-dup', email: 'dup@t.invalid'),
        name: '原账号',
      );
      final bytes = await vault.exportBundle('secret-pass', [a]);
      final report = await vault.importBundle(bytes, 'secret-pass');
      expect(report.added, isEmpty);
      expect(report.skipped, ['原账号']);
      expect((await vault.loadAll()), hasLength(1));
    });
  });

  group('.zsb 形状漂移 fixture（三类 + 外层校验）', () {
    Future<Object?> tryImport(Map<String, dynamic> outer) async {
      final vault = _vault();
      try {
        await vault.importBundle(
          Uint8List.fromList(utf8.encode(jsonEncode(outer))),
          'secret-pass',
        );
        return null;
      } catch (e) {
        return e;
      }
    }

    test('format/version/kdf/cipher 逐项校验', () async {
      final good = {
        'format': 'zsw-accounts-bundle',
        'version': 1,
        'kdf': {'algo': 'pbkdf2-hmac-sha256', 'iters': 1, 'salt': base64.encode(List.filled(16, 1))},
        'cipher': {
          'algo': 'aes-256-gcm',
          'nonce': base64.encode(List.filled(12, 2)),
          'tag': base64.encode(List.filled(16, 3)),
          'data': base64.encode(List.filled(8, 4)),
        },
      };
      expect(await tryImport({...good, 'format': 'other-bundle'}), isA<ZsbFormatException>());
      expect(await tryImport({...good, 'version': 2}), isA<ZsbFormatException>());
      expect(await tryImport({...good, 'kdf': null}), isA<ZsbFormatException>());
      expect(
        await tryImport({
          ...good,
          'kdf': {...good['kdf'] as Map, 'salt': 'too-short'},
        }),
        isA<ZsbFormatException>(),
      );
      expect(await tryImport({...good, 'cipher': {'algo': 'aes-128'}}), isA<ZsbFormatException>());
    });

    test('坏 tag（篡改密文）→ 认证失败', () async {
      final vault = _vault();
      final a = await vault.upsertFromCredentials(
        provider: 'zai_cn',
        credentials: _creds(userId: 'u-t'),
      );
      final bytes = await vault.exportBundle('secret-pass', [a]);
      final outer = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final cipher = Map<String, dynamic>.from(outer['cipher'] as Map);
      cipher['tag'] = base64.encode(List.filled(16, 9));
      outer['cipher'] = cipher;
      final fresh = _vault();
      await expectLater(
        fresh.importBundle(
          Uint8List.fromList(utf8.encode(jsonEncode(outer))),
          'secret-pass',
        ),
        throwsA(isA<ZsbFormatException>()),
      );
    });
  });

  group('.zsb 跨端互导 fixture（独立构造外层，不依赖本仓导出路径）', () {
    test('按 zcode-switch 形状手搓的外层可被导入', () async {
      // 用 cryptography 原语独立加密（模拟桌面端导出路径），内层为
      // zcode-accounts-bundle v2（不含 id/hash/mid）。
      const password = 'secret-pass';
      final salt = List<int>.generate(16, (i) => i);
      final nonce = List<int>.generate(12, (i) => 0x40 + i);
      final inner = {
        'format': 'zcode-accounts-bundle',
        'version': 2,
        'exportedAt': '2026-11-15T09:00:00.000',
        'accounts': [
          {
            'name': '桌面导出',
            'createdAt': '2026-10-01T08:00:00.000',
            'credentials': {
              'zcodejwttoken': _fakeJwt(expSec: 1893456000),
              'oauth:active_provider': 'zai',
              'oauth:zai:access_token': 'at-desktop',
              'oauth:zai:user_info': '{"user_id":"desk-1","email":"d@t.invalid"}',
            },
            'config': null,
          },
        ],
      };
      final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256);
      final key = await kdf.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(jsonEncode(inner)),
        secretKey: key,
        nonce: nonce,
      );
      final outer = {
        'format': 'zsw-accounts-bundle',
        'version': 1,
        'kdf': {
          'algo': 'pbkdf2-hmac-sha256',
          'iters': 100000,
          'salt': base64.encode(salt),
        },
        'cipher': {
          'algo': 'aes-256-gcm',
          'nonce': base64.encode(box.nonce),
          'tag': base64.encode(box.mac.bytes),
          'data': base64.encode(box.cipherText),
        },
      };
      final vault = _vault();
      final report = await vault.importBundle(
        Uint8List.fromList(utf8.encode(jsonEncode(outer))),
        password,
      );
      expect(report.added, ['桌面导出']);
      final all = await vault.loadAll();
      expect(all.single.provider, 'zai');
      expect(all.single.credentials['oauth:zai:access_token'], 'at-desktop');
      expect(all.single.jwtExpAtMs, 1893456000000);
      // 内层不带 id/hash/mid → 落库时补齐。
      expect(all.single.id, isNotEmpty);
      expect(all.single.hash, isNotEmpty);
      expect(all.single.virtualDeviceMid, isNotEmpty);
    });
  });

  group('注入键序列化', () {
    test('五键 + user_info 全在场：逐键 setItem，IIFE 包裹，无注释序列', () {
      final account = Account(
        id: 'i',
        name: 'n',
        provider: 'zai_cn',
        credentials: {
          'zcodejwttoken': 'jwt"x',
          'oauth:active_provider': 'zai_cn',
          'oauth:zai_cn:access_token': 'at',
          'oauth:zai_cn:user_info': '{"user_id":"u"}',
          'oauth:bigmodel:refresh_token': 'rt',
          'web-remote-control:flags': 'noise',
        },
        hash: 'h',
        virtualDeviceMid: 'm',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final script = AccountVault.credentialInjectScript(account);
      expect(script.startsWith('(function(){try{'), isTrue);
      expect(script.endsWith('}catch(e){}})()'), isTrue);
      expect(script.contains('://'), isFalse);
      expect(script.contains('//'), isFalse);
      expect(script.contains('/*'), isFalse);
      expect(
        script.contains(
          'window.localStorage.setItem("zcodejwttoken","jwt\\"x")',
        ),
        isTrue,
      );
      expect(
        script.contains('window.localStorage.setItem("oauth:active_provider","zai_cn")'),
        isTrue,
      );
      expect(
        script.contains('window.localStorage.setItem("oauth:zai_cn:user_info","{\\"user_id\\":\\"u\\"}")'),
        isTrue,
      );
      // refresh_token 与 web-remote-control:* 不在注入键面。
      expect(script.contains('refresh_token'), isFalse);
      expect(script.contains('web-remote-control'), isFalse);
    });

    test('空凭据 → 空脚本', () {
      final account = Account(
        id: 'i',
        name: 'n',
        provider: 'zai_cn',
        credentials: const {},
        hash: 'h',
        virtualDeviceMid: 'm',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(AccountVault.credentialInjectScript(account), isEmpty);
    });

    test('清除脚本覆盖全部可读键', () {
      final script = AccountVault.credentialClearScript();
      for (final k in AccountVault.readableKeys) {
        expect(script.contains('removeItem(${jsonEncode(k)})'), isTrue);
      }
      expect(script.contains('//'), isFalse);
      expect(script.contains('/*'), isFalse);
    });

    test('回读脚本与解析配对', () {
      final script = AccountVault.credentialReadScript();
      expect(script.startsWith('(function(){'), isTrue);
      expect(script.contains('//'), isFalse);
      expect(script.contains('/*'), isFalse);
      final parsed = AccountVault.parseReadResult(
        '{"zcodejwttoken":"j","oauth:active_provider":"zai_cn"}',
      );
      expect(parsed['zcodejwttoken'], 'j');
      expect(parsed['oauth:active_provider'], 'zai_cn');
      expect(AccountVault.parseReadResult(null), isEmpty);
      expect(AccountVault.parseReadResult('not json'), isEmpty);
      expect(AccountVault.parseReadResult('[]'), isEmpty);
    });

    test('applyToDevice 返回注入脚本（服务方法签名）', () {
      final account = Account(
        id: 'i',
        name: 'n',
        provider: 'zai_cn',
        credentials: {'zcodejwttoken': 'j', 'oauth:active_provider': 'zai_cn'},
        hash: 'h',
        virtualDeviceMid: 'm',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final device = RemoteDevice(
        id: 'dev',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'sid': 's', 'app_version': '3.18.2'},
        label: '',
        createdAt: DateTime(2026),
        kind: DeviceKind.v2,
      );
      final script = AccountVault.applyToDevice(account, device);
      expect(script.contains('zcodejwttoken'), isTrue);
    });
  });

  group('过期标签判定', () {
    Account accountOfExp(int? expMs) => Account(
      id: 'i',
      name: 'n',
      provider: 'zai_cn',
      credentials: const {},
      hash: 'h',
      jwtExpAtMs: expMs,
      virtualDeviceMid: 'm',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    test('needsRelogin / expiringSoon 边界', () {
      expect(accountOfExp(null).needsRelogin, isFalse);
      expect(accountOfExp(null).expiringSoon, isFalse);
      final far = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      expect(accountOfExp(far).needsRelogin, isFalse);
      expect(accountOfExp(far).expiringSoon, isFalse);
      final soon = DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
      expect(accountOfExp(soon).needsRelogin, isFalse);
      expect(accountOfExp(soon).expiringSoon, isTrue);
      final past = DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
      expect(accountOfExp(past).needsRelogin, isTrue);
      expect(accountOfExp(past).expiringSoon, isTrue);
    });
  });
}
