#!/bin/bash
###############################################################################
#  rock5b-hw-check.sh
#  Checks NPU & GPU on a Rock 5B running Armbian (RK3588)
#
#  Usage:  sudo ./rock5b-hw-check.sh [--fix]
#
#  Without --fix:  Diagnosis only (read-only)
#  With    --fix:  Attempts to load missing kernel modules and checks for
#                  harmful overlays
#
#  NPU detection:
#    Vendor kernel (6.1.x, rknpu 0.9.x):
#      DRM subsystem: /dev/dri/renderD129 (platform-fdab0000.npu-render).
#      The old /dev/rknpu* path no longer exists.
#      The vendor DTB already has the NPU with status="okay" — a separate
#      overlay is NOT needed and causes conflicts.
#
#    Mainline kernel 6.18+ (Rocket driver):
#      DRM accel subsystem: /dev/accel/accel0 (rocket.ko, upstream GPL)
#      Userspace: Mesa Teflon TFLite delegate (instead of rknn-toolkit2)
#      Model format: .tflite (instead of .rknn)
#      panthor GPU driver (replaces panfrost for Mali G610 / Valhall)
#
#  Kernel family:
#    Armbian has renamed the RK3588 kernel packages:
#      Old: linux-image-edge-rockchip-rk3588  (6.12.x)
#      New: linux-image-edge-rockchip64       (6.18.x+)
#    Both packages can coexist in the repo.
#
#  CLI kernel switch:
#    armbian-config --cmd KER001                        # interactive TUI selector
#    apt install linux-image-edge-rockchip64 \          # directly via apt
#                linux-dtb-edge-rockchip64
#
#  References:
#    - https://docs.armbian.com/User-Guide_Armbian_overlays/
#    - https://github.com/armbian/linux-rockchip (overlay sources)
#    - https://github.com/Pelochus/ezrknpu (NPU usage)
###############################################################################

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "  ${RED}✘${NC} $*"; }
info() { echo -e "  ${CYAN}ℹ${NC} $*"; }
header() { echo -e "\n${BOLD}══ $* ══${NC}"; }

# ── Configuration ────────────────────────────────────────────────────────────
# Hardware-specific paths (RK3588)
NPU_DRM_DEVICE="/dev/dri/by-path/platform-fdab0000.npu-render"
GPU_DRM_DEVICE="/dev/dri/by-path/platform-display-subsystem-render"
NPU_DEVFREQ_PATH="/sys/class/devfreq/fdab0000.npu"
GPU_UTIL_PATH="/sys/devices/platform/fb000000.gpu/utilisation"
OVERLAY_USER_DIR="/boot/overlay-user"

# Kernel version thresholds
KERNEL_PANTHOR_MIN="6.12"         # Minimum for panthor GPU support
KERNEL_NPU_EXPERIMENTAL_MIN="6.14"  # Experimental NPU support starts here
KERNEL_NPU_STABLE_MIN="6.18"     # Stable NPU support (Rocket driver)

# U-Boot
UBOOT_MIN_YEAR_NVME=202301       # Minimum U-Boot version for reliable NVMe/USB boot
SPI_DD_BLOCK_SIZE=4096            # Block size for SPI flash dd operations (bytes)

# Output
DMESG_NPU_LINES=10               # Number of NPU dmesg lines
DMESG_GPU_LINES=8                 # Number of GPU dmesg lines
MODPROBE_WAIT=1                   # Seconds to wait after modprobe

FIX_MODE=false
[[ "${1:-}" == "--fix" ]] && FIX_MODE=true

ARMBIAN_ENV="/boot/armbianEnv.txt"
REBOOT_NEEDED=false
ISSUES_FOUND=0

###############################################################################
#  Helper functions
###############################################################################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

get_current_overlays() {
    grep -oP '(?<=^overlays=).*' "$ARMBIAN_ENV" 2>/dev/null || true
}

get_user_overlays() {
    grep -oP '(?<=^user_overlays=).*' "$ARMBIAN_ENV" 2>/dev/null || true
}

###############################################################################
#  1. System overview
###############################################################################

header "System Overview"

echo -e "  Hostname:       $(hostname)"
echo -e "  Kernel:         $(uname -r)"
echo -e "  Architecture:   $(uname -m)"

if [[ -f /etc/armbian-release ]]; then
    source /etc/armbian-release 2>/dev/null || true
    echo -e "  Armbian:        ${BOARD_NAME:-?} / ${DISTRIBUTION_CODENAME:-?} / Branch: ${BRANCH:-?}"
    echo -e "  Image:          ${IMAGE_TYPE:-?} / ${LINUXFAMILY:-?}"
else
    warn "/etc/armbian-release not found — is this really Armbian?"
fi

# Estimate kernel type
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | grep -oP '^\d+\.\d+' || echo "0.0")
IS_VENDOR_KERNEL=false
IS_MODERN_MAINLINE=false  # Mainline ≥6.12 with panthor/RKNPU support
if [[ "$KERNEL_VER" == *-vendor-rk35xx ]] || [[ "$KERNEL_VER" == 5.10.* ]] || [[ "$KERNEL_VER" == 6.1.*rk* ]]; then
    ok "Vendor/BSP kernel detected ($KERNEL_VER) — NPU & GPU support expected"
    IS_VENDOR_KERNEL=true
elif [[ "$KERNEL_VER" == 6.1.* ]]; then
    ok "Vendor/BSP kernel detected ($KERNEL_VER) — NPU & GPU support expected"
    IS_VENDOR_KERNEL=true
elif awk "BEGIN {exit !($KERNEL_MAJOR >= $KERNEL_PANTHOR_MIN)}" 2>/dev/null; then
    IS_MODERN_MAINLINE=true
    if awk "BEGIN {exit !($KERNEL_MAJOR >= $KERNEL_NPU_STABLE_MIN)}" 2>/dev/null; then
        ok "Modern mainline kernel ($KERNEL_VER) — ${BOLD}NPU & GPU support expected${NC}"
        info "panthor (GPU) and RKNPU (NPU) are stable in mainline since $KERNEL_NPU_STABLE_MIN"
    elif awk "BEGIN {exit !($KERNEL_MAJOR >= $KERNEL_NPU_EXPERIMENTAL_MIN)}" 2>/dev/null; then
        ok "Mainline kernel ($KERNEL_VER) — NPU & GPU support possible (experimental)"
        info "RKNPU driver in mainline since ~$KERNEL_NPU_EXPERIMENTAL_MIN, panthor since ~$KERNEL_PANTHOR_MIN"
        info "Support is considered stable from ${KERNEL_NPU_STABLE_MIN}+"
    else
        ok "Mainline kernel ($KERNEL_VER) — GPU via panthor expected, NPU may not be available yet"
        info "RKNPU driver only in mainline since ~$KERNEL_NPU_EXPERIMENTAL_MIN"
    fi
else
    warn "Older mainline kernel ($KERNEL_VER) — NPU probably does NOT work"
    warn "GPU limited (panfrost instead of panthor for Mali G610)"
    echo ""
    info "Two options:"
    echo -e "    ${CYAN}1.${NC} Vendor kernel (6.1.x): full NPU+GPU support, Rockchip BSP patches"
    echo -e "       ${CYAN}→ sudo armbian-config --cmd KER001${NC}"
    echo -e "    ${BOLD}${GREEN}2.${NC}${BOLD} Mainline ≥6.18 (recommended):${NC} panthor GPU + RKNPU in mainline, better security"
    echo -e "       ${CYAN}→ sudo armbian-config --cmd KER001${NC}  (select edge/current)"
    ((ISSUES_FOUND++)) || true
fi

###############################################################################
#  1b. SPI Flash & Boot Source
###############################################################################

header "SPI Flash & Boot Source"

