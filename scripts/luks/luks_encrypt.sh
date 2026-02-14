#!/bin/bash
# luks_encrypt.sh - Encrypt a root partition with LUKS + clevis/tang
#
# Supports:
#   - Raspberry Pi: runs on EXTERNAL machine with Pi's SD/NVMe plugged in
#   - Armbian NVMe/USB migration: runs LOCALLY on the same board (target != boot disk)
#   - Armbian in-place: runs from SD card against eMMC
#
# Prerequisites:
#   - luks_prepare.sh has been run first
#   - cryptsetup, clevis, clevis-luks, curl, jq, rsync installed
#
# Usage: sudo ./luks_encrypt.sh
#        sudo ./luks_encrypt.sh --lv-size=50G   # Set root LV size (default: 100%FREE)
#        sudo ./luks_encrypt.sh --spi-only       # Flash U-Boot to SPI only (skip encryption)
#        sudo ./luks_encrypt.sh --start-phase=clevis
#        sudo ./luks_encrypt.sh --start-phase=restore --backup-dir=/tmp/luks-backup.abc123
#        sudo ./luks_encrypt.sh --list-phases

set -euo pipefail

# --- Parse flags ---
SPI_ONLY=false
START_PHASE=""
BACKUP_DIR_OVERRIDE=""
LIST_PHASES=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: sudo ./luks_encrypt.sh [OPTIONS]"
      echo ""
      echo "Encrypt a root partition with LUKS + clevis/tang auto-unlock."
      echo ""
      echo "Supports:"
      echo "  - Raspberry Pi: runs on EXTERNAL machine with Pi's SD/NVMe plugged in"
      echo "  - Armbian NVMe/USB migration: runs LOCALLY on the same board"
      echo "  - Armbian in-place: runs from SD card against eMMC"
      echo ""
      echo "Prerequisites:"
      echo "  - luks_prepare.sh has been run on the target board first"
      echo "  - cryptsetup, clevis, clevis-luks, curl, jq, rsync installed"
      echo ""
      echo "Options:"
      echo "  --lv-size=SIZE         Set root LV size (e.g., 50G, 50%FREE; default: 100%FREE)"
      echo "  --spi-only             Flash U-Boot to SPI only (skip encryption)"
      echo "  --start-phase=PHASE    Resume from a specific phase (name or number)"
      echo "  --backup-dir=PATH      Specify backup directory (for --start-phase resume)"
      echo "  --list-phases          List available phases and exit"
      echo "  -h, --help             Show this help"
      echo ""
      echo "Phases:"
      echo "  1. detect       Device detection, board type, confirmation"
      echo "  2. backup       Root partition backup via rsync"
      echo "  3. encrypt      LUKS format + open"
      echo "  4. restore      Create filesystem, restore backup"
      echo "  5. bootconfig   cmdline/armbianEnv/crypttab/fstab"
      echo "  6. initramfs    Chroot + update-initramfs"
      echo "  7. clevis       Clevis/Tang SSS binding"
      echo "  8. verify       Verification, cleanup, SPI flash"
      echo ""
      echo "Examples:"
      echo "  sudo ./luks_encrypt.sh"
      echo "  sudo ./luks_encrypt.sh --lv-size=50G"
      echo "  sudo ./luks_encrypt.sh --start-phase=clevis"
      echo "  sudo ./luks_encrypt.sh --start-phase=restore --backup-dir=/tmp/luks-backup.abc123"
      exit 0
      ;;
    --spi-only) SPI_ONLY=true ;;
    --lv-size=*) LVM_ROOT_SIZE="${arg#--lv-size=}" ;;
    --start-phase=*) START_PHASE="${arg#--start-phase=}" ;;
    --backup-dir=*) BACKUP_DIR_OVERRIDE="${arg#--backup-dir=}" ;;
    --list-phases) LIST_PHASES=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# --- Phase definitions ---
PHASE_NAMES=(detect backup encrypt restore bootconfig initramfs clevis verify)
PHASE_DESCRIPTIONS=(
  "Device detection, board type, confirmation"
  "Root partition backup via rsync"
  "LUKS format + open"
  "Create filesystem, restore backup"
  "cmdline/armbianEnv/crypttab/fstab"
  "Chroot + update-initramfs"
  "Clevis/Tang SSS binding"
  "Verification, cleanup, SPI flash"
)

if [ "$LIST_PHASES" = true ]; then
  echo "Available phases for --start-phase:"
  for i in "${!PHASE_NAMES[@]}"; do
    printf "  %d. %-12s  %s\n" "$((i+1))" "${PHASE_NAMES[$i]}" "${PHASE_DESCRIPTIONS[$i]}"
  done
  exit 0
fi

# Validate and convert --start-phase to number
START_PHASE_NUM=1
if [ -n "$START_PHASE" ]; then
  if [[ "$START_PHASE" =~ ^[0-9]+$ ]]; then
    START_PHASE_NUM="$START_PHASE"
  else
    FOUND=false
    for i in "${!PHASE_NAMES[@]}"; do
      if [ "${PHASE_NAMES[$i]}" = "$START_PHASE" ]; then
        START_PHASE_NUM=$((i+1))
        FOUND=true
        break
      fi
    done
    if [ "$FOUND" != true ]; then
      echo "Unknown phase: $START_PHASE"
      echo "Use --list-phases to see available phases."
      exit 1
    fi
  fi
  if [ "$START_PHASE_NUM" -lt 1 ] || [ "$START_PHASE_NUM" -gt 8 ]; then
    echo "Phase number out of range (1-8): $START_PHASE_NUM"
    echo "Use --list-phases to see available phases."
    exit 1
  fi
fi

# Validate --backup-dir
if [ -n "$BACKUP_DIR_OVERRIDE" ]; then
  if [ ! -d "$BACKUP_DIR_OVERRIDE" ]; then
    echo "Backup directory does not exist: $BACKUP_DIR_OVERRIDE"
    exit 1
  fi
fi

# --- Configuration ---
TANG_SERVERS=("" "")
SSS_THRESHOLD=2
LUKS_MAPPER_NAME="rootfs"
USE_LVM=true                  # Set to false for LUKS-only (no LVM layer)
LVM_VG_NAME="pivg"            # Volume group name
LVM_LV_NAME="root"            # Logical volume name for root filesystem
LVM_ROOT_SIZE="${LVM_ROOT_SIZE:-}"  # LV size — set via --lv-size=<size> (e.g., "50G", "50%FREE") — empty = 100%FREE
BACKUP_VERIFY_PCT=90              # Minimum % of files expected after backup/restore (sanity check)
MIN_PASSPHRASE_LEN=8              # Minimum LUKS passphrase length
TANG_TIMEOUT=5                    # Timeout in seconds for tang server connectivity checks

# Derived: root device path depends on LVM mode
if [ "$USE_LVM" = true ]; then
  ROOT_DEV="/dev/${LVM_VG_NAME}/${LVM_LV_NAME}"
else
  ROOT_DEV="/dev/mapper/${LUKS_MAPPER_NAME}"
fi

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# Cleanup function
CLEANUP_MOUNTS=()
CLEANUP_TMPDIR=()
CLEANUP_LUKS=""
BACKUP_DIR_FOR_CLEANUP=""

