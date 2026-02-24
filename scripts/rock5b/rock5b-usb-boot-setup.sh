#!/bin/bash
#
# rock5b-usb-boot-setup.sh
# ========================
# Interactive script for setting up USB boot on the Radxa Rock 5B
# - Checks the current state of the SPI flash
# - Flashes a U-Boot bootloader to SPI if needed
# - Configures the boot order (USB before SD/eMMC)
#
# Prerequisite: Running Armbian on SD card (Vendor Kernel 6.x)
# NO serial access required.
#
# Usage: sudo bash rock5b-usb-boot-setup.sh
#

set -euo pipefail

# ============================================================
# Configuration
# ============================================================
# Radxa official SPI image (URL is downloaded if needed)
RADXA_SPI_IMAGE_URL="https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img"
SPI_DOWNLOAD_DIR="/tmp/rock5b-spi"

# DTB overlay path and overlay names for SPI flash
DTB_OVERLAY_DIR="/boot/dtb/rockchip/overlay"
SPI_OVERLAY_NAMES=("rk3588-spi-flash" "rock-5b-spi-flash" "spi-flash")

# Armbian SPI image search paths
ARMBIAN_SPI_CANDIDATES=(
    "/usr/lib/linux-u-boot-*/u-boot-rockchip-spi.bin"
    "/usr/lib/u-boot/rock-5b/u-boot-rockchip-spi.bin"
    "/usr/share/armbian/u-boot/rock-5b/u-boot-rockchip-spi.bin"
)

# SPI flash dd block size (bytes)
SPI_DD_BLOCK_SIZE=4096

# Boot order
DEFAULT_BOOT_ORDER="mmc1 nvme mmc0 scsi usb pxe dhcp spi"
USB_FIRST_BOOT_ORDER="usb mmc1 nvme mmc0 scsi pxe dhcp spi"

# U-Boot environment configuration (Armbian Rock 5B)
UBOOT_ENV_OFFSET="0xc00000"      # 12 MB into 16 MB SPI
UBOOT_ENV_SIZE="0x20000"         # 128 KB
UBOOT_ENV_SECTOR_SIZE="0x1000"   # 4 KB erase block

# lsblk output limit
LSBLK_DISPLAY_LIMIT=30

# ============================================================
# Colors and helper functions
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC}  $*"; }
header()  { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}\n"; }
ask()     { echo -en "${YELLOW}» $* ${NC}"; }

confirm() {
    local prompt="${1:-Continue?}"
    ask "$prompt [y/N]: "
    read -r answer
    [[ "$answer" =~ ^[jJyY]$ ]]
}

pause() {
    echo ""
    ask "Press Enter to continue..."
    read -r
}

# ============================================================
# Root check
# ============================================================
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root!"
    echo "  → sudo bash $0"
    exit 1
fi

# grep -P (Perl regex) is required (e.g. for mtdinfo parsing)
if ! echo "test123" | grep -oP '\K[0-9]+' &>/dev/null; then
    err "grep does not support Perl regex (-P)."
    err "Please install GNU grep: apt-get install grep"
    exit 1
fi

# ============================================================
# Cleanup-Trap
# ============================================================
CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        rm -f "$f"
    done
}
trap cleanup EXIT

# ============================================================
# Board detection
# ============================================================
header "Step 1: System check"

info "Checking board type..."

BOARD_NAME=""
if [[ -f /proc/device-tree/model ]]; then
    BOARD_NAME=$(tr -d '\0' < /proc/device-tree/model)
    ok "Board detected: ${BOLD}$BOARD_NAME${NC}"
else
    warn "Could not read board model."
fi

if ! echo "$BOARD_NAME" | grep -qi "rock.5b\|rk3588"; then
    warn "This script is intended for the Radxa Rock 5B (RK3588)."
    warn "Detected board: $BOARD_NAME"
    if ! confirm "Continue anyway?"; then
        echo "Aborted."
        exit 0
    fi
fi

# Kernel info
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"

# ============================================================
# Check if Armbian
# ============================================================
if [[ -f /etc/armbian-release ]]; then
    source /etc/armbian-release 2>/dev/null || true
    ok "Armbian release: ${BOARD:-unknown} / ${BRANCH:-unknown} / ${VERSION:-unknown}"
