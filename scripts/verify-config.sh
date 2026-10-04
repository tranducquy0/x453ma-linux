#!/usr/bin/env bash
#
# verify-config.sh — prove that config/x453ma.fragment still resolves the way
# we intend on the *current* kernel tree.
#
# Why this exists: kernel Kconfig symbol names drift between releases. In
# Linux 7.2 alone we hit RETPOLINE -> MITIGATION_RETPOLINE, BTRFS_FS_XATTR and
# X86_5LEVEL gone, WLAN_VENDOR_ATH9K -> WLAN_VENDOR_ATH, MOUSEPS2 ->
# MOUSE_PS2, EEPROM_AT24, GPIO base drivers renamed, and an entire media menu
# that silently swallows CONFIG_VIDEO_DEV. A fragment that "looked right" was
# silently dropping R8169 on one iteration and the webcam on another.
#
# Exit status: 0 if every requested setting is honoured, 1 otherwise.
#
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(dirname -- "$HERE")"
SRC="${SRC:-$(cd -- "$PKG/.." && pwd)}"
FRAG="${FRAG:-$PKG/config/x453ma.fragment}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/x453ma-verify.XXXXXX")}"
KEEP="${KEEP:-0}"

# CONFIG_LINUX_DIR lets the caller point at a freshly unpacked kernel tree.
if [[ -n "${CONFIG_LINUX_DIR:-}" ]]; then
    SRC="$CONFIG_LINUX_DIR"
fi

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC/Makefile"        ]] || die "not a kernel tree: $SRC"
[[ -f "$SRC/.config"         ]] && die "$SRC is not a clean source tree (it has a .config). Run 'make mrproper' in it, or point CONFIG_LINUX_DIR at a pristine copy."
[[ -d "$SRC/include/config"  ]] && die "$SRC/include/config exists — source tree is not clean; run 'make mrproper'."
[[ -d "$SRC/arch/x86/include/generated" ]] && die "$SRC/arch/x86/include/generated exists — source tree is not clean; run 'make mrproper'."
[[ -f "$FRAG"                ]] || die "no fragment at $FRAG"

trap '[ "$KEEP" = 1 ] || rm -rf "$WORK"' EXIT

echo "tree    : $SRC"
echo "fragment: $FRAG"
echo "workdir : $WORK"
echo

echo "==> make defconfig"
make -C "$SRC" O="$WORK" defconfig >/dev/null || die "defconfig failed"

echo "==> merging fragment"
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$WORK" "$WORK/.config" "$FRAG" \
    >"$WORK/merge.log" 2>&1 || { cat "$WORK/merge.log"; die "merge_config.sh failed"; }

echo "==> make olddefconfig (resolves dependencies)"
make -C "$SRC" O="$WORK" olddefconfig >"$WORK/olddefconfig.log" 2>&1 \
    || { cat "$WORK/olddefconfig.log"; die "olddefconfig failed"; }

grep -i 'warning' "$WORK/olddefconfig.log" | sed 's/^/    warn: /'

echo
python3 - "$FRAG" "$WORK/.config" <<'PY'
import sys
frag, final = sys.argv[1], sys.argv[2]
cfg = {}
for line in open(final):
    s = line.strip()
    if s.startswith("CONFIG_") and "=" in s:
        k, v = s.split("=", 1); cfg[k] = v
    elif s.startswith("# CONFIG_") and s.endswith(" is not set"):
        cfg[s[2:-11]] = "n"

missing, conflict, ok = [], [], 0
for raw in open(frag):
    s = raw.strip()
    if s.startswith("# CONFIG_") and s.endswith(" is not set"):
        k, want = s[2:-11], "n"
    elif s.startswith("CONFIG_") and "=" in s:
        k, want = s.split("=", 1)
    else:
        continue
    if k not in cfg:
        missing.append(k)
    elif cfg[k] != want:
        conflict.append((k, want, cfg[k]))
    else:
        ok += 1

print(f"    honoured verbatim : {ok}")
print(f"    not emitted       : {len(missing)}   (parent menu off, dependency-gated, or symbol gone)")
print(f"    resolved differently: {len(conflict)}")
for k in sorted(missing):
    print(f"      absent    {k}")
for k, w, g in sorted(conflict):
    print(f"      CONFLICT {k}: wanted {w}, got {g}")

# A conflict is always a bug in the fragment. An absent symbol is only a bug
# if it is something we actively require; the curated list below is the set
# that is expected to vanish because a parent menu is off.
EXPECTED_ABSENT = {
    "CONFIG_ATA_OVERLAY", "CONFIG_ETHERNET_VENDOR_MICROCHIP", "CONFIG_SCSI_ISCSI",
    "CONFIG_ATH9K_COMMON_DEBUG", "CONFIG_ATH9K_COMMON_SPECTRAL", "CONFIG_ATH9K_DEBUGFS",
    "CONFIG_ATH9K_DFS_DEBUGFS", "CONFIG_ATH9K_STATION_STATISTICS",
    "CONFIG_BNX2", "CONFIG_DRM_CIRRUS", "CONFIG_DRM_SIS", "CONFIG_DRM_VIA",
    "CONFIG_E1000", "CONFIG_E1000E", "CONFIG_MT7601U", "CONFIG_RT2X00", "CONFIG_ZD1211RW",
    "CONFIG_OCFS2_FS", "CONFIG_UBIFS_FS", "CONFIG_REGULATOR_DEBUG",
    "CONFIG_SND_PCM_OSS", "CONFIG_EFI_VARS_PSTORE", "CONFIG_WIRELESS_EXT",
}
unexpected = [k for k in missing if k not in EXPECTED_ABSENT]

print()
if conflict or unexpected:
    if conflict:
        print("FAIL: the fragment did not get what it asked for.")
    if unexpected:
        print("FAIL: these symbols vanished unexpectedly:")
        for k in sorted(unexpected):
            print("   ", k)
    sys.exit(1)

print("PASS: every requested setting resolved as intended.")
print("      (re-run this after every kernel version bump)")
PY
rc=$?

if [[ $rc -eq 0 ]]; then
    echo
    echo "resolved .config left at: $WORK/.config"
    KEEP=1
    echo "copy it to config/x453ma.config if you want to snapshot it."
fi
exit $rc