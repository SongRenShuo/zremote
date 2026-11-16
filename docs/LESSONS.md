# LESSONS（教训账本）

> 本文件是**持续演进、带淘汰压力的规则账本**（机制引自 mybatis-plus-sql-visualizer 仓库，2026-11-14 建册）。
> 每条教训固定四段：**粗体祈使句规则 → 证据（提交号/CI run/日志读数，hash 级）→ 正例与反例 → `Seen N× (日期…)`**。
> 同日多次发现只算一天；**Seen 满 3 个不同日期的规则整体搬进 [`规范/编码与验收标准-规范.md`](规范/编码与验收标准-规范.md)**，本文件在升级区保留指针，后续复发继续记回。
> 复盘触发点：每次**收口、CI 复跑、真机/模拟器故障**之后，由当值会话顺手补记一条（有新教训才记，没有不硬凑）。
> 分工：本文件只收**可执行规则**；事件叙事与完整排查过程写 `docs/经验总结/`，条目用链接引用不复制内容。**改代码前先读本文件。**

## 2026-11-14 建册（功能工具箱修复 + 本机 Android 环境搭建）

**数据**：22 commit（5e50a67 功能实现起，至 202b5fa P3-4 持久化；含 6 笔 CI 迭代修复已压扁为 1290181）/ CI：最终全绿 / 本地：flutter test 665 例全绿 + analyze 零问题 / 返工：CI 连红 4 轮（run #4/#5/#6/#7 各不同根因，见下）/ 完整叙事：[经验总结/20261114-2130-Android开发环境从零搭建-经验总结.md](经验总结/20261114-2130-Android开发环境从零搭建-经验总结.md)。

