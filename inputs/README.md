# inputs/ — 写盘输入约定

此目录 **不提交大 blob**（gitignore）。本地或 CI cache 按下列文件名放置。产品 CLI 是 [`scripts/build-image.sh`](../scripts/build-image.sh)（[ADR-0002](../docs/adr/0002-own-image-builder.md)，写盘契约见 [BSP 启动链](../docs/bsp-boot-chain.md)），用参数指向这些文件，不扫描本目录，也不读 `parameter.txt`。

FriendlyELEC 预编译 blob 只作为验证输入，不入库，也不是写盘入口。不要调用 `sd_update` 出图。扇区表见 [`scripts/partition-layout.md`](../scripts/partition-layout.md)。

## 目录布局

```
inputs/
  SOURCES.txt           # 每个文件的来源 URL 或 git describe + 日期（不入库）
  idbloader.img         # --idbloader  必选，rksd，写入 LBA 64
  uboot.img             # --uboot      必选
  kernel.img            # --kernel     必选（vendor 6.1）
  resource.img          # --resource   必选
  dtbo.img              # --dtbo       必选，plain（关闭 OverlayFS）
  rootfs/               # --rootfs     优先。目录，脚本打 ext4 LABEL=rootfs
  rootfs.img            # --rootfs     也可以。裸 ext4；sparse 只作兜底
  misc.img              # --misc       可选（无则空分区）
  boot.img              # --boot       可选
  recovery.img          # --recovery   可选
  rootfs.img.FORMAT     # 可选文本，一行：sparse|raw
  *.sha256              # 强烈建议，不入库
```

示例（Linux 上写出镜像，退出码 0；`--rootfs` 也可以是目录）：

```
scripts/build-image.sh \
  --idbloader inputs/idbloader.img \
  --uboot inputs/uboot.img \
  --kernel inputs/kernel.img \
  --resource inputs/resource.img \
  --dtbo inputs/dtbo.img \
  --rootfs inputs/rootfs
```

## 从谁来

| 文件 | 来源角色 | 典型获取 |
|------|----------|----------|
| `idbloader.img` | BSP；FE prebuilt 仅作验证 | `sd-fuse_rk3528` `prebuilt/idbloader.img`，或 U-Boot+rkbin 打包（**须 rksd**） |
| `uboot.img` | BSP；FE 预编译仅作验证 | 预编译包，或 `build-uboot.sh`（分支 `nanopi5-v2017.09`） |
| `MiniLoaderAll.bin` | BSP（下载模式/对照） | 同 U-Boot 构建；**不要**当作 `--idbloader` |
| `kernel.img` / `resource.img` | BSP；FE tgz 仅作验证 | 分区包或 `build-kernel.sh`（`nanopi6-v6.1.y`） |
| `dtbo.img` / `boot.img` / `misc.img` | BSP 或 FE 包 | plain dtbo，不是 overlay 版 |
| rootfs 目录（优先）或裸 ext4 `rootfs.img` | Ubuntu | debootstrap Resolute（ADR-0001）。块 4096，卷标 `rootfs`。sparse 不是交付要求 |
| 厂商 `/lib/modules/6.1.*` | Ubuntu+BSP | 从 Noble 镜像/板子 `carry.tgz`，版本与 `kernel.img` 一致 |

## 下载入口（FE）

只用于取验证输入，不是产品写盘入口。

- 分区镜像包（示例）：`http://112.124.9.243/dvdfiles/rk3528/images-for-eflasher/ubuntu-noble-core-arm64-images.tgz`（带宽差时改用 [NetDrive](https://download.friendlyelec.com/rk3528)）
- sd-fuse 脚本默认 CDN：`https://downloads.friendlyelec.com/os-images/rk3528/images/`
- Wiki：[NanoPi NEO3 Plus](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_NEO3_Plus) → Official images

解压后把需要的文件 **复制或软链**到本 `inputs/`，不要把整个 sd-fuse 树塞进本仓。

## 版本钉扎

`SOURCES.txt` 示例：

```
idbloader.img  sha256=...  from sd-fuse prebuilt/  or built from rkbin@...
uboot.img      sha256=...  uboot-rockchip nanopi5-v2017.09 @ <sha>
kernel.img     sha256=...  kernel-rockchip nanopi6-v6.1.y @ <sha>  uname=6.1.xx
resource.img   sha256=...  same build as kernel.img
dtbo.img       sha256=...  plain (OverlayFS off)
rootfs.img     sha256=...  ubuntu-resolute debootstrap <date>  or noble-core extract
```

## 宿主要求

- Linux x86_64 或 aarch64（Docker 内的 Linux 即可）
- 正式重活在 **DW-MiBook**，经本地 Grok Bot，每次需人工批准。见 [AGENTS.md](../AGENTS.md)。
- 不要使用 **MBA-M1-Fedora**。Cursor 云端虚拟机不做大型编译，也不保留镜像产物。
- 工具：`sgdisk`（gdisk）、`dd`、`mkfs.ext4` 与 `dumpe2fs`（e2fsprogs）。android sparse 兜底时要 `simg2img`（`android-sdk-libsparse-utils` 或 android-tools）。检查文件镜像用 `losetup`，没有分区节点时再 `partx -av`。写盘本身不挂 loop
- 写盘只支持 Linux（含 Docker）。不要在裸 macOS 上写镜像
