# X453MA kernel configuration

A minimal-but-practical kernel configuration for the **ASUS X453MA**, maintained
as a config delta over upstream `x86_64_defconfig`.

It contains no source patches. `patches/README.md` explains why, and documents
the four genuine firmware defects the kernel reports on this board.

---

## 1. Supported hardware

Everything below was read off a working system with `lscpu`, `lspci -nnk`,
`/sys/bus/dmi/id/*`, `/sys/bus/acpi/devices/*` and `journalctl -b -k`.

| | |
|---|---|
| Board | ASUSTeK X453MA, BIOS `X453MA.209` (2014-07-09), AMI |
| CPU | Celeron N2840 @ 2.16 GHz — family 6, model 0x37, stepping 8, microcode 0x838 |
| Microarchitecture | Silvermont cores in a Braswell SoC (ACPI LPIT `VLV2`) |
| RAM | 4 GiB, 1 of 2 SODIMM slots populated (3.7 GiB usable) |
| Storage | SATA SSD `PH6-CE120-L1`, 112 GiB, non-rotational |
| GPU | `8086:0f31` Intel HD Graphics; i915 reports *"valleyview ... version 7.00"* (Gen7) |
| Wi-Fi | `168c:0032` Qualcomm Atheros **AR9485** → `ath9k` |
| Ethernet | `10ec:8136` Realtek **RTL8402** 10/100 → `r8169` |
| Audio | `8086:0f04` Intel HDA + Realtek ALC269 codec |
| USB | `8086:0f35` xHCI — the only USB controller on the board |
| Card reader | `10ec:5286` Realtek RTS5286 (PCI) → `rtsx_pci` |
| Filesystems | root: btrfs on `/dev/sda2` (subvol `@`); ESP: vfat `/dev/sda1` → `/boot` |
| Boot | UEFI (GPT ESP + systemd-boot); BIOS/CSM also supported |

### Notes on the platform

**Silvermont vs. Braswell.** These name different things and both are correct.
Silvermont is the CPU microarchitecture; Braswell is the SoC codename, confirmed
by the `VLV2` LPIT and the `8086:0f*` PCI IDs. The N2840 is a Braswell part
built from Silvermont cores. Bay Trail is also Silvermont. Gemini Lake would be
Goldmont with different PCI IDs — this platform is not that.

**Only one USB controller exists.** `lspci` shows just the xHCI. The Braswell
xHCI enumerates the USB 1.1/2.0 ports directly, which is why every USB device
logs as `high-speed USB device ... using xhci_hcd`. EHCI/OHCI/UHCI can be
disabled with no loss.

**The root filesystem is btrfs, not ext4.** A kernel without `CONFIG_BTRFS_FS`
will not boot this installation. ext4 is enabled regardless, because other
distributions on this machine and most rescue media expect it.

**The pre-existing tree `.config` was unusable.** A hand-edited configuration
was found in the source tree with btrfs and ext4 disabled (unbootable) and with
`CONFIG_WIRELESS_EXT` set — a prompt-less Kconfig symbol that cannot be set from
a config file at all. It has been replaced by the layout described below.

---

## 2. How the configuration is expressed

`config/x453ma.fragment` is the authoritative artifact. It is a **delta** applied
on top of upstream `x86_64_defconfig`:

```sh
make O=build defconfig
scripts/kconfig/merge_config.sh -m -O build build/.config \
    config/x453ma.fragment config/build-speed.fragment
make O=build olddefconfig
```

`config/x453ma.config` is the fully resolved result, kept as a snapshot and for
reference. It is regenerated rather than edited — see §3 for why that
distinction matters.

### Why not a checked-in `.config`

A 7000-line `.config` full of `CONFIG_FOO=y` lines rots silently. Symbol names
get renamed, dependencies change, and the file keeps "working" while quietly
dropping drivers — the classic symptom being a config that still parses but has
lost the driver that carries your root filesystem. A delta against a maintained
upstream base config cannot drift that way: anything unmentioned follows
`x86_64_defconfig` by construction.

### Why not `make localmodconfig`

`localmodconfig` derives its output from the modules currently loaded. It is
unreproducible, it differs every time it is run, and it drops anything needed
only on a cold path — SD card reader, fallback NIC, boot menu, rescue media.

---

## 3. Verifying and rebasing

Kernel symbol names drift between releases. In the 7.2 tree alone:

