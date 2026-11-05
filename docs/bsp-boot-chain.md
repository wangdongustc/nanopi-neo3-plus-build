# BSP 启动链对接

给自研 SD 写盘用。产物是一张可冷启动的 SD：FriendlyELEC U-Boot + kernel 6.1，只换 Ubuntu 26.04 rootfs。本仓库不提交 `img` / `bin` / `tgz`。

主路径与 [ADR-0002](adr/0002-own-image-builder.md) 对齐：本仓库 [`scripts/build-image.sh`](../scripts/build-image.sh) 用 GPT + `dd` 写盘，扇区以 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 为准。入口是逐个文件参数（`--idbloader` 等），不扫描目录。用户态见 [ADR-0001](adr/0001-userland-resolute-debootstrap.md)，步骤见 [构建提纲](build-outline.md)。

FriendlyELEC `sd-fuse_rk3528` 只提供分区、loader 和预编译文件的对照。`sd_update` / `fusing.sh` 可以临时对照偏移或在自研灌装落地前退路出卡，不是并列的打包入口。产品分区表用 plain 布局（与 `parameter-plain.txt` 的扇区一致）。不读 Wiki 的 eMMC `parted`，也不用官方包里带 userdata 的 OverlayFS `parameter.txt`。

核对日期 2026-11-05。下面的官方包用来说明文件从哪来、plain 与 OverlayFS 差在哪。

## 1. U-Boot、kernel、DTB 从哪来

钉死 FriendlyELEC 仓库，不用主线 U-Boot / 主线 kernel。

