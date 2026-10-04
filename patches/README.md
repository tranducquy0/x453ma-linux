# Why there is no patchset

This directory is intentionally empty. The reasoning is recorded here so the
decision can be revisited rather than re-derived, and so the four real defects
found on this platform are documented somewhere other than a bug report.

Summary: every genuine anomaly is a firmware defect that the kernel already
reports correctly. In each case the right response is a configuration change or
no change at all, because patching would mean either hiding an accurate
diagnostic or overriding the platform silently.

---

## 1. `mei_txe 0000:00:1a.0: can't derive routing for PCI INT A`

```
mei_txe 0000:00:1a.0: can't derive routing for PCI INT A
mei_txe 0000:00:1a.0: PCI INT A: not connected
```

`8086:0f18` on this part is the Bay Trail/Braswell PMC, but `pci-txe.c` claims it
(`{PCI_VDEVICE(INTEL, 0x0F18)}, /* Baytrail */`) and then requests an IRQ. The
DSDT's `_PRT` table has no entry for the device, so
`acpi_pci_irq_find_prt_entry()` in `drivers/acpi/pci_irq.c` gives up and prints
the warning. The message originates in generic ACPI code and is accurate; it
would be printed for any device exhibiting this firmware defect.

It is not a MEI bug. Suppressing the warning, or guessing an IRQ, would hide a
real defect and invent a routing that does not exist. MEI is also unusable on
this platform regardless, and nothing in the kernel or a normal desktop
userspace depends on it: Gen7 i915 loads no GuC/HuC firmware and therefore does
not use MEI, and HDCP-over-MEI is irrelevant here.

Resolution: `# CONFIG_INTEL_MEI is not set`. The device is then left unclaimed,
which is the correct state.

## 2. `ACPI BIOS Warning (bug): 32/64X length mismatch in FADT/Gpe0Block: 128/32`

The firmware declares a 32-bit FADT but populates the 64-bit `Gpe0Block`
pointer and length fields. `drivers/acpi/bus/tbfadt.c` detects this, warns, and
continues with the 32-bit interpretation — which is precisely what that code
exists to do. Suppressing the warning would be a cosmetic change to core
behaviour with no functional benefit.

## 3. Missing `_OSC`, and the resulting `r8169` ASPM failure

```
ACPI: [Firmware Bug]: BIOS _OSI(Linux) query ignored
ACPI BIOS Error (bug): Could not resolve symbol [\_SB._OSC.CDW1], AE_NOT_FOUND
acpi PNP0A08:00: _OSC: platform retains control of PCIe features (AE_ERROR)
r8169 0000:03:00.2: can't disable ASPM; OS doesn't have ASPM control
```

The firmware provides no `_OSC` method for the PCI host bridge, so the kernel
never obtains ownership of PCIe features. The visible consequence is that
`r8169` cannot disable ASPM on the wired NIC.

No kernel-side change can grant ownership the firmware declines to give.
Patching `pcieport` to force an ASPM policy regardless would override the
platform silently and can strand the link in a low-power state it cannot exit.
The correct place to experiment is the bootloader
(`pcie_aspm=performance` / `powersup` via `loader.conf`), which is trivially
reversible. See README §9.3.

## 4. `asus_wmi` warnings on the ATK/DSTS interface

```
asus-nb-wmi asus-nb-wmi: Detected ATK, not ASUSWMI, use DSTS
asus_wmi: fan_curve_get_factory_default (0x00110024) failed: -19
asus_armoury: No matching power limits found for this system
```

The 2014 board exposes the older ASUS ATK/DSTS ACPI interface rather than
ASUSWMI. The modern WMI paths the driver probes first do not exist, so it
correctly falls back to DSTS. The two warnings are the driver reporting that
newer interfaces are absent. Fan control works — `hwmon` exposes `fan1_input` and
`pwm1`, both from `asus_wmi`.

## 5. USB DVD-RAM enumeration failure

```
usb 1-1.3: Cannot enable. Maybe the USB cable is bad?
usb 1-1.3: device not accepting address 7, error -71
```

The external MATSHITA UJ8FBS behind a USB-SATA bridge fails to enumerate on one
port while the flash disk, webcam and hub on the same hub work. `-71` is
`EPROTO`. The kernel retries, reports correctly, and the drive does eventually
bind as `sr0`. The evidence points at power, cable or enclosure signalling.

