#!/bin/bash
# =============================================================================
# 02 - 拉取源码（内核 / lk2nd / qhypstub / qtestsign）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

echo "==> [02] 拉取源码"
mkdir -p "$SRCDIR"
cd "$SRCDIR"

clone() { # url dir branch
  local url="$1" dir="$2" br="$3"
  if [[ -d "$dir/.git" ]]; then
    echo "    $dir 已存在，更新中..."
    git -C "$dir" fetch --depth 1 origin "$br" 2>/dev/null || git -C "$dir" fetch origin
    git -C "$dir" checkout -f "$br" 2>/dev/null || true
  else
    echo "    克隆 $dir (分支 $br) ..."
    git clone --depth 1 -b "$br" "$url" "$dir"
  fi
}

clone "$KERNEL_REPO" linux "$KERNEL_BRANCH"
clone "$LK2ND_REPO" lk2nd master
clone "$QHYPSTUB_REPO" qhypstub master
clone "$QTESTSIGN_REPO" qtestsign master

echo "==> 内核版本：$(git -C linux describe --tags 2>/dev/null || git -C linux rev-parse --short HEAD)"
echo "==> 可用 UFI/通用 DTB 候选："
ls linux/arch/arm64/boot/dts/qcom/ | grep -E "msm8916.*(thwc|uz801|ufi|mf800|jz)" || true

echo "==> [02] 完成。下一步：./scripts/03-build-bootchain.sh"
