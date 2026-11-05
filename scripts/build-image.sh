#!/usr/bin/env bash
# NanoPi NEO3 Plus 的 SD 镜像入口。
# 布局见同目录 partition-layout.md，决策见 docs/adr/0002-own-image-builder.md。
# 不要改成调用 friendlyarm/sd-fuse 的 mk-sd-image.sh、fusing.sh 或 tools/sd_update。
set -euo pipefail

usage() {
  cat <<'EOF'
用法: scripts/build-image.sh [选项]

本仓库的 SD 镜像构建入口。按 scripts/partition-layout.md 组 GPT 镜像。
当前只校验输入并打印计划，不写镜像文件（退出码 2）。

必选:
  --idbloader FILE   Rockchip idbloader，原始写入 LBA 64
  --uboot FILE       uboot.img，分区 uboot
  --kernel FILE      kernel.img（vendor 6.1），分区 kernel
  --resource FILE    resource.img，分区 resource
  --dtbo FILE        plain dtbo.img（关闭 OverlayFS），分区 dtbo
  --rootfs PATH      rootfs 目录，或已经打好的 rootfs.img

可选:
  --misc FILE
  --boot FILE
  --recovery FILE
  --out PATH         默认 out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img
  --size-mb N        镜像大小，十进制 MB，默认 7800，必须 >= 256
  --print-layout     打印扇区表后退出 0
  -h, --help         显示本说明后退出 0

输入可以是 FriendlyELEC 预编译，或本仓库 BSP / Ubuntu 角色的编译产物。
不要把这些二进制提交进 git。
EOF
}

print_layout() {
  cat <<'EOF'
扇区 512 字节。plain GPT（无 userdata，关闭 OverlayFS）。
详见 scripts/partition-layout.md。

idbloader  原始  LBA 64 (0x40)  偏移 32 KiB

分区名      起始 LBA    扇区数     起始      大小
uboot       0x4000      0x2000     8 MiB     4 MiB
misc        0x6000      0x2000     12 MiB    4 MiB
dtbo        0x8000      0x2000     16 MiB    4 MiB
resource    0xA000      0x8000     20 MiB    16 MiB
kernel      0x12000     0x14000    36 MiB    40 MiB
boot        0x26000     0x10000    76 MiB    32 MiB
recovery    0x36000     0x10000    108 MiB   32 MiB
rootfs      0x46000     grow       140 MiB   剩余空间
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

need_arg() {
  if [[ $# -lt 2 || -z ${2:-} || ${2} == --* ]]; then
    die "选项 $1 需要参数"
  fi
}

SIZE_MB=7800
OUT=""
IDBLOADER=""
UBOOT=""
KERNEL=""
RESOURCE=""
DTBO=""
ROOTFS=""
MISC=""
BOOT=""
RECOVERY=""
MODE=build

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      MODE=help
      shift
      ;;
    --print-layout)
      MODE=layout
      shift
      ;;
    --size-mb)
      need_arg "$@"
      SIZE_MB=$2
      shift 2
      ;;
    --out)
      need_arg "$@"
      OUT=$2
      shift 2
      ;;
    --idbloader)
      need_arg "$@"
      IDBLOADER=$2
      shift 2
      ;;
    --uboot)
      need_arg "$@"
      UBOOT=$2
      shift 2
      ;;
    --kernel)
      need_arg "$@"
      KERNEL=$2
      shift 2
      ;;
    --resource)
      need_arg "$@"
      RESOURCE=$2
      shift 2
      ;;
    --dtbo)
      need_arg "$@"
      DTBO=$2
      shift 2
      ;;
    --rootfs)
      need_arg "$@"
      ROOTFS=$2
      shift 2
      ;;
    --misc)
      need_arg "$@"
      MISC=$2
      shift 2
      ;;
    --boot)
      need_arg "$@"
      BOOT=$2
      shift 2
      ;;
    --recovery)
      need_arg "$@"
      RECOVERY=$2
      shift 2
      ;;
    *)
      die "无法识别的参数: $1（用 --help 查看）"
      ;;
  esac
done

case "$MODE" in
  help)
    usage
    exit 0
    ;;
  layout)
    print_layout
    exit 0
    ;;
esac

if [[ ! ${SIZE_MB} =~ ^[0-9]+$ ]] || [[ ${SIZE_MB} -lt 256 ]]; then
  die "--size-mb 必须是 >= 256 的整数（十进制 MB），当前: ${SIZE_MB}"
fi

[[ -n ${IDBLOADER} ]] || die "缺少 --idbloader"
[[ -n ${UBOOT} ]] || die "缺少 --uboot"
[[ -n ${KERNEL} ]] || die "缺少 --kernel"
[[ -n ${RESOURCE} ]] || die "缺少 --resource"
[[ -n ${DTBO} ]] || die "缺少 --dtbo"
[[ -n ${ROOTFS} ]] || die "缺少 --rootfs"

require_file() {
  local label=$1 path=$2
  [[ -f ${path} ]] || die "${label} 不是已存在的文件: ${path}"
}

require_file idbloader "${IDBLOADER}"
require_file uboot "${UBOOT}"
require_file kernel "${KERNEL}"
require_file resource "${RESOURCE}"
require_file dtbo "${DTBO}"
if [[ -n ${MISC} ]]; then
  require_file misc "${MISC}"
fi
if [[ -n ${BOOT} ]]; then
  require_file boot "${BOOT}"
fi
if [[ -n ${RECOVERY} ]]; then
  require_file recovery "${RECOVERY}"
fi
if [[ ! -f ${ROOTFS} && ! -d ${ROOTFS} ]]; then
  die "rootfs 须是已存在的文件或目录: ${ROOTFS}"
fi

if [[ -z ${OUT} ]]; then
  OUT="out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-$(date +%Y%m%d).img"
fi

printf '计划写入: %s\n' "${OUT}"
printf '大小: %s MB（十进制），本次不创建该文件\n' "${SIZE_MB}"
printf 'idbloader: %s\n' "${IDBLOADER}"
printf 'uboot:     %s\n' "${UBOOT}"
printf 'kernel:    %s\n' "${KERNEL}"
printf 'resource:  %s\n' "${RESOURCE}"
printf 'dtbo:      %s\n' "${DTBO}"
printf 'rootfs:    %s\n' "${ROOTFS}"
printf 'misc:      %s\n' "${MISC:-（空分区）}"
printf 'boot:      %s\n' "${BOOT:-（空分区）}"
printf 'recovery:  %s\n' "${RECOVERY:-（空分区）}"
printf '\n'
print_layout
printf 'TODO: GPT 写入、loader/分区灌装、rootfs 打包尚未实现，本次不生成镜像。\n' >&2
printf '实现要求见 scripts/partition-layout.md 与 docs/adr/0002-own-image-builder.md。\n' >&2
exit 2
