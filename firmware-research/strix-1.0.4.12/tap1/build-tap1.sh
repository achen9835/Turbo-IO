#!/usr/bin/env bash
# 云Mac 重编 TAP1 系实验固件（2026-10 版：导航路况扩展 + 12 项菜单 + 容器探查）。
# 用法（仓库根目录）：
#   bash firmware-research/strix-1.0.4.12/tap1/build-tap1.sh /absolute/OHOS_LLVM_BIN /absolute/StrixOS-1.0.4.12-ORIGINAL-rollback.zip /absolute/新输出目录
# OHOS_LLVM_BIN = DevEco Studio 所带 OpenHarmony native llvm/bin（版本门槛：clang 15.0.4 / 39bec79f）。
# 只离线构建，不触碰眼镜、不授权刷写。输出目录必须不存在。
set -euo pipefail
cd "$(dirname "$0")/../../.."   # 仓库根

LLVM_BIN="$1"; STOCK="$2"; OUT="$3"
[ -d "$LLVM_BIN" ] || { echo "LLVM bin 目录不存在"; exit 1; }
[ -f "$STOCK" ] || { echo "原厂 rollback ZIP 不存在（Release firmware-strix-1.0.4.12-turbophoto-r3 附件）"; exit 1; }
[ ! -e "$OUT" ] || { echo "输出目录已存在，换新目录"; exit 1; }
for t in clang ld.lld llvm-nm llvm-objcopy node; do command -v "$t" >/dev/null || { echo "缺少 $t"; exit 1; }; done

# 1) 共享 venv（capstone/unicorn）
SHARED=firmware-research/strix-1.0.4.12
[ -d "$SHARED/.venv" ] || { python3 -m venv "$SHARED/.venv"; "$SHARED/.venv/bin/pip" install -r "$SHARED/requirements.txt"; }

# 2) 复制源快照 + 准备基线 + 放置 PNG
mkdir -p "$OUT"
cp -R firmware-research/strix-1.0.4.12/tap1/source/. "$OUT/"
"$SHARED/.venv/bin/python" "$SHARED/src/prepare-baseline.py" "$STOCK" --output "$OUT/firmware-inspection/StrixOS-1.0.4.12"
PNG_DIR="$OUT/official-addon/build/turbo-photo-png-10412-20260921"
mkdir -p "$PNG_DIR"
cp "$SHARED/assets/turbo-photo-firmware.png" "$PNG_DIR/turbo-photo-gray16-rgba-88x98.png"

# 3) 以全运行时组合驱动快照构建器（wide + native-eight + display + navigation + animation + music）
export PATH="$LLVM_BIN:$PATH"
cd "$OUT/official-addon/research"
REPO_ROOT="$(cd ../../../.. && pwd)"
PYTHONPATH="$PWD:$PWD/music-runtime-v1:$PWD/navigation-runtime-v1" "$REPO_ROOT/$SHARED/.venv/bin/python" - <<'PY'
import importlib.util, json, hashlib
from pathlib import Path
spec = importlib.util.spec_from_file_location("bir", "build-image-rx-candidate.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
report = mod.build(Path("candidate"), True, True, True, True, True, True)
ap = Path("candidate/payload/nuttx_ap.bin").read_bytes()
print(json.dumps({"candidateAP": hashlib.sha256(ap).hexdigest(), "candidateAPBytes": len(ap), "archive": report["archive"]["name"]}, indent=2))
print("Built offline; no flash authorized. 把 candidateAP 记入 REBUILD-2026-10.md 刷机清单。")
PY