| Symbol | Reality |
|---|---|
| `RETPOLINE` | renamed `MITIGATION_RETPOLINE` |
| `BTRFS_FS_XATTR`, `BTRFS_FS_ZSTD` | no longer exist (unconditional now) |
| `X86_5LEVEL` | removed |
| `WLAN_VENDOR_ATH9K` | is `WLAN_VENDOR_ATH` |
| `MOUSEPS2` | is `MOUSE_PS2` |
| `SENSORS_AT24` | is `EEPROM_AT24` |
| `WIRELESS_EXT` | prompt-less `bool`; unsettable from a config file |
| `VIDEO_DEV` | unreachable while `MEDIA_SUPPORT_FILTER=y` (the default) |
| `GPIOLIB` | off in `x86_64_defconfig`; nothing selects it, so `RFKILL_GPIO` vanishes with it |

These are silent failures, so treat them as such. Two live examples from
developing this file:

- Disabling the `NET_VENDOR_REALTEK` menu while requesting `R8169=y` removes wired
  Ethernet, because `r8169` lives under that menu. Vendor menus must stay enabled
  whenever a driver from them is required.
- `CONFIG_VIDEO_DEV=y` is ignored without `# CONFIG_MEDIA_SUPPORT_FILTER is not
  set`, because with the filter enabled the whole `Media core support` menu is
  absent from the Kconfig database. See §9.4.

`scripts/verify-config.sh` catches both classes of failure:

```sh
scripts/verify-config.sh                                       # this tree
CONFIG_LINUX_DIR=/path/to/new/linux scripts/verify-config.sh   # another tree
```

It merges the fragment, resolves it, and diffs what was requested against what
Kconfig produced. Conflicts and unexpected absences exit non-zero. Absences that
are expected (parent menu off, dependency-gated) are listed in
`EXPECTED_ABSENT` inside the script and should be extended deliberately.

**Rebasing is then just:**

```sh
tar -xf linux-<new>.tar.xz
CONFIG_LINUX_DIR=$PWD/linux-<new> scripts/verify-config.sh
SRC=$PWD/linux-<new> scripts/x453ma-kernel.sh both
```

Nothing else carries over. There is no series to forward-apply, which is the
main practical benefit of the fragment layout.

---

## 4. What is enabled

Built-in (`=y`) rather than modular, because these are on the boot path or are
the only driver for their device:

- `DRM_I915` — the only GPU, and the framebuffer console. Gen7 requires no
  GuC/HuC firmware, so no firmware blob is involved at all.
- `ATH9K`, `ATH9K_PCI` — no firmware blob required (unlike `ath9k_htc`).
- `SATA_AHCI` — carries the root filesystem.
- `USB_XHCI_HCD`, `USB_XHCI_PCI` — the only USB controller.
- `ASUS_WMI`, `ASUS_NB_WMI`, `ASUS_WIRELESS` — the wireless radio switch
  (`ATK4001`), the WMI/ATK hotkeys, and the fan (`hwmon fan1_input`, `pwm1`).
  This board uses the older ATK/DSTS interface; the driver reports
  `Detected ATK, not ASUSWMI, use DSTS` at boot. The ACPI interpreter must stay
  fully enabled: the fan and the lid/wireless controls are reached through ACPI
  methods.
- `SND_HDA_INTEL` with `SND_HDA_CODEC_REALTEK` and `SND_HDA_CODEC_ALC269`.
- `BTRFS_FS` (root), `EXT4_FS` (other distros and rescue media), `VFAT_FS` (ESP).
- `INTEL_SOC_DTS_THERMAL` — not optional: i915 consumes the SoC DTS for its GT
  temperature limits. Provides `soc_dts0` / `soc_dts1`.
- `X86_PKG_TEMP_THERMAL` / `SENSORS_CORETEMP`, `ACPI_THERMAL`,
  `INTEL_POWERCLAMP`, `INTEL_IDLE`, `CPU_IDLE` with the menu governor.
- `FB_EFI` and `FB_VESA` alongside `DRM_FBDEV_EMULATION`. Roughly 50 KB, and the
  difference between boot messages and a black screen when i915's fbdev
  emulation is not the primary device.
- `MOUSE_PS2_FOCALTECH`, whose upstream help text is *"Say Y here if you have a
  FocalTech PS/2 TouchPad connected to your system"* — that is the touchpad here.
