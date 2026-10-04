#!/usr/bin/env bash
#
# x453ma-kernel — build and install the X453MA kernel on Arch Linux.
#
#   ./scripts/x453ma-kernel.sh build     build bzImage + modules (out-of-tree)
#   ./scripts/x453ma-kernel.sh install   install into /boot + /usr/lib/modules
#   ./scripts/x453ma-kernel.sh both      build then install
#   ./scripts/x453ma-kernel.sh config    re-resolve .config from defconfig+fragment
#   ./scripts/x453ma-kernel.sh verify    check the fragment still resolves
#   ./scripts/x453ma-kernel.sh info      show what would be installed
#
# Design notes
#   * Out-of-tree build (build/ subdir) so your source tree stays clean and
#     an old build can never leak into a new one.
#   * Deliberately does NOT run efibootmgr, bootctl install, or anything else
#     that creates Boot#### entries. This machine's firmware/NVRAM has a
#     history of trouble; boot entry creation stays a manual, explicit act.
#   * Only `bootctl update` is used, and only if systemd-boot is already
#     installed. `update` refreshes the loader binary; `install` is what writes
#     a NVRAM boot entry, and we never call it.
#
set -euo pipefail

PKG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-$(cd -- "$PKG/.." && pwd)}"
BUILD="${BUILD:-$PKG/build}"
# Applied in order. build-speed.fragment is optional; point KERNEL_FRAGMENT at
# your own file to append more. All are merged on top of defconfig, in order.
FRAGS=("$PKG/config/x453ma.fragment")
[[ -f "$PKG/config/build-speed.fragment" ]] && FRAGS+=("$PKG/config/build-speed.fragment")
[[ -n "${KERNEL_FRAGMENT:-}" ]] && FRAGS+=("$KERNEL_FRAGMENT")
SNAPSHOT="$PKG/config/x453ma.config"

# Keep the release name stable and greppable.
KVER_NAME="x453ma"
LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$SNAPSHOT" 2>/dev/null | head -1)"
[[ -n "$LOCALVERSION" ]] || LOCALVERSION=""

JOBS="${JOBS:-$(nproc)}"
# 2 CPUs / 4 GiB: gcc is not the bottleneck, but a parallel link stage on a
# 4 GiB machine is a real OOM risk. Cap at 4.
(( JOBS > 4 )) && JOBS=4

# ---- ccache: the biggest build-time win available on a slow machine ------
# It is a toolchain setting, not a kernel option, so it cannot live in a
# fragment. On 2 cores this is the difference between ~4 hours for every
# config tweak and a few minutes for all but the changed files.
USE_CCACHE="${USE_CCACHE:-auto}"
if [[ "$USE_CCACHE" == auto ]]; then
    command -v ccache >/dev/null 2>&1 && USE_CCACHE=yes || USE_CCACHE=no
fi
if [[ "$USE_CCACHE" == yes ]]; then
    if command -v ccache >/dev/null 2>&1; then
        # CCACHE_BASEDIR makes hits independent of the tree's directory name,
        # so the cache survives re-extracting the kernel under a new version.
        export CCACHE_BASEDIR="$SRC"
        export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
        # 3 GiB is ample for one kernel config and does not fight everything
        # else for space on a small SSD.
        ccache -M "${CCACHE_MAXSIZE:-3G}" >/dev/null 2>&1 || true
        ccache -z >/dev/null 2>&1 || true
        MAKE_CC="ccache gcc"
    else
        warn "USE_CCACHE=yes requested but ccache is not installed (pacman -S ccache)"
        USE_CCACHE=no
    fi
fi
[[ "${MAKE_CC:-}" ]] || MAKE_CC="gcc"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "this step needs root: sudo $0 $*"; }

check_tree_clean() {
    # Out-of-tree builds refuse to run against a dirty tree; fail with an
    # actionable message instead of the kernel's terse one, and never run
    # mrproper on someone's tree without them asking.
    if [[ -f "$SRC/.config" || -d "$SRC/include/config" \
       || -d "$SRC/arch/$(basename "$PKG")/include/generated" ]] \
       || [[ -d "$SRC/arch/x86/include/generated" ]]; then
        warn "source tree $SRC has build artifacts in it"
        die "out-of-tree builds need a clean tree. Either:
       (a) unpack a pristine copy elsewhere and use:
             SRC=/path/to/linux scripts/x453ma-kernel.sh build
       (b) or deliberately discard it (this deletes .config and generated
           headers in the source tree):
             make -C $SRC mrproper"
    fi
}

kver_of() { # derive the full kernel release from the built tree
    make -s -C "$SRC" O="$BUILD" kernelrelease 2>/dev/null
}

cmd_config() {
    log "resolving .config from defconfig + ${#FRAGS[@]} fragment(s)"
    printf '     - %s\n' "${FRAGS[@]}"
    check_tree_clean
    mkdir -p "$BUILD"
    make -C "$SRC" O="$BUILD" defconfig
    "$SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" "$BUILD/.config" "${FRAGS[@]}"
    make -C "$SRC" O="$BUILD" olddefconfig
    log "resolved .config: $BUILD/.config"
    log "snapshot it with:  cp $BUILD/.config $SNAPSHOT"
}