## 6. `regulatory.db` firmware load failure

```
cfg80211: Direct firmware load for regulatory.db failed with error -2
```

Not a kernel issue. The file ships in Arch's `linux-firmware` package. See
README §9.6.

---

## What would justify a patch

A patch for this platform is defensible in exactly two shapes:

1. **An in-tree-style quirk entry** for a device this board actually has — for
   example a `pci_device_id` plus a quirk flag — submitted upstream so it
   survives rebasing.
2. **A fix to a generic driver that is wrong for everyone**, not a special case
   for one device ID.

A patch phrased as "on Braswell, skip X" without a general argument is a red
flag. Send it upstream rather than carrying it locally.

---

# Why there is no build-speedup patchset either

The other obvious place to reach for patches, and also the wrong one. Almost
every kernel build-time "optimisation" that circulates in that form is either
configuration in disguise or an actual pessimisation.

## Where the time actually goes

The resolved configuration is already optimal on the largest single cost:

```
CONFIG_DEBUG_INFO_NONE=y      # no DWARF generated at all
CONFIG_DEBUG_INFO_BTF         # already absent; pahole never runs
CONFIG_LTO_NONE=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
```

`x86_64_defconfig` does not generate debug information, so there is nothing to
strip. `GCC_PLUGINS=y` looks concerning but has no sub-options enabled
(`LATENT_ENTROPY` is off) and costs nothing.

What remains is roughly 25–30k objects rebuilt from scratch on every clean
build. No configuration option and no patch changes that. The addressable
parts are ranked in README §8; the largest by far is ccache, which is a
toolchain setting rather than a kernel option.

## Rejected patches, and why

**The `sleep` / `timeout` build hack.** Still widely recommended:

```c
/* hack: make the build "reliable" */
system("sleep 5");
```

These are band-aids over parallel-build *races* in the build system. They make
the build slower, they are unmaintainable, upstream rejects them, and the real
fix is always to find the race.

**Disabling warnings, objtool or `Werror` globally.** One diff, and it hides
real bugs. Setting `CONFIG_WERROR=n` is a legitimate and useful single-line
change, which is why it lives in `build-speed.fragment` where it is visible.
Scattering `#pragma GCC diagnostic ignored` through the tree is unreviewable and
loses that distinction entirely.

**Making `make` skip subsystems** via `#if 0` around directories or hardcoded
`obj-y` deletions. That is what Kconfig is for. Doing it in Makefiles makes the
change unauditable, unreconfigurable and impossible to carry across a version
bump.

**LTO.** The conventional answer to "make the kernel smaller", and actively
harmful here: it makes the build substantially slower, and its link stage
exhausts 4 GiB of RAM against 1.9 GiB of swap. The fast path (clang + ThinLTO)
also needs clang, which is not part of a default Arch install, leaving only
GCC's slower LTO. `build-speed.fragment` pins `LTO_NONE`.

**`localmodconfig`.** Not a patch, but the other standard suggestion. Its output
depends on which modules happened to be loaded on the day it ran, and it drops
drivers needed only on cold paths. See README §2.

## The one patch-shaped item

There is a genuine build-system bug here, and it is not an optimisation.
`Makefile` decides whether to define `CC_USING_FENTRY` with a
`cc-option-yn -mfentry` probe, and that probe appears to misdetect support under
GCC 16.2.1:

```
arch/x86/include/asm/ftrace.h:9: error: #error Compiler does not support fentry?
```

A fix to the detection would be a legitimate upstream contribution: it is a
build-system bug affecting any newer compiler, not a special case for this
laptop. It is left unfixed here because the root cause has not been pinned down,
and patching `Makefile` on the strength of a single observation is not a sound
basis for a change that affects every build on the machine.
`CONFIG_FTRACE=n` in `build-speed.fragment` works around it in one reversible
line meanwhile.

To chase the real fix:

```sh
make -C <clean-tree> O=build prepare V=1 2>&1 | grep -i mfentry
```

and check whether `cc-option-yn` is being invoked with flags that make the probe
fail for a reason unrelated to the configuration at all.