# UFI103S_V02 · Debian 13 (trixie) 纯净固件构建套件

针对 **MSM8916（骁龙 410）/ 512MB RAM / 4GB eMMC** 随身 WiFi 棒，从源码构建一套
低内存占用、主线新内核、CPU 超频、开箱可用 ADB 的 Debian 13 固件。

> 这不是一个「下载就能刷」的现成镜像，而是一套**在你自己机器上跑的构建流水线**。
> 原因很简单：内核要编译、超频要改设备树、射频固件必须来自你自己的机器，
> 这三件事都不可能由别人代劳后通用。

---

## 一、先确认你的硬件

拆机看 PCB 丝印，必须是 **UFI103S_V02**（同方案的 V03/V05 大多也能用，但 DTB 可能要换）。

| 项目 | 值 |
|---|---|
| SoC | Qualcomm MSM8916（Snapdragon 410），四核 Cortex-A53 @ 1.2GHz，28nm |
| 内存 | 512MB LPDDR3（系统可见约 400-460MB） |
| 存储 | 4GB eMMC（可见约 3.2-3.4GB） |
| WiFi | 多为 WCN3620 over SDIO |
| 调试 UART | 板上有 TX/RX/GND 测试点，**UFI 系列是 3.3V 电平**（UZ801 是 1.8V，别搞混） |

主线内核对 MSM8916 的支持度很好——CPU、eMMC、USB、WiFi、4G 基带、GPU 全部可用，
这也是这台十几块钱的棒子能跑完整 Debian 的原因[citation:15]。

---

## 二、快速开始

### 没有 Linux 编译环境？用云端

**推荐路线**：推到 GitHub，用 Actions 云端编译，你只下载产物、在本机刷机。
详见 [`docs/GitHub-Actions云端构建.md`](docs/GitHub-Actions云端构建.md)。

```bash
git init && git add . && git commit -m "UFI103S Debian13 builder"
git push                      # 仓库设为 Public（机器大一倍且免费）
# GitHub 仓库页 → Actions → UFI103S Debian 13 Firmware → Run workflow
```

云端跑完下载 `boot.bin.xz` / `rootfs.bin.xz`，`xz -d` 解压后刷机。
刷机用的 edl / fastboot 在 **Windows 上也能跑**，所以你不需要 Linux。

### 有 Linux 构建机

构建机需要：**Debian 13 或 Ubuntu 22.04+（x86_64）、root、约 15GB 空闲磁盘、能联网**。

```bash
git clone <本套件>  ufi103s-debian13 && cd ufi103s-debian13

sudo ./scripts/00-prepare-host.sh      # 装依赖（交叉编译器、edl、fastboot）
sudo ./scripts/01-backup-edl.sh        # 【必做】9008 全盘备份 + 射频校准备份
sudo ./scripts/02-fetch-sources.sh     # 拉内核/lk2nd/qhypstub 源码
sudo ./scripts/03-build-bootchain.sh   # 编译 hyp.mbn + aboot.mbn(lk2nd)
sudo ./scripts/04-build-kernel.sh      # 编译内核 + 打超频补丁
sudo ./scripts/05-build-rootfs.sh      # debootstrap trixie + 精简 + ADB
sudo ./scripts/06-pack-images.sh       # 打包 boot.bin / rootfs.bin
sudo ./scripts/07-flash.sh             # 刷写
```

所有可调参数集中在 `config.env`，改那一个文件就够了。

---

## 三、四个诉求分别是怎么实现的

### 1. 内存占用少

512MB 是这台机器唯一的硬约束。做了这些：

