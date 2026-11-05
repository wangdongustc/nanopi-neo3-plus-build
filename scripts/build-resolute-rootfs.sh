#!/usr/bin/env bash
# NanoPi NEO3 Plus 的 Ubuntu 用户态 rootfs。主产物是目录。
# 交接: sudo ./scripts/build-image.sh --rootfs <目录>
# 决策: docs/adr/0001-userland-resolute-debootstrap.md
#       docs/adr/0002-own-image-builder.md
# 步骤与 carry / 验收: docs/resolute-rootfs.md
# 不 dd 磁盘，不调用 mk-emmc-image.sh，sd-fuse 不是出口。
set -euo pipefail

# mkfs.ext4、dumpe2fs 在 /usr/sbin，非登录 shell 的 PATH 里经常没有。
export PATH="/usr/sbin:/sbin:${PATH}"

FSTAB_ROOT='LABEL=rootfs  /  ext4 defaults,noatime,errors=remount-ro 0 1'
HOLD_PACKAGES=(linux-image-generic linux-generic linux-headers-generic)
MOUNTED=0
QEMU_COPIED=0
TARGET=""

usage() {
  cat <<'EOF'
用法: sudo ./scripts/build-resolute-rootfs.sh [选项]

在仓库根目录执行。主产物是 rootfs 目录（默认 out/resolute-rootfs），
不是磁盘镜像。脚本结束时打印交接命令:

  sudo ./scripts/build-image.sh --rootfs <目录>

只在所有者的 DW-MiBook 上跑。该机 debootstrap 为 1.0.134ubuntu2，
apt 免密。Resolute 之前先补 suite 脚本:

  sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute

主机不是 arm64 时，需要 qemu-user-static 提供的 qemu-aarch64-static
做 second-stage。本脚本不 dd 磁盘，不调用 mk-emmc-image，也不调用
sd-fuse 的 mk-sd-image.sh / fusing.sh / sd_update。

选项:
  --out DIR            rootfs 目录，默认 out/resolute-rootfs
  --suite NAME         resolute（默认）或 noble。
                       noble 只在 Resolute 镜像源故障时作过渡。
  --mirror NAME|URL    aliyun（默认，https://mirrors.aliyun.com/ubuntu-ports）、
                       tuna 或 official（http://ports.ubuntu.com/ubuntu-ports）。
                       也可以给 ubuntu-ports URL。拒绝 archive.ubuntu.com。
  --pack-img [FILE]    可选。写出 raw ext4，卷标 rootfs，块大小 4096。
                       默认 out/resolute-rootfs.img。主路径不需要。
                       用 fallocate 或 dd if=/dev/zero 分配完整文件，
                       不是稀疏空洞，也不是 android sparse。
                       仅当 KERNEL_RELEASE 与唯一的 /lib/modules 目录全名一致，
                       且 .ko 的 vermagic 第一字段等于该字符串时才写。
  --kernel-release REL 覆盖环境变量 KERNEL_RELEASE。必须是板上 uname -r
                       的完整字符串，不能只写 6.1。
  -h, --help           显示本说明后退出 0

环境变量: SUITE、MIRROR、KERNEL_RELEASE。命令行选项优先。
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

resolve_mirror() {
  local raw=${1:-aliyun}
  raw=${raw%/}
  case "$raw" in
    ''|aliyun)
      printf '%s\n' 'https://mirrors.aliyun.com/ubuntu-ports'
      ;;
    tuna)
      printf '%s\n' 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'
      ;;
    official)
      printf '%s\n' 'http://ports.ubuntu.com/ubuntu-ports'
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

validate_mirror_url() {
  local url=$1
  if [[ ${url} == *archive.ubuntu.com* ]]; then
    die "拒绝 archive.ubuntu.com。arm64 必须用 ubuntu-ports（aliyun、tuna 或 official）。"
  fi
  if [[ ${url} != *ubuntu-ports* ]]; then
    die "镜像 URL 必须是 ubuntu-ports，当前: ${url}"
  fi
}

