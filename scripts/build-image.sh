#!/usr/bin/env bash
# NanoPi NEO3 Plus 的 SD 镜像入口。唯一写盘脚本，没有第二套入口。
# 布局: scripts/partition-layout.md
# 决策: docs/adr/0002-own-image-builder.md
# 写盘契约: docs/bsp-boot-chain.md 第 2–3 节
# 不要调用 friendlyarm/sd-fuse 的 mk-sd-image.sh、fusing.sh 或 tools/sd_update。
# 不要把 parameter.txt 写到 LBA 0x2000，也不要写入 MiniLoaderAll.bin、idblock.bin、trust、userdata。
set -euo pipefail

# sgdisk、mkfs.ext4 在 /usr/sbin，非登录 shell 的 PATH 里经常没有。
export PATH="/usr/sbin:/sbin:${PATH}"

usage() {
  cat <<'EOF'
用法: scripts/build-image.sh [选项]

本仓库的 SD 镜像构建入口。按 scripts/partition-layout.md 与
docs/bsp-boot-chain.md 第 2–3 节写 GPT，再用 dd 灌装。决策见
docs/adr/0002-own-image-builder.md。不扫描目录，不调用 sd_update、
fusing.sh、mk-sd-image.sh。

写盘只支持 Linux（含 Docker）。裸 macOS / Darwin 会拒绝写盘。
成功时创建 --out 并退出 0。缺必选参数退出 1。

必选:
  --idbloader FILE   RKNS 的 idbloader.img，原始写入 LBA 64 (0x40)
                     不要传 MiniLoaderAll.bin 或 idblock.bin
  --uboot FILE       uboot.img，分区 uboot
  --kernel FILE      kernel.img（vendor 6.1），分区 kernel
  --resource FILE    resource.img，分区 resource
  --dtbo FILE        plain dtbo.img（关闭 OverlayFS），分区 dtbo
  --rootfs PATH      优先是目录：mkfs.ext4 -b 4096 -L rootfs 后写入。
                     也接受裸 ext4 .img（卷标 rootfs，块大小 4096）。
                     android sparse 只作兜底：先 simg2img 再写入。
                     不要求 Ubuntu 交付 sparse。fstab 使用 LABEL=rootfs。

可选:
  --misc FILE        省略则 misc 分区留空
  --boot FILE        省略则 boot 分区留空
  --recovery FILE    省略则 recovery 分区留空
  --out PATH         默认 out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-YYYYMMDD.img
  --size-mb N        镜像大小，十进制 MB，默认 7800，必须 >= 256 且为 8 的倍数
  --dry-run          打印计划，不创建镜像文件，退出 0
  --print-layout     打印扇区表后退出 0
  -h, --help         显示本说明后退出 0

宿主工具: sgdisk (gdisk)、dd、truncate、od、mkfs.ext4 与 dumpe2fs (e2fsprogs)。
遇到 android sparse 时还要 simg2img（android-sdk-libsparse-utils 或 android-tools）。
检查镜像：losetup -f --show 文件，若没有分区节点再 partx -av。脚本写的是普通文件，不挂 loop，也不写 /dev/sdX。

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

need_cmd() {
  local cmd=$1 hint=$2
  command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令 ${cmd}（${hint}）"
}

file_size() {
  local path=$1 bytes
  if bytes=$(stat -c %s "${path}" 2>/dev/null); then
    printf '%s\n' "${bytes}"
    return
  fi
  stat -f %z "${path}"
}

od_hex() {
  local path=$1 offset=$2 length=$3
  od -An -tx1 -N "${length}" -j "${offset}" "${path}" | tr -d ' \n'
}

is_android_sparse() {
  local path=$1 size magic
  size=$(file_size "${path}")
  if (( size < 28 )); then
    return 1
  fi
  magic=$(od_hex "${path}" 0 4)
  [[ ${magic} == 3aff26ed ]]
}

# ext 超级块从偏移 1024 开始，magic 在超级块内 0x38。
EXT_SUPER_OFFSET=1024
EXT_MAGIC_OFFSET=$((1024 + 0x38))

is_ext_superblock() {
  local path=$1 size magic
  size=$(file_size "${path}")
  if (( size < EXT_MAGIC_OFFSET + 2 )); then
    return 1
  fi
  magic=$(od_hex "${path}" "${EXT_MAGIC_OFFSET}" 2)
  [[ ${magic} == 53ef ]]
}

require_rootfs_ext() {
  local path=$1 vol bs
  if ! is_ext_superblock "${path}"; then
    die "rootfs 展开后不是 ext 超级块: ${path}"
  fi
  vol=$(dumpe2fs -h "${path}" 2>/dev/null | sed -n 's/^Filesystem volume name:[[:space:]]*//p')
  bs=$(dumpe2fs -h "${path}" 2>/dev/null | sed -n 's/^Block size:[[:space:]]*//p')
  vol=${vol%%$'\n'*}
  bs=${bs%%$'\n'*}
  if [[ ${vol} != rootfs ]]; then
    die "rootfs 卷标必须是 rootfs，当前: ${vol:-（空）}。/etc/fstab 使用 LABEL=rootfs。"
  fi
  if [[ ${bs} != 4096 ]]; then
    die "rootfs 块大小必须是 4096，当前: ${bs:-（未知）}"
  fi
}

# docs/bsp-boot-chain.md 第 2 节。结束 LBA 含终点：end = start + sectors - 1。
# idbloader 不在 GPT 里。rootfs 的结束扇区要等知道盘大小后再算。
IDB_LBA=$((0x40))
IDB_MAX_SECTORS=$((0x1400))
UBOOT_LBA=$((0x4000))
UBOOT_SECTORS=$((0x2000))
MISC_LBA=$((0x6000))
MISC_SECTORS=$((0x2000))
DTBO_LBA=$((0x8000))
DTBO_SECTORS=$((0x2000))
RESOURCE_LBA=$((0xA000))
RESOURCE_SECTORS=$((0x8000))
KERNEL_LBA=$((0x12000))
KERNEL_SECTORS=$((0x14000))
BOOT_LBA=$((0x26000))
BOOT_SECTORS=$((0x10000))
RECOVERY_LBA=$((0x36000))
RECOVERY_SECTORS=$((0x10000))
ROOTFS_LBA=$((0x46000))
# 备份 GPT：32 个分区项扇区 + 1 个备份头。最后可用扇区 = 扇区总数 - 34。
GPT_BACKUP_RESERVE=33

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
DRY_RUN=0
PARTIAL=""
WORKDIR=""

cleanup() {
  if [[ -n ${WORKDIR} && -d ${WORKDIR} ]]; then
    rm -rf -- "${WORKDIR}"
  fi
  if [[ -n ${PARTIAL} && -f ${PARTIAL} ]]; then
    rm -f -- "${PARTIAL}"
  fi
}
trap cleanup EXIT

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
    --dry-run)
      DRY_RUN=1
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

