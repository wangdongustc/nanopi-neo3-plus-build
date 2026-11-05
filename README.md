# nanopi-neo3-plus-build

NanoPi NEO3 Plus（RK3528A，2GB LPDDR4）的镜像构建仓库。FriendlyELEC U-Boot 与 kernel 6.1 配上 Ubuntu 26.04 Resolute 用户态，打成可刷写的 SD / eMMC 镜像。

做法已接受，见 [ADR-0001](docs/adr/0001-userland-resolute-debootstrap.md)：在构建主机上 debootstrap Resolute（arm64）rootfs，再用 FriendlyELEC [`sd-fuse_rk3528`](https://github.com/friendlyarm/sd-fuse_rk3528) 分支 `kernel-6.1.y` 打包。官方 Noble 镜像上的 `do-release-upgrade` 只作为一次性试验，不进入发布。

板卡说明：[FriendlyELEC Wiki — NanoPi NEO3 Plus](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_NEO3_Plus)。高层步骤见 [docs/build-outline.md](docs/build-outline.md)。

## 硬约束

- **引导与内核**：FriendlyELEC U-Boot v2017.09 + kernel 6.1.y。`/lib/modules/6.1.*` 与 `kernel.img` 一致，模块从现有 Noble 镜像带入。apt Pin-Priority -1 并 hold：`linux-image-generic`、`linux-generic` 及 headers。不安装 Ubuntu 官方 7.0 内核。
- **用户态**：仅 Ubuntu 26.04 Server/core。不安装 Desktop、snapd、NetworkManager、cloud-init。
- **网络**：netplan → systemd-networkd。网卡名以板上 `ip link` 为准（`eth0` 或 `end0`）。
- **内存**：2GB。打包使用 sd-fuse 的 plain 参数，关闭 OverlayFS，便于 swap 与 Docker。
- **官方镜像**：目前只有 `rk3528-*-ubuntu-noble-core-6.1-arm64-*.img.gz`，没有 Resolute 镜像。sd-fuse 的 OS 目录名写在脚本里；优先新增 `ubuntu-resolute-core-arm64`。暂时复用 `ubuntu-noble-core-arm64` 时，写明目录内容是 Resolute。

## 下一步

脚本尚未进仓库。按 ADR 分工落地：

1. **Ubuntu**：`build-resolute-rootfs.sh`，以及厂商模块 `carry.tgz` 清单。
2. **BSP**：U-Boot / kernel 6.1 / DTS，与 modules 成对。
3. **Build**：sd-fuse 打包、plain 参数、烧录。
4. **Platform**：2GB 下的 swap / Docker、网络与温控。

第一张卡的验收：`uname -r` 仍是 6.1，`/etc/os-release` 是 26.04，SSH 与千兆可用，厂商模块在，没有官方 7.0 内核。
