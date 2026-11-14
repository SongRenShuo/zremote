# 开发计划：功能工具箱修复（模型设置 / 用量统计 / 权益中心 / 自动化调度历史）

> 版本基准：v1.7.0（commit 1549e1d）
> 目标：修复功能工具箱内四个入口无法正常使用的问题，并补齐自动化调度历史任务查看能力。
> 状态：P0–P4 已实现（本机无 Flutter SDK，编译/测试验证走 CI 或本地 flutter test；
> 真机回归清单见 docs/manual-regression-toolbox.md）

---

## 1. 症状与影响面

| 入口 | 症状 | 直接依赖的 RPC 服务 |
|---|---|---|
| 模型设置 | 无法正常使用（加载失败/报错） | `providerSettingsService.getView`、`modelSelectionService.getView`、`settingService.get/update` |
| 用量统计 | 无法正常使用 | `usageStatsService.getAppUsageSnapshot`、`getEntitlementSnapshot` |
| 权益中心（领券） | 无法正常使用；工具箱卡片常置灰 | `codingPlanSubscriptionService.getManualClaimPlanPreviews / getCaptchaConfig / claimManualPlan` |
| 自动化调度 | 无法查看历史定时任务；列表为空无错误提示 | `offPeakTaskService.list`、`zcodeAgentService.listAllAutomations` |

四个入口**同时失效**这一点是关键线索：它们共享同一条 RPC 通道，问题大概率出在公共链路，而非各页面自身的业务逻辑。

## 2. 公共调用链（现状）

```
session_view.dart
  └─ 注入 UserScript（AT_DOCUMENT_START，event_observer.dart:6 hookScriptFor）
       ├─ 劫持 fetch / EventSource / WebSocket → 会话事件观察
       └─ zrFindServices()：在 React Fiber 树里爬出"服务注册表"对象
       └─ 长轮询 127.0.0.1:<dispatchPort>/zrp/<token>（rpc_dispatch.dart LoopbackDispatchServer）
            └─ window.__zrSvcCall(id, svcKey, method, argsB64)
                 └─ svc[method].apply(svc, args) → post('zrSvcResult', ...)
  └─ RpcBridge.call(channel, method)（rpc_bridge.dart）
       └─ channel → 服务名映射 _serviceByChannel（rpc_bridge.dart:59）
       └─ push 命令到 dispatch 队列 → JS 执行 → zrSvcResult 回填 Completer
  └─ 各页面 bridge.call → RpcResponse.firstObject → Model.fromJson
```

## 3. 根因分析

### 3.1 [跨页根因·最可疑] JS 侧服务发现（zrFindServices）极其脆弱

位置：`lib/services/event_observer.dart:207-276`

发现逻辑要求"服务注册表"对象同时满足：

1. key 数 ≥ 10 且都以 `Service` 结尾；
2. **必须同时含有 `zcodeAgentService` 和 `offPeakTaskService`**（`event_observer.dart:236-240`）；
3. 能通过 `document.querySelectorAll('*')` 找到的第一个 `__reactFiber` 元素向上走到 fiber 根，再 DFS `memoizedState / stateNode / memoizedProps` 找到它。

失效模式（任一即全灭，与症状完全吻合）：

- **宿主（ZCode 客户端 WebView 前端）升级后**：服务改名/拆分（如 `offPeakTaskService` 改名、注册表拆成多个小对象）→ 条件 2 不满足 → 返回 null → 所有 RPC 报 `no-services`。
- React 版本升级 / 组件结构重构 → fiber 链上不再可达该对象 → 同样返回 null。
- 发现失败后**没有重试与降级策略**：只在 fiber 树这一条路径上找，找不到就永远 `no-services`。
- DFS 有 `depth > 20000` 上限与 `seen` 集合，页面大时开销大且可能漏找。

结果：模型设置 / 用量统计 / 权益中心三个页面的 `_callWithRetry` 重试 3 次后全部落到 notReady/remote 错误；自动化页则静默吞错显示空列表（见 3.4）。

### 3.2 [跨页根因] RPC 响应解包与模型解析假设过强

- `RpcResponse.firstObject`（`rpc_bridge.dart:42`）只取第一个 Map。宿主若把结果包一层（如 `{snapshot: {...}}`、`{tasks: [...]}`），页面拿到的是外壳对象。
- 各模型 `fromJson` 对字段漂移**零容错并返回 null**，被页面解释为通用错误，且**不携带任何诊断信息**：
  - `AppUsageSnapshot.fromJson`：summary/heatmap/models/dailyModelUsage 四个 key 全空即返回 null（`models/usage_stats.dart:224-232`）→ 用量页直接进 error 态（`ui/usage_page.dart:112-119`）。
  - `ClaimPreview` 只认 `obj['plans']` 数组（`ui/claim_page.dart:63-68`），宿主若改字段名即"无可用券"。
  - `ProviderSettingsView.fromJson` 同理（`ui/model_settings_page.dart:104-114`）。