- **L1 Gradle 发行包禁直连官网，腾讯镜像预置进 wrapper 缓存**。证据：CI run #4 前本机构建 `Premature EOF`（services.gradle.org 直连断流）；实测直连 ~30KB/s，腾讯镜像 `mirrors.cloud.tencent.com/gradle/` 3.8MB/s；zip 落位 `~/.gradle/wrapper/dists/gradle-<版本>-<类型>/<hash>/` 后 wrapper 跳过下载（验证：`unzip -t` 完整 → 构建 19.5s 过发行包校验）。**Seen 1× (11-14)**
- **L2 Studio JBR 25 会让 Kotlin 构建崩在 `JavaVersion.parse: 25.0.4`，Gradle 必须指定 JDK 21 且该行勿提交**。证据：run #3/#6 `java.lang.IllegalArgumentException: 25.0.4`（`org.jetbrains.kotlin.com.intellij.util.lang.JavaVersion.parse`）；真因是 Toolbox 装的 Android Studio（Rabbit 2 / 2026.2.2）JBR 为 openjdk 25.0.4，KGP 解析器不支持；`org.gradle.java.home=D:/HuanJing/Java/jdk-21.0.2`（华为镜像 Oracle OpenJDK 201MB zip）落地后构建正常。**Seen 1× (11-14)**
- **L3 SDK 组件自动安装可能解压损坏，清 `.temp` 后用 sdkmanager 补装**。证据：run #5 `InstallFailedException: cmake;3.22.1`，`Sdk/.temp/PackageOperation01/unzip/.../ProcessorCount.rst` 半截文件；`rm -rf Sdk/.temp` + `sdkmanager "cmake;3.22.1"` 后 configureCMakeDebug 通过。同族风险面：NDK（28.2.13676358 这次自动装成功，不代表下次稳）。**Seen 1× (11-14)**
- **L4 JetBrains Toolbox 代理地址栏禁带 `http://` 前缀**。证据：地址填 `http://127.0.0.1` 时全部请求报 `UnknownHostException: 不知道这样的主机。 (http://127.0.0.1)`（toolbox.latest.log 十余条连刷，含 feed/下载/区域映射全灭）；改 `127.0.0.1` 即通（edgedl.me.gvt1.com 经代理实测 ~880KB/s）。**Seen 1× (11-14)**
- **L5 flutter run 卡 "Installing" 后手动 am start 拉起，会话自动附着**。证据：run5/run6 均停在 `Installing ... 3.0s` 无 Syncing；`adb shell am start -n com.pjpv.zremote/.MainActivity` 后 flutter 会话附着（三件套读数：Syncing 289ms / Flutter run key commands / Dart VM Service `http://127.0.0.1:10535`）。**Seen 1× (11-14)**
- **L6 同 testWidgets 二次 pumpWidget 同类型 widget 走 didUpdateWidget 复用 State，initState 不重跑**。证据：`运行历史 tab` 用例 CI 连挂（run #4/#5/#6）——第二次 pumpPage 的 bridge 换了但 `_loadError` 沿用第一段的；拆独立 testWidgets 后过。同族已修：`automation_page_test` 全部失败用例、横幅重试 key 定位。**Seen 1× (11-14)**
- **L7 RPC 服务别名/重试策略改动会成倍改写命令序列，脚本化测试必须按候选数重算**。证据：P1-3 别名机制上线致 23 个测试连坐（CI run #4）——`errors` 映射按「每频道候选数 × 重试次数」重算（off-peak-task 2 候选、zcode-agent/coding-plan 3 候选）后归零；反面教训：漏算一个候选（automation allFail 7→8 条）又是 3 轮修复。**Seen 1× (11-14)**
- **L8 脚本化测试桥默认行为变更必须加开关**。证据：`scripted_bridge` 「耗尽自动回空」上线使依赖沉默超时的用例语义全变（model 26-30、usage 4 连挂）；加 `respondEmptyOnExhausted` 参数后归零。**Seen 1× (11-14)**
- **L9 analyze 一个 warning 也会红 CI**。证据：run #6 的 `flutter test` 已 656 过 4 挂，修完后 run #7 却卡在 analyze `unused_import`——CI 的 analyze 步骤零容忍。推送前本地 `flutter analyze` 必跑。**Seen 1× (11-14)**
- **L10 aliyun Maven TLS 握手瞬断，重跑自愈勿急改配置**。证据：run #5 `Remote host terminated the handshake`（swiperefreshlayout-1.0.0.aar）；curl 复测 HTTP 200 正常；直接重跑构建即过。**Seen 1× (11-14)**
- **L12 行内横向滑动区的触摸区必须整行高，细条手势域会被外层滚动列表抢走**。证据：模型设置页名称列 18px 高的横向 SingleChildScrollView，真机（`b5aa5fd` APK）拖不动——手指稍偏即落进外层竖向 ListView 的手势域；改整行高（32px + 垂直 padding 居中）后可拖（`13b2418`）。同族风险：任何「行内水平滚动」都把触摸面做到与同行控件等高。**Seen 1× (11-15)**
- **L11 错误消息本体就是诊断入口：裸版本号 = 环境/兼容问题**。证据：`* What went wrong: 25.0.4`（无上下文）——曾误判为 NDK 缺失并装了 2.2GB NDK（NDK 确实缺但不是这报错的因）；真因是 JavaVersion.parse。判据：消息只有版本号 → 查「谁在解析什么版本」；InstallFailedException → SDK 组件损坏。**Seen 1× (11-14)**

## 2026-11-15 V2.0 大版本（五车道并行实施）

**数据**：主控 + 5 车道 worktree（feat/v2-l1..l5 → integ/v2）；合并 4 轮全绿读数 720/851/910→986 例；真机 E2E 与收口见验收文档。

