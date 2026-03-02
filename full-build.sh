#!/bin/bash
# =============================================================
#  NextOS — Master Build Script
#
#  Usage: ./full-build.sh [OPTIONS]
#
#  Options:
#    --clean           Wipe all build artifacts, then build fresh
#    --clean-only      Wipe all build artifacts and exit (no build)
#    --clean-kernel    Include kernel object files in the clean
#                      (implies --clean; runs 'make mrproper')
#    --skip-kernel     Re-use existing vmlinuz  (saves ~10 min)
#    --skip-rootfs     Skip rootfs.img creation (needs sudo)
#    --help | -h       Show this message
# =============================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}[$1/7] $2${RESET}"; }
clean_item() { echo -e "  ${RED}[-]${RESET}  $*"; }

# ── Argument parsing ──────────────────────────────────────────
DO_CLEAN=0
CLEAN_ONLY=0
CLEAN_KERNEL=0
SKIP_KERNEL=0
SKIP_ROOTFS_IMG=0

for arg in "$@"; do
    case "$arg" in
        --clean)          DO_CLEAN=1 ;;
        --clean-only)     DO_CLEAN=1; CLEAN_ONLY=1 ;;
        --clean-kernel)   DO_CLEAN=1; CLEAN_KERNEL=1 ;;
        --skip-kernel)    SKIP_KERNEL=1 ;;
        --skip-rootfs)    SKIP_ROOTFS_IMG=1 ;;
        --help|-h)
            echo ""
            echo "  Usage: $0 [OPTIONS]"
            echo ""
            echo "  Build options:"
            echo "    --skip-kernel     Re-use existing vmlinuz (saves ~10 min)"
            echo "    --skip-rootfs     Skip rootfs.img creation (needs sudo)"
            echo ""
            echo "  Clean options:"
            echo "    --clean           Wipe all build artifacts, then do a full build"
            echo "    --clean-only      Wipe all build artifacts and exit (no build)"
            echo "    --clean-kernel    Also wipe kernel objects (runs make mrproper)"
            echo ""
            echo "  Examples:"
            echo "    $0                          Normal incremental build"
            echo "    $0 --clean                  Clean everything, then full build"
            echo "    $0 --clean --skip-kernel    Clean, then build (re-use kernel)"
            echo "    $0 --clean-only             Just clean, don't build"
            echo ""
            exit 0
            ;;
    esac
done

# ── Paths ─────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VERSION="6.19"
KERNEL_DIR="$PROJECT_DIR/linux-${KERNEL_VERSION}"
ROOTFS_DIR="$PROJECT_DIR/rootfs"
INITRAMFS_DIR="$PROJECT_DIR/initramfs"
BOOT_DIR="$PROJECT_DIR/boot"
ISO_DIR="$PROJECT_DIR/iso"           # Pure build artefact — deleted & recreated each build
BUILD_DIR="$PROJECT_DIR/build"
MNT_DIR="$BUILD_DIR/mnt"
ISO_OUT="$PROJECT_DIR/Next-OS.iso"

# FIX #3 — GRUB_SRC is now OUTSIDE the ISO staging directory.
# Previously it pointed into iso/boot/grub, which is deleted at
# the start of Step 7. The source of truth now lives in grub/.
GRUB_SRC="$PROJECT_DIR/grub"
BANNER_SRC="$PROJECT_DIR/banner/nextOS2.png"

