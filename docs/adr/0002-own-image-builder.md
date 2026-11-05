# ADR-0002：自研薄镜像打包，sd-fuse 只作分区参考

- 状态：已接受（NEO3 · Tech Lead，2026-11-05）。
- 取代：ADR-0001 里「用 FriendlyELEC `sd-fuse_rk3528` 打包」以及为此服务的 OS 目录名。用户态、U-Boot、kernel 约束不变。
- 相关：[ADR-0001](0001-userland-resolute-debootstrap.md)、[构建提纲](../build-outline.md)、[分区布局](../../scripts/partition-layout.md)

## Context

ADR-0001 把可启动镜像交给上游 `mk-sd-image.sh`。这条路径有三个问题：

1. 构建入口、OS 目录名和产物文件名写在上游脚本里，CI 与发布命名不由本仓库拥有。
2. `kernel-6.1.y` 上真正写盘的是预编译 `tools/sd_update`，不是可审的脚本。`fusing.sh` 里的 `dd` 辅助函数当前没有被调用。
3. 本仓库的目标是 SD 上能冷启动的 `.img`。分区知识要留下，官方仓库不该成为唯一打包器。

FriendlyELEC U-Boot v2017.09 按固定 GPT 分区名找 `uboot`、`kernel`、`resource`、`dtbo`、`rootfs`。plain 参数（单 rootfs 增长、无 OverlayFS）仍然是 2GB 板上要的布局。这部分可以对齐，不必把上游脚本引进来。

## Decision

主路径是本仓库的薄打包器 `scripts/build-image.sh`：

- 按 `scripts/partition-layout.md` 写 GPT，分区起止与上游 `prebuilt/parameter-plain.txt` 的扇区一致，以便现有 U-Boot 能找到各分区。
- 输入：idbloader、uboot、kernel、resource、dtbo（plain，关闭 OverlayFS）、rootfs。可选 misc、boot、recovery。来源是 FE 预编译或本仓编译产物，均不提交。
- 输出：`out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img`，可 `dd` 到 SD 卡。
- 不调用 `mk-sd-image.sh`、`fusing.sh`、`sd_update`，也不为了它们维护 `ubuntu-noble-core-arm64` 这类目录名。
- 允许阅读上游文档和 parameter 文本。数字以本仓库布局文档为准；实现时用 parted/sgdisk 与 `dd`，对照官方镜像的分区表核对，而不是包一层上游脚本。

未选的做法：

- 薄封装 `mk-sd-image.sh`：入口仍在上游，OS 目录名和 `sd_update` 去不掉。
- 整仓 fork sd-fuse：把上游的多 OS 矩阵和闭源写盘工具带进本仓库，超出「打出一张 Resolute SD 镜像」的范围。

## Consequences

构建角色维护 `scripts/` 和 `out/*.img` 命名。第一张卡的完成标准是这条脚本打出的镜像能从 SD 冷启动，而不是一次成功的 sd-fuse 调用。

fstab 的 LABEL 对齐本布局的 `rootfs`，不再对齐 sd-fuse 目录里的标签。OverlayFS 保持关闭。

eMMC（上游 `mk-emmc-image.sh`）不在本决策里。SD 冷启动通过后再开。

当前 `scripts/build-image.sh` 只校验输入并打印布局，退出码 2，不生成镜像文件。GPT 写入、parameter 是否要额外嵌入、以及 idbloader 落在 LBA 64，实现时对照官方 SD 镜像确认。

验收清单以 [AGENTS.md](../../AGENTS.md) 为准：`uname -r` 仍为 6.1，`/etc/os-release` 为 26.04，串口 1500000，SSH 与千兆可用，SD 冷启动。
