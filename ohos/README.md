# ohos/ 鸿蒙平台工程（HarmonyOS NEXT）

> **状态：参考骨架，未经工具链验证（not run）。**
> 本机未安装 DevEco Studio / OpenHarmony SDK，本目录文件按 CPF-Flutter
> `flutter create --platforms ohos` 的产物结构手写，**首跑前必须用官方模板
> 校准**：
>
> ```bash
> # 用 Flutter-OH SDK（CPF-Flutter/flutter_flutter，锁 tag）执行：
> flutter create --platforms ohos --project-name zremotex .
> ```
>
> 生成后以本目录的「必需定制」清单逐项合并（bundleName / 权限 / 深链 / 原生通道 /
> 签名），冲突处**以官方模板为准**。

## 必需定制（相对默认模板）

1. **bundleName**：`cn.song.zremote`（与 Android `applicationId`、iOS bundle id 一致，
   保证账号/深链 bound 不分裂）。`versionCode`/`versionName` 与 `pubspec.yaml` 同步。
2. **权限**（`entry/src/main/module.json5` `requestPermissions`）：
   - `ohos.permission.INTERNET`
   - `ohos.permission.CAMERA`（扫码导入）
   - `ohos.permission.ACCESS_BIOMETRIC`（生物识别门禁）
   - `ohos.permission.FOREGROUND_SERVICE` + 对应 `FOREGROUND_SERVICE_TYPE_*`（保活）
   - 通知权限（`ohos.permission.NOTIFICATION_CONTROLLER` 相关，按需）
3. **深链**（`module.json5` `skills`/`uris`）：
   - `zrsong://import`（自定义 scheme 兜底）
   - `https://zcode.z.ai/remote*`（App Links）
4. **原生通道 ohos 实现**（对齐 Android 的 `MainActivity.kt`）：
   - `zremote/deeplink`：冷启动 `want` 参数 + `onNewWant`
   - `zremote/keepalive`：前台服务 / 长时任务
   - `zremote/app`：跳系统应用设置
5. **签名**：`build-profile.json5` 的 `signingConfigs` 由 DevEco「自动生成签名」或
   CI secrets 注入；未签名包只能验证构建，不能安装。

## 构建

```bash
flutter build hap --debug
flutter build hap --release --no-codesign   # 未签名，仅验证可构建
```

产物：`build/ohos/hap/entry-default-unsigned.hap`。

## 参考

- CPF-Flutter/flutter_flutter：https://gitcode.com/CPF-Flutter/flutter_flutter
- 文档：https://gitcode.com/CPF-Flutter/flutter_samples/tree/master/docs/ohos
- 开发计划：`docs/开发计划/20261116-1434-鸿蒙NEXT全面支持-开发计划.md`