# Determine boot source
BOOT_SOURCE_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
BOOT_DISK=""
if [[ -n "$BOOT_SOURCE_DEV" ]]; then
    BOOT_DISK="/dev/$(lsblk -n -o PKNAME "$BOOT_SOURCE_DEV" 2>/dev/null | head -1 | tr -d ' ')"
    case "$BOOT_DISK" in
        /dev/mmcblk*)  BOOT_FROM="eMMC/SD ($BOOT_DISK)" ;;
        /dev/nvme*)    BOOT_FROM="NVMe ($BOOT_DISK)" ;;
        /dev/sd*)      BOOT_FROM="USB/SATA ($BOOT_DISK)" ;;
        /dev/mapper/*|/dev/dm-*)
            # LUKS/LVM — resolve to underlying device
            LUKS_UNDER=$(lsblk -n -o PKNAME "$BOOT_SOURCE_DEV" 2>/dev/null | tail -1 | tr -d ' ')
            if [[ -n "$LUKS_UNDER" ]]; then
                BOOT_DISK="/dev/$LUKS_UNDER"
                case "$BOOT_DISK" in
                    /dev/nvme*)    BOOT_FROM="NVMe via LUKS ($BOOT_DISK)" ;;
                    /dev/mmcblk*)  BOOT_FROM="eMMC/SD via LUKS ($BOOT_DISK)" ;;
                    *)             BOOT_FROM="$BOOT_DISK (LUKS)" ;;
                esac
            else
                BOOT_FROM="$BOOT_SOURCE_DEV"
            fi
            ;;
        *)             BOOT_FROM="$BOOT_DISK" ;;
    esac
    info "Boot source: ${BOLD}${BOOT_FROM}${NC}"

    # ── Where does the boot source come from? ──

    # 1. Kernel command line (root= parameter, passed by bootloader)
    KCMDLINE=$(cat /proc/cmdline 2>/dev/null || true)
    KROOT=$(echo "$KCMDLINE" | grep -oP 'root=\S+' || true)
    if [[ -n "$KROOT" ]]; then
        info "Kernel root=: ${BOLD}${KROOT}${NC}  (passed from U-Boot to kernel)"
    fi

    # 2. U-Boot Environment (boot_targets = scan order)
    if command -v fw_printenv &>/dev/null; then
        BOOT_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$BOOT_TARGETS" ]]; then
            info "U-Boot boot_targets: ${BOLD}${BOOT_TARGETS}${NC}"
        fi
        # devnum/devtype show which device U-Boot actually selected
        UBOOT_DEVTYPE=$(fw_printenv devtype 2>/dev/null | cut -d= -f2 || true)
        UBOOT_DEVNUM=$(fw_printenv devnum 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$UBOOT_DEVTYPE" ]]; then
            info "U-Boot selected device: ${BOLD}${UBOOT_DEVTYPE}${UBOOT_DEVNUM:+ #${UBOOT_DEVNUM}}${NC}"
        fi
    else
        info "fw_printenv not installed — cannot read U-Boot env"
        info "  → apt install u-boot-tools  (for fw_printenv/fw_setenv)"
    fi

    # 3. armbianEnv.txt rootdev (explicit root specification, overrides autodetect)
    if [[ -f "$ARMBIAN_ENV" ]]; then
        ARMBIAN_ROOTDEV=$(grep -oP '(?<=^rootdev=).*' "$ARMBIAN_ENV" 2>/dev/null || true)
        if [[ -n "$ARMBIAN_ROOTDEV" ]]; then
            info "armbianEnv.txt rootdev: ${BOLD}${ARMBIAN_ROOTDEV}${NC}  (explicitly set)"
        fi
    fi

    # 4. DeviceTree boot-device (set by bootloader/firmware)
    DT_BOOT_DEV=$(cat /proc/device-tree/chosen/u-boot,spl-boot-device 2>/dev/null | tr -d '\0' || true)
    if [[ -n "$DT_BOOT_DEV" ]]; then
        info "DeviceTree SPL-Boot-Device: ${BOLD}${DT_BOOT_DEV}${NC}"
    fi

    # 5. List other bootable media
    echo ""
    info "Available boot media:"
    for blk in /sys/class/block/mmcblk[0-9] /sys/class/block/nvme[0-9]n[0-9] /sys/class/block/sd[a-z]; do
        [[ -d "$blk" ]] || continue
        BLK_NAME=$(basename "$blk")
        BLK_SIZE_SECTORS=$(cat "$blk/size" 2>/dev/null || echo "0")
        BLK_SIZE_GB=$(( BLK_SIZE_SECTORS * 512 / 1024 / 1024 / 1024 ))
        [[ "$BLK_SIZE_GB" -eq 0 ]] && continue
        BLK_MODEL=$(cat "$blk/device/model" 2>/dev/null | tr -s ' ' || true)
        BLK_MODEL=${BLK_MODEL:-$(cat "$blk/device/name" 2>/dev/null || echo "?")}
        MARKER=""
        if [[ "/dev/$BLK_NAME" == "$BOOT_DISK" ]] || [[ "$BOOT_DISK" == /dev/${BLK_NAME}* ]]; then
            MARKER=" ${GREEN}← active boot source${NC}"
        fi
        echo -e "      /dev/${BLK_NAME}  ${BLK_SIZE_GB} GB  ${BOLD}${BLK_MODEL}${NC}${MARKER}"
    done

    # ── RK3588 BootROM priority (stage 1: loading bootloader) ──
    echo ""
    info "RK3588 BootROM priority (hardcoded in SoC, not changeable):"
    info "  Determines where the first bootloader (SPL/TPL) is loaded from."
    info "  U-Boot boot_targets (changeable via fw_setenv) then determine where the OS is searched."

    # 1. SPI NOR Flash
    if [[ -b /dev/mtdblock0 ]]; then
        _SPI_MARKER=""
        [[ -n "${DT_BOOT_DEV:-}" ]] && [[ "$DT_BOOT_DEV" == *sfc* || "$DT_BOOT_DEV" == *spi* ]] && _SPI_MARKER=" ${GREEN}← SPL-Boot${NC}"
        echo -e "      ${GREEN}1.${NC} SPI NOR Flash (16 MB)  ${GREEN}✔ present${NC}${_SPI_MARKER}"
    else
        echo -e "      ${YELLOW}1.${NC} SPI NOR Flash (16 MB)  ${RED}✘ not detected${NC}"
    fi

    # 2. eMMC (if populated)
    _EMMC_DEV=""
    for _mmcblk in /sys/class/block/mmcblk[0-9]; do
        [[ -d "$_mmcblk" ]] || continue
        if [[ "$(cat "$_mmcblk/device/type" 2>/dev/null)" == "MMC" ]]; then
            _EMMC_DEV="/dev/$(basename "$_mmcblk")"
            break
        fi
    done
    if [[ -n "$_EMMC_DEV" ]]; then
        _EMMC_MARKER=""
        [[ "$BOOT_DISK" == "$_EMMC_DEV"* ]] && _EMMC_MARKER=" ${GREEN}← active boot source${NC}"
        echo -e "      ${GREEN}2.${NC} eMMC ($_EMMC_DEV)  ${GREEN}✔ present${NC}${_EMMC_MARKER}"
    else
        echo -e "      ${YELLOW}2.${NC} eMMC  ${YELLOW}— not populated${NC}"
    fi

    # 3. SD card
    _SD_DEV=""
    for _mmcblk in /sys/class/block/mmcblk[0-9]; do
        [[ -d "$_mmcblk" ]] || continue
        if [[ "$(cat "$_mmcblk/device/type" 2>/dev/null)" == "SD" ]]; then
            _SD_DEV="/dev/$(basename "$_mmcblk")"
            break
        fi
    done
    if [[ -n "$_SD_DEV" ]]; then
        _SD_MARKER=""
        [[ "$BOOT_DISK" == "$_SD_DEV"* ]] && _SD_MARKER=" ${GREEN}← active boot source${NC}"
        echo -e "      ${GREEN}3.${NC} SD card ($_SD_DEV)  ${GREEN}✔ present${NC}${_SD_MARKER}"
    else
        echo -e "      ${YELLOW}3.${NC} SD card  ${YELLOW}— not inserted${NC}"
    fi

    echo -e "      ${CYAN}↳${NC}  NVMe/USB/Network: only via U-Boot (must be in SPI)"
else
    warn "Could not determine boot source"
fi

# Check SPI device
SPI_OK=false
if [[ -b /dev/mtdblock0 ]]; then
    ok "/dev/mtdblock0 present"

    # Size from sysfs
    MTD_SIZE=$(cat /sys/class/mtd/mtd0/size 2>/dev/null || echo "0")
    MTD_NAME=$(cat /sys/class/mtd/mtd0/name 2>/dev/null || echo "?")
    MTD_TYPE=$(cat /sys/class/mtd/mtd0/type 2>/dev/null || echo "?")
    if [[ "$MTD_SIZE" -gt 0 ]]; then
        info "MTD-Device: ${MTD_NAME} (${MTD_TYPE}, $((MTD_SIZE / 1024)) KB)"
    fi

    # Check content (first 4 KB)
    SPI_CONTENT=$(dd if=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    if [[ -z "$(echo "$SPI_CONTENT" | tr -d '0')" ]]; then
        warn "SPI flash is empty (no bootloader)"
    else
        SPI_OK=true

        # ── Rockchip idbloader magic (offset 0: "RKNS" = 0x524B4E53) ──
        RK_MAGIC=$(dd if=/dev/mtdblock0 bs=1 count=4 2>/dev/null | od -A n -t x1 | tr -d ' \n')
        if [[ "$RK_MAGIC" == "524b4e53" ]]; then
            ok "Rockchip idbloader detected (RKNS signature)"
            # idbloader sector count (bytes 4-5, little-endian)
            IDL_SECTORS=$(dd if=/dev/mtdblock0 bs=1 skip=4 count=2 2>/dev/null | od -A n -t u2 --endian=little | tr -d ' ')
            if [[ -n "$IDL_SECTORS" ]] && [[ "$IDL_SECTORS" -gt 0 ]]; then
                info "idbloader size: ${IDL_SECTORS} sectors ($((IDL_SECTORS * 512 / 1024)) KB)"
            fi
        fi

        # ── GPT / EFI PART signature (offset 0x200) ──
        EFI_SIG=$(dd if=/dev/mtdblock0 bs=1 skip=512 count=8 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 16)
        if [[ "$EFI_SIG" == "4546492050415254" ]]; then
            ok "GPT partition table detected in SPI (EFI PART)"
        fi

        # ── Extract U-Boot version string ──
        # U-Boot embeds plaintext strings like "U-Boot 2024.01-armbian..."
        UBOOT_VER=$(strings /dev/mtdblock0 2>/dev/null | grep -oP '^U-Boot \d{4}\.\d{2}[^\s]*(\s.*)?$' | head -1 || true)
        if [[ -n "$UBOOT_VER" ]]; then
            ok "U-Boot Version: ${BOLD}${UBOOT_VER}${NC}"
            # Extract build date (format: "(Mon DD YYYY - HH:MM:SS ...)" or "YYYY-MM-DD")
            UBOOT_DATE=$(strings /dev/mtdblock0 2>/dev/null | grep -oP '\(\w{3} \d{2} \d{4} - \d{2}:\d{2}:\d{2}' | head -1 | tr -d '(' || true)
            if [[ -z "$UBOOT_DATE" ]]; then
                UBOOT_DATE=$(echo "$UBOOT_VER" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1 || true)
            fi
            if [[ -n "$UBOOT_DATE" ]]; then
                info "Build date: ${BOLD}${UBOOT_DATE}${NC}"
            fi
        else
            # Fallback: less strict search
            UBOOT_VER_LOOSE=$(strings /dev/mtdblock0 2>/dev/null | grep -m1 'U-Boot SPL\|U-Boot 20' || true)
            if [[ -n "$UBOOT_VER_LOOSE" ]]; then
                ok "U-Boot detected: ${BOLD}${UBOOT_VER_LOOSE}${NC}"
            else
                info "No U-Boot version string found (proprietary loader?)"
            fi
        fi

        # Summary of SPI loader type
        if [[ "$RK_MAGIC" == "524b4e53" ]] && [[ "$EFI_SIG" == "4546492050415254" ]]; then
            info "SPI loader type: Rockchip idbloader + GPT (standard for NVMe boot)"
        elif [[ "$RK_MAGIC" == "524b4e53" ]]; then
            info "SPI loader type: Rockchip idbloader (legacy format)"
        elif [[ "$EFI_SIG" == "4546492050415254" ]]; then
            info "SPI loader type: GPT format (without Rockchip idbloader header)"
        else
            info "SPI loader type: Unknown"
        fi
    fi

    # Available U-Boot SPI images + checksum comparison
    mapfile -t SPI_IMAGES < <(find /usr/lib/linux-u-boot-* -maxdepth 1 -type f \
        \( -name "rkspi_loader*.img" -o -name "u-boot-rockchip-spi*.bin" \) 2>/dev/null)
    if [[ ${#SPI_IMAGES[@]} -gt 0 ]]; then
        # Calculate SPI flash hash (once, over the relevant size)
        SPI_FLASH_HASH=""
        for img in "${SPI_IMAGES[@]}"; do
            IMG_SIZE=$(stat -c%s "$img" 2>/dev/null || echo "0")
            IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))
            info "SPI image available: $(basename "$img") (${IMG_SIZE_MB} MB)"

            # Compare: read same number of bytes from SPI as image size
            if [[ "$IMG_SIZE" -gt 0 ]] && $SPI_OK; then
                IMG_HASH=$(md5sum "$img" 2>/dev/null | cut -d' ' -f1)
                if [[ -z "$SPI_FLASH_HASH" ]] || [[ "${LAST_IMG_SIZE:-0}" -ne "$IMG_SIZE" ]]; then
                    SPI_FLASH_HASH=$(dd if=/dev/mtdblock0 bs=1 count="$IMG_SIZE" 2>/dev/null | md5sum | cut -d' ' -f1)
                    LAST_IMG_SIZE=$IMG_SIZE
                fi
                if [[ "$IMG_HASH" == "$SPI_FLASH_HASH" ]]; then
                    ok "SPI flash matches $(basename "$img") ${GREEN}(up to date)${NC}"
                else
                    warn "SPI flash differs from $(basename "$img") (update available?)"
                    info "  Flash: ${SPI_FLASH_HASH}"
                    info "  Image: ${IMG_HASH}"
                fi
            fi
        done

        # U-Boot version from image for comparison
        if [[ ${#SPI_IMAGES[@]} -gt 0 ]]; then
            IMG_UBOOT_VER=$(strings "${SPI_IMAGES[0]}" 2>/dev/null | grep -oP '^U-Boot \d{4}\.\d{2}[^\s]*(\s.*)?$' | head -1 || true)
            if [[ -n "$IMG_UBOOT_VER" ]] && [[ -n "${UBOOT_VER:-}" ]] && [[ "$IMG_UBOOT_VER" != "$UBOOT_VER" ]]; then
                info "Image-Version: ${BOLD}${IMG_UBOOT_VER}${NC} (Flash: ${UBOOT_VER})"
            fi
        fi
    else
        warn "No U-Boot SPI image found in /usr/lib/linux-u-boot-*/"
        info "Consider installing a u-boot package: apt list --installed 'linux-u-boot-*'"
    fi
