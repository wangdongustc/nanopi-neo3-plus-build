# SD 镜像布局与输入契约（RK3528 / NanoPi NEO3 Plus）

> 状态：调研草稿，**未在板上验证**。要写进镜像的扇区以 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 为准（对齐上游 `parameter-plain.txt`）。下方阻塞项需 BSP/板上实测确认后再钉死。

## 产品路径

决策见 [ADR-0002](adr/0002-own-image-builder.md)。写盘契约以 [BSP 启动链](bsp-boot-chain.md) 为准。产品 CLI 只有 [`scripts/build-image.sh`](../scripts/build-image.sh)：按 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 自建 GPT，再用 `dd` 灌装。Linux 上成功写出 `.img` 并退出 0。没有第二套入口。板上冷启动尚未验收。

- FriendlyELEC 预编译 blob 只作验证输入（本地 `inputs/`，不入库），用 `build-image.sh` 的参数传入。
- 不调用 `sd_update`、`mk-sd-image.sh`、`fusing.sh`。可以读上游文档做对照。

交叉引用：[ADR-0001](adr/0001-userland-resolute-debootstrap.md)（用户态与内核；本文不改其结论）、[构建提纲](build-outline.md)、[AGENTS.md](../AGENTS.md)、[里程碑](milestones.md)。

## 构建宿主

重活（`build-image.sh` 写出镜像、debootstrap、交叉编译、存放大镜像）在所有者的 **DW-MiBook** 上执行，经本机 Grok Bot，每次需要人工批准。不要使用 **MBA-M1-Fedora**。Cursor 云端虚拟机不做大型编译，也不保留镜像产物。全文见 [AGENTS.md](../AGENTS.md)。

## 启动链（事实摘要）