else
    warn "No Armbian release file found. Is this really Armbian?"
    if ! confirm "Continue anyway?"; then
        exit 0
    fi
fi

# ============================================================
# SPI flash status
# ============================================================
header "Step 2: Check SPI flash"

SPI_MTD=""
SPI_SIZE=0
SPI_EMPTY=true

info "Searching for MTD devices (SPI flash)..."

if [[ -e /dev/mtd0 ]]; then
    ok "/dev/mtd0 found."

    # Read MTD info
    if [[ -f /proc/mtd ]]; then
        echo ""
        info "MTD partitions:"
        cat /proc/mtd
        echo ""
    fi

    SPI_MTD="/dev/mtd0"

    # Determine size
    if command -v mtdinfo &>/dev/null; then
        SPI_SIZE=$(mtdinfo /dev/mtd0 2>/dev/null | grep "Amount of eraseblocks" | head -1 | grep -oP '\(\K[0-9]+' || echo "0")
        if [[ "$SPI_SIZE" -gt 0 ]]; then
            info "SPI flash size: approx. $((SPI_SIZE / 1024 / 1024)) MB ($SPI_SIZE bytes)"
        fi
    fi

    # Check if SPI flash is empty (only 0xFF bytes = empty)
    info "Checking whether SPI flash contains data (reading first 4 KB)..."
    FIRST_BYTES=$(dd if=/dev/mtd0ro bs=$SPI_DD_BLOCK_SIZE count=1 2>/dev/null | xxd -p | tr -d '\n')

    # Check if everything is FF (= empty)
    CLEAN_BYTES="${FIRST_BYTES//f/}"
    if [[ -z "$CLEAN_BYTES" ]]; then
        SPI_EMPTY=true
        warn "SPI flash appears to be EMPTY (only 0xFF)."
    else
        SPI_EMPTY=false
        ok "SPI flash contains data (bootloader present)."

        # Try to find U-Boot signature
        if echo "$FIRST_BYTES" | grep -q "3b8cfc00\|55424f4f"; then
            info "Detected: Looks like an RK3588 bootloader."
        fi
    fi
else
    warn "/dev/mtd0 not found!"
    echo ""
    info "Possible causes:"
    info "  - SPI flash is not enabled in the device tree"
    info "  - SPI overlay is missing"
    echo ""
    info "Checking available overlays..."

    # Search for SPI flash overlay
    OVERLAY_DIR="$DTB_OVERLAY_DIR"
    if [[ -d "$OVERLAY_DIR" ]]; then
        SPI_OVERLAYS=$(find "$OVERLAY_DIR" -maxdepth 1 -type f \( -name "*spi*" -o -name "*flash*" \) 2>/dev/null || true)
        if [[ -n "$SPI_OVERLAYS" ]]; then
            info "Found SPI overlays:"
            echo "$SPI_OVERLAYS" | while read -r f; do echo "    $f"; done
        fi
    fi

    # Also check in armbianEnv.txt
    if [[ -f /boot/armbianEnv.txt ]]; then
        info "Current armbianEnv.txt overlays:"
        grep "^overlays=" /boot/armbianEnv.txt 2>/dev/null || echo "    (no overlays set)"
    fi

    echo ""
    warn "Without an MTD device the SPI flash cannot be flashed directly."
    info "Options:"
    info "  1) Enable SPI flash overlay in /boot/armbianEnv.txt and reboot"
    info "  2) Flash via Maskrom mode (USB-OTG + PC)"
    echo ""

    if [[ -f /boot/armbianEnv.txt ]]; then
        # Try to enable SPI flash overlay automatically
        FOUND_SPI_OVERLAY=""
        for ov in "${SPI_OVERLAY_NAMES[@]}"; do
            if [[ -f "$OVERLAY_DIR/${ov}.dtbo" ]]; then
                FOUND_SPI_OVERLAY="$ov"
                break
            fi
        done

        if [[ -n "$FOUND_SPI_OVERLAY" ]]; then
            info "Found SPI overlay: $FOUND_SPI_OVERLAY"
            if confirm "Enable the SPI flash overlay? (Reboot required)"; then
                CURRENT_OVERLAYS=$(grep "^overlays=" /boot/armbianEnv.txt 2>/dev/null | cut -d= -f2 || true)
                if echo "$CURRENT_OVERLAYS" | grep -qw "$FOUND_SPI_OVERLAY"; then
                    ok "Overlay '$FOUND_SPI_OVERLAY' is already enabled."
                elif [[ -n "$CURRENT_OVERLAYS" ]]; then
                    sed -i "s/^overlays=.*/overlays=$CURRENT_OVERLAYS $FOUND_SPI_OVERLAY/" /boot/armbianEnv.txt
                else
                    echo "overlays=$FOUND_SPI_OVERLAY" >> /boot/armbianEnv.txt
                fi
                ok "Overlay added. Please reboot and run the script again."
                info "  → sudo reboot"
                exit 0
            fi
        else
            warn "No matching SPI flash overlay found."
            info "Trying alternatively whether mtdblock device exists..."
            if [[ -e /dev/mtdblock0 ]]; then
                ok "/dev/mtdblock0 exists! Continuing..."
                SPI_MTD="/dev/mtdblock0"
            else
                err "No SPI flash access possible. Please check your setup."
                info "Note: Some Armbian images do not enable SPI flash by default."
                info "You can try:"
                info "  modprobe spi-rockchip-sfc"
                info "  ... and then run the script again."
                exit 1
            fi
        fi
    fi