# =============================================================
#  CLEAN FUNCTION
# =============================================================
do_clean() {
    echo -e "\n${BOLD}${RED}========================================"
    echo "   NextOS Clean"
    echo -e "========================================${RESET}\n"

    # ISO output file
    echo -e "${BOLD}  ISO output:${RESET}"
    if [ -f "$ISO_OUT" ]; then
        SIZE=$(du -sh "$ISO_OUT" | cut -f1)
        rm -f "$ISO_OUT"
        clean_item "Removed  Next-OS.iso  ($SIZE)"
    else
        info "  Next-OS.iso — not present"
    fi

    # ISO staging directory (pure build artefact — safe to delete entirely)
    echo -e "\n${BOLD}  ISO staging directory:${RESET}"
    if [ -d "$ISO_DIR" ]; then
        SIZE=$(du -sh "$ISO_DIR" 2>/dev/null | cut -f1 || echo "?")
        rm -rf "$ISO_DIR"
        clean_item "Removed  iso/  ($SIZE)"
    else
        info "  iso/ — not present"
    fi

    # Boot artifacts
    echo -e "\n${BOLD}  Boot artifacts (boot/):${RESET}"
    FOUND_ANY=0
    for artifact in vmlinuz initramfs.img rootfs.img; do
        TARGET="$BOOT_DIR/$artifact"
        if [ -f "$TARGET" ]; then
            SIZE=$(du -sh "$TARGET" | cut -f1)
            rm -f "$TARGET"
            clean_item "Removed  boot/$artifact  ($SIZE)"
            FOUND_ANY=1
        fi
    done
    [ "$FOUND_ANY" = "0" ] && info "  boot/ — no artifacts present"

    # Busybox symlinks in initramfs
    echo -e "\n${BOLD}  Busybox symlinks (initramfs/bin/ and initramfs/sbin/):${RESET}"
    LINK_COUNT=0
    for dir in bin sbin usr/bin usr/sbin; do
        TARGET_DIR="$INITRAMFS_DIR/$dir"
        [ -d "$TARGET_DIR" ] || continue
        while IFS= read -r -d '' link; do
            DEST=$(readlink "$link" 2>/dev/null || true)
            case "$DEST" in
                busybox|*/busybox|../bin/busybox)
                    rm -f "$link"
                    LINK_COUNT=$((LINK_COUNT + 1))
                    ;;
            esac
        done < <(find "$TARGET_DIR" -maxdepth 1 -type l -print0 2>/dev/null)
    done
    if [ "$LINK_COUNT" -gt 0 ]; then
        clean_item "Removed  $LINK_COUNT busybox symlinks"
    else
        info "  No busybox symlinks found"
    fi

    # FIX #2 — Guard: warn if stale files are present in initramfs/mnt/
    # (a rootfs.img left there will be packed into the initramfs, breaking boot)
    if find "$INITRAMFS_DIR/mnt" -mindepth 1 -not -type d 2>/dev/null | grep -q .; then
        warn "Stale files found inside initramfs/mnt/ — removing:"
        find "$INITRAMFS_DIR/mnt" -mindepth 1 -not -type d | while read -r f; do
            rm -f "$f"
            clean_item "Removed $f"
        done
    fi

    # Rootfs build-generated files only
    echo -e "\n${BOLD}  Rootfs build-generated files (rootfs/):${RESET}"
    if [ -f "$ROOTFS_DIR/bin/bash" ]; then
        rm -f "$ROOTFS_DIR/bin/bash"; clean_item "Removed  rootfs/bin/bash"
    fi
    for libdir in \
        "$ROOTFS_DIR/lib/x86_64-linux-gnu" \
        "$ROOTFS_DIR/lib/i386-linux-gnu" \
        "$ROOTFS_DIR/lib/aarch64-linux-gnu"; do
        if [ -d "$libdir" ]; then
            SIZE=$(du -sh "$libdir" | cut -f1)
            rm -rf "$libdir"
            clean_item "Removed  ${libdir#$PROJECT_DIR/}  ($SIZE)"
        fi
    done
    if [ -d "$ROOTFS_DIR/lib64" ] && [ -n "$(ls -A "$ROOTFS_DIR/lib64" 2>/dev/null)" ]; then
        SIZE=$(du -sh "$ROOTFS_DIR/lib64" | cut -f1)
        rm -rf "$ROOTFS_DIR/lib64"
        mkdir -p "$ROOTFS_DIR/lib64"
        clean_item "Removed  rootfs/lib64/ contents  ($SIZE)"
    fi
    if [ -d "$ROOTFS_DIR/lib/modules" ]; then
        SIZE=$(du -sh "$ROOTFS_DIR/lib/modules" | cut -f1)
        rm -rf "$ROOTFS_DIR/lib/modules"
        clean_item "Removed  rootfs/lib/modules/  ($SIZE)"
    fi

    # Kernel build objects
    echo -e "\n${BOLD}  Kernel build objects:${RESET}"
    if [ "$CLEAN_KERNEL" = "1" ]; then
        if [ -d "$KERNEL_DIR" ]; then
            info "  Running make mrproper in $KERNEL_DIR ..."
            cd "$KERNEL_DIR" && make mrproper 2>&1 | tail -3 && cd "$PROJECT_DIR"
            clean_item "Kernel objects wiped via make mrproper"
        fi
    else
        if [ -d "$KERNEL_DIR" ] && [ -f "$KERNEL_DIR/vmlinux" ]; then
            info "  Running make clean in $KERNEL_DIR ..."
            cd "$KERNEL_DIR" && make clean 2>&1 | tail -3 && cd "$PROJECT_DIR"
            clean_item "Kernel objects cleaned via make clean (.config kept)"
        else
            info "  No kernel build objects found"
        fi
    fi

    echo ""
    echo -e "${BOLD}${GREEN}  Clean complete.${RESET}"
    echo ""
}

