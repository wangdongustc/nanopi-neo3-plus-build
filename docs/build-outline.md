# 构建提纲

对应 [ADR-0001](adr/0001-userland-resolute-debootstrap.md)。这里只列顺序，脚本以后再进仓库。不要把 sd-fuse、U-Boot、kernel 或官方镜像 blob 提交进本仓库。

上游（构建机上另行克隆，固定分支）：

- 打包：<https://github.com/friendlyarm/sd-fuse_rk3528>，分支 `kernel-6.1.y`
- U-Boot：<https://github.com/friendlyarm/uboot-rockchip>，分支 `nanopi5-v2017.09`
- 内核：<https://github.com/friendlyarm/kernel-rockchip>，分支 `nanopi6-v6.1.y`

## 步骤

1. **克隆 sd-fuse。** `git clone -b kernel-6.1.y --single-branch`。需要预编译分区镜像时，从 FriendlyELEC 拉取 `ubuntu-noble-core-arm64-images.tgz`（引导与 `kernel.img` 的来源），不要把压缩包提交进本仓库。
2. **准备 OS 目录。** 优先新增 `ubuntu-resolute-core-arm64`（薄封装或 fork 说明；上游脚本把 OS 名写成目录名）。暂时复用 `ubuntu-noble-core-arm64` 时，在该目录放一份标记，写明 rootfs 内容是 Resolute。
3. **主机构建 Resolute rootfs。** `debootstrap --arch=arm64 resolute`。主机 debootstrap 若没有 `resolute` 脚本，先升级包，或把 `/usr/share/debootstrap/scripts/resolute` 链接到已有 Ubuntu 脚本（通常是 `gutsy`）。软件源用 ubuntu-ports，例如 `ports.ubuntu.com`、阿里云或清华的 ubuntu-ports；不要用 amd64 archive。只装 Server/core，不装 Desktop、snapd、NetworkManager、cloud-init。
4. **带入厂商模块。** 从 Noble 板卡或官方镜像取出 `/lib/modules/6.1.*`，打成 `carry.tgz` 再放进新 rootfs，版本与 `kernel.img` 一致。对 `linux-image-generic`、`linux-generic` 及 headers 设置 Pin-Priority -1 并 hold。
5. **网络与 fstab。** netplan 只渲染 systemd-networkd。网卡名等板子上 `ip link` 确认后再写（`eth0` 或 `end0`）。`/etc/fstab` 的 UUID/LABEL 对齐 sd-fuse 的分区标签。保持厂商 initramfs 路径，不改成 Dracut。
6. **关闭 OverlayFS。** 在 OS 目录执行上游的 plain 参数复制：`parameter-plain.txt` → `parameter.txt`，`dtbo-plain.img` → `dtbo.img`。
7. **打包。** `build-rootfs-img.sh` 把 rootfs 目录做成 `rootfs.img`，再 `mk-sd-image.sh` 生成 SD 镜像。eMMC 烧录镜像用 `mk-emmc-image.sh`，本提纲不展开。
8. **板上验收。** `uname -r` 为 6.1；`/etc/os-release` 为 26.04；SSH 与千兆可用；厂商模块在；没有官方 7.0 内核。

`build-resolute-rootfs.sh` 与 `carry.tgz` 清单由 Ubuntu 角色补；U-Boot / kernel / DTS 由 BSP 补；打包与烧录由 Build 补。