fi

pause

# ============================================================
# Step 3: Analyse current bootloader / obtain U-Boot SPI image
# ============================================================
header "Step 3: U-Boot SPI image"

UBOOT_SPI_IMG=""

# Check whether Armbian ships an SPI image
info "Searching for existing U-Boot SPI images..."

shopt -s nullglob
for pattern in "${ARMBIAN_SPI_CANDIDATES[@]}"; do
    # shellcheck disable=SC2206  # intentional glob expansion
    candidates=($pattern)
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            UBOOT_SPI_IMG="$candidate"
            ok "Armbian SPI image found: $UBOOT_SPI_IMG"
            ls -lh "$UBOOT_SPI_IMG"
            break 2
        fi
    done
done
shopt -u nullglob

if [[ -z "$UBOOT_SPI_IMG" ]]; then
    warn "No pre-installed SPI image found."
    echo ""
    info "Options:"
    info "  1) Download official Radxa SPI image"
    info "  2) Specify custom image (path)"
    info "  3) Abort"
    echo ""
    ask "Choice [1/2/3]: "
    read -r choice

    case "$choice" in
        1)
            info "Downloading official Radxa SPI image..."
            SPI_URL="$RADXA_SPI_IMAGE_URL"
            DOWNLOAD_DIR="$SPI_DOWNLOAD_DIR"
            mkdir -p "$DOWNLOAD_DIR"

            if command -v wget &>/dev/null; then
                wget -O "$DOWNLOAD_DIR/rock-5b-spi-image.img" "$SPI_URL" || {
                    err "Download failed!"
                    info "Please download the image manually:"
                    info "  $SPI_URL"
                    info "Then run the script again with option 2."
                    exit 1
                }
            elif command -v curl &>/dev/null; then
                curl -L -o "$DOWNLOAD_DIR/rock-5b-spi-image.img" "$SPI_URL" || {
                    err "Download failed!"
                    exit 1
                }
            else
                err "Neither wget nor curl is available!"
                exit 1
            fi
            UBOOT_SPI_IMG="$DOWNLOAD_DIR/rock-5b-spi-image.img"
            ok "Download successful: $UBOOT_SPI_IMG"
            ;;
        2)
            ask "Path to SPI image: "
            read -r custom_path
            if [[ -f "$custom_path" ]]; then
                UBOOT_SPI_IMG="$custom_path"
                ok "Image: $UBOOT_SPI_IMG"
            else
                err "File not found: $custom_path"
                exit 1
            fi
            ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

echo ""
info "Image to flash:"
ls -lh "$UBOOT_SPI_IMG"

pause

# ============================================================
# Step 4: Write SPI flash
# ============================================================
header "Step 4: Write SPI flash"

if [[ "$SPI_EMPTY" == false ]]; then
    warn "The SPI flash already contains data!"
    info "The existing bootloader will be overwritten."
fi

