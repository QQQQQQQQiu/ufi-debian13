#!/bin/bash
# =============================================================================
# 07 - 刷写
#
# 强烈推荐的稳妥顺序（不要图快一次全刷）：
#   阶段 A：先刷社区已验证的 Debian 12 基线镜像，确认机器能起来
#   阶段 B：只替换 boot（自编译内核+DTB），起不来还能刷回 A 的 boot
#   阶段 C：再换 rootfs
#
# 本脚本默认走阶段 B+C（假设你已有可用的 aboot/hyp）。
# 若要全量刷（含 GPT、sbl1、tz、rpm、hyp、aboot），用 --full。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

echo "=========================================================================="
echo " 刷写  UFI103S_V02"
echo "=========================================================================="

if [[ $FULL -eq 1 ]]; then
  cat <<'TXT'
!! --full 会重写 GPT 与整条启动链。一旦刷错，只能靠 9008(EDL) 救回。
   请确认 backup/ 下已有 orig_fw.bin 和 fsc/fsg/modemst1/modemst2。
TXT
  read -r -p "确认已备份并继续全量刷写？输入 UFI103S 继续：" ok
  [[ "$ok" == "UFI103S" ]] || { echo "已取消。"; exit 1; }
fi

echo "==> 等待 fastboot 设备 ..."
echo "    进入 fastboot： adb reboot bootloader"
echo "    或：上电后约 1 秒内按住 RESET 键（时机很微妙，见文档）"
fastboot devices
[[ -n "$(fastboot devices)" ]] || { echo "!! 未检测到 fastboot 设备" >&2; exit 1; }

if [[ $FULL -eq 1 ]]; then
  echo "==> [全量] 刷 GPT 与启动链 ..."
  [[ -f "$FILESDIR/gpt_both0.bin" ]] && fastboot flash partition "$FILESDIR/gpt_both0.bin"
  [[ -f "$FILESDIR/sbl1.mbn"   ]] && fastboot flash sbl1 "$FILESDIR/sbl1.mbn"
  [[ -f "$FILESDIR/tz.mbn"     ]] && fastboot flash tz   "$FILESDIR/tz.mbn"
  [[ -f "$FILESDIR/rpm.mbn"    ]] && fastboot flash rpm  "$FILESDIR/rpm.mbn"
  fastboot flash hyp   "$FILESDIR/hyp.mbn"
  fastboot flash aboot "$FILESDIR/aboot.mbn"
  echo "==> 必须物理断电再上电，不要用 fastboot reboot"
  read -r -p "已断电重插并重新进入 fastboot？[y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || exit 1
fi

# ---------- boot ----------
echo "==> 刷 boot ..."
if [[ -f "$FILESDIR/boot.img" ]]; then
  fastboot flash boot "$FILESDIR/boot.img"
else
  fastboot flash boot "$FILESDIR/boot.bin"
fi

# ---------- rootfs ----------
echo "==> 刷 rootfs（较大，请耐心）..."
if [[ -f "$FILESDIR/rootfs.img" ]]; then
  fastboot -S 200M flash rootfs "$FILESDIR/rootfs.img"
else
  fastboot -S 200M flash rootfs "$FILESDIR/rootfs.bin"
fi

# ---------- 还原射频校准分区（全量刷时必须） ----------
if [[ $FULL -eq 1 ]]; then
  echo "==> 还原射频校准分区 ..."
  for p in fsc fsg modemst1 modemst2 persist sec; do
    [[ -s "$BACKUPDIR/${p}.bin" ]] && fastboot flash "$p" "$BACKUPDIR/${p}.bin"
  done
fi

echo "==> 刷写完成，请【物理断电再上电】（不要 fastboot reboot）"
cat <<'TXT'
==============================================================================
 首次启动检查清单
  1) USB 插入电脑后应出现 RNDIS 网卡，网关 192.168.68.1
     ssh user@192.168.68.1    密码 1
  2) ADB：
       adb devices           应看到设备
       adb shell
     若 adb 显示 unauthorized：把本机 ~/.android/adbkey.pub 内容
     追加到设备的 /root/.android/adb_keys
  3) WiFi 热点：默认 SSID/密码见 config.env（WIFI_SSID / WIFI_PSK）
  4) 撑满 eMMC：
       sudo resize2fs /dev/disk/by-partlabel/rootfs
  5) 确认超频生效：
       cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
       cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
  6) 确认 zram：
       zramctl ; free -h
  7) 起不来 / 只有红灯：见 docs/排障与救砖.md
==============================================================================
TXT
