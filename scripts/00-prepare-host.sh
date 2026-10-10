#!/bin/bash
# =============================================================================
# 00 - 准备构建主机（在 x86_64 的 Debian 13 / Ubuntu 22.04+ 上执行）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

echo "==> [00] 准备构建主机"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "本套件需要 root（chroot / loop 挂载）。请用 sudo 运行。" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  build-essential git curl wget ca-certificates python3 python3-pip \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  binutils-aarch64-linux-gnu \
  gcc-arm-none-eabi binutils-arm-none-eabi \
  bc bison flex libssl-dev libncurses-dev kmod cpio rsync xz-utils \
  debootstrap qemu-user-static binfmt-support \
  device-tree-compiler u-boot-tools \
  e2fsprogs dosfstools util-linux parted \
  android-sdk-libsparse-utils \
  libelf-dev dwarves pkg-config

# img2simg / simg2img 在不同发行版里包名不同，兜底检查
if ! command -v img2simg >/dev/null 2>&1; then
  echo "!! 缺少 img2simg（android-sdk-libsparse-utils）。"
  echo "   部分发行版已拆包，可手动安装或改用 fastboot 直接刷 raw 镜像。"
fi

# 启用 qemu 的 aarch64 binfmt（debootstrap 第二阶段需要）
if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
  update-binfmts --enable qemu-aarch64 2>/dev/null || true
fi

# bkerler/edl：9008 模式备份与救砖的唯一可靠工具
if [[ ! -d /opt/edl ]]; then
  echo "==> 安装 bkerler/edl（EDL 9008 工具）"
  git clone --depth 1 https://github.com/bkerler/edl /opt/edl
  pip3 install --break-system-packages -r /opt/edl/requirements.txt 2>/dev/null \
    || pip3 install -r /opt/edl/requirements.txt
  ln -sf /opt/edl/edl /usr/local/bin/edl 2>/dev/null || true
else
  echo "==> edl 已存在，跳过"
fi

# fastboot / adb
apt-get install -y android-sdk-platform-tools-common fastboot adb 2>/dev/null \
  || apt-get install -y android-tools-fastboot android-tools-adb

mkdir -p "$SRCDIR" "$BUILDDIR" "$ROOTFSDIR" "$FILESDIR" "$BACKUPDIR"

echo
echo "==> [00] 完成。下一步：sudo ./scripts/01-backup-edl.sh"
echo "    强烈建议先在原厂系统下确认 adb 可用：adb shell 'echo ok'"