echo ""
echo -e "${RED}${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}  ║  WARNING: Flash operation!                   ║${NC}"
echo -e "${RED}${BOLD}  ║                                              ║${NC}"
echo -e "${RED}${BOLD}  ║  - Do NOT interrupt the process              ║${NC}"
echo -e "${RED}${BOLD}  ║  - Ensure stable power supply                ║${NC}"
echo -e "${RED}${BOLD}  ║                                              ║${NC}"
echo -e "${RED}${BOLD}  ║  - A failed flash may require Maskrom        ║${NC}"
echo -e "${RED}${BOLD}  ║    mode to recover                           ║${NC}"
echo -e "${RED}${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
echo ""

if ! confirm "Write SPI flash NOW?"; then
    echo "Aborted."
    exit 0
fi

# Check whether armbian-install is available (preferred)
if command -v armbian-install &>/dev/null && [[ -n "$UBOOT_SPI_IMG" ]]; then
    info "armbian-install is available."
    info "Using direct flash method anyway for more control."
fi

# Direct flash via MTD
if [[ -c "$SPI_MTD" ]]; then
    info "Flashing via MTD device $SPI_MTD ..."

    # Back up current SPI contents
    info "Creating backup of current SPI flash contents..."
    BACKUP_FILE=$(mktemp /tmp/spi-flash-backup-XXXXXXXX.bin)
    if dd if="${SPI_MTD}ro" of="$BACKUP_FILE" bs=$SPI_DD_BLOCK_SIZE 2>/dev/null; then
        ok "Backup saved: $BACKUP_FILE"
    else
        warn "Backup could not be created (non-critical)."
    fi

    # Flash operation
    if command -v flashcp &>/dev/null; then
        info "Using flashcp..."
        flashcp -v "$UBOOT_SPI_IMG" "$SPI_MTD"
    elif command -v mtd_debug &>/dev/null; then
        info "Using mtd_debug..."
        MTD_SIZE=$(wc -c < "$UBOOT_SPI_IMG")
        mtd_debug erase "$SPI_MTD" 0 "$MTD_SIZE" || {
            err "mtd_debug erase failed! Flash operation aborted."
            err "Backup is located at: $BACKUP_FILE"
            exit 1
        }
        mtd_debug write "$SPI_MTD" 0 "$MTD_SIZE" "$UBOOT_SPI_IMG" || {
            err "mtd_debug write failed! SPI may be corrupted."
            err "Backup is located at: $BACKUP_FILE"
            exit 1
        }
    else
        info "Using dd (fallback)..."
        # Erase first (fill with 0xFF)
        flash_erase "$SPI_MTD" 0 0 2>/dev/null || {
            warn "flash_erase not available, trying direct write..."
        }
        dd if="$UBOOT_SPI_IMG" of="$SPI_MTD" bs=$SPI_DD_BLOCK_SIZE conv=fsync 2>/dev/null
    fi

    # Verification
    info "Verifying flash contents..."
    VERIFY_FILE=$(mktemp /tmp/spi-verify-XXXXXXXX.bin)
    CLEANUP_FILES+=("$VERIFY_FILE")
    IMG_SIZE=$(wc -c < "$UBOOT_SPI_IMG")
    dd if="${SPI_MTD}ro" of="$VERIFY_FILE" bs=$SPI_DD_BLOCK_SIZE count=$(( (IMG_SIZE + 4095) / 4096 )) 2>/dev/null
    truncate -s "$IMG_SIZE" "$VERIFY_FILE"

    if cmp -s "$UBOOT_SPI_IMG" "$VERIFY_FILE"; then
        ok "Verification successful! SPI flash was written correctly."
    else
        err "Verification FAILED!"
        err "The written data does not match the image."
        err "Backup is located at: $BACKUP_FILE"
        warn "Please do NOT reboot and investigate the problem first."
        exit 1
    fi

elif [[ -b "$SPI_MTD" ]]; then
    info "Flashing via block device $SPI_MTD ..."
    dd if="$UBOOT_SPI_IMG" of="$SPI_MTD" bs=$SPI_DD_BLOCK_SIZE conv=fsync
    sync
    ok "Flash operation completed (no verification via block device)."
else
    err "No suitable MTD device found!"
    exit 1
fi

ok "SPI flash written successfully!"
echo ""

pause

# ============================================================
# Step 5: Configure boot order
# ============================================================
header "Step 5: Configure boot order"

info "Goal: USB should be checked BEFORE SD card and eMMC."
echo ""