if [[ ! ${SIZE_MB} =~ ^[0-9]+$ ]]; then
  die "--size-mb 必须是 >= 256 的整数（十进制 MB），当前: ${SIZE_MB}"
fi
SIZE_MB=$((10#${SIZE_MB}))
if (( SIZE_MB < 256 )); then
  die "--size-mb 必须是 >= 256 的整数（十进制 MB），当前: ${SIZE_MB}"
fi
if (( SIZE_MB % 8 != 0 )); then
  die "--size-mb 必须是 8 的倍数，十进制字节数才按 512 字节对齐。当前: ${SIZE_MB}"
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

loader_base=$(basename -- "${IDBLOADER}")
loader_base_lc=${loader_base,,}
case "${loader_base_lc}" in
  miniloaderall.bin|idblock.bin)
    die "不要把 ${loader_base} 当作 --idbloader。SD 扇区 64 要 RKNS 的 idbloader.img，不是 MiniLoaderAll.bin 或 idblock.bin（docs/bsp-boot-chain.md）。"
    ;;
esac

idb_magic=$(od_hex "${IDBLOADER}" 0 4)
if [[ ${idb_magic} != 524b4e53 ]]; then
  die "idbloader 头 4 字节须为 RKNS（52 4b 4e 53），当前 ${idb_magic:-（空）}。不要传入 MiniLoaderAll.bin 或 idblock.bin。"
fi
idb_bytes=$(file_size "${IDBLOADER}")
if (( idb_bytes == 0 )); then
  die "idbloader 是空文件"
fi
idb_sectors=$(( (idb_bytes + 511) / 512 ))
if (( idb_sectors > IDB_MAX_SECTORS )); then
  die "idbloader 为 ${idb_sectors} 扇区，超过 docs/bsp-boot-chain.md 的上限 0x1400。它必须落在 LBA 0x40 与 uboot（0x4000）之间。"
fi

IMAGE_BYTES=$((SIZE_MB * 1000000))
TOTAL_SECTORS=$((IMAGE_BYTES / 512))
LAST_USABLE=$((TOTAL_SECTORS - 1 - GPT_BACKUP_RESERVE))
if (( LAST_USABLE < ROOTFS_LBA )); then
  die "镜像太小：rootfs 起点 LBA 0x46000 超过最后可用扇区 ${LAST_USABLE}。请增大 --size-mb。"
fi
ROOTFS_SECTORS=$((LAST_USABLE - ROOTFS_LBA + 1))
ROOTFS_END=${LAST_USABLE}

if [[ -z ${OUT} ]]; then
  OUT="out/rk3528-sd-ubuntu-resolute-core-6.1-arm64-$(date +%Y%m%d).img"
fi

ROOTFS_KIND=""
if [[ -d ${ROOTFS} ]]; then
  ROOTFS_KIND=dir
elif is_android_sparse "${ROOTFS}"; then
  ROOTFS_KIND=sparse
elif is_ext_superblock "${ROOTFS}"; then
  ROOTFS_KIND=raw
else
  die "rootfs 文件既不是 ext4，也不是 android sparse: ${ROOTFS}。优先传入目录；裸 ext4 也可以。sparse 只是兜底。"
fi
if [[ ${ROOTFS_KIND} == raw ]]; then
  need_cmd dumpe2fs "包 e2fsprogs。用来确认卷标 rootfs 与块大小 4096"
  require_rootfs_ext "${ROOTFS}"
fi

rootfs_desc() {
  case "${ROOTFS_KIND}" in
    dir)
      printf '目录 %s → mkfs.ext4 -b 4096 -L rootfs，再 dd 到 LBA 0x46000\n' "${ROOTFS}"
      ;;
    raw)
      printf '裸 ext4 %s → dd 到 LBA 0x46000（不要求 sparse，不在此 resize）\n' "${ROOTFS}"
      ;;
    sparse)
      printf 'android sparse %s → simg2img 后 dd 到 LBA 0x46000（兜底，不是交付要求）\n' "${ROOTFS}"
      ;;
  esac
}