# =============================================================
#  Run clean if requested
# =============================================================
if [ "$DO_CLEAN" = "1" ]; then
    do_clean
    if [ "$CLEAN_ONLY" = "1" ]; then
        echo "  --clean-only passed. Exiting without building."
        exit 0
    fi
    echo -e "  Proceeding to full build...\n"
fi

echo -e "${BOLD}"
echo "========================================"
echo "   NextOS Complete Build"
echo "   Project: $PROJECT_DIR"
echo "   Kernel:  $KERNEL_VERSION"
echo "========================================"
echo -e "${RESET}"

mkdir -p "$BOOT_DIR" "$MNT_DIR"

# =============================================================
# STEP 1 — Build Kernel
# =============================================================
step 1 "Building kernel ${KERNEL_VERSION}..."

if [ "$SKIP_KERNEL" = "1" ]; then
    warn "Skipping kernel build (--skip-kernel passed)"
    [ -f "$BOOT_DIR/vmlinuz" ] || die "No existing vmlinuz at $BOOT_DIR/vmlinuz"
else
    [ -d "$KERNEL_DIR" ] || die "Kernel source not found at $KERNEL_DIR\n  Run: build/download_kernel.sh"
    cd "$KERNEL_DIR"

    info "Applying kernel config..."
    make olddefconfig

    # FIX #4 — Use only valid Kconfig symbol names.
    # CONFIG_ISO9660_FS_MODULE and CONFIG_BLK_DEV_LOOP_MODULE do not exist
    # as separate symbols. Setting =y (--enable) already forces built-in;
    # there is no _MODULE counterpart to disable. The old --disable lines
    # caused a silent indeterminate state that could leave ISO9660 as =m.
    scripts/config \
        --enable  CONFIG_ISO9660_FS          \
        --enable  CONFIG_BLK_DEV_LOOP        \
        --enable  CONFIG_EXT4_FS             \
        --enable  CONFIG_OVERLAY_FS          \
        --enable  CONFIG_TMPFS               \
        --enable  CONFIG_DEVTMPFS            \
        --enable  CONFIG_DEVTMPFS_MOUNT      \
        --enable  CONFIG_FB_VESA             \
        --enable  CONFIG_FRAMEBUFFER_CONSOLE \
        --enable  CONFIG_ATA                 \
        --enable  CONFIG_ATA_PIIX            \
        --enable  CONFIG_SATA_AHCI           \
        --enable  CONFIG_BLK_DEV_SR          \
        --enable  CONFIG_BLK_DEV_SD          \
        --enable  CONFIG_SCSI                \
        --enable  CONFIG_SCSI_LOWLEVEL       \
        --enable  CONFIG_SR_ATTACHED_SETTINGS\
        --enable  CONFIG_CDROM               \
        --enable  CONFIG_VIRTIO_BLK          \
        --enable  CONFIG_VIRTIO_PCI          \
        --enable  CONFIG_VIRTIO_MMIO         \
        --enable  CONFIG_PCI                 \
        --enable  CONFIG_PCI_LEGACY

    # Run olddefconfig a second time AFTER scripts/config so the values
    # are locked in before the build — without this, olddefconfig on the
    # first pass may override the =y settings back to =m.
    make olddefconfig

    info "Building kernel ($(nproc) threads)..."
    make -j"$(nproc)"
    cp arch/x86/boot/bzImage "$BOOT_DIR/vmlinuz"
    ok "Kernel built → $BOOT_DIR/vmlinuz"
    cd "$PROJECT_DIR"