- `MOUSE_PS2`, `I2C_HID`, `HID_MULTITOUCH`, `I2C_I801`, `SPI_INTEL_PCI`,
  `SPI_INTEL_PLATFORM`, `PWM_LPSS`, `EEPROM_AT24`, `GPIOLIB`.
- `EFI`, `EFI_STUB`, `EFI_MIXED`, `EFI_PARTITION` and `RD_GZIP`/`RD_ZSTD`/
  `RD_LZ4`/`RD_XZ`.

Modular (`=m`), real hardware but off the boot path: the SDHC controller the DSDT
still describes (`\_SB_.SDHA`), the Braswell PMIC and ACPI PMC, `USB_SERIAL*`,
`FUSE_FS`, `UDF_FS`, `EEPROM_AT24`.

The fragment comments each setting inline with the evidence behind it.

---

## 5. What is disabled, and why

All entries are either provably absent from this platform or non-functional on
it.

| Family | Examples | Reason |
|---|---|---|
| Other GPUs | `AMDGPU`, `RADEON`, `NOUVEAU`, `VIRTIO_GPU`, `VBOXVIDEO`, `BOCHS`, `CIRRUS`, `QXL`, `SIS`, `VIA` | only Intel HD Graphics `0f31` is on the PCI bus |
| Other wireless vendors | 16 `WLAN_VENDOR_*` menus, `ATH5K`, `ATH9K_HTC`, `CARL9170`, `MT7601U`, `RT2X00`, `ZD1211RW` | the only radio is the AR9485; `ATH9K_HTC` is the USB variant |
| ath9k debug | `ATH9K_DEBUGFS`, `ATH9K_COMMON_DEBUG`, `ATH9K_DFS_DEBUGFS`, `ATH9K_COMMON_SPECTRAL`, `ATH9K_STATION_STATISTICS`, `ATH9K_BTCOEX_SUPPORT` | pure diagnostics |
| Other USB HCDs | `USB_EHCI_HCD`, `USB_OHCI_HCD`, `USB_UHCI_HCD` | only `8086:0f35` exists; xHCI runs USB1/USB2 |
| PATA / legacy IDE | `ATA_PIIX`, `ATA_GENERIC` | no PATA controller in `lspci`; the DVD-RAM is a USB-SATA bridge bound as SCSI `sr0` |
| Intel MEI | `INTEL_MEI` (+ `INTEL_MEI_TXE`, `mei_hdcp`) | device at `00:1a.0` has no ACPI interrupt routing, and nothing on this platform uses MEI — see `patches/README.md` §1 |
| Virtualisation | `KVM`, `HYPERV`, `XEN` | 4 GiB RAM, no hypervisor use case |
| Other Ethernet | `8139CP`, `8139TOO`, `NE2K_PCI`, `VIA_RHINE`, `INTEL`/`BROADCOM`/`MELLANOX`/`MARVELL`/`QLOGIC` vendor menus | only the RTL8402 is fitted |
| Fabric / SAN / cluster | `INFINIBAND`, `ISCSI_TCP`, `MD`, `CEPH_FS`, `OCFS2_FS`, `GFS2_FS`, `NILFS2_FS`, `UBIFS_FS`, `EROFS_FS`, `NFS_FS`, `CIFS` | absent hardware |
| Absent sound | `SND_USB_AUDIO`, `SND_PCM_OSS` | no such hardware |
| Debug outputs | `DEBUG_DRIVER`, `I2C_DEBUG_CORE`, `SPI_DEBUG`, `REGULATOR_DEBUG` | diagnostics |

> `WLAN_VENDOR_REALTEK` here is the *wireless* vendor, unrelated to
> `NET_VENDOR_REALTEK` (Ethernet), which must stay enabled because `r8169` is
> under it.

### Deliberately left at upstream defaults

Preemption model and scheduler, `HZ`, RCU, `NO_HZ`, the Spectre/MDS/IBPB
mitigations, LSMs/audit/IMA/EVM, generic netfilter and conntrack, and core MM /
VFS infrastructure. Changing these trades correctness or robustness for very
little size. Weakening CPU mitigations for speed on a laptop that gets used
daily is a bad trade, and none of it buys meaningful space.

---

## 6. Firmware and NVRAM

Two constraints shape this: firmware-variable writes on this board have a
history of causing trouble, and the boot mode must not be hard-coded.