else
    warn "/dev/mtdblock0 not present — SPI flash not available"
    info "Try loading module: modprobe spi-rockchip-sfc"
fi

###############################################################################
#  2. armbianEnv.txt & overlay check
###############################################################################

header "Armbian Boot Configuration"

if [[ ! -f "$ARMBIAN_ENV" ]]; then
    fail "$ARMBIAN_ENV not found!"
    exit 1
fi

# Overlay prefix
OVERLAY_PREFIX=$(grep -oP '(?<=^overlay_prefix=).*' "$ARMBIAN_ENV" 2>/dev/null || true)
if [[ -z "$OVERLAY_PREFIX" ]]; then
    warn "overlay_prefix not in $ARMBIAN_ENV, default would be: rockchip-rk3588"
else
    ok "overlay_prefix = ${BOLD}$OVERLAY_PREFIX${NC}"
fi

# Show active overlays
echo ""
CURRENT_OVERLAYS=$(get_current_overlays)
USER_OVERLAYS=$(get_user_overlays)

if [[ -n "$CURRENT_OVERLAYS" ]]; then
    info "overlays=${BOLD}$CURRENT_OVERLAYS${NC}"
else
    info "overlays= ${YELLOW}(empty — no system overlays active)${NC}"
fi
if [[ -n "$USER_OVERLAYS" ]]; then
    info "user_overlays=${BOLD}$USER_OVERLAYS${NC}"
fi

# Check for harmful NPU overlays
# The vendor DTB already has the NPU with status="okay".
# Any NPU overlay causes "can't request region for resource" conflicts.
NPU_OVERLAY_CONFLICT=false
for line_key in overlays user_overlays; do
    line_val=$(grep -oP "(?<=^${line_key}=).*" "$ARMBIAN_ENV" 2>/dev/null || true)
    if [[ -n "$line_val" ]] && echo "$line_val" | grep -qiE 'npu|rknpu'; then
        fail "Harmful NPU overlay found in ${line_key}=: $line_val"
        fail "The vendor DTB already has the NPU enabled. Overlays cause conflicts!"
        NPU_OVERLAY_CONFLICT=true
        ((ISSUES_FOUND++)) || true
    fi
done

# Check for user_overlays .dtbo files
if [[ -n "$USER_OVERLAYS" ]] && [[ -d "$OVERLAY_USER_DIR" ]]; then
    for uo in $USER_OVERLAYS; do
        if [[ "$uo" == *npu* ]] || [[ "$uo" == *rknpu* ]]; then
            if [[ -f "${OVERLAY_USER_DIR}/${uo}.dtbo" ]]; then
                fail "NPU overlay .dtbo present: ${OVERLAY_USER_DIR}/${uo}.dtbo"
                NPU_OVERLAY_CONFLICT=true
            fi
        fi
    done
fi

