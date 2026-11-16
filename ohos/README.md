# ohos/ 鸿蒙平台工程（HarmonyOS NEXT）

> **状态：模板对齐的参考骨架，未经工具链验证（not run）。**
> 本机未安装 DevEco Studio / OpenHarmony SDK。本目录已按 CPF-Flutter
> `flutter create --platforms ohos` 的**模板产物对齐**（来源：GitHub 镜像
> `zhongdaiqi/flutter_flutter` 的 `packages/flutter_tools/templates/app_shared/ohos.tmpl/`），
> 并叠加本项目定制。**首跑前仍建议用官方模板重新生成并 diff**：
>
> ```bash
> # 用 Flutter-OH SDK（CPF-Flutter/flutter_flutter，锁 tag）执行：
> flutter create --platforms ohos --project-name zremotex .
> ```
>
> 冲突处**以官方模板为准**，再把下面的定制合并回去。

## 相对模板的定制（合并清单）

1. **bundleName**：`cn.song.zremote`（与 Android `applicationId`、iOS bundle id 一致，
   保证账号/深链 bound 不分裂）。`versionCode`/`versionName` 与 `pubspec.yaml` 同步。
2. **权限**（`entry/src/main/module.json5` `requestPermissions`）：
   - `ohos.permission.INTERNET`（模板自带）
   - `ohos.permission.CAMERA`（扫码导入）
   - `ohos.permission.ACCESS_BIOMETRIC`（生物识别门禁）
   - `ohos.permission.FOREGROUND_SERVICE`（保活）
3. **深链**（`module.json5` 第二个 `skills` 条目 `uris`）：
   - `zrsong://import`（自定义 scheme 兜底）
   - `https://zcode.z.ai/remote*`（App Links）
4. **应用名/资源**：`AppScope` 与 `entry` 的 `string.json` 均写 `ZRemoteX`；
   `color.json` 启动背景 `#0B0B0C`（对齐 Android 启动背景）；
   `media/app_icon.png` / `media/icon.png` 暂用 `assets/brand/mark.png`（占位，
   正式图标待替换）。
5. **原生通道 ohos 实现**（对齐 Android 的 `MainActivity.kt`，**尚未实现**）：
   - `zremote/deeplink`：冷启动 `want` 参数 + `onNewWant`
   - `zremote/keepalive`：前台服务 / 长时任务
   - `zremote/app`：跳系统应用设置
6. **签名**：`build-profile.json5` 的 `signingConfigs` 由 DevEco「自动生成签名」或
   CI secrets 注入；未签名包只能验证构建，不能安装。

## 构建

```bash
flutter build hap --debug
flutter build hap --release --no-codesign   # 未签名，仅验证可构建
```

产物：`build/ohos/hap/entry-default-unsigned.hap`。

## 生成态文件（不提交）

`ohos/entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets`、`ohos/hvigor/hvigor-wrapper.js`、
`ohos/oh_modules/`、`ohos/.hvigor/`、`ohos/build/` 等由工具生成，见 `.gitignore`。

## 参考

- CPF-Flutter/flutter_flutter：https://gitcode.com/CPF-Flutter/flutter_flutter
- 文档：https://gitcode.com/CPF-Flutter/flutter_samples/tree/master/docs/ohos
- 开发计划：`docs/开发计划/20261116-1434-鸿蒙NEXT全面支持-开发计划.md`
