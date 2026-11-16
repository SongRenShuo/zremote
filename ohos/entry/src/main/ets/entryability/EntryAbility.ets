import { FlutterAbility, FlutterEngine, BinaryMessenger } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { ZRemoteDeepLinkChannel } from '../plugins/ZRemoteDeepLinkChannel';
import { ZRemoteKeepAliveChannel } from '../plugins/ZRemoteKeepAliveChannel';
import { ZRemoteAppSettingsChannel } from '../plugins/ZRemoteAppSettingsChannel';

/**
 * ZRemoteX 鸿蒙入口 Ability。
 *
 * 注册三条手写 MethodChannel（对齐 Android MainActivity 语义）：
 * - zremote/deeplink：冷启动 want.uri / onNewWant 热启动链接；
 * - zremote/keepalive：长时任务（TASK_KEEPING）后台守护；
 * - zremote/app：跳转系统设置应用信息页。
 */
export default class EntryAbility extends FlutterAbility {
  private deepLinkChannel: ZRemoteDeepLinkChannel | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
    const uri: string = want.uri ?? '';
    this.deepLinkChannel = new ZRemoteDeepLinkChannel(this.context, uri);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onNewWant(want, launchParam);
    if (this.deepLinkChannel != null) {
      this.deepLinkChannel.onNewWant(want);
    }
  }

  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    const messenger: BinaryMessenger = flutterEngine.dartExecutor.getBinaryMessenger();
    if (this.deepLinkChannel == null) {
      // 防御：极端路径下 onCreate 未先走（如引擎复用），冷链按空处理。
      this.deepLinkChannel = new ZRemoteDeepLinkChannel(this.context, '');
    }
    this.deepLinkChannel.register(messenger);
    new ZRemoteKeepAliveChannel(this.context).register(messenger);
    new ZRemoteAppSettingsChannel(this.context).register(messenger);
  }
}