# Check whether fw_printenv / fw_setenv is available
FW_ENV_AVAILABLE=false
if command -v fw_printenv &>/dev/null; then
    FW_ENV_AVAILABLE=true
    ok "fw_printenv / fw_setenv is available."
else
    warn "fw_printenv not found. Installing libubootenv-tool..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        if apt-get install -y -qq libubootenv-tool 2>/dev/null; then
            FW_ENV_AVAILABLE=true
            ok "libubootenv-tool installed."
        else
            warn "Installation failed. Trying u-boot-tools..."
            if apt-get install -y -qq u-boot-tools 2>/dev/null; then
                FW_ENV_AVAILABLE=true
                ok "u-boot-tools installed."
            fi
        fi
    fi
fi

# Check/create fw_env.config
if [[ "$FW_ENV_AVAILABLE" == true ]]; then
    if [[ ! -f /etc/fw_env.config ]]; then
        warn "/etc/fw_env.config does not exist. Creating default configuration..."
        info "For Rock 5B with SPI flash U-Boot environment (Armbian):"
        # Armbian-specific values from config/boards/rock-5b.conf:
        #   CONFIG_ENV_IS_IN_SPI_FLASH=y
        #   CONFIG_ENV_OFFSET=0xc00000  (12 MB into 16 MB SPI)
        #   CONFIG_ENV_SIZE=0x20000     (128 KB)
        #   CONFIG_ENV_SECT_SIZE_AUTO=y (4 KB erase block, Macronix MX25U12835F)
        # NOTE: Upstream U-Boot and official Radxa builds may use different
        # offsets (e.g. CONFIG_ENV_IS_IN_MMC instead of SPI)!
        cat > /etc/fw_env.config << EOF
# Device name    Device offset    Env. size    Flash sector size
# Armbian Rock 5B: ENV in SPI NOR @ 12 MB, 128 KB, 4 KB sectors
/dev/mtd0        $UBOOT_ENV_OFFSET         $UBOOT_ENV_SIZE      $UBOOT_ENV_SECTOR_SIZE
EOF
        ok "/etc/fw_env.config created."
    fi

    echo ""
    info "Trying to read current U-Boot environment variables..."
    echo ""

    CURRENT_BOOT_TARGETS=""
    if fw_printenv boot_targets 2>/dev/null; then
        CURRENT_BOOT_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2)
        echo ""
        ok "Current boot_targets: $CURRENT_BOOT_TARGETS"
    else
        warn "Could not read boot_targets."
        info "This may mean:"
        info "  - The environment offsets are incorrect"
        info "  - U-Boot is using compile-time defaults (no saved environment)"
        info "  - The SPI flash was just written and has no environment yet"
        echo ""
        info "Default boot order for Armbian Rock 5B:"
        info "  mmc1 nvme mmc0 scsi usb pxe dhcp spi"
        CURRENT_BOOT_TARGETS="$DEFAULT_BOOT_ORDER"
    fi

    echo ""
    info "Desired new order (USB first):"
    NEW_BOOT_TARGETS="$USB_FIRST_BOOT_ORDER"
    echo -e "  ${GREEN}$NEW_BOOT_TARGETS${NC}"
    echo ""
    info "Explanation:"
    info "  usb   = USB mass storage (your USB drive)"
    info "  mmc1  = SD card"
    info "  nvme  = NVMe SSD"
    info "  mmc0  = eMMC"
    info "  scsi  = SATA/SCSI"
    info "  pxe   = Network boot (PXE)"
    info "  dhcp  = Network boot (DHCP)"
    info "  spi   = SPI NOR flash"
    echo ""

    ask "Enter custom order or press Enter for default: "
    read -r custom_order
    if [[ -n "$custom_order" ]]; then
        NEW_BOOT_TARGETS="$custom_order"
        info "Using: $NEW_BOOT_TARGETS"
    fi

    echo ""
    if confirm "Set boot order to '$NEW_BOOT_TARGETS'?"; then
        if fw_setenv boot_targets "$NEW_BOOT_TARGETS" 2>/dev/null; then
            ok "boot_targets set successfully!"

            # Verification
            VERIFY_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2 || true)
            if [[ "$VERIFY_TARGETS" == "$NEW_BOOT_TARGETS" ]]; then
                ok "Verified: $VERIFY_TARGETS"
            else
                warn "Verification unclear. Please check after reboot."
            fi
        else
            err "fw_setenv failed!"
            echo ""
            info "Alternative: Configure boot order via /boot/armbianEnv.txt."
        fi
    fi
