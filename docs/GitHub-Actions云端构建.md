# 用 GitHub Actions 云端编译

没有 Linux 编译环境时，这是最省事的路子：**代码和编译全在云端，你只管下载产物、在本机刷机**。
而且你大概只有 Windows——刷机用的 edl / fastboot 在 Windows 上都能跑，闭环是通的。

---

## 一、四个必须提前知道的坑

我查过 runner 规格，这三点不知道就会跑到一半失败：

### 1. 磁盘

官方文档写的是 14GB SSD，但**实测 `ubuntu-24.04`（image 20261004）拿到的是 145GB、
可用 86GB**——GitHub 已经扩容了。所以磁盘大概率不会成为瓶颈。

workflow 第一步仍然会删掉 `/opt/hostedtoolcache`、`.NET`、Android SDK、GHC、PowerShell
这些用不上的预装大件（约 2 分钟，能再腾出 30GB），内核编译完还会 `rm -rf src/linux`。
这些是保险措施，删了不亏。

### 2. apt 源可能很慢（但不致命）

runner 默认走 `azure.archive.ubuntu.com`，**实测低到约 240 kB/s**——
装依赖那 137MB 下了将近 10 分钟。这不是你的错，也不用管，只是慢。
workflow 里已经加了 `Acquire::Retries=5` 和超时设置防断流，job 6 小时上限足够宽裕。

### 3. artifact 额度只有 500MB，rootfs 有 1.4GB

Free 计划 artifact 存储 **500MB**，直接传 `rootfs.bin` 必挂。
所以打包后统一 `xz -6 -T0` 压缩——ext4 镜像里大半是空块，压缩率极高，
一般能压到一两百 MB。**下载后要先 `xz -d` 解压再刷。**

如果压缩后仍然超，或者你想长期保存，把 `publish_release` 勾上：
Release 单文件上限 **2GB**，不受 500MB 限制。

### 4. 公开仓库和私有仓库拿到的机器不一样

| | vCPU | RAM | 磁盘 | 分钟数 |
|---|---|---|---|---|
| **公开仓库** | **4** | **16GB** | 14GB | **免费无限** |
| 私有仓库（Free 计划） | 2 | 8GB | 14GB | 2000 分钟/月 |

**建议把仓库设成 Public。** 机器大一倍、编译快一倍、还不要钱。
仓库里只有构建脚本，没有任何你的私人数据——射频备份那些东西从来不需要上传。

另外单个 job 硬上限 6 小时，workflow 里设了 `timeout-minutes: 350`（约 5.8 小时）留余量。
4 核大约 40-70 分钟能编完；私有仓库 2 核可能要 2-3 小时，仍在时限内但慢很多。

---

## 二、操作步骤

### 0. 先跑探针（强烈建议，只要 3 分钟）

**在第一次全量构建之前**，先跑 `UFI103S 环境探针（快速诊断）` 这个 workflow，
参数全留空。它不编译任何东西，只把下面这些「我只能靠猜」的事情问清楚：

- 内核实际版本 / 分支名
- `arch/arm64/configs/` 里**真实存在**的 defconfig 名字
- 内核树里**真实存在**的 msm8916 板级 DTB 列表 ← 决定你的板子该用哪个
- OPP 表能否解析（超频补丁能否打上）
- lk2nd 有哪些 make 目标
- loop 挂载是否可用（决定打包走哪条路）
- debootstrap trixie / adbd 包是否可用

跑完把【1】~【8】的输出贴出来对齐一次，比盲跑一小时再排错划算得多。

## 二·五、探针实测基线（2026-10 跑出来的真实数据）

这份数据决定了上面那些默认值，记录了就不用再猜：

| 项目 | 实测结果 |
|---|---|
| 内核分支 | `wip/msm8916/7.0` |
| 内核版本 | **Linux 7.0**（`VERSION=7 PATCHLEVEL=0`），HEAD `ea3a5c52f` |
| defconfig | `msm8916_defconfig` **存在**；`qcom_defconfig` 不存在（全树仅 4 个 defconfig） |
| 随身WiFi 可用 DTB | `msm8916-thwc-ufi001c`、`msm8916-thwc-uf896`、`msm8916-yiming-uz801v3`、`msm8916-xiaoxun-jz0145-v33` |
| 全部 msm8916 DTB | 约 42 个，绝大多数是三星/摩托罗拉手机，与本设备无关 |
| OPP 表最高频点 | **998400000 Hz（998.4 MHz）** |
| OPP 节点属性 | **只有 `opp-hz`，没有 `opp-microvolt`** —— 电压由 CPR 驱动按 fuse 动态算 |
| lk2nd target | `target/` 下有 `msm8916`；顶层 Makefile 里 grep 不到目标定义 |
| loop 挂载 | **可用**（打包走这条路） |
| `mkfs -d` | **不可用**（已不作为兜底） |
| Debian trixie | 支持，当前 **13.7**，`adbd`/`zram-tools`/`modemmanager` 仓库均 HTTP 200 |
| qemu binfmt | 可用 |

