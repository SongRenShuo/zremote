# 开发计划：V4 远控链接登录黑屏修复（window.open 弹窗支持）

> 日期：2026-11-14
> 状态：待实施
> 目标版本：v1.7.1

## 1. 背景与现象

- 2026-05 v1.7.0 已适配"无 hash V2 链接"（`?app_version=…&sid=…` 形态）。
- 最新版 ZCode（3.18.2）下发的远控链接为 v4 形态：

  ```
  https://zcode.z.ai/remote/v4?sid=d_RdqN4ET4W97rgGrBjM7Fiv&mid=009ec9cd-39cb-49c4-9bc4-30cf88b56e1a&name=SongRenShuo&app_version=3.18.2
  ```

- 现象：导入成功（`LinkBuilder.parse` 判定为 v2 设备），进入会话页后点击页面内"登录"按钮**没有反应**，页面黑屏，不跳转登录页。
- 影响：所有 v2 设备（含旧 `/remote/v4?app_version=3.16.1&sid=…` 链接，服务端已统一升级登录逻辑）首次登录均失败。

## 2. 根因分析

### 2.1 链接解析层：无问题

`lib/services/link_builder.dart:32-40`：v4 链接含 `sid` + `app_version`（无 `hash`）→ 正确判定 `DeviceKind.v2`；新增的 `mid` 参数随 `params` 全量保留并在 `buildUrl` 时原样回拼。导入链路正常。

### 2.2 真正根因：v4 页面登录使用 OAuth 弹窗（`window.open`），App 未支持多窗口

抓取 v4 页面主 bundle（`/remote/v4/3.18.2/assets/index-Chh4bF09.js`）确认登录实现：

```js
// 登录运行时（tbr 函数）
openAuthorization: () => {
  let e = window.open(`about:blank`, `_blank`);   // 先开空白弹窗
  return e
    ? (e.opener = null,
       { navigate: t => { e.location.href = t },   // 再把弹窗导航到授权页
         close: () => e.close(),
         isClosed: () => e.closed })
    : null;
},
assign: e => { window.location.assign(e) },
...
// 登录发起流程
let r = this.runtime.openAuthorization?.();
if (!r) throw Error(`Authorization popup was blocked`);   // ← 弹窗被拦即静默失败
```

- 授权弹窗最终跳转 `https://chat.z.ai/api/oauth/authorize?…`（`VITE_ZAI_OAUTH_ORIGIN: "https://chat.z.ai"`）；
- 登录**不依赖弹窗回调跳转**，而是主页面轮询 `/api/v1/oauth/cli/init` 与 `/api/v1/oauth/cli/poll/{id}` 完成票据交换；
- 因此只要弹窗能打开、用户能在弹窗里完成登录，主页面会自动感知登录成功。

### 2.3 App 侧缺失的三件事

`lib/ui/session_view.dart:952-959` 的 `InAppWebViewSettings` 及 `InAppWebView` 回调注册均未支持新窗口：

| 缺失项 | 后果 |
| --- | --- |
| `supportMultipleWindows`（插件默认 `false`，见 `third_party/.../in_app_webview_settings.dart:1329`） | Android `setSupportMultipleWindows(false)`，`window.open()` 直接返回 `null`，`onCreateWindow` 永远不触发 |
| `javaScriptCanOpenWindowsAutomatically`（插件默认 `false`） | JS 主动开窗被禁 |
| `onCreateWindow` / `onCloseWindow` 回调 | 即使开了多窗口也没有宿主处理弹窗 |

链路：页面点"登录" → `window.open('about:blank','_blank')` 返回 `null` → `openAuthorization()` 返回 `null` → 抛 `Authorization popup was blocked` → 页面只渲染暗色错误态/停住。由于页面自身是 `#161616` 暗色主题且 App 端 `transparentBackground: true`，用户看到的就是"黑屏、无反应"。

### 2.4 插件能力已具备（无需改第三方包）

vendored 插件（`third_party/flutter_inappwebview_android`、`..._platform_interface`）已支持完整弹窗机制：