else
    warn "fw_printenv/fw_setenv not available."
fi

# ============================================================
# Alternative/supplement: armbianEnv.txt
# ============================================================
echo ""
info "Checking /boot/armbianEnv.txt as supplementary configuration..."

if [[ -f /boot/armbianEnv.txt ]]; then
    echo ""
    info "Current /boot/armbianEnv.txt:"
    echo "  ─────────────────────────────"
    sed 's/^/  │ /' /boot/armbianEnv.txt
    echo "  ─────────────────────────────"
    echo ""

    # Check whether rootdev needs to be adjusted
    info "If your root filesystem is on the USB drive,"
    info "'rootdev' in /boot/armbianEnv.txt must be updated."
    echo ""

    # Show USB devices
    info "Detected block devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,FSTYPE 2>/dev/null | head -$LSBLK_DISPLAY_LIMIT
    echo ""

    if confirm "Set rootdev in armbianEnv.txt to a USB device?"; then
        # Filter USB devices
        info "Available USB storage:"
        USB_DEVS=$(lsblk -dpno NAME,SIZE,TRAN 2>/dev/null | grep "usb" || true)
        if [[ -z "$USB_DEVS" ]]; then
            warn "No USB storage device detected."
            info "Plug in the USB drive and restart this step."
        else
            echo "$USB_DEVS"
            echo ""
            ask "Device for rootdev (e.g. /dev/sda1): "
            read -r usb_rootdev
            if [[ -b "$usb_rootdev" ]]; then
                # Backup
                cp /boot/armbianEnv.txt /boot/armbianEnv.txt.bak
                ok "Backup created: /boot/armbianEnv.txt.bak"

                if grep -q "^rootdev=" /boot/armbianEnv.txt; then
                    sed -i "s|^rootdev=.*|rootdev=$usb_rootdev|" /boot/armbianEnv.txt
                else
                    echo "rootdev=$usb_rootdev" >> /boot/armbianEnv.txt
                fi
                ok "rootdev set to: $usb_rootdev"
            else
                warn "Device '$usb_rootdev' does not exist. Skipping."
            fi
        fi
    fi
fi

pause

# ============================================================
# Summary
# ============================================================
header "Summary"

echo -e "${GREEN}Actions performed:${NC}"
echo ""

if [[ -n "$UBOOT_SPI_IMG" ]]; then
    echo -e "  ✓ U-Boot written to SPI flash"
    echo -e "    Image: $UBOOT_SPI_IMG"
fi

if [[ "$FW_ENV_AVAILABLE" == true ]]; then
    echo -e "  ✓ Boot order configured"
    FINAL_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2 || echo "(could not be read)")
    echo -e "    boot_targets: $FINAL_TARGETS"
fi

if [[ -f /boot/armbianEnv.txt.bak ]]; then
    echo -e "  ✓ armbianEnv.txt updated (backup: armbianEnv.txt.bak)"
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "  1. Make sure your USB drive contains a bootable system"
echo "     (e.g. flashed with Armbian via dd or Etcher)"
echo ""
echo "  2. Plug in the USB drive"
echo ""
echo "  3. Reboot:"
echo "     → sudo reboot"
echo ""
echo "  4. The system should now boot from the USB drive"
echo "     (provided a valid system is present on it)"
echo ""
echo -e "${YELLOW}Troubleshooting:${NC}"
echo ""
echo "  - If the system does not boot from USB:"
echo "    → Check whether the USB drive is correctly formatted/flashed"
echo "    → Try a USB 2.0 port (better U-Boot support)"
echo "    → Remove the SD card and use only the USB drive"
echo ""
echo "  - If the system no longer boots at all:"
echo "    → Insert an SD card with a working Armbian"
echo "    → In an emergency: Maskrom mode (golden button) + rkdeveloptool"
echo "    → SPI flash backup: ${BACKUP_FILE:-not created}"
echo ""
echo "  - Reset boot order:"
echo "    → sudo fw_setenv boot_targets \"mmc1 nvme mmc0 scsi usb pxe dhcp spi\""
echo ""

ok "Script completed. Good luck!"
