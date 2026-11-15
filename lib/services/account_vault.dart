import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import 'zai_auth_client.dart';

/// 账号模型（计划 §2.2，字段与 zcode-switch 逐一对齐）。
@immutable
class Account {
  const Account({
    required this.id,
    required this.name,
    required this.provider,
    required this.credentials,
    required this.hash,
    required this.virtualDeviceMid,
    required this.createdAt,
    required this.updatedAt,
    this.jwtExpAtMs,
  });

  final String id;
  final String name;

  /// `bigmodel|zai|zai_cn`（wire 名）。
  final String provider;

  /// 键名与远控页 localStorage 一致：
  /// `zcodejwttoken`、`oauth:active_provider`、`oauth:<p>:access_token`、
  /// `oauth:<p>:refresh_token?`、`oauth:<p>:user_info`（JSON 串）。
  final Map<String, String> credentials;

  /// SHA256(credentials 去 `web-remote-control:*` 键的 canonical JSON)。
  final String hash;

  final int? jwtExpAtMs;
  final String virtualDeviceMid;
  final DateTime createdAt;
  final DateTime updatedAt;

  String? get jwt => credentials['zcodejwttoken'];

  bool get needsRelogin {
    final exp = jwtExpAtMs;
    if (exp == null) return false;
    return ZaiAuthClient.isJwtExpired(exp);
  }

  bool get expiringSoon {
    final exp = jwtExpAtMs;
    if (exp == null) return false;
    return ZaiAuthClient.isJwtExpiringWithin(exp);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider,
    'credentials': credentials,
    'hash': hash,
    'jwtExpAtMs': jwtExpAtMs,
    'virtualDeviceMid': virtualDeviceMid,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static Account? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final provider = json['provider'];
    final creds = json['credentials'];
    final hash = json['hash'];
    if (id is! String ||
        id.isEmpty ||
        provider is! String ||
        creds is! Map ||
        hash is! String) {
      return null;
    }
    final credentials = <String, String>{};
    creds.forEach((k, v) {
      if (k is String && v is String) credentials[k] = v;
    });
    DateTime? parse(Object? v) =>
        v is String ? DateTime.tryParse(v) : null;
    final created = parse(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return Account(
      id: id,
      name: json['name'] is String ? json['name'] as String : '',
      provider: provider,
      credentials: credentials,
      hash: hash,
      jwtExpAtMs: json['jwtExpAtMs'] is int ? json['jwtExpAtMs'] as int : null,
      virtualDeviceMid: json['virtualDeviceMid'] is String
          ? json['virtualDeviceMid'] as String
          : '',
      createdAt: created,
      updatedAt: parse(json['updatedAt']) ?? created,
    );
  }

  Account copyWith({
    String? name,
    Map<String, String>? credentials,
    String? hash,
    int? jwtExpAtMs,
    DateTime? updatedAt,
  }) => Account(
    id: id,
    name: name ?? this.name,
    provider: provider,
    credentials: credentials ?? this.credentials,
    hash: hash ?? this.hash,
    jwtExpAtMs: jwtExpAtMs ?? this.jwtExpAtMs,
    virtualDeviceMid: virtualDeviceMid,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) => other is Account && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 身份匹配（计划 §2.2 三级回退：user_id → email → provider+username）。
@immutable
class AccountIdentity {
  const AccountIdentity({
    this.userId = '',
    this.email = '',
    this.username = '',
    this.provider = '',
  });

  final String userId;
  final String email;
  final String username;
  final String provider;

  static AccountIdentity of(Account account) {
    var userId = '';
    var email = '';
    var username = '';
    final raw = account.credentials['oauth:${account.provider}:user_info'] ??
        account.credentials['oauth:zai:user_info'];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          userId = decoded['user_id'] is String ? decoded['user_id'] as String : '';
          email = decoded['email'] is String ? decoded['email'] as String : '';
          username = decoded['name'] is String ? decoded['name'] as String : '';
        }
      } catch (_) {}
    }
    return AccountIdentity(
      userId: userId,
      email: email,
      username: username,
      provider: account.provider,
    );
  }

  /// 三级回退匹配：命中返回 true。两侧同字段为空不算命中。
  bool matches(AccountIdentity other) {
    if (userId.isNotEmpty && userId == other.userId) return true;
    if (email.isNotEmpty && email == other.email) return true;
    if (username.isNotEmpty &&
        username == other.username &&
        provider.isNotEmpty &&
        provider == other.provider) {
      return true;
    }
    return false;
  }
}

