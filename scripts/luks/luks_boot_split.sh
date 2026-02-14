#!/bin/bash
# luks_boot_split.sh - Create a separate /boot partition on Armbian boards
#
# Two modes:
#
# ON-BOARD MODE (default when running on live Armbian):
#   The root filesystem cannot be shrunk while mounted (ext4 does not support
#   online shrinking). This mode installs initramfs hooks that perform the
#   resize offline at next boot, when the root partition is not yet mounted.
#   Flow:
#     1. Run this script on the live system → installs initramfs hooks
#     2. Reboot → hooks run in initramfs (root unmounted), split partition
#     3. After reboot, /boot is a separate partition → run luks_prepare.sh
#
# EXTERNAL MODE (auto-detected or --external):
#   When running on a different host with the SD card plugged in (unmounted),
#   the split is performed directly — no initramfs hooks or reboot needed.
#   Flow:
#     1. Plug SD card into external host
#     2. Run: sudo ./luks_boot_split.sh [--external /dev/sdX]
#     3. /boot is split immediately → proceed with luks_prepare.sh
#
# Usage:
#   sudo ./luks_boot_split.sh                  # on-board mode (live Armbian)
#   sudo ./luks_boot_split.sh --external       # external mode (auto-detect device)
#   sudo ./luks_boot_split.sh --external /dev/sdX  # external mode (explicit device)

set -euo pipefail

# --- Configuration ---
BOOT_SIZE_MB=1536                 # Boot partition size in MiB (1.5 GB)
MIN_ROOT_SIZE_MB=4096             # Minimum root partition size after shrink (MiB)
SHRINK_BUFFER_MB=64               # Safety buffer when shrinking filesystem (MiB)
BOOT_LABEL="armbi_boot"           # Filesystem label for the boot partition
PARTPROBE_DELAY=1                 # Seconds to wait after partprobe for partition table refresh

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

