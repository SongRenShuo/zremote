#!/usr/bin/env python3
"""修复 CPF-Flutter 3.41 嵌入层 OhosAutoFillHelper 的编译期类型错误。

背景（2026-11-16 本机实测）：
  @ohos/flutter_ohos（嵌入层）的 OhosAutoFillHelper.ets 引用了
  autoFillManager.AutoFillType / ViewData / FillRequest 等类型，但所有公开
  OpenHarmony / HarmonyOS SDK（API 12/23/24）的 autoFillManager.d.ts 只导出
  AutoSaveCallback / requestAutoSave，没有这些类型 → ArkTS 编译失败
  （15 个 10505001 ArkTS Compiler Error）。

  这些 Autofill API 在嵌入层代码里用 AUTOFILL_SUPPORT_API = 26 做运行时短路
  （deviceInfo.sdkApiVersion < 26 直接返回），即低版本真机本就不执行该分支。
  故将这些编译期类型降级为 any、把两个函数调用改为 (autoFillManager as any)
  即可通过编译，且不改变低版本运行语义。

用法（build hap 前执行，幂等）：
  python3 tool/patch_ohos_autofill.py [ohosProjectDir]
  默认 ohosProjectDir = <repo>/ohos

注意：
  - ohos/oh_modules 是 ohpm install 生成物，每次 `flutter pub get` / 清理后
    会被覆盖，故本脚本必须在 build 前重跑（CI 脚本已串接）。
  - 上游 CPF-Flutter 修复该嵌入层后可移除本脚本（见开发计划 P3 TODO）。
"""

import sys
from pathlib import Path

TYPES = (
    "AutoFillType",
    "ViewData",
    "AutoFillTriggerType",
    "FillRequest",
    "AutoFillCallback",
    "FillFailureResult",
    "SaveRequest",
    "AutoSaveCallback",
)
MARKER = "(autoFillManager as any)"


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    ohos = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "ohos"

    ohpm_dir = ohos / "oh_modules" / ".ohpm"
    if not ohpm_dir.exists():
        print(f"[autofill-patch] no oh_modules at {ohpm_dir}; run flutter pub get first")
        return 0

    candidates = sorted(ohpm_dir.glob("@ohos+flutter_ohos@*"))
    if not candidates:
        print("[autofill-patch] @ohos/flutter_ohos not installed; nothing to patch")
        return 0

    patched = 0
    for pkg in candidates:
        target = (
            pkg
            / "oh_modules"
            / "@ohos"
            / "flutter_ohos"
            / "src"
            / "main"
            / "ets"
            / "plugin"
            / "editing"
            / "OhosAutoFillHelper.ets"
        )
        if not target.exists():
            continue
        text = target.read_text(encoding="utf-8")
        if MARKER in text:
            print(f"[autofill-patch] already patched: {target.name}")
            continue
        original = text
        for t in TYPES:
            text = text.replace(f"autoFillManager.{t}", "any")
        text = text.replace(
            "autoFillManager.requestAutoFill(",
            "(autoFillManager as any).requestAutoFill(",
        )
        text = text.replace(
            "autoFillManager.requestAutoSave(",
            "(autoFillManager as any).requestAutoSave(",
        )
        if text != original:
            target.write_text(text, encoding="utf-8")
            patched += 1
            print(f"[autofill-patch] patched {target}")
    if patched == 0:
        print("[autofill-patch] no files changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
