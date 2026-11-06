# Resolute rootfs

主路径是目录，不是磁盘镜像。在仓库根目录执行 [`scripts/build-resolute-rootfs.sh`](../scripts/build-resolute-rootfs.sh)，默认写出 `out/resolute-rootfs`。脚本结束时打印交接命令。把该目录交给本仓库的打包入口：

```bash
sudo ./scripts/build-image.sh --rootfs out/resolute-rootfs
```

`/etc/fstab` 的根行固定为：

```text
LABEL=rootfs  /  ext4 defaults,noatime,errors=remount-ro 0 1
```

不要写 `/dev/mmcblk*`。卷标与 [`scripts/partition-layout.md`](../scripts/partition-layout.md) 里 ext4 分区的 `rootfs` 一致。

本脚本不 `dd` 磁盘，不调用 `mk-emmc-image`。sd-fuse 不是出口。可启动 SD 仍由 `scripts/build-image.sh` 按 plain GPT 写出。

默认 `SUITE=resolute`。`SUITE=noble` 只在 Resolute 镜像源故障时作过渡，这时 `/etc/os-release` 必须是 24.04/noble。默认发布仍是 26.04/resolute。不要装 Desktop、snapd、NetworkManager（`network-manager`）、cloud-init，也不装 `linux-image-generic`、`linux-generic`、`linux-headers-generic`。脚本在 debootstrap 支持时传入 `--exclude`，并写入 Pin-Priority -1，再 `apt-mark hold`。Resolute 早期软件源若还没有这些 generic 内核元包，hold 可以跳过；pin 仍然生效。

debootstrap 使用 `--arch=arm64 --variant=minbase`。装上 systemd、systemd-sysv、udev、dbus、apt-utils、sudo、openssh-server、netplan.io、systemd-resolved、ca-certificates、locales、tzdata、kmod、initramfs-tools、iproute2、iputils-ping，以及 ubuntu-keyring、adduser、procps、ethtool、e2fsprogs。不装 `linux-image-*`。

软件源是同一条 ubuntu-ports 上的 `$SUITE`、`$SUITE-updates`、`$SUITE-security`。

| `MIRROR` | URL |
| --- | --- |
| `aliyun`（默认） | `https://mirrors.aliyun.com/ubuntu-ports` |
| `tuna` | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports` |
| `official` | `http://ports.ubuntu.com/ubuntu-ports` |

拒绝 `archive.ubuntu.com`。

locale 为 `en_US.UTF-8`，时区 `Asia/Shanghai`，主机名 `nanopi-neo3-plus`。启用 `ssh`、`systemd-networkd`、`systemd-resolved`。netplan 的 renderer 是 networkd，`eth0` 开 dhcp4，并注明板上的网卡名可能是 `end0`（`match name`，用 `ip link` 确认后再改）。

## DW-MiBook 前置

debootstrap、以及后面的 `build-image.sh`，只在所有者的 DW-MiBook 上跑。该机的 debootstrap 是 `1.0.134ubuntu2`，apt 免密（passwordless sudo apt）。不要在 MBA-M1-Fedora 或 Cursor 云端虚拟机上做这次 debootstrap。

Resolute 之前先补 suite 脚本（各 Ubuntu 代号通常链到 `gutsy`）：

```bash
sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute
```

主机不是 arm64 时，安装 `qemu-user-static`，使 `qemu-aarch64-static` 可用。脚本用它完成 second-stage，结束后从 rootfs 里删掉这个仿真器。

构建：

```bash
sudo ./scripts/build-resolute-rootfs.sh
```

源异常、且确认不是脚本错误时，才：

```bash
sudo SUITE=noble ./scripts/build-resolute-rootfs.sh
```

## carry.tgz 清单

模块和固件从 **正在运行即将打进镜像的那份 `kernel.img` 的 Noble 板** 上取。不要从构建机的 `uname -r` 取，也不要只拷一个 `6.1` 前缀目录。

在那块板上：

```bash
uname -r
ls -d /lib/modules/"$(uname -r)"
ko=$(find /lib/modules/"$(uname -r)" -type f -name '*.ko' | head -n 1)
modinfo -F vermagic "$ko"
```

`uname -r` 的完整字符串就是目录名。`modinfo -F vermagic` 的第一个字段必须等于这个字符串。记录这个字符串，后面 `--pack-img` 的 `KERNEL_RELEASE` 用它，不能写成 `6.1`。

打进新 rootfs（不要覆盖下面「不要带」的文件）：

- [ ] `/lib/modules/$(uname -r)/` 整树，目录名是完整版本字符串
- [ ] 这块板在用的厂商 firmware（`/lib/firmware` 里实际用到的）
- [ ] SSH host keys（`/etc/ssh/ssh_host_*`）
- [ ] 登录用户家目录里的 `~/.ssh/authorized_keys`。该用户要在新 rootfs 里存在（passwd/group/shadow 里对应的那几行和家目录），不要整份覆盖 `/etc/passwd`
- [ ] 板上已在用的 udev rules
- [ ] modprobe 配置（`/etc/modprobe.d`）
- [ ] 板上在用的 Friendly 脚本（路径以实机为准）

不要带，也不要覆盖：

- [ ] 不要用 `/dev/mmcblk*` 覆盖 `/etc/fstab`。根行保持 `LABEL=rootfs`
- [ ] 不要带 `/etc/os-release`
- [ ] 不要带 apt sources（`sources.list`、`sources.list.d`、preferences 里的 pin 留在新 rootfs）
- [ ] 不要带 snapd
- [ ] 不要带 cloud-init
- [ ] 不要带 NetworkManager

带完后核对：

```bash
test "$(basename out/resolute-rootfs/lib/modules/*)" = "<板上 uname -r 全字符串>"
```

`/lib/modules` 下只能有这一个目录。

## 验收

先写备用 SD，不写 eMMC。镜像由 `scripts/build-image.sh` 产出后再冷启动。断电再上电。

- [ ] 串口 1500000 8N1，能看到启动日志
- [ ] `uname -r` 是 6.1 系列，并且等于 `/lib/modules/$(uname -r)` 的目录名，并且等于打进卡里的那份 `kernel.img`
- [ ] `/etc/os-release` 为 26.04 / resolute（`SUITE=noble` 过渡卡则是 24.04 / noble，不作为默认发布）
- [ ] SSH 可登录
- [ ] 千兆网口可用
- [ ] 厂商模块在
- [ ] 没有官方 7.0 内核包。`linux-image-generic`、`linux-generic`、`linux-headers-generic` 的 Pin-Priority 为 -1，且 `apt-mark showhold` 含这三项
- [ ] `findmnt /` 的源是 `LABEL=rootfs`

## 可选 `--pack-img`

主路径不需要。目录交接给 `build-image.sh --rootfs` 即可，由打包脚本做 `mkfs.ext4 -b 4096 -L rootfs`。

只有在 carry 完成、且 `KERNEL_RELEASE` 与 rootfs 里唯一的 `/lib/modules/<目录>` 全名一致、vermagic 第一字段也一致时，才额外写出 raw ext4：

```bash
sudo KERNEL_RELEASE='<板上 uname -r 全字符串>' \
  ./scripts/build-resolute-rootfs.sh --pack-img
```

默认文件是 `out/resolute-rootfs.img`。分配用 `fallocate`，失败则 `dd if=/dev/zero` 写满，得到完整分配的普通文件。不是稀疏空洞文件，也不是 android sparse。卷标 `rootfs`，块大小 4096。不要对磁盘设备 `dd`。