# --- Parse flags ---
EXTERNAL_MODE=false
EXTERNAL_DEVICE=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: sudo ./luks_boot_split.sh [OPTIONS]"
      echo ""
      echo "Create a separate /boot partition on Armbian boards."
      echo ""
      echo "Modes:"
      echo "  On-board (default on live Armbian):"
      echo "    Installs initramfs hooks; split happens at next reboot."
      echo ""
      echo "  External (auto-detected or --external):"
      echo "    Splits partition directly on an unmounted SD card."
      echo "    Auto-activates when not running on Armbian."
      echo ""
      echo "Options:"
      echo "  --external             Force external mode (auto-detect device)"
      echo "  --external /dev/sdX    External mode with explicit device"
      echo "  --external=/dev/sdX    Same, alternate syntax"
      echo "  -h, --help             Show this help"
      exit 0
      ;;
    --external)
      EXTERNAL_MODE=true
      ;;
    --external=*)
      EXTERNAL_MODE=true
      EXTERNAL_DEVICE="${arg#--external=}"
      ;;
    /dev/*)
      # Bare device path after --external
      if [ "$EXTERNAL_MODE" = true ] && [ -z "$EXTERNAL_DEVICE" ]; then
        EXTERNAL_DEVICE="$arg"
      else
        echo "Unknown option: $arg"; exit 1
      fi
      ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# =====================================================================
# 1. Root check
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  fail "This script must be run as root (sudo)."
fi

# =====================================================================
# 2. Mode detection
# =====================================================================

# Auto-detect external mode: if we're NOT on an Armbian system, we must
# be running on an external host with the SD card plugged in.
if [ "$EXTERNAL_MODE" = false ] && [ ! -f /boot/armbianEnv.txt ]; then
  info "Not running on Armbian — switching to external mode"
  EXTERNAL_MODE=true
fi

if [ "$EXTERNAL_MODE" = true ]; then
  # ===================================================================
  # EXTERNAL MODE — direct offline split
  # ===================================================================

  info "=== External/Offline Boot Split Mode ==="

  # --- Prerequisite checks ---
  for cmd in parted resize2fs e2fsck mkfs.ext4 blkid; do
    command -v "$cmd" &>/dev/null || fail "Required command not found: $cmd"
  done

  # --- Device selection ---
  if [ -z "$EXTERNAL_DEVICE" ]; then
    info "Searching for removable block devices..."
    echo ""

    # List candidate devices (removable or USB-attached, excluding the host root disk)
    HOST_ROOT_DISK="/dev/$(lsblk -n -o PKNAME "$(findmnt -n -o SOURCE /)" | head -1)"
    CANDIDATES=()
    while IFS= read -r line; do
      dev=$(echo "$line" | awk '{print $1}')
      [ "/dev/$dev" = "$HOST_ROOT_DISK" ] && continue
      CANDIDATES+=("/dev/$dev")
    done < <(lsblk -d -n -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -E 'usb|mmc' || true)

    # Also check for non-host sd* devices (USB card readers may show as scsi)
    while IFS= read -r line; do
      dev=$(echo "$line" | awk '{print $1}')
      devpath="/dev/$dev"
      [ "$devpath" = "$HOST_ROOT_DISK" ] && continue
      # Skip if already in candidates
      local_found=false
      for c in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
        [ "$c" = "$devpath" ] && local_found=true
      done
      [ "$local_found" = true ] && continue
      # Only include if it has partitions (not empty disks)
      if lsblk -n -o TYPE "$devpath" 2>/dev/null | grep -q part; then
        CANDIDATES+=("$devpath")
      fi
    done < <(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -E '^sd' || true)

    if [ ${#CANDIDATES[@]} -eq 0 ]; then
      fail "No removable devices found. Specify device explicitly: --external /dev/sdX"
    fi

    if [ ${#CANDIDATES[@]} -eq 1 ]; then
      EXTERNAL_DEVICE="${CANDIDATES[0]}"
      info "Auto-selected device: $EXTERNAL_DEVICE"
    else
      echo "Multiple candidate devices found:"
      for i in "${!CANDIDATES[@]}"; do
        dev="${CANDIDATES[$i]}"
        dev_info=$(lsblk -d -n -o SIZE,MODEL "$dev" 2>/dev/null | xargs)
        echo "  $((i+1)). $dev  ($dev_info)"
      done
      echo ""
      read -rp "Select device [1-${#CANDIDATES[@]}]: " SEL
      if [[ ! "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt ${#CANDIDATES[@]} ]; then
        fail "Invalid selection"
      fi
      EXTERNAL_DEVICE="${CANDIDATES[$((SEL-1))]}"
    fi
  fi

  # Validate the device
  if [ ! -b "$EXTERNAL_DEVICE" ]; then
    fail "Device not found: $EXTERNAL_DEVICE"
  fi

  # Check it's not the host root disk
  HOST_ROOT_DISK="/dev/$(lsblk -n -o PKNAME "$(findmnt -n -o SOURCE /)" | head -1)"
  if [ "$EXTERNAL_DEVICE" = "$HOST_ROOT_DISK" ]; then
    fail "Device $EXTERNAL_DEVICE is the host's root disk — cannot split externally"
  fi

  info "Target device: $EXTERNAL_DEVICE"
  echo ""
  lsblk "$EXTERNAL_DEVICE"
  echo ""

  # --- Detect partitions ---
  PART_COUNT=$(lsblk -n -o TYPE "$EXTERNAL_DEVICE" 2>/dev/null | grep -c part || true)
  if [ "$PART_COUNT" -ne 1 ]; then
    fail "Expected exactly 1 partition on $EXTERNAL_DEVICE (found $PART_COUNT). Already split or not a fresh Armbian image."
  fi

  # Determine the single root partition
  ROOT_PART=$(lsblk -n -o NAME,TYPE "$EXTERNAL_DEVICE" 2>/dev/null | awk '$2=="part"{print $1}' | head -1)
  if [[ "$EXTERNAL_DEVICE" == *nvme* ]] || [[ "$EXTERNAL_DEVICE" == *mmcblk* ]]; then
    ROOT_PART_DEV="${EXTERNAL_DEVICE}p${ROOT_PART##*[!0-9]}"
    # Simpler: just get the first partition
    ROOT_PART_NUM=$(lsblk -n -o NAME "$EXTERNAL_DEVICE" | grep -oE '[0-9]+$' | head -1)
    ROOT_PART_DEV="${EXTERNAL_DEVICE}p${ROOT_PART_NUM}"
  else
    ROOT_PART_NUM=$(lsblk -n -o NAME "$EXTERNAL_DEVICE" | grep -oE '[0-9]+$' | head -1)
    ROOT_PART_DEV="${EXTERNAL_DEVICE}${ROOT_PART_NUM}"
  fi

  if [ ! -b "$ROOT_PART_DEV" ]; then
    fail "Could not find root partition device (expected $ROOT_PART_DEV)"
  fi

  info "Root partition: $ROOT_PART_DEV (partition $ROOT_PART_NUM)"

  # Verify it's not mounted
  if findmnt -n "$ROOT_PART_DEV" &>/dev/null; then
    fail "Partition $ROOT_PART_DEV is currently mounted — unmount it first"
  fi

  # Verify it's an Armbian root (mount temporarily to check)
  VERIFY_MNT=$(mktemp -d /tmp/bootsplit-verify.XXXXXX)
  mount -o ro "$ROOT_PART_DEV" "$VERIFY_MNT"
  if [ ! -f "$VERIFY_MNT/boot/armbianEnv.txt" ]; then
    umount "$VERIFY_MNT"
    rmdir "$VERIFY_MNT"
    fail "Not an Armbian root filesystem — /boot/armbianEnv.txt not found on $ROOT_PART_DEV"
  fi
  umount "$VERIFY_MNT"
  rmdir "$VERIFY_MNT"
  ok "Confirmed Armbian root filesystem on $ROOT_PART_DEV"

  # --- Compute sizes (shared logic) ---
  DISK="$EXTERNAL_DEVICE"
  CURRENT_ROOT_DEV="$ROOT_PART_DEV"
  CURRENT_ROOT_DISK="$DISK"
  CURRENT_ROOT_PART_NUM="$ROOT_PART_NUM"
  BOOT_PART_NUM=$((CURRENT_ROOT_PART_NUM + 1))

  if [[ "$CURRENT_ROOT_DISK" == *nvme* ]] || [[ "$CURRENT_ROOT_DISK" == *mmcblk* ]]; then
    BOOT_PART_DEV="${CURRENT_ROOT_DISK}p${BOOT_PART_NUM}"
  else
    BOOT_PART_DEV="${CURRENT_ROOT_DISK}${BOOT_PART_NUM}"
  fi

  if [ -b "$BOOT_PART_DEV" ]; then
    fail "Partition $BOOT_PART_DEV already exists — cannot create boot partition there."
  fi

  SHRINK_MB=$BOOT_SIZE_MB

  # --- Fix GPT if needed (common when smaller image flashed to larger disk) ---
  # Uses ---pretend-input-tty to capture all output (parted -s writes warnings to /dev/tty)
  GPT_CHECK=$(printf 'Fix\nFix\n' | LC_ALL=C parted ---pretend-input-tty "$CURRENT_ROOT_DISK" unit MiB print 2>&1) || true
  if echo "$GPT_CHECK" | grep -qiE 'Not all.*space|nicht.*belegt'; then
    ok "Fixed GPT backup header to span full disk"
  fi

  # --- Detect free space after root partition ---
  PARTED_OUTPUT=$(LC_ALL=C parted -s "$CURRENT_ROOT_DISK" unit MiB print)
  DISK_SIZE_MB=$(echo "$PARTED_OUTPUT" | grep "^Disk ${CURRENT_ROOT_DISK}:" | grep -oE '[0-9]+MiB' | tr -d 'MiB')
  PART_START_MB=$(echo "$PARTED_OUTPUT" | grep "^ *${CURRENT_ROOT_PART_NUM} " | awk '{print $2}' | tr -d 'MiB' | cut -d. -f1)
  ROOT_END_CURRENT_MB=$(echo "$PARTED_OUTPUT" | grep "^ *${CURRENT_ROOT_PART_NUM} " | awk '{print $3}' | tr -d 'MiB' | cut -d. -f1)

  if [ -z "$PART_START_MB" ] || [ -z "$ROOT_END_CURRENT_MB" ]; then
    fail "Could not determine partition layout for partition $CURRENT_ROOT_PART_NUM"
  fi
  if [ -z "$DISK_SIZE_MB" ]; then
    fail "Could not determine disk size for $CURRENT_ROOT_DISK"
  fi

  FREE_SPACE_MB=$((DISK_SIZE_MB - ROOT_END_CURRENT_MB))
  CURRENT_SIZE_SECTORS=$(blockdev --getsz "$CURRENT_ROOT_DEV")
  SECTOR_SIZE=$(blockdev --getss "$CURRENT_ROOT_DEV")
  CURRENT_SIZE_MB=$((CURRENT_SIZE_SECTORS * SECTOR_SIZE / 1024 / 1024))

  info "Disk size: ${DISK_SIZE_MB}MiB, root ends at: ${ROOT_END_CURRENT_MB}MiB, free after root: ${FREE_SPACE_MB}MiB"

  if [ "$FREE_SPACE_MB" -ge "$SHRINK_MB" ]; then
    # --- Append strategy: grow root, place /boot at end of disk ---
    APPEND_STRATEGY=true
    # Last ~1MiB is reserved for GPT backup header; use 100% in mkpart for exact end
    BOOT_START_MB=$((DISK_SIZE_MB - SHRINK_MB))
    ROOT_NEW_END_MB=$((BOOT_START_MB - 1))

    info "Append strategy: enough free space (${FREE_SPACE_MB}MiB >= ${SHRINK_MB}MiB)"
    info "Root partition: ${PART_START_MB}MiB → ${ROOT_NEW_END_MB}MiB (was ${ROOT_END_CURRENT_MB}MiB)"
    info "Boot partition: ${BOOT_START_MB}MiB → end of disk (~${SHRINK_MB}MiB)"
  else
    # --- Shrink strategy: shrink root to make room for /boot ---
    APPEND_STRATEGY=false
    NEW_ROOT_SIZE_MB=$((CURRENT_SIZE_MB - SHRINK_MB))

    if [ "$NEW_ROOT_SIZE_MB" -lt $MIN_ROOT_SIZE_MB ]; then
      fail "Root partition too small to shrink by ${SHRINK_MB}MB (current: ${CURRENT_SIZE_MB}MB, would leave: ${NEW_ROOT_SIZE_MB}MB). Not enough free space after root either (${FREE_SPACE_MB}MiB)."
    fi

    ROOT_END_MB=$((PART_START_MB + NEW_ROOT_SIZE_MB))
    BOOT_START_MB=$((ROOT_END_MB + 1))
    BOOT_END_MB=$((BOOT_START_MB + SHRINK_MB))
    RESIZE_TARGET_MB=$((NEW_ROOT_SIZE_MB - SHRINK_BUFFER_MB))

    info "Shrink strategy: insufficient free space (${FREE_SPACE_MB}MiB < ${SHRINK_MB}MiB)"
    info "Current root: ${CURRENT_SIZE_MB}MB (starts at ${PART_START_MB}MiB)"
    info "After split:  root=${NEW_ROOT_SIZE_MB}MB, boot=${SHRINK_MB}MB"
    info "Partition end positions: root=${ROOT_END_MB}MiB, boot=${BOOT_END_MB}MiB"
  fi

  echo ""
  if [ "$APPEND_STRATEGY" = true ]; then
    echo -e "${YELLOW}This will grow root and create /boot at the end of ${EXTERNAL_DEVICE}:${NC}"
    echo "  1. Grow root partition (${ROOT_END_CURRENT_MB}MiB → ${ROOT_NEW_END_MB}MiB)"
    echo "  2. Create /boot partition at end of disk (${SHRINK_MB}MB)"
    echo "  3. Format boot partition as ext4"
    echo "  4. Copy /boot contents to new partition"
    echo "  5. Update fstab with /boot mount"
    echo "  6. Expand root filesystem to fill grown partition"
  else
    echo -e "${YELLOW}This will directly split the partition on ${EXTERNAL_DEVICE}:${NC}"
    echo "  1. Check and shrink root filesystem offline (e2fsck + resize2fs)"
    echo "  2. Shrink root partition (parted resizepart)"
    echo "  3. Create new /boot partition (${SHRINK_MB}MB ext4)"
    echo "  4. Copy /boot contents to new partition"
    echo "  5. Update fstab with /boot mount"
    echo "  6. Expand root filesystem to fill resized partition"
  fi
  echo ""
  echo -e "${RED}Ensure you have a backup before proceeding!${NC}"
  echo ""
  read -rp "Type 'YES' to proceed: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }

  # --- Perform the split directly ---

  # Cleanup on exit
  CLEANUP_MOUNTS=()
  CLEANUP_TMPDIRS=()
  cleanup_external() {
    set +e
    for (( i=${#CLEANUP_MOUNTS[@]}-1 ; i>=0 ; i-- )); do
      mnt="${CLEANUP_MOUNTS[$i]}"
      if [ -n "$mnt" ] && mountpoint -q "$mnt" 2>/dev/null; then
        umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      fi
    done
    for dir in "${CLEANUP_TMPDIRS[@]+"${CLEANUP_TMPDIRS[@]}"}"; do
      if [ -n "$dir" ] && [ -d "$dir" ]; then
        rmdir "$dir" 2>/dev/null || true
      fi
    done
  }
  trap cleanup_external EXIT

  STEP=0
  if [ "$APPEND_STRATEGY" = true ]; then
    TOTAL_STEPS=6
  else
    TOTAL_STEPS=8
  fi

  if [ "$APPEND_STRATEGY" = false ]; then
    # Step: fsck
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Running e2fsck on ${CURRENT_ROOT_DEV}..."
    e2fsck -f -y "$CURRENT_ROOT_DEV" || true
    ok "Filesystem check complete"

    # Step: Shrink filesystem offline
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Shrinking filesystem to ${RESIZE_TARGET_MB}M..."
    if ! resize2fs "$CURRENT_ROOT_DEV" "${RESIZE_TARGET_MB}M"; then
      fail "resize2fs shrink failed — filesystem may need manual repair"
    fi
    ok "Filesystem shrunk"

    # Step: Shrink root partition
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Shrinking root partition to end at ${ROOT_END_MB}MiB..."
    if ! yes | parted ---pretend-input-tty "$CURRENT_ROOT_DISK" resizepart "$CURRENT_ROOT_PART_NUM" "${ROOT_END_MB}MiB"; then
      warn "parted resizepart failed — expanding filesystem back"
      resize2fs "$CURRENT_ROOT_DEV" || true
      fail "Could not shrink root partition"
    fi
    ok "Root partition shrunk"

    # Step: Create new boot partition (shrink: placed after shrunk root)
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Creating boot partition (${BOOT_START_MB}MiB to ${BOOT_END_MB}MiB)..."
    if ! parted -s "$CURRENT_ROOT_DISK" mkpart boot ext4 "${BOOT_START_MB}MiB" "${BOOT_END_MB}MiB"; then
      warn "parted mkpart failed — reverting root partition"
      parted -s "$CURRENT_ROOT_DISK" resizepart "$CURRENT_ROOT_PART_NUM" 100% || true
      resize2fs "$CURRENT_ROOT_DEV" || true
      fail "Could not create boot partition"
    fi
  else
    # Step: Grow root partition to fill disk (minus boot reservation)
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Growing root partition (${ROOT_END_CURRENT_MB}MiB → ${ROOT_NEW_END_MB}MiB)..."
    if ! parted -s "$CURRENT_ROOT_DISK" resizepart "$CURRENT_ROOT_PART_NUM" "${ROOT_NEW_END_MB}MiB"; then
      fail "Could not grow root partition"
    fi
    ok "Root partition grown"

    # Step: Create /boot partition at end of disk
    STEP=$((STEP + 1))
    info "Step ${STEP}/${TOTAL_STEPS}: Creating boot partition at end of disk (${BOOT_START_MB}MiB to end, ~${SHRINK_MB}MiB)..."
    if ! parted -s "$CURRENT_ROOT_DISK" mkpart boot ext4 "${BOOT_START_MB}MiB" 100%; then
      fail "Could not create boot partition"
    fi
  fi
  # Wait for partition to appear
  sleep $PARTPROBE_DELAY
  partprobe "$CURRENT_ROOT_DISK" 2>/dev/null || true
  sleep $PARTPROBE_DELAY
  if [ ! -b "$BOOT_PART_DEV" ]; then
    fail "Boot partition device $BOOT_PART_DEV did not appear after mkpart"
  fi
  ok "Boot partition created: $BOOT_PART_DEV"

  # Step: Format boot partition
  STEP=$((STEP + 1))
  info "Step ${STEP}/${TOTAL_STEPS}: Formatting ${BOOT_PART_DEV} as ext4..."
  mkfs.ext4 -L "$BOOT_LABEL" "$BOOT_PART_DEV"
  ok "Boot partition formatted"

  # Step: Copy /boot contents
  STEP=$((STEP + 1))
  info "Step ${STEP}/${TOTAL_STEPS}: Copying /boot to new partition..."
  TMPROOT=$(mktemp -d /tmp/bootsplit-root.XXXXXX)
  TMPBOOT=$(mktemp -d /tmp/bootsplit-boot.XXXXXX)
  CLEANUP_TMPDIRS+=("$TMPROOT" "$TMPBOOT")

  mount "$CURRENT_ROOT_DEV" "$TMPROOT"
  CLEANUP_MOUNTS+=("$TMPROOT")
  mount "$BOOT_PART_DEV" "$TMPBOOT"
  CLEANUP_MOUNTS+=("$TMPBOOT")

  if [ -d "$TMPROOT/boot" ]; then
    cp -a "$TMPROOT/boot/." "$TMPBOOT/"
    ok "Copied /boot contents"
  else
    warn "/boot directory not found on root — skipping copy"
  fi

  # Set legacy_boot flag on the boot partition so U-Boot's distro_bootcmd
  # scans it BEFORE partition 1 (rootfs). Without this flag, U-Boot finds
  # boot.scr on partition 1 first and loads the old kernel from there.
  # Also clear any legacy_boot flag on the root partition to be safe.
  parted -s "$CURRENT_ROOT_DISK" set "$CURRENT_ROOT_PART_NUM" legacy_boot off 2>/dev/null || true
  if parted -s "$CURRENT_ROOT_DISK" set "$BOOT_PART_NUM" legacy_boot on 2>/dev/null; then
    ok "Set legacy_boot flag on partition ${BOOT_PART_NUM} (cleared on partition ${CURRENT_ROOT_PART_NUM})"
  else
    warn "Could not set legacy_boot flag — U-Boot may still boot from partition 1"
  fi

  # Step: Update fstab
  STEP=$((STEP + 1))
  info "Step ${STEP}/${TOTAL_STEPS}: Updating fstab..."
  BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART_DEV")
  if [ -n "$BOOT_UUID" ] && [ -f "$TMPROOT/etc/fstab" ]; then
    if grep -qE "^\S+\s+/boot\s+" "$TMPROOT/etc/fstab"; then
      sed -i -E "s|^[^ ]+(\s+/boot\s+)|UUID=${BOOT_UUID}\1|" "$TMPROOT/etc/fstab"
    else
      echo "UUID=${BOOT_UUID}  /boot  ext4  defaults  0  2" >> "$TMPROOT/etc/fstab"
    fi
    ok "Updated fstab with /boot UUID=${BOOT_UUID}"
  else
    warn "Could not update fstab (UUID=${BOOT_UUID:-empty})"
  fi

  # Unmount before final resize
  umount "$TMPBOOT"
  umount "$TMPROOT"
  CLEANUP_MOUNTS=()

  # Step: Expand root filesystem to fill partition
  STEP=$((STEP + 1))
  info "Step ${STEP}/${TOTAL_STEPS}: Expanding root filesystem to fill partition..."
  e2fsck -f -y "$CURRENT_ROOT_DEV" || true
  resize2fs "$CURRENT_ROOT_DEV"
  ok "Root filesystem expanded"

  # --- Done ---
  echo ""
  echo "================================================================="
  echo -e "${GREEN}Boot partition split complete!${NC}"
  echo "================================================================="
  echo ""
  echo "Partition layout:"
  lsblk "$EXTERNAL_DEVICE"
  echo ""
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Insert the SD card into the Armbian board"
  echo "  2. Boot the board — /boot should mount automatically"
  echo "  3. Run luks_prepare.sh on the board"
  echo ""

else
  # ===================================================================
  # ON-BOARD MODE — initramfs hooks (existing behavior)
  # ===================================================================

  # --- Safety checks ---
  if [ ! -f /boot/armbianEnv.txt ]; then
    fail "This script is for Armbian boards only (/boot/armbianEnv.txt not found)."
  fi

  if mountpoint -q /boot 2>/dev/null; then
    fail "/boot is already a separate mount — no split needed."
  fi

  # --- Detect root device and partition layout ---

  info "Detecting board model..."
  if [ -f /proc/device-tree/model ]; then
    BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    info "Model: $BOARD_MODEL"
  else
    BOARD_MODEL="Unknown"
    warn "Could not detect board model"
  fi

  CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
  CURRENT_ROOT_DISK="/dev/$(lsblk -n -o PKNAME "$CURRENT_ROOT_DEV" | head -1)"
  CURRENT_ROOT_PART_NUM=$(echo "$CURRENT_ROOT_DEV" | grep -oE '[0-9]+$')

  info "Root device: $CURRENT_ROOT_DEV (disk: $CURRENT_ROOT_DISK, partition: $CURRENT_ROOT_PART_NUM)"

  PART_COUNT=$(lsblk -n -o TYPE "$CURRENT_ROOT_DISK" 2>/dev/null | grep -c part || true)
  BOOT_PART_NUM=$((CURRENT_ROOT_PART_NUM + 1))

  if [[ "$CURRENT_ROOT_DISK" == *nvme* ]] || [[ "$CURRENT_ROOT_DISK" == *mmcblk* ]]; then
    BOOT_PART_DEV="${CURRENT_ROOT_DISK}p${BOOT_PART_NUM}"
  else
    BOOT_PART_DEV="${CURRENT_ROOT_DISK}${BOOT_PART_NUM}"
  fi

  if [ -b "$BOOT_PART_DEV" ]; then
    fail "Partition $BOOT_PART_DEV already exists — cannot create boot partition there."
  fi

  # --- Compute sizes ---
  SHRINK_MB=$BOOT_SIZE_MB

  # --- Fix GPT if needed (common when smaller image flashed to larger disk) ---
  GPT_CHECK=$(printf 'Fix\nFix\n' | LC_ALL=C parted ---pretend-input-tty "$CURRENT_ROOT_DISK" unit MiB print 2>&1) || true
  if echo "$GPT_CHECK" | grep -qiE 'Not all.*space|nicht.*belegt'; then
    ok "Fixed GPT backup header to span full disk"
  fi

  # --- Detect free space after root partition ---
  PARTED_OUTPUT=$(LC_ALL=C parted -s "$CURRENT_ROOT_DISK" unit MiB print)
  DISK_SIZE_MB=$(echo "$PARTED_OUTPUT" | grep "^Disk ${CURRENT_ROOT_DISK}:" | grep -oE '[0-9]+MiB' | tr -d 'MiB')
  PART_START_MB=$(echo "$PARTED_OUTPUT" | grep "^ *${CURRENT_ROOT_PART_NUM} " | awk '{print $2}' | tr -d 'MiB' | cut -d. -f1)
  ROOT_END_CURRENT_MB=$(echo "$PARTED_OUTPUT" | grep "^ *${CURRENT_ROOT_PART_NUM} " | awk '{print $3}' | tr -d 'MiB' | cut -d. -f1)

  if [ -z "$PART_START_MB" ] || [ -z "$ROOT_END_CURRENT_MB" ]; then
    fail "Could not determine partition layout for partition $CURRENT_ROOT_PART_NUM"
  fi
  if [ -z "$DISK_SIZE_MB" ]; then
    fail "Could not determine disk size for $CURRENT_ROOT_DISK"
  fi

  FREE_SPACE_MB=$((DISK_SIZE_MB - ROOT_END_CURRENT_MB))
  CURRENT_SIZE_SECTORS=$(blockdev --getsz "$CURRENT_ROOT_DEV")
  SECTOR_SIZE=$(blockdev --getss "$CURRENT_ROOT_DEV")
  CURRENT_SIZE_MB=$((CURRENT_SIZE_SECTORS * SECTOR_SIZE / 1024 / 1024))

  info "Disk size: ${DISK_SIZE_MB}MiB, root ends at: ${ROOT_END_CURRENT_MB}MiB, free after root: ${FREE_SPACE_MB}MiB"

  if [ "$FREE_SPACE_MB" -ge "$SHRINK_MB" ]; then
    # --- Append strategy: grow root, place /boot at end of disk ---
    APPEND_STRATEGY=true
    # Last ~1MiB is reserved for GPT backup header; use 100% in mkpart for exact end
    BOOT_START_MB=$((DISK_SIZE_MB - SHRINK_MB))
    ROOT_NEW_END_MB=$((BOOT_START_MB - 1))

    info "Append strategy: enough free space (${FREE_SPACE_MB}MiB >= ${SHRINK_MB}MiB)"
    info "Root partition: ${PART_START_MB}MiB → ${ROOT_NEW_END_MB}MiB (was ${ROOT_END_CURRENT_MB}MiB)"
    info "Boot partition: ${BOOT_START_MB}MiB → end of disk (~${SHRINK_MB}MiB)"
  else
    # --- Shrink strategy: shrink root to make room for /boot ---
    APPEND_STRATEGY=false
    NEW_ROOT_SIZE_MB=$((CURRENT_SIZE_MB - SHRINK_MB))

    if [ "$NEW_ROOT_SIZE_MB" -lt $MIN_ROOT_SIZE_MB ]; then
      fail "Root partition too small to shrink by ${SHRINK_MB}MB (current: ${CURRENT_SIZE_MB}MB, would leave: ${NEW_ROOT_SIZE_MB}MB). Not enough free space after root either (${FREE_SPACE_MB}MiB)."
    fi

    ROOT_END_MB=$((PART_START_MB + NEW_ROOT_SIZE_MB))
    BOOT_START_MB=$((ROOT_END_MB + 1))
    BOOT_END_MB=$((BOOT_START_MB + SHRINK_MB))
    RESIZE_TARGET_MB=$((NEW_ROOT_SIZE_MB - SHRINK_BUFFER_MB))

    info "Shrink strategy: insufficient free space (${FREE_SPACE_MB}MiB < ${SHRINK_MB}MiB)"
    info "Current root: ${CURRENT_SIZE_MB}MB (starts at ${PART_START_MB}MiB)"
    info "After split:  root=${NEW_ROOT_SIZE_MB}MB, boot=${SHRINK_MB}MB"
    info "Partition end positions: root=${ROOT_END_MB}MiB, boot=${BOOT_END_MB}MiB"
  fi

  echo ""
  echo -e "${YELLOW}This will:${NC}"
  echo "  1. Install initramfs hooks for offline boot partition split"
  echo "  2. Rebuild initramfs"
  if [ "$APPEND_STRATEGY" = true ]; then
    echo "  3. At next boot (in initramfs, root unmounted):"
    echo "     a. Grow root partition (${ROOT_END_CURRENT_MB}MiB → ${ROOT_NEW_END_MB}MiB)"
    echo "     b. Create /boot partition at end of disk (${SHRINK_MB}MB ext4)"
    echo "     c. Copy /boot contents to new partition"
    echo "     d. Add /boot to fstab"
    echo "     e. Expand root filesystem to fill grown partition"
    echo "     f. Self-destruct (remove initramfs hooks)"
  else
    echo "  3. At next boot (in initramfs, root unmounted):"
    echo "     a. Shrink root filesystem offline (resize2fs)"
    echo "     b. Shrink root partition (parted resizepart)"
    echo "     c. Create new /boot partition (${SHRINK_MB}MB ext4)"
    echo "     d. Copy /boot contents to new partition"
    echo "     e. Add /boot to fstab"
    echo "     f. Expand root filesystem to fill resized partition"
    echo "     g. Self-destruct (remove initramfs hooks)"
  fi
  echo ""
  echo -e "${RED}Ensure you have a backup before proceeding!${NC}"
  echo ""
  read -rp "Type 'YES' to proceed: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }

  # --- Install required packages ---

  info "Ensuring required packages are installed..."
  NEEDED_PKGS=""
  for pkg in parted e2fsprogs; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      NEEDED_PKGS="$NEEDED_PKGS $pkg"
    fi
  done

  if [ -n "$NEEDED_PKGS" ]; then
    apt-get update -qq
    apt-get install -y $NEEDED_PKGS
    ok "Installed:$NEEDED_PKGS"
  else
    ok "Required packages already installed"
  fi

  # --- Create initramfs hook ---

  info "Creating initramfs hook..."

  cat > /etc/initramfs-tools/hooks/boot-split << 'HOOKEOF'
#!/bin/sh -e
PREREQS=""
case $1 in
prereqs) echo "${PREREQS}"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /sbin/resize2fs /sbin
copy_exec /sbin/e2fsck /sbin
copy_exec /sbin/mkfs.ext4 /sbin
copy_exec /sbin/parted /sbin
copy_exec /sbin/blkid /sbin
HOOKEOF
  chmod +x /etc/initramfs-tools/hooks/boot-split
  ok "Created /etc/initramfs-tools/hooks/boot-split"

  # --- Create local-premount script ---

  info "Creating local-premount boot-split script..."

  if [ "$APPEND_STRATEGY" = true ]; then
    # --- Append strategy: grow root, place /boot at end of disk ---
    cat > /etc/initramfs-tools/scripts/local-premount/boot-split << SCRIPTEOF
#!/bin/sh
# One-shot boot partition split (append strategy) — runs in initramfs before root is mounted.
# Grows root partition, then creates /boot at end of disk.
# Self-destructs after successful execution.

PREREQ=""
prereqs() { echo "\$PREREQ"; }
case \$1 in
prereqs) prereqs; exit 0;;
esac

# Baked-in values from luks_boot_split.sh
ROOT_DEV="${CURRENT_ROOT_DEV}"
ROOT_DISK="${CURRENT_ROOT_DISK}"
ROOT_PART_NUM=${CURRENT_ROOT_PART_NUM}
BOOT_PART_NUM=${BOOT_PART_NUM}
BOOT_PART_DEV="${BOOT_PART_DEV}"
ROOT_NEW_END_MB=${ROOT_NEW_END_MB}
BOOT_START_MB=${BOOT_START_MB}

log_msg() { echo "boot-split: \$*"; }

# All errors exit 0 to never block boot
trap 'log_msg "ERROR at line \$LINENO — continuing boot"; exit 0' ERR

log_msg "Starting offline boot partition split (append strategy — grow root, boot at end)"

# Step 1: Grow root partition
log_msg "Growing root partition to \${ROOT_NEW_END_MB}MiB..."
if ! parted -s "\${ROOT_DISK}" resizepart "\${ROOT_PART_NUM}" "\${ROOT_NEW_END_MB}MiB"; then
  log_msg "parted resizepart (grow) FAILED — aborting split"
  exit 0
fi

# Step 2: Create /boot partition at end of disk
log_msg "Creating boot partition at end of disk (\${BOOT_START_MB}MiB to end)..."
if ! parted -s "\${ROOT_DISK}" mkpart boot ext4 "\${BOOT_START_MB}MiB" 100%; then
  log_msg "parted mkpart FAILED — aborting split"
  exit 0
fi

# Step 3: Format boot partition
log_msg "Formatting \${BOOT_PART_DEV} as ext4..."
mkfs.ext4 -L "${BOOT_LABEL}" "\${BOOT_PART_DEV}"

# Step 4: Copy /boot contents
log_msg "Copying /boot to new partition..."
TMPROOT=\$(mktemp -d)
TMPBOOT=\$(mktemp -d)

mount "\${ROOT_DEV}" "\${TMPROOT}"
mount "\${BOOT_PART_DEV}" "\${TMPBOOT}"

if [ -d "\${TMPROOT}/boot" ]; then
  cp -a "\${TMPROOT}/boot/." "\${TMPBOOT}/"
  log_msg "Copied /boot contents"
else
  log_msg "WARNING: /boot directory not found on root — skipping copy"
fi

# Set legacy_boot flag so U-Boot scans boot partition before rootfs partition.
# Clear any legacy_boot on root partition to be safe.
parted -s "\${ROOT_DISK}" set "\${ROOT_PART_NUM}" legacy_boot off 2>/dev/null || true
parted -s "\${ROOT_DISK}" set "\${BOOT_PART_NUM}" legacy_boot on 2>/dev/null \
  && log_msg "Set legacy_boot flag on partition \${BOOT_PART_NUM} (cleared on partition \${ROOT_PART_NUM})" \
  || log_msg "WARNING: Could not set legacy_boot flag"

# Step 5: Add /boot to fstab
BOOT_UUID=\$(blkid -s UUID -o value "\${BOOT_PART_DEV}")
if [ -n "\${BOOT_UUID}" ] && [ -f "\${TMPROOT}/etc/fstab" ]; then
  if grep -qE "^\S+\s+/boot\s+" "\${TMPROOT}/etc/fstab"; then
    sed -i -E "s|^[^ ]+(\s+/boot\s+)|UUID=\${BOOT_UUID}\1|" "\${TMPROOT}/etc/fstab"
  else
    echo "UUID=\${BOOT_UUID}  /boot  ext4  defaults  0  2" >> "\${TMPROOT}/etc/fstab"
  fi
  log_msg "Updated fstab with /boot UUID=\${BOOT_UUID}"
fi

# Step 6: Self-destruct — remove hooks from root filesystem
rm -f "\${TMPROOT}/etc/initramfs-tools/hooks/boot-split"
rm -f "\${TMPROOT}/etc/initramfs-tools/scripts/local-premount/boot-split"
log_msg "Removed initramfs hooks (self-destruct)"

umount "\${TMPBOOT}"
umount "\${TMPROOT}"
rmdir "\${TMPBOOT}" "\${TMPROOT}" 2>/dev/null || true

# Step 7: Expand root filesystem to fill grown partition
log_msg "Expanding root filesystem to fill partition..."
e2fsck -f -y "\${ROOT_DEV}" || true
resize2fs "\${ROOT_DEV}"

log_msg "Boot partition split complete!"
exit 0
SCRIPTEOF
  else
    # --- Shrink strategy: full initramfs script with shrink steps ---
    cat > /etc/initramfs-tools/scripts/local-premount/boot-split << SCRIPTEOF
#!/bin/sh
# One-shot boot partition split (shrink strategy) — runs in initramfs before root is mounted.
# Self-destructs after successful execution.

PREREQ=""
prereqs() { echo "\$PREREQ"; }
case \$1 in
prereqs) prereqs; exit 0;;
esac

# Baked-in values from luks_boot_split.sh
ROOT_DEV="${CURRENT_ROOT_DEV}"
ROOT_DISK="${CURRENT_ROOT_DISK}"
ROOT_PART_NUM=${CURRENT_ROOT_PART_NUM}
BOOT_PART_NUM=${BOOT_PART_NUM}
BOOT_PART_DEV="${BOOT_PART_DEV}"
RESIZE_TARGET_MB=${RESIZE_TARGET_MB}
ROOT_END_MB=${ROOT_END_MB}
BOOT_START_MB=${BOOT_START_MB}
BOOT_END_MB=${BOOT_END_MB}

log_msg() { echo "boot-split: \$*"; }

# All errors exit 0 to never block boot
trap 'log_msg "ERROR at line \$LINENO — continuing boot"; exit 0' ERR

log_msg "Starting offline boot partition split (shrink strategy)"

# Step 1: fsck
log_msg "Running e2fsck on \${ROOT_DEV}..."
e2fsck -f -y "\${ROOT_DEV}" || true

# Step 2: Shrink filesystem offline
log_msg "Shrinking filesystem to \${RESIZE_TARGET_MB}M..."
if ! resize2fs "\${ROOT_DEV}" "\${RESIZE_TARGET_MB}M"; then
  log_msg "resize2fs shrink FAILED — aborting split"
  exit 0
fi

# Step 3: Shrink root partition
log_msg "Shrinking root partition to end at \${ROOT_END_MB}MiB..."
if ! yes | parted ---pretend-input-tty "\${ROOT_DISK}" resizepart "\${ROOT_PART_NUM}" "\${ROOT_END_MB}MiB"; then
  log_msg "parted resizepart FAILED — expanding filesystem back"
  resize2fs "\${ROOT_DEV}" || true
  exit 0
fi

# Step 4: Create new boot partition
log_msg "Creating boot partition (\${BOOT_START_MB}MiB to \${BOOT_END_MB}MiB)..."
if ! parted -s "\${ROOT_DISK}" mkpart boot ext4 "\${BOOT_START_MB}MiB" "\${BOOT_END_MB}MiB"; then
  log_msg "parted mkpart FAILED — expanding root filesystem back"
  parted -s "\${ROOT_DISK}" resizepart "\${ROOT_PART_NUM}" 100% || true
  resize2fs "\${ROOT_DEV}" || true
  exit 0
fi

# Step 5: Format boot partition
log_msg "Formatting \${BOOT_PART_DEV} as ext4..."
mkfs.ext4 -L "${BOOT_LABEL}" "\${BOOT_PART_DEV}"

# Step 6: Copy /boot contents
log_msg "Copying /boot to new partition..."
TMPROOT=\$(mktemp -d)
TMPBOOT=\$(mktemp -d)

mount "\${ROOT_DEV}" "\${TMPROOT}"
mount "\${BOOT_PART_DEV}" "\${TMPBOOT}"

# Copy boot directory contents
if [ -d "\${TMPROOT}/boot" ]; then
  cp -a "\${TMPROOT}/boot/." "\${TMPBOOT}/"
  log_msg "Copied /boot contents"
else
  log_msg "WARNING: /boot directory not found on root — skipping copy"
fi

# Set legacy_boot flag so U-Boot scans boot partition before rootfs partition.
# Clear any legacy_boot on root partition to be safe.
parted -s "\${ROOT_DISK}" set "\${ROOT_PART_NUM}" legacy_boot off 2>/dev/null || true
parted -s "\${ROOT_DISK}" set "\${BOOT_PART_NUM}" legacy_boot on 2>/dev/null \
  && log_msg "Set legacy_boot flag on partition \${BOOT_PART_NUM} (cleared on partition \${ROOT_PART_NUM})" \
  || log_msg "WARNING: Could not set legacy_boot flag"

# Step 7: Add /boot to fstab
BOOT_UUID=\$(blkid -s UUID -o value "\${BOOT_PART_DEV}")
if [ -n "\${BOOT_UUID}" ] && [ -f "\${TMPROOT}/etc/fstab" ]; then
  if grep -qE "^\S+\s+/boot\s+" "\${TMPROOT}/etc/fstab"; then
    # Update existing /boot line
    sed -i -E "s|^[^ ]+(\s+/boot\s+)|UUID=\${BOOT_UUID}\1|" "\${TMPROOT}/etc/fstab"
  else
    echo "UUID=\${BOOT_UUID}  /boot  ext4  defaults  0  2" >> "\${TMPROOT}/etc/fstab"
  fi
  log_msg "Updated fstab with /boot UUID=\${BOOT_UUID}"
fi

# Step 8: Self-destruct — remove hooks from root filesystem
rm -f "\${TMPROOT}/etc/initramfs-tools/hooks/boot-split"
rm -f "\${TMPROOT}/etc/initramfs-tools/scripts/local-premount/boot-split"
log_msg "Removed initramfs hooks (self-destruct)"

umount "\${TMPBOOT}"
umount "\${TMPROOT}"
rmdir "\${TMPBOOT}" "\${TMPROOT}" 2>/dev/null || true

# Step 9: Expand root filesystem to fill resized partition
log_msg "Expanding root filesystem to fill partition..."
e2fsck -f -y "\${ROOT_DEV}" || true
resize2fs "\${ROOT_DEV}"

log_msg "Boot partition split complete!"
exit 0
SCRIPTEOF
  fi
  chmod +x /etc/initramfs-tools/scripts/local-premount/boot-split
  ok "Created /etc/initramfs-tools/scripts/local-premount/boot-split"

  # --- Rebuild initramfs ---

  info "Rebuilding initramfs..."
  update-initramfs -u -k all
  ok "Initramfs rebuilt"

  # --- Done ---

  echo ""
  echo "================================================================="
  echo -e "${GREEN}Boot split hooks installed!${NC}"
  echo "================================================================="
  echo ""
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Reboot now: sudo reboot"
  echo "  2. The boot partition split happens automatically during boot"
  echo "     (you will see 'boot-split:' messages in the boot log)"
  echo "  3. After reboot, verify:"
  echo "     lsblk    — should show two partitions"
  echo "     df -h    — /boot should be mounted"
  echo "  4. Run luks_prepare.sh — it will detect /boot and proceed normally"
  echo ""
  echo -e "${CYAN}Installed hooks (self-destruct after successful split):${NC}"
  echo "  /etc/initramfs-tools/hooks/boot-split"
  echo "  /etc/initramfs-tools/scripts/local-premount/boot-split"
  echo ""
fi