| 部件 | 仓库 | 分支 | 用途 |
| --- | --- | --- | --- |
| 写盘（主路径） | 本仓库 [`scripts/build-image.sh`](../scripts/build-image.sh) | — | GPT + `dd`。布局见 [`scripts/partition-layout.md`](../scripts/partition-layout.md) |
| 对照 | [sd-fuse_rk3528](https://github.com/friendlyarm/sd-fuse_rk3528) | `kernel-6.1.y` | `parameter-plain.txt`、预编译分区。`fusing.sh` / `sd_update` 只作对照或退路 |
| U-Boot | [uboot-rockchip](https://github.com/friendlyarm/uboot-rockchip) | `nanopi5-v2017.09` | 自编时用上游 `build-uboot.sh`（`./make.sh nanopi_zero2`），产物交给 `--uboot` |
| kernel / DTB | [kernel-rockchip](https://github.com/friendlyarm/kernel-rockchip) | `nanopi6-v6.1.y` | 自编时用上游 `build-kernel.sh`，默认 `KCFG=nanopi5_linux_defconfig kvm.config`，产物交给 `--kernel` / `--resource` |

`build-uboot.sh` 的板级目标是 `nanopi_zero2`（`configs/nanopi_zero2_defconfig`：`CONFIG_ROCKCHIP_RK3528`、`CONFIG_ROCKCHIP_NEW_IDB`、`CONFIG_DEFAULT_DEVICE_TREE="rk3528-nanopi-zero2"`）。该分支的 `configs/` 里没有 NEO3 Plus 专用 defconfig。Wiki 示例里的 `./make.sh nanopi_r3` 是另一份 defconfig，不要拿来编这块板。NEO3 Plus 的内核 DTS 是 [rk3528-nanopi-rev02.dts](https://github.com/friendlyarm/kernel-rockchip/blob/nanopi6-v6.1.y/arch/arm64/boot/dts/rockchip/rk3528-nanopi-rev02.dts)：`model = "FriendlyElec NanoPi NEO3 Plus"`，`compatible = "friendlyelec,nanopi-neo3-plus", "rockchip,rk3528"`。`rk3528-nanopi-rev01.dts` 是 NanoPi Zero2。DTB 打进 `resource.img`，由 U-Boot 按 compatible 挑选。

### 推荐基线：官方预编译分区，只换 rootfs

下载入口：<https://downloads.friendlyelec.com/os-images/rk3528/images/>。`tools/get_rom.sh` 使用的稳定 URL 与 [sd-fuse README](https://github.com/friendlyarm/sd-fuse_rk3528/blob/kernel-6.1.y/README.md) 相同。

```bash
wget -O ubuntu-noble-core-arm64-images.tgz \
  https://downloads.friendlyelec.com/os-images/rk3528/images/ubuntu-noble-core-arm64-images.tgz
wget -O ubuntu-noble-core-arm64-images.tgz.sha256 \
  https://downloads.friendlyelec.com/os-images/rk3528/images/ubuntu-noble-core-arm64-images.tgz.sha256
sha256sum -c ubuntu-noble-core-arm64-images.tgz.sha256
tar -tzf ubuntu-noble-core-arm64-images.tgz
tar -xOf ubuntu-noble-core-arm64-images.tgz ubuntu-noble-core-arm64/parameter.txt
```

2026-11-05 该 URL 302 到 `ubuntu-noble-core-arm64-images-20280806.tgz`。发布的 `.sha256` 为：

```text
901db07662de13f33becb8b1aeb674c8ae894e83a9ee24865badefc2ab4e2da5  ubuntu-noble-core-arm64-images.tgz
```

包内目录 `ubuntu-noble-core-arm64/`（`info.conf`：`os-id=ubuntu-noble-core-arm64`，`version=20280806`，`title=Ubuntu 24.04 Core`）：

| 包内路径 | 字节数 | 冷启动 SD 用途 |
| --- | ---: | --- |
| `idbloader.img` | 309248 | 必写。GPT 之前的 loader，见第 2 节 |
| `uboot.img` | 4194304 | 可原样复用，分区 `uboot` |
| `misc.img` | 49152 | 可原样复用，分区 `misc` |
| `dtbo.img` | 880 | 这是 OverlayFS 版。产品卡换成 `prebuilt/dtbo-plain.img` |
| `resource.img` | 10245120 | 可原样复用。vendor DTB + logo |
| `kernel.img` | 36132884 | 可原样复用。6.1 内核 |
| `boot.img` | 8379340 | 可原样复用。ramdisk |
| `rootfs.img` | 2018452024 | 必须换成 Resolute。文件是 android sparse，不是裸 ext4 |
| `userdata.img` | 159868 | plain 布局不用 |
| `parameter.txt` | 472 | OverlayFS 默认表。产品卡换成 `prebuilt/parameter-plain.txt` |
| `MiniLoaderAll.bin` | 465344 | 不写入 SD 用户区。USB 下载用，本文不展开 |
| `info.conf` | 92 | 包说明，不写盘 |

包内没有 `trust.img`，也没有 `recovery.img`。

`prebuilt/idbloader.img`（同一分支）与包内 `idbloader.img` 字节相同，sha256：

```text
1b85c9fc51728c3673aa2473f79b0db9d43ea157940f8636a5c4dbd0ebaf3553
```

### 自编

在 sd-fuse 工作区里编，产物留在该工作区。不要拷进本仓库。

```bash
git clone https://github.com/friendlyarm/sd-fuse_rk3528 -b kernel-6.1.y --single-branch
cd sd-fuse_rk3528
# 需要官方分区目录时再下 ubuntu-noble-core-arm64-images.tgz 并解压

git clone https://github.com/friendlyarm/uboot-rockchip -b nanopi5-v2017.09 --depth 1 uboot
UBOOT_SRC=uboot ./build-uboot.sh ubuntu-noble-core-arm64
```

`build-uboot.sh` 会把 `rkbin`（分支 `nanopi5`）克隆到 U-Boot 源码同级，然后 `./make.sh nanopi_zero2`。`tools/update_uboot_bin.sh` 只把 `rk3528_spl_loader_*.bin` 或 `rk3528_loader_*.bin` 抄成 OS 目录里的 `MiniLoaderAll.bin`，并复制 `uboot.img`。它不生成 `idbloader.img`。SD 冷启动继续用上一节那份 `idbloader.img`，直到 BSP 给出新的 RKNS 打包结果并在板上确认。

```bash
git clone https://github.com/friendlyarm/kernel-rockchip -b nanopi6-v6.1.y --depth 1 kernel
KERNEL_SRC=kernel ./build-kernel.sh ubuntu-noble-core-arm64
```

`build-kernel.sh` 的 `make nanopi5-images` 生成两份文件，再由 `tools/update_kernel_bin_to_img.sh` 放进 OS 目录：

- `kernel.img`：`scripts/mkkrnlimg arch/arm64/boot/Image kernel.img`
- `resource.img`：`scripts/mkimg --dtb 'rk3*-nanopi*-rev*.dtb' --keep-dtb-name`，带上 `logo.bmp` 与 `logo_kernel.bmp`

OS 目录里如果已经有 Resolute 的 `rootfs.img`，`build-kernel.sh` 会把它拆开、塞进新模块，并按 `prebuilt/parameter.template` 重写 `parameter.txt`。编内核前先把 Resolute `rootfs.img` 挪走；编完只取 `kernel.img` 和 `resource.img`，再把 rootfs 和 plain 参数放回去。

本仓库不存这些文件。构建机上的 sd-fuse 工作区或以后的 `out/` 都保持在 git 之外。

## 2. 冷启动 SD 的最小分区

### 写盘以哪份表为准

产品卡的扇区与 sd-fuse `kernel-6.1.y` 的 [`prebuilt/parameter-plain.txt`](https://github.com/friendlyarm/sd-fuse_rk3528/blob/kernel-6.1.y/prebuilt/parameter-plain.txt) 一致，dtbo 用 [`prebuilt/dtbo-plain.img`](https://github.com/friendlyarm/sd-fuse_rk3528/blob/kernel-6.1.y/prebuilt/dtbo-plain.img)。这是 2GB 上关闭 OverlayFS 的硬约束。本仓库把这张表写在 [`scripts/partition-layout.md`](../scripts/partition-layout.md)，`build-image.sh` 按那份实现。

官方包里的 `parameter.txt` 用来说明 OverlayFS 默认长什么样。Wiki 的 eMMC `parted` 示例不采用：它多一个 `trust`、没有 `recovery`，扇区与下面两份 parameter 对不上。`sd_update` 读的是 OS 目录里的 `parameter.txt`，不读 Wiki。

三份材料的差异：

| 项 | 产品：`parameter-plain.txt` | 官方包 `parameter.txt`（OverlayFS 默认） | Wiki eMMC `parted` 示例 |
| --- | --- | --- | --- |
| 来源 | sd-fuse `kernel-6.1.y` `prebuilt/parameter-plain.txt` | `ubuntu-noble-core-arm64/parameter.txt`，包版本 `20280806` | [NanoPi NEO3 Plus Wiki](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_NEO3_Plus) “Install to target board” |
| `trust` | 无 | 无。包内也无 `trust.img` | 有，插在 `uboot` 和 `misc` 之间 |
| `recovery` | 有，第 7 项，`0x10000` 扇区 | 有，同样位置 | 无 |
| `rootfs` | 第 8 项，`-@0x00046000(rootfs:grow)` | 第 8 项，固定 `0x00460000` 扇区 | 第 8 项，示例上约 134MB–2500MB |
| `userdata` | 无 | 第 9 项，`-@0x004a6000(userdata:grow)` | 有，第 9 项 |
| 前 7 项几何 | `uboot,misc,dtbo,resource,kernel,boot,recovery`，起点见下表 | 与 plain 相同 | 因插入 `trust` 而整体后移 |

plain 把 rootfs 撑到盘尾，去掉 userdata，这样没有 OverlayFS 的 upper 分区。官方默认把 rootfs 固定为 `0x460000` 个扇区（2240 MiB，从 140 MiB 到 2380 MiB），后面整段是 userdata。dtbo 必须和这张表一起换，只改 parameter 不够。

`dtbo.img`（880 字节，与官方包相同）里 SD 那条 bootargs 是：

```text
root=/dev/mmcblk0p8 rw rootfstype=ext4 data=/dev/mmcblk0p9 consoleblank=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
```

`data=/dev/mmcblk0p9` 就是 OverlayFS 的 upper。`dtbo-plain.img`（752 字节）的 SD 条是：

```text
cgroup_enable=memory cgroup_memory=1 consoleblank=0 root=/dev/mmcblk0p8 rw rootfstype=auto
```

没有 `data=`。root 仍是 `mmcblk0p8`，所以 GPT 里 rootfs 必须保持第 8 项。删掉 recovery 或按 Wiki 插进 trust，都会让第 8 项不再是 rootfs。

Wiki 设备节点：SD 是 `/dev/mmcblk0`，eMMC 是 `/dev/mmcblk2`。同一份 dtbo 里两条 fragment 各写一套。冷启动 SD 走 `mmcblk0`。

### 官方包里的 parameter.txt

复现：`tar -xOf ubuntu-noble-core-arm64-images.tgz ubuntu-noble-core-arm64/parameter.txt`。全文：

```text
FIRMWARE_VER: 12.0
MACHINE_MODEL: RK3528
MACHINE_ID: 007
MANUFACTURER: RK3528
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: nanopi-z2
CHECK_MASK: 0x80
PWR_HLD: 0,0,A,0,1
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00002000@0x00006000(misc),0x00002000@0x00008000(dtbo),0x00008000@0x0000a000(resource),0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),0x00460000@0x00046000(rootfs),-@0x004a6000(userdata:grow)
```

这是 OverlayFS 默认，不是产品卡。`CMDLINE` 里 `长度@起点(名字)`，单位是 512 字节扇区。

### 产品卡：parameter-plain.txt

文件路径：`sd-fuse_rk3528` `kernel-6.1.y` 的 `prebuilt/parameter-plain.txt`。原样复制到 OS 目录的 `parameter.txt`，不要手改文件头。文件头仍是上游的 `MACHINE_MODEL: RK356X` / `MACHINE: NanoPi5`，分区 `CMDLINE` 的前 7 项与上面的 RK3528 表一致。

```text
FIRMWARE_VER: 12.0
MACHINE_MODEL: RK356X
MACHINE_ID: 007
MANUFACTURER: RK356X
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: NanoPi5
CHECK_MASK: 0x80
PWR_HLD: 0,0,A,0,1
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00002000@0x00006000(misc),0x00002000@0x00008000(dtbo),0x00008000@0x0000a000(resource),0x00014000@0x00012000(kernel),0x00010000@0x00026000(boot),0x00010000@0x00036000(recovery),-@0x00046000(rootfs:grow)
```

`build-rootfs-img.sh` 在打完 ext4 后会用 `prebuilt/parameter.template` 重写 `parameter.txt`（rootfs 固定大小 + `userdata:grow`）。plain 文件要在这之后再覆盖一次。`dtbo-plain.img` 同样在这之后覆盖 `dtbo.img`。

扇区 512 字节。GPT 项的结束扇区按包含终点计算（`end = start + size - 1`）：

| # | 名字 | 起点 LBA | 扇区数 | 结束 LBA | 起点字节 |
| --- | --- | --- | --- | --- | --- |
| — | `idbloader.img` | `0x40` | 文件 604 扇区，表上上限 `0x1400` | 落在主 GPT 之后、`uboot` 之前 | 32 KiB |
| 1 | uboot | `0x4000` | `0x2000` | `0x5FFF` | 8 MiB |
| 2 | misc | `0x6000` | `0x2000` | `0x7FFF` | 12 MiB |
| 3 | dtbo | `0x8000` | `0x2000` | `0x9FFF` | 16 MiB |
| 4 | resource | `0xA000` | `0x8000` | `0x11FFF` | 20 MiB |
| 5 | kernel | `0x12000` | `0x14000` | `0x25FFF` | 36 MiB |
| 6 | boot | `0x26000` | `0x10000` | `0x35FFF` | 76 MiB |
| 7 | recovery | `0x36000` | `0x10000` | `0x45FFF` | 108 MiB |
| 8 | rootfs | `0x46000` | 直到盘尾 | 留给备份 GPT | 140 MiB |

recovery 分区要建，即使没有 `recovery.img`。空着即可，这样 rootfs 仍是第 8 项。不要加 `trust`，不要加 `userdata`。

主 GPT 常规占用 LBA 1（头）和 LBA 2–33（分区表）。`idbloader` 从 LBA 64 开始，与主表不重叠。rootfs 结束于磁盘最后一扇区减 33，把备份 GPT 留出来。第一次用 `sgdisk -p` 对一张 `sd_update` 写出的卡核对这个结尾。

### idbloader 用哪一种

SD 冷启动写 `idbloader.img`。文件头 4 字节是 `RKNS`（`52 4b 4e 53`），对应 `CONFIG_ROCKCHIP_NEW_IDB`。

文件内部的字符串表同时有 `rksd`（`Rockchip SD Boot Image`）和 `rkspi`（`Rockchip SPI Boot Image`）。那是 loader 自己的介质名，不是两份可选镜像。官方包不提供单独的 rkspi 文件，SD 写盘也不使用它。

`fusing.sh` 的证据（`kernel-6.1.y`）：

- 注释写着 “Fusing idbloader, bootloader, trust to card”，并定义了 `fusing_bin()`：`dd if=$1 of=/dev/${DEV_NAME} bs=512 seek=$2`。脚本后文没有调用 `fusing_bin`，所以偏移不在这个 shell 函数里。
- 上游脚本里实际写卡的是 `tools/${HOST_ARCH}sd_update -d /dev/${DEV_NAME} -p ${RK_PARAMETER_TXT}`。`mk-sd-image.sh` 对普通 OS 也是直接调 `sd_update`，不经过 `fusing.sh`。本仓库主路径不走这两支脚本。
- x86-64 `tools/sd_update`（BuildID `de40719becf8e128f8ee5ee7e082e32ff6b981a9`）和 aarch64 `tools/aarch64/sd_update`（BuildID `a59cbc2cb6e0b63ae619181a40bed7be6784d751`）都内嵌同一张表：`idbloader.img` 起点 LBA `0x40`、长度 `0x1400` 扇区。`TYPE: GPT` 时走这张表。非 GPT 才会再把 `parameter.txt` 当作 RAW 写到 LBA `0x2000`。

这两份 parameter 都是 `TYPE: GPT`。上游 `sd_update -p` 才读取 `parameter.txt`；本仓库写盘不把该文件当输入，也不要把它 dd 到 LBA `0x2000`。

U-Boot `make.sh` 的 `pack_idblock()` 会跑 `./tools/mkimage -n ${PLAT} -T rksd -d ${TPL_BIN}:${SPL_BIN} idblock.bin`。`build-uboot.sh` 不调用它。`idblock.bin` 不是本写盘输入。`MiniLoaderAll.bin` 也不是：它和 `idbloader.img` 大小不同（465344 对 309248），留给 USB 下载。

### 谁可以复用，谁必须换

| 文件 | 产品卡 |
| --- | --- |
| `idbloader.img` | 复用官方包 / `prebuilt` 那一份 |
| `uboot.img`、`misc.img`、`resource.img`、`kernel.img`、`boot.img` | 可复用官方包。BSP 自编后只替换对应文件 |
| `dtbo.img` | 换成 `prebuilt/dtbo-plain.img` |
| `parameter.txt` | 换成 `prebuilt/parameter-plain.txt` |
| `rootfs.img` | 必须换成 Resolute |
| `userdata.img`、`trust.img`、`MiniLoaderAll.bin` | 不写入这张 SD |
| `recovery` 分区 | 建空分区，不需要镜像文件 |

### 启动顺序

片内 Maskrom / BootROM 从 SD 的 LBA 64 读到 `RKNS` 的 `idbloader.img`（DDR 初始化 + SPL）。SPL 加载 `uboot` 分区里的 `uboot.img`。U-Boot 读 GPT（几何与 plain `CMDLINE` 相同，实现以 `scripts/partition-layout.md` 为准），再加载 `kernel`、`resource`（DTB + logo）和 `boot`（ramdisk），内核把根切到第 8 项 rootfs。

eMMC 安装和 Maskrom 救砖见 Wiki 的 USB flashing / eflasher。本文不写。

## 3. 与 Build 的契约

主路径是 [`scripts/build-image.sh`](../scripts/build-image.sh)：按 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 建 GPT，用 `dd` 灌装。参数指向具体文件，不扫描目录，不调用 `mk-sd-image.sh`。

BSP / Ubuntu 的产物可以落在 git 外的这个目录，文件名按本文：

```text
sd-out/ubuntu-resolute-core-arm64/
  idbloader.img
  uboot.img
  misc.img          # 可选
  dtbo.img          # dtbo-plain 的内容
  resource.img
  kernel.img
  boot.img          # 可选
  rootfs.img        # 或者不放 img，改放 rootfs 目录
```

Build 用参数指向其中的文件：

```bash
scripts/build-image.sh \
  --idbloader sd-out/ubuntu-resolute-core-arm64/idbloader.img \
  --uboot     sd-out/ubuntu-resolute-core-arm64/uboot.img \
  --kernel    sd-out/ubuntu-resolute-core-arm64/kernel.img \
  --resource  sd-out/ubuntu-resolute-core-arm64/resource.img \
  --dtbo      sd-out/ubuntu-resolute-core-arm64/dtbo.img \
  --rootfs    sd-out/ubuntu-resolute-core-arm64/rootfs.img \
  --misc      sd-out/ubuntu-resolute-core-arm64/misc.img \
  --boot      sd-out/ubuntu-resolute-core-arm64/boot.img
```

还可选 `--recovery`。未传 `--misc`、`--boot`、`--recovery` 时仍建对应空分区。

默认输出：`out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`。

`--rootfs` 若是 `.img`：Build 检测 android sparse，先 `simg2img` 再写入。若是目录：Build 打 ext4，卷标 `LABEL=rootfs`。两种输入都不改第 2 节的扇区数字。

产品表是 `scripts/partition-layout.md`。不读 Wiki eMMC `parted`，不以官方包内 OverlayFS `parameter.txt` 为产品表。

`build-image.sh` 当前只校验输入并打印布局（退出码 2）。GPT 写入按下面的顺序实现。

### 写盘顺序

1. 用 `sgdisk` 按第 2 节 plain 表建 GPT。分区名是 `uboot`、`misc`、`dtbo`、`resource`、`kernel`、`boot`、`recovery`、`rootfs`。rootfs 从 LBA `0x46000` 到磁盘末尾减去备份 GPT。8 项、无 `trust`、无 `userdata`、rootfs 为第 8 项且增长。
2. 写 loader（GPT 分区之外）：

```bash
dd if=idbloader.img of=/dev/sdX bs=512 seek=$((0x40)) conv=fsync
```

3. 各分区镜像按裸文件 `dd`，`bs=512 seek=<起点 LBA>`。没有 misc / boot / recovery 文件就留下空分区。
4. rootfs 按上一节的 sparse 或目录规则处理后再写入。直接 `dd` android sparse 会把稀疏头写进文件系统。

### rootfs 从哪来

`--rootfs` 给目录时，由 Build 打 ext4（`LABEL=rootfs`，块大小 4096），`/etc/fstab` 用 `LABEL=rootfs`。分区比镜像大，镜像不必撑满整张卡。

若 Ubuntu 先交来一份 `.img`，且该文件来自上游 `build-rootfs-img.sh`，它只作为 `--rootfs` 的输入，不做整卡写盘。该文件是 android sparse：`mke2fs -E android_sparse -t ext4 -L rootfs -M /root -b 4096`。未传入大小时，字节数约为 `(du -s -B64M <rootfs-dir> 的数值 + 3) * 64MiB`。整卡仍由 `build-image.sh` 写；Build 在这份 `.img` 上先 `simg2img`。该上游脚本还会按 `parameter.template` 重写带 userdata 的 `parameter.txt`；那份表不是产品表。

### 对照 / 退路

上游 `fusing.sh` 定义了 `fusing_bin`（`dd ... bs=512 seek=$2`）但没有调用。真正写卡的是 `tools/sd_update`（aarch64 构建机用 `tools/aarch64/sd_update`）。它从 `-p` 所指 `parameter.txt` 的目录按分区名找 `<名字>.img`。第 2 节的 LBA `0x40` 和 plain 表是对照这个二进制核对过的。

本仓库入口不调用 `fusing.sh`、`sd_update` 或 `mk-sd-image.sh`。只有 `build-image.sh` 的灌装还没落地、需要临时出一张卡时，才在 sd-fuse 工作区单步跑 `sd_update`，并且先换成 `parameter-plain.txt` 与 `dtbo-plain.img`。`build-rootfs-img.sh` 会在打完 ext4 后用 template 盖掉 plain parameter，所以这两份覆盖要放在它之后。

### 验收

SD 冷启动，串口为 Wiki 上的 Debug UART：UART0，3.3V，1500000。进来之后：

- `uname -r` 以 `6.1` 开头，并且和刷进去的 `kernel.img` 是同一次构建。
- `/etc/os-release` 为 Ubuntu 26.04。
- 第 8 项是 rootfs，`findmnt /` 的源是 `mmcblk0p8`（或 LABEL `rootfs`），没有挂 `data=` 那层 OverlayFS。

SSH、千兆和厂商模块仍按 ADR-0001 验收。写完卡可以用 `dd if=/dev/sdX bs=512 skip=64 count=1` 看头四字节是否为 `RKNS`。

## 待板上验证

- `parameter-plain.txt` 文件头里的 `RK356X` / `NanoPi5`，U-Boot 是否原样接受。
- `nanopi_zero2` 的 `idbloader.img` + `uboot.img` 能否在 NEO3 Plus 2GB 上完成 DDR 初始化并进入内核。
- 官方 `20280806` 的 `resource.img` 是否选中 `friendlyelec,nanopi-neo3-plus`（rev02）。内核树在 2026-03-04 加入该 DTS，镜像日期晚于该提交，但仍以启动日志为准。
- 自研 `sgdisk` 的 rootfs 结尾是否与 `sd_update` 的备份 GPT 一致。
- 冷启动后根设备名是否就是 dtbo 里的 `/dev/mmcblk0p8`，并且 `/etc/fstab` 的 `LABEL=rootfs` 指向同一分区。两者要一起看。
