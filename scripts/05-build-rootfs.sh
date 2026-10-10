#!/bin/bash
# =============================================================================
# 05 - 构建 Debian 13 (trixie) 根文件系统：纯净 + 低内存 + ADB
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

ROOTFS="$ROOTFSDIR"
MODULES="$BUILDDIR/modules"

echo "==> [05] 构建 Debian $DEBIAN_SUITE rootfs"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "需要 root（chroot / mount）" >&2; exit 1
fi
[[ -f "$FILESDIR/modules.tar.gz" ]] || { echo "!! 先跑 04-build-kernel.sh" >&2; exit 1; }

# ---------- 1. debootstrap 第一阶段 ----------
if [[ -d "$ROOTFS/bin" ]]; then
  echo "==> rootfs 已存在，跳过 debootstrap（如需重来：rm -rf $ROOTFS）"
else
  echo "==> debootstrap --variant=$DEBIAN_VARIANT $DEBIAN_SUITE ..."
  debootstrap --arch arm64 --foreign \
    --variant="$DEBIAN_VARIANT" \
    --components="$DEBIAN_COMPONENTS" \
    --include="ca-certificates,locales,tzdata" \
    "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

  echo "==> 第二阶段（qemu 模拟 arm64）..."
  cp -a /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
  chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
fi

# ---------- 2. 挂载并进入 chroot ----------
mount_chroot() {
  mount --bind /dev  "$ROOTFS/dev"
  mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
  mount -t proc proc "$ROOTFS/proc"
  mount -t sysfs sys "$ROOTFS/sys"
  mount --bind /run  "$ROOTFS/run" 2>/dev/null || true
}
umount_chroot() {
  for m in run sys proc dev/pts dev; do
    umount -l "$ROOTFS/$m" 2>/dev/null || true
  done
}
mount_chroot
trap umount_chroot EXIT

# ---------- 3. 软件源 ----------
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE $DEBIAN_COMPONENTS
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates $DEBIAN_COMPONENTS
deb http://security.debian.org/debian-security $DEBIAN_SUITE-security $DEBIAN_COMPONENTS
EOF

# ---------- 4. 装包（按需选择，全部不装 Recommends） ----------
echo "==> 安装基础软件包..."
chroot "$ROOTFS" bash -c "apt-get update"

# 4G 基带相关包：按 MODEM_MODE 决定
case "$MODEM_MODE" in
  onboot|ondemand) MODEM_PKGS="modemmanager" ;;
  none)            MODEM_PKGS="" ;;
esac

chroot "$ROOTFS" bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd systemd-sysv udev dbus \
  openssh-server \
  network-manager \
  wireless-tools wpasupplicant iw \
  adbd \
  zram-tools \
  procps psmisc htop \
  vim-tiny nano curl wget ca-certificates \
  iproute2 iptables isc-dhcp-client \
  tzdata locales \
  ${MODEM_PKGS}"

# ---------- 5. 内核模块 ----------
echo "==> 安装内核模块..."
mkdir -p "$ROOTFS/lib/modules"
tar -C "$ROOTFS" -xzf "$FILESDIR/modules.tar.gz"
chroot "$ROOTFS" depmod -a "$(cat "$FILESDIR/kernel-version.txt")" 2>/dev/null || true

# ---------- 6. Qualcomm 固件（modem/wcnss） ----------
# 从 01 步的备份里提取；随身WiFi 的 WiFi/基带固件是闭源的，缺了就起不来。
if [[ -x "$(command -v edl || true)" ]] || [[ -d "$BACKUPDIR" ]]; then
  echo "==> 提示：固件提取见 scripts/05b-extract-firmware.sh"
fi
mkdir -p "$ROOTFS/lib/firmware"

# ---------- 7. 拷贝 overlay（ADB / gadget / 内存优化） ----------
echo "==> 部署 overlay ..."
rsync -a "$WORKDIR/overlay/" "$ROOTFS/" 2>/dev/null \
  || cp -a "$WORKDIR/overlay/." "$ROOTFS/"
chmod +x "$ROOTFS/usr/local/sbin/ufi-usb-gadget"

# ---------- 8. adbd 运行所需的 shell 用户（uid/gid 2000 = AID_SHELL） ----------
chroot "$ROOTFS" bash -c "
  getent group shell >/dev/null || groupadd -g 2000 shell
  getent passwd shell >/dev/null || useradd -u 2000 -g 2000 -M -s /bin/bash -d /home/shell shell
  mkdir -p /root/.android /dev/usb-ffs