- **L13 cryptography 包的 PBKDF2 每 2000 迭代 `Future.delayed(1ms)`，testWidgets 假时钟下 await 会自锁**。证据：L1 车道 account_vault 的 .zsb 测试（`fcbf7b0`）首次跑挂——假时钟不前进、delayed 永不完成；解法：setup 阶段 `tester.runAsync` 走真时钟，按钮触发路径用循环 `pump(20ms)` 推进假时钟消化 delay。同族风险：任何内部带 `Future.delayed` 的第三方 crypto/网络库都不能在 testWidgets 直接 await。**Seen 1× (11-15)**
- **L14 多车道并行改同一 l10n arb：key 按车道前缀隔离可让 git 自动合并，生成产物冲突靠「并集后重跑 gen-l10n」收敛**。证据：V2 五车道（login*/acct*、quota*/rewards*、claimAuto*/claimHist*、settings*/ux*、approval*/assets* 前缀隔离）l10n 全部自动合并零冲突；仅 lib/l10n 生成产物需每轮合并后 `flutter gen-l10n` 重提（L1 合并后 72 个 undefined_getter 全由此来，gen 后归零）；主键冲突（双方同改同 key）用三方 stage 并集脚本兜底。反例：L4×L2 后半在 toolbox_sheet 同区重构（网格 vs 分组 IA）只能语义取舍，git 无解。**Seen 1× (11-15)**
- **L15 注入 JS 字面量若含任意用户可控值，`/*` 判据连 `\/` 转义都躲不开，须 `\uXXXX` 转义**。证据：rewards 供票注入脚本（`940dba8`）里 token 值含 `/` 与后续 `*` 组合即触发 M0-1 语法测试红；值内 `/`→`\u002f`、`*`→`\u002a` 后对任意凭据值结构性成立（测试含敌对值反例）。**Seen 1× (11-15)**
- **L16 运行中 debug App 的最强 E2E 驱动是 VM Service evaluate（attach 注册 DDS 后），坐标要乘 dpr；多会话共享模拟器必须串行**。证据：`flutter attach` 后 `evaluate`（isolateId+targetId=库 id）可读 Provider/按 Key 找元素取全局坐标/触发 onPressed；RenderBox localToGlobal 返回逻辑像素需 ×devicePixelRatio（本机 2.625）才是 adb tap 的物理像素；evaluate 输出 valueAsString 截断 128 字符；仅 debug/JIT 可用。反例：本次两个并发会话同时操作同一模拟器，调研会话的 force-stop 两次误杀 E2E 进程（05:17/05:18 ActivityManager 读数）——并行实验必须隔离设备或串行。**Seen 1× (11-15)**

## 2026-11-15 功能问题修复轮（四车道并行，P0 实测先行）

**数据**：主控 + 4 车道 worktree（fix/v2-{account,claim,assets,login} → fix/v2-integ）；P0 实测 1 个（独占模拟器）+ 契约核查 2 个（开源/官方 asar）；合并 4 轮，integ 全量 **1072 例全绿** + analyze 零问题；提交 `7e79574`/`228a9b3`/`4bfb1ce`/`576ba6b` + 主控接线 `03cb8fa`；读数见 `~/.zremote-e2e/P0-report.md`、`P0-static-contract.md`、`P0-official-contract.md`。

