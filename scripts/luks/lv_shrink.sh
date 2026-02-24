#!/bin/bash
# lv_shrink.sh - Interactively shrink an LVM Logical Volume (ext4)
#
# LVM LVs with ext4 cannot be shrunk online (only grown). For mounted/root
# partitions, an offline approach via initramfs is required. This script
# guides the user through the entire process and uses the proven initrd-hook
# pattern from luks_boot_split.sh.
#
# Two paths:
#   Path A: Direct offline shrink (ext4, not mounted)
#     - e2fsck + resize2fs + lvreduce directly
#
#   Path B: initrd approach (mounted / root LVs)
#     - Installs initramfs hooks that perform the shrink at next boot
#     - Self-destructs after successful execution
#     - Logs to /var/log/lv-shrink-initrd.log
#
# Usage:
#   sudo ./lv_shrink.sh              # interactive mode
#   sudo ./lv_shrink.sh --dry-run    # show what would be done
#   sudo ./lv_shrink.sh --help       # show help

set -euo pipefail

# --- Configuration ---
MIN_LV_SIZE_MB=512             # Minimum LV size after shrink (MiB)
FS_SHRINK_BUFFER_MB=64         # Safety buffer: filesystem is shrunk this much smaller than LV target
HOOK_FILE="/etc/initramfs-tools/hooks/lv-shrink"
PREMOUNT_FILE="/etc/initramfs-tools/scripts/local-premount/lv-shrink"
CLEANUP_SERVICE="/etc/systemd/system/lv-shrink-cleanup.service"
LOG_FILE="/run/lv-shrink-initrd.log"

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
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: sudo ./lv_shrink.sh [OPTIONS]"
      echo ""
      echo "Interactively shrink an LVM Logical Volume with ext4 filesystem."
      echo ""
      echo "For unmounted LVs, the shrink is performed directly (offline)."
      echo "For mounted/root LVs, initramfs hooks are installed and the"
      echo "shrink happens at next boot when the filesystem is not mounted."
      echo ""
      echo "Options:"
      echo "  --dry-run    Show what would be done without making changes"
      echo "  -h, --help   Show this help"
      exit 0
      ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# =====================================================================
# 1. Root check and prerequisites
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  fail "This script must be run as root (sudo)."
fi

REQUIRED_CMDS=(lvs blkid findmnt e2fsck resize2fs lvreduce lvm update-initramfs lsinitramfs)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "Required command not found: $cmd"
  fi
done

if [ "$DRY_RUN" = true ]; then
  info "DRY-RUN mode — no changes will be made"
  echo ""
fi

# =====================================================================
# 2. Interactive LV selection
# =====================================================================

echo ""
echo "================================================================="
echo -e "${YELLOW}LVM Logical Volume Shrink${NC}"
echo "================================================================="
echo ""

info "Scanning Logical Volumes..."

# Build LV list
LV_LIST=()
LV_DISPLAY=()
IDX=0
while IFS='|' read -r lv_name vg_name lv_size_raw; do
  # Trim whitespace
  lv_name=$(echo "$lv_name" | xargs)
  vg_name=$(echo "$vg_name" | xargs)
  lv_size_raw=$(echo "$lv_size_raw" | xargs)

  [ -z "$lv_name" ] && continue

  LV_DEV="/dev/${vg_name}/${lv_name}"

  # Get mount points (may be multiple, e.g. / and /var/log.hdd via bind mounts)
  MOUNTPOINTS=$(findmnt -n -o TARGET "$LV_DEV" 2>/dev/null | xargs echo || true)

  # Get filesystem type
  FSTYPE=$(blkid -s TYPE -o value "$LV_DEV" 2>/dev/null || true)

  IDX=$((IDX + 1))
  LV_LIST+=("${lv_name}|${vg_name}|${LV_DEV}")
  DISPLAY_LINE="  ${IDX}) ${LV_DEV} (${lv_size_raw})"
  [ -n "$FSTYPE" ] && DISPLAY_LINE+="  fs=${FSTYPE}"
  [ -n "$MOUNTPOINTS" ] && DISPLAY_LINE+="  mounted=${MOUNTPOINTS}"
  LV_DISPLAY+=("$DISPLAY_LINE")
