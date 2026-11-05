#!/usr/bin/env bash
# NanoPi NEO3 Plus 的 Ubuntu rootfs。主产物是目录。
# 打包：sudo ./scripts/build-image.sh --rootfs <目录>
# 说明：docs/resolute-rootfs.md。用户态决策见 docs/adr/0001，本脚本不改那份 ADR。
set -euo pipefail

usage() {
  cat <<'EOF'
用法: sudo ./scripts/build-resolute-rootfs.sh [选项]

做出 NanoPi NEO3 Plus 的 Ubuntu rootfs 目录（主产物）。
镜像打包消费该目录：

  sudo ./scripts/build-image.sh --rootfs <目录>

本脚本不把系统写入 SD 或 eMMC，也不对块设备做 dd。第一张卡用备用 SD，
由 build-image.sh 的产物另行写入。可选 rootfs.img 只在普通文件上用
fallocate，或 dd if=/dev/zero 做完整分配。

DW-MiBook 前提（写在帮助里，跑 Resolute 之前核对）：
  debootstrap 是 1.0.134ubuntu2
  apt/apt-get 免密
  sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute

主机若没有 resolute 脚本，上列 ln -sf 是规定修法。系统脚本仍缺失时，
本脚本再用私有 DEBOOTSTRAP_DIR 把 resolute 链到 gutsy。

选项:
  --output DIR       rootfs 目录。默认 out/rootfs-<suite>（相对当前目录）
  --suite NAME       resolute（默认）或 noble。Resolute 源失败时允许
                     SUITE=noble 作过渡 rootfs，仍是本脚本。
  --mirror NAME      aliyun（默认，阿里云 ubuntu-ports）、tuna（清华）、
                     official（ports.ubuntu.com）。拒绝 amd64 archive.ubuntu.com。
  --carry FILE       可选。把 carry.tgz 解进 rootfs（模块、固件、密钥等）。
  --kver STRING      kernel.img 对应的完整 uname -r。目录名必须是
                     /lib/modules/$KVER，不能只写 6.1 前缀。
  --rootfs-img FILE  可选。另写 raw ext4，卷标 rootfs，fallocate 或 dd
                     完整分配。不强制稀疏文件，不生成 android sparse。
                     build-image.sh 的 simg2img 只用于调用者另行传入的
                     android-sparse .img；本脚本不产那种文件。
  -h, --help         显示本说明后退出 0

环境变量 SUITE、MIRROR 与上列选项相同。在仓库根目录执行。
x86_64 构建主机必须已安装 qemu-user-static，否则直接失败。主机可以是
x86_64 或 arm64。

不安装 Desktop、snapd、NetworkManager、cloud-init，也不安装
linux-image-generic / linux-generic（Resolute generic 是 7.0）及
linux-headers-generic。apt-mark hold，并在
/etc/apt/preferences.d 写 Pin-Priority: -1。
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

MNT=""
CLEAN_DEBOOTSTRAP_DIR=""

cleanup() {
  local status=$?
  if [[ -n ${MNT} && -d ${MNT} ]]; then
    umount "${MNT}" 2>/dev/null || true
    rmdir "${MNT}" 2>/dev/null || true
  fi
  if [[ -n ${CLEAN_DEBOOTSTRAP_DIR} && -d ${CLEAN_DEBOOTSTRAP_DIR} ]]; then
    rm -rf "${CLEAN_DEBOOTSTRAP_DIR}"
  fi
  exit "${status}"
}
trap cleanup EXIT

SUITE=${SUITE:-resolute}
MIRROR=${MIRROR:-aliyun}
OUTPUT=""
CARRY=""
KVER=""
ROOTFS_IMG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --output)
      need_arg "$@"
      OUTPUT=$2
      shift 2
      ;;
    --suite)
      need_arg "$@"
      SUITE=$2
      shift 2
      ;;
    --mirror)
      need_arg "$@"
      MIRROR=$2
      shift 2
      ;;
    --carry)
      need_arg "$@"
      CARRY=$2
      shift 2
      ;;
    --kver)
      need_arg "$@"
      KVER=$2
      shift 2
      ;;
    --rootfs-img)
      need_arg "$@"
      ROOTFS_IMG=$2
      shift 2
      ;;
    *)
      die "无法识别的参数: $1（用 --help 查看）"
      ;;
  esac
done

case "${SUITE}" in
  resolute|noble) ;;
  *)
    die "SUITE 只允许 resolute（默认）或 noble（Resolute 源失败时的过渡 rootfs）。当前: ${SUITE}"
    ;;