- **L17 WebView 网关的 `load()` 必须缓存「控制器未就绪」时的待载 URL，禁止用 `?.` 静默丢弃**。证据：登录页 `_start` 在 `setState(authorizing)` 后同步 `load()`，此刻 `InAppWebView` 尚未 build、`onWebViewCreated` 未触发，`_controller?.loadUrl(...)` 空安全调用直接吞掉 → CDP `Page.getNavigationHistory` 仅 1 条空记录、VM 采样 `phase=authorizing ctrl=ctrl injected=false`、5 分钟后才「等待授权超时」（`576ba6b` 修复：待载队列 + attach 后补载）。同族风险：任何「先调用、后挂载」的桥接 API（controller/gateway/portal）都要问一句「对象还没创建时会怎样」。**Seen 1× (11-15)**
- **L18 能力态与业务态禁止共用一个状态位；一次性探针不得由页面回写**。证据：工具箱权益卡 `enabled` 绑在 `claimEntryProvider` 上，而该 provider 同时承载「无券可领」，`ClaimPage` 一次空结果 `report(false)` 后卡片永灰，只有 reload 才复位（实测 `true→false→点不动→reload→true` 循环）；且探针 `_claimEntryProbed` 只跑一次（`228a9b3`+`03cb8fa` 修复：新增 `claimServiceProvider` 三态，能力探针只在转 live/开箱/错误恢复时重跑）。判据：**入口可点性 = 能力；计数/徽标 = 业务**，两者永不互相写。**Seen 1× (11-15)**
- **L19 宿主 RPC 的「缺字段」多数不报校验错、只回退业务态——schema 阅读不能替代实调用读数**。证据：`getEntitlementSnapshot` 的 `accountAccess` 在开源 schema 里是 strict 四字段全必填，但实测缺 `entitled` 仍返回完整快照，缺 `type`/`accountType`/`mode` 只是回 `unavailableReason:"not_configured"` 而不抛错（`P0-report.md` P0-5 九组读数）；本仓旧实现「字段为 null 就省略」→ 一律落 `not_configured` → 被上层当「加载失败」（`4bfb1ce` 修复：三字段齐全才发，缺则降级并不再混同错误态）。同族风险：把「业务回退值」当「调用失败」是同一类误判。**Seen 1× (11-15)**
- **L20 会话索引的 `workspacePath` 不可靠，工作区真值要回退宿主 localStorage**。证据：实测 `sessionIndexProvider` 内 HQZC-01 约 100 条会话 `workspacePath` **全为 null**，而 skills/subagents/mcp/hooks 四频道空参必抛错（`The "path" argument must be of type string`）→ 资产页全灭；真实值在宿主 `localStorage['zcode-workspace-expansion']`（`Record<path,boolean>`，取首个 key）（`03cb8fa` 修复：新增 `_readHostWorkspacePath()` 带缓存，资产页/Git 卡回退）。判据：跨端状态（RPC 索引）与页面本地状态（localStorage）不一致时，以**宿主页面**为准并显式回退。**Seen 1× (11-15)**

## 2026-11-16 真机回归修复轮（问题八~十六，五车道并行）

**数据**：主控 + 5 车道 worktree（fix/v21-{diag,update,quota,git,devices}）；定位 3 个（诊断/更新/额度预警）+ 调研 2 个（Git 精华/账户直连）；全量 **1176 例全绿** + analyze 零问题；提交 `de85332`/`4d3c331`/`b9677ac`/`9ae32ed`/`23603b1`/`2676cd1`/`3db62bc`/`d90db99`；报告在 `~/.zremote-e2e/`（lane-*.md、P0-report、e2e-after-fix-report、*-research）。