validate_suite() {
  case "$1" in
    resolute|noble) ;;
    *)
      die "SUITE 只能是 resolute（默认）或 noble（仅当 Resolute 源故障时的过渡），当前: $1"
      ;;
  esac
}

validate_kernel_release_token() {
  local release=$1
  if [[ -z ${release} ]]; then
    die "缺少 KERNEL_RELEASE。它必须是 Noble 板上 uname -r 的完整字符串，不能只写 6.1。"
  fi
  case "${release}" in
    6.1|6.1.)
      die "KERNEL_RELEASE=${release} 只是 6.1 前缀。必须与 uname -r 全字符串一致。"
      ;;
    *'*'*|*'?'*)
      die "KERNEL_RELEASE 不能含通配符: ${release}"
      ;;
  esac
}

check_os_release() {
  local file=$1
  local id="" version_id="" codename=""
  [[ -f ${file} ]] || die "缺少 ${file}"
  id=$(sed -n 's/^ID=//p' "${file}" | tr -d '"')
  version_id=$(sed -n 's/^VERSION_ID=//p' "${file}" | tr -d '"')
  codename=$(sed -n 's/^VERSION_CODENAME=//p' "${file}" | tr -d '"')
  if [[ -z ${codename} ]]; then
    codename=$(sed -n 's/^UBUNTU_CODENAME=//p' "${file}" | tr -d '"')
  fi
  [[ ${id} == ubuntu ]] || die "os-release ID 必须是 ubuntu，当前: ${id:-空}"
  case "${SUITE}" in
    resolute)
      [[ ${version_id} == 26.04 && ${codename} == resolute ]] || \
        die "os-release 必须是 26.04/resolute，当前 VERSION_ID=${version_id:-空} CODENAME=${codename:-空}"
      ;;
    noble)
      [[ ${version_id} == 24.04 && ${codename} == noble ]] || \
        die "os-release 必须是 24.04/noble，当前 VERSION_ID=${version_id:-空} CODENAME=${codename:-空}"
      ;;
  esac
}

write_fstab() {
  local rootfs=$1
  mkdir -p "${rootfs}/etc"
  cat > "${rootfs}/etc/fstab" <<EOF
# 根分区按卷标挂载，与 scripts/partition-layout.md 的 ext4 卷标一致。
# 不要改成 /dev/mmcblk*。
${FSTAB_ROOT}
proc  /proc  proc  defaults  0  0
sysfs /sys   sysfs defaults  0  0
tmpfs /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF
}

assert_fstab() {
  local rootfs=$1
  [[ -f ${rootfs}/etc/fstab ]] || die "缺少 ${rootfs}/etc/fstab"
  grep -qxF "${FSTAB_ROOT}" "${rootfs}/etc/fstab" || \
    die "fstab 根行必须是: ${FSTAB_ROOT}"
  if grep -v '^[[:space:]]*#' "${rootfs}/etc/fstab" | grep -q '/dev/mmcblk'; then
    die "fstab 含有 /dev/mmcblk。根必须是 LABEL=rootfs。"
  fi
}

write_netplan() {
  local rootfs=$1
  mkdir -p "${rootfs}/etc/netplan"
  cat > "${rootfs}/etc/netplan/01-eth0.yaml" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      match:
        name: eth0
      dhcp4: true
      # 板上网卡名可能是 end0。先在板上 ip link 确认，再把 match name 改成实际接口名。
EOF
  chmod 600 "${rootfs}/etc/netplan/01-eth0.yaml"
}

assert_netplan() {
  local file=$1/etc/netplan/01-eth0.yaml
  [[ -f ${file} ]] || die "缺少 ${file}"
  grep -q 'renderer: networkd' "${file}" || die "netplan renderer 必须是 networkd"
  grep -q 'dhcp4: true' "${file}" || die "netplan 必须打开 dhcp4"
  grep -q 'name: eth0' "${file}" || die "netplan 必须 match name eth0"
  grep -q 'end0' "${file}" || die "netplan 必须注明网卡名可能是 end0"
}

