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

## 升级区（Seen ≥ 3 → 编码与验收标准 的指针）

- 无（账本刚开册）。