- `InAppWebView(onCreateWindow:, onCloseWindow:, windowId:)`（`in_app_webview.dart:43/25`）；
- 原生侧：`onCreateWindow` 时把 `resultMsg`（`WebView.WebViewTransport`）按 `windowId` 存入 `InAppWebViewManager.windowWebViewMessages`（`InAppWebViewChromeClient.java:626`）；
- 当 Dart 侧创建 **带 `windowId` 的新 `InAppWebView`** 时，`FlutterWebView.makeInitialLoad` 会消费该 transport 并 `sendToTarget()`（`FlutterWebView.java:103-104`）→ JS `window.open()` 拿到真实 window 句柄 → 页面再执行 `e.location.href = t` 把弹窗导航到授权页；
- 弹窗内 `window.close()` → `onCloseWindow` 回调。

即：只需在 Dart 应用层接线，原生机制已齐备。

## 3. 方案选型

| 方案 | 说明 | 结论 |
| --- | --- | --- |
| **A. 应用内弹窗 WebView（推荐）** | `onCreateWindow` 中弹 Flutter Dialog/全屏 sheet，内嵌 `InAppWebView(windowId: action.windowId)`，使用与主 WebView 相同的 `androidWebProfile` | ✅ Cookie 落在同一 profile，**多账号隔离不被破坏**；体验一致；轮询机制不受影响 |
| B. 系统浏览器打开授权 URL | `onCreateWindow` 中取出 URL 用外部浏览器打开 | ❌ 系统浏览器 Cookie 全局共享，破坏 per-device profile 多账号隔离；且 `window.open('about:blank')` 场景拿不到最终 URL |
| C. 同窗口 `loadUrl` 跳转 | 在主 WebView 里直接加载授权页 | ❌ 主页面被卸载，`/api/v1/oauth/cli/poll/{id}` 轮询中断，登录永远无法完成 |

采用方案 A。

## 4. 改动清单

### 4.1 主 WebView 开启多窗口（`lib/ui/session_view.dart`）

`initialSettings` 增加：

```dart
initialSettings: InAppWebViewSettings(
  // ...existing...
  supportMultipleWindows: true,
  javaScriptCanOpenWindowsAutomatically: true,
),
```

注册回调（与现有 `onWebViewCreated` 内的 handler 注册并列）：

```dart
onCreateWindow: (controller, action) async {
  if (!mounted) return false;
  await _openAuthPopup(action);   // 返回 true 表示已接管，插件将保留 transport 供弹窗 WebView 消费
  return true;
},
```

要点：
- `action.request.url` 在 JS `window.open('about:blank')` 场景下是 `about:blank`/空 → **不要**拿它做 `initialUrlRequest`；弹窗 WebView 靠 `windowId` 接管，随后由页面执行 `e.location.href = t` 自行导航到 chat.z.ai。若未来出现真实 URL 的弹窗（如 `target=_blank` 链接），则把该 URL 作为弹窗的 `initialUrlRequest` 传入，同一组件兼容两种形态。
- `_openAuthPopup` 用 `Navigator.push` 全屏/大 sheet 路由承载弹窗 WebView；返回 `true` 前确保路由已发起。
- 弹窗打开失败（如路由异常）时返回 `false`，行为退化为现状（窗口丢弃），并打 `debugPrint('[zr-popup] …')` 便于排查。

### 4.2 新增弹窗组件（`lib/ui/webview_popup.dart`，新文件）

`AuthPopupPage`（StatefulWidget），构造参数：

```dart
AuthPopupPage({
  required this.device,          // 用于 webProfileNameFor(device) 保持同 profile
  required this.windowId,        // createWindowAction.windowId
  this.initialRequest,           // 有真实 URL 的弹窗场景；about:blank 场景传 null
});
```

实现要点：

1. `InAppWebView(windowId: widget.windowId, initialUrlRequest: widget.initialRequest, androidWebProfile: webProfileNameFor(widget.device), …)`：
   - 同 profile → chat.z.ai 登录 Cookie 与 zcode.z.ai 会话落在同一 profile，登录完成后主 WebView 轮询自动拿到票据，且多账号隔离语义不变；
   - 弹窗**不注入** `EventObserver` / RPC bridge user scripts（登录页不需要，避免副作用）；
   - 不需要 `transparentBackground`，正常白底/页面自绘。