- **L21 「发请求 + 关页面」顺序颠倒会弹掉刚压栈的页面**。证据：设置页「连接诊断」先 `request()` 再 `pop()`，Riverpod 3 的 `ref.listen` **同步派发** → SessionView 立刻 push 诊断页，随后的 `pop()` 弹的正是它（实测同构样例：现状 `diagnostics=0 open=1`，先 pop 后 request `diagnostics=1 open=0`）；反证是工具箱同功能入口「先 pop 再回调」一直正常（`b9677ac`）。判据：**凡「发通知/请求 + 关闭当前页」的组合，先关页面再发请求**，且请求要可 `consume()`（残留会误报）。**Seen 1× (11-16)**
- **L22 版本检查类 API 必须盯住「仓库地址」与「三态返回」**。证据：`UpdateChecker` 写死上游 `pjpv/zremote`（latest v1.7.0）而 App 已 2.0.1 → `compareVersions>=0` 恒真、永远「无更新」；同时 `null` 同时表达「无更新/网络失败/形状异常」，UI 无任何提示（`4d3c331`）。判据：检查类功能至少三条独立路径（有更新/无更新/失败）+ 失败可重试；仓库地址这类"看起来不会变的常量"也要在迁移仓库后全局搜过。**Seen 1× (11-16)**
- **L23 形状归一化要按「RPC 解包后的真实形态」写，别按嵌套直觉**。证据：`memoryService.listProjectMemories()` 返回对象数组，RPC 解包后 `values` **就是顶层数组**（元素是 Map）；本仓 `_memoryOf` 只找「数组里嵌数组」→ 恒 `degraded` → 真机显示「响应形状不识别，已按空列表降级」（`de85332`）。判据：先写一条**真实形态**的用例再写归一化；「空数组」必须与「形状不符」区分（空=无内容，不降级）。**Seen 1× (11-16)**
- **L24 跨源比较只用「同量纲字段」；展示与真值分离**。证据：额度预警若用 `remaining` 跨源比较会因单位不同（token/分钟/次）失真，统一用 `percentUsed`（`2676cd1`）；反例同轮：自动化表单下拉直接渲染 `workspacePath` 真值 → 满屏路径（`de85332`）。判据：列表/下拉**展示名与 value 分离**（value 存 ID/路径，展示取名称，无名称回落 basename）。**Seen 1× (11-16)**
- **L25 共享 provider 驱动的定时任务，测试要固定其依赖表**。证据：`QuotaAlertWatcher` 的「无设备」用例依赖真实 `deviceListProvider` 的异步加载时序，全量跑偶发失败（单独跑必过）——用 `overrideWith` 固定空设备表后稳定（`d90db99`）。判据：**测试断言的前提如果是"某个异步 provider 恰好是空的"，就必须 override 它**，否则用例间会互相应响。**Seen 1× (11-16)**
- **L26 弹层/展开内容必须落在「有界可滚动」容器里，展开后要主动滚入可视区**。证据：自动化计划卡「展开运行」与工具箱「更多」展开后新内容整块停在视口外（复现：800×1200 卡底边 1283>1200），需用户自己找；同型还有 `session_view._showSwitcher` 无界 `Column`（20 台设备溢出 329px、不可滚动）（`da550bd`+`b4e93f3`）。判据：**弹层列表一律 `Flexible/Expanded` + `ListView`/`SingleChildScrollView`；展开状态变化后用 `Scrollable.ensureVisible`（`keepVisibleAtEnd`）只补最小滚动**——用 explicit 滚到顶会让顶部卡片跳页（实测 428px→0）。**Seen 1× (11-16)**
- **L27 账户能力不得强依赖「已有设备」——入口可达性是硬需求**。证据：`LoginWebPage`/`AccountVaultPage` 构造 `required device`、登录入口只在设备会话页 → **全新安装（0 设备）无法登录**，于是「登录→拉取服务端设备列表→重建设备库」的迁移路径断在第一步（`6dd76c4`+`606dd6f`）。判据：涉及账户/登录的能力要能在**空库态**可达（入口放空态页与设置页，`device` 设可选并显式降级），并把「0 设备可达」写进用例。**Seen 1× (11-16)**

## 2026-11-16 登录入口 / 导入设备登录态 / 改名轮（两车道并行）

**数据**：2 车道 worktree（fix/v22-{loginentry,autoinject}）；合并后全量 **1209 例全绿** + analyze 零问题；提交 `1518699`（合并 `aa0a7dd`）、`0ee8db2`（合并 `e44c34e`）、`c49c856`；报告 `~/.zremote-e2e/lane-{loginentry,autoinject}-report.md`。