| 手段 | 说明 | 大致收益 |
|---|---|---|
| `debootstrap --variant=minbase` | 最小根文件系统，不带任何任务套件 | 省几百 MB 磁盘 |
| 全局关闭 Recommends/Suggests | `apt.conf.d/99-ufi-minimal` | 避免装进一堆无用依赖 |
| 自编译内核开 `CONFIG_ZRAM` | 压缩内存当 swap 用 | **最关键**，见下 |
| 内核关 debug / ftrace / perf / kprobes / slub_debug / THP | `kernel-fragments/ufi-lowmem.config` | 省几 MB 常驻 |
| 关掉 bluetooth/avahi/cups/rsyslog/cron/定时任务 | rootfs 脚本里 systemctl disable | 省 20-40MB |
| journald 改 volatile + 16MB 上限 | 日志不落盘 | 省内存也保护 eMMC |
| /tmp /var/log /run 挂 tmpfs | fstab | 减少 eMMC 写入 |
| ModemManager 默认不自启 | `MODEM_MODE=ondemand` | **省 80-100MB** |
| 删掉 /usr/share/doc、man、info | 清理 | 省约 100MB 磁盘 |

**为什么 zram 必须由你自己编译内核**：多数现成的随身 WiFi Debian 底包把 zram
模块阉割了，`apt install zram-tools` 会直接报 `Job for zramswap.service failed`。
自己编译内核就能彻底解决这个问题——这是本套件相对现成镜像最实际的改进之一。

### 2. 内核最新

直接用 `msm8916-mainline/linux` 主线仓库编译，而不是用 postmarketOS 的预编译包。
`config.env` 里 `KERNEL_BRANCH=master` 拿最新；想求稳就改成具体 tag（如 `v6.12`）。

主线内核对 UFI 这类板子的 DTB 命名是 `msm8916-thwc-ufi001c`，
`config.env` 的 `DTB_CANDIDATES` 里放了好几个候选，**起不来就换**。

### 3. 芯片超频

默认目标 **1.4GHz**（`OC_MAX_HZ=1401600000`）。

选这个数不是随便定的：1.4016GHz 正是 **Snapdragon 412（MSM8916v2）的官方规格频率**，
也就是同一颗芯片的高配 SKU 频点。相比强行拉到 1.6GHz，它属于「合法频点」，
风险低得多，比默认的 1.2GHz 提升约 17%。

超频不是往设备树里塞个数字就完事，有两个坑：

- **电压必须由 CPR 管**。MSM8916 的电压由 CPR(Core Power Reduction) 驱动按
  fuse corner 动态调节，OPP 节点里的 `opp-microvolt` / `qcom,opp-fuse-level`
  必须和该内核版本里已有频点的写法一致。**不同内核版本写法不同，写死就会出错**——
  电压不足死机，电压过高伤芯片。
  所以 `tools/opp-overclock.py` 不硬编码数值，而是**解析你源码树里现有的 OPP 表，
  克隆最高频点的属性**来生成新节点。

  ```bash
  # 先看清楚现有频点
  python3 tools/opp-overclock.py --check --dtsi src/linux/arch/arm64/boot/dts/qcom/msm8916.dtsi
  # 再打补丁（可手动指定电压）
  python3 tools/opp-overclock.py --apply --hz 1401600000 --microvolt 1250000 --dtsi <同上>
  ```

- **改设备树不一定够**。CPU 频率还受 CPR 与 rpmpd(VDD_APC) 制约，
  启动后要验证：
  ```bash
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
  ```
  如果不是 1401600，说明被挡住了，处理方式见 `docs/排障与救砖.md`。

> ⚠️ 随身 WiFi 棒**没有散热片**。1.4GHz 满载会明显发热，建议贴一片散热片，
> 或在高负载场景下用 `cpufreq-set -u 1209600` 临时降回去。
> 超过 1.4GHz 属激进超频，可能死机甚至损伤芯片，本套件不提供该档位的默认配置。

### 4. ADB 调试

Debian trixie 官方仓库就有设备端 adbd（`adbd` 包，34.0.5-12，arm64 可用），
不需要去啃 AOSP 源码树。

难点在 USB gadget 的**时序**：必须在挂载 FunctionFS 之后、绑定 UDC 之前让 adbd
打开 endpoint。提前绑 UDC，主机枚举到的就是一个没有 adb 接口的残缺设备。

还有一个隐蔽的坑：adbd 启动后会**降权到 uid 2000**（AID_SHELL），
而 FunctionFS 的 ep0 默认 `root:root 0600`，权限不足会打不开，
adbd 会**静默退化成只监听 TCP**，USB 侧永远出不来。
解决办法是挂载时显式指定属主：

