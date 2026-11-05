# nanopi-neo3-plus-build

NanoPi NEO3 Plus（RK3528A，2GB LPDDR4）的镜像构建仓库。FriendlyELEC U-Boot v2017.09 与 vendor kernel 6.1 配上 Ubuntu 26.04 Resolute 用户态，打成可写入 SD 卡并启动的镜像。

用户态已接受，见 [ADR-0001](docs/adr/0001-userland-resolute-debootstrap.md)：在构建主机上 debootstrap Resolute（arm64）rootfs。官方 Noble 镜像上的 `do-release-upgrade` 只作为一次性试验，不进入发布。

打包以本仓库为准，见 [ADR-0002](docs/adr/0002-own-image-builder.md)。入口是 [`scripts/build-image.sh`](scripts/build-image.sh)，分区见 [`scripts/partition-layout.md`](scripts/partition-layout.md)。FriendlyELEC [`sd-fuse_rk3528`](https://github.com/friendlyarm/sd-fuse_rk3528) 只提供分区和参数参考，不作为构建入口，也不调用它的 `mk-sd-image.sh`。

板卡说明：[FriendlyELEC Wiki — NanoPi NEO3 Plus](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_NEO3_Plus)。步骤见 [docs/build-outline.md](docs/build-outline.md)。协作者约束见 [AGENTS.md](AGENTS.md)。

## 硬约束

- **引导与内核**：FriendlyELEC U-Boot v2017.09 + kernel 6.1.y。`/lib/modules/6.1.*` 与 `kernel.img` 一致，模块从现有 Noble 镜像带入。apt Pin-Priority -1 并 hold：`linux-image-generic`、`linux-generic` 及 headers。不安装 Ubuntu 官方 7.0 内核。
- **用户态**：仅 Ubuntu 26.04 Server/core。不安装 Desktop、snapd、NetworkManager、cloud-init。
- **网络**：netplan → systemd-networkd。网卡名以板上 `ip link` 为准（`eth0` 或 `end0`）。
- **内存**：2GB。分区用 plain 布局（单个增长的 rootfs，关闭 OverlayFS），便于 swap 与 Docker。
- **产物**：`out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`。预编译固件和镜像不进 git。
- **在哪构建**：debootstrap、U-Boot/kernel 编译、镜像打包在所有者的 DW-MiBook 上，经本机 Grok Bot 执行。不在 MBA-M1-Fedora，也不作为大型 Cursor 云端任务。云端 agent 只改仓库代码和文档。详见 [AGENTS.md](AGENTS.md)。

## 通向第一张 SD 卡

1. **Ubuntu**：`build-resolute-rootfs.sh`（尚未入库）做出 Resolute rootfs，并用 `carry.tgz` 带入与 `kernel.img` 成对的 6.1 模块。
2. **BSP**：准备 `idbloader`、`uboot.img`、`kernel.img`、`resource.img`、plain `dtbo.img`。来源是 FriendlyELEC 预编译或本仓编译，文件放在 git 外。
3. **构建**：`scripts/build-image.sh` 按分区表写出 `out/*.img`。脚本现在会校验参数并打印布局，GPT 灌装仍是 TODO（退出码 2，不生成文件）。
4. **验收**：把镜像写入 SD，断电冷启动。`uname -r` 仍是 6.1，`/etc/os-release` 是 26.04，串口 1500000，SSH 与千兆可用。

## 分工

| 角色 | 现在要补的 |
| --- | --- |
| Ubuntu | rootfs 脚本、模块清单、pin/hold、netplan → networkd |
| BSP | U-Boot v2017.09、kernel 6.1、DTS，与模块成对 |
| 构建 | 把 `scripts/build-image.sh` 从校验做成真正写 `out/*.img` |
| 平台 | 2GB 下的 swap / Docker、网卡名与温控 |

PR 由 Yiming Liu · 资深工程师 · PR Review 审查。作者不自审合入。