part_desc() {
  local label=$1 path=$2
  if [[ -z ${path} ]]; then
    printf '%s: （空分区，不写入）\n' "${label}"
  elif is_android_sparse "${path}"; then
    printf '%s: %s → simg2img 后 dd\n' "${label}" "${path}"
  else
    printf '%s: %s → dd\n' "${label}" "${path}"
  fi
}

printf '计划写入: %s\n' "${OUT}"
printf '大小: %s MB（十进制）= %s 字节，%s 扇区；rootfs LBA 0x46000–%s\n' \
  "${SIZE_MB}" "${IMAGE_BYTES}" "${TOTAL_SECTORS}" "${ROOTFS_END}"
printf 'idbloader: %s → 原始 LBA 0x40（RKNS，%s 字节）\n' "${IDBLOADER}" "${idb_bytes}"
part_desc uboot "${UBOOT}"
part_desc kernel "${KERNEL}"
part_desc resource "${RESOURCE}"
part_desc dtbo "${DTBO}"
printf 'rootfs: '
rootfs_desc
part_desc misc "${MISC}"
part_desc boot "${BOOT}"
part_desc recovery "${RECOVERY}"
printf '\n'
print_layout

if (( DRY_RUN == 1 )); then
  printf 'dry-run: 不创建 %s\n' "${OUT}"
  exit 0
fi

if [[ $(uname -s) != Linux ]]; then
  die "写盘只支持 Linux（含 Docker）。当前是 $(uname -s)。裸 macOS 不能写这张镜像。"
fi