```sh
mount -t functionfs -o uid=2000,gid=2000 adb /dev/usb-ffs/adb
```

这两个点都写进了 `overlay/usr/local/sbin/ufi-usb-gadget` 和对应的 systemd 单元。
最终 USB 是一个**复合设备**：RNDIS 网卡（ssh 用）+ ADB（调试用）同时可用。

---

## 四、必读的风险

1. **01 步的备份不能跳。** 尤其是 `fsc/fsg/modemst1/modemst2`，
   这是每台机器唯一的射频校准数据，丢了 4G 和 IMEI 永久无法恢复，
   而且**不能用别的机器的同名文件顶替**。

2. **自编译固件有可能点不亮。** 社区已有明确案例：用 OpenStick-Builder 自行构建
   Debian 13 并修正 lk2nd compatible 后，boot/rootfs/aboot 回读校验全部一致，
   但冷启动后**只有红灯**，没有 USB gadget 也没有热点[citation:29]。
   写入校验成功只能证明存储层正确，证明不了 bootchain/内核/DTB/固件这个组合适配你的板子。

   **所以强烈建议分阶段刷**（`07-flash.sh` 默认就是这个思路）：
   先用社区已验证的镜像建立能启动的基线，再只替换 boot 分区试自己的内核，
   起不来随时能刷回去。不要一上来就 `--full` 重写整条启动链。

3. **强烈建议飞一根串口线。** 板子上的 TX/RX/GND 测试点接 USB-TTL
   （UFI 是 **3.3V**，波特率 115200 8N1）。没有串口日志，
   黑屏红灯时你根本不知道死在哪个阶段——sbl1、lk2nd、内核还是 userspace。
   这是所有随身 WiFi 折腾里性价比最高的一次投入。

4. Debian 系统有文件日志，**不能直接拔电**，要 `sudo poweroff` 后等几秒再拔，
   否则 ext4 容易损坏（去掉 journal 后风险更高，介意的话改回带日志的 mkfs.ext4）。

---

## 五、刷完之后的默认配置

| 项目 | 默认值 |
|---|---|
| USB 网关 | `192.168.68.1`（RNDIS） |
| WiFi 热点 | 见 `config.env` 的 `WIFI_SSID` / `WIFI_PSK` |
| 登录 | `user` / `1`（root 同密码） |
| ADB | 开机自启，USB 复合设备 |
| 4G 基带 | `MODEM_MODE=ondemand`，默认不自启，`systemctl start ModemManager` 拉起 |

**首次联网后请立刻改密码和 WiFi 密码。**

常用收尾命令：

```bash
sudo resize2fs /dev/disk/by-partlabel/rootfs   # 撑满 eMMC
zramctl && free -h                              # 确认 zram
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq   # 确认超频
systemctl status adbd ufi-usb-gadget            # 确认 ADB
```

---

## 六、目录结构

```
config.env                    所有可调参数
scripts/00-prepare-host.sh    装依赖
scripts/01-backup-edl.sh      9008 备份（唯一救砖凭据）
scripts/02-fetch-sources.sh   拉源码
scripts/03-build-bootchain.sh 编译 hyp.mbn + aboot.mbn
scripts/04-build-kernel.sh    编译内核 + 超频补丁
scripts/05-build-rootfs.sh    debootstrap + 精简 + ADB
scripts/06-pack-images.sh     打包 boot/rootfs 镜像
scripts/07-flash.sh           刷写（分阶段）
tools/opp-overclock.py        OPP 超频补丁生成器（自动继承电压属性）
.github/workflows/build.yml   GitHub Actions 云端编译（无本地编译环境时用它）
kernel-fragments/             内核低内存配置片段
overlay/                      直接进 rootfs 的配置（gadget/adbd/sysctl/zram）
docs/GitHub-Actions云端构建.md 云端编译全流程（含 runner 规格与额度限制）
docs/排障与救砖.md            红灯、DTB、超频不生效、救砖
```
