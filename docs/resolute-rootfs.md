# Resolute rootfs

Ubuntu 26.04 Resolute 的 rootfs 由 [`scripts/build-resolute-rootfs.sh`](../scripts/build-resolute-rootfs.sh) 在 DW-MiBook 上做。产品路径仍是 [ADR-0001](adr/0001-userland-resolute-debootstrap.md)。打包入口仍是 [`scripts/build-image.sh`](../scripts/build-image.sh)，分区与卷标见 [`scripts/partition-layout.md`](../scripts/partition-layout.md)。

主产物是一个目录。镜像打包消费它：

```bash
sudo ./scripts/build-image.sh --rootfs <目录>
```

其它必选参数见 `scripts/build-image.sh --help`。当前该脚本校验后退出码 2，还不生成 `.img`。

## DW-MiBook 前提

重活只在 DW-MiBook 上跑。跑 Resolute 之前：

- debootstrap 是 `1.0.134ubuntu2`
- `apt` / `apt-get` 免密（本脚本用 root 或免密 `sudo -n`）
- 执行：

```bash
sudo ln -sf gutsy /usr/share/debootstrap/scripts/resolute
```

主机若没有 `resolute` 脚本，这行 `ln -sf` 是规定修法。系统路径仍缺失时，脚本会再用私有 `DEBOOTSTRAP_DIR` 把 `resolute` 链到 `gutsy`，帮助文本里同样写着上面的 `ln -sf`。

x86_64 构建主机必须已安装 `qemu-user-static`（`/usr/bin/qemu-aarch64-static` 且 binfmt 已注册），否则脚本直接报错退出。arm64 主机不需要 qemu。

## 怎么跑

在仓库根目录：

```bash
sudo ./scripts/build-resolute-rootfs.sh
sudo ./scripts/build-resolute-rootfs.sh --mirror tuna
sudo ./scripts/build-resolute-rootfs.sh --mirror official
```

- 默认 `SUITE=resolute`，默认镜像是阿里云 ubuntu-ports（`MIRROR=aliyun`）。
- `MIRROR=tuna` 是清华 ubuntu-ports，`MIRROR=official` 是 `ports.ubuntu.com`。脚本拒绝 amd64 的 `archive.ubuntu.com`。
- Resolute 源失败时，同一脚本允许过渡：`SUITE=noble`（或 `--suite noble`）。产品发布仍是 26.04 Resolute，noble 只是过渡 rootfs。内核仍然是厂商 6.1，不要装 noble 的 generic。

默认目录是 `out/rootfs-resolute`（noble 时为 `out/rootfs-noble`）。

可选 raw ext4（不是主产物）：

```bash
sudo ./scripts/build-resolute-rootfs.sh --rootfs-img out/rootfs.img
```

该文件是卷标 `rootfs` 的 raw ext4，用 `fallocate` 或 `dd if=/dev/zero` 完整分配。脚本不强制稀疏文件，也不生成 android sparse。`build-image.sh` 的 `simg2img` 只用于调用者另行传入的 android-sparse `.img`；本脚本不产那种文件。

本脚本不 `dd` 到盘，不打开 `/dev/mmcblk*`，不碰 eMMC。第一张卡用备用 SD，等 `build-image.sh` 写出镜像后再写入。

## rootfs 里写死的配置