fi

# =============================================================
# STEP 2 — Install Kernel Modules into rootfs
# =============================================================
step 2 "Installing kernel modules into rootfs..."

if [ "$SKIP_KERNEL" = "0" ]; then
    cd "$KERNEL_DIR"
    make modules_install INSTALL_MOD_PATH="$ROOTFS_DIR"
    find "$ROOTFS_DIR/lib/modules" -maxdepth 2 \
        \( -name build -o -name source \) -type l -delete 2>/dev/null || true
    ok "Modules installed → $ROOTFS_DIR/lib/modules/"
    cd "$PROJECT_DIR"
else
    warn "Skipping module install (kernel build skipped)"
fi

# =============================================================
# STEP 3 — Populate rootfs
# =============================================================
step 3 "Populating rootfs..."

ROOTFS_DIR="${ROOTFS_DIR:-./rootfs}"

mkdir -p "$ROOTFS_DIR"/{bin,sbin,lib,lib64,dev,proc,sys,etc,tmp,run,var/log,home/user,root}

# ── Bash ─────────────────────────────────────────────────────
cp /bin/bash "$ROOTFS_DIR/bin/bash"

# Create /bin/sh -> bash symlink so any #!/bin/sh scripts work
ln -sf bash "$ROOTFS_DIR/bin/sh"

# Copy bash's shared libraries
copy_libs() {
    local binary="$1" dest_root="$2"
    ldd "$binary" 2>/dev/null | grep -oP '(/[a-zA-Z0-9_./-]+\.so[.0-9]*)' | sort -u | \
    while read -r lib; do
        [ -f "$lib" ] || continue
        local dest_dir="$dest_root$(dirname "$lib")"
        mkdir -p "$dest_dir"
        cp -L "$lib" "$dest_dir/" 2>/dev/null || true
    done
    local interp
    interp=$(readelf -l "$binary" 2>/dev/null | grep -oP '\[.+ld[^]]+\]' | tr -d '[]' || true)
    if [ -n "$interp" ] && [ -f "$interp" ]; then
        mkdir -p "$dest_root$(dirname "$interp")"
        cp -L "$interp" "$dest_root$(dirname "$interp")/"
    fi
}
copy_libs /bin/bash "$ROOTFS_DIR"

# ── Validate /sbin/init BEFORE building the image ─────────────
INIT_FILE="$ROOTFS_DIR/sbin/init"
[ -f "$INIT_FILE" ] || die "MISSING: rootfs/sbin/init"
chmod +x "$INIT_FILE"

# Check shebang — must be bash (sh does not exist in rootfs without symlink)
# SHEBANG=$(head -1 "$INIT_FILE")
# if echo "$SHEBANG" | grep -q '#!/bin/sh$'; then
#     warn "rootfs/sbin/init uses #!/bin/sh — changing to #!/bin/bash"
#     sed -i '1s|#!/bin/sh$|#!/bin/bash|' "$INIT_FILE"
# fi

