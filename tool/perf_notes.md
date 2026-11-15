# 性能预算读数（V2 P6-4）

> 采集命令模板与基线表格**架子**（2026-11-15 随 L5 车道搭好）。
> 读数由主控在 E2E 阶段（P7）填数，本文件不跑任何命令；
> 判定以 adb 读数为准（验收规范 S6）。模拟器基线：`Medium_Phone_API_37.0`。

## 1. 冷启动耗时

```bash
# 确保进程冷态（先杀再测，取 3 轮中位数）
adb shell am force-stop com.pjpv.zremote
adb shell am start -W -n com.pjpv.zremote/.MainActivity
# 读数：ThisTime / TotalTime / WaitTime（ms）
```

| 轮次 | ThisTime | TotalTime | WaitTime | 备注 |
|---|---|---|---|---|
| 1 | 待填 | 待填 | 待填 | |
| 2 | 待填 | 待填 | 待填 | |
| 3 | 待填 | 待填 | 待填 | |
| 中位数 | 待填 | 待填 | 待填 | |

基线参照：v1.7.0+9 同机读数（主控补）。

## 2. 内存（单会话 / 多 WebView）

```bash
# 总览：PSS TOTAL 为主读数
adb shell dumpsys meminfo com.pjpv.zremote

# 只看关键行
adb shell dumpsys meminfo com.pjpv.zremote | grep -E "TOTAL PSS|Native Heap|Dalvik Heap|Graphics|Views"
```

采集场景（每场景静置 30s 后取读数）：

| 场景 | PSS TOTAL | Native Heap | Graphics | 备注 |
|---|---|---|---|---|
| 冷启动空列表 | 待填 | 待填 | 待填 | |
| 1 台设备会话 live | 待填 | 待填 | 待填 | |
| 2 台并行会话 | 待填 | 待填 | 待填 | 多 profile 隔离开启 |
| 3 台并行会话 | 待填 | 待填 | 待填 | 5 台上限时读数另记 |
| 福利中心页（内嵌 rewards WebView） | 待填 | 待填 | 待填 | |

## 3. 调度器唤醒频率（P2 自动领取）

```bash
# 时间线过滤（调度器日志前缀 [claim-scheduler]，logcat 时间戳看轮间隔）
adb logcat -v time | grep -E "claim-scheduler|zr-claim"

# 后台 30 分钟窗口内的 tick 计数（应 ≈ 3 次 ± jitter，10min 间隔）
adb logcat -d -v time | grep -c "claim-scheduler.*tick"

# 前台服务存活性（保活开启时）
adb shell dumpsys activity services com.pjpv.zremote
```

| 指标 | 读数 | 判定 |
|---|---|---|
| 30min tick 次数 | 待填 | 2~4 次（10min ±20% jitter） |
| 静默时段（23:00–08:00）tick 次数 | 待填 | 0 次 |
| 开关关闭 tick 次数 | 待填 | 0 次（零调用红线） |
| 保活开启后台 30min 存活 | 待填 | 服务在册、tick 持续 |

## 4. APK 体积预算（P5-5 附录 B 联动）

```bash
D:/HuanJing/flutter/bin/flutter.bat build apk --release
# 读数：build/app/outputs/flutter-apk/app-release.apk 字节数（MB）
```

| 版本 | 体积 | 新增依赖说明 |
|---|---|---|
| v1.7.0+9 基线 | 待填 | — |
| v2.0.0（dio/cryptography/share_plus/path_provider/file_picker/device_info_plus 落位后） | 待填 | P5-5 统一评审 |

## 5. 填数纪律

- 每格读数附采集命令与日期；改实现后复测同场景，旧值不删（换行保留）。
- iOS 同项读数本机不可采（无 macOS）——真机回归阶段由主控补记，标 not run。
