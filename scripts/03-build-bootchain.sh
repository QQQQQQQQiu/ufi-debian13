#!/bin/bash
# =============================================================================
# 03 - 编译启动链（qhypstub -> hyp.mbn，lk2nd -> aboot.mbn）
#
# 为什么需要：
#   原厂 aboot 只认 Android bootimg，且把内核限制在 32 位。
#   qhypstub 顶替 hyp，让 SoC 能进 EL2 跑 aarch64；
#   lk2nd 顶替 aboot，提供 fastboot 和 extlinux.conf 引导（像 u-boot 一样）。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

echo "==> [03] 编译 bootchain"
cd "$SRCDIR"

# ---------- qhypstub -> hyp.mbn ----------
echo "==> 编译 qhypstub ..."
make -C qhypstub CROSS_COMPILE=aarch64-linux-gnu- clean
make -C qhypstub CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS"

# ---------- lk2nd -> aboot.mbn ----------
echo "==> 编译 lk2nd (DTB=$LK2ND_DTB) ..."
make -C lk2nd TOOLCHAIN_PREFIX=arm-none-eabi- clean || true
make -C lk2nd TOOLCHAIN_PREFIX=arm-none-eabi- \
       lk1st-msm8916 -j"$JOBS"

LK2ND_IMG="$SRCDIR/lk2nd/build-lk1st-msm8916/lk1st-msm8916.img"
[[ -f "$LK2ND_IMG" ]] || { echo "!! 未找到 lk2nd 产物，检查编译输出" >&2; exit 1; }

# ---------- 签名 ----------
# MSM8916 的随身WiFi 基本没开 secure boot，用 qtestsign 的假证书签名即可。
echo "==> 签名 ..."
mkdir -p "$FILESDIR"
python3 qtestsign/qtestsign.py hyp  qhypstub/qhypstub.elf -o "$FILESDIR/hyp.mbn"
python3 qtestsign/qtestsign.py aboot "$LK2ND_IMG"        -o "$FILESDIR/aboot.mbn"

ls -lh "$FILESDIR/hyp.mbn" "$FILESDIR/aboot.mbn"
echo "==> [03] 完成。下一步：./scripts/04-build-kernel.sh"
