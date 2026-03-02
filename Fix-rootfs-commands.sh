#!/bin/bash
# =============================================================
#  NextOS — Complete Fix for Empty Rootfs (v2 - Dynamic)
#  Auto-detects all busybox applets instead of hardcoded list
#  Run from your NextOS project root directory
# =============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()  { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }

echo -e "\n${BOLD}${GREEN}========================================"
echo "  NextOS Complete Rootfs Fix (v2)"
echo "  Dynamic busybox applet detection"
echo -e "========================================${RESET}\n"

# ── Step 1: Verify busybox exists ──────────────────────────────
info "Checking busybox..."
if [ ! -f initramfs/bin/busybox ]; then
    die "initramfs/bin/busybox not found. Download it first:\n  wget https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox -O initramfs/bin/busybox\n  chmod +x initramfs/bin/busybox"
fi
ok "Busybox found"

# ── Step 2: Create rootfs directories ──────────────────────────
info "Creating rootfs directory structure..."
mkdir -p rootfs/{bin,sbin,lib,lib64,dev,proc,sys,etc,tmp,run,var/log,home/user,root}
mkdir -p rootfs/usr/{bin,sbin}
ok "Directory structure created"

# ── Step 3: Copy bash and libraries ────────────────────────────
info "Installing bash..."
cp /bin/bash rootfs/bin/bash
ln -sf bash rootfs/bin/sh

# Copy bash libraries
ldd /bin/bash | grep -oP '/[^ ]+ \(' | sed 's/ ($//' | while read lib; do
    [ -f "$lib" ] || continue
    dest="rootfs$(dirname "$lib")"
    mkdir -p "$dest"
    cp -L "$lib" "$dest/" 2>/dev/null || true
done

# Copy dynamic linker
LINKER=$(ldd /bin/bash | grep -oP '/lib.*ld-linux.*\.so\.[0-9]+' | head -1)
if [ -n "$LINKER" ]; then
    mkdir -p "rootfs$(dirname "$LINKER")"
    cp -L "$LINKER" "rootfs$(dirname "$LINKER")/"
fi
ok "Bash installed with libraries"

# ── Step 4: Copy busybox to rootfs ─────────────────────────────
info "Installing busybox in rootfs..."
cp initramfs/bin/busybox rootfs/bin/busybox
chmod +x rootfs/bin/busybox

# ── Step 5: Auto-detect and create ALL busybox symlinks ───────
info "Querying busybox for available applets..."

BUSYBOX_BIN="rootfs/bin/busybox"

# Verify busybox works
if ! "$BUSYBOX_BIN" --help >/dev/null 2>&1; then
    die "busybox binary is not executable or corrupt"
fi

# Get list of all applets
APPLET_LIST=$("$BUSYBOX_BIN" --list 2>/dev/null)

if [ -z "$APPLET_LIST" ]; then
    die "busybox --list returned empty. Binary may be corrupt."
fi

TOTAL_APPLETS=$(echo "$APPLET_LIST" | wc -l)
ok "Found $TOTAL_APPLETS applets in busybox"

# Define which applets belong in /sbin (system administration commands)
SBIN_APPLETS="
    acpid adjtimex arp blkid blockdev brctl chroot
    depmod devmem dhcprelay ether-wake
    fdisk findfs freeramdisk fsck fsck.ext2 fsck.ext3 fsck.ext4
    getty halt hdparm hwclock
    ifconfig ifdown ifenslave ifplugd ifup
    init insmod ip ipcalc iplink ipneigh iproute iprule iptunnel
    klogd ldconfig loadkmap losetup
    mdev mkdosfs mke2fs mkfs.ext2 mkfs.ext3 mkfs.ext4 mkfs.vfat
    mknod mkswap modinfo modprobe
    nameif nbd-client pivot_root poweroff
    raidautorun reboot rmmod route runlevel
    setconsole shutdown slattach start-stop-daemon sulogin
    swapoff swapon switch_root sysctl syslogd
    tc tunctl udhcpc udhcpd vconfig zcip
"

info "Creating symlinks dynamically..."

BIN_COUNT=0
SBIN_COUNT=0
SKIPPED=0

while IFS= read -r applet; do
    [ -z "$applet" ] && continue
    
    # Determine target directory
    if echo "$SBIN_APPLETS" | grep -Fqw -- "$applet"; then
        TARGET_DIR="rootfs/sbin"
        LINK_TARGET="../bin/busybox"
        TARGET_PATH="$TARGET_DIR/$applet"
        SBIN_COUNT=$((SBIN_COUNT + 1))
    else
        TARGET_DIR="rootfs/bin"
        LINK_TARGET="busybox"
        TARGET_PATH="$TARGET_DIR/$applet"
        BIN_COUNT=$((BIN_COUNT + 1))
    fi
    
    # Skip if a real binary already exists (preserve it)
    if [ -f "$TARGET_PATH" ] && [ ! -L "$TARGET_PATH" ]; then
        info "  Preserving real binary: $TARGET_PATH"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    
    # Create the symlink
    ln -sf "$LINK_TARGET" "$TARGET_PATH" 2>/dev/null || true
    
done <<< "$APPLET_LIST"

ok "Created $BIN_COUNT symlinks in /bin"
ok "Created $SBIN_COUNT symlinks in /sbin"
[ "$SKIPPED" -gt 0 ] && info "Preserved $SKIPPED existing binaries"

# ── Step 6: Verify critical commands exist ────────────────────
info "Verifying critical commands..."
CRITICAL_CMDS="sh mount umount switch_root losetup modprobe mknod sleep cat grep ls"
MISSING=""