# Check for CRLF line endings — kills scripts silently on Linux
if file "$INIT_FILE" | grep -q CRLF; then
    warn "rootfs/sbin/init has CRLF line endings — converting to LF"
    sed -i 's/\r//' "$INIT_FILE"
fi

# Check for busybox-only commands that don't exist in rootfs
for cmd in setsid cttyhack busybox; do
    if grep -q "$cmd" "$INIT_FILE"; then
        warn "rootfs/sbin/init references '$cmd' which is NOT in the rootfs"
        warn "Remove it — it only exists in the initramfs busybox environment"
    fi
done

ok "/sbin/init validated — shebang: $(head -1 "$INIT_FILE")"

# ── /etc files ────────────────────────────────────────────────
[ -f "$ROOTFS_DIR/etc/passwd" ] || cat > "$ROOTFS_DIR/etc/passwd" <<'ETCEOF'
root:x:0:0:root:/root:/bin/bash
user:x:1000:1000:NextOS User:/home/user:/bin/bash
ETCEOF

[ -f "$ROOTFS_DIR/etc/group" ] || cat > "$ROOTFS_DIR/etc/group" <<'ETCEOF'
root:x:0:
user:x:1000:
ETCEOF

[ -f "$ROOTFS_DIR/etc/hostname" ] || echo "nextos" > "$ROOTFS_DIR/etc/hostname"

[ -f "$ROOTFS_DIR/etc/profile" ] || cat > "$ROOTFS_DIR/etc/profile" <<'ETCEOF'
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export HOME=/root
export TERM=linux
ETCEOF

ok "rootfs populated"

# =============================================================
# STEP 4 — Busybox symlinks (initramfs)
# =============================================================
step 4 "Creating busybox symlinks in initramfs..."

BUSYBOX_BIN="$INITRAMFS_DIR/bin/busybox"
[ -f "$BUSYBOX_BIN" ] || die "busybox not found at $BUSYBOX_BIN"
[ -x "$BUSYBOX_BIN" ] || chmod +x "$BUSYBOX_BIN"

if file "$BUSYBOX_BIN" | grep -q "dynamically"; then
    warn "busybox is dynamically linked!"
    warn "initramfs REQUIRES a static busybox build."
    warn "Download: https://busybox.net/downloads/binaries/"
fi

SBIN_APPLETS="
    acpid       adjtimex    arp         blkid       blockdev
    brctl       chroot      depmod      devmem      dhcprelay
    dnsmasq     e2fsck      eject       fdisk       findfs
    freeramdisk fsck        fsck.ext2   fsck.ext3   fsck.ext4
    getty       halt        hdparm      hwclock
    ifconfig    ifdown      ifenslave   ifup
    init        insmod      ip          ipcalc
    klogd       ldconfig    loadkmap    losetup
    mdev        mkdosfs     mke2fs      mkfs.ext2   mkfs.ext3
    mkfs.ext4   mkfs.vfat   mknod       mkswap
    modinfo     modprobe    nameif
    pivot_root  poweroff
    raidautorun reboot      rmmod       route       runlevel
    setconsole  start-stop-daemon       sulogin
    swapoff     swapon      switch_root
    sysctl      syslogd
    udhcpc      udhcpd      umount      zcip
"

CRITICAL_APPLETS="sh mount umount switch_root losetup modprobe mknod sleep mdev"

mkdir -p \
    "$INITRAMFS_DIR/bin" \
    "$INITRAMFS_DIR/sbin" \
    "$INITRAMFS_DIR/usr/bin" \
    "$INITRAMFS_DIR/usr/sbin" \
    "$INITRAMFS_DIR/dev" \
    "$INITRAMFS_DIR/proc" \
    "$INITRAMFS_DIR/sys" \
    "$INITRAMFS_DIR/mnt/iso" \
    "$INITRAMFS_DIR/mnt/root"

