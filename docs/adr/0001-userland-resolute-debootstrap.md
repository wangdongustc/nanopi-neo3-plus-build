# ADR-0001：主机 debootstrap Ubuntu 26.04 Resolute，固件保持 FriendlyELEC U-Boot + kernel 6.1

- 状态：已接受（Tech Lead，2026-11-05）。用户态与固件结论仍然有效，不重新打开选型。
- 打包工具：Decision 第一句里的 `sd-fuse_rk3528` 打包，以及下面约束 5，已由 [ADR-0002](0002-own-image-builder.md) 取代。原文留在下面，避免改写当时的拍板记录。
- 相关：[构建提纲](../build-outline.md)、[ADR-0002](0002-own-image-builder.md)

## Context

目标板是 NanoPi NEO3 Plus（RK3528A，2GB LPDDR4，原生千兆）。本仓库把 BSP（U-Boot、kernel、DTS）和 Ubuntu 用户态合成可刷写的 SD / eMMC 镜像。

FriendlyELEC 现有官方镜像只有 Noble，文件名形如 `rk3528-*-ubuntu-noble-core-6.1-arm64-*.img.gz`，没有 Resolute 镜像。打包工具是 [sd-fuse_rk3528](https://github.com/friendlyarm/sd-fuse_rk3528) 的 `kernel-6.1.y` 分支：U-Boot v2017.09（`nanopi5-v2017.09`），kernel 6.1.y（`nanopi6-v6.1.y`）。脚本把 OS 名写成目录名，不能随便改名；Ubuntu 目录目前是 `ubuntu-noble-core-arm64`。

官方镜像默认 OverlayFS。2GB 上要做 swap 和 Docker，使用 sd-fuse 自带的 plain 参数关掉 OverlayFS（`prebuilt/parameter-plain.txt` 与 `prebuilt/dtbo-plain.img`）。

用户态只要 Ubuntu 26.04 Server/core。官方 generic 内核是 7.0，不能装上板：`/lib/modules/6.1.*` 必须与刷入的 `kernel.img` 一致，模块从现有 Noble 板卡镜像带入。

在官方 `ubuntu-noble-core` 上做 `do-release-upgrade` 只能当一次性试验。升级会拉官方内核和额外用户态组件，也绕不开 sd-fuse 的目录名和模块布局，不能当产品路径。

## Decision

产品路径：在构建主机上 **debootstrap Ubuntu 26.04 Resolute（arm64）rootfs**，再用 FriendlyELEC `sd-fuse_rk3528`（分支 `kernel-6.1.y`）打包。引导与内核使用 FE 预编译或自行编译的 U-Boot v2017.09 + kernel 6.1.y。

**自 ADR-0002 起：** 上一句的打包工具改为本仓库 `scripts/build-image.sh`。用户态 debootstrap、U-Boot v2017.09、kernel 6.1 不变。约束 5 停止执行，不再为上游脚本维护 `ubuntu-*-core-arm64` 目录。fstab 对齐自研镜像的分区名 `rootfs`。OverlayFS 仍然关闭，布局取 plain，不调用 `mk-sd-image.sh`。

从官方 `ubuntu-noble-core` 在设备上 `do-release-upgrade` 不进入发布。试验产物不回写本决策。

与该路径一起生效的约束：

1. 用户态仅 Ubuntu 26.04 Server/core。不安装 Desktop、snapd、NetworkManager、cloud-init。
2. 保持厂商内核 6.1。`/lib/modules/6.1.*` 与 `kernel.img` 匹配；模块从 Noble 板卡/镜像带入。apt 对 `linux-image-generic`、`linux-generic` 及对应 headers 设置 Pin-Priority -1，并 `apt-mark hold`。不安装 Ubuntu 官方 7.0 内核。
3. 网络使用 netplan 生成 systemd-networkd。网卡名以板上 `ip link` 为准（`eth0` 或 `end0`）。
4. 2GB 内存：打包时用 plain 参数关闭 OverlayFS，便于 swap 与 Docker。
5. OS 目录名优先通过 sd-fuse 的薄封装或 fork 说明，新增 `ubuntu-resolute-core-arm64`。若暂时复用 `ubuntu-noble-core-arm64`，目录内和发布说明写明内容是 Resolute、目录名仍是 noble。本条自 ADR-0002 起停止执行。
6. 构建时：
   - 主机 debootstrap 可能还不含 `resolute`。升级 debootstrap，或把 suite 脚本符号链接到已有 Ubuntu 脚本（各代号通常链到 `gutsy`）。
   - 软件源用 ubuntu-ports（arm64）。阿里云、清华镜像可用。不用只含 amd64 的 archive。
   - rootfs 的 `/etc/fstab` UUID/LABEL 与 sd-fuse 写入的分区标签一致。自 ADR-0002 起改为 `LABEL=rootfs`，对齐 `scripts/partition-layout.md`。
   - 沿用厂商镜像的 initramfs 路径，不把 initramfs 换成 Dracut。

## Consequences

发布镜像的用户态是 Resolute 26.04，引导与内核仍是 FriendlyELEC U-Boot 2017.09 + 6.1.y。内核安全更新走 BSP，不走 `apt upgrade` 的 generic 内核。

没有 Desktop、snapd、NetworkManager、cloud-init。联网只靠 netplan + systemd-networkd。

关闭 OverlayFS 后，rootfs 改动直接落盘，swap 和 Docker 数据盘按普通分区来做。

sd-fuse 目录名在过渡期可能仍叫 noble。复用时，镜像说明、目录标记和 `/etc/os-release` 一起标明 Resolute。该过渡办法随 ADR-0002 结束：产物文件名直接写 resolute，不再复用 noble 目录名。

第一张可启动卡同时满足：

- `uname -r` 仍是 6.1，且与刷入的 `kernel.img` 同一版本。
- `/etc/os-release` 为 Ubuntu 26.04（Resolute）。
- SSH 可登录，千兆网口可用。
- `/lib/modules/6.1.*` 存在，厂商模块在，模块树与 `kernel.img` 匹配。
- 未安装官方 7.0 内核（没有指向 7.0 的 `linux-image-*` / `linux-image-generic`）。

## Follow-ups

| 角色 | 负责 |
| --- | --- |
| Ubuntu | `build-resolute-rootfs.sh`（debootstrap、ports 源、pin/hold、Server/core 包集、netplan → networkd），以及从 Noble 镜像提取厂商模块的 `carry.tgz` 清单。 |
| BSP | U-Boot v2017.09、kernel 6.1.y、DTS；`kernel.img` 与 `/lib/modules/6.1.*` 成对发布。 |
| Build | 自研打包（ADR-0002）：`scripts/build-image.sh` 按 plain GPT 写出 `out/*.img`。不调用 `mk-sd-image.sh`。fstab 使用 `LABEL=rootfs`。 |
| Platform | 2GB 下的 swap / Docker、网络（网卡名、千兆）和温控。 |