2. 关闭时机（三重保险）：
   - 弹窗自身 `onCloseWindow`（页面 `e.close()`）→ `Navigator.pop`；
   - URL 启发式：`onLoadStart`/`onUpdateVisitedHistory` 检测到回到 `zcode.z.ai` 域（授权完成后可能回跳回调页）→ 延迟 ~800ms 自动 pop，给主页面轮询留出窗口；
   - 常驻顶部工具条：标题 + 关闭按钮（系统返回键同样 pop），兜底页面不自动关的情况。
3. `WillPopScope`/`PopScope` 允许直接退出；pop 即结束弹窗生命周期，主页面轮询会继续进行（登录成功与否由主页面自行感知）。
4. 深色主题下弹窗容器底色与 `zt.bg` 一致即可。

### 4.3 回归保护（无需改动，验证即可）

- legacy 设备：`onCreateWindow` 是通用回调，legacy 页面若从未 `window.open` 则行为不变；若触发则同样获得弹窗能力（顺手修复）。
- `lib/services/webview_profile.dart`：`webProfileNameFor` 仅对 v2 返回非空 profile；legacy 弹窗走默认 profile，与主 WebView 一致（主 WebView legacy 也是默认 profile），Cookie 仍共享。
- 会话页 `onLoadStart` 的状态机（`session_view.dart:1024-1042`）只作用于主 WebView 控制器，弹窗是独立 WebView 实例，不会互相干扰。

## 5. 测试计划

### 5.1 现有单测

- `test/link_builder_test.dart`、`test/paste_import_test.dart` 等已覆盖 v4/v2/legacy 解析，**无需新增解析用例**。
- 运行 `flutter test` 确认无回归。

### 5.2 新增单测（可测部分）

- 若 `_openAuthPopup` 的"真实 URL vs about:blank"判定抽成纯函数（建议：`AuthPopupPolicy.initialRequestFor(CreateWindowAction)`），补一个单测文件 `test/auth_popup_policy_test.dart`：
  - `about:blank` → 返回 null；
  - `https://chat.z.ai/...` → 返回对应 URLRequest；
  - 空 URL → 返回 null。

### 5.3 手测清单（真机，debug 包 + chrome://inspect）

用用户提供的 v4 链接（及一个 3.16.1 旧 v2 链接）验证：

1. [ ] 导入 v4 链接 → 进入设备 → 页面正常渲染（非黑屏）；
2. [ ] 点击"登录" → 应用内弹出授权页（chat.z.ai），可正常输入账号完成登录；
3. [ ] 登录完成后主页面自动变为已登录/live（LED 绿），无需手动刷新；
4. [ ] 弹窗自动关闭（或手动关闭）后，刷新会话页登录态保持（Cookie 已入 profile）；
5. [ ] 多账号：两张 V2 卡分别登录不同账号 → 互不顶号；
6. [ ] 弹窗内点"关闭"按钮、系统返回键均能正常退出弹窗；
7. [ ] legacy 设备打开会话页，功能不受 `supportMultipleWindows: true` 影响；
8. [ ] 弹窗打开状态下切后台/回前台、旋转屏幕，弹窗与主页面状态正常；
9. [ ] 登录页中途关闭弹窗 → 主页面停在未登录态，可重新点击登录再次弹窗。

## 6. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| `supportMultipleWindows: true` 全局生效后，页面里任何 `target=_blank` 链接也会触发 `onCreateWindow` | `onCreateWindow` 统一走弹窗组件（兼容真实 URL 形态），不会出现"链接点了没反应"的新问题 |
| 弹窗 WebView 与主 WebView 并存内存开销 | 弹窗为临时页面，pop 即销毁；不做 keepAlive |
| 部分厂商 WebView 版本对 `MULTI_PROFILE` 不支持（已有 `webviewIsolationUnsupportedHint` 降级横幅） | 弹窗沿用 `androidWebProfile` 设置，不支持时插件回退默认 profile，行为与现状一致 |
| iOS 侧 `window.open` 行为未验证 | 同一 Dart 回调在 iOS 插件同样存在（WKWebView `createWebViewWith`）；先交付 Android，iOS 真机回归后随下个版本合入 |

## 7. 验收标准

- 使用 3.18.2 v4 链接从导入到登录成功全流程无黑屏、无卡死，登录后主页面自动进入 live 态；
- 旧 v2 链接与 legacy 链接回归通过；
- 多账号隔离语义保持（不同设备卡登录态互不影响）；
- `flutter analyze` / `flutter test` 全绿。