cleanup() {
  set +e
  info "Cleaning up..."

  # Unmount in reverse order
  for (( i=${#CLEANUP_MOUNTS[@]}-1 ; i>=0 ; i-- )); do
    mnt="${CLEANUP_MOUNTS[$i]}"
    if [ -n "$mnt" ] && mountpoint -q "$mnt" 2>/dev/null; then
      umount -l "$mnt" 2>/dev/null
    fi
  done

  # Deactivate LVM if active
  if [ "$USE_LVM" = true ]; then
    vgchange -an "$LVM_VG_NAME" 2>/dev/null || true
  fi

  # Close LUKS
  if [ -n "$CLEANUP_LUKS" ] && [ -b "/dev/mapper/$CLEANUP_LUKS" ]; then
    cryptsetup luksClose "$CLEANUP_LUKS" 2>/dev/null
  fi

  # Remove temp mount dirs (NOT the backup - that's precious)
  for dir in "${CLEANUP_TMPDIR[@]}"; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      rmdir "$dir" 2>/dev/null || true
    fi
  done

  # Warn about backup if it still exists
  if [ -n "$BACKUP_DIR_FOR_CLEANUP" ] && [ -d "$BACKUP_DIR_FOR_CLEANUP" ]; then
    echo ""
    warn "Backup directory still exists: $BACKUP_DIR_FOR_CLEANUP"
    warn "You may want to keep it until you verify the system boots correctly."
  fi
}

trap cleanup EXIT

# --- Variables that may be unset when resuming past their originating phase ---
MOUNT_DST=""
MOUNT_BOOT=""
LUKS_UUID=""
LUKS_PASS=""
BACKUP_DIR=""
BACKUP_COUNT=0

# --- Prerequisite setup functions for --start-phase resume ---

_ensure_luks_open() {
  if [ -b "/dev/mapper/$LUKS_MAPPER_NAME" ]; then
    info "LUKS device already open: /dev/mapper/$LUKS_MAPPER_NAME"
  else
    info "Opening LUKS device on $EXT_ROOT_PART..."
    cryptsetup luksOpen "$EXT_ROOT_PART" "$LUKS_MAPPER_NAME"
    CLEANUP_LUKS="$LUKS_MAPPER_NAME"
  fi
  LUKS_UUID=$(blkid -s UUID -o value "$EXT_ROOT_PART")
  info "LUKS UUID: $LUKS_UUID"
  # Activate LVM if needed
  if [ "$USE_LVM" = true ] && [ ! -b "$ROOT_DEV" ]; then
    vgchange -ay "$LVM_VG_NAME" 2>/dev/null || true
  fi
}

_ensure_root_mounted() {
  if [ -n "$MOUNT_DST" ] && mountpoint -q "$MOUNT_DST" 2>/dev/null; then
    info "Root already mounted at $MOUNT_DST"
    return
  fi
  MOUNT_DST=$(mktemp -d /tmp/luks-dst.XXXXXX)
  CLEANUP_TMPDIR+=("$MOUNT_DST")
  info "Mounting encrypted root ($ROOT_DEV) at $MOUNT_DST..."
  mount "$ROOT_DEV" "$MOUNT_DST"
  CLEANUP_MOUNTS+=("$MOUNT_DST")
}

_ensure_boot_mounted() {
  if [ -n "$MOUNT_BOOT" ] && mountpoint -q "$MOUNT_BOOT" 2>/dev/null; then
    info "Boot already mounted at $MOUNT_BOOT"
    return
  fi
  MOUNT_BOOT=$(mktemp -d /tmp/luks-boot.XXXXXX)
  CLEANUP_TMPDIR+=("$MOUNT_BOOT")
  info "Mounting boot partition ($EXT_BOOT_PART) at $MOUNT_BOOT..."
  mount "$EXT_BOOT_PART" "$MOUNT_BOOT"
  CLEANUP_MOUNTS+=("$MOUNT_BOOT")
}

_find_backup_dir() {
  if [ -n "$BACKUP_DIR_OVERRIDE" ]; then
    BACKUP_DIR="$BACKUP_DIR_OVERRIDE"
  else
    # Try to find existing backup dir
    local search_base="${BACKUP_BASE:-/tmp}"
    local candidates
    candidates=$(find "$search_base" -maxdepth 1 -type d -name 'luks-backup.*' 2>/dev/null | sort -r)
    if [ -z "$candidates" ]; then
      fail "No backup directory found in $search_base. Use --backup-dir=<path> to specify."
    fi
    local count
    count=$(echo "$candidates" | wc -l)
    if [ "$count" -eq 1 ]; then
      BACKUP_DIR="$candidates"
    else
      info "Multiple backup directories found:"
      echo "$candidates"
      fail "Ambiguous backup directory. Use --backup-dir=<path> to specify."
    fi
  fi
  if [ ! -d "$BACKUP_DIR" ]; then
    fail "Backup directory does not exist: $BACKUP_DIR"
  fi
  BACKUP_DIR_FOR_CLEANUP="$BACKUP_DIR"
  BACKUP_COUNT=$(find "$BACKUP_DIR" | wc -l)
  info "Using backup directory: $BACKUP_DIR ($BACKUP_COUNT files)"
}

# =====================================================================
# 1. Safety checks
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  fail "This script must be run as root (sudo)."
fi

# --- Prompt for empty tang servers ---
for i in "${!TANG_SERVERS[@]}"; do
  if [ -z "${TANG_SERVERS[$i]}" ]; then
    read -rp "Tang server $((i+1)) URL (e.g. http://tang.example.com): " url
    if [ -z "$url" ]; then
      fail "Tang server $((i+1)) must not be empty."
    fi
    TANG_SERVERS[$i]="$url"
  fi
done

# --spi-only: skip everything and jump straight to SPI flash
if [ "$SPI_ONLY" = true ]; then
  SCENARIO="nvme_migrate"
  BOARD_TYPE="armbian"
  # Source section 9b inline (the SPI flash block checks RK3588/mtdblock itself)
  echo ""
  echo "================================================================="
  echo -e "${YELLOW}SPI U-Boot Flash (standalone mode)${NC}"
  echo "================================================================="
  echo ""

  # --- begin SPI flash logic (same as section 9b) ---
  info "=== SPI U-Boot Flash (NVMe Boot) ==="

  IS_RK3588=false
  if [ -f /proc/device-tree/compatible ]; then
    if tr '\0' '\n' < /proc/device-tree/compatible | grep -q 'rockchip,rk3588'; then
      IS_RK3588=true
    fi
  fi

  if [ "$IS_RK3588" != true ]; then
    fail "Not an RK3588 board — SPI flash not applicable"
  fi

  info "Detected RK3588 SoC"

  if [ ! -b /dev/mtdblock0 ]; then
    fail "SPI device /dev/mtdblock0 not found (try: modprobe spi-rockchip-sfc)"
  fi

  SPI_CONTENT=$(dd if=/dev/mtdblock0 bs=4096 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
  if [ -z "$(echo "$SPI_CONTENT" | tr -d '0')" ]; then
    info "SPI flash status: empty (no bootloader)"
    SPI_STATUS="empty"
  else
    info "SPI flash status: has existing bootloader"
    SPI_STATUS="has_bootloader"
  fi

  mapfile -t SPI_IMAGES < <(find /usr/lib/linux-u-boot-* -maxdepth 1 -type f \
    \( -name "rkspi_loader*.img" -o -name "u-boot-rockchip-spi*.bin" \) 2>/dev/null)

  if [ ${#SPI_IMAGES[@]} -eq 0 ]; then
    fail "No U-Boot SPI images found in /usr/lib/linux-u-boot-*/ — install the u-boot package for your board"
  fi

  echo ""
  info "Found U-Boot SPI image(s):"
  for i in "${!SPI_IMAGES[@]}"; do
    IMG_SIZE=$(stat -c%s "${SPI_IMAGES[$i]}" 2>/dev/null || echo "?")
    echo "  $((i+1)). ${SPI_IMAGES[$i]} (${IMG_SIZE} bytes)"
  done

  SPI_IMAGE=""
  if [ ${#SPI_IMAGES[@]} -eq 1 ]; then
    SPI_IMAGE="${SPI_IMAGES[0]}"
  else
    echo ""
    while true; do
      read -rp "Select image number [1-${#SPI_IMAGES[@]}]: " IMG_NUM
      if [[ "$IMG_NUM" =~ ^[0-9]+$ ]] && [ "$IMG_NUM" -ge 1 ] && [ "$IMG_NUM" -le ${#SPI_IMAGES[@]} ]; then
        SPI_IMAGE="${SPI_IMAGES[$((IMG_NUM-1))]}"
        break
      fi
      warn "Invalid selection. Enter a number between 1 and ${#SPI_IMAGES[@]}."
    done
  fi

  echo ""
  if [ "$SPI_STATUS" = "has_bootloader" ]; then
    warn "SPI flash already contains a bootloader. This will overwrite it."
  fi
  info "Image: $SPI_IMAGE"
  read -rp "Write U-Boot to SPI flash for NVMe boot? [y/N] " FLASH_CONFIRM

  if [[ "$FLASH_CONFIRM" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi

  MTD_SIZE=$(cat /sys/class/mtd/mtd0/size 2>/dev/null || echo "")
  if [ -z "$MTD_SIZE" ] || [ "$MTD_SIZE" -eq 0 ]; then
    fail "Cannot determine SPI flash size from /sys/class/mtd/mtd0/size"
  fi
  MTD_BLOCKS=$((MTD_SIZE / 4096))
  info "SPI flash size: $((MTD_SIZE / 1024)) KB ($MTD_BLOCKS blocks)"

  info "Erasing SPI flash..."
  dd if=/dev/zero of=/dev/mtdblock0 bs=4096 count="$MTD_BLOCKS" status=progress 2>&1
  sync

  info "Writing U-Boot to SPI flash..."
  if [[ "$SPI_IMAGE" == *.bin ]] && command -v flashcp &>/dev/null; then
    flashcp -v -p "$SPI_IMAGE" /dev/mtd0
  else
    dd if="$SPI_IMAGE" of=/dev/mtdblock0 conv=notrunc status=progress 2>&1
  fi
  sync

  VERIFY_DATA=$(dd if=/dev/mtdblock0 bs=512 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
  if [ -n "$(echo "$VERIFY_DATA" | tr -d '0')" ]; then
    ok "SPI flash verified — U-Boot written successfully"
  else
    fail "SPI flash verification failed — data appears empty after write"
  fi

  echo ""
  echo "================================================================="
  echo -e "${GREEN}SPI flash complete!${NC}"
  echo "================================================================="
  echo ""
  echo "Reboot to boot from NVMe with U-Boot from SPI."
  exit 0
fi

# Check required tools
REQUIRED_CMDS=(cryptsetup clevis rsync curl jq mkfs.ext4 mkimage wipefs)
if [ "$USE_LVM" = true ]; then
  REQUIRED_CMDS+=(pvcreate vgcreate lvcreate)
fi
if [ "$(uname -m)" != "aarch64" ]; then
  if ! command -v qemu-aarch64-static &>/dev/null && ! command -v qemu-aarch64 &>/dev/null; then
    fail "Required command not found: qemu-aarch64-static or qemu-aarch64 (install qemu-user-static or qemu-user)"
  fi
fi
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "Required command not found: $cmd (install it first)"
  fi
done

# =====================================================================
# 1b. Auto-detect device (if running from SD card or re-exec'd)
# =====================================================================

AUTODETECT_CONF="/tmp/.luks_autodetect"
EXT_DEVICE=""
PI_DEVICE=""
PI_BOOT_PART=""
PI_ROOT_PART=""
BOARD_TYPE=""
LOCAL_MODE=false
SCENARIO=""
SOURCE_DEVICE=""
SPI_FLASHED=false

# Detect boot vs root partitions for a device.
# Armbian may have root=part1 boot=part2 (reversed from RPi convention).
# Sets EXT_BOOT_PART and EXT_ROOT_PART.
_detect_ext_partitions() {
  local dev="$1"
  local p1 p2

  if [[ "$dev" == *nvme* ]] || [[ "$dev" == *mmcblk* ]]; then
    p1="${dev}p1"
    p2="${dev}p2"
  else
    p1="${dev}1"
    p2="${dev}2"
  fi

  # Check filesystem type: boot is typically vfat or ext2, root is ext4
  local fs1 fs2
  fs1=$(blkid -s TYPE -o value "$p1" 2>/dev/null || true)
  fs2=$(blkid -s TYPE -o value "$p2" 2>/dev/null || true)

  if [ "$fs1" = "vfat" ] || [ "$fs1" = "ext2" ]; then
    EXT_BOOT_PART="$p1"
    EXT_ROOT_PART="$p2"
  elif [ "$fs2" = "vfat" ] || [ "$fs2" = "ext2" ]; then
    EXT_BOOT_PART="$p2"
    EXT_ROOT_PART="$p1"
  else
    # Fallback: larger partition is root
    local sz1 sz2
    sz1=$(blockdev --getsize64 "$p1" 2>/dev/null || echo 0)
    sz2=$(blockdev --getsize64 "$p2" 2>/dev/null || echo 0)
    if [ "$sz1" -gt "$sz2" ]; then
      EXT_ROOT_PART="$p1"
      EXT_BOOT_PART="$p2"
    else
      EXT_BOOT_PART="$p1"
      EXT_ROOT_PART="$p2"
    fi
  fi
}

# Check if we were re-launched after auto-detection
if [ -n "${_LUKS_REEXEC:-}" ] && [ -f "$AUTODETECT_CONF" ]; then
  EXT_DEVICE=$(grep '^EXT_DEVICE=' "$AUTODETECT_CONF" | cut -d'"' -f2)
  PI_DEVICE=$(grep '^PI_DEVICE=' "$AUTODETECT_CONF" | cut -d'"' -f2)
  PI_BOOT_PART=$(grep '^PI_BOOT_PART=' "$AUTODETECT_CONF" | cut -d'"' -f2)
  PI_ROOT_PART=$(grep '^PI_ROOT_PART=' "$AUTODETECT_CONF" | cut -d'"' -f2)
  BOARD_TYPE=$(grep '^BOARD_TYPE=' "$AUTODETECT_CONF" | cut -d'"' -f2)
  rm -f "$AUTODETECT_CONF"
  ok "Auto-detected devices from storage:"
  info "  External device: $EXT_DEVICE"
  info "  Internal device: $PI_DEVICE"
fi

# Try to detect if script is running from the storage medium
if [ -z "$EXT_DEVICE" ]; then
  # realpath may fail if CWD is stale (e.g., after previous unmount); try /proc/self/exe or BASH_SOURCE
  SCRIPT_REAL=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || true)
  if [ -z "$SCRIPT_REAL" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_REAL=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  fi
  if [ -z "$SCRIPT_REAL" ]; then
    # Last resort: try readlink on /proc/self/fd/255 (bash's script fd)
    SCRIPT_REAL=$(readlink -f /proc/$$/fd/255 2>/dev/null || true)
  fi
  SCRIPT_REAL="${SCRIPT_REAL:-}"
  if [ -n "$SCRIPT_REAL" ]; then
    SCRIPT_SOURCE=$(findmnt --target "$SCRIPT_REAL" -n -o SOURCE 2>/dev/null || true)
    HOST_ROOT=$(findmnt --target / -n -o SOURCE 2>/dev/null || true)

    if [ -n "$SCRIPT_SOURCE" ] && [ "$SCRIPT_SOURCE" != "$HOST_ROOT" ] && [ -b "$SCRIPT_SOURCE" ]; then
      # Script is running from a mounted non-root device (likely the SD card)
      BASE_DEV=$(lsblk -n -o PKNAME "$SCRIPT_SOURCE" 2>/dev/null | head -1 | tr -d ' ')

      if [ -n "$BASE_DEV" ]; then
        DETECTED_DEV="/dev/$BASE_DEV"
        SCRIPT_DIR_REAL=$(dirname "$SCRIPT_REAL")

        info "Script is running from external storage ($DETECTED_DEV)"

        # Read luks.conf if available next to the script
        _AD_PI_DEVICE=""
        _AD_PI_BOOT=""
        _AD_PI_ROOT=""
        _AD_BOARD_TYPE=""
        if [ -f "${SCRIPT_DIR_REAL}/luks.conf" ]; then
          _AD_PI_DEVICE=$(grep '^PI_DEVICE=' "${SCRIPT_DIR_REAL}/luks.conf" | cut -d'"' -f2)
          _AD_PI_BOOT=$(grep '^PI_BOOT_PART=' "${SCRIPT_DIR_REAL}/luks.conf" | cut -d'"' -f2)
          _AD_PI_ROOT=$(grep '^PI_ROOT_PART=' "${SCRIPT_DIR_REAL}/luks.conf" | cut -d'"' -f2)
          _AD_BOARD_TYPE=$(grep '^BOARD_TYPE=' "${SCRIPT_DIR_REAL}/luks.conf" | cut -d'"' -f2)
        fi

        # Save auto-detected config
        cat > "$AUTODETECT_CONF" << ADEOF
EXT_DEVICE="${DETECTED_DEV}"
PI_DEVICE="${_AD_PI_DEVICE}"
PI_BOOT_PART="${_AD_PI_BOOT}"
PI_ROOT_PART="${_AD_PI_ROOT}"
BOARD_TYPE="${_AD_BOARD_TYPE}"
ADEOF

        # Copy script to /tmp
        TMPSCRIPT="/tmp/luks_encrypt.sh"
        cp "$SCRIPT_REAL" "$TMPSCRIPT"
        chmod +x "$TMPSCRIPT"

        # Unmount all storage partitions
        info "Unmounting storage partitions and re-launching from /tmp..."
        for mnt in $(lsblk -n -o MOUNTPOINT "$DETECTED_DEV" 2>/dev/null | grep -v '^$' | sort -r); do
          umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        done

        # Re-exec from /tmp
        exec env _LUKS_REEXEC=1 "$TMPSCRIPT"
      fi
    fi
  fi
fi

# Derive partition names from EXT_DEVICE if auto-detected
if [ -n "$EXT_DEVICE" ]; then
  _detect_ext_partitions "$EXT_DEVICE"
fi

# =====================================================================
# 1c. Detect local mode and board type
# =====================================================================

# Try to read luks.conf from staged dir on the target root
_read_luks_conf_from_root() {
  local mount_point="$1"
  local conf="${mount_point}/root/luks-staged/luks.conf"
  if [ -f "$conf" ]; then
    PI_DEVICE=$(grep '^PI_DEVICE=' "$conf" | cut -d'"' -f2)
    PI_BOOT_PART=$(grep '^PI_BOOT_PART=' "$conf" | cut -d'"' -f2)
    PI_ROOT_PART=$(grep '^PI_ROOT_PART=' "$conf" | cut -d'"' -f2)
    [ -z "$BOARD_TYPE" ] && BOARD_TYPE=$(grep '^BOARD_TYPE=' "$conf" | cut -d'"' -f2)
    SCENARIO=$(grep '^SCENARIO=' "$conf" | cut -d'"' -f2)
    SOURCE_DEVICE=$(grep '^SOURCE_DEVICE=' "$conf" | cut -d'"' -f2)
    return 0
  fi
  return 1
}

# Detect local mode: if the target device IS our boot disk (e.g., Armbian NVMe migration)
if [ -n "$EXT_DEVICE" ]; then
  BOOT_DISK="/dev/$(lsblk -n -o PKNAME "$(findmnt -n -o SOURCE /)" | head -1)"
  if [ "$BOOT_DISK" = "$EXT_DEVICE" ]; then
    LOCAL_MODE=true
    info "Local mode: encrypting $EXT_DEVICE (current boot disk)"
  fi
fi

# =====================================================================
# 2. Banner and device selection
# =====================================================================

echo ""
echo "================================================================="
if [ -n "$BOARD_TYPE" ]; then
  case "$BOARD_TYPE" in
    armbian)
      MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Armbian Board")
      echo -e "${YELLOW}${MODEL} LUKS Encryption Script${NC}"
      ;;
    rpi)
      echo -e "${YELLOW}Raspberry Pi LUKS Encryption Script${NC}"
      ;;
    *)
      echo -e "${YELLOW}LUKS Encryption Script${NC}"
      ;;
  esac
else
  echo -e "${YELLOW}LUKS Encryption Script${NC}"
fi
echo "================================================================="
echo ""
echo "This script will ENCRYPT the root partition."
echo -e "${RED}ALL DATA on the root partition will be backed up and restored.${NC}"
echo ""

# Show available block devices
info "Available block devices:"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "^loop"
echo ""

# Ask for device if not auto-detected
if [ -z "$EXT_DEVICE" ]; then
  read -rp "Enter the target device (e.g., /dev/sdb or /dev/nvme0n1): " EXT_DEVICE
  EXT_DEVICE="${EXT_DEVICE%/}"  # strip trailing slash

  if [ ! -b "$EXT_DEVICE" ]; then
    fail "Device $EXT_DEVICE not found"
  fi

  # Detect boot vs root partitions
  _detect_ext_partitions "$EXT_DEVICE"

  # Re-check local mode after user input
  BOOT_DISK="/dev/$(lsblk -n -o PKNAME "$(findmnt -n -o SOURCE /)" | head -1)"
  if [ "$BOOT_DISK" = "$EXT_DEVICE" ]; then
    LOCAL_MODE=true
    info "Local mode: encrypting $EXT_DEVICE (current boot disk)"
  fi
fi

echo ""
info "Device layout:"
lsblk "$EXT_DEVICE"
echo ""

if [ ! -b "$EXT_BOOT_PART" ]; then
  fail "Boot partition not found: $EXT_BOOT_PART"
fi
if [ ! -b "$EXT_ROOT_PART" ]; then
  fail "Root partition not found: $EXT_ROOT_PART"
fi

# Verify partitions are not mounted (skip when resuming past encrypt — partition is LUKS now)
if [ "$START_PHASE_NUM" -le 2 ]; then
  if findmnt -rn "$EXT_ROOT_PART" &>/dev/null; then
    fail "Root partition $EXT_ROOT_PART is currently mounted. Unmount it first."
  fi
  if findmnt -rn "$EXT_BOOT_PART" &>/dev/null; then
    fail "Boot partition $EXT_BOOT_PART is currently mounted. Unmount it first."
  fi
fi

# =====================================================================
# 2b. Read luks.conf from target root or live system
# =====================================================================

if [ -z "$PI_DEVICE" ] || [ -z "$PI_BOOT_PART" ] || [ -z "$PI_ROOT_PART" ]; then
  # In local mode, try reading luks.conf from the live system first
  if [ "$LOCAL_MODE" = true ] && [ -f /root/luks-staged/luks.conf ]; then
    _read_luks_conf_from_root "" 2>/dev/null || true
    # _read_luks_conf_from_root expects mount_point prefix; read directly
    PI_DEVICE=$(grep '^PI_DEVICE=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    PI_BOOT_PART=$(grep '^PI_BOOT_PART=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    PI_ROOT_PART=$(grep '^PI_ROOT_PART=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    [ -z "$BOARD_TYPE" ] && BOARD_TYPE=$(grep '^BOARD_TYPE=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    SCENARIO=$(grep '^SCENARIO=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    SOURCE_DEVICE=$(grep '^SOURCE_DEVICE=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    if [ -n "$PI_DEVICE" ]; then
      ok "Read device info from live system luks.conf: $PI_DEVICE (scenario: ${SCENARIO:-unknown})"
    fi
  fi

  # Otherwise, try mounting the target root to read luks.conf
  if [ -z "$PI_DEVICE" ] || [ -z "$PI_BOOT_PART" ] || [ -z "$PI_ROOT_PART" ]; then
    echo ""
    MOUNT_TMP_ROOT=$(mktemp -d /tmp/luks-probe.XXXXXX)
    if mount -o ro "$EXT_ROOT_PART" "$MOUNT_TMP_ROOT" 2>/dev/null; then
      if _read_luks_conf_from_root "$MOUNT_TMP_ROOT"; then
        ok "Read device info from luks.conf: $PI_DEVICE (board: ${BOARD_TYPE:-unknown})"
      fi
      umount "$MOUNT_TMP_ROOT" 2>/dev/null || true
    else
      # Mount failed — partition may be corrupted from a previous failed cryptsetup attempt.
      # Try reading luks.conf from an existing backup directory instead.
      _bkp_conf=""
      if [ -n "$BACKUP_DIR_OVERRIDE" ] && [ -f "${BACKUP_DIR_OVERRIDE}/root/luks-staged/luks.conf" ]; then
        _bkp_conf="${BACKUP_DIR_OVERRIDE}/root/luks-staged/luks.conf"
      else
        # Search for backup dirs in /tmp
        _bkp_dir=$(find /tmp -maxdepth 1 -type d -name 'luks-backup.*' 2>/dev/null | sort -r | head -1)
        if [ -n "$_bkp_dir" ] && [ -f "${_bkp_dir}/root/luks-staged/luks.conf" ]; then
          _bkp_conf="${_bkp_dir}/root/luks-staged/luks.conf"
        fi
      fi
      if [ -n "$_bkp_conf" ]; then
        warn "Could not mount $EXT_ROOT_PART (may be corrupted from previous attempt)"
        info "Reading luks.conf from backup: $_bkp_conf"
        PI_DEVICE=$(grep '^PI_DEVICE=' "$_bkp_conf" | cut -d'"' -f2)
        PI_BOOT_PART=$(grep '^PI_BOOT_PART=' "$_bkp_conf" | cut -d'"' -f2)
        PI_ROOT_PART=$(grep '^PI_ROOT_PART=' "$_bkp_conf" | cut -d'"' -f2)
        [ -z "$BOARD_TYPE" ] && BOARD_TYPE=$(grep '^BOARD_TYPE=' "$_bkp_conf" | cut -d'"' -f2)
        SCENARIO=$(grep '^SCENARIO=' "$_bkp_conf" | cut -d'"' -f2)
        SOURCE_DEVICE=$(grep '^SOURCE_DEVICE=' "$_bkp_conf" | cut -d'"' -f2)
        if [ -n "$PI_DEVICE" ]; then
          ok "Read device info from backup luks.conf: $PI_DEVICE (board: ${BOARD_TYPE:-unknown})"
        fi
      fi
    fi
    rmdir "$MOUNT_TMP_ROOT" 2>/dev/null || true
  fi

  if [ -z "$PI_DEVICE" ] || [ -z "$PI_BOOT_PART" ] || [ -z "$PI_ROOT_PART" ]; then
    info "No luks.conf found — asking for internal device path."
    info "This is how the target system sees its own storage."
    read -rp "Enter the INTERNAL device path [/dev/mmcblk0]: " PI_DEVICE
    PI_DEVICE="${PI_DEVICE:-/dev/mmcblk0}"

    if [[ "$PI_DEVICE" == *nvme* ]] || [[ "$PI_DEVICE" == *mmcblk* ]]; then
      PI_BOOT_PART="${PI_DEVICE}p1"
      PI_ROOT_PART="${PI_DEVICE}p2"
    else
      PI_BOOT_PART="${PI_DEVICE}1"
      PI_ROOT_PART="${PI_DEVICE}2"
    fi
  fi
fi

# Verify root partition is ext4 (skip for nvme_migrate/usb_migrate and when resuming past encrypt)
if [ "$START_PHASE_NUM" -le 2 ]; then
  if [ "$SCENARIO" != "nvme_migrate" ] && [ "$SCENARIO" != "usb_migrate" ]; then
    ROOT_FSTYPE=$(blkid -s TYPE -o value "$EXT_ROOT_PART" 2>/dev/null || true)
    if [ "$ROOT_FSTYPE" != "ext4" ]; then
      fail "Root partition $EXT_ROOT_PART is not ext4 (found: ${ROOT_FSTYPE:-unknown})"
    fi
  else
    info "Migration scenario: skipping ext4 check on target partition (will be LUKS-formatted)"
  fi
fi

# Detect board type from boot partition if still unknown
if [ -z "$BOARD_TYPE" ]; then
  MOUNT_TMP_BOOT=$(mktemp -d /tmp/luks-boot-probe.XXXXXX)
  mount -o ro "$EXT_BOOT_PART" "$MOUNT_TMP_BOOT" 2>/dev/null || true
  if [ -f "$MOUNT_TMP_BOOT/armbianEnv.txt" ]; then
    BOARD_TYPE="armbian"
  elif [ -f "$MOUNT_TMP_BOOT/config.txt" ]; then
    BOARD_TYPE="rpi"
  else
    BOARD_TYPE="rpi"  # fallback
    warn "Could not detect board type from boot partition, assuming RPi"
  fi
  umount "$MOUNT_TMP_BOOT" 2>/dev/null || true
  rmdir "$MOUNT_TMP_BOOT" 2>/dev/null || true
  info "Detected board type: $BOARD_TYPE"
fi

# Check available disk space for backup
if [ "$LOCAL_MODE" = true ]; then
  # In local mode, estimate used space from running root
  ROOT_USED_KB=$(df --output=used / 2>/dev/null | tail -1 | tr -d ' ')
  info "Root filesystem used space: ~$((ROOT_USED_KB / 1024)) MB"
  NEEDED_KB="$ROOT_USED_KB"
else
  ROOT_SIZE_KB=$(blockdev --getsize64 "$EXT_ROOT_PART" 2>/dev/null | awk '{printf "%d", $1/1024}')
  info "Root partition size: ~$((ROOT_SIZE_KB / 1024)) MB"
  NEEDED_KB="$ROOT_SIZE_KB"
fi

TMPDIR_AVAIL_KB=$(df --output=avail /tmp 2>/dev/null | tail -1 | tr -d ' ')
info "Available space in /tmp: ~$((TMPDIR_AVAIL_KB / 1024)) MB"

if [ "$TMPDIR_AVAIL_KB" -lt "$NEEDED_KB" ]; then
  warn "Insufficient space in /tmp for backup!"
  read -rp "Enter an alternative backup directory with enough space: " BACKUP_BASE
  if [ ! -d "$BACKUP_BASE" ]; then
    fail "Directory $BACKUP_BASE does not exist"
  fi
else
  BACKUP_BASE="/tmp"
fi

echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "  Board type:            $BOARD_TYPE"
echo "  Scenario:              ${SCENARIO:-external}"
echo "  Local mode:            $LOCAL_MODE"
echo "  External device:       $EXT_DEVICE"
echo "  External boot part:    $EXT_BOOT_PART"
echo "  External root part:    $EXT_ROOT_PART"
echo "  Internal device:       $PI_DEVICE"
echo "  Internal boot:         $PI_BOOT_PART"
echo "  Internal root:         $PI_ROOT_PART"
echo "  LUKS mapper name:      $LUKS_MAPPER_NAME"
if [ "$USE_LVM" = true ]; then
echo "  LVM:                   enabled (VG: $LVM_VG_NAME, LV: $LVM_LV_NAME, size: ${LVM_ROOT_SIZE:-100%FREE})"
fi
echo "  Root device:           $ROOT_DEV"
echo "  Backup location:       $BACKUP_BASE"
echo ""
if [ "$START_PHASE_NUM" -gt 1 ]; then
  echo -e "${YELLOW}Resuming from phase ${START_PHASE_NUM} (${PHASE_NAMES[$((START_PHASE_NUM-1))]})${NC}"
  read -rp "Continue? [y/N] " CONFIRM
  [[ "$CONFIRM" == [yY] ]] || { echo "Aborted."; exit 0; }
else
  echo -e "${RED}WARNING: This will ENCRYPT $EXT_ROOT_PART. Data will be backed up first.${NC}"
  read -rp "Type 'YES' to proceed: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }
fi

# =====================================================================
# 3. Backup root partition
# =====================================================================

if [ "$START_PHASE_NUM" -le 2 ]; then

echo ""
info "=== Phase 1: Backup ==="

BACKUP_DIR=$(mktemp -d "${BACKUP_BASE}/luks-backup.XXXXXX")
BACKUP_DIR_FOR_CLEANUP="$BACKUP_DIR"

if [ "$LOCAL_MODE" = true ]; then
  # Local mode: backup from live root filesystem
  info "Backing up live root filesystem to $BACKUP_DIR..."
  info "This may take a while depending on filesystem size..."
  # rsync exit code 23 = partial transfer (e.g. xattr not supported on tmpfs) — tolerable
  rsync -aHAXx --info=progress2 \
    --exclude='/dev/*' --exclude='/proc/*' \
    --exclude='/sys/*' --exclude='/tmp/*' --exclude='/run/*' \
    --exclude='/mnt/*' --exclude='/media/*' \
    / "${BACKUP_DIR}/" || { RC=$?; [ "$RC" -eq 23 ] && warn "rsync reported non-critical xattr warnings (exit 23), continuing" || exit "$RC"; }

  BACKUP_COUNT=$(find "$BACKUP_DIR" | wc -l)
  SRC_COUNT=$(find / -xdev 2>/dev/null | wc -l)
  info "Source file count (approx): $SRC_COUNT"
  info "Backup file count: $BACKUP_COUNT"
else
  # External mode: mount and backup
  MOUNT_SRC=$(mktemp -d /tmp/luks-src.XXXXXX)
  CLEANUP_TMPDIR+=("$MOUNT_SRC")

  info "Mounting root partition ($EXT_ROOT_PART) to $MOUNT_SRC..."
  mount -o ro "$EXT_ROOT_PART" "$MOUNT_SRC"
  CLEANUP_MOUNTS+=("$MOUNT_SRC")

  info "Backing up root filesystem to $BACKUP_DIR..."
  info "This may take a while depending on filesystem size..."
  rsync -aHAXx --info=progress2 "${MOUNT_SRC}/" "${BACKUP_DIR}/"

  # Verify backup
  SRC_COUNT=$(find "$MOUNT_SRC" -xdev | wc -l)
  BACKUP_COUNT=$(find "$BACKUP_DIR" | wc -l)
  info "Source file count: $SRC_COUNT"
  info "Backup file count: $BACKUP_COUNT"

  if [ "$BACKUP_COUNT" -lt "$((SRC_COUNT * BACKUP_VERIFY_PCT / 100))" ]; then
    fail "Backup file count is suspiciously low ($BACKUP_COUNT vs $SRC_COUNT source). Aborting."
  fi

  info "Unmounting source..."
  umount "$MOUNT_SRC"
  CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$MOUNT_SRC}")
fi

# Check staged files exist in backup
if [ ! -d "${BACKUP_DIR}/root/luks-staged" ]; then
  fail "Staged files not found in backup (${BACKUP_DIR}/root/luks-staged). Did you run luks_prepare.sh first?"
fi

ok "Backup complete ($BACKUP_COUNT files)"

fi  # end phase gate: backup

# =====================================================================
# 4. LUKS encrypt root partition
# =====================================================================

if [ "$START_PHASE_NUM" -le 3 ]; then

# When resuming at encrypt phase, backup was already done — locate it now
if [ "$START_PHASE_NUM" -eq 3 ]; then
  _find_backup_dir
fi

echo ""
info "=== Phase 2: LUKS Encryption ==="

# Get LUKS passphrase
while true; do
  read -rsp "Enter LUKS passphrase (this is the fallback password): " LUKS_PASS
  echo ""
  read -rsp "Confirm LUKS passphrase: " LUKS_PASS2
  echo ""
  if [ "$LUKS_PASS" = "$LUKS_PASS2" ]; then
    if [ ${#LUKS_PASS} -lt $MIN_PASSPHRASE_LEN ]; then
      warn "Passphrase is very short. Use at least 8 characters."
      read -rp "Use this passphrase anyway? [y/N] " CONFIRM
      [[ "$CONFIRM" == [yY] ]] || continue
    fi
    break
  else
    warn "Passphrases do not match. Try again."
  fi
done

# Close stale LVM/LUKS stack from a previous failed run, if any
if [ -b "/dev/mapper/${LVM_VG_NAME}-${LVM_LV_NAME}" ]; then
  warn "Removing stale LVM device /dev/mapper/${LVM_VG_NAME}-${LVM_LV_NAME}..."
  dmsetup remove "${LVM_VG_NAME}-${LVM_LV_NAME}" 2>/dev/null || true
fi
if [ -b "/dev/mapper/$LUKS_MAPPER_NAME" ]; then
  warn "Closing stale LUKS device /dev/mapper/$LUKS_MAPPER_NAME..."
  dmsetup remove "$LUKS_MAPPER_NAME" 2>/dev/null || true
fi

info "Wiping filesystem signatures on $EXT_ROOT_PART..."
wipefs --all --force "$EXT_ROOT_PART" 2>/dev/null || true
# Zero out the first 16MB to prevent cryptsetup header-wipe failures (common on SD cards)
dd if=/dev/zero of="$EXT_ROOT_PART" bs=1M count=16 conv=notrunc 2>/dev/null || true

info "Encrypting $EXT_ROOT_PART with LUKS2..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$EXT_ROOT_PART" -

info "Opening LUKS device..."
# Close stale mapper device from a previous failed run, if any
if [ -b "/dev/mapper/$LUKS_MAPPER_NAME" ]; then
  warn "Closing stale /dev/mapper/$LUKS_MAPPER_NAME from previous run..."
  cryptsetup luksClose "$LUKS_MAPPER_NAME" 2>/dev/null || true
fi
echo -n "$LUKS_PASS" | cryptsetup luksOpen "$EXT_ROOT_PART" "$LUKS_MAPPER_NAME" -
CLEANUP_LUKS="$LUKS_MAPPER_NAME"

ok "LUKS encryption complete"

# Capture LUKS UUID for crypttab/cmdline (avoids device-path resolution issues in chroot)
LUKS_UUID=$(blkid -s UUID -o value "$EXT_ROOT_PART")
info "LUKS UUID: $LUKS_UUID"

fi  # end phase gate: encrypt

# =====================================================================
# 5. Create filesystem and restore data
# =====================================================================

if [ "$START_PHASE_NUM" -le 4 ]; then

if [ "$START_PHASE_NUM" -eq 4 ]; then
  _find_backup_dir
  _ensure_luks_open
fi

echo ""
info "=== Phase 3: Restore ==="

if [ "$USE_LVM" = true ]; then
  info "Creating LVM physical volume on /dev/mapper/$LUKS_MAPPER_NAME..."
  pvcreate "/dev/mapper/$LUKS_MAPPER_NAME"
  info "Creating volume group $LVM_VG_NAME..."
  vgcreate "$LVM_VG_NAME" "/dev/mapper/$LUKS_MAPPER_NAME"

  echo VGS
  vgs

  echo LVS
  lvs

  if [ -n "$LVM_ROOT_SIZE" ]; then
    info "Creating logical volume $LVM_LV_NAME (${LVM_ROOT_SIZE})..."
    if [[ "$LVM_ROOT_SIZE" == *%* ]]; then
      lvcreate -l "$LVM_ROOT_SIZE" -n "$LVM_LV_NAME" "$LVM_VG_NAME"
    else
      lvcreate -L "$LVM_ROOT_SIZE" -n "$LVM_LV_NAME" "$LVM_VG_NAME"
    fi
  else
    info "Creating logical volume $LVM_LV_NAME (100% of VG)..."
    lvcreate -l 100%FREE -n "$LVM_LV_NAME" "$LVM_VG_NAME"
  fi
  info "Creating ext4 filesystem on $ROOT_DEV..."
  mkfs.ext4 "$ROOT_DEV"
else
  info "Creating ext4 filesystem on /dev/mapper/$LUKS_MAPPER_NAME..."
  mkfs.ext4 "/dev/mapper/$LUKS_MAPPER_NAME"
fi

MOUNT_DST=$(mktemp -d /tmp/luks-dst.XXXXXX)
CLEANUP_TMPDIR+=("$MOUNT_DST")

info "Mounting encrypted root..."
mount "$ROOT_DEV" "$MOUNT_DST"
CLEANUP_MOUNTS+=("$MOUNT_DST")

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  fail "BACKUP_DIR is not set or does not exist ('$BACKUP_DIR'). Use --backup-dir=<path> to specify."
fi

info "Restoring filesystem from backup ($BACKUP_DIR)..."
info "This may take a while..."
rsync -aHAXx --info=progress2 "${BACKUP_DIR}/" "${MOUNT_DST}/"

# Verify
RESTORED_COUNT=$(find "$MOUNT_DST" | wc -l)
info "Restored file count: $RESTORED_COUNT (backup had: $BACKUP_COUNT)"

if [ "$RESTORED_COUNT" -lt "$((BACKUP_COUNT * BACKUP_VERIFY_PCT / 100))" ]; then
  fail "Restore file count is suspiciously low. Something went wrong."
fi

ok "Filesystem restored"

fi  # end phase gate: restore

# =====================================================================
# 6. Activate staged boot configuration
# =====================================================================

if [ "$START_PHASE_NUM" -le 5 ]; then

if [ "$START_PHASE_NUM" -eq 5 ]; then
  _ensure_luks_open
  _ensure_root_mounted
fi

echo ""
info "=== Phase 4: Boot Configuration ==="

STAGED="${MOUNT_DST}/root/luks-staged"

if [ ! -d "$STAGED" ]; then
  fail "Staged directory not found at $STAGED"
fi

# Mount boot partition
MOUNT_BOOT=$(mktemp -d /tmp/luks-boot.XXXXXX)
CLEANUP_TMPDIR+=("$MOUNT_BOOT")
mount "$EXT_BOOT_PART" "$MOUNT_BOOT"
CLEANUP_MOUNTS+=("$MOUNT_BOOT")

# --- Board-specific boot config ---

if [ "$BOARD_TYPE" = "rpi" ]; then
  # RPi: update cmdline.txt
  if [ -f "$MOUNT_BOOT/cmdline.txt" ]; then
    CURRENT_CMDLINE=$(cat "$MOUNT_BOOT/cmdline.txt")
    NEW_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed \
      -e 's|root=[^ ]*||g' \
      -e 's|cryptdevice=[^ ]*||g' \
      -e 's|  *| |g' \
      -e 's|^ ||' \
      -e 's| $||')
    NEW_CMDLINE="${NEW_CMDLINE} root=${ROOT_DEV} cryptdevice=UUID=${LUKS_UUID}:${LUKS_MAPPER_NAME}"
    echo "$NEW_CMDLINE" > "$MOUNT_BOOT/cmdline.txt"
    info "Updated cmdline.txt:"
    echo -e "  ${CYAN}$(cat "$MOUNT_BOOT/cmdline.txt")${NC}"
  else
    cp "${STAGED}/cmdline.txt" "$MOUNT_BOOT/cmdline.txt"
    info "Installed staged cmdline.txt"
  fi

  # Ensure auto_initramfs=1 in config.txt
  if [ -f "$MOUNT_BOOT/config.txt" ]; then
    if ! grep -q "^auto_initramfs=1" "$MOUNT_BOOT/config.txt"; then
      echo "auto_initramfs=1" >> "$MOUNT_BOOT/config.txt"
      info "Added auto_initramfs=1 to config.txt"
    else
      info "auto_initramfs=1 already in config.txt"
    fi
  fi

elif [ "$BOARD_TYPE" = "armbian" ]; then
  # Armbian: update armbianEnv.txt
  if [ -f "$MOUNT_BOOT/armbianEnv.txt" ]; then
    sed -i "s|^rootdev=.*|rootdev=${ROOT_DEV}|" "$MOUNT_BOOT/armbianEnv.txt"
    info "Updated armbianEnv.txt (rootdev=${ROOT_DEV})"
    echo -e "  ${CYAN}$(grep '^rootdev=' "$MOUNT_BOOT/armbianEnv.txt")${NC}"
  elif [ -f "${STAGED}/armbianEnv.txt" ]; then
    cp "${STAGED}/armbianEnv.txt" "$MOUNT_BOOT/armbianEnv.txt"
    info "Installed staged armbianEnv.txt"
  fi

  # Recompile boot.scr if boot.cmd exists
  if [ -f "$MOUNT_BOOT/boot.cmd" ]; then
    if command -v mkimage &>/dev/null; then
      mkimage -C none -A arm64 -T script -d "$MOUNT_BOOT/boot.cmd" "$MOUNT_BOOT/boot.scr"
      info "Recompiled boot.scr from boot.cmd"
    else
      warn "mkimage not found — cannot recompile boot.scr"
      warn "Install u-boot-tools if boot.scr needs updating"
    fi
  fi
fi

# Update crypttab in restored root (use UUID so initramfs can resolve the device in chroot)
cat > "${MOUNT_DST}/etc/crypttab" << EOF
# <target name>	<source device>		<key file>	<options>
${LUKS_MAPPER_NAME}	UUID=${LUKS_UUID}	none	luks,initramfs
EOF
info "Updated /etc/crypttab:"
echo -e "  ${CYAN}$(cat "${MOUNT_DST}/etc/crypttab")${NC}"

# Update fstab in restored root
if [ -f "${MOUNT_DST}/etc/fstab" ]; then
  # Replace root mount line to use $ROOT_DEV
  if grep -qE "^[^ ]+[ \t]+/[ \t]+ext4" "${MOUNT_DST}/etc/fstab"; then
    sed -i -E "s|^[^ ]+(\s+/\s+ext4)|${ROOT_DEV}\1|" "${MOUNT_DST}/etc/fstab"
  else
    echo "${ROOT_DEV}  /  ext4  defaults,noatime  0  1" >> "${MOUNT_DST}/etc/fstab"
  fi

  # Update boot partition mount
  if [ "$BOARD_TYPE" = "rpi" ]; then
    sed -i -E "s|^[^ ]+(\s+/boot/firmware\s+)|${PI_BOOT_PART}\1|" "${MOUNT_DST}/etc/fstab"
  elif [ "$BOARD_TYPE" = "armbian" ]; then
    BOOT_UUID=$(blkid -s UUID -o value "$EXT_BOOT_PART")
    if grep -qE "^\S+\s+/boot\s+" "${MOUNT_DST}/etc/fstab"; then
      sed -i -E "s|^[^ ]+(\s+/boot\s+)|UUID=${BOOT_UUID}\1|" "${MOUNT_DST}/etc/fstab"
    else
      echo "UUID=${BOOT_UUID}  /boot  ext4  defaults  0  2" >> "${MOUNT_DST}/etc/fstab"
    fi
  fi
  info "Updated /etc/fstab root mount to ${ROOT_DEV}"
fi

# Deploy cleanup-netplan hook into chroot
if [ -f "${STAGED}/cleanup-netplan" ]; then
  mkdir -p "${MOUNT_DST}/etc/initramfs-tools/scripts/init-bottom"
  cp "${STAGED}/cleanup-netplan" \
    "${MOUNT_DST}/etc/initramfs-tools/scripts/init-bottom/cleanup-netplan"
  chmod 755 "${MOUNT_DST}/etc/initramfs-tools/scripts/init-bottom/cleanup-netplan"
  info "Deployed cleanup-netplan to init-bottom"

  # Remove old incorrect location if present
  if [ -f "${MOUNT_DST}/etc/initramfs-tools/scripts/local-bottom/cleanup-netplan" ]; then
    rm -f "${MOUNT_DST}/etc/initramfs-tools/scripts/local-bottom/cleanup-netplan"
    info "Removed old local-bottom/cleanup-netplan"
  fi
fi

# Deploy tang_check_connection.sh into chroot
if [ -f "${STAGED}/tang_check_connection.sh" ]; then
  cp "${STAGED}/tang_check_connection.sh" "${MOUNT_DST}/root/tang_check_connection.sh"
  chmod 755 "${MOUNT_DST}/root/tang_check_connection.sh"
  info "Deployed tang_check_connection.sh to /root/"
fi

ok "Boot configuration activated"

fi  # end phase gate: bootconfig

# =====================================================================
# 7. Rebuild initramfs in chroot
# =====================================================================

if [ "$START_PHASE_NUM" -le 6 ]; then

if [ "$START_PHASE_NUM" -eq 6 ]; then
  _ensure_luks_open
  _ensure_root_mounted
  _ensure_boot_mounted
fi

echo ""
info "=== Phase 5: Initramfs Rebuild (chroot) ==="

# Bind-mount required filesystems for chroot
mount --bind /dev "${MOUNT_DST}/dev"
CLEANUP_MOUNTS+=("${MOUNT_DST}/dev")
mount --bind /dev/pts "${MOUNT_DST}/dev/pts"
CLEANUP_MOUNTS+=("${MOUNT_DST}/dev/pts")
mount -t proc proc "${MOUNT_DST}/proc"
CLEANUP_MOUNTS+=("${MOUNT_DST}/proc")
mount -t sysfs sys "${MOUNT_DST}/sys"
CLEANUP_MOUNTS+=("${MOUNT_DST}/sys")

# Bind-mount boot partition into chroot at the correct path
if [ "$BOARD_TYPE" = "rpi" ]; then
  CHROOT_BOOT_MOUNT="${MOUNT_DST}/boot/firmware"
else
  CHROOT_BOOT_MOUNT="${MOUNT_DST}/boot"
fi
mkdir -p "$CHROOT_BOOT_MOUNT"
mount --bind "$MOUNT_BOOT" "$CHROOT_BOOT_MOUNT"
CLEANUP_MOUNTS+=("$CHROOT_BOOT_MOUNT")

# For aarch64 target, we may need qemu-user-static for cross-arch chroot
if [ "$(uname -m)" != "aarch64" ]; then
  QEMU_BIN=""
  for _q in /usr/bin/qemu-aarch64-static /usr/bin/qemu-aarch64; do
    if [ -f "$_q" ]; then QEMU_BIN="$_q"; break; fi
  done
  if [ -n "$QEMU_BIN" ]; then
    cp "$QEMU_BIN" "${MOUNT_DST}/usr/bin/qemu-aarch64-static"
    info "Copied $QEMU_BIN for cross-arch chroot"
  else
    warn "No qemu-aarch64 binary found. Chroot may fail on non-aarch64 host."
    warn "Install qemu-user-static or qemu-user if chroot fails."
  fi
fi

info "Rebuilding initramfs inside chroot..."
chroot "$MOUNT_DST" /bin/bash -c "LC_ALL=C update-initramfs -u -k all" || {
  warn "Initramfs rebuild in chroot failed."
  warn "You may need to rebuild initramfs after first boot."
  warn "(Boot with LUKS passphrase, then run: sudo update-initramfs -u -k all)"
}

# Armbian: ensure uInitrd (U-Boot wrapped) exists
if [ "$BOARD_TYPE" = "armbian" ]; then
  chroot "$MOUNT_DST" /bin/bash -c '
    for KVER in $(ls /lib/modules/ 2>/dev/null); do
      if [ -f "/boot/initrd.img-${KVER}" ] && [ ! -f "/boot/uInitrd-${KVER}" ]; then
        if command -v mkimage >/dev/null 2>&1; then
          mkimage -A arm64 -T ramdisk -C gzip -n "uInitrd ${KVER}" \
            -d "/boot/initrd.img-${KVER}" "/boot/uInitrd-${KVER}"
          ln -sf "uInitrd-${KVER}" /boot/uInitrd
          echo "[INFO] Created uInitrd-${KVER}"
        else
          echo "[WARN] mkimage not found, cannot create uInitrd-${KVER}"
        fi
      fi
    done
  '
fi

ok "Initramfs rebuilt"

# Unmount chroot bind mounts (in reverse order)
for mnt in "$CHROOT_BOOT_MOUNT" "${MOUNT_DST}/sys" "${MOUNT_DST}/proc" "${MOUNT_DST}/dev/pts" "${MOUNT_DST}/dev"; do
  if mountpoint -q "$mnt" 2>/dev/null; then
    umount "$mnt"
  fi
done
# Remove these from cleanup array since we already unmounted
CLEANUP_MOUNTS=("$MOUNT_DST" "$MOUNT_BOOT")

fi  # end phase gate: initramfs

# =====================================================================
# 8. Bind clevis/tang (SSS)
# =====================================================================

if [ "$START_PHASE_NUM" -le 7 ]; then

# If resuming at clevis, we need the LUKS passphrase for binding
if [ -z "$LUKS_PASS" ]; then
  read -rsp "Enter LUKS passphrase (for clevis binding): " LUKS_PASS
  echo ""
fi

echo ""
info "=== Phase 6: Clevis/Tang Binding ==="

info "Checking tang server connectivity..."
ALL_OK=true
for SERVER in "${TANG_SERVERS[@]}"; do
  if curl -sf --max-time $TANG_TIMEOUT "${SERVER}/adv" > /dev/null 2>&1; then
    ok "$SERVER"
  else
    echo -e "  ${RED}[FAIL]${NC} $SERVER"
    ALL_OK=false
  fi
done

if [ "$ALL_OK" != "true" ]; then
  warn "Not all tang servers are reachable."
  warn "Skipping clevis binding. You can bind later with:"
  warn "  sudo /root/setup_clevis_tang.sh"
  warn "The system will boot with passphrase prompt until clevis is bound."
else
  info "Building clevis SSS configuration (threshold: $SSS_THRESHOLD)..."

  TANG_PINS="["
  FIRST=true
  for SERVER in "${TANG_SERVERS[@]}"; do
    ADV=$(curl -sfS "${SERVER}/adv")
    if [ "$FIRST" = true ]; then FIRST=false; else TANG_PINS+=","; fi
    TANG_PINS+=$(jq -n --argjson adv "$ADV" --arg url "$SERVER" \
      '{"url": $url, "adv": $adv}')
  done
  TANG_PINS+="]"

  CONFIG=$(jq -n \
    --argjson pins "$TANG_PINS" \
    --argjson t "$SSS_THRESHOLD" \
    '{"t": $t, "pins": {"tang": $pins}}')

  info "Binding clevis/tang to $EXT_ROOT_PART..."
  KEYFILE=$(mktemp)
  echo -n "$LUKS_PASS" > "$KEYFILE"
  chmod 600 "$KEYFILE"

  if clevis luks bind -k "$KEYFILE" -d "$EXT_ROOT_PART" sss "$CONFIG"; then
    ok "Clevis/tang binding successful"
  else
    warn "Clevis binding failed. You can bind later with:"
    warn "  sudo /root/setup_clevis_tang.sh"
  fi

  rm -f "$KEYFILE"
fi

fi  # end phase gate: clevis

# =====================================================================
# 9. Verify and cleanup
# =====================================================================

echo ""
info "=== Verification ==="

# Show clevis bindings
info "Clevis bindings on $EXT_ROOT_PART:"
clevis luks list -d "$EXT_ROOT_PART" 2>/dev/null || echo "  (none)"

# Verify initramfs contains clevis
if [ -n "$MOUNT_BOOT" ] && mountpoint -q "$MOUNT_BOOT" 2>/dev/null; then
  if [ "$BOARD_TYPE" = "rpi" ]; then
    INITRAMFS_FILE=$(find "$MOUNT_BOOT" -name 'initramfs*' -o -name 'initrd*' 2>/dev/null | head -1)
  else
    INITRAMFS_FILE=$(find "$MOUNT_BOOT" -name 'initrd.img-*' 2>/dev/null | head -1)
  fi
  if [ -n "$INITRAMFS_FILE" ]; then
    CLEVIS_COUNT=$(lsinitramfs "$INITRAMFS_FILE" 2>/dev/null | grep -c clevis || echo "0")
    info "Clevis hooks in initramfs: $CLEVIS_COUNT files"
  else
    info "Could not locate initramfs file for verification"
  fi
else
  info "Boot partition not mounted — skipping initramfs verification"
fi

# Clean unmount
info "Unmounting..."
[ -n "$MOUNT_DST" ] && umount "$MOUNT_DST" 2>/dev/null || true
[ -n "$MOUNT_BOOT" ] && umount "$MOUNT_BOOT" 2>/dev/null || true
CLEANUP_MOUNTS=()

if [ "$USE_LVM" = true ]; then
  vgchange -an "$LVM_VG_NAME" 2>/dev/null || true
fi
cryptsetup luksClose "$LUKS_MAPPER_NAME" 2>/dev/null || true
CLEANUP_LUKS=""

# =====================================================================
# 9b. SPI U-Boot flash for NVMe/USB boot (Rock 5B / RK3588)
# =====================================================================

if { [ "$SCENARIO" = "nvme_migrate" ] || [ "$SCENARIO" = "usb_migrate" ]; } && [ "$BOARD_TYPE" = "armbian" ]; then
  if [ "$SCENARIO" = "nvme_migrate" ]; then
    STORAGE_TYPE="NVMe"
  else
    STORAGE_TYPE="USB"
  fi
  echo ""
  info "=== SPI U-Boot Flash (${STORAGE_TYPE} Boot) ==="

  # Check for RK3588 SoC
  IS_RK3588=false
  if [ -f /proc/device-tree/compatible ]; then
    if tr '\0' '\n' < /proc/device-tree/compatible | grep -q 'rockchip,rk3588'; then
      IS_RK3588=true
    fi
  fi

  if [ "$IS_RK3588" = true ]; then
    info "Detected RK3588 SoC"

    # Check SPI device
    if [ -b /dev/mtdblock0 ]; then
      # Read first 4KB and check for existing content
      SPI_CONTENT=$(dd if=/dev/mtdblock0 bs=4096 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
      SPI_ZEROS=$(printf '%0*d' $(( ${#SPI_CONTENT} )) 0 | tr '0' '0')

      if [ "$SPI_CONTENT" = "$SPI_ZEROS" ] || [ -z "$(echo "$SPI_CONTENT" | tr -d '0')" ]; then
        SPI_STATUS="empty"
        info "SPI flash status: empty (no bootloader)"
      else
        SPI_STATUS="has_bootloader"
        info "SPI flash status: has existing bootloader"
      fi

      # Discover U-Boot SPI images
      mapfile -t SPI_IMAGES < <(find /usr/lib/linux-u-boot-* -maxdepth 1 -type f \
        \( -name "rkspi_loader*.img" -o -name "u-boot-rockchip-spi*.bin" \) 2>/dev/null)

      if [ ${#SPI_IMAGES[@]} -eq 0 ]; then
        warn "No U-Boot SPI images found in /usr/lib/linux-u-boot-*/"
        warn "Install the appropriate u-boot package for your board, then flash manually:"
        warn "  dd if=<spi-image> of=/dev/mtdblock0 conv=notrunc status=progress"
      else
        echo ""
        info "Found U-Boot SPI image(s):"
        for i in "${!SPI_IMAGES[@]}"; do
          IMG_SIZE=$(stat -c%s "${SPI_IMAGES[$i]}" 2>/dev/null || echo "?")
          echo "  $((i+1)). ${SPI_IMAGES[$i]} (${IMG_SIZE} bytes)"
        done

        # Select image
        SPI_IMAGE=""
        if [ ${#SPI_IMAGES[@]} -eq 1 ]; then
          SPI_IMAGE="${SPI_IMAGES[0]}"
        else
          echo ""
          while true; do
            read -rp "Select image number [1-${#SPI_IMAGES[@]}]: " IMG_NUM
            if [[ "$IMG_NUM" =~ ^[0-9]+$ ]] && [ "$IMG_NUM" -ge 1 ] && [ "$IMG_NUM" -le ${#SPI_IMAGES[@]} ]; then
              SPI_IMAGE="${SPI_IMAGES[$((IMG_NUM-1))]}"
              break
            fi
            warn "Invalid selection. Enter a number between 1 and ${#SPI_IMAGES[@]}."
          done
        fi

        echo ""
        if [ "$SPI_STATUS" = "has_bootloader" ]; then
          warn "SPI flash already contains a bootloader. This will overwrite it."
        fi
        info "Image: $SPI_IMAGE"
        read -rp "Write U-Boot to SPI flash for ${STORAGE_TYPE} boot? [y/N] " FLASH_CONFIRM

        if [[ "$FLASH_CONFIRM" == [yY] ]]; then
          MTD_SIZE=$(cat /sys/class/mtd/mtd0/size 2>/dev/null || echo "")
          if [ -z "$MTD_SIZE" ] || [ "$MTD_SIZE" -eq 0 ]; then
            warn "Cannot determine SPI flash size — skipping erase+write"
          else
            MTD_BLOCKS=$((MTD_SIZE / 4096))
            info "SPI flash size: $((MTD_SIZE / 1024)) KB ($MTD_BLOCKS blocks)"

            info "Erasing SPI flash..."
            dd if=/dev/zero of=/dev/mtdblock0 bs=4096 count="$MTD_BLOCKS" status=progress 2>&1
            sync

            info "Writing U-Boot to SPI flash..."
            if [[ "$SPI_IMAGE" == *.bin ]] && command -v flashcp &>/dev/null; then
              flashcp -v -p "$SPI_IMAGE" /dev/mtd0
            else
              dd if="$SPI_IMAGE" of=/dev/mtdblock0 conv=notrunc status=progress 2>&1
            fi
            sync

            # Verify: read back first 512 bytes and check non-zero
            VERIFY_DATA=$(dd if=/dev/mtdblock0 bs=512 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
            if [ -n "$(echo "$VERIFY_DATA" | tr -d '0')" ]; then
              ok "SPI flash verified — U-Boot written successfully"
              SPI_FLASHED=true
            else
              warn "SPI flash verification failed — data appears empty after write"
              warn "You may need to flash manually after reboot"
            fi
          fi
        else
          info "Skipped SPI flash. You can flash manually later:"
          info "  dd if=$SPI_IMAGE of=/dev/mtdblock0 conv=notrunc status=progress"
        fi
      fi
    else
      warn "SPI device /dev/mtdblock0 not found"
      warn "SPI flash may not be available or mtd modules not loaded"
      warn "Try: modprobe spi-rockchip-sfc"
    fi
  else
    info "Not an RK3588 board — skipping SPI flash step"
  fi
fi

# Remove backup (only if a backup was created or found)
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
  echo ""
  read -rp "Remove backup directory $BACKUP_DIR? [Y/n] " RM_BACKUP
  if [[ "$RM_BACKUP" != [nN] ]]; then
    rm -rf "$BACKUP_DIR"
    BACKUP_DIR_FOR_CLEANUP=""
    ok "Backup removed"
  else
    info "Backup kept at: $BACKUP_DIR"
    BACKUP_DIR_FOR_CLEANUP=""  # don't warn on exit since user chose to keep it
  fi
fi

echo ""
echo "================================================================="
echo -e "${GREEN}Encryption complete!${NC}"
echo "================================================================="
echo ""

if [ "$BOARD_TYPE" = "rpi" ]; then
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Insert the SD card / NVMe back into the Raspberry Pi"
  echo "  2. Connect the Pi to the network (tang servers must be reachable)"
  echo "  3. Power on the Pi"

elif [ "$BOARD_TYPE" = "armbian" ] && [ "$LOCAL_MODE" = true ]; then
  if [ "$SCENARIO" = "usb_migrate" ]; then
    STORAGE_TYPE="USB"
  else
    STORAGE_TYPE="NVMe"
  fi
  echo -e "${YELLOW}Next steps:${NC}"
  STEP=1
  if [ "$SPI_FLASHED" != true ]; then
    echo "  ${STEP}. Write U-Boot to SPI flash for ${STORAGE_TYPE} boot (if not already done)"
    STEP=$((STEP + 1))
  fi
  echo "  ${STEP}. Reboot and verify LUKS auto-unlock via clevis/tang"
  echo ""
  warn "After successful ${STORAGE_TYPE} boot, disable eMMC boot:"
  if [ -n "$SOURCE_DEVICE" ]; then
    warn "  mount ${SOURCE_DEVICE}p1 /mnt"
  else
    warn "  mount /dev/mmcblk1p1 /mnt"
  fi
  warn "  mv /mnt/boot/boot.scr /mnt/boot/boot.scr.disabled"
  warn "  umount /mnt"

elif [ "$BOARD_TYPE" = "armbian" ]; then
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Remove the SD card and boot from the encrypted eMMC/NVMe"
  echo "  2. Ensure the board is connected to the network (tang servers must be reachable)"
  echo "  3. Power on"
fi

echo ""
echo "  If clevis/tang is bound and servers are reachable:"
echo "    -> The system should boot automatically without passphrase"
echo ""
echo "  If tang servers are unreachable:"
echo "    -> You will be prompted for the LUKS passphrase at boot"
echo ""
echo "  After first successful boot, verify with:"
echo "    lsblk                                # should show ${ROOT_DEV}"
if [ "$USE_LVM" = true ]; then
echo "    pvs                                  # should show /dev/mapper/${LUKS_MAPPER_NAME} in VG ${LVM_VG_NAME}"
echo "    lvs                                  # should show ${LVM_LV_NAME} in VG ${LVM_VG_NAME}"
fi
echo "    clevis luks list -d ${PI_ROOT_PART}  # should show SSS binding"
echo "    /root/tang_check_connection.sh ${PI_ROOT_PART}"
echo ""
echo "  If clevis was not bound (tang unreachable), bind with:"
echo "    sudo /root/setup_clevis_tang.sh"
echo ""