esac

resolve_mirror() {
  case "$1" in
    *archive.ubuntu.com*)
      die "拒绝 amd64 源 archive.ubuntu.com。请使用 ubuntu-ports：MIRROR=aliyun（默认）、MIRROR=tuna 或 MIRROR=official。"
      ;;
  esac
  case "$1" in
    aliyun)
      MIRROR_URL=http://mirrors.aliyun.com/ubuntu-ports
      ;;
    tuna)
      MIRROR_URL=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
      ;;
    official)
      MIRROR_URL=http://ports.ubuntu.com/ubuntu-ports
      ;;
    *)
      die "未知 MIRROR=${1}。可选：aliyun（默认，阿里云 ubuntu-ports）、tuna（清华）、official（ports.ubuntu.com）。拒绝 archive.ubuntu.com。"
      ;;
  esac
}

resolve_mirror "${MIRROR}"

if [[ -z ${OUTPUT} ]]; then
  OUTPUT="out/rootfs-${SUITE}"
fi

reject_device() {
  local label=$1 path=$2
  if [[ ${path} == /dev/* || -b ${path} ]]; then
    die "${label} 指向块设备（${path}）。本脚本不 dd，不写 SD，不碰 eMMC。第一张卡用备用 SD。"
  fi
}

reject_device "输出目录" "${OUTPUT}"
if [[ -n ${ROOTFS_IMG} ]]; then
  reject_device "rootfs.img" "${ROOTFS_IMG}"
fi

ensure_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    die "需要 root。DW-MiBook 前提：apt/apt-get 免密，并且用免密 sudo 运行本脚本（sudo -n）。"
  fi
  # sudo 会清掉环境变量。把已经解析的 SUITE / MIRROR 写成参数再执行。
  local -a args=(--suite "${SUITE}" --mirror "${MIRROR}" --output "${OUTPUT}")
  if [[ -n ${CARRY} ]]; then
    args+=(--carry "${CARRY}")
  fi
  if [[ -n ${KVER} ]]; then
    args+=(--kver "${KVER}")
  fi
  if [[ -n ${ROOTFS_IMG} ]]; then
    args+=(--rootfs-img "${ROOTFS_IMG}")
  fi
  exec sudo -n -- "$0" "${args[@]}"
}

ensure_root

check_host_arch() {
  local machine
  machine=$(uname -m)
  case "${machine}" in
    aarch64|arm64)
      return 0
      ;;
    x86_64)
      if [[ ! -x /usr/bin/qemu-aarch64-static ]]; then
        die "x86_64 构建主机需要 qemu-user-static（未找到 /usr/bin/qemu-aarch64-static）。请先安装 qemu-user-static。"
      fi
      if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 && ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64-static && ! -e /proc/sys/fs/binfmt_misc/aarch64 ]]; then
        die "x86_64 构建主机需要已注册的 qemu-aarch64 binfmt。已安装 qemu-user-static 后执行：sudo systemctl restart systemd-binfmt"
      fi
      ;;
    *)
      die "不支持的构建主机架构: ${machine}。只支持 x86_64（需 qemu-user-static）或 arm64。"
      ;;
  esac
}

check_debootstrap() {
  local ver
  command -v debootstrap >/dev/null 2>&1 || die "未安装 debootstrap。DW-MiBook 前提版本是 1.0.134ubuntu2。"
  ver=$(dpkg-query -W -f '${Version}' debootstrap 2>/dev/null || true)
  if [[ -z ${ver} ]]; then
    ver=$(debootstrap --version 2>/dev/null | awk '{print $NF}' || true)
  fi
  if [[ ${ver} != 1.0.134ubuntu2 ]]; then
    printf '警告: DW-MiBook 前提是 debootstrap 1.0.134ubuntu2，当前是 %s。\n' "${ver:-未知}" >&2
  fi
  if [[ ! -d /usr/share/debootstrap/scripts ]]; then
    die "未找到 /usr/share/debootstrap/scripts。请安装 debootstrap 1.0.134ubuntu2。"
  fi
  if [[ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
    die "主机缺少 /usr/share/keyrings/ubuntu-archive-keyring.gpg（包 ubuntu-keyring）。不要改用 archive.ubuntu.com。"
  fi
}

prepare_resolute_script() {
  local sys=/usr/share/debootstrap
  local dst item base
  if [[ ${SUITE} != resolute ]]; then
    return 0
  fi
  if [[ -e ${sys}/scripts/resolute ]]; then
    return 0
  fi
  if [[ ! -e ${sys}/scripts/gutsy ]]; then
    die "没有 ${sys}/scripts/gutsy，无法为 resolute 建链接。请安装 debootstrap，并执行：sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute"
  fi
  printf '警告: 主机没有 %s/scripts/resolute。\n' "${sys}" >&2
  printf '规定修法（DW-MiBook，跑 Resolute 之前执行）：\n' >&2
  printf '  sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute\n' >&2
  printf '本次使用私有 DEBOOTSTRAP_DIR，把 resolute 符号链接到 gutsy。\n' >&2

  dst=$(mktemp -d)
  CLEAN_DEBOOTSTRAP_DIR=${dst}
  mkdir -p "${dst}/scripts"
  for item in "${sys}"/*; do
    base=$(basename "${item}")
    if [[ ${base} == scripts ]]; then
      continue
    fi
    ln -s "${item}" "${dst}/${base}"
  done
  for item in "${sys}/scripts"/*; do
    ln -s "${item}" "${dst}/scripts/$(basename "${item}")"
  done
  ln -sfn "${sys}/scripts/gutsy" "${dst}/scripts/resolute"
  DEBOOTSTRAP_DIR=${dst}
}

in_target() {
  chroot "${OUTPUT}" "$@"
}

write_sources() {
  local keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  if [[ ! -f ${OUTPUT}${keyring} ]]; then
    die "rootfs 里没有 ${keyring}。ubuntu-keyring 未装好，不能把源指到 ubuntu-ports。"
  fi
  mkdir -p "${OUTPUT}/etc/apt/sources.list.d"
  rm -f "${OUTPUT}/etc/apt/sources.list.d/"*.list "${OUTPUT}/etc/apt/sources.list.d/"*.sources
  cat > "${OUTPUT}/etc/apt/sources.list" <<EOF
# ubuntu-ports。不要改成 amd64 的 archive.ubuntu.com。
# 三个 pocket 在 sources.list.d/ubuntu-ports.sources。
EOF
  cat > "${OUTPUT}/etc/apt/sources.list.d/ubuntu-ports.sources" <<EOF
Types: deb
URIs: ${MIRROR_URL}
Suites: ${SUITE} ${SUITE}-updates ${SUITE}-security
Components: main
Signed-By: ${keyring}
EOF
}

write_kernel_pin() {
  mkdir -p "${OUTPUT}/etc/apt/preferences.d"
  cat > "${OUTPUT}/etc/apt/preferences.d/no-official-kernel" <<'EOF'
# Resolute 的 linux-image-generic 是 7.0。厂商内核来自 kernel.img 与 /lib/modules。

Package: linux-image-generic
Pin: release *
Pin-Priority: -1

Package: linux-generic
Pin: release *
Pin-Priority: -1

Package: linux-headers-generic
Pin: release *
Pin-Priority: -1
EOF
}

install_build_resolv() {
  if [[ ! -r /etc/resolv.conf ]]; then
    die "构建主机没有可读的 /etc/resolv.conf，chroot 里无法 apt-get update。"
  fi
  rm -f "${OUTPUT}/etc/resolv.conf"
  if ! cp -L /etc/resolv.conf "${OUTPUT}/etc/resolv.conf"; then
    die "无法复制主机 /etc/resolv.conf 到 rootfs，chroot 里无法 apt-get update。"
  fi
}

point_resolv_at_resolved() {
  ln -sfn ../run/systemd/resolve/stub-resolv.conf "${OUTPUT}/etc/resolv.conf"
}

configure_identity() {
  printf 'nanopi-neo3-plus\n' > "${OUTPUT}/etc/hostname"
  cat > "${OUTPUT}/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 nanopi-neo3-plus

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

  in_target sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  in_target locale-gen en_US.UTF-8
  printf 'LANG=en_US.UTF-8\n' > "${OUTPUT}/etc/default/locale"
  printf 'LANG=en_US.UTF-8\n' > "${OUTPUT}/etc/locale.conf"

  printf 'tzdata tzdata/Areas select Asia\ntzdata tzdata/Zones/Asia select Shanghai\n' \
    | in_target debconf-set-selections
  ln -sfn /usr/share/zoneinfo/Asia/Shanghai "${OUTPUT}/etc/localtime"
  printf 'Asia/Shanghai\n' > "${OUTPUT}/etc/timezone"
  in_target dpkg-reconfigure -f noninteractive tzdata
}

write_fstab_file() {
  cat > "${OUTPUT}/etc/fstab" <<'EOF'
# 根分区按卷标挂载。不要改成 /dev/mmcblk*。
LABEL=rootfs  /  ext4  errors=remount-ro  0  1
EOF
}

ensure_root_fstab() {
  local fstab="${OUTPUT}/etc/fstab"
  local tmp
  tmp=$(mktemp)
  if [[ -f ${fstab} ]]; then
    awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      $2 == "/" && $1 != "LABEL=rootfs" {
        printf "警告: fstab 根行是「%s」，已改回 LABEL=rootfs（不要使用 /dev/mmcblk*）。\n", $1 > "/dev/stderr"
        print "LABEL=rootfs  /  ext4  errors=remount-ro  0  1"
        next
      }
      { print }
    ' "${fstab}" > "${tmp}"
    if ! awk '$1 !~ /^#/ && $2 == "/" { found=1 } END { exit found ? 0 : 1 }' "${tmp}"; then
      printf 'LABEL=rootfs  /  ext4  errors=remount-ro  0  1\n' >> "${tmp}"
    fi
  else
    printf '%s\n' '# 根分区按卷标挂载。不要改成 /dev/mmcblk*。' \
      'LABEL=rootfs  /  ext4  errors=remount-ro  0  1' > "${tmp}"
  fi
  install -m 0644 "${tmp}" "${fstab}"
  rm -f "${tmp}"
}

write_netplan() {
  mkdir -p "${OUTPUT}/etc/netplan"
  cat > "${OUTPUT}/etc/netplan/01-dhcp-eth0.yaml" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      # 板上网卡名可能是 end0，以 ip link 为准。若不是 eth0，改用 match，例如：
      # match:
      #   name: "end0"
EOF
  chmod 600 "${OUTPUT}/etc/netplan/01-dhcp-eth0.yaml"
}

enable_unit() {
  local unit=$1
  local lib=""
  if [[ -f ${OUTPUT}/usr/lib/systemd/system/${unit} ]]; then
    lib=/usr/lib/systemd/system/${unit}
  elif [[ -f ${OUTPUT}/lib/systemd/system/${unit} ]]; then
    lib=/lib/systemd/system/${unit}
  else
    die "rootfs 中没有 systemd 单元 ${unit}，无法 enable。"
  fi
  if ! systemctl enable --root="${OUTPUT}" "${unit}"; then
    mkdir -p "${OUTPUT}/etc/systemd/system/multi-user.target.wants"
    ln -sfn "${lib}" "${OUTPUT}/etc/systemd/system/multi-user.target.wants/${unit}"
  fi
}

apply_carry() {
  if [[ ! -f ${CARRY} ]]; then
    die "carry 不是已存在的文件: ${CARRY}"
  fi
  case ${CARRY} in
    *.img|*.img.gz|*.img.xz)
      die "carry 应是 tar 包（例如 carry.tgz），不是磁盘镜像。"
      ;;
  esac
  tar --numeric-owner -C "${OUTPUT}" -xf "${CARRY}"
}

verify_modules() {
  local d base
  local -a extras=()
  local -a dirs=()
  shopt -s nullglob
  for d in "${OUTPUT}/lib/modules"/*; do
    if [[ -d ${d} ]]; then
      dirs+=("${d}")
    fi
  done
  shopt -u nullglob

  if [[ -n ${CARRY} && ${#dirs[@]} -eq 0 ]]; then
    die "carry 解包后没有 /lib/modules/<完整 uname -r>。请把启动该 kernel.img 的 Noble 板上的模块打进 carry.tgz。"
  fi
  if [[ -z ${KVER} ]]; then
    if [[ ${#dirs[@]} -gt 1 ]]; then
      die "存在多个 /lib/modules 目录，请用 --kver 指定与 kernel.img 一致的完整 uname -r。"
    fi
    if [[ ${#dirs[@]} -eq 1 ]]; then
      printf '模块目录: /lib/modules/%s\n' "$(basename "${dirs[0]}")"
      printf '请在启动该 kernel.img 的 Noble 板上核对：uname -r，以及 modinfo -F vermagic 的第一字段，必须与目录名全字符串相同。\n'
    else
      printf '尚未带入 /lib/modules。打包前按 docs/resolute-rootfs.md 做 carry，目录名必须是完整 uname -r。\n'
    fi
    return 0
  fi
  if [[ ! -d ${OUTPUT}/lib/modules/${KVER} ]]; then
    die "缺少 /lib/modules/${KVER}。目录名必须是 kernel.img 对应的完整 uname -r，不能只写 6.1 前缀。在启动该 kernel.img 的 Noble 板上执行 uname -r，并用 modinfo -F vermagic 的第一字段核对。"
  fi
  for d in "${dirs[@]}"; do
    base=$(basename "${d}")
    if [[ ${base} != "${KVER}" ]]; then
      extras+=("${base}")
    fi
  done
  if ((${#extras[@]} > 0)); then
    die "模块目录与 KVER=${KVER} 不一致，还存在: ${extras[*]}。必须全字符串匹配，不能只对 6.1 前缀。"
  fi
}

forbid_packages() {
  local bad
  bad=$(awk '
    function check() {
      if (st != "install ok installed") return
      if (p == "snapd" || p == "network-manager" || p == "cloud-init" ||
          p == "linux-image-generic" || p == "linux-generic" ||
          p == "linux-headers-generic" || p == "ubuntu-desktop" ||
          p == "ubuntu-desktop-minimal" ||
          p ~ /^linux-image-/ || p ~ /^linux-headers-/ || p ~ /^linux-modules-/)
        print p
    }
    $1 == "Package:" { check(); p = $2; st = ""; next }
    $1 == "Status:" { st = $2 " " $3 " " $4; next }
    END { check() }
  ' "${OUTPUT}/var/lib/dpkg/status")
  if [[ -n ${bad} ]]; then
    die "rootfs 含禁止安装的包（Desktop / snapd / NetworkManager / cloud-init / 官方内核）：${bad//$'\n'/ }"
  fi
  if compgen -G "${OUTPUT}/lib/modules/7.*" >/dev/null || compgen -G "${OUTPUT}/boot/vmlinuz-7.*" >/dev/null; then
    die "rootfs 出现了官方 7.0 内核文件。Resolute generic 是 7.0，不能装。"
  fi
}

file_is_fully_allocated() {
  local file=$1
  local size blocks alloc
  size=$(stat -c '%s' "${file}")
  blocks=$(stat -c '%b' "${file}")
  alloc=$((blocks * 512))
  [[ ${alloc} -ge ${size} ]]
}

assert_fully_allocated() {
  local file=$1
  if ! file_is_fully_allocated "${file}"; then
    local size blocks alloc
    size=$(stat -c '%s' "${file}")
    blocks=$(stat -c '%b' "${file}")
    alloc=$((blocks * 512))
    die "rootfs.img 是稀疏文件（逻辑 ${size} 字节，已分配 ${alloc}）。请用 fallocate 或 dd if=/dev/zero 完整分配，不要强制稀疏。"
  fi
}

write_rootfs_img() {
  local dest=$1
  local used bytes mib
  local parent
  command -v mkfs.ext4 >/dev/null 2>&1 || die "主机没有 mkfs.ext4（e2fsprogs），无法写 raw ext4 rootfs.img。"
  command -v e2label >/dev/null 2>&1 || die "主机没有 e2label（e2fsprogs），无法核对卷标 rootfs。"
  used=$(du -sb "${OUTPUT}" | awk '{print $1}')
  bytes=$((used + used / 4 + 256 * 1024 * 1024))
  if ((bytes < 768 * 1024 * 1024)); then
    bytes=$((768 * 1024 * 1024))
  fi
  mib=$(((bytes + 1048576 - 1) / 1048576))
  bytes=$((mib * 1048576))
  parent=$(dirname "${dest}")
  mkdir -p "${parent}"
  rm -f "${dest}"
  if ! fallocate -l "${bytes}" "${dest}" || ! file_is_fully_allocated "${dest}"; then
    rm -f "${dest}"
    # 这是镜像文件的完整分配，不是写 SD / eMMC。
    dd if=/dev/zero of="${dest}" bs=1048576 count="${mib}" status=progress
  fi
  assert_fully_allocated "${dest}"
  # raw ext4。不要 -E android_sparse，也不要 img2simg。
  mkfs.ext4 -F -L rootfs "${dest}"
  assert_fully_allocated "${dest}"
  if [[ $(e2label "${dest}") != rootfs ]]; then
    die "rootfs.img 卷标不是 rootfs（e2label 读到 $(e2label "${dest}")）。"
  fi
  MNT=$(mktemp -d)
  mount -o loop "${dest}" "${MNT}"
  tar -C "${OUTPUT}" --one-file-system --xattrs --xattrs-include='*' --numeric-owner -cpf - . \
    | tar -C "${MNT}" --xattrs --xattrs-include='*' --numeric-owner -xpf -
  umount "${MNT}"
  rmdir "${MNT}"
  MNT=""
  assert_fully_allocated "${dest}"
  printf '已写出 raw ext4（卷标 rootfs，完整分配）: %s\n' "${dest}"
}

check_host_arch
check_debootstrap
prepare_resolute_script

if [[ -e ${OUTPUT} ]]; then
  die "输出路径已存在: ${OUTPUT}。请换 --output，或删掉该目录后重跑。"
fi
mkdir -p "$(dirname "${OUTPUT}")"

INCLUDE="systemd,systemd-sysv,udev,dbus,apt-utils,sudo,openssh-server,netplan.io,systemd-resolved,ca-certificates,locales,tzdata,kmod,initramfs-tools,iproute2,iputils-ping,ubuntu-keyring,adduser,procps,ethtool,e2fsprogs"
EXCLUDE="snapd,network-manager,cloud-init,linux-image-generic,linux-generic,linux-headers-generic,ubuntu-desktop,ubuntu-desktop-minimal"

printf 'suite:  %s\n' "${SUITE}"
printf 'mirror: %s\n' "${MIRROR_URL}"
printf 'output: %s\n' "${OUTPUT}"
if [[ ${SUITE} == noble ]]; then
  printf 'SUITE=noble 是过渡 rootfs（Resolute 源失败时）。产品路径仍是 26.04 Resolute。\n'
fi

deb_env=()
if [[ -n ${DEBOOTSTRAP_DIR:-} ]]; then
  deb_env+=(DEBOOTSTRAP_DIR="${DEBOOTSTRAP_DIR}")
fi

if ! env "${deb_env[@]}" debootstrap \
  --arch=arm64 \
  --variant=minbase \
  --components=main \
  --include="${INCLUDE}" \
  --exclude="${EXCLUDE}" \
  --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
  "${SUITE}" \
  "${OUTPUT}" \
  "${MIRROR_URL}"
then
  if [[ ${SUITE} == resolute ]]; then
    die "debootstrap resolute 失败。确认已执行：sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute。Resolute 源失败时可用同一脚本 SUITE=noble 做过渡 rootfs。"
  fi
  die "debootstrap ${SUITE} 失败。"
fi

if [[ -n ${CLEAN_DEBOOTSTRAP_DIR} ]]; then
  rm -rf "${CLEAN_DEBOOTSTRAP_DIR}"
  CLEAN_DEBOOTSTRAP_DIR=""
  unset DEBOOTSTRAP_DIR
fi

if [[ $(uname -m) == x86_64 ]]; then
  cp -a /usr/bin/qemu-aarch64-static "${OUTPUT}/usr/bin/qemu-aarch64-static"
fi

export DEBIAN_FRONTEND=noninteractive
install_build_resolv
write_sources
write_kernel_pin

if ! in_target apt-get update; then
  if [[ ${SUITE} == resolute ]]; then
    die "apt-get update 失败（${MIRROR_URL}，suite ${SUITE}）。Resolute 源失败时可用同一脚本 SUITE=noble 做过渡 rootfs。"
  fi
  die "apt-get update 失败（${MIRROR_URL}，suite ${SUITE}）。"
fi
in_target apt-mark hold linux-image-generic linux-generic linux-headers-generic
in_target apt-get clean

configure_identity
write_fstab_file
write_netplan
enable_unit ssh.service
enable_unit systemd-networkd.service
enable_unit systemd-resolved.service
in_target netplan generate
if [[ -d ${OUTPUT}/run ]]; then
  find "${OUTPUT}/run" -mindepth 1 -delete
fi

if [[ -n ${CARRY} ]]; then
  apply_carry
fi
ensure_root_fstab
verify_modules
forbid_packages

rm -f "${OUTPUT}/usr/bin/qemu-aarch64-static"
: > "${OUTPUT}/etc/machine-id"
rm -f "${OUTPUT}/var/lib/dbus/machine-id"
point_resolv_at_resolved

if [[ -n ${ROOTFS_IMG} ]]; then
  write_rootfs_img "${ROOTFS_IMG}"
fi

printf 'rootfs 目录: %s\n' "${OUTPUT}"
printf '下一步（在仓库根目录，其它必选参数见 scripts/build-image.sh --help）：\n'
printf '  sudo ./scripts/build-image.sh --rootfs %s\n' "${OUTPUT}"