- 参数侧同样有假设：用量页把 `{range, timeZone}` 作为单个对象参数传（`ui/usage_page.dart:96-101`），宿主改为多参或改 key 即失败。

### 3.3 [自动化调度] 历史任务根本没有 UI 通路，且解析层主动丢弃历史

三个叠加原因：

1. **无历史视图**：`zcodeAgentService.listAutomationRuns` 在探针清单里（`services/service_probe.dart:67`），但 `ui/automation_page.dart` 从未调用；页面只有"闲时队列 / 定时计划"两个 Tab（`ui/automation_page.dart:371-388`），没有"运行历史"入口。
2. **解析层主动丢弃历史数据**：
   - `AutomationExtractor` 跳过所有带 `runId` 的条目（`services/event_observer.dart:1156-1158`）→ 自动化运行记录被整段过滤；
   - `OffPeakTask.fromJson` 遇 `historyDeletedAt != null` 直接返回 null（`state/automation.dart:37-38`）→ 已入历史的闲时任务消失。
3. **错误静默**：`_refresh` 里两次 `catch (_) {}`（`ui/automation_page.dart:56-63`），RPC 失败时不给任何提示，用户看到的是"空列表"而非"加载失败"，加剧"无法查看历史"的感知。

### 3.4 [权益中心] 入口探针与就绪判定耦合过紧

- 工具箱领券卡片是否可点由 `_probeClaimEntry` 决定（`ui/session_view.dart:676-712`）：最多 15 次 × 2s 调 `getManualClaimPlanPreviews`。若 3.1 的服务发现失效，探针永远失败 → 卡片置灰。
- 探针把 `no-method` 也当可重试（`session_view.dart:701-705`），方法真被移除时会白等 30 秒才放弃。

### 3.5 [共性] 失败不可诊断

- `ServiceProbe.run`（`services/service_probe.dart:123`）能产出 keys/missing/checks/liveCalls 的完整诊断报告，但只在 debug 模式 `debugPrint`，无 UI 呈现入口；线上问题无法定位到"哪个服务缺了、哪个方法没了"。
- 各页面错误态只有 notReady/remote 两种，文案笼统，`RpcRemoteException.message` 未展示或被吞。

## 4. 修复方案（分阶段）

### P0 — 诊断能力先行（先能看见，再修）

| # | 任务 | 涉及文件 | 说明 |
|---|---|---|---|
| P0-1 | 内置"连接诊断"页：手动触发 `ServiceProbe.run`，把 dump(keys/missing/checks)+liveCalls 报告渲染出来（可复制/导出） | `ui/`（新增 diagnostics 页）、`services/service_probe.dart` | 修复验收与后续排障的基础设施 |
| P0-2 | `RpcRemoteException` / `fromJson→null` 路径带上原始报文片段（截断至 ~300 字符），错误态展示可读原因 | `rpc_bridge.dart`、各页面错误态 UI | 区分 no-services / no-method / 解析失败 / 超时 |
| P0-3 | 自动化页 `_refresh` 去掉裸 `catch (_) {}`：失败时记录最后错误并渲染为非致命提示条，空态文案区分"没有任务"与"加载失败" | `ui/automation_page.dart` | |

### P1 — 服务发现加固（解决跨页根因）

| # | 任务 | 涉及文件 | 说明 |
|---|---|---|---|
| P1-1 | `zrFindServices` 多策略化：① 现有 fiber DFS（放宽条件 2，改为"≥10 个 *Service key，按需 channel 对应的服务存在即可"，不再强制同时含 zcodeAgent+offPeak）；② 扫描 window 上可直接暴露的服务对象；③ 多个候选注册表支持（拆分对象场景） | `services/event_observer.dart` | 这是 JS 注入脚本，注意转义与体积 |
| P1-2 | 发现失败重试与缓存：未找到时按退避重试（页面可见时 2s/5s/10s），找到后缓存并在路由切换/版本变化时校验失效重建 | `services/event_observer.dart` | 复用现有 `zrPollRevive` 思路 |
| P1-3 | channel→服务名映射支持候选别名（如 offPeakTaskService 的旧/新名并存探测），映射失败在诊断页可见 | `rpc_bridge.dart:59` | 与 P0-1 报告联动 |
| P1-4 | 就绪探针 `ServiceProbe.checkReady` 增加对四个业务服务的定点 check，工具箱卡片就绪判定改用它（替代 15×2s 轮询 getManualClaimPlanPreviews） | `services/service_probe.dart`、`ui/session_view.dart:676`、`ui/toolbox_sheet.dart` | 领券卡片置灰逻辑与真实服务可用性解耦 |