### 关于超频档位的说明（探针数据推导）

这棵树把 MSM8916 当作 **1.0GHz 器件**（最高 998.4MHz），且电压不在设备树里写死。
加更高频点后，电压全靠 CPR 驱动外推，**没有手动调压的余地**。

- **1.2GHz（默认）**：从 998MHz 起跳 +21%，社区验证过的可行档位
- **1.4GHz**：+40%，CPR 外推跨度大，高负载死机风险明显更高，需自行承担

开机后核对实际频率：
```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
```
若不是目标值，多半被 speed-bin / CPR / rpmpd 挡住了。
真死机也不怕——进 fastboot 重刷未超频的 boot 分区即可恢复，不伤硬件。

### 1. 建仓库

把本套件推到 GitHub 仓库，**设为 Public**：

```bash
cd ufi103s-debian13
git init && git add . && git commit -m "UFI103S Debian13 builder"
git remote add origin https://github.com/<你的用户名>/ufi103s-debian13.git
git push -u origin main
```

### 2. 跑 workflow

仓库页面 → **Actions** → 左栏选 `UFI103S Debian 13 Firmware` → 右上 **Run workflow**

| 参数 | 建议值 | 说明 |
|---|---|---|
| `dtb_name` | `msm8916-thwc-ufi001c` | 探针已确认**该 DTB 确实存在**；起不来再换备选 |
| `oc_hz` | `1209600000` | 1.2GHz（+21%，推荐）；`1401600000`=1.4GHz（+40%，激进）；`0`=不超频 |
| `oc_microvolt` | 留空 | 当前内核 OPP 表**无此属性**，电压由 CPR 管，一般别填 |
| `modem_mode` | `ondemand` | 装但不自启，省 80-100MB |
| `kernel_ref` | **留空** | 用仓库默认分支（最稳）。要指定可填 `wip/msm8916/v6.18-rc4` 之类 |
| `rootfs_size_mb` | `1400` | 刷完在设备上 `resize2fs` 撑满 |
| `firmware_url` | 看下面 | modem/wcnss 固件包直链，可留空 |
| `publish_release` | 视情况 | 产物超 500MB 或要长期保存就勾上 |

> **别在 `kernel_ref` 里填 `master`。** 见下面「第一步就挂」那节。

### 3. 下载

跑完点进这次 run → 底部 **Artifacts** → 下载压缩包，解压得到：

```
boot.bin.xz      解压后刷 boot 分区
rootfs.bin.xz    解压后刷 rootfs 分区
hyp.mbn          自定义 hypervisor
aboot.mbn        lk2nd 二级 bootloader
kernel-version.txt
SHA256SUMS
```

---

## 三、云端拿不到什么（重要）

**GHA 再强也变不出你机器上唯一的那些东西。** 下面三样必须你在本机处理：

1. **射频校准** `fsc / fsg / modemst1 / modemst2 / persist / sec`
   每台机器唯一，丢了 4G 和 IMEI 永久无法恢复，也不能拿别人的顶替。
   必须本机 9008 备份，云端无法代劳。

2. **原厂启动链** `sbl1 / rpm / tz`
   来自原厂固件，云端没有。好消息是：如果你的棒子已经能进 fastboot，
   这几个分区不用动，只需刷 `hyp.mbn` + `aboot.mbn` + boot + rootfs。

3. **modem / WiFi 固件** `modem.* / wcnss.* / mba.mbn`
   闭源，来自原厂。两种办法：
   - workflow 的 `firmware_url` 填一个固件包的直链（你自己放到某个可下载的地方）
   - 或者刷完后手动拷进去：用 7z 打开 9008 全盘备份里的 `0.modem.fat`
     （它本身是个 FAT 镜像），把里面的文件全部拷到设备的 `/lib/firmware/`，reboot

   `.github/workflows/build.yml` 里的 `可选：装入 modem/wcnss 固件` 这一步就是干这个的，
   留空则跳过，之后手动补。