if ! $NPU_OVERLAY_CONFLICT; then
    ok "No harmful NPU overlays active (correct — vendor DTB is sufficient)"
fi

###############################################################################
#  3. Check NPU status
###############################################################################

header "NPU Status"

NPU_OK=false
NPU_DRIVER=""  # "rocket" (mainline 6.18+) or "rknpu" (vendor)

# ── Option 1: Rocket driver (mainline 6.18+, /dev/accel/accel0) ──
if [[ -c /dev/accel/accel0 ]]; then
    ok "NPU accel device: ${BOLD}/dev/accel/accel0${NC} (Rocket driver, mainline)"
    NPU_OK=true
    NPU_DRIVER="rocket"
elif [[ -d /dev/accel ]]; then
    # Directory exists but no device
    info "/dev/accel/ exists, but accel0 is missing"
fi

# ── Option 2: RKNPU DRM subsystem (vendor kernel, /dev/dri/renderD129) ──
NPU_DRM_PATH="$NPU_DRM_DEVICE"
if ! $NPU_OK && [[ -L "$NPU_DRM_PATH" ]]; then
    NPU_DRM_DEV=$(readlink -f "$NPU_DRM_PATH")
    NPU_DRM_NODE=$(basename "$(readlink "$NPU_DRM_PATH")")
    ok "NPU DRM-Device: ${BOLD}${NPU_DRM_NODE}${NC} → $NPU_DRM_DEV"
    NPU_OK=true
    NPU_DRIVER="rknpu"
fi

# ── Option 3: Legacy /dev/rknpu* (older kernels/drivers) ──
if ! $NPU_OK && ls /dev/rknpu* &>/dev/null; then
    ok "/dev/rknpu device present (legacy mode):"
    ls -la /dev/rknpu* 2>/dev/null | while read -r line; do echo "      $line"; done
    NPU_OK=true
    NPU_DRIVER="rknpu-legacy"
fi

if ! $NPU_OK; then
    if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
        fail "NPU not found — /dev/accel/accel0 missing (Rocket driver expected on kernel ≥6.18)"
    elif $IS_VENDOR_KERNEL; then
        fail "NPU not found as DRM device ($NPU_DRM_PATH) or /dev/rknpu*"
    else
        fail "NPU not found (kernel $KERNEL_VER — NPU requires vendor 6.1 or mainline ≥6.18)"
    fi
    ((ISSUES_FOUND++)) || true
fi

# Check kernel module
if lsmod 2>/dev/null | grep -qi '^rocket '; then
    ok "rocket kernel module loaded (mainline NPU driver)"
    lsmod | grep -i '^rocket ' | while read -r line; do echo "      $line"; done
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rocket"
elif [[ -d /sys/module/rocket ]]; then
    ok "rocket is built-in to the kernel"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rocket"
elif lsmod 2>/dev/null | grep -qi rknpu; then
    ok "rknpu kernel module loaded"
    lsmod | grep -i rknpu | while read -r line; do echo "      $line"; done
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rknpu"
elif [[ -d /sys/module/rknpu ]]; then
    NPU_MOD_VER=$(cat /sys/module/rknpu/version 2>/dev/null || echo "?")
    ok "rknpu built-in to the kernel (version: ${BOLD}$NPU_MOD_VER${NC})"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rknpu"
elif zgrep -qi 'CONFIG_ROCKCHIP_RKNPU=y' /proc/config.gz 2>/dev/null; then
    ok "rknpu built-in (CONFIG_ROCKCHIP_RKNPU=y)"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rknpu"
elif zgrep -qi 'CONFIG_DRM_ACCEL_ROCKET=m' /proc/config.gz 2>/dev/null; then
    info "rocket configured as module (CONFIG_DRM_ACCEL_ROCKET=m) — but not loaded"
    if ! $NPU_OK; then
        info "Try: modprobe rocket"
    fi
elif zgrep -qi 'CONFIG_DRM_ACCEL_ROCKET=y' /proc/config.gz 2>/dev/null; then
    ok "rocket built-in (CONFIG_DRM_ACCEL_ROCKET=y)"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rocket"
else
    if ! $NPU_OK; then
        fail "No NPU driver found (neither rocket nor rknpu)"
        ((ISSUES_FOUND++)) || true
    fi
fi

# Show NPU driver type
if [[ -n "$NPU_DRIVER" ]]; then
    case "$NPU_DRIVER" in
        rocket)
            info "NPU stack: ${BOLD}Rocket${NC} (mainline, userspace: Mesa Teflon / TFLite)"
            ;;
        rknpu)
            info "NPU stack: ${BOLD}RKNPU${NC} (vendor, userspace: rknn-toolkit2 / .rknn models)"
            ;;
        rknpu-legacy)
            info "NPU stack: ${BOLD}RKNPU Legacy${NC} (older vendor driver)"
            ;;
    esac
fi

# devfreq (NPU clock frequency) — vendor kernel/rknpu only
NPU_DEVFREQ="$NPU_DEVFREQ_PATH"
if [[ -d "$NPU_DEVFREQ" ]]; then
    NPU_FREQ=$(cat "$NPU_DEVFREQ/cur_freq" 2>/dev/null || echo "?")
    NPU_FREQ_MHZ=$((NPU_FREQ / 1000000))
    NPU_AVAIL=$(cat "$NPU_DEVFREQ/available_frequencies" 2>/dev/null || echo "?")
    ok "NPU frequency: ${BOLD}${NPU_FREQ_MHZ} MHz${NC}"
    info "Available frequencies: $NPU_AVAIL"
fi

# dmesg messages
echo ""
info "Kernel messages for NPU:"
DMESG_NPU=$(dmesg 2>/dev/null | grep -iE 'rknpu|rocket|fdab0000\.npu|accel accel' | tail -$DMESG_NPU_LINES || true)
if [[ -n "$DMESG_NPU" ]]; then
    echo "$DMESG_NPU" | while read -r line; do echo "      $line"; done
    # Version from DRM init message
    NPU_VER=$(echo "$DMESG_NPU" | grep -oP 'Initialized rknpu \K[0-9.]+' | tail -1 || true)
    if [[ -z "$NPU_VER" ]]; then
        NPU_VER=$(echo "$DMESG_NPU" | grep -oP 'Initialized rocket \K[0-9.]+' | tail -1 || true)
    fi
    if [[ -z "$NPU_VER" ]]; then
        NPU_VER=$(echo "$DMESG_NPU" | grep -oP 'driver version: \K[0-9.]+' | tail -1 || true)
    fi
    if [[ -n "$NPU_VER" ]]; then
        ok "NPU driver version: ${BOLD}$NPU_VER${NC}"
    fi
else
    warn "No NPU messages found in dmesg"
fi

###############################################################################
#  4. Check GPU status
###############################################################################

header "GPU Status (Mali G610)"

GPU_OK=false
GPU_DRIVER=""

# GPU is display-subsystem (fb000000.gpu / renderD128), NOT fdab0000.npu
GPU_DRM_PATH="$GPU_DRM_DEVICE"
if [[ -L "$GPU_DRM_PATH" ]]; then
    GPU_DRM_NODE=$(basename "$(readlink "$GPU_DRM_PATH")")
    ok "GPU DRM-Device: ${BOLD}${GPU_DRM_NODE}${NC}"
    GPU_OK=true