# FIX #2 — Safety guard: refuse to build if mnt/ contains real files.
# A rootfs.img left in initramfs/mnt/iso/boot/ gets packed into the
# initramfs, making it 256+ MB and breaking early boot memory limits.
if find "$INITRAMFS_DIR/mnt" -mindepth 1 -not -type d 2>/dev/null | grep -q .; then
    echo ""
    warn "================================================================"
    warn "  STALE FILES DETECTED INSIDE initramfs/mnt/"
    warn ""
    warn "  The following files will be packed INTO the initramfs image"
    warn "  if not removed. This is almost always a leftover from a"
    warn "  previous (failed) mount operation."
    warn ""
    find "$INITRAMFS_DIR/mnt" -mindepth 1 -not -type d | while read -r f; do
        warn "    $f  ($(du -sh "$f" | cut -f1))"
    done
    warn ""
    warn "  Removing stale files now..."
    warn "================================================================"
    echo ""
    sudo rm -rf "$INITRAMFS_DIR/mnt/iso"
    ok "Stale files removed from initramfs/mnt/"
fi

is_sbin() { echo "$SBIN_APPLETS" | grep -Fqw -- "$1"; }

info "Querying busybox --list..."
APPLET_LIST=$("$BUSYBOX_BIN" --list 2>/dev/null) || \
    die "busybox --list failed — binary may be corrupt or wrong architecture"

TOTAL=0; BIN_COUNT=0; SBIN_COUNT=0; SKIPPED=0