- **L28 `ConsumerState.dispose` 里 `ref.read` 在 Flutter 3.38 会抛（unmount 后 ref 已 defunct）——要在 `didChangeDependencies` 缓存 notifier**。证据：会话页 dispose 用 `ref.read(claimSchedulerHubProvider.notifier).detach(...)`，页面销毁即抛（`0ee8db2` 同批最小修复：缓存 `_claimSchedulerHubNotifier`/`_approvalCenterNotifier` 后判空调用）。判据：**dispose 内只允许用已在 `didChangeDependencies`/`initState` 缓存的引用**，不要在 unmount 路径上现取 provider。**Seen 1× (11-16)**
- **L29 「账号↔设备绑定」与「凭据注入」是两件事：只写绑定不写 localStorage，页面依旧取不到票**。证据：`AccountVaultPage._installAccountDevice` 只 `add(device)` + `setActiveForDevice`，设备 WebView 五键凭据仓为空 → 额度/福利取不到票，用户必须去账户库手动「应用」一次（`0ee8db2` 修复：会话页 `onLoadStop` 自检「有绑定 + 缺 `zcodejwttoken`」→ 注入并 reload 一次，按「设备 id+账号 id」防循环；换绑重检、解绑清键）。判据：凡「新增/切换账号到设备」的落点，要么**同批注入**，要么**由会话页自检补注入**，并显式防循环。**Seen 1× (11-16)**
- **L30 一次性副作用（注入/上报/解锁）必须带「身份键」防循环，且键要随身份变化而失效**。证据：注入后 reload 会再触发 `onLoadStop`，若无键则每次加载都回读+注入+reload（`0ee8db2`）。判据：键 = 触发条件全体（此处 设备 id + 账号 id）；「已完成」与「确认无需做」都写键；身份变化（换绑/解绑）清键。**Seen 1× (11-16)**

- **L31 发布资产文件名必须自带「应用名 + 版本 + 平台」——否则与上游同名产物无法区分**。证据：Release 资产长期叫 `app-release.apk` / `zremote-ios-unsigned.ipa`，应用改名 ZRemoteX 后用户仍反馈「两个包识别不出是当前应用」（应用内 `android:label`/`CFBundleDisplayName` 虽已是 ZRemoteX，但下载页与文件名看不出来）（`9ce0851` 修复：workflow 发布前重命名为 `ZRemoteX-v<版本>-android.apk` / `ZRemoteX-v<版本>-ios-unsigned.ipa`；已发布的 v2.0.3 用资产改名 API 直接重命名，无需重传 80MB）。判据：**凡对外分发的产物名，先回答「只看文件名能否认出是哪个应用、哪个版本」**；GitHub 资产可用 `PATCH /releases/assets/{id}` 改名，别为改名重跑构建。**Seen 1× (11-16)**

## 2026-11-16 鸿蒙（HarmonyOS NEXT）支持立项

**数据**：方案裁定 + P1 平台抽象 + P2 脚手架 + P5 CI（`3691207`/`91e971c`/`b1afa3e`/`ab2bb13`）；全量 1216 例全绿 + analyze 零问题；计划册 `docs/开发计划/20261116-1434-鸿蒙NEXT全面支持-开发计划.md`。

- **L32 新平台判定必须抽象成能力层，禁止散写 `Platform.isAndroid`/`isIOS` 二分**。证据：stock Flutter 3.38 **没有** `Platform.isOhos`、`TargetPlatform` **没有** `ohos` 取值，直接写编译失败；本仓 `zai_auth_client.dart`、`quota_client.dart`、`webview_profile.dart` 三处二分需改造（`3691207` 引入 `lib/services/platform_caps.dart`，用 `Platform.operatingSystem` 探测 + 测试注入；判定要尊重 `debugDefaultTargetPlatformOverride`，否则既有 iOS/Android 用例回归）。判据：**凡「按平台分支」的代码先问「新增平台时这里会不会漏」**；新平台接入先落能力层，再改分支。**Seen 1× (11-16)**
- **L33 `dependency_overrides` 无平台条件——一份 pubspec 服务多端时，新平台插件 fork 替换是核心难点**。证据：本仓 `flutter_inappwebview` 有本地 Android fork（MULTI_PROFILE，`third_party/`），CPF-Flutter 的 ohos 实现是 **git fork（`-ohos-` tag，多不在 pub.dev）**；直接覆盖会连带改掉 Android/iOS 行为（计划 20261116-1434 P3）。判据：**多端工程接新平台，先列「插件 × 平台」支持矩阵与覆盖影响面**，再动 `dependency_overrides`；无法两全时优先自研抽象层而非全局覆盖。**Seen 1× (11-16)**

## 升级区（Seen ≥ 3 → 编码与验收标准 的指针）

- 无（账本刚开册）。