else
    # Fallback: check if /dev/dri/renderD* exists (excluding NPU)
    for rd in /dev/dri/renderD*; do
        if [[ -c "$rd" ]]; then
            RD_DRIVER=$(cat "/sys/class/drm/$(basename "$rd")/device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2 || true)
            if [[ "$RD_DRIVER" != "RKNPU" ]]; then
                ok "GPU DRM device: ${BOLD}$(basename "$rd")${NC} (driver: $RD_DRIVER)"
                GPU_OK=true
                break
            fi
        fi
    done
fi

if ! $GPU_OK; then
    fail "GPU DRM device not found"
    ((ISSUES_FOUND++)) || true
fi

# Kernel modules: mali (vendor BSP), panfrost (mainline open), panthor (newer mainline)
for drv in mali panfrost panthor; do
    if lsmod 2>/dev/null | grep -qi "^${drv} "; then
        GPU_DRIVER="$drv"
        ok "$drv kernel module loaded"
        break
    elif [[ -d "/sys/module/$drv" ]]; then
        GPU_DRIVER="$drv"
        ok "$drv is built-in to the kernel"
        break
    fi
done

# Broader search if nothing found
if [[ -z "$GPU_DRIVER" ]]; then
    for drv in bifrost valhall mali_kbase; do
        if lsmod 2>/dev/null | grep -qi "$drv" || [[ -d "/sys/module/$drv" ]]; then
            GPU_DRIVER="$drv"
            ok "GPU driver: ${BOLD}$drv${NC}"
            break
        fi
    done
fi

if [[ -z "$GPU_DRIVER" ]] && $GPU_OK; then
    # DRM device present but no module detected — take driver name from uevent
    GPU_DRIVER=$(cat "/sys/class/drm/card0/device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2 || echo "unknown")
    info "GPU driver (from uevent): ${BOLD}$GPU_DRIVER${NC}"
elif [[ -z "$GPU_DRIVER" ]]; then
    warn "No GPU driver detected"
fi

# GPU utilization
if [[ -f "$GPU_UTIL_PATH" ]]; then
    GPU_UTIL=$(cat "$GPU_UTIL_PATH" 2>/dev/null || echo "?")
    info "GPU utilization: ${GPU_UTIL}%"
fi

# dmesg GPU
echo ""
info "Kernel messages for GPU:"
DMESG_GPU=$(dmesg 2>/dev/null | grep -iE 'mali|panfrost|panthor|fb000000\.gpu' | tail -$DMESG_GPU_LINES || true)
if [[ -n "$DMESG_GPU" ]]; then
    echo "$DMESG_GPU" | while read -r line; do echo "      $line"; done
else
    warn "No GPU messages found in dmesg"
fi

###############################################################################
#  5. DRI overview
###############################################################################

header "DRI Devices (/dev/dri)"

if [[ -d /dev/dri/by-path ]]; then
    for link in /dev/dri/by-path/*-render; do
        [[ -L "$link" ]] || continue
        target=$(readlink "$link")
        name=$(basename "$link" | sed 's/-render$//')
        driver=$(cat "/sys/class/drm/$(basename "$target")/device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2 || echo "?")
        info "$(basename "$target")  ←  $name  (driver: ${BOLD}$driver${NC})"
    done
else
    warn "/dev/dri/by-path not present"
    if [[ -d /dev/dri ]]; then
        ls -la /dev/dri/ 2>/dev/null | while read -r line; do echo "      $line"; done
    fi
fi

###############################################################################
#  6. Thermal & Fan
###############################################################################

header "Thermal & Fan"

# ── List thermal zones ──
THERMAL_ZONES=(/sys/class/thermal/thermal_zone*)
if [[ -d "${THERMAL_ZONES[0]}" ]]; then
    info "Thermal Zones:"
    for tz in "${THERMAL_ZONES[@]}"; do
        TZ_NAME=$(cat "$tz/type" 2>/dev/null || echo "?")
        TZ_TEMP=$(cat "$tz/temp" 2>/dev/null || echo "0")
        TZ_TEMP_C=$((TZ_TEMP / 1000))
        TZ_POLICY=$(cat "$tz/policy" 2>/dev/null || echo "?")
        printf "      %-25s  %s°C  (Governor: %s)\n" "$TZ_NAME" "$TZ_TEMP_C" "$TZ_POLICY"
    done
else
    warn "No thermal zones found"
fi

# ── List cooling devices ──
echo ""
info "Cooling Devices:"
FAN_CDEV=""
for cd in /sys/class/thermal/cooling_device*; do
    [[ -d "$cd" ]] || continue
    CD_NAME=$(basename "$cd")
    CD_TYPE=$(cat "$cd/type" 2>/dev/null || echo "?")
    CD_CUR=$(cat "$cd/cur_state" 2>/dev/null || echo "?")
    CD_MAX=$(cat "$cd/max_state" 2>/dev/null || echo "?")
    printf "      %-20s  %-16s  State: %s/%s\n" "$CD_NAME" "$CD_TYPE" "$CD_CUR" "$CD_MAX"
    if [[ "$CD_TYPE" == "pwm-fan" ]]; then
        FAN_CDEV="$CD_NAME"
    fi
done

# ── PWM fan details ──
if [[ -n "$FAN_CDEV" ]]; then
    echo ""
    ok "PWM fan detected: ${BOLD}${FAN_CDEV}${NC}"
    FAN_PATH="/sys/class/thermal/${FAN_CDEV}"
    FAN_CUR=$(cat "$FAN_PATH/cur_state" 2>/dev/null || echo "?")
    FAN_MAX=$(cat "$FAN_PATH/max_state" 2>/dev/null || echo "?")
    info "Fan level: ${BOLD}${FAN_CUR}/${FAN_MAX}${NC} (0=off, ${FAN_MAX}=max)"

    # Find trip points bound to fan
    for tz in "${THERMAL_ZONES[@]}"; do
        [[ -d "$tz" ]] || continue
        for cdev_link in "$tz"/cdev*/type; do
            [[ -f "$cdev_link" ]] || continue
            if [[ "$(cat "$cdev_link" 2>/dev/null)" == "pwm-fan" ]]; then
                TZ_NAME=$(cat "$tz/type" 2>/dev/null || echo "?")
                CDEV_IDX=$(echo "$cdev_link" | grep -oP 'cdev\K\d+')
                TRIP_IDX=$(cat "$tz/cdev${CDEV_IDX}_trip_point" 2>/dev/null || echo "?")
                if [[ "$TRIP_IDX" =~ ^[0-9]+$ ]]; then
                    TRIP_TEMP=$(cat "$tz/trip_point_${TRIP_IDX}_temp" 2>/dev/null || echo "0")
                    TRIP_TYPE=$(cat "$tz/trip_point_${TRIP_IDX}_type" 2>/dev/null || echo "?")
                    TRIP_TEMP_C=$((TRIP_TEMP / 1000))
                    info "  Bound to ${BOLD}${TZ_NAME}${NC} trip ${TRIP_IDX}: ${BOLD}${TRIP_TEMP_C}°C${NC} (${TRIP_TYPE})"
                fi
            fi
        done
    done
else
    info "No PWM fan detected"
fi

###############################################################################
#  7. Fix mode
###############################################################################

if $FIX_MODE; then
    header "Fix Mode"
    require_root

    FIXED=false

    # ── Remove harmful NPU overlays ──
    if $NPU_OVERLAY_CONFLICT; then
        info "Removing harmful NPU overlays from $ARMBIAN_ENV ..."

        for line_key in overlays user_overlays; do
            line_val=$(grep -oP "(?<=^${line_key}=).*" "$ARMBIAN_ENV" 2>/dev/null || true)
            if [[ -n "$line_val" ]]; then
                # Remove NPU-related entries
                new_val=$(echo "$line_val" | tr ' ' '\n' | grep -viE 'npu|rknpu' | tr '\n' ' ' | sed 's/ $//')
                if [[ "$new_val" != "$line_val" ]]; then
                    if [[ -z "$new_val" ]]; then
                        sed -i "/^${line_key}=/d" "$ARMBIAN_ENV"
                        ok "Line ${line_key}= removed (was only NPU overlay)"
                    else
                        sed -i "s|^${line_key}=.*|${line_key}=$new_val|" "$ARMBIAN_ENV"
                        ok "${line_key}= cleaned up: $new_val"
                    fi
                    FIXED=true
                    REBOOT_NEEDED=true
                fi
            fi
        done

        # Remove .dtbo files
        for dtbo in "$OVERLAY_USER_DIR"/*npu*.dtbo "$OVERLAY_USER_DIR"/*rknpu*.dtbo; do
            if [[ -f "$dtbo" ]]; then
                rm -v "$dtbo"
                ok "Removed: $dtbo"
                FIXED=true
            fi
        done
    fi

    # ── Load NPU module (rocket or rknpu, depending on kernel) ──
    if ! $NPU_OK; then
        # Which module to try?
        if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
            TRY_NPU_MOD="rocket"
        else
            TRY_NPU_MOD="rknpu"
        fi

        if ! [[ -d /sys/module/$TRY_NPU_MOD ]]; then
            info "Attempting to load ${TRY_NPU_MOD} kernel module ..."
            if modprobe "$TRY_NPU_MOD" 2>/dev/null; then
                sleep $MODPROBE_WAIT
                if [[ -c /dev/accel/accel0 ]] || [[ -L "$NPU_DRM_PATH" ]] || ls /dev/rknpu* &>/dev/null 2>&1; then
                    ok "${TRY_NPU_MOD} module loaded — NPU is now active!"
                    FIXED=true
                else
                    warn "Module loaded, but NPU device does not appear (reboot needed?)"
                    REBOOT_NEEDED=true
                fi
            else
                warn "modprobe ${TRY_NPU_MOD} failed"
                if $IS_VENDOR_KERNEL; then
                    info "On the vendor kernel, rknpu is usually built-in"
                elif awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
                    info "Kernel ≥6.18 detected — rocket should be available. Check:"
                    echo -e "    ${CYAN}→ zgrep DRM_ACCEL_ROCKET /proc/config.gz${NC}"
                elif $IS_MODERN_MAINLINE; then
                    info "Kernel $KERNEL_VER is between 6.12 and 6.17 — neither rknpu nor rocket available"
                    info "Upgrade to ≥6.18 for Rocket NPU driver:"
                    echo -e "    ${CYAN}→ apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
                    echo -e "    ${CYAN}→ # or: armbian-config --cmd KER001${NC}"
                else
                    info "Two options for NPU support:"
                    echo -e "    ${CYAN}1.${NC} Vendor-Kernel (6.1.x): ${CYAN}apt install linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx${NC}"
                    echo -e "    ${BOLD}${GREEN}2.${NC}${BOLD} Mainline ≥6.18 (recommended):${NC} ${CYAN}apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
                fi
            fi
        fi
    fi

    # ── Offer kernel upgrade (if not vendor/modern mainline) ──
    if ! $IS_VENDOR_KERNEL && ! $IS_MODERN_MAINLINE && (! $NPU_OK || ! $GPU_OK); then
        echo ""
        header "Kernel Upgrade"
        info "Current kernel ($KERNEL_VER) does not have full NPU/GPU support."
        info "Searching for available kernel packages ..."
        echo ""

        # Find available kernel packages
        mapfile -t EDGE_PKGS < <(apt-cache search 'linux-image.*edge.*rockchip' 2>/dev/null | sort || true)
        mapfile -t CURRENT_PKGS < <(apt-cache search 'linux-image.*current.*rockchip' 2>/dev/null | grep -v vendor | sort || true)
        mapfile -t VENDOR_PKGS < <(apt-cache search 'linux-image.*vendor.*rk35' 2>/dev/null | sort || true)

        HAS_CANDIDATES=false

        if [[ ${#EDGE_PKGS[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}${GREEN}Edge kernel (recommended for ≥6.18):${NC}"
            for pkg in "${EDGE_PKGS[@]}"; do
                PKG_NAME=$(echo "$pkg" | cut -d' ' -f1)
                # Check installed version
                PKG_VER=$(apt-cache policy "$PKG_NAME" 2>/dev/null | grep -oP '(?<=Candidate: ).*' || echo "?")
                echo -e "    ${CYAN}${PKG_NAME}${NC}  (${PKG_VER})"
            done
            HAS_CANDIDATES=true
            echo ""
        fi

        if [[ ${#CURRENT_PKGS[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}Current kernel:${NC}"
            for pkg in "${CURRENT_PKGS[@]}"; do
                PKG_NAME=$(echo "$pkg" | cut -d' ' -f1)
                PKG_VER=$(apt-cache policy "$PKG_NAME" 2>/dev/null | grep -oP '(?<=Candidate: ).*' || echo "?")
                echo -e "    ${CYAN}${PKG_NAME}${NC}  (${PKG_VER})"
            done
            HAS_CANDIDATES=true
            echo ""
        fi

        if [[ ${#VENDOR_PKGS[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}Vendor-Kernel (BSP 6.1.x):${NC}"
            for pkg in "${VENDOR_PKGS[@]}"; do
                PKG_NAME=$(echo "$pkg" | cut -d' ' -f1)
                PKG_VER=$(apt-cache policy "$PKG_NAME" 2>/dev/null | grep -oP '(?<=Candidate: ).*' || echo "?")
                echo -e "    ${CYAN}${PKG_NAME}${NC}  (${PKG_VER})"
            done
            HAS_CANDIDATES=true
            echo ""
        fi

        if $HAS_CANDIDATES; then
            # Suggest best option (Edge preferred)
            SUGGESTED_PKG=""
            SUGGESTED_BRANCH=""
            if [[ ${#EDGE_PKGS[@]} -gt 0 ]]; then
                SUGGESTED_PKG=$(echo "${EDGE_PKGS[0]}" | cut -d' ' -f1)
                SUGGESTED_BRANCH="edge"
            elif [[ ${#CURRENT_PKGS[@]} -gt 0 ]]; then
                SUGGESTED_PKG=$(echo "${CURRENT_PKGS[0]}" | cut -d' ' -f1)
                SUGGESTED_BRANCH="current"
            elif [[ ${#VENDOR_PKGS[@]} -gt 0 ]]; then
                SUGGESTED_PKG=$(echo "${VENDOR_PKGS[0]}" | cut -d' ' -f1)
                SUGGESTED_BRANCH="vendor"
            fi

            if [[ -n "$SUGGESTED_PKG" ]]; then
                echo -e "  ${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
                echo -e "  ${BOLD}${YELLOW}║                    ⚠  WARNING  ⚠                            ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║                                                              ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  A kernel switch is a significant system change!             ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║                                                              ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • The system will require a REBOOT                          ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • Hardware drivers may change                               ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • DTB/overlays may need adjustment                          ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • If problems occur: select old kernel in boot menu         ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║                                                              ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  Suggestion: ${SUGGESTED_PKG}${NC}"
                echo -e "  ${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -ne "  Install kernel package ${BOLD}${SUGGESTED_PKG}${NC}? Type ${BOLD}${RED}YES${NC} to confirm: "
                read -r CONFIRM
                if [[ "$CONFIRM" == "YES" ]]; then
                    echo ""
                    info "Installing ${SUGGESTED_PKG} ..."
                    if apt-get install -y "$SUGGESTED_PKG" 2>&1 | while read -r line; do echo "      $line"; done; then
                        ok "Kernel package installed: ${BOLD}${SUGGESTED_PKG}${NC}"
                        FIXED=true
                        REBOOT_NEEDED=true

                        # Install matching DTB package if available
                        DTB_PKG=$(echo "$SUGGESTED_PKG" | sed 's/linux-image/linux-dtb/')
                        if apt-cache show "$DTB_PKG" &>/dev/null; then
                            info "Installing matching DTB package: ${DTB_PKG} ..."
                            if apt-get install -y "$DTB_PKG" 2>&1 | while read -r line; do echo "      $line"; done; then
                                ok "DTB package installed: ${BOLD}${DTB_PKG}${NC}"
                            else
                                warn "DTB package installation failed — install manually if needed"
                            fi
                        fi

                        # ── Optional SPI bootloader update ──
                        # U-Boot in SPI is largely independent of the kernel.
                        # It initializes hardware (DRAM, PCIe, USB), then loads
                        # kernel + DTB + initramfs from /boot/. The DTB package (not
                        # U-Boot) must match the kernel.
                        # An SPI update is only needed when:
                        #   - U-Boot is too old for the boot medium (e.g. no NVMe support)
                        #   - Hardware init bugs in old U-Boot
                        # Otherwise it's nice-to-have (newer fixes, better init).

                        UBOOT_PKG=$(echo "$SUGGESTED_PKG" | sed 's/linux-image/linux-u-boot/')
                        UBOOT_CANDIDATES=()
                        for uboot_try in \
                            "$UBOOT_PKG" \
                            "linux-u-boot-${SUGGESTED_BRANCH}-rockchip-rk3588" \
                            "linux-u-boot-rock-5b-${SUGGESTED_BRANCH}" \
                            "linux-u-boot-rock5b-${SUGGESTED_BRANCH}"; do
                            if apt-cache show "$uboot_try" &>/dev/null 2>&1; then
                                UBOOT_CANDIDATES+=("$uboot_try")
                            fi
                        done
                        if [[ ${#UBOOT_CANDIDATES[@]} -eq 0 ]]; then
                            mapfile -t UBOOT_CANDIDATES < <(apt-cache search "linux-u-boot.*${SUGGESTED_BRANCH}.*rock" 2>/dev/null | cut -d' ' -f1 | sort -u || true)
                        fi

                        echo ""
                        header "SPI Bootloader (optional)"
                        info "The SPI bootloader (U-Boot) is ${BOLD}independent${NC} of the kernel."
                        info "It initializes hardware and loads kernel/DTB/initramfs from /boot/."
                        info "An update is usually ${BOLD}not strictly necessary${NC}, but can help with:"
                        echo "      - Hardware init bugs in old U-Boot"
                        echo "      - Missing support for boot medium"
                        echo "      - Newer fixes and better compatibility"

                        # Check if boot medium could be problematic
                        SPI_UPDATE_RECOMMENDED=false
                        if [[ -b /dev/mtdblock0 ]] && $SPI_OK; then
                            # Check if NVMe/USB boot but U-Boot possibly without support
                            SPI_UBOOT_AGE=""
                            if [[ -n "${UBOOT_VER:-}" ]]; then
                                SPI_UBOOT_YEAR=$(echo "$UBOOT_VER" | grep -oP '\d{4}\.\d{2}' | head -1 || true)
                                if [[ -n "$SPI_UBOOT_YEAR" ]]; then
                                    UBOOT_YEAR_NUM=$(echo "$SPI_UBOOT_YEAR" | tr -d '.')
                                    # U-Boot before 2023.01 had NVMe/USB boot issues on RK3588
                                    if [[ "$UBOOT_YEAR_NUM" -lt $UBOOT_MIN_YEAR_NVME ]]; then
                                        SPI_UBOOT_AGE="alt"
                                    fi
                                fi
                            fi
                            case "${BOOT_FROM:-}" in
                                *NVMe*|*USB*)
                                    if [[ "$SPI_UBOOT_AGE" == "alt" ]]; then
                                        SPI_UPDATE_RECOMMENDED=true
                                        echo ""
                                        warn "Booting from ${BOOT_FROM} with old U-Boot (${UBOOT_VER:-?})!"
                                        warn "Older U-Boot versions (<2023.01) have known NVMe/USB boot issues."
                                        info "An SPI update is ${BOLD}recommended${NC} here."
                                    fi
                                    ;;
                            esac
                        fi

                        if [[ ${#UBOOT_CANDIDATES[@]} -gt 0 ]]; then
                            echo ""
                            info "Available U-Boot packages for branch '${SUGGESTED_BRANCH}':"
                            for uc in "${UBOOT_CANDIDATES[@]}"; do
                                UC_VER=$(apt-cache policy "$uc" 2>/dev/null | grep -oP '(?<=Candidate: ).*' || echo "?")
                                UC_INSTALLED=$(apt-cache policy "$uc" 2>/dev/null | grep -oP '(?<=Installed: ).*' || echo "(none)")
                                if [[ "$UC_INSTALLED" == "(none)" ]]; then
                                    echo -e "    ${CYAN}${uc}${NC}  (${UC_VER}) — ${YELLOW}not installed${NC}"
                                else
                                    echo -e "    ${CYAN}${uc}${NC}  (installed: ${UC_INSTALLED}, available: ${UC_VER})"
                                fi
                            done

                            UBOOT_INSTALL="${UBOOT_CANDIDATES[0]}"

                            if [[ -b /dev/mtdblock0 ]]; then
                                echo ""
                                if $SPI_UPDATE_RECOMMENDED; then
                                    echo -e "  ${BOLD}${YELLOW}SPI update recommended (old U-Boot + NVMe/USB boot)${NC}"
                                else
                                    info "SPI update is optional. The current bootloader will probably continue to work."
                                fi
                                echo ""
                                echo -e "  ${CYAN}What will happen:${NC}"
                                echo "    1. Install U-Boot package (apt install)"
                                echo "    2. Flash SPI image to /dev/mtdblock0 (dd)"
                                echo "    3. Verify checksum"
                                echo ""
                                echo -e "  ${YELLOW}If flash fails: SD card with Armbian image → boot from it → reflash SPI${NC}"
                                echo ""
                                echo -ne "  Update SPI bootloader? [y/N]: "
                                read -r SPI_CONFIRM
                                if [[ "$SPI_CONFIRM" =~ ^[yY]$ ]]; then
                                    echo ""
                                    # Explicit confirmation for actual flash
                                    info "Installing ${UBOOT_INSTALL} ..."
                                    if apt-get install -y "$UBOOT_INSTALL" 2>&1 | while read -r line; do echo "      $line"; done; then
                                        ok "U-Boot package installed: ${BOLD}${UBOOT_INSTALL}${NC}"

                                        mapfile -t NEW_SPI_IMAGES < <(find /usr/lib/linux-u-boot-* -maxdepth 1 -type f \
                                            \( -name "rkspi_loader*.img" -o -name "u-boot-rockchip-spi*.bin" \) 2>/dev/null | sort -t/ -k5 -V)
                                        if [[ ${#NEW_SPI_IMAGES[@]} -gt 0 ]]; then
                                            SPI_IMG="${NEW_SPI_IMAGES[-1]}"
                                            SPI_IMG_SIZE=$(stat -c%s "$SPI_IMG" 2>/dev/null || echo "0")

                                            SPI_BEFORE_HASH=$(dd if=/dev/mtdblock0 bs=1 count="$SPI_IMG_SIZE" 2>/dev/null | md5sum | cut -d' ' -f1)
                                            SPI_IMG_HASH=$(md5sum "$SPI_IMG" 2>/dev/null | cut -d' ' -f1)

                                            if [[ "$SPI_BEFORE_HASH" == "$SPI_IMG_HASH" ]]; then
                                                ok "SPI flash is already up to date (checksum matches)"
                                            else
                                                echo ""
                                                info "Image: $(basename "$SPI_IMG") ($((SPI_IMG_SIZE / 1024 / 1024)) MB)"
                                                echo -ne "  ${BOLD}${RED}Flash to SPI now?${NC} Type ${BOLD}${RED}YES${NC} to confirm: "
                                                read -r FLASH_CONFIRM
                                                if [[ "$FLASH_CONFIRM" == "YES" ]]; then
                                                    info "Flashing SPI: $(basename "$SPI_IMG") → /dev/mtdblock0 ..."
                                                    if dd if="$SPI_IMG" of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE 2>&1 | while read -r line; do echo "      $line"; done; then
                                                        sync
                                                        SPI_AFTER_HASH=$(dd if=/dev/mtdblock0 bs=1 count="$SPI_IMG_SIZE" 2>/dev/null | md5sum | cut -d' ' -f1)
                                                        if [[ "$SPI_AFTER_HASH" == "$SPI_IMG_HASH" ]]; then
                                                            ok "SPI flash successfully updated and verified"
                                                        else
                                                            fail "SPI flash verification failed!"
                                                            fail "  Expected: ${SPI_IMG_HASH}"
                                                            fail "  Read:     ${SPI_AFTER_HASH}"
                                                            warn "Recovery: SD card with Armbian image → boot from it → reflash SPI"
                                                        fi
                                                    else
                                                        fail "SPI flash failed!"
                                                        info "Manually: dd if=${SPI_IMG} of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE"
                                                    fi
                                                else
                                                    info "Flash skipped. Package is installed, flash manually:"
                                                    echo -e "    ${CYAN}→ sudo dd if=${SPI_IMG} of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE${NC}"
                                                fi
                                            fi
                                        else
                                            warn "No SPI image found in U-Boot package"
                                        fi
                                    else
                                        fail "U-Boot installation failed!"
                                        info "Manually: sudo apt install ${UBOOT_INSTALL}"
                                    fi
                                else
                                    ok "SPI update skipped."
                                    info "Can be done manually later:"
                                    echo -e "    ${CYAN}→ sudo apt install ${UBOOT_INSTALL}${NC}"
                                    echo -e "    ${CYAN}→ sudo dd if=/usr/lib/linux-u-boot-*/rkspi_loader*.img of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE${NC}"
                                fi
                            else
                                info "/dev/mtdblock0 not present — cannot flash SPI right now"
                                info "Install package and flash SPI later:"
                                echo -e "    ${CYAN}→ sudo apt install ${UBOOT_INSTALL}${NC}"
                                echo -e "    ${CYAN}→ modprobe spi-rockchip-sfc && dd if=... of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE${NC}"
                            fi
                        else
                            info "No matching U-Boot package found for branch '${SUGGESTED_BRANCH}'."
                            info "This is OK — the current SPI bootloader usually continues to work."
                            info "Search manually if needed:"
                            echo -e "    ${CYAN}→ apt-cache search linux-u-boot.*rock${NC}"
                        fi
                    else
                        fail "Installation failed!"
                        info "Try manually: sudo apt install ${SUGGESTED_PKG}"
                    fi
                else
                    info "Cancelled. Install manually:"
                    echo -e "    ${CYAN}→ sudo apt install ${SUGGESTED_PKG}${NC}"
                    echo -e "    ${CYAN}→ sudo reboot${NC}"
                    if [[ -b /dev/mtdblock0 ]]; then
                        info "SPI bootloader update is optional — the current one usually continues to work."
                    fi
                fi
            fi
        else
            warn "No matching kernel packages found"
            info "Check Armbian repos or install manually:"
            echo -e "    ${CYAN}→ sudo armbian-config --cmd KER001${NC}"
            echo -e "    ${CYAN}→ apt-cache search linux-image.*rockchip${NC}"
        fi
    fi

    if ! $FIXED && [[ $ISSUES_FOUND -eq 0 ]]; then
        ok "Nothing to fix — everything looks good"
    fi
else
    # No fix mode — output recommendations
    if [[ $ISSUES_FOUND -gt 0 ]]; then
        header "Recommendations"

        if $NPU_OVERLAY_CONFLICT; then
            warn "Remove harmful NPU overlays:"
            echo -e "    ${CYAN}→ sudo $0 --fix${NC}"
        fi

        if ! $NPU_OK && ! $IS_VENDOR_KERNEL && ! $IS_MODERN_MAINLINE; then
            info "NPU requires a compatible kernel:"
            echo -e "    ${CYAN}1.${NC} Vendor-Kernel (6.1.x): ${CYAN}apt install linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx${NC}"
            echo -e "    ${BOLD}${GREEN}2.${NC}${BOLD} Mainline ≥6.18 (recommended):${NC} ${CYAN}apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
            echo -e "    ${CYAN}   or interactively: armbian-config --cmd KER001${NC}"
        elif ! $NPU_OK && $IS_MODERN_MAINLINE; then
            if awk "BEGIN {exit !(${KERNEL_MAJOR} < 6.18)}" 2>/dev/null; then
                warn "Kernel ${KERNEL_VER} is between 6.12–6.17 — NPU requires ≥6.18 (Rocket driver)"
                info "Upgrade:"
                echo -e "    ${CYAN}→ apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
                echo -e "    ${CYAN}→ # Verify initramfs (LUKS/Clevis!), then reboot${NC}"
                echo -e "    ${CYAN}→ # or interactively: armbian-config --cmd KER001${NC}"
            else
                info "Mainline ≥6.18 detected — Rocket NPU should be available. Check:"
                echo -e "    ${CYAN}→ zgrep DRM_ACCEL_ROCKET /proc/config.gz${NC}  (kernel config)"
                echo -e "    ${CYAN}→ sudo $0 --fix${NC}  (attempts to load module)"
                echo -e "    ${CYAN}→ dmesg | grep -iE 'rocket|accel'${NC}  (check error messages)"
            fi
        elif ! $NPU_OK && $IS_VENDOR_KERNEL; then
            info "NPU driver does not seem to be loaded:"
            echo -e "    ${CYAN}→ sudo $0 --fix${NC}  (attempts to load module)"
            echo -e "    ${CYAN}→ dmesg | grep -i rknpu${NC}  (check error messages)"
        fi

        if ! $GPU_OK; then
            info "Check GPU:"
            echo -e "    ${CYAN}→ dmesg | grep -iE 'mali|panthor|panfrost'${NC}"
            if $IS_MODERN_MAINLINE; then
                echo -e "    ${CYAN}→ zgrep -E 'PANTHOR|PANFROST' /proc/config.gz${NC}  (kernel config)"
            else
                echo -e "    ${CYAN}→ sudo armbian-config --cmd KER001${NC}  (check kernel)"
                info "Mainline ≥6.12 uses ${BOLD}panthor${NC} instead of panfrost for Mali G610"
            fi
        fi
    fi
fi

###############################################################################
#  8. Summary
###############################################################################

header "Summary"

echo ""
KERNEL_TYPE="unknown"
if $IS_VENDOR_KERNEL; then
    KERNEL_TYPE="Vendor/BSP (rknpu)"
elif $IS_MODERN_MAINLINE; then
    if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
        KERNEL_TYPE="Mainline (panthor + Rocket NPU)"
    else
        KERNEL_TYPE="Mainline (panthor, no NPU — ≥6.18 needed)"
    fi
else
    KERNEL_TYPE="Mainline (older, limited)"
fi
printf "  %-20s  %s\n" "Kernel:" "$KERNEL_VER ($KERNEL_TYPE)"
printf "  %-20s  %s\n" "Overlay prefix:" "${OVERLAY_PREFIX:-not set}"

if $NPU_OK; then
    NPU_SUMMARY="✔ Active"
    case "$NPU_DRIVER" in
        rocket)
            NPU_SUMMARY+=" (Rocket, /dev/accel/accel0"
            ;;
        rknpu)
            NPU_SUMMARY+=" (${NPU_DRM_NODE:-rknpu}"
            [[ -n "${NPU_FREQ_MHZ:-}" ]] && NPU_SUMMARY+=", ${NPU_FREQ_MHZ}MHz"
            ;;
        rknpu-legacy)
            NPU_SUMMARY+=" (rknpu-legacy"
            ;;
        *)
            NPU_SUMMARY+=" (${NPU_DRIVER:-?}"
            ;;
    esac
    NPU_SUMMARY+=")"
    echo -e "  NPU:                ${GREEN}${NPU_SUMMARY}${NC}"
