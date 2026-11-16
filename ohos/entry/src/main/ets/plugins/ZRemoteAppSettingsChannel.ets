import { MethodChannel, MethodCallHandler, MethodCall, MethodResult, BinaryMessenger } from '@ohos/flutter_ohos';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';

/**
 * zremote/app（鸿蒙车道 C）。
 *
 * 对齐 Android MainActivity 的 openAppSettings：跳转本应用的应用信息页
 * （系统设置），OH 走系统设置应用的 action.settings.app.info 隐式 want，
 * parameters.appId 传本应用 bundleName。失败返回 error('open_failed')，
 * Dart 侧 AppSettings.open 会 catch 后静默降级。
 */
const CHANNEL_NAME = 'zremote/app';

export class ZRemoteAppSettingsChannel {
  private channel: MethodChannel | null = null;
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  register(messenger: BinaryMessenger): void {
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(new ZRemoteAppSettingsHandler(this));
  }

  openAppSettings(result: MethodResult): void {
    const want: Want = {
      action: 'action.settings.app.info',
      parameters: { 'appId': this.context.abilityInfo.bundleName },
    };
    this.context.startAbility(want)
      .then(() => {
        result.success(null);
      })
      .catch((err: BusinessError) => {
        result.error('open_failed', `${err.code}: ${err.message}`, null);
      });
  }
}

class ZRemoteAppSettingsHandler implements MethodCallHandler {
  private readonly owner: ZRemoteAppSettingsChannel;

  constructor(owner: ZRemoteAppSettingsChannel) {
    this.owner = owner;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'openAppSettings') {
      this.owner.openAppSettings(result);
    } else {
      result.notImplemented();
    }
  }
}