while IFS= read -r applet; do
    [ -z "$applet" ] && continue
    if is_sbin "$applet"; then
        TARGET_DIR="$INITRAMFS_DIR/sbin"
        LINK_TARGET="../bin/busybox"
        SBIN_COUNT=$((SBIN_COUNT + 1))
    else
        TARGET_DIR="$INITRAMFS_DIR/bin"
        LINK_TARGET="busybox"
        BIN_COUNT=$((BIN_COUNT + 1))
    fi
    LINK_PATH="$TARGET_DIR/$applet"
    if [ -f "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
        info "  Keeping real binary: $LINK_PATH"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    ln -sf "$LINK_TARGET" "$LINK_PATH"
    TOTAL=$((TOTAL + 1))
done <<< "$APPLET_LIST"

ok "Symlinks created: $TOTAL total  ($BIN_COUNT in bin/,  $SBIN_COUNT in sbin/)"
[ "$SKIPPED" -gt 0 ] && info "Preserved $SKIPPED existing real binaries"

echo ""
info "Verifying boot-critical applets..."
ALL_OK=1
for applet in $CRITICAL_APPLETS; do
    FOUND=""
    for dir in bin sbin usr/bin usr/sbin; do
        [ -e "$INITRAMFS_DIR/$dir/$applet" ] && FOUND="$dir/$applet" && break
    done
    if [ -n "$FOUND" ]; then
        info "  [✓]  $FOUND"
    else
        warn "  [✗]  MISSING: $applet  ← boot failure"
        ALL_OK=0
    fi
done
[ "$ALL_OK" = "1" ] && ok "All critical applets present" || \
    warn "One or more critical applets missing — rebuild busybox with those applets enabled"

# =============================================================
# STEP 5 — Pack initramfs image
# INSERT this block BEFORE the find/cpio/gzip line
# =============================================================

# Strip CRLF from all text files in initramfs.
# A single \r in the /init shebang causes "Failed to execute /init (error -2)"
# because the kernel looks for "/bin/sh\r" which doesn't exist.
info "Stripping CRLF line endings from initramfs text files..."
find "$INITRAMFS_DIR" -maxdepth 3 -type f | while read -r f; do
    # Only process files that are text (scripts, configs)
    # Skip the busybox binary itself and any other ELF binaries
    if file "$f" 2>/dev/null | grep -qvE 'ELF|data|archive|image'; then
        if grep -qP '\r' "$f" 2>/dev/null; then
            sed -i 's/\r//' "$f"
            warn "  Fixed CRLF: $f"
        fi
    fi
done

# Ensure init is executable (cpio preserves permissions, so this matters)
chmod +x "$INITRAMFS_DIR/init"

# Verify the shebang is clean before packing
INIT_SHEBANG=$(head -1 "$INITRAMFS_DIR/init" | cat -A)
if echo "$INIT_SHEBANG" | grep -q '\^M'; then
    die "initramfs/init still has CRLF after stripping! Check your editor settings."
fi
info "initramfs/init shebang OK: $(head -1 "$INITRAMFS_DIR/init")"

# --- existing pack command below (unchanged) ---
cd "$INITRAMFS_DIR"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$BOOT_DIR/initramfs.img"
cd "$PROJECT_DIR"

ok "initramfs packed → $BOOT_DIR/initramfs.img ($(du -sh "$BOOT_DIR/initramfs.img" | cut -f1))"

# =============================================================
# STEP 6 — Build rootfs image
# =============================================================
step 6 "Building rootfs.img (requires sudo)..."
#info "run build-iso for the next stage for Docker builds"

if [ "$SKIP_ROOTFS_IMG" = "1" ]; then
    warn "Skipping rootfs.img (--skip-rootfs passed)"
    [ -f "$BOOT_DIR/rootfs.img" ] || \
        warn "No existing rootfs.img — ISO will not switch_root"
else
    if ! sudo -n true 2>/dev/null && ! sudo -v 2>/dev/null; then
        warn "sudo not available — skipping rootfs.img"
        warn "Build manually:"
        warn "  sudo dd if=/dev/zero of=$BOOT_DIR/rootfs.img bs=1M count=256"
        warn "  sudo mkfs.ext4 -F -L nextos-root $BOOT_DIR/rootfs.img"
        warn "  sudo mount -o loop $BOOT_DIR/rootfs.img $MNT_DIR"
        warn "  sudo cp -a $ROOTFS_DIR/. $MNT_DIR/"
        warn "  sudo umount $MNT_DIR"
    else
        ROOTFS_SIZE_MB=256
        info "Creating ${ROOTFS_SIZE_MB}MB ext4 rootfs image..."
        sudo dd if=/dev/zero of="$BOOT_DIR/rootfs.img" bs=1M count="$ROOTFS_SIZE_MB" status=progress
        sudo mkfs.ext4 -F -L "nextos-root" "$BOOT_DIR/rootfs.img"

        info "Populating rootfs image..."
        sudo mount -o loop,rw "$BOOT_DIR/rootfs.img" "$MNT_DIR"
        sudo cp -a "$ROOTFS_DIR/." "$MNT_DIR/"
        sudo umount "$MNT_DIR"
        # Mark filesystem clean now to avoid ext4 recovery remounts.
        sudo e2fsck -pf "$BOOT_DIR/rootfs.img" >/dev/null || true

        ok "rootfs.img → $BOOT_DIR/rootfs.img ($(du -sh "$BOOT_DIR/rootfs.img" | cut -f1))"
    fi
fi

# =============================================================
# STEP 7 — Build ISO
# =============================================================
step 7 "Building ISO..."

# FIX #3 — iso/ is a pure build artefact. Deleting it here is safe
# because grub.cfg and other source files now live in grub/ (outside iso/).
info "Creating ISO staging directory..."
rm -rf "$ISO_DIR"
mkdir -p \
    "$ISO_DIR/boot/grub/themes/nextos" \
    "$ISO_DIR/boot/grub/fonts"

cp "$BOOT_DIR/vmlinuz"       "$ISO_DIR/boot/"
cp "$BOOT_DIR/initramfs.img" "$ISO_DIR/boot/"

if [ -f "$BOOT_DIR/rootfs.img" ]; then
    cp "$BOOT_DIR/rootfs.img" "$ISO_DIR/boot/"
    ok "rootfs.img staged"
else
    warn "rootfs.img not found — switch_root will not work"
fi

# grub.cfg — read from grub/ (NOT from iso/ which was just deleted)
if [ -f "$GRUB_SRC/grub.cfg" ]; then
    cp "$GRUB_SRC/grub.cfg" "$ISO_DIR/boot/grub/"
    ok "grub.cfg staged from $GRUB_SRC/grub.cfg"
else
    warn "grub/grub.cfg not found — generating minimal fallback grub.cfg"
    warn "Create $GRUB_SRC/grub.cfg to use a custom GRUB configuration."
    mkdir -p "$GRUB_SRC"
    cat > "$ISO_DIR/boot/grub/grub.cfg" <<'GRUBEOF'
set timeout=10
set default=0
insmod all_video
insmod gfxterm
insmod png
set gfxmode=1024x768,auto
terminal_output gfxterm
if background_image /boot/grub/nextOS2.png ; then true ; fi
menuentry "NextOS" {
    linux  /boot/vmlinuz root=/dev/ram0 rw quiet nextos.rootfs=/boot/rootfs.img
    initrd /boot/initramfs.img
}
menuentry "NextOS (Verbose)" {
    linux  /boot/vmlinuz root=/dev/ram0 rw nextos.rootfs=/boot/rootfs.img
    initrd /boot/initramfs.img
}
GRUBEOF
    # Also save a copy to grub/ so it becomes the source going forward
    cp "$ISO_DIR/boot/grub/grub.cfg" "$GRUB_SRC/grub.cfg"
    ok "grub.cfg generated and saved to $GRUB_SRC/grub.cfg"
fi

if [ -d "$GRUB_SRC/themes/nextos" ]; then
    cp -r "$GRUB_SRC/themes/nextos/." "$ISO_DIR/boot/grub/themes/nextos/"
    ok "GRUB theme staged"
else
    warn "GRUB theme not found at $GRUB_SRC/themes/nextos"
fi

if [ -f "$BANNER_SRC" ]; then
    cp "$BANNER_SRC" "$ISO_DIR/boot/grub/"
    [ -d "$ISO_DIR/boot/grub/themes/nextos" ] && \
        cp "$BANNER_SRC" "$ISO_DIR/boot/grub/themes/nextos/"
    ok "Banner image staged"
else
    warn "Banner not found at $BANNER_SRC"
fi

UNICODE_FONT=""
for f in /usr/share/grub/unicode.pf2 \
         /usr/share/grub2/unicode.pf2 \
         /boot/grub/fonts/unicode.pf2; do
    [ -f "$f" ] && UNICODE_FONT="$f" && break
done
if [ -n "$UNICODE_FONT" ]; then
    cp "$UNICODE_FONT" "$ISO_DIR/boot/grub/fonts/"
    ok "GRUB unicode font staged"
else
    warn "unicode.pf2 not found — install grub-common"
fi

info "Running grub-mkrescue..."
grub-mkrescue \
    --output="$ISO_OUT" \
    "$ISO_DIR" \
    -- \
    -volid "NEXTOS"

ok "ISO created → $ISO_OUT ($(du -sh "$ISO_OUT" | cut -f1))"

# =============================================================
# Summary
# =============================================================
echo ""
echo -e "${BOLD}${GREEN}========================================"
echo "   NextOS build complete!"
echo -e "========================================${RESET}"
echo ""
echo "  ISO:        $ISO_OUT"
echo "  Kernel:     $BOOT_DIR/vmlinuz"
echo "  initramfs:  $BOOT_DIR/initramfs.img"
[ -f "$BOOT_DIR/rootfs.img" ] && \
echo "  rootfs:     $BOOT_DIR/rootfs.img"
echo ""
echo "  Test with QEMU:"
echo "    qemu-system-x86_64 -m 512M -cdrom $ISO_OUT -boot d"
echo ""
echo "  Test with VirtualBox:"
echo "    See build/setup_virtualbox.sh"
echo ""