---

## 四、本机刷机（Windows / Linux 都行）

```bash
# 1) 解压
xz -d -k boot.bin.xz
xz -d -k rootfs.bin.xz

# 2) 9008 备份（还没做的话，必做！）
edl rf orig_fw.bin
for p in fsc fsg modemst1 modemst2 persist sec; do edl r $p $p.bin; done

# 3) 进 fastboot：adb reboot bootloader（或按键/短接）
fastboot devices

# 4) 刷（首次需要 hyp/aboot；之后重刷只需 boot + rootfs）
fastboot flash hyp    hyp.mbn
fastboot flash aboot  aboot.mbn
fastboot flash boot   boot.bin
fastboot -S 200M flash rootfs rootfs.bin

# 5) 物理断电再上电，不要 fastboot reboot
```

Windows 上 edl / fastboot / adb 都能跑（edl 用 `python edl.py`，fastboot/adb 用 platform-tools）。

---

## 五、构建失败的排查

### 第一步就挂：`fatal: Remote branch master not found in upstream origin`

**这是最常见的失败**，原因很朴素：`msm8916-mainline/linux` 这个仓库**没有 `master` 分支**。
它虽然在 GitHub 上叫 "forked from torvalds/linux"，但自己维护的分支命名是另一套。

修法（已修）：不再写死分支名，`kernel_ref` 留空时直接 `git clone` 默认分支（HEAD）。
lk2nd / qhypstub / qtestsign 同理，都不指定 `-b`。

如果你**确实**想指定某个内核分支，先在本地确认它存在：

```bash
git ls-remote --heads https://github.com/msm8916-mainline/linux.git
```

把输出里真实存在的分支名（去掉 `refs/heads/` 前缀）填进 `kernel_ref`。
已知主线开发用 `wip/msm8916/v6.18-rc4` 这类命名。

### lk2nd 编译报 "No rule to make target"

lk2nd 的 make 目标名在不同版本间会变。workflow 已改成依次尝试
`lk1st-msm8916` → `msm8916` → 默认目标，产物也改成 glob 查找，不再写死路径。

### Node.js 20 弃用警告

```
Node.js 20 is deprecated ... actions/cache@v4, actions/checkout@v4
```

只是警告，不影响运行——GitHub 把它们强制跑在 Node 24 上了。可以忽略。

---

## 六、起不来怎么办

**第一件事是换 DTB 重跑**，不用重新编译内核（ccache 会让第二次快很多）：
Run workflow → `dtb_name` 依次试：

`msm8916-thwc-ufi001c` → `msm8916-thwc-uf896` → `msm8916-yiming-uz801v3` → `msm8916-fy-mf800`

ccache 的 key 里带了 `dtb_name`，严格说换 DTB 会 miss 一次 cache；
但 `restore-keys` 会回退到同内核分支的缓存，重编译仍然比首次快得多。

更快的办法是**不用重跑**：boot 分区里已经放了全部候选 DTB，
改 `/boot/extlinux/extlinux.conf` 的 `FDT` 行，或开机菜单直接选 `debian13-fallback` 那一项。

其它问题（红灯、超频没生效、ADB 出不来、救砖）见 `排障与救砖.md`。

---

## 七、想要更快拿到能启动的基线？

如果你不想第一次就赌自编译内核能不能点亮，可以分两步：

1. **先 fork `G-huohuo/OpenStick-Builder`**（它官方支持 GitHub Actions，
   fork 后 Run workflow 就能出 Debian 13 镜像，用的是 postmarketOS 预编译内核，稳）。
   刷进去建立「能启动」的基线，顺便确认你的板子和 DTB 对得上。
2. **再用本套件只替换 boot 分区**（自编译内核 + 超频 + 完整 ADB）。
   起不来随时刷回第 1 步的 boot，永远有退路。

这比一上来就全量刷自编译固件稳妥得多——社区有明确案例：
boot/rootfs/aboot 回读校验全部一致，冷启动依然只有红灯。
**写入校验成功只证明存储层正确，证明不了 bootchain+内核+DTB+固件这个组合适配你的板子。**