write_hostname() {
  local rootfs=$1
  printf 'nanopi-neo3-plus\n' > "${rootfs}/etc/hostname"
  cat > "${rootfs}/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 nanopi-neo3-plus

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
}

write_sources() {
  local rootfs=$1
  local url=$2
  local suite=$3
  local keyring="" candidate
  for candidate in \
    /usr/share/keyrings/ubuntu-archive-keyring.gpg \
    /usr/share/keyrings/ubuntu-archive-keyring.pgp
  do
    if [[ -f ${rootfs}${candidate} ]]; then
      keyring=${candidate}
      break
    fi
  done
  mkdir -p "${rootfs}/etc/apt"
  if [[ -n ${keyring} ]]; then
    cat > "${rootfs}/etc/apt/sources.list" <<EOF
deb [signed-by=${keyring}] ${url} ${suite} main
deb [signed-by=${keyring}] ${url} ${suite}-updates main
deb [signed-by=${keyring}] ${url} ${suite}-security main
EOF
  else
    cat > "${rootfs}/etc/apt/sources.list" <<EOF
deb ${url} ${suite} main
deb ${url} ${suite}-updates main
deb ${url} ${suite}-security main
EOF
  fi
  rm -f "${rootfs}/etc/apt/sources.list.d/ubuntu.sources"
}

