#!/bin/bash
# =============================================================================
# 04 - 编译主线内核（含超频补丁、低内存裁剪）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

KDIR="$SRCDIR/linux"
DTSI="$KDIR/arch/arm64/boot/dts/qcom/msm8916.dtsi"

echo "==> [04] 编译内核"
[[ -d "$KDIR" ]] || { echo "!! 未找到内核源码，请先跑 02-fetch-sources.sh" >&2; exit 1; }
cd "$KDIR"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_VERSION=1

# ---------- 1. 先看清楚现有 OPP 表 ----------
echo "==> 当前 CPU OPP 表（超频前）："
python3 "$WORKDIR/tools/opp-overclock.py" --check --dtsi "$DTSI" || true

# ---------- 2. 超频补丁 ----------
if [[ "$OC_ENABLE" == "yes" ]]; then
  echo "==> 应用超频补丁 -> ${OC_MAX_HZ} Hz"
  OC_ARGS=(--apply --hz "$OC_MAX_HZ" --dtsi "$DTSI")
  [[ -n "$OC_MICROVOLT"  ]] && OC_ARGS+=(--microvolt  "$OC_MICROVOLT")
  [[ -n "$OC_FUSE_LEVEL" ]] && OC_ARGS+=(--fuse-level "$OC_FUSE_LEVEL")
  python3 "$WORKDIR/tools/opp-overclock.py" "${OC_ARGS[@]}"
else
  echo "==> OC_ENABLE=no，跳过超频"
fi

# ---------- 3. 合并 defconfig + 低内存片段 ----------
echo "==> 生成 .config"
make "$KERNEL_DEFCONFIG"
"$KDIR/scripts/kconfig/merge_config.sh" -m .config \
  "$WORKDIR/kernel-fragments/ufi-lowmem.config"
make olddefconfig

# ---------- 4. 编译 ----------
echo "==> 编译内核（本机 ${JOBS} 线程，约 20-90 分钟）..."
make -j"$JOBS" Image.gz dtbs modules 2>&1 | tail -40
make -j"$JOBS" modules_install INSTALL_MOD_PATH="$BUILDDIR/modules"

# ---------- 5. 收产物 ----------
mkdir -p "$FILESDIR"
KVER="$(make kernelrelease)"
echo "==> 内核版本: $KVER"

cp "$KDIR/arch/arm64/boot/Image.gz" "$FILESDIR/Image.gz"
mkdir -p "$FILESDIR/dtbs/qcom"

# 目标 DTB + 所有候选 DTB（方便现场切换排障）
for d in "${DTB_CANDIDATES[@]}"; do
  f="$KDIR/arch/arm64/boot/dts/qcom/${d}.dtb"
  if [[ -f "$f" ]]; then
    cp "$f" "$FILESDIR/dtbs/qcom/"
  else
    echo "    (警告) 未编译出 ${d}.dtb"
  fi
done
[[ -f "$FILESDIR/dtbs/qcom/${DTB_NAME}.dtb" ]] \
  || { echo "!! 主 DTB ${DTB_NAME} 不存在，见 docs/排障与救砖.md" >&2; exit 1; }

# 反编译回 dts 便于人工核对超频是否生效
dtc -I dtb -O dts "$FILESDIR/dtbs/qcom/${DTB_NAME}.dtb" \
    -o "$FILESDIR/dtbs/qcom/${DTB_NAME}.dts" 2>/dev/null || true

echo "$KVER" > "$FILESDIR/kernel-version.txt"
tar -C "$BUILDDIR/modules" -czf "$FILESDIR/modules.tar.gz" lib

echo "==> [04] 完成，产物："
ls -lh "$FILESDIR/Image.gz" "$FILESDIR/dtbs/qcom/"*.dtb "$FILESDIR/modules.tar.gz"
echo "==> 下一步：./scripts/05-build-rootfs.sh"