cmd_build() {
    check_tree_clean
    mkdir -p "$BUILD"
    [[ -f "$BUILD/.config" ]] || { log "no .config yet; generating"; cmd_config; }
    if [[ "$USE_CCACHE" == yes ]]; then
        log "ccache: on (CCACHE_DIR=${CCACHE_DIR:-$HOME/.cache/ccache})"
    else
        log "ccache: OFF — consider: sudo pacman -S ccache  (biggest build-time win)"
    fi
    log "building with -j$JOBS  (JOBS=$JOBS to override; kernelrelease derived after)"
    make -C "$SRC" O="$BUILD" -j"$JOBS" CC="$MAKE_CC" HOSTCC="$MAKE_CC" bzImage modules
    local kver; kver="$(kver_of)"
    [[ -n "$kver" ]] || die "could not determine kernelrelease"
    log "built $kver"
    printf '%s\n' "$kver" > "$BUILD/.kernelrelease"
    if [[ -f "$BUILD/vmlinuz" ]]; then
        ls -lh "$BUILD/vmlinuz" | awk '{printf "    vmlinuz %s\n", $5}'
    fi
    if [[ "$USE_CCACHE" == yes ]]; then
        log "ccache statistics:"
        ccache -s 2>/dev/null | sed -n '1,6p' | sed 's/^/    /'
    fi
    log "run '$0 install' to install, or '$0 both' next time"
}

cmd_install() {
    need_root install
    local kver; kver="$(cat "$BUILD/.kernelrelease" 2>/dev/null || kver_of)"
    [[ -n "$kver" && -f "$BUILD/vmlinuz" ]] || die "nothing built; run '$0 build' first"

    log "kernel release: $kver"

    # ---- modules -----------------------------------------------------
    log "installing modules to /usr/lib/modules/$kver"
    rm -rf "/usr/lib/modules/$kver"
    make -C "$SRC" O="$BUILD" modules_install
    depmod -a "$kver"

    # ---- kernel + initramfs -----------------------------------------
    # Name it after the release so several custom kernels can coexist.
    local vmlinuz="/boot/vmlinuz-$KVER_NAME"
    log "installing $vmlinuz"
    install -m 0644 "$BUILD/vmlinuz" "$vmlinuz"

    local preset="/etc/mkinitcpio.d/${KVER_NAME}.preset"
    log "writing mkinitcpio preset: $preset"
    install -d -m 0755 /etc/mkinitcpio.d
    cat > "$preset" <<EOF
# Generated by x453ma-kernel.sh — do not edit by hand.
# Mirrors Arch's stock /etc/mkinitcpio.d/linux.preset
ALL_kver="$vmlinuz"
EOF
    if [[ -f /etc/mkinitcpio.d/linux.preset ]]; then
        grep -v '^ALL_kver=' /etc/mkinitcpio.d/linux.preset >> "$preset"
    fi
    grep -q '^ALL_mkinitcpio_args=' "$preset" || echo 'ALL_mkinitcpio_args=""' >> "$preset"

    log "building initramfs (mkinitcpio -p $KVER_NAME)"
    mkinitcpio -p "$KVER_NAME"

    # ---- bootloader --------------------------------------------------
    # ONLY `bootctl update`. We never run `bootctl install` or `efibootmgr`,
    # because those are the operations that write Boot#### entries to this
    # board's NVRAM.
    if command -v bootctl >/dev/null 2>&1 && [[ -d /boot/loader ]]; then
        log "systemd-boot detected: running 'bootctl update' (no NVRAM writes)"
        bootctl update || warn "bootctl update failed; copy the loader manually"
        log "add an entry by hand if you want one in the Boot menu:"
        log "    edit /boot/loader/loader.conf, then reboot and pick it"
    elif command -v efibootmgr >/dev/null 2>&1; then
        log "no systemd-boot layout found; skipping loader update"
    fi

    log "installed. Reboot and select 'Arch Linux (x453ma)' in the boot menu."
    log "If it does not appear, add it to /boot/loader/loader.conf yourself:"
    cat <<'EOF'

        title   Arch Linux (x453ma)
        linux   /vmlinuz-x453ma
        initrd  /initramfs-x453ma.img
        options root=PARTUUID=<your-root-partuuid> rootflags=subvol=@ rw rootfstype=btrfs

EOF
}

cmd_info() {
    local kver; kver="$(cat "$BUILD/.kernelrelease" 2>/dev/null || kver_of || true)"
    echo "source tree : $SRC"
    echo "build dir   : $BUILD"
    echo "fragments   :"
    printf '              %s\n' "${FRAGS[@]}"
    echo "snapshot    : $SNAPSHOT"
    echo "jobs        : $JOBS"
    echo "ccache      : $( [[ "$USE_CCACHE" == yes ]] && echo "on (${CCACHE_DIR:-$HOME/.cache/ccache})" || echo 'off — sudo pacman -S ccache' )"
    echo "compiler    : $MAKE_CC ($(gcc --version 2>/dev/null | head -1))"
    echo "kernelrelease: ${kver:-<not built>}"
    echo "mkinitcpio  : $(command -v mkinitcpio || echo '<not installed>')"
    echo "bootctl     : $(command -v bootctl   || echo '<not installed>')"
    echo "/boot       : $(findmnt -no SOURCE,FSTYPE /boot 2>/dev/null || echo '<not a separate mount>')"
    echo "booted via  : $( [[ -d /sys/firmware/efi ]] && echo UEFI || echo 'BIOS/CSM' )"
    echo "swap        : $(free -h 2>/dev/null | awk '/^Swap/{print $2" total, "$3" used"}')"
}

case "${1:-}" in
    build)   cmd_build ;;
    install) cmd_install ;;
    both)    cmd_build; cmd_install ;;
    config)  cmd_config ;;
    verify)  "$PKG/scripts/verify-config.sh" ;;
    info)    cmd_info ;;
    *) sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac