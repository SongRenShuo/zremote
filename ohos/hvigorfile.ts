import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { FlutterHvigorPlugin } from 'flutter-hvigor-plugin';

// flutter-hvigor-plugin 由 Flutter-OH 工具在 build 时注入/调用。
// 若插件名或导入路径与 SDK 版本不符，以 flutter create 生成的 hvigorfile.ts 为准。
export default {
  system: appTasks,
  plugins: [new FlutterHvigorPlugin()],
};
