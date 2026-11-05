# 构建提纲

用户态见 [ADR-0001](adr/0001-userland-resolute-debootstrap.md)。镜像打包见 [ADR-0002](adr/0002-own-image-builder.md)。打包入口是本仓库 [`scripts/build-image.sh`](../scripts/build-image.sh)，分区见 [`scripts/partition-layout.md`](../scripts/partition-layout.md)。产物来源、idbloader 和 `--idbloader` 等参数契约见 [BSP 启动链](bsp-boot-chain.md)。

FriendlyELEC `sd-fuse_rk3528` 只作分区和参数参考，不克隆来当构建入口，也不调用它的 `mk-sd-image.sh`、`fusing.sh` 或 `sd_update`。U-Boot、kernel、官方镜像 blob 不要提交进本仓库。

固件源（构建机上另行克隆，固定分支；产物留在 git 外）：

- U-Boot：<https://github.com/friendlyarm/uboot-rockchip>，分支 `nanopi5-v2017.09`
- 内核：<https://github.com/friendlyarm/kernel-rockchip>，分支 `nanopi6-v6.1.y`
- 分区参考：<https://github.com/friendlyarm/sd-fuse_rk3528>，分支 `kernel-6.1.y`，读 `prebuilt/parameter-plain.txt`。预编译 idbloader / uboot / kernel 可从 FriendlyELEC 分区包取出，只作 `build-image.sh` 的输入文件。

## 步骤

1. **准备引导与内核输入。** BSP 给出 `idbloader`、`uboot.img`、`kernel.img`、`resource.img`，以及关闭 OverlayFS 的 plain `dtbo.img`。可以是 FE 预编译，或上列分支的本仓编译结果。文件放在仓库外。
2. **主机构建 Resolute rootfs。** `debootstrap --arch=arm64 resolute`。主机 debootstrap 若没有 `resolute` 脚本，先升级包，或把 `/usr/share/debootstrap/scripts/resolute` 链接到已有 Ubuntu 脚本（通常是 `gutsy`）。软件源用 ubuntu-ports，例如 `ports.ubuntu.com`、阿里云或清华的 ubuntu-ports；不要用 amd64 archive。只装 Server/core，不装 Desktop、snapd、NetworkManager、cloud-init。
3. **带入厂商模块。** 从 Noble 板卡或官方镜像取出 `/lib/modules/6.1.*`，打成 `carry.tgz` 再放进新 rootfs，版本与 `kernel.img` 一致。对 `linux-image-generic`、`linux-generic` 及 headers 设置 Pin-Priority -1 并 hold。
4. **网络与 fstab。** netplan 只渲染 systemd-networkd。网卡名等板子上 `ip link` 确认后再写（`eth0` 或 `end0`）。`/etc/fstab` 使用 `LABEL=rootfs`，与 `scripts/partition-layout.md` 里的 ext4 卷标一致。保持厂商 initramfs 路径，不改成 Dracut。
5. **打包。** 在仓库根目录执行 `scripts/build-image.sh`，用 `--idbloader`、`--uboot`、`--kernel`、`--resource`、`--dtbo`、`--rootfs` 指向上述文件（可选 `--misc`、`--boot`、`--recovery`）。目标产物是 `out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`。脚本当前只校验输入并打印布局（退出码 2），GPT 灌装仍是 TODO，不会生成 `.img`。
6. **写入 SD 并冷启动。** 镜像生成后，`dd` 到整张 SD（不是某个分区），断电再上电。eMMC 不在本提纲。
7. **板上验收。** `uname -r` 为 6.1；`/etc/os-release` 为 26.04；串口波特率 1500000；SSH 与千兆可用；厂商模块在；没有官方 7.0 内核；断电后能从这张 SD 冷启动。

`build-resolute-rootfs.sh` 与 `carry.tgz` 清单由 Ubuntu 角色补；U-Boot / kernel / DTS 由 BSP 补；`scripts/build-image.sh` 的灌装由构建角色补。