else
    if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.12)}" 2>/dev/null && \
       awk "BEGIN {exit !($KERNEL_MAJOR < 6.18)}" 2>/dev/null; then
        echo -e "  NPU:                ${YELLOW}⚠ Not available (kernel $KERNEL_VER — requires ≥6.18 for Rocket)${NC}"
    else
        echo -e "  NPU:                ${RED}✘ Not active${NC}"
    fi
fi

if $GPU_OK; then
    echo -e "  GPU:                ${GREEN}✔ Active${NC} (driver: ${GPU_DRIVER:-unknown})"
else
    echo -e "  GPU:                ${RED}✘ Not active / limited${NC}"
fi

if $SPI_OK; then
    SPI_SUMMARY="✔ Bootloader present"
    [[ -n "${UBOOT_VER:-}" ]] && SPI_SUMMARY+=" (${UBOOT_VER})"
    echo -e "  SPI-Flash:          ${GREEN}${SPI_SUMMARY}${NC}"
elif [[ -b /dev/mtdblock0 ]]; then
    echo -e "  SPI-Flash:          ${YELLOW}⚠ Empty (no bootloader)${NC}"
else
    echo -e "  SPI-Flash:          ${RED}✘ Not available${NC}"
fi
if [[ -n "${FAN_CDEV:-}" ]]; then
    FAN_CUR_SUM=$(cat "/sys/class/thermal/${FAN_CDEV}/cur_state" 2>/dev/null || echo "?")
    FAN_MAX_SUM=$(cat "/sys/class/thermal/${FAN_CDEV}/max_state" 2>/dev/null || echo "?")
    echo -e "  Fan:                ${GREEN}✔ ${FAN_CDEV}${NC} (level: ${FAN_CUR_SUM}/${FAN_MAX_SUM})"
