import { MethodChannel, MethodCallHandler, MethodCall, MethodResult, BinaryMessenger } from '@ohos/flutter_ohos';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';

/**
 * zremote/deeplink（鸿蒙车道 C）。
 *
 * 对齐 Android MainActivity 的语义：
 * - 冷启动：EntryAbility.onCreate 里的 want.uri 作为 initial 返回；
 * - 热启动：EntryAbility.onNewWant 里的 want.uri 经 invokeMethod('onLink') 推给 Dart；
 * - Dart 侧未就绪时到达的链接先进 pendingLink，initial 调用带出后清空。
 * 白名单过滤（zrsong://import / https://zcode.z.ai/remote*）在 Dart 侧
 * extractRemoteLink 做，原生侧只透传原始 uri，与 Android 一致。
 */
const CHANNEL_NAME = 'zremote/deeplink';

export class ZRemoteDeepLinkChannel {
  private channel: MethodChannel | null = null;
  private readonly context: common.UIAbilityContext;
  // 冷启动深链（可为空串，表示非深链启动）
  private readonly coldLink: string;
  // Dart 侧就绪前到达的热启动链接缓存
  private pendingLink: string = '';

  constructor(context: common.UIAbilityContext, coldLink: string) {
    this.context = context;
    this.coldLink = coldLink ?? '';
  }

  register(messenger: BinaryMessenger): void {
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(new ZRemoteDeepLinkHandler(this));
  }

  onNewWant(want: Want): void {
    const uri: string = want.uri ?? '';
    if (uri.length === 0) {
      return;
    }
    if (this.channel != null) {
      // 与 Android 对齐：通道已建则直接推送（Dart 未 set handler 前到达的
      // 推送会被引擎丢弃，与 Android 同形态，属可接受窗口）。
      this.channel.invokeMethod('onLink', uri);
    } else {
      this.pendingLink = uri;
    }
  }

  handleInitial(result: MethodResult): void {
    const data: string = this.pendingLink.length > 0 ? this.pendingLink : this.coldLink;
    this.pendingLink = '';
    result.success(data.length > 0 ? data : null);
  }
}

class ZRemoteDeepLinkHandler implements MethodCallHandler {
  private readonly owner: ZRemoteDeepLinkChannel;

  constructor(owner: ZRemoteDeepLinkChannel) {
    this.owner = owner;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'initial') {
      this.owner.handleInitial(result);
    } else {
      result.notImplemented();
    }
  }
}