/// 键值存储抽象（产品 flutter_secure_storage，单测内存假实现）。
abstract class SecureStringStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStringStore implements SecureStringStore {
  const FlutterSecureStringStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// `.zsb` 导入结果报告。
class ZsbImportReport {
  const ZsbImportReport({required this.added, required this.skipped});

  final List<String> added;
  final List<String> skipped;
}

class ZsbFormatException implements Exception {
  const ZsbFormatException(this.message, {this.wrongPassword = false});

  final String message;

  /// 密码错误（GCM tag 校验失败）与文件损坏区分标记。
  final bool wrongPassword;

  @override
  String toString() => 'ZsbFormatException($message)';
}

/// 账号库：CRUD、hash 身份匹配、`.zsb` 加密互导、localStorage 注入供票。
///
/// 存储键：条目 `zremote.account.<id>`、索引 `zremote.account.index`。
/// 写入走「先写索引后写条目」的保全序——索引先行保证条目即使中途
/// 失败也能被下次 loadAll 发现并按缺失跳过，不会静默丢账号。
class AccountVault {
  AccountVault({
    SecureStringStore? store,
    String Function()? uuidGen,
    DateTime Function()? now,
    Random? random,
  }) : _store = store ?? const FlutterSecureStringStore(),
       _uuid = uuidGen ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  static const _indexKey = 'zremote.account.index';
  static const _entryPrefix = 'zremote.account.';

  /// localStorage 注入五键（远控页凭据仓契约，计划 §2.2）。
  static const injectableKeys = [
    'zcodejwttoken',
    'oauth:active_provider',
    'oauth:zai:access_token',
    'oauth:zai_cn:access_token',
    'oauth:bigmodel:access_token',
  ];

  /// 可选注入的 user_info 键（存在才写）。
  static const userInfoKeys = [
    'oauth:zai:user_info',
    'oauth:zai_cn:user_info',
    'oauth:bigmodel:user_info',
  ];

  /// 从 WebView localStorage 回读时可用的全集（含各 provider 派生键）。
  static const readableKeys = [
    ...injectableKeys,
    'oauth:zai:user_info',
    'oauth:zai_cn:user_info',
    'oauth:bigmodel:user_info',
    'oauth:bigmodel:refresh_token',
    'oauth:zai:refresh_token',
    'oauth:zai_cn:refresh_token',
  ];

  static final AccountVault instance = AccountVault();

  final SecureStringStore _store;
  final String Function() _uuid;
  final DateTime Function() _now;
  final Random _random;

  // ---- hash 与 canonical JSON ----

  /// canonical JSON：键排序后编码（顶层即字符串值，无嵌套排序问题）。
  static String canonicalCredentialsJson(Map<String, String> credentials) {
    final keys = credentials.keys
        .where((k) => !k.startsWith('web-remote-control:'))
        .toList()
      ..sort();
    return jsonEncode({for (final k in keys) k: credentials[k]});
  }