- `/etc/fstab` 根行是 `LABEL=rootfs`。不要改成 `/dev/mmcblk*`。
- netplan：`renderer: networkd`，`eth0` DHCP。注释里说明网卡名可能是 `end0`（以板上 `ip link` 为准），并给出 `match: name` 例子。
- 源：`$SUITE`、`$SUITE-updates`、`$SUITE-security`，都在 ubuntu-ports。
- `en_US.UTF-8`，时区 `Asia/Shanghai`，主机名 `nanopi-neo3-plus`。
- enable：`ssh`、`systemd-networkd`、`systemd-resolved`。
- 不装 Desktop、snapd、NetworkManager、cloud-init，也不装 `linux-image-generic` / `linux-generic` / `linux-headers-generic`（Resolute generic 是 7.0）。`apt-mark hold`，并且 `/etc/apt/preferences.d/no-official-kernel` 里 `Pin-Priority: -1`。
- 包集至少包括：systemd、systemd-sysv、udev、dbus、apt-utils、sudo、openssh-server、netplan.io、systemd-resolved、ca-certificates、locales、tzdata、kmod、initramfs-tools、iproute2、iputils-ping，以及 ubuntu-keyring、adduser、procps、ethtool、e2fsprogs。`debootstrap --arch=arm64 --variant=minbase`。initramfs 保持 initramfs-tools，不换 Dracut。

## carry.tgz

模块不在 debootstrap 里。从**已经用这份 `kernel.img` 启动的 Noble 板**上提取，目录名必须是完整的 `uname -r`，不能只对 `6.1` 前缀。

在那块板上：

```bash
KVER=$(uname -r)
ko=$(find "/lib/modules/${KVER}" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print -quit)
test -n "${ko}"
test "$(modinfo -F vermagic "${ko}" | awk 'NR==1 { print $1 }')" = "${KVER}"
```

`modinfo -F vermagic` 的第一字段必须等于 `uname -r`。Resolute rootfs 里的目录就是 `/lib/modules/$KVER`。

打进 `carry.tgz` 的内容：

- `/lib/modules/$KVER`（完整版本字符串，与上面的 `uname -r` 相同）
- firmware（`/lib/firmware`；usr-merge 时与 `/usr/lib/firmware` 是同一目录）
- fstab：可以带上板上的其它行，但**不要**用 `/dev/mmcblk*` 换掉根行 `LABEL=rootfs`。脚本解包后若发现根行不是 `LABEL=rootfs`，会改回这一行并警告
- SSH host key：`/etc/ssh/ssh_host_*`（解包发生在安装 openssh 之后，用来盖住新生成的 key）
- 登录用户的 `~/.ssh/authorized_keys`（模式保持 `0700` / `0600`）
- udev 规则：`/etc/udev/rules.d`
- modprobe 配置：`/etc/modprobe.d`
- FriendlyELEC 自定义脚本：按板上实际路径原样带上（启动时会调用的那些），不要漏

`carry.tgz`、镜像和密钥不要提交进 git。

```bash
sudo ./scripts/build-resolute-rootfs.sh --carry /path/carry.tgz --kver "${KVER}"
```

`--kver` 与 `/lib/modules` 下的目录名必须全字符串一致。多个目录且没有 `--kver` 时脚本失败。

## 板上验收

先写备用 SD。本脚本不 dd，也不刷 eMMC。

- [ ] `uname -r` 仍是 6.1，等于 `/lib/modules` 下的目录名，并且就是写入的那份 `kernel.img`（Noble 板上 vermagic 第一字段已核对为同一字符串）
- [ ] `/etc/os-release` 为 Ubuntu 26.04 / resolute。若这次是 `SUITE=noble`，则为 24.04 / noble
- [ ] SSH 可登录
- [ ] 千兆网口可用
- [ ] 厂商模块在
- [ ] 没有官方 7.0（没有 `linux-image-generic`，也没有 `linux-image-7.*`）
- [ ] 串口 1500000 8N1，能看到启动日志
- [ ] `findmnt --fstab /` 的 SOURCE 是 `LABEL=rootfs`
- [ ] 断电后能从这张备用 SD 冷启动

## 风险

`/lib/modules` 的目录名必须和 `kernel.img` 的完整版本字符串一致。只对上 `6.1` 前缀时，内核能起来但模块对不上。核对点是 Noble 板上的 `uname -r` 与 `modinfo -F vermagic` 第一字段，不是镜像文件名里的 `6.1`。
