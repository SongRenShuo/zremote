import { FlutterAbility } from '@ohos/flutter_ohos';

// Flutter-OH 的 FlutterAbility 已接管引擎创建、页面路由与 want 转发。
// 如需实现 zremote/deeplink / zremote/keepalive / zremote/app 通道，
// 在子类里覆写对应生命周期并接入 @ohos/flutter_ohos 的引擎句柄。
// 本文件以 flutter create --platforms ohos 的生成结果为准。
export default class EntryAbility extends FlutterAbility {}
