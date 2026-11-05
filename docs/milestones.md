# 最短路径里程碑（首个可刷 SD `.img`）

目标：[`scripts/build-image.sh`](../scripts/build-image.sh) 按 [ADR-0002](adr/0002-own-image-builder.md)、[BSP 启动链](bsp-boot-chain.md) 和 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 自建 GPT 并 `dd` 出可刷 SD 镜像。FriendlyELEC 预编译只作验证输入。不调用 `sd_update` / `mk-sd-image.sh` / `fusing.sh`。没有第二套打包入口。

宿主：正式重活在 **DW-MiBook**（见 [AGENTS.md](../AGENTS.md)）。不在裸 macOS 写盘，不用 MBA-M1-Fedora。

## M0 — 文档与输入契约（本 PR）

- [x] `docs/image-layout.md`：启动链、与 `partition-layout.md` 的交叉引用、阻塞项
- [x] `inputs/README.md`：blob 放置，以及对应 `build-image.sh` 的参数
- [x] 产品 CLI 沿用 main 上的 `scripts/build-image.sh`（校验并打印布局，退出码 2，不写镜像）。本 PR 不另加 stub
- 验收：Tech Lead / Yiming 审过契约；阻塞项交给 BSP/Ubuntu

## M1 — 写盘进镜像（U-Boot 提示符仍待板上验收）

写盘契约：[BSP 启动链](bsp-boot-chain.md) 第 2–3 节、[`scripts/partition-layout.md`](../scripts/partition-layout.md)、[ADR-0002](adr/0002-own-image-builder.md)。入口仍只有 `scripts/build-image.sh`。

- [x] Linux 上写出文件 `.img`（默认 `out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`），成功退出码 0。`--print-layout` / `--help` 仍退出 0。缺必选参数退出 1。`--dry-run` 只打印计划
- [x] idbloader 原始写入 LBA `0x40`，头 4 字节必须是 `RKNS`。拒绝 `MiniLoaderAll.bin` 与 `idblock.bin`。不把 `parameter.txt` 写到 LBA `0x2000`
- [x] `sgdisk` 建 8 个分区：`uboot` `misc` `dtbo` `resource` `kernel` `boot` `recovery` `rootfs`。rootfs 为第 8 项，从 LBA `0x46000` 增长到备份 GPT 之前。无 `trust`、无 `userdata`。省略 `--misc` / `--boot` / `--recovery` 时分区留空
- [x] `--rootfs` 优先目录：`mkfs.ext4 -b 4096 -L rootfs`（`/etc/fstab` 使用 `LABEL=rootfs`，脚本不改 fstab）。裸 ext4 `.img` 同样接受。android sparse 只作兜底（`simg2img` 后再 `dd`），不要求 Ubuntu 交付 sparse
- [x] 不调用 `sd_update` / `fusing.sh` / `mk-sd-image.sh`，不扫描目录
- [ ] 板上验收未做：串口 1500000 8N1 出现 U-Boot 提示符（Wiki：UART0 debug）。`losetup` 能看文件镜像的 GPT，不能代替冷启动
- 对照（可选，不是入口）：同一组验证输入对照官方镜像。不调用 `sd_update` 出图

宿主：`sgdisk`（gdisk）、`dd`、`mkfs.ext4` / `dumpe2fs`（e2fsprogs）、`simg2img`（仅 sparse 兜底；`android-sdk-libsparse-utils` 或 android-tools）、`losetup`（检查文件镜像）。裸 macOS / Darwin 拒绝写盘。正式大镜像仍在 DW-MiBook。

## M2 — 进 kernel

- 同一脚本已把必选的 `--kernel`、`--resource`、`--dtbo` 写入对应分区。串口上的 kernel 日志还没有
- 验收未做：串口看到 kernel 启动日志。CLI 仍要求 `--rootfs`，没有单独的「缺 rootfs 让它 panic」模式
- 钉扎未做：记录 kernel 版本字符串与 modules 目录名

## M3 — 最小 rootfs → 可刷 `.img`

- 输入优先是 Ubuntu 的 rootfs 目录；裸 ext4 `.img` 也可以（Resolute 优先）。android sparse 不是交付要求
- 脚本已能写入 `rootfs` 并生成 `out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`
- 验收未做（对齐 ADR-0001 / AGENTS.md）：`uname -r` 为 6.1；能 SSH；千兆 up；厂商 modules 在（若已 carry）

## M4 — 与官方镜像对照（可选，不是入口）

- 本仓 `build-image.sh` 的产物与官方 SD 镜像对同一类输入核对分区内容，或在板上双盲启动
- 主入口始终是 `scripts/build-image.sh`。不把安装 sd-fuse 或调用 `sd_update` 写成必经步骤

## 非目标（本阶段不做）

- eMMC / eflasher 流程
- 自研 `resource_tool` / `mkkrnlimg`
- 第二套镜像脚本
- 在 README 里展开长教程（保持短定位句）
