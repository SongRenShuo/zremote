import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 深链导入（P4-1，开发计划 20261115-0901）。
///
/// 原生侧（MainActivity）把 VIEW intent 的 dataString 经
/// MethodChannel('zremote/deeplink') 送上来：冷启动走 `initial` 拉取，
/// 热启动（singleTop onNewIntent）走 `onLink` 推送。
/// 白名单对齐官方壳 App 的 RemoteControlUrlPolicy：只接受
/// `https://zcode.z.ai/remote*`（或其 zrsong://import?url= 包装，
/// 兼容旧 zremote://import 包装）。
class DeepLinkService {
  static const MethodChannel _channel = MethodChannel('zremote/deeplink');
  static final List<void Function(String)> _listeners = [];

  /// 冷启动 intent 里的链接；无 / 平台未实现 / 非深链启动时返回 null。
  static Future<String?> initialLink() async {
    try {
      return await _channel.invokeMethod<String>('initial');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 热启动链接回调；测试环境可重复注册（后注册者也会收到）。
  static void listen(void Function(String) onLink) {
    _listeners.add(onLink);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        for (final cb in List.of(_listeners)) {
          cb(call.arguments as String);
        }
      }
      return null;
    });
  }

  /// 仅测试用：清空 listen 注册的回调。
  @visibleForTesting
  static void resetListenersForTest() => _listeners.clear();
}

/// 白名单提取：合法时返回可直接交给 [LinkBuilder.parse] 的 https 链接；
/// 不合规返回 null。
///
/// 规则（官方壳 RemoteControlUrlPolicy.kt 对齐）：
/// - `https://zcode.z.ai/remote` 或 `https://zcode.z.ai/remote/...`（v2/v4/legacy 均此形态）
/// - 包装形态 `zrsong://import?url=<urlencoded 上述链接>`（新 scheme）
/// - 兼容形态 `zremote://import?url=<urlencoded 上述链接>`（旧 scheme，仍接受）
/// - 其余一律拒绝（host 白名单外的 https、http、file、remote 前缀撞名如 /remotefoo）
String? extractRemoteLink(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return null;

  bool isRemotePath(Uri u) =>
      u.path == '/remote' || u.path.startsWith('/remote/');

  if (uri.scheme == 'https') {
    if (uri.host != 'zcode.z.ai') return null;
    if (!isRemotePath(uri)) return null;
    return trimmed;
  }
  if ((uri.scheme == 'zrsong' || uri.scheme == 'zremote') &&
      uri.host == 'import') {
    final target = uri.queryParameters['url'];
    if (target == null) return null;
    final inner = Uri.tryParse(target);
    if (inner == null) return null;
    if (inner.scheme != 'https' || inner.host != 'zcode.z.ai') return null;
    if (!isRemotePath(inner)) return null;
    return target;
  }
  return null;
}