**The kernel writes no UEFI variables.** It does so only if userspace requests
it through `efivarfs`, or via the `efivars` pstore backend, whose sole purpose
is to write a variable on kernel panic. `EFI_VARS_PSTORE` defaults to `=y`
whenever `PSTORE=y`, so the fragment sets:

```
# CONFIG_PSTORE is not set
# CONFIG_EFI_VARS_PSTORE is not set
```

With `PSTORE=n`, `EFI_VARS_PSTORE` cannot be built and the kernel has no code
path that writes a variable. If kernel crash dumps are wanted and that risk is
acceptable, the upstream knob is:

```
CONFIG_PSTORE=m
CONFIG_EFI_VARS_PSTORE=m
CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y   # off unless enabled at runtime
```

**UEFI support is retained in full** — `EFI`, `EFI_STUB`, `EFI_MIXED`,
`EFI_PARTITION`, `VFAT_FS`. Differences between distributions in UEFI
behaviour belong to bootloaders, installer EFI binaries and firmware, not to
the kernel, so no assumption about *how* the system boots is encoded in the
configuration. `EFI_STUB` serves both paths: a UEFI bootloader consumes it
directly, and a BIOS/CSM bootloader loads the kernel normally.

This machine already carries five EFI boot entries (`Linux Boot Manager`,
`Fallback`, `UEFI OS`, plus CD/DVD and network BBS entries), so NVRAM is not
unwritten territory.

---

## 7. Build and install (Arch Linux)

Requires `base-devel`, `bc`, `flex`, `bison`, `openssl`, `libelf`, `zstd`,
`cpio`, `mkinitcpio`.

```sh
tar -xf linux-<ver>.tar.xz                 # pristine tree next to this directory
cd linux-<ver> && make mrproper && cd ..

scripts/x453ma-kernel.sh config            # defconfig + fragments + olddefconfig
scripts/x453ma-kernel.sh build             # bzImage + modules, out-of-tree
sudo scripts/x453ma-kernel.sh install
sudo scripts/x453ma-kernel.sh both         # both steps

scripts/x453ma-kernel.sh info              # paths, jobs, swap, ccache, boot mode
scripts/x453ma-kernel.sh verify            # re-run the config verification
```

Out-of-tree builds require a clean source tree. The script detects a dirty one
and explains how to clean it rather than running `mrproper` unprompted.

