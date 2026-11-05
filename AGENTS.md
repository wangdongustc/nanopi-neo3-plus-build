# AGENTS.md

NanoPi NEO3 Plus 构建仓库。Agent 与协作者按下面执行。Tech Lead 已拍板的条目不要重开。

## 角色

| 角色 | 职责 |
| --- | --- |
| NEO3 · Tech Lead | 拍板。架构、约束、ADR 的最终决定。 |
| BSP | U-Boot v2017.09、vendor kernel 6.1、DTS。`kernel.img` 与 `/lib/modules/6.1.*` 成对。 |
| Ubuntu | 主机 debootstrap Ubuntu 26.04 Resolute rootfs、apt hold、netplan → systemd-networkd。 |
| 平台 | 2GB 上的 swap / Docker、网络、温控。对应 ADR 里的 Platform。 |
| 构建 | `scripts/build-image.sh` 产出可写入 SD 的 `out/*.img`。对应 ADR 里的 Build。 |
| Yiming Liu · 资深工程师 · PR Review | PR 工程审查与合入。作者不自审，不自行合并。 |

## 硬约束

- 引导与内核：FriendlyELEC U-Boot v2017.09 + vendor kernel 6.1。不安装 Ubuntu 官方 7.0 内核。
- 用户态：Ubuntu 26.04 Resolute，见已接受的 [ADR-0001](docs/adr/0001-userland-resolute-debootstrap.md)。只做 Server/core。
- 不安装 Desktop、snapd、NetworkManager、cloud-init。
- 内核相关包 apt Pin-Priority -1 并 hold：`linux-image-generic`、`linux-generic` 及 headers。
- 网络：netplan → systemd-networkd。网卡名以板上 `ip link` 为准（`eth0` 或 `end0`）。
- 内存 2GB。关闭 OverlayFS（plain 布局），方便 swap 与 Docker。
- 大二进制不进 git：U-Boot、kernel、rootfs、`.img` 放构建机或 `out/`（已 gitignore）。

## sd-fuse

允许：阅读 [sd-fuse_rk3528](https://github.com/friendlyarm/sd-fuse_rk3528) `kernel-6.1.y` 的文档和 `parameter-plain.txt`，用来对齐分区。二进制输入可以是 FriendlyELEC 预编译，或本仓 BSP 编译产物。

禁止：把官方 `mk-sd-image.sh`、`fusing.sh` 或 `tools/sd_update` 当作构建入口、CI 入口或主路径。读它们的文档可以，不要调用它们来产发布镜像。

本仓库入口：`scripts/build-image.sh`。布局见 `scripts/partition-layout.md`。决策见 [ADR-0002](docs/adr/0002-own-image-builder.md)。

## 构建在哪跑

重构建只在所有者的 DW-MiBook 上跑，通过本机 Grok Bot 的机器命令执行：

- debootstrap（Resolute rootfs）
- 编译 U-Boot / kernel
- 镜像打包（`scripts/build-image.sh` 写出 `out/*.img`）

不在 MBA-M1-Fedora 上跑。不把这些开成大型 Cursor 云端 VM 任务。

云端 agent 只改本仓库的代码和文档。固件、rootfs 和 `.img` 留在 DW-MiBook，不进 git。

## 协作

- 改动走 PR。大实现之前先写 ADR。
- 沟通用中文。写可执行清单，不写空泛计划。
- 不替用户合入未经审查的 PR。审查人是 Yiming Liu · 资深工程师 · PR Review。

## 验收（第一张 SD 卡）

冷启动从本仓库打出的 SD 镜像，同时满足：

- [ ] `uname -r` 仍是 6.1，且与刷入的 `kernel.img` 同一版本
- [ ] `/etc/os-release` 为 Ubuntu 26.04（Resolute）
- [ ] 串口波特率 1500000，能看到启动日志
- [ ] SSH 可登录，千兆网口可用
- [ ] 断电后可从 SD 冷启动
- [ ] `/lib/modules/6.1.*` 在，且没有官方 7.0 内核包