  static Future<String> computeHash(Map<String, String> credentials) async {
    final digest = await Sha256().hash(
      utf8.encode(canonicalCredentialsJson(credentials)),
    );
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- 存取 ----

  Future<List<Account>> loadAll() async {
    final raw = await _store.read(_indexKey);
    if (raw == null) return [];
    Map<String, dynamic> index;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return [];
      index = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return [];
    }
    final ids = index['ids'];
    if (ids is! List) return [];
    final accounts = <Account>[];
    for (final id in ids) {
      if (id is! String) continue;
      final entry = await _store.read('$_entryPrefix$id');
      if (entry == null) continue;
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic>) {
          final account = Account.fromJson(decoded);
          if (account != null) accounts.add(account);
        }
      } catch (_) {}
    }
    return accounts;
  }

  /// 设备 → 账号绑定全集（AccountsNotifier 同步 UI 用）。
  Future<Map<String, String>> loadActiveBindings() => _readActiveMap();

  Future<Map<String, String>> _readActiveMap() async {
    final raw = await _store.read(_indexKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final active = decoded['active'];
      if (active is! Map) return {};
      return active.map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeIndex(List<String> ids, Map<String, String> active) async {
    await _store.write(
      _indexKey,
      jsonEncode({
        'ids': ids,
        'active': active,
      }),
    );
  }

  /// 新建或身份命中后合并更新（同身份保 id，凭据新值覆盖旧值）。
  Future<Account> upsertFromCredentials({
    required String provider,
    required Map<String, String> credentials,
    String? name,
  }) async {
    final accounts = await loadAll();
    final hash = await computeHash(credentials);
    final identity = _identityOfCredentials(provider, credentials);
    final existing = _matchExisting(accounts, hash, identity);
    final jwt = credentials['zcodejwttoken'];
    final exp = jwt == null ? null : ZaiAuthClient.parseJwtExpMs(jwt);
    final now = _now();
    if (existing != null) {
      final merged = {...existing.credentials, ...credentials};
      final mergedHash = await computeHash(merged);
      final updated = existing.copyWith(
        name: (name != null && name.isNotEmpty) ? name : existing.name,
        credentials: merged,
        hash: mergedHash,
        jwtExpAtMs: exp ?? existing.jwtExpAtMs,
        updatedAt: now,
      );
      await _writeEntry(updated);
      return updated;
    }
    final account = Account(
      id: _uuid(),
      name: (name != null && name.isNotEmpty)
          ? name
          : _fallbackName(provider, identity),
      provider: provider,
      credentials: credentials,
      hash: hash,
      jwtExpAtMs: exp,
      virtualDeviceMid: _uuid(),
      createdAt: now,
      updatedAt: now,
    );
    await _appendEntry(account);
    return account;
  }

  /// 应用前保全：从设备 WebView 回读的 localStorage 键值保全为账号。
  /// 无 token 时返回 null（未登录，无号可保）。
  Future<Account?> preserveRawEntries(Map<String, String> entries) async {
    final token = entries['zcodejwttoken'];
    if (token == null || token.isEmpty) return null;
    final provider = entries['oauth:active_provider'];
    if (provider == null || provider.isEmpty) return null;
    return upsertFromCredentials(
      provider: provider,
      credentials: Map.of(entries),
    );
  }

  Future<void> remove(String id) async {
    final raw = await _store.read(_indexKey);
    var ids = <String>[];
    var active = <String, String>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final idList = decoded['ids'];
          if (idList is List) ids = idList.cast<String>().toList();
          final a = decoded['active'];
          if (a is Map) active = a.map((k, v) => MapEntry('$k', '$v'));
        }
      } catch (_) {}
    }
    ids.remove(id);
    active.removeWhere((_, v) => v == id);
    await _writeIndex(ids, active);
    await _store.delete('$_entryPrefix$id');
  }

  // ---- 设备 → 账号绑定（在用标记）----

  Future<String?> activeAccountIdFor(String deviceId) async {
    final active = await _readActiveMap();
    return active[deviceId];
  }

  Future<void> setActiveForDevice(String deviceId, String? accountId) async {
    final raw = await _store.read(_indexKey);
    var ids = <String>[];
    var active = <String, String>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final idList = decoded['ids'];
          if (idList is List) ids = idList.cast<String>().toList();
          final a = decoded['active'];
          if (a is Map) active = a.map((k, v) => MapEntry('$k', '$v'));
        }
      } catch (_) {}
    }
    if (accountId == null) {
      active.remove(deviceId);
    } else {
      active[deviceId] = accountId;
    }
    await _writeIndex(ids, active);
  }

  // ---- .zsb 导入导出 ----

  static const _zsbOuterFormat = 'zsw-accounts-bundle';
  static const _zsbInnerFormat = 'zcode-accounts-bundle';
  static const _kdfIters = 100000;

  Future<Uint8List> exportBundle(
    String password,
    List<Account> accounts, {
    int? saltBytes,
    int? nonceBytes,
  }) async {
    if (password.length < 6) {
      throw const ZsbFormatException('password too short');
    }
    final inner = {
      'format': _zsbInnerFormat,
      'version': 2,
      'exportedAt': _now().toIso8601String(),
      'accounts': [
        for (final a in accounts)
          {
            'name': a.name,
            'createdAt': a.createdAt.toIso8601String(),
            'credentials': a.credentials,
            'config': null,
          },
      ],
    };
    final salt = _randomBytes(saltBytes ?? 16);
    final nonce = _randomBytes(nonceBytes ?? 12);
    final key = await _deriveKey(password, salt);
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(inner)),
      secretKey: key,
      nonce: nonce,
    );
    final outer = {
      'format': _zsbOuterFormat,
      'version': 1,
      'kdf': {
        'algo': 'pbkdf2-hmac-sha256',
        'iters': _kdfIters,
        'salt': base64.encode(salt),
      },
      'cipher': {
        'algo': 'aes-256-gcm',
        'nonce': base64.encode(box.nonce),
        'tag': base64.encode(box.mac.bytes),
        'data': base64.encode(box.cipherText),
      },
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(outer)));
  }

  Future<ZsbImportReport> importBundle(
    Uint8List bytes,
    String password, {
    String Function(String provider, Map<String, String> credentials)?
    nameFallback,
  }) async {
    Map<String, dynamic> outer;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const ZsbFormatException('outer is not an object');
      }
      outer = decoded;
    } catch (e) {
      if (e is ZsbFormatException) rethrow;
      throw const ZsbFormatException('outer json broken');
    }
    _expect(outer['format'] == _zsbOuterFormat, 'unexpected outer format');
    _expect(outer['version'] == 1, 'unexpected outer version');
    final kdf = outer['kdf'];
    final cipher = outer['cipher'];
    _expect(kdf is Map, 'kdf missing');
    _expect(cipher is Map, 'cipher missing');
    final salt = _b64Field(kdf as Map, 'salt', 16);
    _expect((kdf['algo'] as String?) == 'pbkdf2-hmac-sha256', 'kdf algo');
    final iters = kdf['iters'];
    _expect(iters is int && iters >= 1, 'kdf iters');
    _expect((cipher as Map)['algo'] == 'aes-256-gcm', 'cipher algo');
    final nonce = _b64Field(cipher, 'nonce', 12);
    final tag = _b64Field(cipher, 'tag', 16);
    final data = _b64Field(cipher, 'data', 1);

    Map<String, dynamic> inner;
    try {
      final key = await _deriveKey(
        password,
        salt,
        iters: iters as int,
      );
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(data, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, dynamic>) {
        throw const ZsbFormatException('inner is not an object');
      }
      inner = decoded;
    } on SecretBoxAuthenticationError {
      throw const ZsbFormatException(
        'authentication failed',
        wrongPassword: true,
      );
    } catch (e) {
      if (e is ZsbFormatException) rethrow;
      throw const ZsbFormatException('decrypt failed');
    }
    _expect(inner['format'] == _zsbInnerFormat, 'unexpected inner format');
    _expect(inner['version'] == 2, 'unexpected inner version');
    final list = inner['accounts'];
    _expect(list is List, 'accounts missing');

    final added = <String>[];
    final skipped = <String>[];
    final existing = await loadAll();
    for (final item in list as List) {
      if (item is! Map) continue;
      final credentialsRaw = item['credentials'];
      if (credentialsRaw is! Map) continue;
      final credentials = <String, String>{};
      credentialsRaw.forEach((k, v) {
        if (k is String && v is String) credentials[k] = v;
      });
      if (credentials['zcodejwttoken'] == null) continue;
      final provider = credentials['oauth:active_provider'] ?? 'zai';
      final hash = await computeHash(credentials);
      final identity = _identityOfCredentials(provider, credentials);
      final dup = _matchExisting(existing, hash, identity);
      if (dup != null) {
        skipped.add(dup.name.isNotEmpty ? dup.name : dup.id);
        continue;
      }
      final name = item['name'] is String ? item['name'] as String : '';
      DateTime? created = item['createdAt'] is String
          ? DateTime.tryParse(item['createdAt'] as String)
          : null;
      final account = Account(
        id: _uuid(),
        name: name.isNotEmpty
            ? name
            : (nameFallback?.call(provider, credentials) ?? provider),
        provider: provider,
        credentials: credentials,
        hash: hash,
        jwtExpAtMs: () {
          final jwt = credentials['zcodejwttoken'];
          return jwt == null ? null : ZaiAuthClient.parseJwtExpMs(jwt);
        }(),
        virtualDeviceMid: _uuid(),
        createdAt: created ?? _now(),
        updatedAt: _now(),
      );
      await _appendEntry(account);
      existing.add(account);
      added.add(account.name);
    }
    return ZsbImportReport(added: added, skipped: skipped);
  }

  // ---- localStorage 注入 / 清除（供票）----

  /// 注入脚本：在已加载 zcode.z.ai origin 的 WebView 上执行。
  ///
  /// M0-1 同款纪律：脚本体内禁 `//` 与 `/*` 注释序列。
  static String credentialInjectScript(Account account) {
    final entries = <String, String>{};
    for (final k in [...injectableKeys, ...userInfoKeys]) {
      final v = account.credentials[k];
      if (v != null && v.isNotEmpty) entries[k] = v;
    }
    if (entries.isEmpty) return '';
    final buffer = StringBuffer('(function(){try{');
    for (final e in entries.entries) {
      buffer.write(
        'window.localStorage.setItem(${jsonEncode(e.key)},'
        '${jsonEncode(e.value)});',
      );
    }
    buffer.write('}catch(e){}})()');
    return buffer.toString();
  }

  /// 退出登录清除脚本：移除远控页凭据仓全部键（zcode.z.ai origin 执行）。
  static String credentialClearScript() {
    final buffer = StringBuffer('(function(){try{');
    for (final k in readableKeys) {
      buffer.write('window.localStorage.removeItem(${jsonEncode(k)});');
    }
    buffer.write('}catch(e){}})()');
    return buffer.toString();
  }

  /// 从 WebView 回读当前登录的取数脚本（zcode.z.ai origin 执行），
  /// 返回 JSON 串（键存在才收录）。
  static String credentialReadScript() {
    final keys = jsonEncode(readableKeys);
    return '(function(){try{var o={};var ks=$keys;'
        'for(var i=0;i<ks.length;i++){var v=window.localStorage.getItem(ks[i]);'
        'if(v!==null&&v!==undefined){o[ks[i]]=v}}'
        'return JSON.stringify(o)}catch(e){return "{}"}})()';
  }

  /// 回读结果解析（与 [credentialReadScript] 配对）。
  static Map<String, String> parseReadResult(String? raw) {
    if (raw == null) return {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return {};
    }
    if (decoded is! Map) return {};
    return {
      for (final e in decoded.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  // ---- 内部 ----

  static AccountIdentity _identityOfCredentials(
    String provider,
    Map<String, String> credentials,
  ) {
    final raw = credentials['oauth:$provider:user_info'] ??
        credentials['oauth:zai:user_info'];
    var userId = '';
    var email = '';
    var username = '';
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          userId = decoded['user_id'] is String ? decoded['user_id'] as String : '';
          email = decoded['email'] is String ? decoded['email'] as String : '';
          username = decoded['name'] is String ? decoded['name'] as String : '';
        }
      } catch (_) {}
    }
    return AccountIdentity(
      userId: userId,
      email: email,
      username: username,
      provider: provider,
    );
  }

  static Account? _matchExisting(
    List<Account> accounts,
    String hash,
    AccountIdentity identity,
  ) {
    for (final a in accounts) {
      if (a.hash == hash) return a;
      if (identity.matches(AccountIdentity.of(a))) return a;
    }
    return null;
  }

  String _fallbackName(String provider, AccountIdentity identity) {
    if (identity.email.isNotEmpty) return identity.email;
    if (identity.username.isNotEmpty) return identity.username;
    return provider;
  }

  Future<void> _appendEntry(Account account) async {
    final raw = await _store.read(_indexKey);
    var ids = <String>[];
    var active = <String, String>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final idList = decoded['ids'];
          if (idList is List) ids = idList.cast<String>().toList();
          final a = decoded['active'];
          if (a is Map) active = a.map((k, v) => MapEntry('$k', '$v'));
        }
      } catch (_) {}
    }
    if (!ids.contains(account.id)) ids.add(account.id);
    await _writeIndex(ids, active);
    await _store.write(
      '$_entryPrefix${account.id}',
      jsonEncode(account.toJson()),
    );
  }

  Future<void> _writeEntry(Account account) async {
    final raw = await _store.read(_indexKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final idList = decoded['ids'];
          if (idList is List && !idList.contains(account.id)) {
            final ids = idList.cast<String>().toList()..add(account.id);
            final a = decoded['active'];
            final active = a is Map
                ? a.map((k, v) => MapEntry('$k', '$v'))
                : <String, String>{};
            await _writeIndex(ids, active);
          }
        }
      } catch (_) {}
    }
    await _store.write(
      '$_entryPrefix${account.id}',
      jsonEncode(account.toJson()),
    );
  }

  Uint8List _randomBytes(int len) {
    final bytes = Uint8List(len);
    for (var i = 0; i < len; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  Future<SecretKey> _deriveKey(
    String password,
    Uint8List salt, {
    int iters = _kdfIters,
  }) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iters,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static void _expect(bool v, String what) {
    if (!v) throw ZsbFormatException('zsb: $what mismatch');
  }

  static Uint8List _b64Field(Map m, String key, int minLen) {
    final raw = m[key];
    if (raw is! String) throw ZsbFormatException('zsb: $key missing');
    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64.decode(raw));
    } on FormatException {
      throw ZsbFormatException('zsb: $key not base64');
    }
    if (bytes.length < minLen) {
      throw ZsbFormatException('zsb: $key too short');
    }
    return bytes;
  }

  /// 会话页调用入口：把账号注入设备 WebView（zcode.z.ai origin）后 reload。
  /// 返回注入脚本（调用方 evaluateJavascript 执行）。
  static String applyToDevice(Account account, RemoteDevice device) {
    debugPrint(
      '[zr-vault] apply account ${account.id} to device ${device.id}',
    );
    return credentialInjectScript(account);
  }
}