`install` writes `/boot/vmlinuz-x453ma`, installs modules to
`/usr/lib/modules/<release>/`, writes an mkinitcpio preset at
`/etc/mkinitcpio.d/x453ma.preset` (mirroring Arch's stock `linux.preset`) and
runs `mkinitcpio -p x453ma`.

**NVRAM policy in the install step.** Only `bootctl update` is run, and only if
systemd-boot is already installed. `update` refreshes the loader binary on the
ESP; `install` is the operation that creates a `Boot####` NVRAM entry, and it is
never invoked. `efibootmgr` is never invoked either. Boot entries stay an
explicit manual action; the script prints the `loader.conf` stanza to paste.

```
# /boot/loader/loader.conf
title   Arch Linux (x453ma)
linux   /vmlinuz-x453ma
initrd  /initramfs-x453ma.img
options root=PARTUUID=<root-partuuid> rootflags=subvol=@ rw rootfstype=btrfs
```

Keep an existing stock entry as a fallback. Obtain the real `PARTUUID` with
`findmnt -no PARTUUID /`.

Additional fragments can be appended without editing the tracked ones:

```sh
KERNEL_FRAGMENT=/path/to/mine.fragment scripts/x453ma-kernel.sh config
```

---

## 8. Build time

A clean build on this machine (2 cores, 4 GiB, SATA SSD) takes hours. Where the
time goes, and what can be done about it:

| Cost | Mitigation |
|---|---|
| ~25–30k objects rebuilt from scratch | not addressable by config or patch |
| Rebuilds after a config tweak | **ccache** — by far the largest win |
| Driver/module count | already trimmed here (173 modules) |
| objtool/ORC on every object | `config/build-speed.fragment` |
| ftrace instrumentation | `config/build-speed.fragment` (also sidesteps a build failure) |
| `WERROR` fragility with GCC 16 | `config/build-speed.fragment` |

### ccache

```sh
sudo pacman -S ccache
```

`scripts/x453ma-kernel.sh` detects it and sets `CCACHE_BASEDIR` so hits survive
re-extracting the tree under a new kernel version. The first build is
unaffected; subsequent builds recompile only what changed, which is the
difference between hours and minutes when iterating on the configuration.

### `config/build-speed.fragment`

Optional, merged automatically when present:

- `CONFIG_FTRACE=n` — also **works around the `-mfentry` build failure** in
  §9.7. Does not affect the Spectre/MDS/IBPB mitigations, which are a separate
  mechanism and remain enabled.
- `CONFIG_UNWINDER_FRAME_POINTER=y` in place of `CONFIG_UNWINDER_ORC=y` — skips
  an objtool pass over essentially every object. The only setting here with a
  runtime cost: slightly slower, marginally less detailed crash backtraces.
  Delete that stanza to keep ORC.
- `CONFIG_WERROR=n` — a new compiler warning should not become a failed build.

### Jobs and memory

`JOBS` defaults to `nproc` and is capped at 4. Do not raise it much further:
4 GiB with ~1.9 GiB swap, and the vmlinux link is the memory peak.

### What not to do

**LTO.** The conventional answer to "make the kernel smaller" is exactly wrong
here: it makes the *build* substantially slower, and its link stage will thrash
this machine's RAM and swap. The fast path (clang + ThinLTO) also requires
clang, which is not part of a default Arch install. `build-speed.fragment` pins
`LTO_NONE` and explains why.

Also avoid `make localmodconfig` (§2) and the `sleep`-in-the-Makefile build
hacks, which are band-aids over parallel-build races and make things slower
rather than faster.

---

## 9. Known issues and open questions

### 9.1 `mei_txe` interrupt routing

```
mei_txe 0000:00:1a.0: can't derive routing for PCI INT A
mei_txe 0000:00:1a.0: PCI INT A: not connected
```

The device at `00:1a.0` is claimed by `pci-txe.c`, which then asks ACPI for an
IRQ that this firmware's `_PRT` table does not provide. The message comes from
generic ACPI code and is accurate. MEI is disabled in the fragment; see
`patches/README.md` §1.

### 9.2 ACPI FADT length mismatch

`ACPI BIOS Warning (bug): 32/64X length mismatch in FADT/Gpe0Block: 128/32`.
`drivers/acpi/bus/tbfadt.c` detects and handles it. Cosmetic.

### 9.3 PCIe ASPM is firmware-controlled

The DSDT has no `_OSC` method for the PCI host bridge, so the kernel never
obtains PCIe feature ownership:

```
ACPI BIOS Error (bug): Could not resolve symbol [\_SB._OSC.CDW1], AE_NOT_FOUND
r8169 0000:03:00.2: can't disable ASPM; OS doesn't have ASPM control
```

There is no kernel-side change that grants ownership the firmware refuses to
give, and forcing policy silently is worse than the status quo. If it is worth
experimenting, do it from the bootloader:

```
options  … pcie_aspm=performance
```

Measure before and after with `powertop`. Forcing `performance` is expected to
*increase* draw on an S0ix platform like this one, but that is a prediction
rather than a measurement.

### 9.4 Webcam versus media subsystem size

The built-in webcam (`04f2:b483`, UVC) requires
`# CONFIG_MEDIA_SUPPORT_FILTER is not set`; with the filter enabled (the
upstream default) `VIDEO_DEV` is absent from the Kconfig database and
`CONFIG_VIDEO_DEV=y` is silently ignored. With the filter off, the media
category symbols become prompt-less and default to `y`, so analog TV, radio,
SDR, platform and test support are built in, along with ~36 tuner modules that
are never loaded. `CONFIG_MEDIA_SUBDRV_AUTOSELECT=n` trims three of those.

Keeping a working webcam was judged the better trade than saving a few hundred
kilobytes. To reverse it, remove the `MEDIA_*`, `VIDEO_DEV` and
`USB_VIDEO_CLASS` lines from §6 of the fragment. Verify either way with
`v4l2-ctl --list-devices`.

### 9.5 Bluetooth

`BCM2E1A` is described at `\_SB_.URT1.BTH0` on the internal LPSS UART1 and the
ACPI device reports present and enabled (`_STA = 0x15`), but no adapter
enumerates: `/sys/class/bluetooth/` is empty and only one `rfkill` entry exists.
`8250_lpss` is not built in the currently running kernel, so nothing binds to
`8086:0f0a`, and `btintel` is the wrong vendor — upstream's `hci_bcm.c` is what
matches `"BCM2E1A"`.

Bluetooth is therefore left out of the tracked configuration, because it does
not currently work and enabling it has not been shown to fix it. To test,
build with an additional fragment:

```
CONFIG_SERIAL_8250=m
CONFIG_SERIAL_8250_LPSS=m
CONFIG_BT=m
CONFIG_BT_BCM=m          # the driver that matches BCM2E1A
CONFIG_BT_HCIUART=m
```

Then check `dmesg | grep -iE '8250_lpss|hci|bt'` and whether the ASUS wireless
switch — which toggles Wi-Fi and Bluetooth together — releases the Bluetooth
half.

### 9.6 `regulatory.db` is missing

```
cfg80211: Direct firmware load for regulatory.db failed with error -2
```

This is a userspace issue, not a kernel one: Arch ships the file in the
`linux-firmware` package. Until it is present, Wi-Fi runs on the driver's
built-in world regulatory domain, which can restrict channels and transmit
power. Install `linux-firmware` and confirm with `iw reg get`.

### 9.7 Build not verified end to end

The configuration resolves on linux 7.2.7 with **219 settings honoured
verbatim, 0 conflicts and 0 unexpected absences**. A full compile has not been
run to completion, so "it builds" is unconfirmed. A build attempt failed early
during `make prepare`:

```
arch/x86/include/asm/ftrace.h:9: error: #error Compiler does not support fentry?
  from kernel/sched/rq-offsets.c:5
```

That is `CONFIG_FUNCTION_TRACER` defined while `CC_USING_FENTRY` is not:
`Makefile` only defines the latter when its `cc-option-yn -mfentry` probe
succeeds. Whether the probe failure is specific to this configuration or
pre-existing in this tree has not been established — it occurs on a scheduler
offsets file, driven by `CONFIG_FTRACE`. Reproduce and compare:

```sh
make -C <clean-tree> O=build prepare V=1 2>&1 | grep -i mfentry
```

If it also fails with Arch's stock configuration, ignore it. If not,
`CONFIG_FTRACE=n` in `build-speed.fragment` is a one-line workaround; losing
ftrace costs this platform nothing.

Once built, compare the boot log's `Memory:` line against the stock kernel's
`22213K kernel code` to see the real saving. On a 4 GiB machine it will be
smaller than expected — the benefits here are fewer load-time dependencies and
less to go wrong, not reclaimed RAM.

### 9.8 Unbound peripherals

Present in the DSDT with no driver bound. None is currently functional, and
enabling any of them is a feature request rather than a configuration change:

- `AUTH2750` fingerprint sensor (`\_SB_.SPI1.FPNT`)
- `BCM4752` GNSS (`\_SB_.URT2.GPS0`)
- several I2C touch controllers — `MSFT0002` `TPD1`, `NXP5441` `NFC1`,
  Atmel `ATML1000`, `MXT3432`, `SIS0817` — none of which is the active pointer
  device; that is the FocalTech PS/2 touchpad
- `SMO91D0` Intel ISH sensor hub

### 9.9 Suspend states

`/sys/power/mem_sleep` reports `freeze mem disk s2idle [deep]` — there is no
`s3`. Suspend-to-RAM is not offered by this firmware, which is a BIOS matter
rather than a kernel one. `deep` (s2idle with stricter wakeup constraints) is
available.

### 9.10 USB DVD-RAM

The external MATSHITA UJ8FBS behind a USB-SATA bridge intermittently fails to
enumerate on one port:

```
usb 1-1.3: Cannot enable. Maybe the USB cable is bad?
usb 1-1.3: device not accepting address 7, error -71
```

`-71` is `EPROTO`. Other devices on the same hub work, and the drive does bind
as `sr0`. This points at power, cable or enclosure signalling rather than a
kernel defect — the kernel is retrying and reporting correctly.

---

## 10. Files

| Path | Purpose |
|---|---|
| `config/x453ma.fragment` | authoritative config delta over `x86_64_defconfig` |
| `config/build-speed.fragment` | optional: faster builds, sidesteps the fentry failure |
| `config/x453ma.config` | resolved snapshot; regenerate, do not hand-edit |
| `patches/README.md` | why the patchset is empty — hardware defects and build speed |
| `scripts/x453ma-kernel.sh` | `config` / `build` / `install` / `both` / `verify` / `info` |
| `scripts/verify-config.sh` | prove the fragments still resolve on a given tree |