for cmd in $CRITICAL_CMDS; do
    if [ -e "rootfs/bin/$cmd" ] || [ -e "rootfs/sbin/$cmd" ]; then
        ok "  ✓ $cmd"
    else
        warn "  ✗ $cmd MISSING"
        MISSING="$MISSING $cmd"
    fi
done

if [ -n "$MISSING" ]; then
    warn "Some critical commands are missing:$MISSING"
    warn "This may indicate an incomplete busybox build"
fi

# ── Step 7: Create /sbin/init ──────────────────────────────────
info "Creating rootfs/sbin/init..."
cat > rootfs/sbin/init << 'INITEOF'
#!/bin/bash
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
export HOME=/root
export TERM=linux

echo ""
echo "NextOS — Rootfs Init (PID $$)"
echo "Kernel: $(uname -r)"
echo ""

# Try to keep root writable when possible.
# If booted from ISO without overlay this may legitimately stay read-only.
if mount -o remount,rw / 2>/dev/null; then
    echo "Root filesystem remounted read-write"
else
    echo "Root filesystem is read-only (check initramfs overlay setup)"
fi

# Mount runtime filesystems
mount -t tmpfs tmpfs /run 2>/dev/null && echo "Mounted /run"
mount -t tmpfs tmpfs /tmp 2>/dev/null && echo "Mounted /tmp"
chmod 1777 /tmp 2>/dev/null

# Set hostname
if [ -f /etc/hostname ]; then
    hostname -F /etc/hostname 2>/dev/null
else
    hostname nextos 2>/dev/null
fi

echo ""
echo "System ready. Available commands:"
echo "  $(ls /bin | wc -l) binaries in /bin"
echo "  $(ls /sbin | wc -l) binaries in /sbin"
echo ""

# Try Python init if exists
if [ -f /system/init.py ] && command -v python3 >/dev/null 2>&1; then
    echo "Launching Python init system..."
    exec python3 /system/init.py
fi

# Interactive shell — must never exit (PID 1)
echo "Starting interactive shell..."
echo ""

while true; do
    /bin/bash --login </dev/console >/dev/console 2>/dev/console
    echo ""
    echo "Shell exited - restarting in 2s (type 'reboot -f' to shutdown)"
    sleep 2
done
INITEOF

chmod +x rootfs/sbin/init
ok "rootfs/sbin/init created"

# ── Step 8: Create minimal /etc files ──────────────────────────
info "Creating /etc configuration files..."

[ -f rootfs/etc/passwd ] || cat > rootfs/etc/passwd << 'ETCEOF'
root:x:0:0:root:/root:/bin/bash
user:x:1000:1000:NextOS User:/home/user:/bin/bash
ETCEOF

[ -f rootfs/etc/group ] || cat > rootfs/etc/group << 'ETCEOF'
root:x:0:
user:x:1000:
ETCEOF

[ -f rootfs/etc/hostname ] || echo "nextos" > rootfs/etc/hostname

[ -f rootfs/etc/profile ] || cat > rootfs/etc/profile << 'ETCEOF'
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export HOME=/root
export TERM=linux
ETCEOF

ok "/etc files created"

# ── Step 9: Verify everything ──────────────────────────────────
echo ""
info "Final verification:"
ERRORS=0

[ -x rootfs/bin/bash ] && ok "✓ bash" || { warn "✗ bash"; ERRORS=1; }
[ -L rootfs/bin/sh ] && ok "✓ sh symlink" || { warn "✗ sh symlink"; ERRORS=1; }
[ -x rootfs/bin/busybox ] && ok "✓ busybox" || { warn "✗ busybox"; ERRORS=1; }
[ -x rootfs/sbin/init ] && ok "✓ /sbin/init" || { warn "✗ /sbin/init"; ERRORS=1; }
[ -f rootfs/etc/hostname ] && ok "✓ /etc/hostname" || { warn "✗ /etc/hostname"; ERRORS=1; }

SHEBANG=$(head -1 rootfs/sbin/init)
if echo "$SHEBANG" | grep -q '^#!/bin/bash$'; then
    ok "✓ /sbin/init shebang correct"
else
    warn "✗ /sbin/init shebang: $SHEBANG"
    ERRORS=1
fi

# ── Summary ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}========================================"
echo "  Rootfs Preparation Complete"
echo -e "========================================${RESET}"
echo ""
echo "Rootfs contents:"
echo "  $BIN_COUNT commands in /bin"
echo "  $SBIN_COUNT commands in /sbin"
echo "  Total: $TOTAL_APPLETS busybox applets"
echo "  Size: $(du -sh rootfs/ | cut -f1)"
echo ""

if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ All checks passed${RESET}"
    echo ""
    echo "Next step: Rebuild rootfs.img"
    echo ""
    echo "  sudo rm boot/rootfs.img"
    echo "  sudo ./full-build.sh --skip-kernel"
    echo ""
    echo "Then boot the ISO — you'll have a fully functional shell with ALL busybox commands."
    echo ""
    echo "Available commands will include:"
    echo "  - All standard Unix tools (ls, cat, grep, find, tar, etc.)"
    echo "  - Text editors (vi)"
    echo "  - Network tools (ping, wget, ifconfig)"
    echo "  - System admin (mount, reboot, poweroff, ifconfig)"
    echo "  - Process management (ps, kill, top)"
else
    echo -e "${RED}${BOLD}✗ Errors found — review above${RESET}"
    exit 1
fi