# GNU readlink -f 要求除最后一段外路径都存在。默认 OUT 在 out/ 下，这个目录经常还没有。
mkdir -p -- "$(dirname -- "${OUT}")"
out_real=$(readlink -f "${OUT}")
if [[ -d ${ROOTFS} ]]; then
  root_real=$(readlink -f "${ROOTFS}")
  case "${out_real}" in
    "${root_real}"|"${root_real}"/*)
      die "--out 不能放在 --rootfs 目录里面: ${OUT}"
      ;;
  esac
  if [[ -f ${ROOTFS}/etc/fstab ]] && ! grep -q 'LABEL=rootfs' "${ROOTFS}/etc/fstab"; then
    printf 'warning: %s 没有 LABEL=rootfs。卷标会写成 rootfs；/etc/fstab 需与 ADR-0002 一致。\n' \
      "${ROOTFS}/etc/fstab" >&2
  fi
fi
for input_path in "${IDBLOADER}" "${UBOOT}" "${KERNEL}" "${RESOURCE}" "${DTBO}" "${ROOTFS}" ${MISC:+"${MISC}"} ${BOOT:+"${BOOT}"} ${RECOVERY:+"${RECOVERY}"}; do
  if [[ -f ${input_path} && $(readlink -f "${input_path}") == "${out_real}" ]]; then
    die "--out 与输入是同一个文件: ${input_path}"
  fi
done

need_cmd sgdisk "包 gdisk。直接写镜像文件，不需要 /dev/sdX"
need_cmd dd "coreutils"
need_cmd truncate "coreutils"
need_cmd od "coreutils"
if [[ ${ROOTFS_KIND} == dir ]]; then
  need_cmd mkfs.ext4 "包 e2fsprogs"
fi
if [[ ${ROOTFS_KIND} != dir ]]; then
  need_cmd dumpe2fs "包 e2fsprogs。用来确认卷标 rootfs 与块大小 4096"
fi

WORKDIR=$(mktemp -d)
mkdir -p -- "$(dirname -- "${OUT}")"
PARTIAL=$(mktemp "$(dirname -- "${OUT}")/.build-image.XXXXXX")
truncate -s "${IMAGE_BYTES}" "${PARTIAL}"

# 分区类型用 sgdisk 默认 8300。U-Boot 按分区名查找，不按类型码。
# 终点用十进制。0x 前缀在部分 sgdisk 上会被当成 0。
if ! sgdisk -o \
  -n "1:${UBOOT_LBA}:$((UBOOT_LBA + UBOOT_SECTORS - 1))" -c 1:uboot \
  -n "2:${MISC_LBA}:$((MISC_LBA + MISC_SECTORS - 1))" -c 2:misc \
  -n "3:${DTBO_LBA}:$((DTBO_LBA + DTBO_SECTORS - 1))" -c 3:dtbo \
  -n "4:${RESOURCE_LBA}:$((RESOURCE_LBA + RESOURCE_SECTORS - 1))" -c 4:resource \
  -n "5:${KERNEL_LBA}:$((KERNEL_LBA + KERNEL_SECTORS - 1))" -c 5:kernel \
  -n "6:${BOOT_LBA}:$((BOOT_LBA + BOOT_SECTORS - 1))" -c 6:boot \
  -n "7:${RECOVERY_LBA}:$((RECOVERY_LBA + RECOVERY_SECTORS - 1))" -c 7:recovery \
  -n "8:${ROOTFS_LBA}:0" -c 8:rootfs \
  "${PARTIAL}" >"${WORKDIR}/sgdisk.out" 2>"${WORKDIR}/sgdisk.err"; then
  cat "${WORKDIR}/sgdisk.err" >&2
  die "sgdisk 创建 GPT 失败"
fi

sgdisk_info() {
  local num=$1
  sgdisk -i "${num}" "${PARTIAL}" 2>/dev/null
}

expect_part() {
  local num=$1 name=$2 start=$3 end=$4 info first last got
  if ! info=$(sgdisk_info "${num}"); then
    die "sgdisk 读不到分区 ${num} (${name})"
  fi
  first=$(sed -n 's/^First sector:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"${info}")
  last=$(sed -n 's/^Last sector:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"${info}")
  got=$(sed -n "s/^Partition name: '\\(.*\\)'/\\1/p" <<<"${info}")
  if [[ ${first} != "${start}" || ${last} != "${end}" || ${got} != "${name}" ]]; then
    printf 'sgdisk -i %s:\n%s\n' "${num}" "${info}" >&2
    die "分区 ${num} 与 docs/bsp-boot-chain.md 不一致：期望 ${name} ${start}-${end}，实际 ${got:-?} ${first:-?}-${last:-?}"
  fi
}

expect_part 1 uboot "${UBOOT_LBA}" "$((UBOOT_LBA + UBOOT_SECTORS - 1))"
expect_part 2 misc "${MISC_LBA}" "$((MISC_LBA + MISC_SECTORS - 1))"
expect_part 3 dtbo "${DTBO_LBA}" "$((DTBO_LBA + DTBO_SECTORS - 1))"
expect_part 4 resource "${RESOURCE_LBA}" "$((RESOURCE_LBA + RESOURCE_SECTORS - 1))"
expect_part 5 kernel "${KERNEL_LBA}" "$((KERNEL_LBA + KERNEL_SECTORS - 1))"
expect_part 6 boot "${BOOT_LBA}" "$((BOOT_LBA + BOOT_SECTORS - 1))"
expect_part 7 recovery "${RECOVERY_LBA}" "$((RECOVERY_LBA + RECOVERY_SECTORS - 1))"
expect_part 8 rootfs "${ROOTFS_LBA}" "${ROOTFS_END}"

# sgdisk -i 对不存在的分区仍退出 0，并打印 “does not exist”。用有没有起点判断。
part9=$(sgdisk -i 9 "${PARTIAL}" 2>/dev/null || true)
if grep -q '^First sector:' <<<"${part9}"; then
  die "出现第 9 个分区。plain 布局只有 8 项，不能有 trust 或 userdata。"
fi

gpt_print=$(sgdisk -p "${PARTIAL}" 2>/dev/null || true)
last_usable_seen=$(sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p' <<<"${gpt_print}")
last_usable_seen=${last_usable_seen%%$'\n'*}
if [[ ${last_usable_seen} != "${LAST_USABLE}" ]]; then
  printf '%s\n' "${gpt_print}" >&2
  die "备份 GPT 预留与预期不符：last usable ${last_usable_seen:-（无）}，期望 ${LAST_USABLE}（盘尾减 ${GPT_BACKUP_RESERVE} 扇区）"
fi

verify_log=$(sgdisk -v "${PARTIAL}" 2>&1 || true)
if ! grep -q 'No problems found' <<<"${verify_log}"; then
  printf '%s\n' "${verify_log}" >&2
  die "sgdisk -v 未通过"
fi

# 与 bsp-boot-chain 的 `dd bs=512 seek=<LBA>` 同一字节偏移。
# 分区起点按 1 MiB 对齐，用较大的块减少系统调用；conv=sparse 让空洞留在文件镜像里。
dd_at_lba() {
  local src=$1 lba=$2
  if (( lba % 2048 == 0 )); then
    dd if="${src}" of="${PARTIAL}" bs=1048576 seek="$((lba / 2048))" conv=notrunc,sparse,fsync status=none
  else
    dd if="${src}" of="${PARTIAL}" bs=512 seek="${lba}" conv=notrunc,sparse,fsync status=none
  fi
}

assert_prefix() {
  local src=$1 lba=$2 label=$3 nbytes size got exp
  size=$(file_size "${src}")
  nbytes=16
  if (( size < nbytes )); then
    nbytes=${size}
  fi
  if (( nbytes == 0 )); then
    die "${label} 是空文件"
  fi
  got=$(od_hex "${PARTIAL}" $((lba * 512)) "${nbytes}")
  exp=$(od_hex "${src}" 0 "${nbytes}")
  if [[ ${got} != "${exp}" ]]; then
    die "${label} 写入 LBA ${lba} 后回读不一致"
  fi
}

assert_zero_at() {
  local lba=$1 label=$2 got
  got=$(od_hex "${PARTIAL}" $((lba * 512)) 4)
  if [[ ${got} != 00000000 ]]; then
    die "${label} 应为空分区，LBA ${lba} 开头不是 0（${got}）"
  fi
}

payload_fits() {
  local label=$1 path=$2 sectors=$3 bytes need max_bytes
  bytes=$(file_size "${path}")
  if (( bytes == 0 )); then
    die "${label} 是空文件: ${path}"
  fi
  need=$(( (bytes + 511) / 512 ))
  max_bytes=$((sectors * 512))
  if (( need > sectors )); then
    die "${label} 有 ${bytes} 字节，分区只有 ${max_bytes} 字节（${sectors} 扇区）"
  fi
}

# 分区镜像若是 android sparse，先展开再 dd。idbloader 不走这里。
materialize() {
  local label=$1 src=$2 sectors=$3 dest
  dest=${src}
  if is_android_sparse "${src}"; then
    need_cmd simg2img "包 android-sdk-libsparse-utils 或 android-tools。只在输入是 android sparse 时调用"
    dest=${WORKDIR}/${label}.raw
    if ! simg2img "${src}" "${dest}" >"${WORKDIR}/simg2img.out" 2>"${WORKDIR}/simg2img.err"; then
      cat "${WORKDIR}/simg2img.err" >&2
      die "${label} 是 android sparse，但 simg2img 失败: ${src}"
    fi
  fi
  payload_fits "${label}" "${dest}" "${sectors}"
  printf '%s\n' "${dest}"
}

printf '写入 idbloader @ LBA 0x40\n'
dd_at_lba "${IDBLOADER}" "${IDB_LBA}"
assert_prefix "${IDBLOADER}" "${IDB_LBA}" idbloader
gpt_sig=$(od_hex "${PARTIAL}" 512 8)
if [[ ${gpt_sig} != 4546492050415254 ]]; then
  die "主 GPT 头不是 EFI PART（${gpt_sig}）。idbloader 不应盖住 LBA 1。"
fi

write_part() {
  local label=$1 lba=$2 sectors=$3 src=${4-} raw=""
  if [[ -z ${src} ]]; then
    assert_zero_at "${lba}" "${label}"
    printf '%s 分区留空 @ LBA 0x%x\n' "${label}" "${lba}"
    return
  fi
  raw=$(materialize "${label}" "${src}" "${sectors}")
  printf '写入 %s @ LBA 0x%x\n' "${label}" "${lba}"
  dd_at_lba "${raw}" "${lba}"
  assert_prefix "${raw}" "${lba}" "${label}"
}

write_part uboot "${UBOOT_LBA}" "${UBOOT_SECTORS}" "${UBOOT}"
write_part misc "${MISC_LBA}" "${MISC_SECTORS}" "${MISC}"
write_part dtbo "${DTBO_LBA}" "${DTBO_SECTORS}" "${DTBO}"
write_part resource "${RESOURCE_LBA}" "${RESOURCE_SECTORS}" "${RESOURCE}"
write_part kernel "${KERNEL_LBA}" "${KERNEL_SECTORS}" "${KERNEL}"
write_part boot "${BOOT_LBA}" "${BOOT_SECTORS}" "${BOOT}"
write_part recovery "${RECOVERY_LBA}" "${RECOVERY_SECTORS}" "${RECOVERY}"

rootfs_src=""
case "${ROOTFS_KIND}" in
  dir)
    rootfs_src=${WORKDIR}/rootfs.ext4
    truncate -s $((ROOTFS_SECTORS * 512)) "${rootfs_src}"
    printf 'mkfs.ext4 -b 4096 -L rootfs %s\n' "${ROOTFS}"
    if ! mkfs.ext4 -F -b 4096 -L rootfs -d "${ROOTFS}" \
      -E lazy_itable_init=0,lazy_journal_init=0 \
      "${rootfs_src}" >"${WORKDIR}/mkfs.out" 2>"${WORKDIR}/mkfs.err"; then
      cat "${WORKDIR}/mkfs.err" >&2
      die "mkfs.ext4 失败。rootfs 目录可能超过分区（${ROOTFS_SECTORS} 扇区）。"
    fi
    need_cmd dumpe2fs "包 e2fsprogs"
    require_rootfs_ext "${rootfs_src}"
    ;;
  sparse)
    rootfs_src=$(materialize rootfs "${ROOTFS}" "${ROOTFS_SECTORS}")
    require_rootfs_ext "${rootfs_src}"
    ;;
  raw)
    rootfs_src=${ROOTFS}
    payload_fits rootfs "${rootfs_src}" "${ROOTFS_SECTORS}"
    require_rootfs_ext "${rootfs_src}"
    ;;
esac

printf '写入 rootfs @ LBA 0x46000\n'
dd_at_lba "${rootfs_src}" "${ROOTFS_LBA}"
assert_prefix "${rootfs_src}" "${ROOTFS_LBA}" rootfs
rootfs_magic=$(od_hex "${PARTIAL}" $((ROOTFS_LBA * 512 + EXT_MAGIC_OFFSET)) 2)
if [[ ${rootfs_magic} != 53ef ]]; then
  die "rootfs 分区超级块 magic 不是 0xEF53（偏移 ${EXT_MAGIC_OFFSET}，读到 ${rootfs_magic}）"
fi

sync -f "${PARTIAL}" 2>/dev/null || true
mv -f -- "${PARTIAL}" "${OUT}"
PARTIAL=""
printf '已写入: %s (%s 字节)\n' "${OUT}" "${IMAGE_BYTES}"