write_pin() {
  local rootfs=$1
  mkdir -p "${rootfs}/etc/apt/preferences.d"
  cat > "${rootfs}/etc/apt/preferences.d/no-official-kernel" <<'EOF'
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

rootfs_is_configured() {
  local rootfs=$1
  [[ -f ${rootfs}/etc/nanopi-neo3-plus-rootfs && -f ${rootfs}/etc/os-release && -f ${rootfs}/etc/fstab && -f ${rootfs}/etc/netplan/01-eth0.yaml && -f ${rootfs}/etc/apt/preferences.d/no-official-kernel ]]
}

vermagic_release() {
  local ko=$1
  local line=""
  if command -v modinfo >/dev/null 2>&1; then
    line=$(modinfo -F vermagic -- "${ko}" 2>/dev/null || true)
  fi
  if [[ -z ${line} ]]; then
    line=$(strings -- "${ko}" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1 || true)
  fi
  printf '%s\n' "${line%% *}"
}

require_module_release() {
  local rootfs=$1
  local release=$2
  local modules=${rootfs}/lib/modules
  local -a mod_dirs=() kos=()
  local dir name ko field
  if ! command -v modinfo >/dev/null 2>&1 && ! command -v strings >/dev/null 2>&1; then
    die "核对 vermagic 需要 modinfo（kmod）或 strings（binutils）"
  fi
  validate_kernel_release_token "${release}"
  [[ -d ${modules} ]] || die "缺少 ${modules}。先从正在运行目标 kernel.img 的 Noble 板带入 /lib/modules/\$(uname -r)。"
  mapfile -d '' mod_dirs < <(find "${modules}" -mindepth 1 -maxdepth 1 -type d -print0)
  if [[ ${#mod_dirs[@]} -ne 1 ]]; then
    die "/lib/modules 下必须恰好有一个目录（uname -r 全名），当前 ${#mod_dirs[@]} 个。"
  fi
  dir=${mod_dirs[0]%$'\0'}
  name=$(basename "${dir}")
  if [[ ${name} != "${release}" ]]; then
    die "KERNEL_RELEASE=${release} 与 /lib/modules/${name} 不一致。必须是 uname -r 全字符串，不能只用 6.1 前缀。"
  fi
  mapfile -d '' kos < <(find "${dir}" -type f -name '*.ko' -print0)
  if [[ ${#kos[@]} -eq 0 ]]; then
    die "${modules}/${name} 里没有 .ko，无法核对 vermagic。"
  fi
  for ko in "${kos[@]}"; do
    ko=${ko%$'\0'}
    field=$(vermagic_release "${ko}")
    if [[ ${field} != "${release}" ]]; then
      die "vermagic 第一字段必须等于 ${release}，${ko} 读到: ${field:-空}"
    fi
  done
}

assert_not_sparse_file() {
  local img=$1
  local bytes blocks alloc magic
  bytes=$(stat -c '%s' "${img}")
  blocks=$(stat -c '%b' "${img}")
  alloc=$((blocks * 512))
  if [[ ${alloc} -lt ${bytes} ]]; then
    die "镜像是稀疏空洞文件（分配 ${alloc} 字节，名义 ${bytes} 字节）: ${img}"
  fi
  magic=$(od -An -tx1 -N4 "${img}" | tr -d ' \n')
  if [[ ${magic} == 3aff26ed ]]; then
    die "镜像是 android sparse，本脚本不写这种格式: ${img}"
  fi
}

fill_holes_if_needed() {
  local img=$1
  local bytes blocks alloc tmp
  bytes=$(stat -c '%s' "${img}")
  blocks=$(stat -c '%b' "${img}")
  alloc=$((blocks * 512))
  if [[ ${alloc} -ge ${bytes} ]]; then
    return 0
  fi
  if fallocate -l "${bytes}" "${img}" 2>/dev/null; then
    blocks=$(stat -c '%b' "${img}")
    alloc=$((blocks * 512))
    if [[ ${alloc} -ge ${bytes} ]]; then
      return 0
    fi
  fi
  tmp=${img}.alloc
  rm -f "${tmp}"
  dd if="${img}" of="${tmp}" bs=1048576 status=none
  mv -f "${tmp}" "${img}"
}

pack_ext4() {
  local rootfs=$1
  local img=$2
  local release=$3
  local content size parent vol bs
  assert_fstab "${rootfs}"
  require_module_release "${rootfs}" "${release}"
  if [[ -b ${img} || ${img} == /dev/* ]]; then
    die "拒绝把 rootfs 写到块设备: ${img}。不要 dd 磁盘。"
  fi
  parent=$(dirname "${img}")
  mkdir -p "${parent}"
  if [[ -e ${img} && ! -f ${img} ]]; then
    die "pack 输出已存在且不是普通文件: ${img}"
  fi
  case "${img}" in
    "${rootfs}"|"${rootfs}"/*)
      die "pack 输出不能放在 rootfs 目录里面: ${img}"
      ;;
  esac
  command -v mkfs.ext4 >/dev/null 2>&1 || die "缺少 mkfs.ext4（包 e2fsprogs）"
  command -v dumpe2fs >/dev/null 2>&1 || die "缺少 dumpe2fs（包 e2fsprogs）"
  content=$(du -sb "${rootfs}" | awk '{print $1}')
  size=$((content + content / 2 + 128 * 1024 * 1024))
  if [[ ${size} -lt $((256 * 1024 * 1024)) ]]; then
    size=$((256 * 1024 * 1024))
  fi
  size=$(((size + 1048575) / 1048576 * 1048576))
  rm -f "${img}"
  if ! fallocate -l "${size}" "${img}"; then
    printf 'fallocate 失败，改用 dd if=/dev/zero 分配完整文件\n' >&2
    rm -f "${img}"
    dd if=/dev/zero of="${img}" bs=1048576 count=$((size / 1048576)) status=none
  fi
  # nodiscard：避免 mkfs 对文件打洞。ext4 的 sparse_super 是元数据布局，不是空洞文件。
  if ! mkfs.ext4 -F -b 4096 -L rootfs -E nodiscard -d "${rootfs}" "${img}"; then
    die "mkfs.ext4 失败。没有使用 android sparse。"
  fi
  fill_holes_if_needed "${img}"
  assert_not_sparse_file "${img}"
  vol=$(dumpe2fs -h "${img}" 2>/dev/null | sed -n 's/^Filesystem volume name:[[:space:]]*//p')
  bs=$(dumpe2fs -h "${img}" 2>/dev/null | sed -n 's/^Block size:[[:space:]]*//p')
  [[ ${vol} == rootfs ]] || die "ext4 卷标必须是 rootfs，当前: ${vol:-空}"
  [[ ${bs} == 4096 ]] || die "ext4 块大小必须是 4096，当前: ${bs:-空}"
  printf 'raw ext4: %s（LABEL=rootfs，块 4096，完整分配，不是 android sparse）\n' "${img}"
}

reject_forbidden_packages() {
  local rootfs=$1
  local bad
  bad=$(chroot "${rootfs}" dpkg-query -W -f '${Package}\t${db:Status-Status}\n' | awk -F '\t' '
    $2 == "installed" && ($1 == "snapd" || $1 == "network-manager" || $1 == "cloud-init" ||
      $1 == "linux-image-generic" || $1 == "linux-generic" || $1 == "linux-headers-generic" ||
      $1 == "ubuntu-desktop" || $1 ~ /^linux-image-/) { print $1 }
  ')
  if [[ -n ${bad} ]]; then
    die "安装了禁止的包: $(printf '%s' "${bad}" | tr '\n' ' ')"
  fi
}

hold_kernel_packages() {
  local rootfs=$1
  local holds pkg
  chroot "${rootfs}" apt-mark hold "${HOLD_PACKAGES[@]}"
  holds=$(chroot "${rootfs}" apt-mark showhold)
  for pkg in "${HOLD_PACKAGES[@]}"; do
    grep -qx "${pkg}" <<<"${holds}" || die "未 apt-mark hold: ${pkg}"
  done
}

assert_pin_file() {
  local file=$1/etc/apt/preferences.d/no-official-kernel
  local pkg
  [[ -f ${file} ]] || die "缺少 ${file}"
  for pkg in "${HOLD_PACKAGES[@]}"; do
    grep -q "^Package: ${pkg}$" "${file}" || die "pin 文件缺少 ${pkg}"
  done
  grep -q '^Pin-Priority: -1$' "${file}" || die "pin 文件缺少 Pin-Priority: -1"
}

configure_locale_tz() {
  local rootfs=$1
  if [[ ! -f ${rootfs}/etc/locale.gen ]]; then
    die "缺少 /etc/locale.gen。locales 包应已安装。"
  fi
  if grep -qE '^#[[:space:]]*en_US\.UTF-8 UTF-8$' "${rootfs}/etc/locale.gen"; then
    sed -i 's/^#[[:space:]]*en_US\.UTF-8 UTF-8$/en_US.UTF-8 UTF-8/' "${rootfs}/etc/locale.gen"
  elif ! grep -qE '^en_US\.UTF-8 UTF-8$' "${rootfs}/etc/locale.gen"; then
    printf 'en_US.UTF-8 UTF-8\n' >> "${rootfs}/etc/locale.gen"
  fi
  chroot "${rootfs}" locale-gen en_US.UTF-8
  printf 'LANG=en_US.UTF-8\n' > "${rootfs}/etc/default/locale"
  printf 'LANG=en_US.UTF-8\n' > "${rootfs}/etc/locale.conf"
  ln -sfn /usr/share/zoneinfo/Asia/Shanghai "${rootfs}/etc/localtime"
  printf 'Asia/Shanghai\n' > "${rootfs}/etc/timezone"
  chroot "${rootfs}" dpkg-reconfigure -f noninteractive tzdata
}

enable_services() {
  local rootfs=$1
  local unit
  command -v systemctl >/dev/null 2>&1 || \
    die "缺少 systemctl，无法 enable ssh、systemd-networkd、systemd-resolved"
  for unit in ssh.service systemd-networkd.service systemd-resolved.service; do
    if [[ ! -e ${rootfs}/lib/systemd/system/${unit} && ! -e ${rootfs}/usr/lib/systemd/system/${unit} ]]; then
      die "缺少 systemd 单元 ${unit}。systemd / openssh-server / systemd-resolved 应已安装。"
    fi
  done
  # --root 在宿主上离线 enable，不依赖 chroot 里的 systemd 总线。
  if ! systemctl enable --root="${rootfs}" ssh.service systemd-networkd.service systemd-resolved.service; then
    die "systemctl enable 失败（ssh、systemd-networkd、systemd-resolved）"
  fi
}

copy_resolv_conf() {
  local rootfs=$1
  if [[ -r /etc/resolv.conf ]]; then
    cat /etc/resolv.conf > "${rootfs}/etc/resolv.conf"
  fi
}

use_resolved_stub() {
  local rootfs=$1
  rm -f "${rootfs}/etc/resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf "${rootfs}/etc/resolv.conf"
}

suite_script_ready() {
  local suite=$1
  if [[ -e /usr/share/debootstrap/scripts/${suite} ]]; then
    return 0
  fi
  if [[ ${suite} == resolute ]]; then
    die "Resolute 之前先执行: sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute"
  fi
  die "debootstrap 没有 suite 脚本: ${suite}"
}

debootstrap_supports_exclude() {
  debootstrap --help 2>&1 | grep -q -- '--exclude'
}

mount_target() {
  local rootfs=$1
  mkdir -p "${rootfs}/dev/pts" "${rootfs}/proc" "${rootfs}/sys"
  MOUNTED=1
  mountpoint -q "${rootfs}/dev" || mount --bind /dev "${rootfs}/dev"
  mountpoint -q "${rootfs}/dev/pts" || mount --bind /dev/pts "${rootfs}/dev/pts"
  mountpoint -q "${rootfs}/proc" || mount -t proc proc "${rootfs}/proc"
  mountpoint -q "${rootfs}/sys" || mount -t sysfs sysfs "${rootfs}/sys"
}

umount_target() {
  local rootfs=$1
  local path
  [[ ${MOUNTED:-0} == 1 ]] || return 0
  for path in "${rootfs}/dev/pts" "${rootfs}/dev" "${rootfs}/proc" "${rootfs}/sys"; do
    if mountpoint -q "${path}"; then
      umount "${path}" || umount -l "${path}" || true
    fi
  done
  MOUNTED=0
}

print_handoff() {
  local rootfs=$1
  printf 'rootfs 目录: %s\n' "${rootfs}"
  printf 'sudo ./scripts/build-image.sh --rootfs %s\n' "${rootfs}"
}

release_target_mounts() {
  local rootfs=$1
  local path
  umount_target "${rootfs}"
  for path in dev/pts dev proc sys; do
    if mountpoint -q "${rootfs}/${path}"; then
      die "未能卸载 ${rootfs}/${path}。拒绝继续，以免把挂载点打进 rootfs。"
    fi
  done
  if [[ ${QEMU_COPIED} == 1 ]]; then
    rm -f "${rootfs}/usr/bin/qemu-aarch64-static"
    QEMU_COPIED=0
  fi
}

run_debootstrap() {
  local rootfs=$1
  local suite=$2
  local url=$3
  export DEBIAN_FRONTEND=noninteractive
  export DEBCONF_NONINTERACTIVE_SEEN=true
  local include_csv exclude_csv
  local -a args
  local include_pkgs=(
    systemd
    systemd-sysv
    udev
    dbus
    apt-utils
    sudo
    openssh-server
    netplan.io
    systemd-resolved
    ca-certificates
    locales
    tzdata
    kmod
    initramfs-tools
    iproute2
    iputils-ping
    ubuntu-keyring
    adduser
    procps
    ethtool
    e2fsprogs
  )
  include_csv=$(IFS=,; printf '%s' "${include_pkgs[*]}")
  exclude_csv='snapd,network-manager,cloud-init,linux-image-generic,linux-generic,linux-headers-generic,ubuntu-desktop'
  args=(
    --arch=arm64
    --variant=minbase
    --foreign
    --include="${include_csv}"
  )
  if debootstrap_supports_exclude; then
    args+=(--exclude="${exclude_csv}")
  else
    printf 'warning: 当前 debootstrap 不支持 --exclude。安装后会拒绝禁用包。\n' >&2
  fi
  printf 'debootstrap --arch=arm64 --variant=minbase %s %s %s\n' "${suite}" "${rootfs}" "${url}"
  if ! debootstrap "${args[@]}" "${suite}" "${rootfs}" "${url}"; then
    if [[ ${suite} == resolute ]]; then
      die "debootstrap resolute 失败。确认源之后仍失败时，才用 SUITE=noble 过渡。不要默认降级。"
    fi
    die "debootstrap ${suite} 失败"
  fi
  mkdir -p "${rootfs}/usr/sbin" "${rootfs}/usr/bin"
  printf '#!/bin/sh\nexit 101\n' > "${rootfs}/usr/sbin/policy-rc.d"
  chmod 755 "${rootfs}/usr/sbin/policy-rc.d"
  if [[ $(uname -m) != aarch64 && $(uname -m) != arm64 ]]; then
    if [[ ! -x /usr/bin/qemu-aarch64-static ]]; then
      die "主机不是 arm64。请安装 qemu-user-static（提供 qemu-aarch64-static）后再跑 second-stage。"
    fi
    install -m 0755 /usr/bin/qemu-aarch64-static "${rootfs}/usr/bin/qemu-aarch64-static"
    QEMU_COPIED=1
  fi
  mount_target "${rootfs}"
  copy_resolv_conf "${rootfs}"
  if ! chroot "${rootfs}" /debootstrap/debootstrap --second-stage; then
    if [[ ${suite} == resolute ]]; then
      die "debootstrap second-stage 失败。确认源之后仍失败时，才用 SUITE=noble 过渡。不要默认降级。"
    fi
    die "debootstrap second-stage 失败"
  fi
  write_sources "${rootfs}" "${url}" "${suite}"
  write_pin "${rootfs}"
  if ! chroot "${rootfs}" apt-get update; then
    if [[ ${suite} == resolute ]]; then
      die "apt-get update 失败。确认是 Resolute 源故障后，才用 SUITE=noble 过渡。不要默认降级。"
    fi
    die "apt-get update 失败"
  fi
  hold_kernel_packages "${rootfs}"
  write_fstab "${rootfs}"
  write_netplan "${rootfs}"
  write_hostname "${rootfs}"
  configure_locale_tz "${rootfs}"
  enable_services "${rootfs}"
  use_resolved_stub "${rootfs}"
  rm -f "${rootfs}/usr/sbin/policy-rc.d"
  check_os_release "${rootfs}/etc/os-release"
  assert_fstab "${rootfs}"
  assert_netplan "${rootfs}"
  assert_pin_file "${rootfs}"
  reject_forbidden_packages "${rootfs}"
  [[ $(tr -d '[:space:]' < "${rootfs}/etc/hostname") == nanopi-neo3-plus ]] || \
    die "hostname 必须是 nanopi-neo3-plus"
  [[ -f ${rootfs}/etc/localtime ]] || die "未设置 Asia/Shanghai"
  grep -q 'Asia/Shanghai' "${rootfs}/etc/timezone" || die "timezone 必须是 Asia/Shanghai"
  grep -q '^LANG=en_US.UTF-8$' "${rootfs}/etc/default/locale" || die "locale 必须是 en_US.UTF-8"
  release_target_mounts "${rootfs}"
  printf 'suite=%s\n' "${suite}" > "${rootfs}/etc/nanopi-neo3-plus-rootfs"
}

main() {
  local SUITE=${SUITE:-resolute}
  local MIRROR=${MIRROR:-aliyun}
  local ROOTFS=out/resolute-rootfs
  local PACK=0
  local PACK_OUT=out/resolute-rootfs.img
  local KERNEL_RELEASE=${KERNEL_RELEASE:-}
  local MIRROR_URL=""
  local deb_ver=""
  MOUNTED=0
  QEMU_COPIED=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --out)
        need_arg "$@"
        ROOTFS=$2
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
      --kernel-release)
        need_arg "$@"
        KERNEL_RELEASE=$2
        shift 2
        ;;
      --pack-img)
        PACK=1
        if [[ $# -ge 2 && -n ${2:-} && ${2} != --* ]]; then
          PACK_OUT=$2
          shift 2
        else
          shift
        fi
        ;;
      *)
        die "无法识别的参数: $1（用 --help 查看）"
        ;;
    esac
  done

  ROOTFS=${ROOTFS%/}
  PACK_OUT=${PACK_OUT%/}
  validate_suite "${SUITE}"
  MIRROR_URL=$(resolve_mirror "${MIRROR}")
  validate_mirror_url "${MIRROR_URL}"
  if [[ ${PACK} -eq 1 ]]; then
    validate_kernel_release_token "${KERNEL_RELEASE}"
  fi

  if [[ ${EUID} -ne 0 ]]; then
    die "请用 root 执行: sudo ./scripts/build-resolute-rootfs.sh"
  fi

  TARGET=${ROOTFS}
  cleanup() {
    local status=$?
    trap - EXIT
    if [[ ${QEMU_COPIED} == 1 && -n ${TARGET} ]]; then
      rm -f "${TARGET}/usr/bin/qemu-aarch64-static"
    fi
    if [[ -n ${TARGET} ]]; then
      umount_target "${TARGET}" || true
    fi
    exit "${status}"
  }
  trap cleanup EXIT

  if [[ ${SUITE} == noble ]]; then
    printf 'SUITE=noble：只在 Resolute 镜像源故障时作过渡。os-release 应为 24.04/noble。\n' >&2
  fi

  command -v debootstrap >/dev/null 2>&1 || die "缺少 debootstrap。DW-MiBook 上应为 1.0.134ubuntu2。"
  deb_ver=$(debootstrap --version 2>&1 || true)
  if [[ ${deb_ver} != *1.0.134ubuntu2* ]]; then
    printf 'warning: 预期 DW-MiBook 的 debootstrap 1.0.134ubuntu2，当前: %s\n' "${deb_ver}" >&2
  fi
  suite_script_ready "${SUITE}"

  mkdir -p "$(dirname "${ROOTFS}")"
  if [[ -e ${ROOTFS} ]]; then
    if [[ -d ${ROOTFS} ]] && rootfs_is_configured "${ROOTFS}"; then
      check_os_release "${ROOTFS}/etc/os-release"
      assert_fstab "${ROOTFS}"
      assert_netplan "${ROOTFS}"
      if [[ ${PACK} -eq 0 ]]; then
        die "目录已配置: ${ROOTFS}。主路径不覆盖。交接: sudo ./scripts/build-image.sh --rootfs ${ROOTFS}"
      fi
      printf '使用已有 rootfs 目录打包: %s\n' "${ROOTFS}"
    elif [[ -d ${ROOTFS} ]] && [[ -z $(ls -A "${ROOTFS}") ]]; then
      run_debootstrap "${ROOTFS}" "${SUITE}" "${MIRROR_URL}"
    elif [[ -e ${ROOTFS} ]]; then
      die "目录已存在且不是配置完成的 rootfs，请移走后重跑: ${ROOTFS}"
    fi
  else
    run_debootstrap "${ROOTFS}" "${SUITE}" "${MIRROR_URL}"
  fi

  if [[ ${PACK} -eq 1 ]]; then
    pack_ext4 "${ROOTFS}" "${PACK_OUT}" "${KERNEL_RELEASE}"
  fi
  print_handoff "${ROOTFS}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