Rockchip SD/eMMC 典型链（[Rockchip Boot option](http://opensource.rock-chips.com/wiki_Boot_option)）：

1. **BootROM** 在 SD 扇区 **64（0x40）** 找 ID Block，加载 **idbloader**（DDR init + miniloader/SPL）。
2. idbloader 再加载 **U-Boot**（`uboot.img`，GPT `uboot` 分区，起始扇区 **0x4000** = 8 MiB，与 [`partition-layout.md`](../scripts/partition-layout.md) 一致）。
3. U-Boot 按 Rockchip 分区约定加载 **`kernel.img`**（`kernel` 分区）与 **`resource.img`**（`resource` 分区，含 DTB/logo 等），再挂 **rootfs**。

注意：

- `MiniLoaderAll.bin` / `rk3528_*_loader_*.bin` 是 **下载模式** 用的 LDR 格式；写到 SD 扇区 64 的应是 **rksd 格式的 `idbloader.img`**（magic 常为 `RKNS`），不要把 LDR 文件直接 `dd` 到 seek=64。
- FE 官方 Wiki 的 eMMC `parted` 样例含 `trust`、无 `recovery`；`sd-fuse` 的 `parameter.template` 含 `recovery`、无独立 `trust`。**两套上游布局不一致**。本仓要写的是 plain 表（无 `userdata`），数字在 [`partition-layout.md`](../scripts/partition-layout.md)。官方 noble 包或实板上的 `parameter.txt` 仍要 BSP 核对后才能钉死（见下方阻塞项）。

来源：

- Wiki：[NanoPi NEO3 Plus](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_NEO3_Plus)
- sd-fuse：[friendlyarm/sd-fuse_rk3528](https://github.com/friendlyarm/sd-fuse_rk3528) 分支 `kernel-6.1.y`
- 参数模板：[`prebuilt/parameter.template`](https://github.com/friendlyarm/sd-fuse_rk3528/blob/kernel-6.1.y/prebuilt/parameter.template)、[`prebuilt/parameter-plain.txt`](https://github.com/friendlyarm/sd-fuse_rk3528/blob/kernel-6.1.y/prebuilt/parameter-plain.txt)
- DTS：`rk3528-nanopi-rev02.dts`（model = NanoPi NEO3 Plus），kernel 分支 `nanopi6-v6.1.y`

## GPT 分区

扇区表不在本文重复，避免和脚本两套数字。`scripts/build-image.sh` 使用 [`scripts/partition-layout.md`](../scripts/partition-layout.md)：

- idbloader 在 LBA 64（0x40），不在 GPT 分区名里。
- 分区名：`uboot` `misc` `dtbo` `resource` `kernel` `boot` `recovery`，然后 `rootfs` 从 LBA `0x46000`（140 MiB）增长到盘尾。
- plain：没有 `userdata`。不用 `parameter.template`（那是 rootfs + userdata），也不用 `parameter-opt.template` 的 `opt:grow`。

`dtbo` 必须是关闭 OverlayFS 的 plain 文件。`rootfs` 为 ext4，卷标 `rootfs`。

## Boot 资源：FE 实际用什么

| 产物 | 含义 | 谁产出 |
|------|------|--------|
| `idbloader.img` | SD 扇区 64 的 pre-loader | FE `prebuilt/`，或 U-Boot/`rkbin` 打包 |
| `MiniLoaderAll.bin` | 下载模式 loader；`build-uboot.sh` 用 `rk3528_*loader_*.bin` 覆盖进 OS 目录 | U-Boot/`rkbin`；**不是** seek=64 写入物 |
| `uboot.img` | GPT `uboot` 分区内容 | FE 预编译或 `build-uboot.sh` → `tools/update_uboot_bin.sh` |
| `kernel.img` | 打包后的内核镜像（非裸 Image） | `build-kernel.sh` / `make nanopi5-images` |
| `resource.img` | DTB + logo 等（`resource_tool`） | 与 kernel 同一次 `nanopi5-images` |
| `boot.img` | ext4（android sparse）小分区，含 `logo.bmp` 等 | `build-boot-img.sh` 或预编译包 |
| `dtbo.img` / `dtbo-plain.img` | DT overlay 分区 | FE prebuilt；plain 路径复制 plain 版 |
| `misc.img` | misc | FE prebuilt |
| `rootfs.img` | ext4（常 sparse），LABEL=`rootfs` | Ubuntu 交付目录或镜像；`build-image.sh --rootfs` |
| `parameter.txt` | 上游分区文本 | **脚本不读**。扇区以 `partition-layout.md` 为准；此文件只作对照 |

**不是** distro-boot / `extlinux.conf` 为主路径：Wiki 更新内核示例是直接 `dd` 到 `resource`/`kernel` 分区，而不是改 boot 分区里的 Image+dtb。

## rootfs

- 文件系统：**ext4**，卷标 `rootfs`，块大小 4096（ADR-0002，`/etc/fstab` 用 `LABEL=rootfs`）。
- `--rootfs` 优先是目录。裸 ext4 `.img` 同样接受。FE 工具链的 **android sparse**（`-E android_sparse`）只作兜底：脚本先 `simg2img` 再写入。不要求 Ubuntu 交付 sparse。
- `root=` cmdline 字符串尚未钉死（见 Ubuntu 阻塞项）。fstab 的 LABEL 已经定为 `rootfs`。
- 模块：`/lib/modules/6.1.*` 必须与 `kernel.img` 同版本（ADR-0001）。

## 与官方 sd-fuse 的边界

| 能力 | 在本路径中的位置 |
|------|------------------|
| GPT + 按名写各分区 | **产品路径**：`scripts/build-image.sh`（`sgdisk` + `dd`）。几何见 [bsp-boot-chain.md](bsp-boot-chain.md) |
| `idbloader` → LBA 64 | **产品路径**：同一脚本，RKNS，偏移见 `partition-layout.md`（与官方镜像前 8 MiB 的对照尚未做） |
| 拼出可 `dd` 的 `.img` | **只有** `scripts/build-image.sh`。Linux 上写出文件并退出 0。板上冷启动尚未验收 |
| U-Boot / kernel / `kernel.img`+`resource.img` | BSP 产物。FE 预编译只作验证输入，不入库 |
| rootfs | 优先目录，其次裸 ext4。android sparse 只是写盘兜底 |
| 下载 OS 包作对照 | 只为取验证输入。URL：`https://downloads.friendlyelec.com/os-images/rk3528/images/` |
| `sd_update` / `mk-sd-image.sh` / `fusing.sh` | **不调用**。不是入口，也不是对照时的必经步骤 |

上游 `fusing.sh` 现在是：校验设备 → `sd_update -d DEV -p parameter.txt`。本仓不走这条。灌装实现时要显式写入 idbloader，不要假设「只建 GPT 就能进 U-Boot」。

## 输入契约（给 build-image.sh）

见 [`inputs/README.md`](../inputs/README.md)。文件放在仓库外，用参数传入，不提交。当前必选：`--idbloader` `--uboot` `--kernel` `--resource` `--dtbo` `--rootfs`。可选：`--misc` `--boot` `--recovery`。脚本不读 `parameter.txt`。

版本钉扎：每个 blob 旁放 `*.sha256` 与 `SOURCES.txt`（git commit / 下载 URL / 日期），这些也不入库。

## 阻塞项（BSP / Ubuntu）

布局在这些项确认前不能钉死。

### BSP

1. 用官方 `ubuntu-noble-core` 包或实板确认真实 `parameter.txt`。Wiki 的 eMMC `parted` 样例有 `trust`、无 `recovery`；`parameter.template` 有 `recovery`、无独立 `trust`。
2. 确认写入扇区 64 的 `idbloader.img` 是 rksd（magic 常为 `RKNS`），不是 `MiniLoaderAll.bin` 这种 LDR。
3. 确认可以直接用 prebuilt `idbloader.img`，还是必须用 `mkimage -T rksd` 重新打包。

### Ubuntu

1. `--rootfs` 优先交目录，其次裸 ext4（`LABEL=rootfs`，块 4096）。android sparse 只是写盘兜底，不是交付要求。冷启动后的 `root=` 仍见下一条。
2. 第一张可启动镜像的 `root=` cmdline。fstab 的 LABEL 已定为 `rootfs`（ADR-0002），不要改回 sd-fuse 目录标签。
3. `/lib/modules/6.1.*` 必须与 `kernel.img` 同版本（ADR-0001）。

板上 `parted`、`/proc/cmdline`、`/etc/fstab` 原文用来核对上列项。首卡是否保留 32 MiB `recovery` 随真实 `parameter.txt` 一起定。
