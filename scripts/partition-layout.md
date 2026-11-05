# SD 分区布局

`scripts/build-image.sh` 要写出的 GPT。扇区大小 512 字节。数字来自 FriendlyELEC `sd-fuse_rk3528` 分支 `kernel-6.1.y` 的 `prebuilt/parameter-plain.txt`（`CMDLINE` 里的 `mtdparts`），用来兼容其 U-Boot v2017.09。本文件是本仓库的布局说明，不调用上游 `mk-sd-image.sh`。

plain 布局：一个增长的 `rootfs`，没有 `userdata`，对应关闭 OverlayFS。不要改用 `parameter.template`（那是 rootfs + userdata）。

## 原始引导区

主 GPT 占 LBA 0（保护 MBR）、LBA 1（头）和 LBA 2–33（分区项）。备份 GPT 在盘尾。

| 内容 | 起始 LBA | 起始字节 | 说明 |
| --- | --- | --- | --- |
| idbloader | 64（0x40） | 32768 | Rockchip SD BootROM 的固定位置，落在主 GPT 与第一个分区之间。文件来自 `--idbloader`。实现时对照官方镜像前 8 MiB 确认 `sd_update` 是否也写在这里。 |

## GPT 分区

分区名必须与下表一致。U-Boot 按名字找内核和 rootfs。

| 序号意图 | 名字 | 起始 LBA | 扇区数 | 起始 | 大小 |
| --- | --- | --- | --- | --- | --- |
| 1 | uboot | 0x4000 | 0x2000 | 8 MiB | 4 MiB |
| 2 | misc | 0x6000 | 0x2000 | 12 MiB | 4 MiB |
| 3 | dtbo | 0x8000 | 0x2000 | 16 MiB | 4 MiB |
| 4 | resource | 0xA000 | 0x8000 | 20 MiB | 16 MiB |
| 5 | kernel | 0x12000 | 0x14000 | 36 MiB | 40 MiB |
| 6 | boot | 0x26000 | 0x10000 | 76 MiB | 32 MiB |
| 7 | recovery | 0x36000 | 0x10000 | 108 MiB | 32 MiB |
| 8 | rootfs | 0x46000 | 增长到盘尾 | 140 MiB | 剩余空间 |

`rootfs` 格式 ext4，卷标 `rootfs`。rootfs 的 `/etc/fstab` 使用 `LABEL=rootfs`。

## 输入与输出

必选：

| 参数 | 写入位置 |
| --- | --- |
| `--idbloader` | LBA 64 的原始区域 |
| `--uboot` | 分区 `uboot` |
| `--kernel` | 分区 `kernel`（vendor 6.1 的 `kernel.img`） |
| `--resource` | 分区 `resource` |
| `--dtbo` | 分区 `dtbo`。必须是关闭 OverlayFS 的 plain dtbo，不能用默认 overlay 版 |
| `--rootfs` | 分区 `rootfs`。目录则先打成 ext4；已经是 `.img` 则按文件写入 |

可选：`--misc`、`--boot`、`--recovery`。缺省时仍建空分区，不拿别的文件去填。厂商 U-Boot 的主路径使用 `kernel` + `resource` + `dtbo`；`boot` / `recovery` 是否参与启动，灌装实现时对照实机镜像，不在本表里改起始扇区。

输出：`--out`，默认 `out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`（相对当前工作目录）。`--size-mb` 默认 7800，单位是十进制 MB，且必须 ≥ 256。rootfs 从 140 MiB 起，镜像要大于该起点加上 rootfs 内容。

## 先不要写死的字段

上游 plain 文件的机型字符串仍是 `MACHINE_MODEL: RK356X`、`MACHINE: NanoPi5`。同目录模板写的是 `RK3528` / `nanopi-z2`。两份都不是已经核对过的 NanoPi NEO3 Plus 标识。生成 parameter 文本或磁盘标识时，先对照一块官方 NEO3 Plus SD 镜像，再写进脚本。扇区表以上面的数字为准，不随机型字符串改动。

## 实现时要做的核对

- [ ] `sgdisk -p` 与本表的起止 LBA、分区名一致
- [ ] idbloader 的落点与官方镜像前 8 MiB 一致
- [ ] plain dtbo，rootfs 上没有 OverlayFS
- [ ] 不调用 `mk-sd-image.sh`、`fusing.sh`、`sd_update`
- [ ] 产物只出现在 `out/`，不进 git