done < <(lvs --noheadings --separator '|' -o lv_name,vg_name,lv_size --units m 2>/dev/null)

if [ ${#LV_LIST[@]} -eq 0 ]; then
  fail "No Logical Volumes found."
fi

echo ""
echo "Available Logical Volumes:"
for line in "${LV_DISPLAY[@]}"; do
  echo "$line"
done
echo ""

while true; do
  read -rp "Select LV to shrink [1-${#LV_LIST[@]}]: " LV_SEL
  if [[ "$LV_SEL" =~ ^[0-9]+$ ]] && [ "$LV_SEL" -ge 1 ] && [ "$LV_SEL" -le ${#LV_LIST[@]} ]; then
    break
  fi
  warn "Invalid selection. Enter a number between 1 and ${#LV_LIST[@]}."
done

IFS='|' read -r _SEL_LV_NAME SEL_VG_NAME TARGET_DEV <<< "${LV_LIST[$((LV_SEL - 1))]}"

info "Selected: $TARGET_DEV"

# =====================================================================
# 3. Detect LUKS layer beneath LVM
# =====================================================================

# Check if the VG's PV sits on a LUKS device (e.g., /dev/mapper/rootfs)
PV_DEV=$(pvs --noheadings -o pv_name -S "vg_name=${SEL_VG_NAME}" 2>/dev/null | xargs)
LUKS_MAPPER_NAME=""
LUKS_BACKING_DEV=""

if [ -n "$PV_DEV" ]; then
  info "PV backing VG $SEL_VG_NAME: $PV_DEV"

  # Check if the PV is a dm-crypt / LUKS device
  if [[ "$PV_DEV" == /dev/mapper/* ]]; then
    _mapper_name="${PV_DEV#/dev/mapper/}"
    if cryptsetup status "$_mapper_name" &>/dev/null; then
      LUKS_MAPPER_NAME="$_mapper_name"
      LUKS_BACKING_DEV=$(cryptsetup status "$_mapper_name" 2>/dev/null | awk '/device:/{print $2}')
      info "LUKS detected: /dev/mapper/$LUKS_MAPPER_NAME (backing: ${LUKS_BACKING_DEV:-unknown})"
      info "The initrd shrink script will wait for LUKS decryption before proceeding"
    fi
  fi
fi

# =====================================================================
# 4. Filesystem detection and mount status
# =====================================================================

FSTYPE=$(blkid -s TYPE -o value "$TARGET_DEV" 2>/dev/null || true)

# Get all mount points for this device (may be multiple, e.g. / and bind mounts)
# Use the first mount point for df; track if / is among them for root detection
MOUNTPOINTS_ALL=()
while IFS= read -r mp; do
  mp=$(echo "$mp" | xargs)
  [ -n "$mp" ] && MOUNTPOINTS_ALL+=("$mp")
done < <(findmnt -n -o TARGET "$TARGET_DEV" 2>/dev/null || true)

MOUNTPOINT=""
IS_ROOT=false
if [ ${#MOUNTPOINTS_ALL[@]} -gt 0 ]; then
  MOUNTPOINT="${MOUNTPOINTS_ALL[0]}"
  for mp in "${MOUNTPOINTS_ALL[@]}"; do
    [ "$mp" = "/" ] && IS_ROOT=true
  done
fi

if [ "$FSTYPE" != "ext4" ]; then
  fail "Only ext4 filesystems are supported for shrinking (found: ${FSTYPE:-unknown}).
  XFS, btrfs, and other filesystems cannot be shrunk with this tool."
fi

info "Filesystem: ext4"

# Get current LV size in MiB
CURRENT_SIZE_MB=$(lvs --noheadings --nosuffix --units m -o lv_size "$TARGET_DEV" 2>/dev/null | xargs | cut -d. -f1)
info "Current LV size: ${CURRENT_SIZE_MB} MiB"

# Get used space on the filesystem
if [ -n "$MOUNTPOINT" ]; then
  USED_KB=$(df --output=used "$MOUNTPOINT" 2>/dev/null | tail -1 | xargs)
  USED_MB=$((USED_KB / 1024))
  if [ ${#MOUNTPOINTS_ALL[@]} -gt 1 ]; then
    info "Mounted at: ${MOUNTPOINTS_ALL[*]} (${USED_MB} MiB used)"
  else
    info "Mounted at: $MOUNTPOINT (${USED_MB} MiB used)"
  fi

  if [ "$IS_ROOT" = true ]; then
    info "This is the root filesystem"
  fi
else
  # Not mounted — try to get used space by temporarily mounting
  PROBE_MNT=$(mktemp -d /tmp/lv-shrink-probe.XXXXXX)
  if mount -o ro "$TARGET_DEV" "$PROBE_MNT" 2>/dev/null; then
    USED_KB=$(df --output=used "$PROBE_MNT" 2>/dev/null | tail -1 | xargs)
    USED_MB=$((USED_KB / 1024))
    umount "$PROBE_MNT"
    info "Not mounted (${USED_MB} MiB used)"
  else
    USED_MB=0
    warn "Could not determine used space (filesystem not mounted and mount failed)"
  fi
  rmdir "$PROBE_MNT" 2>/dev/null || true
fi

# =====================================================================
# 4. Target size input
# =====================================================================

echo ""
info "Enter the target size for the LV."
info "  Absolute:  e.g. 20G, 10240M"
info "  Reduction: e.g. -5G, -2048M"
echo ""

parse_size_to_mib() {
  local input="$1"
  local value

  # Strip leading +/- for parsing, track sign
  local sign=""
  if [[ "$input" == -* ]]; then
    sign="-"
    input="${input#-}"
  elif [[ "$input" == +* ]]; then
    input="${input#+}"
  fi

  # Extract numeric value and suffix
  if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[Gg]$ ]]; then
    value="${BASH_REMATCH[1]}"
    # Convert G to MiB (multiply by 1024)
    value=$(echo "$value" | awk '{printf "%d", $1 * 1024}')
  elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[Mm]$ ]]; then
    value="${BASH_REMATCH[1]}"
    value=$(echo "$value" | awk '{printf "%d", $1}')
  else
    echo ""
    return
  fi

  echo "${sign}${value}"
}

while true; do
  read -rp "Target size: " SIZE_INPUT
  TARGET_MIB=$(parse_size_to_mib "$SIZE_INPUT")

  if [ -z "$TARGET_MIB" ]; then
    warn "Invalid size format. Use e.g. 20G, 10240M, -5G, -2048M"
    continue
  fi

  # Handle relative (reduction) vs absolute
  if [[ "$TARGET_MIB" == -* ]]; then
    REDUCTION=${TARGET_MIB#-}
    TARGET_SIZE_MB=$((CURRENT_SIZE_MB - REDUCTION))
    info "Reducing by ${REDUCTION} MiB: ${CURRENT_SIZE_MB} MiB → ${TARGET_SIZE_MB} MiB"
  else
    TARGET_SIZE_MB="$TARGET_MIB"
    info "Target size: ${TARGET_SIZE_MB} MiB (currently ${CURRENT_SIZE_MB} MiB)"
  fi

  # Validations
  if [ "$TARGET_SIZE_MB" -ge "$CURRENT_SIZE_MB" ]; then
    warn "Target size (${TARGET_SIZE_MB} MiB) must be smaller than current size (${CURRENT_SIZE_MB} MiB)."
    continue
  fi

  if [ "$TARGET_SIZE_MB" -lt "$MIN_LV_SIZE_MB" ]; then
    warn "Target size (${TARGET_SIZE_MB} MiB) is below minimum (${MIN_LV_SIZE_MB} MiB)."
    continue
  fi

  if [ "$USED_MB" -gt 0 ] && [ "$TARGET_SIZE_MB" -le "$USED_MB" ]; then
    warn "Target size (${TARGET_SIZE_MB} MiB) must be larger than used space (${USED_MB} MiB)."
    continue
  fi

  # Warn if tight on space
  if [ "$USED_MB" -gt 0 ]; then
    FREE_AFTER=$((TARGET_SIZE_MB - USED_MB))
    if [ "$FREE_AFTER" -lt 512 ]; then
      warn "Only ${FREE_AFTER} MiB free after shrink — this is very tight!"
      read -rp "Continue with this size? [y/N] " TIGHT_CONFIRM
      [[ "$TIGHT_CONFIRM" == [yY] ]] || continue
    fi
  fi

  break
done

FS_TARGET_MB=$((TARGET_SIZE_MB - FS_SHRINK_BUFFER_MB))
info "Filesystem will be shrunk to ${FS_TARGET_MB} MiB (${FS_SHRINK_BUFFER_MB} MiB buffer)"
info "LV will be reduced to ${TARGET_SIZE_MB} MiB"
info "Then filesystem will be expanded to fill the LV (removing the buffer)"

# =====================================================================
# 5. Decision tree
# =====================================================================

USE_INITRD=false

if [ -z "$MOUNTPOINT" ]; then
  # Not mounted — direct offline shrink
  info "Filesystem is not mounted — using direct offline shrink (Path A)"
elif [ "$IS_ROOT" = true ]; then
  # Root filesystem — must use initrd
  info "Root filesystem — using initrd approach (Path B)"
  USE_INITRD=true
else
  # Mounted but not root — ask user
  echo ""
  echo "The filesystem is mounted at ${MOUNTPOINTS_ALL[*]}."
  echo "  1) Unmount and shrink directly (requires no processes using $MOUNTPOINT)"
  echo "  2) Use initrd approach (shrink at next boot)"
  echo ""
  read -rp "Choice [1-2]: " MOUNT_CHOICE

  if [ "$MOUNT_CHOICE" = "1" ]; then
    info "Attempting to unmount $TARGET_DEV..."
    if [ "$DRY_RUN" = true ]; then
      info "[DRY-RUN] Would unmount $MOUNTPOINT"
      MOUNTPOINT=""
    else
      if umount "$TARGET_DEV" 2>/dev/null; then
        ok "Unmounted $MOUNTPOINT"
        MOUNTPOINT=""
      else
        warn "Unmount failed (filesystem in use). Falling back to initrd approach."
        USE_INITRD=true
      fi
    fi
  else
    info "Using initrd approach (Path B)"
    USE_INITRD=true
  fi
fi

# =====================================================================
# 6. Path A: Direct offline shrink
# =====================================================================

if [ "$USE_INITRD" = false ]; then
  echo ""
  echo -e "${YELLOW}Summary — Direct Offline Shrink:${NC}"
  echo "  LV:            $TARGET_DEV"
  echo "  Current size:  ${CURRENT_SIZE_MB} MiB"
  echo "  Target size:   ${TARGET_SIZE_MB} MiB"
  echo "  FS target:     ${FS_TARGET_MB} MiB (with ${FS_SHRINK_BUFFER_MB} MiB buffer)"
  echo ""
  echo "  Steps:"
  echo "    1. e2fsck -f -y $TARGET_DEV"
  echo "    2. resize2fs $TARGET_DEV ${FS_TARGET_MB}M"
  echo "    3. lvreduce --force -L ${TARGET_SIZE_MB}M $TARGET_DEV"
  echo "    4. resize2fs $TARGET_DEV  (expand FS to fill LV, remove buffer)"
  echo ""

  if [ "$DRY_RUN" = true ]; then
    ok "[DRY-RUN] No changes made. Commands shown above."
    exit 0
  fi

  echo -e "${RED}This will shrink $TARGET_DEV. Ensure you have a backup!${NC}"
  read -rp "Type 'YES' to proceed: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }

  # Step 1: fsck
  info "Step 1/4: Running e2fsck on $TARGET_DEV..."
  e2fsck -f -y "$TARGET_DEV" || true
  ok "Filesystem check complete"

  # Step 2: Shrink filesystem
  info "Step 2/4: Shrinking filesystem to ${FS_TARGET_MB}M..."
  if ! resize2fs "$TARGET_DEV" "${FS_TARGET_MB}M"; then
    fail "resize2fs failed — filesystem may need manual repair"
  fi
  ok "Filesystem shrunk"

  # Step 3: Reduce LV
  info "Step 3/4: Reducing LV to ${TARGET_SIZE_MB}M..."
  if ! lvreduce --force -L "${TARGET_SIZE_MB}M" "$TARGET_DEV"; then
    warn "lvreduce failed — rolling back filesystem to fill current LV..."
    resize2fs "$TARGET_DEV" || true
    fail "Could not reduce LV. Filesystem has been restored to full LV size."
  fi
  ok "LV reduced"

  # Step 4: Expand filesystem to fill LV (remove buffer)
  info "Step 4/4: Expanding filesystem to fill LV..."
  e2fsck -f -y "$TARGET_DEV" || true
  resize2fs "$TARGET_DEV"
  ok "Filesystem expanded to fill LV"

  echo ""
  echo "================================================================="
  echo -e "${GREEN}LV shrink complete!${NC}"
  echo "================================================================="
  echo ""
  echo "Verify with:"
  echo "  lvs"
  echo "  e2fsck -f $TARGET_DEV"
  echo ""

# =====================================================================
# 7. Path B: initrd approach
# =====================================================================

else
  echo ""
  echo -e "${YELLOW}Summary — initrd Shrink (at next boot):${NC}"
  echo "  LV:            $TARGET_DEV"
  echo "  VG:            $SEL_VG_NAME"
  if [ -n "$LUKS_MAPPER_NAME" ]; then
  echo "  LUKS:          /dev/mapper/$LUKS_MAPPER_NAME (backing: ${LUKS_BACKING_DEV:-unknown})"
  echo "                 Premount script will wait for LUKS decryption (PREREQ=cryptroot)"
  fi
  echo "  Current size:  ${CURRENT_SIZE_MB} MiB"
  echo "  Target size:   ${TARGET_SIZE_MB} MiB"
  echo "  FS target:     ${FS_TARGET_MB} MiB (with ${FS_SHRINK_BUFFER_MB} MiB buffer)"
  echo ""
  echo "  The following will happen at next boot (in initramfs):"
  STEP_NUM=0
  if [ -n "$LUKS_MAPPER_NAME" ]; then
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. Wait for LUKS decryption (/dev/mapper/$LUKS_MAPPER_NAME, up to 60s)"
  fi
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. Activate VG ($SEL_VG_NAME)"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. e2fsck -f -y $TARGET_DEV"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. resize2fs -f $TARGET_DEV ${FS_TARGET_MB}M"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. lvreduce --force -L ${TARGET_SIZE_MB}M $TARGET_DEV"
  echo "       (on failure: resize2fs rollback, continue boot)"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. resize2fs -f $TARGET_DEV  (expand FS to fill LV)"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. Self-destruct (remove initramfs hooks)"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. Schedule initramfs rebuild (systemd oneshot service)"
  STEP_NUM=$((STEP_NUM + 1))
  echo "    ${STEP_NUM}. Log results to $LOG_FILE"
  echo ""

  if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}--- Hook file: $HOOK_FILE ---${NC}"
    cat << 'DRY_HOOKEOF'
#!/bin/sh -e
PREREQS=""
case $1 in
prereqs) echo "${PREREQS}"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /sbin/e2fsck /sbin
copy_exec /sbin/resize2fs /sbin
copy_exec /sbin/blkid /sbin
copy_exec /sbin/lvm /sbin
DRY_HOOKEOF

    # Determine prereqs for dry-run display
    _DRY_PREREQ=""
    _DRY_LUKS_MAPPER=""
    if [ -n "$LUKS_MAPPER_NAME" ]; then
      _DRY_PREREQ="cryptroot"
      _DRY_LUKS_MAPPER="$LUKS_MAPPER_NAME"
    fi

    echo ""
    echo -e "${CYAN}--- Premount script: $PREMOUNT_FILE ---${NC}"
    cat << DRY_SCRIPTEOF
#!/bin/sh
# One-shot LV shrink — runs in initramfs before root is mounted.
# Self-destructs after execution.

PREREQ="${_DRY_PREREQ}"
prereqs() { echo "\$PREREQ"; }
case \$1 in
prereqs) prereqs; exit 0;;
esac

TARGET_DEV="${TARGET_DEV}"
VG_NAME="${SEL_VG_NAME}"
FS_TARGET_MB=${FS_TARGET_MB}
TARGET_SIZE_MB=${TARGET_SIZE_MB}
LUKS_MAPPER="${_DRY_LUKS_MAPPER}"

RUN_LOG="${LOG_FILE}"
log_msg() { echo "lv-shrink: \$*"; echo "\$(date '+%Y-%m-%d %H:%M:%S'): \$*" >> "\${RUN_LOG}" 2>/dev/null || true; }
trap 'log_msg "ERROR at line \$LINENO — continuing boot"; exit 0' ERR

log_msg "Starting LV shrink: \${TARGET_DEV} → \${TARGET_SIZE_MB}M"

# Wait for LUKS decryption (if applicable)
if [ -n "\${LUKS_MAPPER}" ]; then
  log_msg "Waiting for LUKS device /dev/mapper/\${LUKS_MAPPER}..."
  WAIT_COUNT=0; MAX_WAIT=60
  while [ ! -b "/dev/mapper/\${LUKS_MAPPER}" ] && [ "\$WAIT_COUNT" -lt "\$MAX_WAIT" ]; do
    sleep 1; WAIT_COUNT=\$((WAIT_COUNT + 1))
  done
  [ -b "/dev/mapper/\${LUKS_MAPPER}" ] || { log_msg "LUKS not available — aborting"; exit 0; }
  log_msg "LUKS device available after \${WAIT_COUNT}s"
fi

lvm vgchange -ay "\${VG_NAME}"
e2fsck -f -y "\${TARGET_DEV}" 2>> "\${RUN_LOG}" || true
if ! resize2fs -f "\${TARGET_DEV}" "\${FS_TARGET_MB}M" 2>> "\${RUN_LOG}"; then
  log_msg "resize2fs shrink FAILED — aborting, continuing boot"
  exit 0
fi
if ! lvm lvreduce --force -L "\${TARGET_SIZE_MB}M" "\${TARGET_DEV}" 2>> "\${RUN_LOG}"; then
  log_msg "lvreduce FAILED — rolling back filesystem"
  resize2fs -f "\${TARGET_DEV}" 2>> "\${RUN_LOG}" || true
  exit 0
fi
e2fsck -f -y "\${TARGET_DEV}" 2>> "\${RUN_LOG}" || true
resize2fs -f "\${TARGET_DEV}" 2>> "\${RUN_LOG}"

# Self-destruct and schedule initramfs rebuild
TMPROOT=\$(mktemp -d)
if mount "\${TARGET_DEV}" "\${TMPROOT}"; then
  rm -f "\${TMPROOT}${HOOK_FILE}" "\${TMPROOT}${PREMOUNT_FILE}"
  log_msg "Removed initramfs hooks from root filesystem"

  # Install oneshot service to rebuild initramfs on next boot
  cat > "\${TMPROOT}${CLEANUP_SERVICE}" << 'SVCEOF'
[Unit]
Description=LV shrink cleanup - rebuild initramfs without shrink tools
After=local-fs.target
ConditionPathExists=${CLEANUP_SERVICE}

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'update-initramfs -u -k all; systemctl disable lv-shrink-cleanup.service; rm -f ${CLEANUP_SERVICE}'

[Install]
WantedBy=multi-user.target
SVCEOF
  mkdir -p "\${TMPROOT}/etc/systemd/system/multi-user.target.wants"
  ln -sf "${CLEANUP_SERVICE}" "\${TMPROOT}/etc/systemd/system/multi-user.target.wants/lv-shrink-cleanup.service"
  log_msg "Installed cleanup service for initramfs rebuild"

  umount "\${TMPROOT}"
else
  log_msg "WARNING: Could not mount root for self-destruct"
fi
rmdir "\${TMPROOT}" 2>/dev/null || true

log_msg "LV shrink complete!"
exit 0
DRY_SCRIPTEOF
    echo ""
    ok "[DRY-RUN] No changes made. Hook content shown above."
    exit 0
  fi

  echo -e "${RED}This will install initramfs hooks to shrink $TARGET_DEV at next boot.${NC}"
  echo -e "${RED}Ensure you have a backup!${NC}"
  read -rp "Type 'YES' to proceed: " CONFIRM
  [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }

  # --- Install hook ---
  info "Creating initramfs hook..."

  cat > "$HOOK_FILE" << 'HOOKEOF'
#!/bin/sh -e
PREREQS=""
case $1 in
prereqs) echo "${PREREQS}"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /sbin/e2fsck /sbin
copy_exec /sbin/resize2fs /sbin
copy_exec /sbin/blkid /sbin
copy_exec /sbin/lvm /sbin
HOOKEOF
  chmod +x "$HOOK_FILE"
  ok "Created $HOOK_FILE"

  # --- Install local-premount script ---
  info "Creating local-premount script..."

  # Determine prereqs for the premount script
  if [ -n "$LUKS_MAPPER_NAME" ]; then
    PREMOUNT_PREREQ="cryptroot"
    PREMOUNT_LUKS_MAPPER="$LUKS_MAPPER_NAME"
  else
    PREMOUNT_PREREQ=""
    PREMOUNT_LUKS_MAPPER=""
  fi

  cat > "$PREMOUNT_FILE" << SCRIPTEOF
#!/bin/sh
# One-shot LV shrink — runs in initramfs before root is mounted.
# Self-destructs after successful execution.

PREREQ="${PREMOUNT_PREREQ}"
prereqs() { echo "\$PREREQ"; }
case \$1 in
prereqs) prereqs; exit 0;;
esac

# Baked-in values from lv_shrink.sh
TARGET_DEV="${TARGET_DEV}"
VG_NAME="${SEL_VG_NAME}"
FS_TARGET_MB=${FS_TARGET_MB}
TARGET_SIZE_MB=${TARGET_SIZE_MB}
LUKS_MAPPER="${PREMOUNT_LUKS_MAPPER}"

RUN_LOG="${LOG_FILE}"

log_msg() {
  echo "lv-shrink: \$*"
  echo "\$(date '+%Y-%m-%d %H:%M:%S'): \$*" >> "\${RUN_LOG}" 2>/dev/null || true
}

# All errors exit 0 to never block boot
trap 'log_msg "ERROR at line \$LINENO — continuing boot"; exit 0' ERR

log_msg "Starting LV shrink: \${TARGET_DEV} → \${TARGET_SIZE_MB}M"

# Step 0: Wait for LUKS decryption (if LV sits on a LUKS device)
if [ -n "\${LUKS_MAPPER}" ]; then
  log_msg "Waiting for LUKS device /dev/mapper/\${LUKS_MAPPER}..."
  WAIT_COUNT=0
  MAX_WAIT=60
  while [ ! -b "/dev/mapper/\${LUKS_MAPPER}" ] && [ "\$WAIT_COUNT" -lt "\$MAX_WAIT" ]; do
    sleep 1
    WAIT_COUNT=\$((WAIT_COUNT + 1))
  done
  if [ ! -b "/dev/mapper/\${LUKS_MAPPER}" ]; then
    log_msg "LUKS device /dev/mapper/\${LUKS_MAPPER} not available after \${MAX_WAIT}s — aborting shrink"
    exit 0
  fi
  log_msg "LUKS device available after \${WAIT_COUNT}s"
fi

# Step 1: Activate LVM
log_msg "Activating VG \${VG_NAME}..."
lvm vgchange -ay "\${VG_NAME}"

# Step 2: fsck
log_msg "Running e2fsck on \${TARGET_DEV}..."
e2fsck -f -y "\${TARGET_DEV}" 2>> "\${RUN_LOG}" || true

# Step 3: Shrink filesystem (with -f to force past needs_recovery flag)
log_msg "Shrinking filesystem to \${FS_TARGET_MB}M..."
if ! resize2fs -f "\${TARGET_DEV}" "\${FS_TARGET_MB}M" 2>> "\${RUN_LOG}"; then
  log_msg "resize2fs shrink FAILED — aborting, continuing boot"
  exit 0
fi

# Step 4: Reduce LV
log_msg "Reducing LV to \${TARGET_SIZE_MB}M..."
if ! lvm lvreduce --force -L "\${TARGET_SIZE_MB}M" "\${TARGET_DEV}" 2>> "\${RUN_LOG}"; then
  log_msg "lvreduce FAILED — rolling back filesystem"
  resize2fs -f "\${TARGET_DEV}" 2>> "\${RUN_LOG}" || true
  exit 0
fi

# Step 5: Expand filesystem to fill LV (remove buffer)
log_msg "Expanding filesystem to fill LV..."
e2fsck -f -y "\${TARGET_DEV}" 2>> "\${RUN_LOG}" || true
resize2fs -f "\${TARGET_DEV}" 2>> "\${RUN_LOG}"

# Step 6: Self-destruct — mount root, remove hooks, schedule initramfs rebuild
log_msg "Self-destructing hooks..."
TMPROOT=\$(mktemp -d)
if mount "\${TARGET_DEV}" "\${TMPROOT}"; then
  rm -f "\${TMPROOT}${HOOK_FILE}"
  rm -f "\${TMPROOT}${PREMOUNT_FILE}"
  log_msg "Removed initramfs hooks from root filesystem"

  # Install oneshot service to rebuild initramfs on next boot (removes shrink tools from initrd)
  cat > "\${TMPROOT}${CLEANUP_SERVICE}" << 'SVCEOF'
[Unit]
Description=LV shrink cleanup - rebuild initramfs without shrink tools
After=local-fs.target
ConditionPathExists=${CLEANUP_SERVICE}

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'update-initramfs -u -k all; systemctl disable lv-shrink-cleanup.service; rm -f ${CLEANUP_SERVICE}'

[Install]
WantedBy=multi-user.target
SVCEOF
  mkdir -p "\${TMPROOT}/etc/systemd/system/multi-user.target.wants"
  ln -sf "${CLEANUP_SERVICE}" "\${TMPROOT}/etc/systemd/system/multi-user.target.wants/lv-shrink-cleanup.service"
  log_msg "Installed cleanup service for initramfs rebuild"

  umount "\${TMPROOT}"
else
  log_msg "WARNING: Could not mount root for self-destruct — hooks remain, remove manually"
fi
rmdir "\${TMPROOT}" 2>/dev/null || true

log_msg "LV shrink complete!"
exit 0
SCRIPTEOF
  chmod +x "$PREMOUNT_FILE"
  ok "Created $PREMOUNT_FILE"

  # --- Rebuild initramfs ---
  info "Rebuilding initramfs..."
  update-initramfs -u -k all
  ok "Initramfs rebuilt"

  # --- Verify tools are in the initrd ---
  info "Verifying initrd contents..."
  INITRD_FILE=$(find /boot -name 'initrd.img-*' -o -name 'initramfs*' 2>/dev/null | sort -V | tail -1)
  if [ -n "$INITRD_FILE" ]; then
    INITRD_CONTENTS=$(lsinitramfs "$INITRD_FILE" 2>/dev/null || true)
    MISSING_TOOLS=()
    for tool in lvm e2fsck resize2fs; do
      if ! echo "$INITRD_CONTENTS" | grep -q "/$tool\$"; then
        MISSING_TOOLS+=("$tool")
      fi
    done
    if [ ${#MISSING_TOOLS[@]} -eq 0 ]; then
      ok "All required tools found in initrd ($INITRD_FILE)"
    else
      warn "Tools NOT found in initrd: ${MISSING_TOOLS[*]}"
      warn "The shrink may fail at boot. Check hook output and rebuild with:"
      warn "  update-initramfs -u -k all"
    fi
  else
    warn "Could not locate initrd file for verification"
  fi

  # --- Done ---
  echo ""
  echo "================================================================="
  echo -e "${GREEN}LV shrink hooks installed!${NC}"
  echo "================================================================="
  echo ""
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Reboot now: sudo reboot"
  echo "  2. The LV shrink happens automatically during boot"
  echo "     (you will see 'lv-shrink:' messages in the boot log)"
  echo "  3. After reboot, verify:"
  echo "     lvs                                    — check new LV size"
  echo "     df -h                                  — check filesystem size"
  echo "     cat $LOG_FILE   — check shrink log"
  echo "     (log is on tmpfs — save it before next reboot)"
  echo "  4. A cleanup service will automatically rebuild the initramfs"
  echo "     (removes shrink tools from initrd, then self-destructs)"
  echo ""
  echo -e "${CYAN}Installed hooks (self-destruct after successful shrink):${NC}"
  echo "  $HOOK_FILE"
  echo "  $PREMOUNT_FILE"
  echo "  Cleanup: $CLEANUP_SERVICE (runs once after successful boot)"
  echo ""
fi
