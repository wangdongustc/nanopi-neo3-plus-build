# 最短路径里程碑（首个可刷 SD `.img`）

目标：[`scripts/build-image.sh`](../scripts/build-image.sh) 按 [ADR-0002](adr/0002-own-image-builder.md) 和 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 自建 GPT 并 `dd` 出可刷 SD 镜像。FriendlyELEC 预编译只作验证输入。不调用 `sd_update` / `mk-sd-image.sh` / `fusing.sh`。没有第二套打包入口。

宿主：正式重活在 **DW-MiBook**（见 [AGENTS.md](../AGENTS.md)）。不在裸 macOS 写盘，不用 MBA-M1-Fedora。

## M0 — 文档与输入契约（本 PR）

- [x] `docs/image-layout.md`：启动链、与 `partition-layout.md` 的交叉引用、阻塞项
- [x] `inputs/README.md`：blob 放置，以及对应 `build-image.sh` 的参数
- [x] 产品 CLI 沿用 main 上的 `scripts/build-image.sh`（校验并打印布局，退出码 2，不写镜像）。本 PR 不另加 stub
- 验收：Tech Lead / Yiming 审过契约；阻塞项交给 BSP/Ubuntu

## M1 — 空盘进 U-Boot

- 仍是 `scripts/build-image.sh`。板上要看到 idbloader @ LBA 64 和 `uboot` 分区；其余分区按 `partition-layout.md` 建上，内容可空
- 当前脚本在灌装完成前，凑齐必选参数后仍退出码 2，不生成文件
- 验收：串口 1500000 8N1 出现 U-Boot 提示符（Wiki：UART0 debug）
- 对照（可选，不是入口）：同一组验证输入对照官方镜像的分区，确认布局。不调用 `sd_update` 来出图

## M2 — 进 kernel

- 同一脚本再写入验证用的 `kernel.img` + `resource.img`（FE 或 BSP；外加 plain `dtbo`）
- 验收：串口看到 kernel 启动日志；可允许 rootfs 缺失而 panic（证明内核已起）
- 钉扎：记录 kernel 版本字符串与 modules 目录名

## M3 — 最小 rootfs → 可刷 `.img`

- 输入：Ubuntu 角色提供的最小 rootfs 目录或 `rootfs.img`（Resolute 优先；过渡可用 Noble core 验证写盘）
- 动作：`scripts/build-image.sh` 写入 `rootfs` 分区，生成 `out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`
- 验收（对齐 ADR-0001 / AGENTS.md）：`uname -r` 为 6.1；能 SSH；千兆 up；厂商 modules 在（若已 carry）

## M4 — 与官方镜像对照（可选，不是入口）

- 本仓 `build-image.sh` 的产物与官方 SD 镜像对同一类输入核对分区内容，或在板上双盲启动
- 主入口始终是 `scripts/build-image.sh`。不把安装 sd-fuse 或调用 `sd_update` 写成必经步骤

## 非目标（本阶段不做）

- eMMC / eflasher 流程
- 自研 `resource_tool` / `mkkrnlimg`
- 第二套镜像脚本
- 在 README 里展开长教程（保持短定位句）
