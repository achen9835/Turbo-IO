#!/usr/bin/env bash
# 云Mac 重编 TAP1 系实验固件（2026-10 版：导航路况扩展 + 12 项菜单 + 容器探查）。
# 零参数即可跑：自动找 DevEco 的 OHOS LLVM、自动找原厂 rollback ZIP、自动起时间戳输出目录。
# 也可显式指定：
#   bash firmware-research/strix-1.0.4.12/tap1/build-tap1.sh [OHOS_LLVM_BIN] [原厂rollback.zip] [输出目录]
# 只离线构建+审计，不触碰眼镜、不授权刷写。输出目录必须不存在（时间戳默认值保证）。
set -euo pipefail
cd "$(dirname "$0")/../../.."   # 仓库根
REPO_ROOT="$PWD"
TAP1_DIR="$REPO_ROOT/firmware-research/strix-1.0.4.12/tap1"

# ---- 参数解析：0~3 个，全部可省 ----
LLVM_BIN="${1:-${TAP1_LLVM_BIN:-}}"
STOCK="${2:-${TAP1_STOCK_ZIP:-}}"
OUT="${3:-}"

if [ -z "$LLVM_BIN" ]; then
  for d in "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin" \
           /Applications/DevEco-Studio.app/Contents/sdk/*/openharmony/native/llvm/bin; do
    [ -x "$d/clang" ] && LLVM_BIN="$d" && break
  done
  [ -n "$LLVM_BIN" ] || { echo "未找到 OHOS LLVM（clang）。装好 DevEco Studio，或: export TAP1_LLVM_BIN=<llvm/bin 绝对路径>"; exit 1; }
  echo "[自动] LLVM: $LLVM_BIN"
fi
if [ -z "$STOCK" ]; then
  STOCK="$(ls -t "$REPO_ROOT"/*[Rr]ollback*.zip "$HOME/Downloads"/*[Rr]ollback*.zip \
                   "$REPO_ROOT"/*1.0.4.12*.zip "$HOME/Downloads"/*1.0.4.12*.zip 2>/dev/null | head -1 || true)"
  [ -n "$STOCK" ] || { echo "未找到原厂 rollback ZIP（strix 1.0.4.12 Release 附件）。放到仓库根或 ~/Downloads，或: export TAP1_STOCK_ZIP=<zip 路径>"; exit 1; }
  echo "[自动] 原厂 ZIP: $STOCK"
fi
if [ -z "$OUT" ]; then
  OUT="$TAP1_DIR/out/candidate-$(date +%Y%m%d-%H%M%S)"
  echo "[自动] 输出目录: $OUT"
fi
[ -d "$LLVM_BIN" ] || { echo "LLVM bin 目录不存在: $LLVM_BIN"; exit 1; }
[ -f "$STOCK" ] || { echo "原厂 rollback ZIP 不存在: $STOCK"; exit 1; }
[ ! -e "$OUT" ] || { echo "输出目录已存在，换新目录: $OUT"; exit 1; }
for t in clang ld.lld llvm-nm llvm-objcopy node; do command -v "$t" >/dev/null || { echo "缺少 $t"; exit 1; }; done

# 1) 共享 venv（capstone/unicorn）
SHARED=firmware-research/strix-1.0.4.12
[ -d "$SHARED/.venv" ] || { python3 -m venv "$SHARED/.venv"; "$SHARED/.venv/bin/pip" install -r "$SHARED/requirements.txt"; }

# 2) 复制源快照 + 准备基线 + 放置 PNG
mkdir -p "$OUT"
cp -R "$TAP1_DIR/source/." "$OUT/"
"$SHARED/.venv/bin/python" "$SHARED/src/prepare-baseline.py" "$STOCK" --output "$OUT/firmware-inspection/StrixOS-1.0.4.12"
PNG_DIR="$OUT/official-addon/build/turbo-photo-png-10412-20260921"
mkdir -p "$PNG_DIR"
cp "$SHARED/assets/turbo-photo-firmware.png" "$PNG_DIR/turbo-photo-gray16-rgba-88x98.png"

# 3) 以全运行时组合驱动快照构建器（wide + native-eight + display + navigation + animation + music）
export PATH="$LLVM_BIN:$PATH"
cd "$OUT/official-addon/research"
PYTHONPATH="$PWD:$PWD/music-runtime-v1:$PWD/navigation-runtime-v1" "$REPO_ROOT/$SHARED/.venv/bin/python" - <<'PY'
import importlib.util, json, hashlib
from pathlib import Path
spec = importlib.util.spec_from_file_location("bir", "build-image-rx-candidate.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
report = mod.build(Path("candidate"), True, True, True, True, True, True)
ap = Path("candidate/payload/nuttx_ap.bin").read_bytes()
print(json.dumps({"candidateAP": hashlib.sha256(ap).hexdigest(), "candidateAPBytes": len(ap), "archive": report["archive"]["name"]}, indent=2))
PY

# 4) 独立字节级审计（REBUILD-2026-10.md 第8条；只读，不授权刷写）
PYTHONPATH="$PWD:$PWD/music-runtime-v1:$PWD/navigation-runtime-v1" "$REPO_ROOT/$SHARED/.venv/bin/python" \
  audit-tap1-candidate.py candidate --out candidate-audit.json

# 5) 刷机三步卡
ZIP_PATH="$(cd candidate && pwd)/$(python3 -c "import json;print(json.load(open('report.json'))['archive']['name'])")"
cat <<CARD

================= 构建完成 · 刷机三步 =================
① 手机先装新 IPA（focus-edition dylib 构建产物）——顺序不能反
② 眼镜刷: $ZIP_PATH
   （电量>50%；手机停掉导航/字幕/音乐/番茄全部会话；刷时贴近静止）
③ 刷后看三样: 菜单12项无滴滴/我的应用 · 模拟导航有路况柱与标记 · TCE1仪表盘正常
   异常 → 立刻回滚重刷原版 ZIP，不带病调试
审计: candidate-audit.json 已生成（PASS 才继续②）
======================================================
CARD