"

# ---------- 9. 基础系统配置 ----------
echo "==> 系统配置..."
echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
EOF

# 用户
chroot "$ROOTFS" bash -c "
  useradd -m -s /bin/bash -G sudo,adm $USERNAME 2>/dev/null || true
  echo '$USERNAME:$PASSWORD' | chpasswd
  echo 'root:$PASSWORD' | chpasswd
"

# locale / 时区
chroot "$ROOTFS" bash -c "
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
  locale-gen 2>/dev/null || true
  echo 'LANG=C.UTF-8' > /etc/default/locale
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  echo 'Asia/Shanghai' > /etc/timezone
"

# 串口控制台（调试生命线）
chroot "$ROOTFS" bash -c "
  systemctl enable serial-getty@ttyMSM0.service 2>/dev/null || true
  systemctl enable systemd-networkd.service 2>/dev/null || true
"

# ---------- 10. 内存优化：关掉用不上的服务 ----------
echo "==> 精简服务（省内存）..."
chroot "$ROOTFS" bash -c "
  # 4G 基带：按需启动模式默认不开机自启
  if [ '$MODEM_MODE' != 'onboot' ]; then
    systemctl disable ModemManager.service 2>/dev/null || true
  fi
  [ '$MODEM_MODE' = 'none' ] && (systemctl mask ModemManager.service 2>/dev/null || true)

  # 以下服务在随身WiFi 上无意义，全部关掉
  for s in \
    bluetooth.service \
    avahi-daemon.service \
    cups.service \
    rsyslog.service \
    cron.service \
    apt-daily.timer apt-daily-upgrade.timer \
    man-db.timer \
    e2scrub_all.timer \
    fstrim.timer \
    systemd-timesyncd.service ; do
    systemctl disable \$s 2>/dev/null || true
  done

  # journald 限制：512MB 机器上日志不能无上限
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-lowmem.conf <<'JCF'
[Journal]
SystemMaxUse=16M
RuntimeMaxUse=8M
MaxRetentionSec=3day
Storage=volatile
Compress=yes
ForwardToSyslog=no
JCF

  # adbd / usb gadget 开机启动
  systemctl enable ufi-usb-gadget.service
  systemctl enable adbd.service
"

# ---------- 11. zram ----------
if [[ "$ENABLE_ZRAM" == "yes" ]]; then
  echo "==> 配置 zram (${ZRAM_SIZE_PERCENT}% / $ZRAM_ALGO) ..."
  cat > "$ROOTFS/etc/default/zramswap" <<EOF
ALGO=$ZRAM_ALGO
PERCENT=$ZRAM_SIZE_PERCENT
PRIORITY=100
EOF
  chroot "$ROOTFS" systemctl enable zramswap.service 2>/dev/null || true
fi

# ---------- 12. 网络：USB 网卡 + WiFi AP ----------
echo "==> 预置网络连接..."
mkdir -p "$ROOTFS/etc/NetworkManager/system-connections"
cat > "$ROOTFS/etc/NetworkManager/system-connections/usb0.nmconnection" <<EOF
[connection]
id=usb0
type=gsm
interface-name=usb0
autoconnect=true

[ipv4]
method=shared
address1=$USB_GW_IP
EOF
cat > "$ROOTFS/etc/NetworkManager/system-connections/WiFi-AP.nmconnection" <<EOF
[connection]
id=WiFi-AP
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=ap
ssid=$WIFI_SSID
band=bg
channel=6

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=shared
address1=$WIFI_GW_IP
EOF
chmod 600 "$ROOTFS/etc/NetworkManager/system-connections/"*.nmconnection

# USB RNDIS 网关固定 IP（gadget 起来后由 NM 管理）
chroot "$ROOTFS" bash -c "
  nmcli connection reload 2>/dev/null || true
"

# ---------- 13. 清理 ----------
echo "==> 清理缓存..."
chroot "$ROOTFS" bash -c "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  rm -f /usr/bin/qemu-aarch64-static
  rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* 2>/dev/null || true
"

umount_chroot
trap - EXIT

echo "==> rootfs 大小：$(du -sh "$ROOTFS" | cut -f1)"
echo "==> [05] 完成。下一步：./scripts/06-pack-images.sh"