else
    echo -e "  Fan:                ${YELLOW}— No PWM fan detected${NC}"
fi
printf "  %-20s  %s\n" "Boot source:" "${BOOT_FROM:-unknown}"

echo ""
if $REBOOT_NEEDED; then
    echo -e "  ${YELLOW}${BOLD}⚡ REBOOT REQUIRED for changes to take effect!${NC}"
    echo -e "  ${YELLOW}   → sudo reboot${NC}"
fi

if [[ $ISSUES_FOUND -eq 0 ]] && ! $REBOOT_NEEDED; then
    echo -e "  ${GREEN}${BOLD}Everything looks good! NPU and GPU are operational.${NC}"
elif [[ $ISSUES_FOUND -gt 0 ]] && ! $FIX_MODE; then
    echo ""
    echo -e "  ${YELLOW}Issues found. Run the script with --fix to resolve them:${NC}"
    echo -e "  ${BOLD}  sudo $0 --fix${NC}"
fi

echo ""
info "Useful commands:"
echo "    cat /boot/armbianEnv.txt                           # Boot configuration"
echo "    ls -la /dev/dri/by-path/ /dev/accel/ 2>/dev/null   # DRM/accel devices"
echo "    cat /sys/class/devfreq/fdab0000.npu/cur_freq       # NPU frequency (vendor)"
echo "    dmesg | grep -iE 'rknpu|rocket|fdab0000.npu|accel' # NPU kernel messages"
echo "    dmesg | grep -iE 'mali|panthor|panfrost'           # GPU kernel messages"
echo "    dd if=/dev/mtdblock0 bs=512 count=1 | od -t x1    # Check SPI flash content"
echo "    strings /dev/mtdblock0 | grep 'U-Boot'            # U-Boot version in SPI"
echo "    cat /sys/class/mtd/mtd0/{size,name,type}           # MTD device info"
echo "    zgrep -E 'ROCKET|RKNPU|PANTHOR' /proc/config.gz   # Check kernel config"
echo "    cat /sys/class/thermal/cooling_device*/type        # Cooling device types"
echo "    cat /sys/class/thermal/thermal_zone*/temp          # All thermal zone temps"
echo ""
echo "  Kernel switch:"
echo "    armbian-config --cmd KER001                        # Interactive TUI selector"
echo "    apt install linux-image-edge-rockchip64 \\           # Direct: Edge 6.18+ (NPU)"
echo "                linux-dtb-edge-rockchip64"
echo "    apt install linux-image-current-rockchip64 \\        # Direct: Current 6.12.x"
echo "                linux-dtb-current-rockchip64"
echo "    apt install linux-image-vendor-rk35xx \\             # Direct: Vendor 6.1.x"
echo "                linux-dtb-vendor-rk35xx"
echo ""
