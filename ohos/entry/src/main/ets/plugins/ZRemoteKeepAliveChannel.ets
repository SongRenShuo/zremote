import { MethodChannel, MethodCallHandler, MethodCall, MethodResult, BinaryMessenger } from '@ohos/flutter_ohos';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';

/**
 * zremote/keepalive（鸿蒙车道 C）。
 *
 * OH 没有 Android 式前台 Service，等价物是长时任务（连续任务）：
 * backgroundTaskManager.startBackgroundRunning(context, BackgroundMode.TASK_KEEPING,
 * wantAgent) / stopBackgroundRunning(context)。系统会自动发布常驻通知
 * （d.ts：System will publish a notification related to the UIAbility），
 * 故原生侧不再用 notificationManager 手工发布，避免重复通知。
 *
 * 电池优化白名单类方法（isBatteryIgnored / requestBatteryIgnore /
 * requestVendorExemption）在 OH 无对应系统 API：查询类返回 false、
 * 请求类返回 error('unsupported')，与 Dart 侧 KeepAliveService 的
 * catch-降级逻辑一致，不抛未捕获异常。
 */
const CHANNEL_NAME = 'zremote/keepalive';

export class ZRemoteKeepAliveChannel {
  private channel: MethodChannel | null = null;
  private readonly context: common.UIAbilityContext;
  private running: boolean = false;
  private lastStartBlocked: boolean = false;
  private cachedAgent: WantAgent | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  register(messenger: BinaryMessenger): void {
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(new ZRemoteKeepAliveHandler(this));
  }

  start(result: MethodResult): void {
    this.buildWantAgent()
      .then((agent: WantAgent) => {
        this.cachedAgent = agent;
        return backgroundTaskManager.startBackgroundRunning(
          this.context,
          backgroundTaskManager.BackgroundMode.TASK_KEEPING,
          agent,
        );
      })
      .then(() => {
        this.running = true;
        this.lastStartBlocked = false;
        result.success(null);
      })
      .catch((err: BusinessError) => {
        this.running = false;
        this.lastStartBlocked = true;
        result.error('start_failed', `${err.code}: ${err.message}`, null);
      });
  }

  stop(result: MethodResult): void {
    backgroundTaskManager.stopBackgroundRunning(this.context)
      .then(() => {
        this.running = false;
        result.success(null);
      })
      .catch((err: BusinessError) => {
        // 停止失败按停止语义收口（幂等），与 Android stopService 不报错对齐。
        this.running = false;
        result.success(null);
      });
  }

  isRunning(result: MethodResult): void {
    result.success(this.running);
  }

  isBlocked(result: MethodResult): void {
    result.success(this.lastStartBlocked);
  }

  isBatteryIgnored(result: MethodResult): void {
    // OH 无电池优化白名单概念，固定降级为 false。
    result.success(false);
  }

  requestBatteryIgnore(result: MethodResult): void {
    result.error('unsupported', 'battery optimization whitelist is not supported on HarmonyOS', null);
  }

  requestVendorExemption(result: MethodResult): void {
    result.error('unsupported', 'vendor battery exemption is not supported on HarmonyOS', null);
  }

  private buildWantAgent(): Promise<WantAgent> {
    if (this.cachedAgent != null) {
      return Promise.resolve(this.cachedAgent);
    }
    const want: Want = {
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: this.context.abilityInfo.name,
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    return wantAgent.getWantAgent(info);
  }
}

class ZRemoteKeepAliveHandler implements MethodCallHandler {
  private readonly owner: ZRemoteKeepAliveChannel;

  constructor(owner: ZRemoteKeepAliveChannel) {
    this.owner = owner;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'start') {
      this.owner.start(result);
    } else if (call.method === 'stop') {
      this.owner.stop(result);
    } else if (call.method === 'isRunning') {
      this.owner.isRunning(result);
    } else if (call.method === 'isBlocked') {
      this.owner.isBlocked(result);
    } else if (call.method === 'isBatteryIgnored') {
      this.owner.isBatteryIgnored(result);
    } else if (call.method === 'requestBatteryIgnore') {
      this.owner.requestBatteryIgnore(result);
    } else if (call.method === 'requestVendorExemption') {
      this.owner.requestVendorExemption(result);
    } else {
      result.notImplemented();
    }
  }
}
