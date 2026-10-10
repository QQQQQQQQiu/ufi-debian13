#!/bin/bash
# =============================================================================
# 01 - 9008(EDL) 全盘备份 —— 这一步是唯一能救砖的凭据，绝不能跳过
#
# 备份内容分两类，缺一不可：
#   1) 完整 eMMC 镜像            —— 变砖时整盘回写
#   2) 射频校准分区              —— fsc/fsg/modemst1/modemst2/persist/sec
#      这些是每台机器唯一的射频校准数据，丢了 4G 和 IMEI 就再也回不来，
#      而且绝不能拿别的机器的文件来顶替。
#
# 本脚本只做读取，不做任何写操作。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source config.env

CAL_PARTS=(fsc fsg modemst1 modemst2 persist sec DDR)

echo "=========================================================================="
echo " 9008 / EDL 全盘备份"
echo "=========================================================================="
cat <<'TXT'
进入 9008 模式（任选其一）：
  A) 设备已开 ADB：  adb reboot edl
  B) 长按板子上的 RESET / 恢复键不放，再插入电脑 USB
  C) 拆机短接 EDL 测试点后插 USB（按键失效时用）

确认方式：
  Linux   lsusb | grep -i 9008      应看到 QUALCOMM 9008
  Windows 设备管理器 → 端口(COM/LPT) 出现 9008
TXT

read -r -p "已进入 9008 模式？[y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "请先进入 9008 模式再运行本脚本。"; exit 1; }

mkdir -p "$BACKUPDIR"
cd "$BACKUPDIR"

EDL_BIN="$(command -v edl || echo '/opt/edl/edl')"
if [[ ! -x "$EDL_BIN" ]]; then
  echo "!! 未找到 edl。请先运行 00-prepare-host.sh，或手动安装 bkerler/edl" >&2
  exit 1
fi

# ---------- 1. 完整 eMMC ----------
if [[ -f orig_fw.bin ]]; then
  echo "==> orig_fw.bin 已存在，跳过全盘备份"
else
  echo "==> 正在读取完整 eMMC（4GB，约需数分钟，请勿断开）..."
  "$EDL_BIN" rf orig_fw.bin
fi

# ---------- 2. 射频校准分区 ----------
echo "==> 读取射频校准 / 关键分区..."
for p in "${CAL_PARTS[@]}"; do
  if [[ -s "${p}.bin" ]]; then
    echo "    ${p}.bin 已存在，跳过"
    continue
  fi
  if "$EDL_BIN" r "$p" "${p}.bin" 2>/dev/null; then
    echo "    OK  ${p}"
  else
    echo "    !!  ${p} 读取失败（该板可能无此分区，继续）"
    rm -f "${p}.bin"
  fi
done

# ---------- 3. 基带固件（modem / NON-HLOS） ----------
if [[ ! -s modem.bin ]]; then
  echo "==> 读取基带固件 modem..."
  "$EDL_BIN" r modem modem.bin 2>/dev/null || echo "    modem 分区名不同，稍后从原厂包提取"
fi

# ---------- 4. 校验 ----------
echo "==> 生成 SHA256SUMS ..."
sha256sum orig_fw.bin *.bin 2>/dev/null | grep -v SHA256SUMS > SHA256SUMS || true

echo
echo "==> 备份清单："
ls -lh "$BACKUPDIR"
echo
cat <<'TXT'
==============================================================================
 重要
  - backup/ 目录请立刻多复制一份到别的机器/网盘。它是唯一的救砖凭据。
  - fsc/fsg/modemst1/modemst2/persist/sec 是本机唯一射频校准数据，
    不要把别的机器的同名文件刷进来，也不要上传给任何人/AI。
  - 回写全盘：edl wf orig_fw.bin    （救砖用）
  - 回写单分区：edl w fsc fsc.bin
==============================================================================
TXT

echo "==> [01] 完成。下一步：./scripts/02-fetch-sources.sh"