### P2 — 响应解析容错（解决 3.2）

| # | 任务 | 涉及文件 | 说明 |
|---|---|---|---|
| P2-1 | `RpcResponse` 增加unwrap辅助：`firstObjectDeep`（剥离一层 `{xxx: {...}}` 单键外壳）；各页面改用 | `rpc_bridge.dart` | 保持显式，不做魔法深挖 |
| P2-2 | 模型解析降级策略：`AppUsageSnapshot / ProviderSettingsView / ClaimPreview` 等不再"全空即 null"，缺 key 时尽力渲染已解析部分 + 展示缺失字段提示 | `models/usage_stats.dart`、`models/provider_settings.dart`、`models/claim.dart` | |
| P2-3 | 参数形状兼容层：用量/模型参数按宿主版本探测（先调一次探测方法或带默认参试错一次再回退） | `ui/usage_page.dart:96`、`ui/model_settings_page.dart` | 参考 `RpcBridge.offPeakUpdateTwoArgs` 已有的兼容探测先例（`rpc_bridge.dart:155`） |

### P3 — 自动化调度历史（功能性补齐）

| # | 任务 | 涉及文件 | 说明 |
|---|---|---|---|
| P3-1 | 新增"运行历史"Tab：调用 `zcodeAgentService.listAutomationRuns`（及分页参数），展示 runId/时间/结果/失败原因 | `ui/automation_page.dart`、`state/automation.dart`、l10n | 探针已确认该方法存在 |
| P3-2 | `AutomationExtractor` 不再丢弃带 `runId` 条目，改由 UI 层按 Tab 过滤；`OffPeakTask` 保留 `historyDeletedAt` 字段供历史 Tab 展示（已删除历史做灰态而非直接消失） | `services/event_observer.dart:1143`、`state/automation.dart:35` | |
| P3-3 | 定时计划卡片点击展开最近 N 次运行记录（lastRunAt/runCount 已有，补 runs 列表） | `ui/automation_page.dart` | |
| P3-4 | 历史数据本地缓存（断连/离线时仍可查看上次快照，标明"最后同步时间"） | `state/automation.dart`、可选 `services/device_store.dart` | |

### P4 — 回归防护

| # | 任务 | 说明 |
|---|---|---|
| P4-1 | 为 `zrFindServices` 各策略编写 JS 单测（node 环境跑注入脚本片段，模拟宿主 DOM/fiber 结构变化） | 现有 test/ 目录 |
| P4-2 | 为新 unwrap/降级解析补 Dart 单测（外壳包裹、字段缺失、类型漂移三类 fixture） | |
| P4-3 | 真机回归清单：四入口逐一点开 + 断网恢复 + 宿主升级场景（诊断页报告截图归档） | |

## 5. 验收标准

1. 工具箱四个入口在最新版宿主 ZCode 下全部可加载出数据；任一失败时页面展示**具体错误原因**（含 no-services/no-method/解析失败区分），不再是笼统报错。
2. 诊断页能一键产出报告：missing 服务列表、checks 结果、liveCalls 结果；修复验证以该报告为准。
3. 自动化调度页出现"运行历史"Tab，能看到历史定时任务与运行结果；已删历史项有灰态记录而非凭空消失；加载失败与空列表在 UI 上可区分。
4. 服务发现不再强依赖"注册表同时含 zcodeAgentService + offPeakTaskService"这一单一条件；单服务缺失只影响对应入口，不拖垮全部。

## 6. 风险与备注

- **注入脚本是唯一通路**：P1 改动直接操作宿主 WebView 内 JS，需在真机（iOS WKWebView / Android WebView）双端验证 `__reactFiber` 行为差异；改坏会影响会话观察主链路，务必保留脚本开关可回退。
- **宿主版本碎片化**：不同用户宿主版本不一，P2/P3 的兼容层必须"新形状优先、旧形状兜底"，不能只适配最新版。
- **历史接口未知数**：`listAutomationRuns` 的返回结构需先用 P0-1 诊断页实测一次再定模型（计划里先按 runId/时间/状态建模，实测后修订）。
- 建议实施顺序：P0 → P1 → P2 → P3 → P4；P0/P1 是其余修复能否落地的前提。
