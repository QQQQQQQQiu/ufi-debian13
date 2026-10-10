#!/bin/bash
# =============================================================================
# 06 - 打包 boot.bin（ext2）与 rootfs.bin（ext4）
#
# boot 分区由 lk2nd 读取 /boot/extlinux/extlinux.conf 引导，和 u-boot 类似。
# rootfs 先做成较小的镜像，刷完在设备上 resize2fs 撑满 eMMC。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

echo "==> [06] 打包镜像"
[[ "$(id -u)" -eq 0 ]] || { echo "需要 root" >&2; exit 1; }

BOOT_SIZE_MB=64
ROOTFS_SIZE_MB=${ROOTFS_SIZE_MB:-1400}   # 4GB eMMC：刷完 resize2fs 撑满

MNT="$BUILDDIR/mnt"
mkdir -p "$MNT" "$FILESDIR"

# ---------- boot.bin ----------
echo "==> 制作 boot.bin (${BOOT_SIZE_MB}MB ext2) ..."
dd if=/dev/zero of="$FILESDIR/boot.bin" bs=1M count=$BOOT_SIZE_MB status=none
mkfs.ext2 -F -L boot "$FILESDIR/boot.bin" >/dev/null
mount -o loop "$FILESDIR/boot.bin" "$MNT"
trap 'umount -l "$MNT" 2>/dev/null || true' EXIT

mkdir -p "$MNT/dtbs/qcom" "$MNT/extlinux"
cp "$FILESDIR/Image.gz" "$MNT/"
cp "$FILESDIR/dtbs/qcom/"*.dtb "$MNT/dtbs/qcom/"

# extlinux.conf：起不来时改 FDT 行换 DTB，这是最常调的一处
cat > "$MNT/extlinux/extlinux.conf" <<EOF
# UFI103S_V02 / MSM8916 / Debian 13
# 起不来时改 FDT 这一行，换成 files/dtbs/qcom/ 下别的 dtb 试试
UI menu.c32
PROMPT 5
TIMEOUT 30
DEFAULT debian13

LABEL debian13
    MENU LABEL Debian 13 (${DTB_NAME})
    KERNEL /Image.gz
    FDT /dtbs/qcom/${DTB_NAME}.dtb
    APPEND root=/dev/disk/by-partlabel/rootfs rw \\
        console=ttyMSM0,115200 console=tty0 \\
        earlycon rootwait \\
        transparent_hugepage=never \\
        loglevel=4 systemd.show_status=0

LABEL debian13-fallback
    MENU LABEL Debian 13 (fallback DTB: uz801)
    KERNEL /Image.gz
    FDT /dtbs/qcom/msm8916-yiming-uz801v3.dtb
    APPEND root=/dev/disk/by-partlabel/rootfs rw \\
        console=ttyMSM0,115200 console=tty0 \\
        earlycon rootwait loglevel=7
EOF

sync
umount "$MNT"

# ---------- rootfs.bin ----------
echo "==> 制作 rootfs.bin (${ROOTFS_SIZE_MB}MB ext4) ..."
dd if=/dev/zero of="$FILESDIR/rootfs.bin" bs=1M count=$ROOTFS_SIZE_MB status=none
mkfs.ext4 -F -L rootfs -O ^has_journal,^metadata_csum "$FILESDIR/rootfs.bin" >/dev/null
# 注：^has_journal 去掉日志，省空间也减少 eMMC 写入；掉电风险略增，
#     如果担心文件系统损坏，改成 mkfs.ext4 -F -L rootfs 即可。
mount -o loop "$FILESDIR/rootfs.bin" "$MNT"
cp -a "$ROOTFSDIR/." "$MNT/"
sync

# fstab
ROOT_UUID=$(blkid -s UUID -o value "$FILESDIR/rootfs.bin")
BOOT_UUID=$(blkid -s UUID -o value "$FILESDIR/boot.bin")
cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID  /       ext4  defaults,noatime,nodiratime,errors=remount-ro  0 1
UUID=$BOOT_UUID  /boot   ext2  defaults,noatime                               0 2
tmpfs            /tmp    tmpfs defaults,nosuid,size=32M                       0 0
tmpfs            /var/log tmpfs defaults,nosuid,size=16M                      0 0
tmpfs            /run    tmpfs defaults,nosuid,size=16M                       0 0
EOF

umount "$MNT"
trap - EXIT

# ---------- sparse 化（fastboot 刷得更快） ----------
if command -v img2simg >/dev/null 2>&1; then
  echo "==> 转 sparse 镜像 ..."
  img2simg "$FILESDIR/boot.bin"   "$FILESDIR/boot.img"
  img2simg "$FILESDIR/rootfs.bin" "$FILESDIR/rootfs.img"
fi

echo
echo "==> 产物："
ls -lh "$FILESDIR/" | grep -E "boot|rootfs|Image|dtb"
echo
echo "==> [06] 完成。下一步：./scripts/07-flash.sh"
