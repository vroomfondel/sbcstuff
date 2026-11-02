#!/bin/bash
# luks_encrypt.sh - Encrypt a root partition with LUKS + clevis/tang
#
# Supports:
#   - Raspberry Pi: runs on EXTERNAL machine with Pi's SD/NVMe plugged in
#   - Armbian NVMe/USB migration: runs LOCALLY on the same board (target != boot disk)
#   - Armbian in-place: runs from SD card against eMMC
#   - Raspberry Pi OS card prepared offline (scenario rpi_offline): the card was
#     never booted, luks_prepare.sh --offline staged everything on it
#
# Prerequisites:
#   - luks_prepare.sh has been run first
#   - cryptsetup, clevis, clevis-luks, curl, jq, rsync installed
#
# Usage: sudo ./luks_encrypt.sh
#        sudo ./luks_encrypt.sh --device=/dev/sdX   # Skip the device prompt (confirmation stays)
#        sudo ./luks_encrypt.sh --usb-key-file=/path/to/usb.key   # Plus a USB stick keyslot (needs luks_prepare.sh --usb-key)
#        sudo ./luks_encrypt.sh --lv-size=50G   # Set root LV size (default: 100%FREE)
#        sudo ./luks_encrypt.sh --spi-only       # Flash U-Boot to SPI only (skip encryption)
#        sudo ./luks_encrypt.sh --start-phase=clevis
#        sudo ./luks_encrypt.sh --start-phase=restore --backup-dir=/tmp/luks-backup.abc123
#        sudo ./luks_encrypt.sh --list-phases
#
# Fully non-interactive (offline card, nothing is asked):
#        sudo ./luks_encrypt.sh --device=/dev/sdX --yes --passphrase-file=/path/to/pass \
#             --tang=http://a,http://b --keep-backup

set -euo pipefail
umask 022   # files written into the target get standard modes, whatever the calling shell has set

# --- Parse flags ---
SPI_ONLY=false
START_PHASE=""
BACKUP_DIR_OVERRIDE=""
LIST_PHASES=false
YES_MODE=false                    # --yes: answer every confirmation prompt (no SPI flash)
PASSPHRASE_FILE=""                # --passphrase-file=<path>: LUKS passphrase, first line
TANG_ARG=""                       # --tang=<url1>,<url2>: tang servers (override script and luks.conf)
KEEP_BACKUP=false                 # --keep-backup: keep the backup directory, do not ask
REMOVE_BACKUP=false               # --remove-backup: remove the backup directory, do not ask
DEVICE_ARG=""                     # --device=<dev>: target device, skips the interactive prompt
USB_KEY_FILE=""                   # --usb-key-file=<path>: key for the USB stick keyslot (created if missing)
ALLOW_LOOP=false                  # --allow-loop: accept /dev/loopN as target (test only)
# Offline mode state, filled from luks.conf (see _read_offline_conf)
FIRST_BOOT_PENDING=""             # "yes": the card was never booted (rpi_offline)
NET_DRIVERS=""                    # space separated NIC modules the initramfs must contain
OFFLINE_HOST_DEVICE=""            # host device the card was prepared on (hint only)
# USB key state, filled from luks.conf (see _read_offline_conf) and the key file
USB_KEY=""                        # "yes": luks_prepare.sh --usb-key installed the initramfs fallback
USB_KEY_LABEL=""                  # filesystem label of the stick (luks.conf)
USB_KEY_HOST=""                   # host name that names luks-keys/<host>.key (luks.conf)
USB_KEY_VALUE=""                  # the key: first line of --usb-key-file
USB_KEY_ROOT_PATH="/etc/clevis-keyfile/fallback.key"  # master copy on the encrypted root (read by clevis_keyfile_write_usb.sh)
USB_KEY_WARNED=false              # the "no USB_KEY in luks.conf" warning was shown
LUKS_CONF_READ=false              # a luks.conf was read (the USB_KEY values are known)
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
      echo "  - Raspberry Pi OS card prepared offline (luks_prepare.sh --offline, scenario rpi_offline):"
      echo "    the card was never booted; its first-boot state is kept intact and verified"
      echo ""
      echo "Prerequisites:"
      echo "  - luks_prepare.sh has been run on the target board first"
      echo "  - cryptsetup, clevis, clevis-luks, curl, jq, rsync installed"
      echo ""
      echo "Options:"
      echo "  --device=DEV           Target device (e.g., /dev/sdb); skips the device prompt. DEV must be a"
      echo "                         whole disk, not mounted and not part of the running system. The device"
      echo "                         layout and the final YES confirmation are still shown"
      echo "  --allow-loop           Accept a loop device (/dev/loopN with /dev/loopNp1 and p2) as target."
      echo "                         For tests with an image file only, never for real cards"
      echo "  --yes                  Non-interactive: answer every confirmation (Continue?, Type YES) with yes,"
      echo "                         the SPI flash question with no. The device is NOT prompted for: --device="
      echo "                         is required. A typed passphrase is still asked, and a too short one is"
      echo "                         still confirmed, unless --passphrase-file is used"
      echo "  --passphrase-file=PATH LUKS passphrase: first line of PATH, only the trailing newline is stripped."
      echo "                         Used for luksFormat, luksOpen and the clevis binding. The file is only read,"
      echo "                         never changed or deleted. Fails if missing, empty or shorter than ${MIN_PASSPHRASE_LEN:-8}"
      echo "                         characters (no 'use anyway?' question)"
      echo "  --tang=URL1,URL2       Exactly two tang servers (SSS threshold 2), override script and luks.conf"
      echo "  --usb-key-file=PATH    Add a USB stick key as a further keyslot (needs luks_prepare.sh --usb-key,"
      echo "                         which installs the initramfs fallback and writes USB_KEY=\"yes\" to luks.conf;"
      echo "                         then this option is REQUIRED and the run fails early without it). If PATH is a"
      echo "                         directory (the mounted stick), the key is <dir>/luks-keys/<host>.key with <host> ="
      echo "                         USB_KEY_HOST from luks.conf (luks-keys/ is created, the label is checked). If the"
      echo "                         file does not exist, 48 random bytes are generated as one base64 line of 64 characters"
      echo "                         (mode 600, never overwritten). If it exists, its first line is the key (the file"
      echo "                         is only read, never changed or deleted). The key is stored without trailing"
      echo "                         newline as /etc/clevis-keyfile/fallback.key on the encrypted root and added with"
      echo "                         cryptsetup luksAddKey (authorised by the passphrase); the run then proves that the"
      echo "                         key unlocks and that the keyslot count rose. Works with --start-phase=clevis|verify."
      echo "                         The stick: any filesystem (vfat, exfat, ext4), label LUKSKEY (mkfs.vfat -n LUKSKEY"
      echo "                         /dev/sdY1, or e2label), with the key as luks-keys/<hostname>.key (or luks-fallback.key"
      echo "                         in its root), see the next steps printed at the end. At boot the initramfs offers"
      echo "                         tang, the stick and the typed passphrase in parallel, the first valid answer wins;"
      echo "                         stick plus card unlock the system without tang or passphrase"
      echo "  --keep-backup          Keep the backup directory at the end without asking"
      echo "  --remove-backup        Remove the backup directory at the end without asking"
      echo "                         (mutually exclusive with --keep-backup)"
      echo "  --lv-size=SIZE         Set root LV size (e.g., 50G, 50%FREE; default: 100%FREE)"
      echo "  --spi-only             Flash U-Boot to SPI only (skip encryption)"
      echo "  --start-phase=PHASE    Resume from a specific phase (name or number)"
      echo "  --backup-dir=PATH      Fresh run: directory in which the backup is created (never asks for one,"
      echo "                         fails if it is too small). With --start-phase: the existing backup directory"
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
      echo "Without a terminal on stdin every question that is still open fails with a message naming the"
      echo "option that avoids it."
      echo ""
      echo "Examples:"
      echo "  sudo ./luks_encrypt.sh"
      echo "  # fully non-interactive (offline card):"
      echo "  sudo ./luks_encrypt.sh --device=/dev/sdX --yes --passphrase-file=/path/to/pass --tang=http://a,http://b --keep-backup"
      echo "  sudo ./luks_encrypt.sh --device=/dev/sdb"
      echo "  # card prepared with luks_prepare.sh --usb-key (stick unlock next to tang):"
      echo "  sudo ./luks_encrypt.sh --device=/dev/sdX --usb-key-file=/path/to/usb.key"
      echo "  sudo ./luks_encrypt.sh --start-phase=clevis --usb-key-file=/path/to/usb.key"
      echo "  sudo ./luks_encrypt.sh --lv-size=50G"
      echo "  sudo ./luks_encrypt.sh --start-phase=clevis"
      echo "  sudo ./luks_encrypt.sh --start-phase=restore --backup-dir=/tmp/luks-backup.abc123"
      exit 0
      ;;
    --device=?*) DEVICE_ARG="${arg#--device=}" ;;
    --device|--device=) echo "--device requires a value: --device=/dev/sdX"; exit 1 ;;
    --allow-loop) ALLOW_LOOP=true ;;
    --yes) YES_MODE=true ;;
    --passphrase-file=?*) PASSPHRASE_FILE="${arg#--passphrase-file=}" ;;
    --passphrase-file|--passphrase-file=) echo "--passphrase-file requires a value: --passphrase-file=/path/to/file"; exit 1 ;;
    --tang=?*) TANG_ARG="${arg#--tang=}" ;;
    --tang|--tang=) echo "--tang requires a value: --tang=http://a,http://b"; exit 1 ;;
    --usb-key-file=?*) USB_KEY_FILE="${arg#--usb-key-file=}" ;;
    --usb-key-file|--usb-key-file=) echo "--usb-key-file requires a value: --usb-key-file=/path/to/usb.key"; exit 1 ;;
    --keep-backup) KEEP_BACKUP=true ;;
    --remove-backup) REMOVE_BACKUP=true ;;
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

if [ "$KEEP_BACKUP" = true ] && [ "$REMOVE_BACKUP" = true ]; then
  echo "--keep-backup and --remove-backup are mutually exclusive"
  exit 1
fi

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
LVM_ROOT_SIZE="${LVM_ROOT_SIZE:-}"  # LV size - set via --lv-size=<size> (e.g., "50G", "50%FREE") - empty = 100%FREE
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

WARNINGS=()
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; WARNINGS+=("$*"); }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# --- Prompts (every question goes through these two helpers) ---
# Without a terminal on stdin a question cannot be answered: fail with a
# message naming the option that avoids it, instead of hanging or reading EOF.

# Ask a yes/no question. Returns 0 for yes, 1 for no.
# --yes answers it automatically with <yes-mode answer> (yes, no) or, for
# "ask", still asks.
# Usage: _ask_confirm "<prompt>" "<option avoiding the prompt>" [yes|no|ask] [exact word]
#   exact word: the answer must equal it (e.g. YES), else y/Y counts
_ask_confirm() {
  local prompt="$1" opt="$2" yesmode="${3:-yes}" exact="${4:-}" ans
  if [ "$YES_MODE" = true ] && [ "$yesmode" != "ask" ]; then
    info "--yes: '${prompt%"${prompt##*[![:space:]]}"}' -> ${yesmode}"
    if [ "$yesmode" = "yes" ]; then return 0; fi
    return 1
  fi
  if [ ! -t 0 ]; then
    fail "A question needs an answer but stdin is not a terminal: ${prompt%"${prompt##*[![:space:]]}"}
       Use ${opt} to avoid the prompt."
  fi
  read -rp "$prompt" ans
  if [ -n "$exact" ]; then
    [ "$ans" = "$exact" ]
  else
    [[ "$ans" == [yY] ]]
  fi
}

# Ask for a value (hidden input if the 4th argument is "secret") into a variable.
# Usage: _ask_value <variable> "<prompt>" "<option avoiding the prompt>" [secret]
_ask_value() {
  local __var="$1" __prompt="$2" __opt="$3" __secret="${4:-}" __v
  if [ ! -t 0 ]; then
    fail "Input needed but stdin is not a terminal: ${__prompt%"${__prompt##*[![:space:]]}"}
       Use ${__opt} to avoid the prompt."
  fi
  if [ "$__secret" = "secret" ]; then
    read -rsp "$__prompt" __v
    echo ""
  else
    read -rp "$__prompt" __v
  fi
  printf -v "$__var" '%s' "$__v"
}

# --- Target storage health ---
# A flaky card reader / USB bridge can reset mid-run: writes are lost, ext4
# aborts its journal and remounts read-only, and every later step (initramfs
# rebuild, ...) fails as a consequence. These checks turn that into a hard,
# early failure instead of a "complete" run that cannot boot.

SCRIPT_START_EPOCH=$(date +%s)
TARGET_KNAMES=""   # kernel names (sdc, sdc2, dm-7, ...) seen for the target so far

# Remember the kernel names of the target device, its partitions and the
# device-mapper nodes stacked on it (LUKS, LVM). Accumulates across calls so
# the names are still known after LUKS/LVM were closed.
_remember_target_knames() {
  local name
  [ -n "${EXT_DEVICE:-}" ] && [ -b "$EXT_DEVICE" ] || return 0
  for name in $(lsblk -nlo KNAME "$EXT_DEVICE" 2>/dev/null); do
    case " $TARGET_KNAMES " in
      *" $name "*) ;;
      *) TARGET_KNAMES="${TARGET_KNAMES:+$TARGET_KNAMES }$name" ;;
    esac
  done
}

# Kernel messages since this script started (dmesg ring buffer as fallback).
_kernel_log_since_start() {
  if command -v journalctl >/dev/null 2>&1 \
     && journalctl -k -q --no-pager --since "@${SCRIPT_START_EPOCH}" 2>/dev/null; then
    return 0
  fi
  dmesg 2>/dev/null || true
}

# Fail hard if the target storage shows any sign of trouble:
#   - writeback errors on the mounted target filesystems (sync -f / syncfs)
#   - a target filesystem that the kernel remounted read-only
#   - I/O, ext4 or jbd2 errors for the target devices in the kernel log
# Usage: _check_target_health "<context>"
_check_target_health() {
  local context="$1" mnt names_re hits
  _remember_target_knames

  for mnt in "${MOUNT_DST:-}" "${MOUNT_BOOT:-}"; do
    [ -n "$mnt" ] && mountpoint -q "$mnt" 2>/dev/null || continue
    if ! sync -f "$mnt"; then
      fail "${context}: writeback to ${mnt} failed. The target storage reported write errors; the written data cannot be trusted."
    fi
    if findmnt -no OPTIONS "$mnt" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
      fail "${context}: ${mnt} is read-only now. The kernel remounted it after an error on the target storage."
    fi
  done

  [ -n "$TARGET_KNAMES" ] || return 0
  names_re=$(tr ' ' '|' <<<"$TARGET_KNAMES")
  hits=$(_kernel_log_since_start \
    | grep -E "\\b(${names_re})\\b" \
    | grep -iE 'I/O error|EXT4-fs (error|warning)|Aborting journal|JBD2|read-only|offline|FAILED Result' \
    || true)
  if [ -n "$hits" ]; then
    echo -e "${RED}[FAIL]${NC} Kernel log errors on the target storage (${TARGET_KNAMES}):" >&2
    head -20 <<<"$hits" >&2
    [ "$(wc -l <<<"$hits")" -gt 20 ] && echo "  ... ($(wc -l <<<"$hits") lines in total)" >&2
    fail "${context}: the target storage had I/O errors during this run (card reader / USB reset?). Do not boot this card. Re-run on a reliable reader (directly on the host, no hub)."
  fi
}

# --- Board / scenario helpers ---

# True for Raspberry Pi layouts: /boot/firmware, initramfs* on the boot
# partition, cmdline.txt. The offline scenario (rpi_offline) is a Raspberry Pi
# card as well; luks_prepare.sh stages BOARD_TYPE="rpi" for it, the scenario
# check keeps this true even if that value is missing.
_is_rpi() {
  [ "${BOARD_TYPE:-}" = "rpi" ] || [ "${SCENARIO:-}" = "rpi_offline" ]
}

# True while the card has never been booted (offline mode): the first boot of
# the Pi is still ahead and must find the image state untouched.
_first_boot_pending() {
  [ "${FIRST_BOOT_PENDING:-}" = "yes" ]
}

# --- Initramfs verification ---

# Print the initramfs images on the mounted boot partition, one per line.
_initramfs_images() {
  [ -n "${MOUNT_BOOT:-}" ] && mountpoint -q "$MOUNT_BOOT" 2>/dev/null || return 0
  if _is_rpi; then
    find "$MOUNT_BOOT" -maxdepth 1 -type f -name 'initramfs*' | sort
  else
    find "$MOUNT_BOOT" -maxdepth 1 -type f -name 'initrd.img-*' | sort
  fi
}

# List the contents of an initramfs image: with the host's lsinitramfs, or
# inside the chroot (only while its /proc etc. are mounted, i.e. in phase 5).
_list_initramfs() {
  local img="$1" chroot_boot
  if command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "$img"
  elif [ -n "${MOUNT_DST:-}" ] && [ -x "${MOUNT_DST}/usr/bin/lsinitramfs" ] \
       && mountpoint -q "${MOUNT_DST}/proc" 2>/dev/null; then
    if _is_rpi; then chroot_boot=/boot/firmware; else chroot_boot=/boot; fi
    chroot "$MOUNT_DST" lsinitramfs "${chroot_boot}${img#"$MOUNT_BOOT"}"
  else
    return 2
  fi
}

# Check the network drivers (NET_DRIVERS, offline mode: no running system to
# detect the NIC from) of one initramfs image against the kernel it was built
# for. Several kernels (e.g. initramfs_2712 and initramfs8 on a Pi 5) do not all
# provide every driver as a module, so per image and driver:
#   - listed in the kernel's modules.builtin (on the mounted root): present
#   - else listed in its modules.dep: the module file must be in the image
#     (<name>.ko, optional compression suffix), otherwise fatal
#   - else the kernel has no such driver: warning only
# Fatal as well: the kernel version is unknown, or no driver at all is present.
# '-' and '_' are equivalent in module names.
# Usage: _check_net_drivers "<image name>" "<lsinitramfs listing>"
# Returns 1 if the image has no usable network driver set.
_check_net_drivers() {
  local name="$1" listing="$2" kver moddir drv drv_re present=0 bad=0 _d
  [ -n "${NET_DRIVERS:-}" ] || return 0
  kver=$(sed -nE 's#^(\./)?(usr/)?lib/modules/([^/]+)/.*#\3#p' <<<"$listing" | head -1 || true)
  if [ -z "$kver" ]; then
    warn "${name}: no lib/modules/<kernel>/ inside, cannot tell which kernel it is for"
    return 1
  fi
  moddir=""
  if [ -n "${MOUNT_DST:-}" ]; then
    for _d in "${MOUNT_DST}/usr/lib/modules/${kver}" "${MOUNT_DST}/lib/modules/${kver}"; do
      if [ -f "${_d}/modules.dep" ] || [ -f "${_d}/modules.builtin" ]; then moddir="$_d"; break; fi
    done
  fi
  if [ -z "$moddir" ]; then
    warn "${name}: no modules.dep / modules.builtin for kernel ${kver} on the mounted root, cannot judge the network drivers"
    return 1
  fi
  for drv in $NET_DRIVERS; do
    drv_re="${drv//[-_]/[-_]}"
    if [ -f "${moddir}/modules.builtin" ] \
       && grep -Eq "(^|/)${drv_re}\.ko\$" "${moddir}/modules.builtin"; then
      present=$((present + 1))
      info "${name}: ${drv} is built into kernel ${kver}"
    elif [ ! -f "${moddir}/modules.dep" ] \
         || grep -Eq "(^|/)${drv_re}\.ko(\.[a-z0-9]+)?:" "${moddir}/modules.dep"; then
      if grep -Eq "/${drv_re}\.ko(\.[a-z0-9]+)?\$" <<<"$listing"; then
        present=$((present + 1))
      else
        warn "${name}: ${drv} is a module of kernel ${kver} but is NOT inside the image. No network, no tang unlock at boot"
        bad=1
      fi
    else
      warn "${name}: kernel ${kver} has no driver ${drv}, ignored"
    fi
  done
  if [ "$present" -eq 0 ]; then
    warn "${name}: none of the network drivers (${NET_DRIVERS}) is present for kernel ${kver}. No network, no tang unlock at boot"
    bad=1
  fi
  return "$bad"
}

# Check every initramfs image on the boot partition: it must contain the
# cryptsetup crypttab (otherwise the root is never unlocked and boot ends in
# "ALERT! <root> does not exist") and clevis, and the network drivers of its
# kernel if NET_DRIVERS is set (_check_net_drivers; needs the root mounted at
# MOUNT_DST). With USB_KEY="yes" in luks.conf it also needs the clevis-keyfile scripts and
# keyfile.conf inside and no etc/clevis-keyfile/fallback.key (_usbkey_check_listing). With a checksum list from before
# the rebuild ("sha256  path" lines), every image must also have changed.
# Usage: _verify_initramfs_images ["<sha256sum output before rebuild>"]
# Returns 1 if any image is missing, stale or incomplete.
_verify_initramfs_images() {
  local pre_sums="${1:-}" img name listing pre_sum bad=0 missing
  local images=()
  mapfile -t images < <(_initramfs_images)
  if [ "${#images[@]}" -eq 0 ]; then
    warn "No initramfs image found on the boot partition"
    return 1
  fi
  for img in "${images[@]}"; do
    name=$(basename "$img")
    if [ -n "$pre_sums" ]; then
      pre_sum=$(awk -v p="$img" '$2 == p {print $1}' <<<"$pre_sums")
      if [ -n "$pre_sum" ] && [ "$pre_sum" = "$(sha256sum "$img" | cut -d' ' -f1)" ]; then
        warn "${name}: unchanged, it was NOT rebuilt in this run"
        bad=1
        continue
      fi
    fi
    if ! listing=$(_list_initramfs "$img"); then
      warn "${name}: cannot list its contents (no lsinitramfs on this host)"
      bad=1
      continue
    fi
    if ! grep -q 'cryptroot/crypttab' <<<"$listing"; then
      warn "${name}: no cryptroot/crypttab inside, the root will never be unlocked at boot"
      bad=1
    fi
    if ! grep -q 'clevis' <<<"$listing"; then
      warn "${name}: no clevis inside, no tang auto-unlock"
      bad=1
    fi
    missing=""
    if ! _check_net_drivers "$name" "$listing"; then
      missing="yes"
      bad=1
    fi
    if [ "$USB_KEY" = "yes" ] && ! _usbkey_check_listing "$name" "$listing"; then
      missing="yes"
      bad=1
    fi
    if ! grep -q 'cryptroot/crypttab' <<<"$listing" || ! grep -q 'clevis' <<<"$listing" || [ -n "$missing" ]; then
      continue
    fi
    ok "${name}: crypttab and clevis present ($(grep -c clevis <<<"$listing") clevis files)${NET_DRIVERS:+, network drivers checked: ${NET_DRIVERS}}${USB_KEY:+, USB key fallback present, no key inside}"
  done
  return "$bad"
}
INITRAMFS_VERIFIED=false

# --- Offline mode: "never booted" state of the card ---
# The Pi has not booted this card yet. Its first boot (systemd ConditionFirstBoot,
# regenerate_ssh_host_keys, cloud-init NoCloud) only works if the image still
# looks untouched. Everything run in the chroot (update-initramfs and the
# package hooks behind it) must leave these traces as it found them.

# Print one line per violation of the never-booted state of the mounted target.
# Scope "root": root filesystem only (MOUNT_DST).
# Scope "full": additionally the boot partition (MOUNT_BOOT): cloud-init seed
# and cmdline.txt.
# Usage: _never_booted_findings root|full
_never_booted_findings() {
  local scope="$1" root="${MOUNT_DST:-}" boot="${MOUNT_BOOT:-}" mid f cl
  if [ -L "${root}/etc/machine-id" ] || [ ! -f "${root}/etc/machine-id" ]; then
    echo "/etc/machine-id is missing or a symlink (must be a file containing 'uninitialized')"
  else
    mid=$(cat "${root}/etc/machine-id" 2>/dev/null || true)
    if [ "$mid" != "uninitialized" ]; then
      echo "/etc/machine-id is '${mid}', must be exactly 'uninitialized' (the first boot logic would be skipped)"
    fi
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && echo "SSH host key present: ${f#"$root"} (the image ships none, regenerate_ssh_host_keys creates them)"
  done < <(find "${root}/etc/ssh" -maxdepth 1 -name 'ssh_host_*' 2>/dev/null | sort)
  if [ -e "${root}/var/lib/cloud/instance" ] || [ -L "${root}/var/lib/cloud/instance" ]; then
    echo "/var/lib/cloud/instance exists: cloud-init already ran, it would skip the NoCloud seed"
  fi
  if [ -e "${root}/usr/sbin/policy-rc.d" ] || [ -L "${root}/usr/sbin/policy-rc.d" ]; then
    echo "/usr/sbin/policy-rc.d is still present (it would block every service start on the Pi)"
  fi
  if [ -e "${root}/usr/bin/qemu-aarch64-static" ] || [ -L "${root}/usr/bin/qemu-aarch64-static" ]; then
    echo "/usr/bin/qemu-aarch64-static is still present (leftover of the chroot)"
  fi
  [ "$scope" = "full" ] || return 0

  for f in user-data meta-data; do
    if [ ! -f "${boot}/${f}" ]; then
      echo "${f} missing on the boot partition (cloud-init seed, the Pi would be unreachable)"
    fi
  done
  if [ ! -f "${boot}/cmdline.txt" ]; then
    echo "cmdline.txt missing on the boot partition"
  else
    cl=$(cat "${boot}/cmdline.txt")
    _cmdline_findings "$cl" yes
  fi
}

# Print one line per problem of a cmdline.txt content for a never-booted card:
# no ' resize' (the initramfs resize_early breaks on the LVM root) and, if
# required, the cloud-init instance ID 'ds=nocloud;i=' still present.
# Usage: _cmdline_findings "<cmdline>" yes|no   (second argument: require ds=)
_cmdline_findings() {
  local cl="$1" require_ds="$2"
  if [[ "$cl" =~ (^|[[:space:]])resize([[:space:]]|$) ]]; then
    echo "cmdline.txt contains ' resize' (resize_early would fail on the encrypted LVM root)"
  fi
  if [ "$require_ds" = "yes" ] && [[ "$cl" != *"ds=nocloud;i="* ]]; then
    echo "cmdline.txt has no 'ds=nocloud;i=' (cloud-init would not find its seed)"
  fi
}

# Phase bootconfig check for a never-booted card: the new cmdline.txt must have
# no ' resize' and must still contain 'ds=nocloud;i=' if the original had it
# (otherwise cloud-init skips the NoCloud seed). Fatal. A no-op unless the
# first boot is pending.
# Usage: _check_cmdline_first_boot "<new cmdline>" "<original cmdline(s)>"
_check_cmdline_first_boot() {
  local new="$1" orig="$2" need_ds=no findings
  _first_boot_pending || return 0
  if [[ "$orig" == *"ds=nocloud;i="* ]]; then need_ds=yes; fi
  findings=$(_cmdline_findings "$new" "$need_ds")
  if [ -n "$findings" ]; then
    while IFS= read -r _l; do warn "$_l"; done <<<"$findings"
    fail "The new cmdline.txt would break the first boot of the never-booted card (see above).
       cmdline.txt was NOT changed. Fix the cmdline.txt on the boot partition (or re-run
       luks_prepare.sh --offline), then resume with: sudo ./luks_encrypt.sh --start-phase=bootconfig${BACKUP_DIR:+ --backup-dir=$BACKUP_DIR}"
  fi
}

# State of the chroot, saved before and restored after the initramfs rebuild.
# The restore also runs from the EXIT trap, so it covers failure paths.
FB_STATE_DIR=""    # scratch dir with the saved copies
FB_ARMED=false     # true while chroot modifications still await the restore
FB_PATHS=()        # target-relative paths whose original state is saved
FB_SSH_PRE=""      # SSH host keys that existed before the chroot was used

# Save the state of one path of the target root (absent, file or symlink).
# Usage: _fb_save_path <path relative to the target root>
_fb_save_path() {
  local rel="$1" abs key
  abs="${MOUNT_DST}/${rel}"
  key="${rel//\//_}"
  if [ -L "$abs" ] || [ -f "$abs" ]; then
    cp -a --no-dereference "$abs" "${FB_STATE_DIR}/${key}.data"
    : > "${FB_STATE_DIR}/${key}.present"
  elif [ -e "$abs" ]; then
    fail "${rel} is neither a file nor a symlink, refusing to touch the first-boot state"
  fi
  FB_PATHS+=("$rel")
}

# Restore one saved path exactly as it was (content, mode, owner, times, symlink).
# Usage: _fb_restore_path <path relative to the target root>
_fb_restore_path() {
  local rel="$1" abs key
  abs="${MOUNT_DST}/${rel}"
  key="${rel//\//_}"
  rm -f "$abs" || return 1
  if [ -e "${FB_STATE_DIR}/${key}.present" ]; then
    cp -a --no-dereference "${FB_STATE_DIR}/${key}.data" "$abs" || return 1
  fi
}

# Arm the first-boot protection before the chroot is used. Always saves the
# path of the qemu copy (removed again afterwards in every scenario). While
# FIRST_BOOT_PENDING=yes it also saves machine-id and dbus machine-id, records
# the SSH host keys and installs policy-rc.d (exit 101: no service starts).
# update-initramfs does not use apt, so /etc/resolv.conf stays untouched.
_fb_arm() {
  FB_STATE_DIR=$(mktemp -d /tmp/luks-fbstate.XXXXXX)
  FB_PATHS=()
  _fb_save_path usr/bin/qemu-aarch64-static
  if _first_boot_pending; then
    _fb_save_path etc/machine-id
    _fb_save_path var/lib/dbus/machine-id
    _fb_save_path usr/sbin/policy-rc.d
    FB_SSH_PRE=$(find "${MOUNT_DST}/etc/ssh" -maxdepth 1 -name 'ssh_host_*' 2>/dev/null | sort)
    mkdir -p "${MOUNT_DST}/usr/sbin"
    printf '#!/bin/sh\nexit 101\n' > "${MOUNT_DST}/usr/sbin/policy-rc.d"
    chmod 755 "${MOUNT_DST}/usr/sbin/policy-rc.d"
    info "First-boot protection armed (machine-id saved, policy-rc.d installed)"
  fi
  FB_ARMED=true
}

# Undo everything the chroot may have changed: restore the saved paths in
# reverse order (machine-id files exactly, policy-rc.d and the qemu copy removed
# or put back), and delete SSH host keys created in the chroot (with a warning).
# Idempotent; called after a successful rebuild and from cleanup(). Does not
# exit: the caller decides. Returns 1 if something could not be restored.
_fb_restore() {
  local rc=0 i f
  [ "$FB_ARMED" = true ] || return 0
  if [ -z "${MOUNT_DST:-}" ] || ! mountpoint -q "$MOUNT_DST" 2>/dev/null; then
    warn "Cannot restore the first-boot state: target root is not mounted"
    return 1
  fi
  for (( i=${#FB_PATHS[@]}-1 ; i>=0 ; i-- )); do
    _fb_restore_path "${FB_PATHS[$i]}" || { warn "Could not restore ${FB_PATHS[$i]}"; rc=1; }
  done
  if _first_boot_pending; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case $'\n'"$FB_SSH_PRE"$'\n' in
        *$'\n'"$f"$'\n'*) continue ;;
      esac
      if rm -f "$f"; then
        warn "SSH host key ${f#"$MOUNT_DST"} was created in the chroot and has been deleted"
      else
        warn "Could not delete SSH host key ${f#"$MOUNT_DST"} created in the chroot"
        rc=1
      fi
    done < <(find "${MOUNT_DST}/etc/ssh" -maxdepth 1 -name 'ssh_host_*' 2>/dev/null | sort)
  fi
  rm -rf "$FB_STATE_DIR"
  FB_ARMED=false
  [ "$rc" -eq 0 ] && info "Chroot leftovers removed and first-boot state restored"
  return "$rc"
}

# Cleanup function
CLEANUP_MOUNTS=()
CLEANUP_TMPDIR=()
CLEANUP_LUKS=""
CLEANUP_FILES=()    # temporary files with key material (removed right after use, here as safety net)
BACKUP_DIR_FOR_CLEANUP=""

cleanup() {
  set +e
  info "Cleaning up..."

  # Undo chroot changes first (needs the target root still mounted): machine-id,
  # policy-rc.d, qemu copy, stray SSH host keys. Covers every failure path.
  _fb_restore
  if [ "$FB_ARMED" != true ] && [ -n "$FB_STATE_DIR" ]; then rm -rf "$FB_STATE_DIR"; fi

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

  # Temporary key files (normally removed right after use)
  for f in "${CLEANUP_FILES[@]}"; do
    if [ -n "$f" ]; then rm -f "$f"; fi
  done

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
BACKUP_BASE=""
BACKUP_DIR=""
BACKUP_COUNT=0

# --tang=<url1>,<url2>: replaces the servers of the script; luks.conf only fills
# empty entries, so it cannot override them. Exactly the count the script has
# (two servers, SSS threshold 2).
_apply_tang_arg() {
  local list="$1" commas n url
  local urls=()
  commas="${list//[^,]/}"
  n=$(( ${#commas} + 1 ))
  if [ "$n" -ne "${#TANG_SERVERS[@]}" ]; then
    fail "--tang needs exactly ${#TANG_SERVERS[@]} comma separated URLs (SSS threshold ${SSS_THRESHOLD}), got ${n}"
  fi
  IFS=',' read -r -a urls <<<"$list"
  # read drops a trailing empty field ("a,b,"): that is an empty URL
  [ "${#urls[@]}" -eq "$n" ] || fail "--tang contains an empty URL"
  for url in "${urls[@]}"; do
    [ -n "$url" ] || fail "--tang contains an empty URL"
  done
  TANG_SERVERS=("${urls[@]}")
}

# --passphrase-file=<path>: LUKS passphrase = first line, only the newline is
# stripped. The file is only read (no ownership or mode requirements) and never
# removed. Non-interactive mode cannot ask "use anyway?", so a short one fails.
_load_passphrase_file() {
  local file="$1"
  [ -f "$file" ] || fail "Passphrase file not found: $file"
  if ! { IFS= read -r LUKS_PASS || [ -n "$LUKS_PASS" ]; } < "$file"; then
    LUKS_PASS=""
  fi
  [ -n "$LUKS_PASS" ] || fail "Passphrase file is empty or unreadable (first line): $file"
  if [ "${#LUKS_PASS}" -lt "$MIN_PASSPHRASE_LEN" ]; then
    LUKS_PASS=""
    fail "Passphrase in $file is shorter than ${MIN_PASSPHRASE_LEN} characters. Use a longer one (non-interactive mode does not ask 'use anyway?')."
  fi
}

if [ -n "$TANG_ARG" ]; then _apply_tang_arg "$TANG_ARG"; fi
if [ -n "$PASSPHRASE_FILE" ]; then _load_passphrase_file "$PASSPHRASE_FILE"; fi

# --- Prerequisite setup functions for --start-phase resume ---

_ensure_luks_open() {
  if [ -b "/dev/mapper/$LUKS_MAPPER_NAME" ]; then
    info "LUKS device already open: /dev/mapper/$LUKS_MAPPER_NAME"
  else
    info "Opening LUKS device on $EXT_ROOT_PART..."
    if [ -n "$LUKS_PASS" ]; then
      printf '%s' "$LUKS_PASS" | cryptsetup luksOpen "$EXT_ROOT_PART" "$LUKS_MAPPER_NAME" -
    else
      cryptsetup luksOpen "$EXT_ROOT_PART" "$LUKS_MAPPER_NAME"
    fi
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

# When resuming, luks.conf may not have been readable earlier (the root is LUKS
# by then). Once the encrypted root is mounted, read the offline keys from the
# staged copy there. Fills only what is still unset.
_load_offline_state_from_root() {
  local conf="${MOUNT_DST}/root/luks-staged/luks.conf"
  [ -f "$conf" ] || return 0
  if [ -z "$SCENARIO" ]; then
    SCENARIO=$(grep '^SCENARIO=' "$conf" | cut -d'"' -f2 || true)
  fi
  _read_offline_conf "$conf"
  _normalize_offline_state
  return 0
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

# --- USB key (--usb-key-file): extra keyslot for the clevis-keyfile initramfs fallback ---
# luks_prepare.sh --usb-key installs the initramfs side (hook, local-top and local-bottom
# scripts, /etc/clevis-keyfile/keyfile.conf, USB_KEY="yes" in luks.conf). This script owns
# the key: it creates or reads the key file, stores the master copy on the encrypted root
# (/etc/clevis-keyfile/fallback.key, no trailing newline, read by
# /root/clevis_keyfile_write_usb.sh) and adds it as a further keyslot. The key never goes
# into the initramfs.

# Fresh runs only: when luks.conf has not been read so far (script started from the card,
# values handed over by the re-exec), look into the staged copy on the still unencrypted root.
_usbkey_probe_conf() {
  local m
  m=$(mktemp -d /tmp/luks-conf-probe.XXXXXX)
  if mount -o ro "$EXT_ROOT_PART" "$m" 2>/dev/null; then
    if [ -f "$m/root/luks-staged/luks.conf" ]; then
      _read_offline_conf "$m/root/luks-staged/luks.conf"
    fi
    umount "$m" 2>/dev/null || true
  fi
  rmdir "$m" 2>/dev/null || true
}

# luks.conf says USB_KEY="yes" but the option is missing: fatal (the initramfs carries the
# fallback, the keyslot and the key would be missing). Option given but no USB_KEY in a
# luks.conf that was read: warning, the run continues. Safe to call repeatedly.
_usbkey_check_conf() {
  if [ "$LUKS_CONF_READ" != true ] && [ "$START_PHASE_NUM" -le 2 ] && [ -b "${EXT_ROOT_PART:-}" ]; then
    _usbkey_probe_conf
  fi
  if [ "$USB_KEY" = "yes" ] && [ -z "$USB_KEY_FILE" ]; then
    fail "luks.conf has USB_KEY=\"yes\" (luks_prepare.sh --usb-key): the initramfs carries the USB key fallback, so this run needs --usb-key-file=<path> to create the keyslot (the file is created if it does not exist). Nothing was changed."
  fi
  if [ -n "$USB_KEY_FILE" ] && [ "$USB_KEY" != "yes" ] && [ "$LUKS_CONF_READ" = true ] && [ "$USB_KEY_WARNED" != true ]; then
    USB_KEY_WARNED=true
    warn "--usb-key-file is given, but luks.conf has no USB_KEY=\"yes\": the initramfs has no USB key watcher (run luks_prepare.sh --usb-key). The key and the keyslot are created anyway."
  fi
  return 0
}

# Load the USB key into USB_KEY_VALUE: an existing file is read (first line, newline stripped,
# no owner or mode checks, never changed or deleted), a missing file is created with 48 random
# bytes from /dev/urandom as one base64 line of 64 characters (mode 600, create only, no newline).
_usbkey_prepare_key() {
  local f="$USB_KEY_FILE" dir src label
  [ -n "$f" ] || return 0
  if [ -d "$f" ]; then
    # A directory is the mounted stick: the key goes to <stick>/luks-keys/<host>.key, the
    # layout the initramfs watcher reads (own host first, then every other *.key).
    [ -n "$USB_KEY_HOST" ] || fail "--usb-key-file=${f} is a directory, but luks.conf has no USB_KEY_HOST (run luks_prepare.sh --usb-key first, or name the key file itself)"
    src=$(findmnt -n -o SOURCE --target "$f" 2>/dev/null || true)
    label=$(blkid -s LABEL -o value "$src" 2>/dev/null || true)
    if [ "$label" != "${USB_KEY_LABEL:-LUKSKEY}" ]; then
      warn "Filesystem under ${f} (${src:-unknown}) has label '${label}', the initramfs looks for '${USB_KEY_LABEL:-LUKSKEY}': relabel the stick (fatlabel / e2label) or the key will not be found at boot"
    fi
    f="${f%/}/luks-keys/${USB_KEY_HOST}.key"
    if [ ! -d "$(dirname -- "$f")" ]; then
      mkdir -p "$(dirname -- "$f")" || fail "Cannot create $(dirname -- "$f")"
    fi
    USB_KEY_FILE="$f"
    info "USB key path on the stick: $f"
  fi
  if [ -e "$f" ]; then
    [ -r "$f" ] || fail "USB key file not readable: $f"
    if ! { IFS= read -r USB_KEY_VALUE || [ -n "$USB_KEY_VALUE" ]; } < "$f"; then
      USB_KEY_VALUE=""
    fi
    [ -n "$USB_KEY_VALUE" ] || fail "USB key file is empty or unreadable (first line): $f"
    info "Using the USB key from $f (first line, ${#USB_KEY_VALUE} characters, file left untouched)"
  else
    dir=$(dirname -- "$f")
    { [ -d "$dir" ] && [ -w "$dir" ]; } || fail "Cannot create the USB key file ${f}: directory ${dir} does not exist or is not writable"
    if ! ( set -o noclobber; umask 077; head -c 48 /dev/urandom | base64 -w0 > "$f" ); then
      rm -f "$f" 2>/dev/null || true
      fail "Could not create the USB key file $f"
    fi
    chmod 600 "$f" 2>/dev/null || warn "chmod 600 ${f} failed (vfat has no file modes); the stick is a plain-text key anyway"
    if ! { IFS= read -r USB_KEY_VALUE || [ -n "$USB_KEY_VALUE" ]; } < "$f"; then
      USB_KEY_VALUE=""
    fi
    [ "${#USB_KEY_VALUE}" -eq 64 ] || fail "Generated USB key has ${#USB_KEY_VALUE} characters instead of 64: $f"
    ok "Generated a new USB key: $f (64 characters, mode 600, root owned if run with sudo)"
    info "Keep this file: together with the card (or a stick) it unlocks the root without tang and passphrase."
  fi
}

# Print the number of luks2 keyslots of a device (luksDump lines "  <n>: luks2").
# Usage: _usbkey_slot_count <luks device>
_usbkey_slot_count() {
  local dump
  dump=$(LC_ALL=C cryptsetup luksDump "$1") || fail "cryptsetup luksDump $1 failed"
  grep -cE '^\s+[0-9]+: luks2$' <<<"$dump" || true
}

# Clevis phase: store the master copy of the key on the encrypted root and add it as a further
# keyslot (authorised by the main passphrase). Fatal if the key does not unlock afterwards or
# the slot count did not rise by one. Skips the add if the key is enrolled already (resume).
_usbkey_enroll() {
  [ -n "$USB_KEY_FILE" ] || return 0
  local keypath tmp_main="" tmp_new before after added=false rc=0
  echo ""
  info "Adding the USB key as a further keyslot of $EXT_ROOT_PART..."
  if [ -z "$MOUNT_DST" ] || ! mountpoint -q "$MOUNT_DST" 2>/dev/null; then
    _ensure_luks_open
    _ensure_root_mounted
    _load_offline_state_from_root
    _usbkey_check_conf
  fi
  [ -n "$USB_KEY_VALUE" ] || fail "Internal error: the USB key was not loaded"

  keypath="${MOUNT_DST}${USB_KEY_ROOT_PATH}"
  install -d -m 0700 "$(dirname "$keypath")"
  ( umask 077; printf '%s' "$USB_KEY_VALUE" > "$keypath" )
  chmod 600 "$keypath"
  info "  Master copy: ${USB_KEY_ROOT_PATH} on the encrypted root (mode 600, no trailing newline)"

  before=$(_usbkey_slot_count "$EXT_ROOT_PART")
  tmp_new=$(mktemp /tmp/luks-usbkey.XXXXXX)
  CLEANUP_FILES+=("$tmp_new")
  chmod 600 "$tmp_new"
  printf '%s' "$USB_KEY_VALUE" > "$tmp_new"

  if cryptsetup open --test-passphrase --key-file "$tmp_new" "$EXT_ROOT_PART" >/dev/null 2>&1; then
    info "  The USB key unlocks $EXT_ROOT_PART already (keyslot exists), not adding it again"
  else
    tmp_main=$(mktemp /tmp/luks-mainpass.XXXXXX)
    CLEANUP_FILES+=("$tmp_main")
    chmod 600 "$tmp_main"
    printf '%s' "$LUKS_PASS" > "$tmp_main"
    cryptsetup luksAddKey --key-file "$tmp_main" "$EXT_ROOT_PART" "$tmp_new" || rc=$?
    rm -f "$tmp_main"
    if [ "$rc" -ne 0 ]; then
      rm -f "$tmp_new"
      fail "cryptsetup luksAddKey failed (exit ${rc}): the USB key was not added. Resume with: sudo ./luks_encrypt.sh --start-phase=clevis --usb-key-file=${USB_KEY_FILE}${BACKUP_DIR:+ --backup-dir=$BACKUP_DIR}"
    fi
    added=true
  fi

  if ! cryptsetup open --test-passphrase --key-file "$tmp_new" "$EXT_ROOT_PART"; then
    rm -f "$tmp_new"
    fail "The USB key does not unlock $EXT_ROOT_PART after luksAddKey (cryptsetup open --test-passphrase failed)."
  fi
  rm -f "$tmp_new"
  after=$(_usbkey_slot_count "$EXT_ROOT_PART")
  if [ "$added" = true ] && [ "$after" -ne "$((before + 1))" ]; then
    fail "Keyslot count is ${after} after adding the USB key, expected $((before + 1)) (before: ${before})."
  fi
  ok "USB key enrolled: ${after} keyslot(s), the key unlocks $EXT_ROOT_PART"
}

# Check one initramfs listing for the USB key fallback: scripts/local-top/clevis-keyfile,
# scripts/local-bottom/clevis-keyfile and etc/clevis-keyfile/keyfile.conf must be inside,
# etc/clevis-keyfile/fallback.key must not. Warns about every violation, returns 1 if any.
# Usage: _usbkey_check_listing "<image name>" "<lsinitramfs listing>"
_usbkey_check_listing() {
  local name="$1" listing="$2" rc=0 p
  for p in scripts/local-top/clevis-keyfile scripts/local-bottom/clevis-keyfile etc/clevis-keyfile/keyfile.conf; do
    if ! grep -Eq "(^|/)${p//./\\.}\$" <<<"$listing"; then
      warn "${name}: ${p} missing, the USB key would not be offered at boot"
      rc=1
    fi
  done
  if grep -Eq '(^|/)etc/clevis-keyfile/fallback\.key$' <<<"$listing"; then
    warn "${name}: etc/clevis-keyfile/fallback.key is INSIDE the initramfs (the key must stay on the encrypted root only)"
    rc=1
  fi
  return "$rc"
}

# Verification phase (USB_KEY="yes"): master copy equals the key, the stick writer script exists,
# the key unlocks, and the keyslot count is 3 (passphrase, clevis, USB key; 2 if clevis is not
# bound because tang was unreachable). Needs the root mounted at MOUNT_DST. Fatal on any miss.
_usbkey_verify() {
  [ "$USB_KEY" = "yes" ] || return 0
  local keypath="${MOUNT_DST}${USB_KEY_ROOT_PATH}" want=2 got tmp
  info "Verifying the USB key..."
  if [ -z "$MOUNT_DST" ] || ! mountpoint -q "$MOUNT_DST" 2>/dev/null; then
    fail "Root not mounted, cannot verify the USB key."
  fi
  [ -f "$keypath" ] || fail "${USB_KEY_ROOT_PATH} is missing on the encrypted root (resume with --start-phase=clevis --usb-key-file=...)"
  if [ -n "$USB_KEY_VALUE" ]; then
    tmp=$(mktemp /tmp/luks-usbkey.XXXXXX)
    CLEANUP_FILES+=("$tmp")
    chmod 600 "$tmp"
    printf '%s' "$USB_KEY_VALUE" > "$tmp"
    if ! cmp -s "$tmp" "$keypath"; then
      rm -f "$tmp"
      fail "${USB_KEY_ROOT_PATH} on the root differs from the key in ${USB_KEY_FILE}"
    fi
    rm -f "$tmp"
  fi
  [ -x "${MOUNT_DST}/root/clevis_keyfile_write_usb.sh" ] || fail "/root/clevis_keyfile_write_usb.sh is missing or not executable on the encrypted root"
  if ! cryptsetup open --test-passphrase --key-file "$keypath" "$EXT_ROOT_PART"; then
    fail "${USB_KEY_ROOT_PATH} does not unlock $EXT_ROOT_PART"
  fi
  if clevis luks list -d "$EXT_ROOT_PART" 2>/dev/null | grep -q .; then
    want=3
  else
    warn "No clevis binding on $EXT_ROOT_PART: expecting 2 keyslots (passphrase, USB key) instead of 3"
  fi
  got=$(_usbkey_slot_count "$EXT_ROOT_PART")
  [ "$got" -eq "$want" ] || fail "Expected ${want} keyslots on $EXT_ROOT_PART, found ${got}"
  ok "USB key verified: master copy matches, unlocks the device, ${got} keyslots, write script present"
}

# Text for the end of the run (option given or USB_KEY="yes")
_usbkey_next_steps() {
  local host="${USB_KEY_HOST:-<host>}" label="${USB_KEY_LABEL:-LUKSKEY}" keysrc="${USB_KEY_FILE:-/path/to/usb.key}"
  [ -n "$USB_KEY_FILE" ] || [ "$USB_KEY" = "yes" ] || return 0
  echo "  USB stick unlock (fallback key, luks.conf USB_KEY=\"yes\"):"
  echo "    Unlock order at boot: tang (clevis), stick, typed passphrase. The first valid answer wins;"
  echo "    the stick may be plugged in while the passphrase prompt is shown. Stick plus card unlock"
  echo "    the system without tang or passphrase."
  echo "    Prepare the stick (any filesystem: vfat, exfat or ext4), label ${label}:"
  echo "      mkfs.vfat -n ${label} /dev/sdY1        # or: e2label /dev/sdY1 ${label}"
  echo "    Then put the key on it as luks-keys/${host}.key, either on the Pi after the first unlock:"
  echo "      sudo /root/clevis_keyfile_write_usb.sh /dev/sdY1"
  echo "    or by hand on the workstation (stick mounted at <mnt>; the key has no trailing newline):"
  echo "      mkdir -p <mnt>/luks-keys"
  echo "      head -n 1 ${keysrc} | tr -d '\n' | install -m 0400 /dev/stdin <mnt>/luks-keys/${host}.key"
  echo ""
}

# =====================================================================
# 1. Safety checks
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  fail "This script must be run as root (sudo)."
fi

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
    fail "Not an RK3588 board - SPI flash not applicable"
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
    fail "No U-Boot SPI images found in /usr/lib/linux-u-boot-*/ - install the u-boot package for your board"
  fi

  echo ""
  info "Found U-Boot SPI image(s):"
  for i in "${!SPI_IMAGES[@]}"; do
    IMG_SIZE=$(stat -c%s "${SPI_IMAGES[$i]}" 2>/dev/null || echo "?")
    echo "  $((i+1)). ${SPI_IMAGES[$i]} (${IMG_SIZE} bytes)"
  done

  if [ "$YES_MODE" = true ]; then
    info "--yes answers the SPI flash question with no: nothing flashed."
    exit 0
  fi

  SPI_IMAGE=""
  if [ ${#SPI_IMAGES[@]} -eq 1 ]; then
    SPI_IMAGE="${SPI_IMAGES[0]}"
  else
    echo ""
    while true; do
      _ask_value IMG_NUM "Select image number [1-${#SPI_IMAGES[@]}]: " "--yes (skips the SPI flash)"
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
  if ! _ask_confirm "Write U-Boot to SPI flash for NVMe boot? [y/N] " "--yes (skips the SPI flash)" no; then
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
    ok "SPI flash verified - U-Boot written successfully"
  else
    fail "SPI flash verification failed - data appears empty after write"
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

  if [[ "$dev" == *nvme* ]] || [[ "$dev" == *mmcblk* ]] || [[ "$dev" == */loop[0-9]* ]]; then
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

# Validate a device given with --device (the interactive prompt only checks that
# it is a block device). Fails unless the device is
#   - a block device and a whole disk (a loop device only with --allow-loop,
#     where /dev/loopNp1 and p2 are the partitions),
#   - not part of the running system (holding /, /boot, /boot/efi, /boot/firmware),
#   - not mounted anywhere, including its partitions and anything stacked on
#     them (skipped when resuming past the encrypt phase: the root is LUKS then).
# Prints the canonical device path (symlinks like /dev/disk/by-id resolved).
# Usage: EXT_DEVICE=$(_validate_target_device /dev/sdX)
_validate_target_device() {
  local dev="$1" real type mnt src anc mnts
  [ -b "$dev" ] || fail "Device $dev not found (not a block device)"
  real=$(readlink -f "$dev")
  [ -b "$real" ] || fail "Device $dev resolves to $real, which is not a block device"

  type=$(lsblk -dno TYPE "$real" 2>/dev/null | head -1 | tr -d ' ')
  if [[ "$real" == /dev/loop* ]]; then
    [ "$ALLOW_LOOP" = true ] || fail "$real is a loop device. Loop devices are only accepted with --allow-loop (test only)."
    [ "$type" = "loop" ] || fail "$real is not a whole loop device (type: ${type:-unknown}); pass /dev/loopN, not a partition"
  elif [ "$type" != "disk" ]; then
    fail "$real is not a whole disk (type: ${type:-unknown}); pass the disk, e.g. /dev/sdb, not a partition"
  fi

  for mnt in / /boot /boot/efi /boot/firmware; do
    mountpoint -q "$mnt" 2>/dev/null || continue
    src=$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || true)
    [ -b "$src" ] || continue
    for anc in $(lsblk -snro KNAME "$src" 2>/dev/null); do
      if [ "/dev/$anc" = "$real" ]; then
        fail "$real is part of the running system ($mnt is mounted from $src). Refusing."
      fi
    done
  done

  if [ "$START_PHASE_NUM" -le 2 ]; then
    mnts=$(lsblk -nro MOUNTPOINTS "$real" 2>/dev/null || lsblk -nro MOUNTPOINT "$real" 2>/dev/null || true)
    mnts=$(grep -v '^$' <<<"$mnts" || true)
    if [ -n "$mnts" ]; then
      fail "$real is in use, it (or a partition of it) is mounted at: $(tr '\n' ' ' <<<"$mnts")
       Unmount it first."
    fi
  fi
  echo "$real"
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
# (not with --device: the device was named explicitly)
if [ -z "$EXT_DEVICE" ] && [ -z "$DEVICE_ARG" ]; then
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

        # Re-exec from /tmp, keeping the command line (--yes, --passphrase-file, --usb-key-file, ...)
        exec env _LUKS_REEXEC=1 "$TMPSCRIPT" "$@"
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

# Read the offline mode keys from a luks.conf into FIRST_BOOT_PENDING,
# NET_DRIVERS and OFFLINE_HOST_DEVICE, and the USB key keys into USB_KEY,
# USB_KEY_LABEL and USB_KEY_HOST. Values already set are kept.
# Usage: _read_offline_conf <luks.conf>
_read_offline_conf() {
  local conf="$1" v
  v=$(grep '^FIRST_BOOT_PENDING=' "$conf" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$FIRST_BOOT_PENDING" ]; then FIRST_BOOT_PENDING="$v"; fi
  v=$(grep '^NET_DRIVERS=' "$conf" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$NET_DRIVERS" ]; then NET_DRIVERS="$v"; fi
  v=$(grep '^OFFLINE_HOST_DEVICE=' "$conf" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$OFFLINE_HOST_DEVICE" ]; then OFFLINE_HOST_DEVICE="$v"; fi
  v=$(grep '^USB_KEY=' "$conf" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$USB_KEY" ]; then USB_KEY="$v"; fi
  v=$(grep '^USB_KEY_LABEL=' "$conf" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$USB_KEY_LABEL" ]; then USB_KEY_LABEL="$v"; fi
  v=$(grep '^USB_KEY_HOST=' "$conf" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$USB_KEY_HOST" ]; then USB_KEY_HOST="$v"; fi
  LUKS_CONF_READ=true
}

# Make the scenario rpi_offline consistent: it is a Raspberry Pi card whose
# first boot is still pending, even if luks.conf lacks BOARD_TYPE or
# FIRST_BOOT_PENDING. A conflicting board type is refused.
_normalize_offline_state() {
  if [ "$SCENARIO" = "rpi_offline" ]; then
    case "$BOARD_TYPE" in
      ""|rpi) BOARD_TYPE="rpi" ;;
      *) fail "Scenario rpi_offline with BOARD_TYPE=$BOARD_TYPE: only Raspberry Pi (rpi) is supported offline" ;;
    esac
    if [ -z "$FIRST_BOOT_PENDING" ]; then FIRST_BOOT_PENDING="yes"; fi
  fi
  return 0
}

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
    local _ts1 _ts2
    _ts1=$(grep '^TANG_SERVER_1=' "$conf" | cut -d'"' -f2)
    _ts2=$(grep '^TANG_SERVER_2=' "$conf" | cut -d'"' -f2)
    [ -z "${TANG_SERVERS[0]}" ] && [ -n "$_ts1" ] && TANG_SERVERS[0]="$_ts1"
    [ -z "${TANG_SERVERS[1]}" ] && [ -n "$_ts2" ] && TANG_SERVERS[1]="$_ts2"
    _read_offline_conf "$conf"
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
    rpi|rpi_offline)
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
if [ "$ALLOW_LOOP" = true ]; then
  lsblk -d -o NAME,SIZE,MODEL,TRAN
else
  lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "^loop"
fi
echo ""

if [ -n "$DEVICE_ARG" ]; then
  # Device given on the command line: validate it, skip the prompt
  EXT_DEVICE=$(_validate_target_device "${DEVICE_ARG%/}")
  info "Target device (--device): $EXT_DEVICE"
  _detect_ext_partitions "$EXT_DEVICE"
# Ask for device if not auto-detected
elif [ -z "$EXT_DEVICE" ]; then
  if [ "$YES_MODE" = true ]; then
    fail "--yes never prompts for the target device: pass --device=/dev/sdX (the card is chosen explicitly, not guessed)."
  fi
  _ask_value EXT_DEVICE "Enter the target device (e.g., /dev/sdb or /dev/nvme0n1): " "--device=<dev>"
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

# Verify partitions are not mounted (skip when resuming past encrypt - partition is LUKS now)
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
  # Try reading luks.conf from the live system (works for local mode and nvme_migrate)
  if [ -f /root/luks-staged/luks.conf ]; then
    _read_luks_conf_from_root "" 2>/dev/null || true
    # _read_luks_conf_from_root expects mount_point prefix; read directly
    PI_DEVICE=$(grep '^PI_DEVICE=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    PI_BOOT_PART=$(grep '^PI_BOOT_PART=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    PI_ROOT_PART=$(grep '^PI_ROOT_PART=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    [ -z "$BOARD_TYPE" ] && BOARD_TYPE=$(grep '^BOARD_TYPE=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    SCENARIO=$(grep '^SCENARIO=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    SOURCE_DEVICE=$(grep '^SOURCE_DEVICE=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    _ts1=$(grep '^TANG_SERVER_1=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    _ts2=$(grep '^TANG_SERVER_2=' /root/luks-staged/luks.conf | cut -d'"' -f2)
    [ -z "${TANG_SERVERS[0]}" ] && [ -n "$_ts1" ] && TANG_SERVERS[0]="$_ts1"
    [ -z "${TANG_SERVERS[1]}" ] && [ -n "$_ts2" ] && TANG_SERVERS[1]="$_ts2"
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
      # Mount failed - partition may be corrupted from a previous failed cryptsetup attempt.
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
        _ts1=$(grep '^TANG_SERVER_1=' "$_bkp_conf" | cut -d'"' -f2)
        _ts2=$(grep '^TANG_SERVER_2=' "$_bkp_conf" | cut -d'"' -f2)
        [ -z "${TANG_SERVERS[0]}" ] && [ -n "$_ts1" ] && TANG_SERVERS[0]="$_ts1"
        [ -z "${TANG_SERVERS[1]}" ] && [ -n "$_ts2" ] && TANG_SERVERS[1]="$_ts2"
        _read_offline_conf "$_bkp_conf"
        if [ -n "$PI_DEVICE" ]; then
          ok "Read device info from backup luks.conf: $PI_DEVICE (board: ${BOARD_TYPE:-unknown})"
        fi
      fi
    fi
    rmdir "$MOUNT_TMP_ROOT" 2>/dev/null || true
  fi

  if [ -z "$PI_DEVICE" ] || [ -z "$PI_BOOT_PART" ] || [ -z "$PI_ROOT_PART" ]; then
    info "No luks.conf found - asking for internal device path."
    info "This is how the target system sees its own storage."
    _ask_value PI_DEVICE "Enter the INTERNAL device path [/dev/mmcblk0]: " "a luks.conf from luks_prepare.sh on the target root"
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

# rpi_offline: Raspberry Pi card, never booted (external mode, like rpi)
_normalize_offline_state
if [ "$SCENARIO" = "rpi_offline" ]; then
  info "Offline scenario: the card has never been booted (first boot pending: ${FIRST_BOOT_PENDING})"
fi

# USB key: luks.conf with USB_KEY="yes" needs --usb-key-file (fails here, before the backup)
_usbkey_check_conf

# Migrate scenarios run on the board itself - treat as local mode
if [ "$LOCAL_MODE" = false ]; then
  if [ "$SCENARIO" = "nvme_migrate" ] || [ "$SCENARIO" = "usb_migrate" ]; then
    LOCAL_MODE=true
    info "Local mode: migrating to $EXT_DEVICE from current root"
  fi
fi

# --- Prompt for empty tang servers (after luks.conf may have filled them) ---
for i in "${!TANG_SERVERS[@]}"; do
  if [ -z "${TANG_SERVERS[$i]}" ]; then
    _ask_value url "Tang server $((i+1)) URL (e.g. http://tang.example.com): " "--tang=<url1>,<url2>"
    if [ -z "$url" ]; then
      fail "Tang server $((i+1)) must not be empty."
    fi
    TANG_SERVERS[$i]="$url"
  fi
done

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

# Check available disk space for backup (migrate scenarios copy directly, no backup needed)
if [ "$SCENARIO" != "nvme_migrate" ] && [ "$SCENARIO" != "usb_migrate" ]; then
  if [ "$LOCAL_MODE" = true ]; then
    ROOT_USED_KB=$(df --output=used / 2>/dev/null | tail -1 | tr -d ' ')
    info "Root filesystem used space: ~$((ROOT_USED_KB / 1024)) MB"
    NEEDED_KB="$ROOT_USED_KB"
  else
    # External mode: mount the target root briefly to check actual used space
    _size_probe=$(mktemp -d /tmp/luks-size-probe.XXXXXX)
    if mount -o ro "$EXT_ROOT_PART" "$_size_probe" 2>/dev/null; then
      ROOT_USED_KB=$(df --output=used "$_size_probe" 2>/dev/null | tail -1 | tr -d ' ')
      umount "$_size_probe" 2>/dev/null || true
      info "Root filesystem used space: ~$((ROOT_USED_KB / 1024)) MB"
      NEEDED_KB="$ROOT_USED_KB"
    else
      # Fallback to total partition size if mount fails (e.g. corrupted from previous attempt)
      ROOT_SIZE_KB=$(blockdev --getsize64 "$EXT_ROOT_PART" 2>/dev/null | awk '{printf "%d", $1/1024}')
      info "Root partition size (estimate): ~$((ROOT_SIZE_KB / 1024)) MB"
      NEEDED_KB="$ROOT_SIZE_KB"
    fi
    rmdir "$_size_probe" 2>/dev/null || true
  fi

  if [ -n "$BACKUP_DIR_OVERRIDE" ] && [ "$START_PHASE_NUM" -gt 2 ]; then
    # Resume: --backup-dir is the existing backup, nothing to size or ask
    BACKUP_BASE="$BACKUP_DIR_OVERRIDE"
  else
    # Fresh run: --backup-dir, if given, is where the backup is created
    _backup_root="${BACKUP_DIR_OVERRIDE:-/tmp}"
    TMPDIR_AVAIL_KB=$(df --output=avail "$_backup_root" 2>/dev/null | tail -1 | tr -d ' ')
    info "Available space in ${_backup_root}: ~$((TMPDIR_AVAIL_KB / 1024)) MB"

    if [ "$TMPDIR_AVAIL_KB" -lt "$NEEDED_KB" ]; then
      warn "Insufficient space in ${_backup_root} for backup!"
      if [ -n "$BACKUP_DIR_OVERRIDE" ]; then
        fail "--backup-dir=${BACKUP_DIR_OVERRIDE} has too little space (~$((TMPDIR_AVAIL_KB / 1024)) MB free, ~$((NEEDED_KB / 1024)) MB needed). Pass a larger directory with --backup-dir=."
      fi
      _ask_value BACKUP_BASE "Enter an alternative backup directory with enough space: " "--backup-dir=<dir>"
      if [ ! -d "$BACKUP_BASE" ]; then
        fail "Directory $BACKUP_BASE does not exist"
      fi
    else
      BACKUP_BASE="$_backup_root"
    fi
  fi
else
  info "Migration scenario: copying directly from live root (no backup needed)"
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
if _first_boot_pending; then
echo "  First boot pending:    yes (first-boot state is protected and verified)"
fi
if [ -n "$NET_DRIVERS" ]; then
echo "  Initramfs NIC modules: $NET_DRIVERS (checked in every initramfs)"
fi
if [ -n "$USB_KEY_FILE" ]; then
echo "  USB key file:          $USB_KEY_FILE (extra keyslot, label ${USB_KEY_LABEL:-LUKSKEY})"
fi
if [ -n "$BACKUP_BASE" ]; then
  echo "  Backup location:       $BACKUP_BASE"
fi
echo ""
# Without a terminal, find out now (before the long backup) which questions
# would be left, instead of failing at the end of the run
if [ ! -t 0 ]; then
  if [ -z "$PASSPHRASE_FILE" ] && [ "$START_PHASE_NUM" -le 7 ]; then
    fail "A LUKS passphrase is needed but stdin is not a terminal. Use --passphrase-file=<file>."
  fi
  if [ "$SCENARIO" != "nvme_migrate" ] && [ "$SCENARIO" != "usb_migrate" ] \
     && [ "$KEEP_BACKUP" != true ] && [ "$REMOVE_BACKUP" != true ]; then
    fail "The final 'remove the backup?' question cannot be asked: stdin is not a terminal. Use --keep-backup or --remove-backup."
  fi
  if { [ "$SCENARIO" = "nvme_migrate" ] || [ "$SCENARIO" = "usb_migrate" ]; } && [ "$BOARD_TYPE" = "armbian" ] \
     && [ "$YES_MODE" != true ]; then
    fail "The SPI flash question cannot be asked: stdin is not a terminal. Use --yes (answers it with no)."
  fi
fi
if [ -n "$OFFLINE_HOST_DEVICE" ]; then
  # Hint only: the device path on the host changes between runs and ports
  if [ "$OFFLINE_HOST_DEVICE" = "$EXT_DEVICE" ]; then
    info "luks.conf: this card was prepared as $OFFLINE_HOST_DEVICE (same as the selected device)"
  else
    info "luks.conf: this card was prepared as $OFFLINE_HOST_DEVICE on the host; you selected $EXT_DEVICE."
    info "Device names change between runs, so compare model and size above with the card you prepared."
  fi
  echo ""
fi
if [ "$START_PHASE_NUM" -gt 1 ]; then
  echo -e "${YELLOW}Resuming from phase ${START_PHASE_NUM} (${PHASE_NAMES[$((START_PHASE_NUM-1))]})${NC}"
  _ask_confirm "Continue? [y/N] " "--yes" yes || { echo "Aborted."; exit 0; }
else
  echo -e "${RED}WARNING: This will ENCRYPT $EXT_ROOT_PART. Data will be backed up first.${NC}"
  _ask_confirm "Type 'YES' to proceed: " "--yes" yes YES || { echo "Aborted."; exit 0; }
fi

# USB key: read the key file or generate it (before the backup, so a bad file fails early)
_usbkey_prepare_key

# =====================================================================
# 3. Backup root partition (skipped for migrate scenarios)
# =====================================================================

if [ "$SCENARIO" = "nvme_migrate" ] || [ "$SCENARIO" = "usb_migrate" ]; then
  # Migrate: no backup needed, the live root (SD card) stays untouched
  info "=== Skipping backup (migrate: copying directly from live root) ==="
  if [ ! -d "/root/luks-staged" ]; then
    fail "Staged files not found (/root/luks-staged). Did you run luks_prepare.sh first?"
  fi
elif [ "$START_PHASE_NUM" -le 2 ]; then

echo ""
info "=== Phase 1: Backup ==="

BACKUP_DIR=$(mktemp -d "${BACKUP_BASE}/luks-backup.XXXXXX")
BACKUP_DIR_FOR_CLEANUP="$BACKUP_DIR"

if [ "$LOCAL_MODE" = true ]; then
  # Local mode: backup from live root filesystem
  info "Backing up live root filesystem to $BACKUP_DIR..."
  info "This may take a while depending on filesystem size..."
  # rsync exit code 23 = partial transfer (e.g. xattr not supported on tmpfs) - tolerable
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

# When resuming at encrypt phase, backup was already done - locate it now
if [ "$START_PHASE_NUM" -eq 3 ]; then
  _find_backup_dir
fi

echo ""
info "=== Phase 2: LUKS Encryption ==="

# Get LUKS passphrase (--passphrase-file: already loaded and checked at startup)
if [ -n "$PASSPHRASE_FILE" ]; then
  info "Using the LUKS passphrase from $PASSPHRASE_FILE"
else
  while true; do
    _ask_value LUKS_PASS "Enter LUKS passphrase (this is the fallback password): " "--passphrase-file=<file>" secret
    _ask_value LUKS_PASS2 "Confirm LUKS passphrase: " "--passphrase-file=<file>" secret
    if [ "$LUKS_PASS" = "$LUKS_PASS2" ]; then
      if [ ${#LUKS_PASS} -lt $MIN_PASSPHRASE_LEN ]; then
        warn "Passphrase is very short. Use at least 8 characters."
        # --yes does not skip this one
        _ask_confirm "Use this passphrase anyway? [y/N] " "a passphrase of at least ${MIN_PASSPHRASE_LEN} characters" ask || continue
      fi
      break
    else
      warn "Passphrases do not match. Try again."
    fi
  done
fi

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
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$EXT_ROOT_PART" -

info "Opening LUKS device..."
# Close stale mapper device from a previous failed run, if any
if [ -b "/dev/mapper/$LUKS_MAPPER_NAME" ]; then
  warn "Closing stale /dev/mapper/$LUKS_MAPPER_NAME from previous run..."
  cryptsetup luksClose "$LUKS_MAPPER_NAME" 2>/dev/null || true
fi
printf '%s' "$LUKS_PASS" | cryptsetup luksOpen "$EXT_ROOT_PART" "$LUKS_MAPPER_NAME" -
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
  if [ "$SCENARIO" != "nvme_migrate" ] && [ "$SCENARIO" != "usb_migrate" ]; then
    _find_backup_dir
  fi
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

if [ "$SCENARIO" = "nvme_migrate" ] || [ "$SCENARIO" = "usb_migrate" ]; then
  # Migrate: copy directly from live root to encrypted target
  info "Copying live root filesystem to encrypted target..."
  info "This may take a while depending on filesystem size..."
  rsync -aHAXx --info=progress2 \
    --exclude='/dev/*' --exclude='/proc/*' \
    --exclude='/sys/*' --exclude='/tmp/*' --exclude='/run/*' \
    --exclude='/mnt/*' --exclude='/media/*' \
    / "${MOUNT_DST}/" || { RC=$?; [ "$RC" -eq 23 ] && warn "rsync reported non-critical xattr warnings (exit 23), continuing" || exit "$RC"; }

  RESTORED_COUNT=$(find "$MOUNT_DST" | wc -l)
  SRC_COUNT=$(find / -xdev 2>/dev/null | wc -l)
  info "Source file count (approx): $SRC_COUNT"
  info "Copied file count: $RESTORED_COUNT"
else
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
fi

_check_target_health "Phase 3 (restore)"
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
_load_offline_state_from_root
_usbkey_check_conf

if [ ! -d "$STAGED" ]; then
  fail "Staged directory not found at $STAGED"
fi

# Mount boot partition
MOUNT_BOOT=$(mktemp -d /tmp/luks-boot.XXXXXX)
CLEANUP_TMPDIR+=("$MOUNT_BOOT")
mount "$EXT_BOOT_PART" "$MOUNT_BOOT"
CLEANUP_MOUNTS+=("$MOUNT_BOOT")

# --- Board-specific boot config ---

if _is_rpi; then
  # RPi: update cmdline.txt
  if [ -f "$MOUNT_BOOT/cmdline.txt" ]; then
    CURRENT_CMDLINE=$(cat "$MOUNT_BOOT/cmdline.txt")
    CMDLINE_ORIGINAL="$CURRENT_CMDLINE"
    if _first_boot_pending && [ -f "${STAGED}/cmdline.txt" ]; then
      # Offline card: luks_prepare.sh staged the cmdline.txt with the new disk ID
      # and without ' resize'. It is the base; only root= and cryptdevice= are
      # replaced below, everything else (ds=nocloud;i=...) is kept as is.
      CURRENT_CMDLINE=$(cat "${STAGED}/cmdline.txt")
      CMDLINE_ORIGINAL="${CMDLINE_ORIGINAL} ${CURRENT_CMDLINE}"
      info "Offline card: using the staged cmdline.txt as base"
    fi
    NEW_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed \
      -e 's|root=[^ ]*||g' \
      -e 's|cryptdevice=[^ ]*||g' \
      -e 's|  *| |g' \
      -e 's|^ ||' \
      -e 's| $||')
    NEW_CMDLINE="${NEW_CMDLINE} root=${ROOT_DEV} cryptdevice=UUID=${LUKS_UUID}:${LUKS_MAPPER_NAME}"
    # Checked before anything is written: the card's cmdline.txt stays untouched on failure
    _check_cmdline_first_boot "$NEW_CMDLINE" "$CMDLINE_ORIGINAL"
    echo "$NEW_CMDLINE" > "$MOUNT_BOOT/cmdline.txt"
    info "Updated cmdline.txt:"
    echo -e "  ${CYAN}$(cat "$MOUNT_BOOT/cmdline.txt")${NC}"
  else
    _check_cmdline_first_boot "$(cat "${STAGED}/cmdline.txt")" "$(cat "${STAGED}/cmdline.txt")"
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
  if _is_rpi; then
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

_check_target_health "Phase 4 (bootconfig)"
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
  _load_offline_state_from_root
  _usbkey_check_conf
fi

echo ""
info "=== Phase 5: Initramfs Rebuild (chroot) ==="

RESUME_HINT="sudo ./luks_encrypt.sh --start-phase=initramfs${BACKUP_DIR:+ --backup-dir=$BACKUP_DIR}"

# Offline card: the root must still be in its never-booted state before the
# chroot is used (else nothing below can restore a state that is already gone)
if _first_boot_pending; then
  _pre_findings=$(_never_booted_findings root)
  if [ -n "$_pre_findings" ]; then
    while IFS= read -r _l; do warn "$_l"; done <<<"$_pre_findings"
    fail "The root is not in its never-booted state (see above): the first boot of this card would not behave as on a fresh image.
       Re-image the card and run luks_prepare.sh --offline again; remove leftovers of a failed run only if you are sure of what they are."
  fi
  ok "Root is in its never-booted state"
fi

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
if _is_rpi; then
  CHROOT_BOOT_MOUNT="${MOUNT_DST}/boot/firmware"
else
  CHROOT_BOOT_MOUNT="${MOUNT_DST}/boot"
fi
mkdir -p "$CHROOT_BOOT_MOUNT"
mount --bind "$MOUNT_BOOT" "$CHROOT_BOOT_MOUNT"
CLEANUP_MOUNTS+=("$CHROOT_BOOT_MOUNT")

# Save what the chroot may change (machine-id, policy-rc.d, qemu copy, SSH host
# keys) BEFORE the first chroot command; _fb_restore undoes it afterwards and
# from the EXIT trap on every failure path.
_fb_arm

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

# Checksums before the rebuild, to prove afterwards that every image changed
INITRAMFS_PRE_SUMS=$(_initramfs_images | xargs -r -d '\n' sha256sum)

info "Rebuilding initramfs inside chroot..."
if ! chroot "$MOUNT_DST" /bin/bash -c "LC_ALL=C update-initramfs -u -k all"; then
  # A storage error is the more fundamental cause; report it first if present.
  _check_target_health "Phase 5 (initramfs)"
  fail "Initramfs rebuild in chroot failed (see the update-initramfs output above).
       The old initramfs does not know the encrypted root: this card will NOT boot
       (no passphrase prompt either, it ends in 'ALERT! ${ROOT_DEV} does not exist').
       Fix the cause, then resume with: ${RESUME_HINT}"
fi

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

_check_target_health "Phase 5 (initramfs)"
info "Verifying the rebuilt initramfs images..."
if ! _verify_initramfs_images "$INITRAMFS_PRE_SUMS"; then
  fail "Initramfs verification failed (see warnings above): this card will NOT boot.
       Fix the cause, then resume with: ${RESUME_HINT}"
fi
INITRAMFS_VERIFIED=true
ok "Initramfs rebuilt"

# The chroot is done (the verification above may still have used its qemu copy):
# remove the leftovers and restore the first-boot state. Runs in every scenario
# (the qemu copy is a leftover everywhere); the cloud-init and SSH key checks
# only apply to a never-booted card.
if ! _fb_restore; then
  fail "The chroot leftovers / first-boot state could not be restored completely (see warnings above).
       Do not boot this card. Fix the cause, then resume with: ${RESUME_HINT}"
fi
if _first_boot_pending; then
  _post_findings=$(_never_booted_findings root)
  if [ -n "$_post_findings" ]; then
    while IFS= read -r _l; do warn "$_l"; done <<<"$_post_findings"
    fail "The rebuild changed the never-booted state of the root (see above): the first boot would not behave as on a fresh image.
       Do not boot this card. Re-image it and start over."
  fi
  ok "First-boot state intact (machine-id, no SSH host keys, no cloud-init instance, no policy-rc.d, no qemu copy)"
fi
_check_target_health "Phase 5 (first-boot state)"

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
  _ask_value LUKS_PASS "Enter LUKS passphrase (for clevis binding): " "--passphrase-file=<file>" secret
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
  printf '%s' "$LUKS_PASS" > "$KEYFILE"
  chmod 600 "$KEYFILE"

  if clevis luks bind -k "$KEYFILE" -d "$EXT_ROOT_PART" sss "$CONFIG"; then
    ok "Clevis/tang binding successful"
  else
    warn "Clevis binding failed. You can bind later with:"
    warn "  sudo /root/setup_clevis_tang.sh"
  fi

  rm -f "$KEYFILE"
fi

# USB key: master copy on the root, further keyslot, proof that it unlocks (after the tang binding)
_usbkey_enroll

_check_target_health "Phase 6 (clevis)"

fi  # end phase gate: clevis

# =====================================================================
# 9. Verify and cleanup
# =====================================================================

echo ""
info "=== Verification ==="

# Show clevis bindings
info "Clevis bindings on $EXT_ROOT_PART:"
clevis luks list -d "$EXT_ROOT_PART" 2>/dev/null || echo "  (none)"

# Resumed after the initramfs phase on a never-booted card: the root and boot
# partition are needed for the checks below
if { _first_boot_pending || [ -n "$NET_DRIVERS" ] || [ -n "$USB_KEY_FILE" ]; } && [ "$START_PHASE_NUM" -ge 7 ]; then
  _ensure_luks_open
  _ensure_root_mounted
  _ensure_boot_mounted
  if [ -n "$USB_KEY_FILE" ]; then
    _load_offline_state_from_root
    _usbkey_check_conf
  fi
fi

# Verify every initramfs image can unlock the encrypted root
if [ "$INITRAMFS_VERIFIED" = true ]; then
  info "Initramfs images already verified in phase 5"
elif [ -n "$MOUNT_BOOT" ] && mountpoint -q "$MOUNT_BOOT" 2>/dev/null; then
  if ! _verify_initramfs_images; then
    fail "Initramfs verification failed (see warnings above): this card will NOT boot.
       Rebuild it with: sudo ./luks_encrypt.sh --start-phase=initramfs${BACKUP_DIR:+ --backup-dir=$BACKUP_DIR}"
  fi
else
  fail "Boot partition not mounted, cannot verify the initramfs images."
fi

# Never-booted card (offline mode): the image must look exactly as the Imager
# wrote it, so the first boot on the Pi runs the full first-boot logic
if _first_boot_pending; then
  info "Verifying the never-booted state of the card..."
  if [ -z "$MOUNT_DST" ] || ! mountpoint -q "$MOUNT_DST" 2>/dev/null \
     || [ -z "$MOUNT_BOOT" ] || ! mountpoint -q "$MOUNT_BOOT" 2>/dev/null; then
    fail "Root or boot partition not mounted, cannot verify the never-booted state."
  fi
  _nb_findings=$(_never_booted_findings full)
  if [ -n "$_nb_findings" ]; then
    while IFS= read -r _l; do warn "$_l"; done <<<"$_nb_findings"
    fail "The card is no longer in its never-booted state (see above): its first boot would not work as on a fresh image.
       Do not boot this card."
  fi
  ok "Never-booted state verified (machine-id, SSH keys, cloud-init, seed files, cmdline.txt, no leftovers)"
fi

# USB key: master copy, writer script, unlock test and keyslot count (USB_KEY="yes" only)
_usbkey_verify

_check_target_health "Verification"

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
      elif [ "$YES_MODE" = true ]; then
        info "--yes answers the SPI flash question with no: nothing flashed."
        info "Flash later, e.g.: dd if=${SPI_IMAGES[0]} of=/dev/mtdblock0 conv=notrunc status=progress"
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
            _ask_value IMG_NUM "Select image number [1-${#SPI_IMAGES[@]}]: " "--yes (skips the SPI flash)"
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
        if _ask_confirm "Write U-Boot to SPI flash for ${STORAGE_TYPE} boot? [y/N] " "--yes (skips the SPI flash)" no; then
          MTD_SIZE=$(cat /sys/class/mtd/mtd0/size 2>/dev/null || echo "")
          if [ -z "$MTD_SIZE" ] || [ "$MTD_SIZE" -eq 0 ]; then
            warn "Cannot determine SPI flash size - skipping erase+write"
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
              ok "SPI flash verified - U-Boot written successfully"
              SPI_FLASHED=true
            else
              warn "SPI flash verification failed - data appears empty after write"
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
    info "Not an RK3588 board - skipping SPI flash step"
  fi
fi

# Remove backup (only if a backup was created or found)
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
  # Last line of defence: never drop the backup after storage errors
  _check_target_health "Before removing the backup"
  echo ""
  info "Keep the backup until the device has booted from the encrypted root."
  RM_BACKUP_NOW=false
  if [ "$REMOVE_BACKUP" = true ]; then
    info "--remove-backup: removing $BACKUP_DIR"
    RM_BACKUP_NOW=true
  elif [ "$KEEP_BACKUP" = true ]; then
    info "--keep-backup: keeping $BACKUP_DIR"
  elif _ask_confirm "Remove backup directory $BACKUP_DIR now? [y/N] " "--keep-backup or --remove-backup" ask; then
    RM_BACKUP_NOW=true
  fi
  if [ "$RM_BACKUP_NOW" = true ]; then
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
if [ "${#WARNINGS[@]}" -eq 0 ]; then
  echo -e "${GREEN}Encryption complete!${NC}"
else
  echo -e "${YELLOW}Encryption complete, with ${#WARNINGS[@]} warning(s):${NC}"
  for _w in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}-${NC} ${_w}"
  done
fi
echo "================================================================="
echo ""

if [ "$SCENARIO" = "rpi_offline" ]; then
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Put the card into the Raspberry Pi (it has never been booted)"
  echo "  2. Connect the Ethernet cable (tang servers must be reachable)"
  echo "  3. Power on: the initramfs brings up the network, clevis unlocks the root via tang"
  echo "  4. Then the normal first boot runs: resize services, SSH host keys, cloud-init"
  echo "     (user, hostname, SSH keys, Wi-Fi from the seed on the boot partition)"
  if [ -n "$USB_KEY_FILE" ] || [ "$USB_KEY" = "yes" ]; then
    echo "  5. Optional: plug in the prepared USB stick (label ${USB_KEY_LABEL:-LUKSKEY}, see below) instead of"
    echo "     relying on tang: stick plus card unlock the system without tang or passphrase"
  fi

elif _is_rpi; then
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
  warn "After successful ${STORAGE_TYPE} boot, disable eMMC boot by clearing its bootable flag:"
  if [ -n "$SOURCE_DEVICE" ]; then
    warn "  parted ${SOURCE_DEVICE} set 1 boot off"
  else
    warn "  parted /dev/mmcblk1 set 1 boot off"
  fi

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
if [ -n "$USB_KEY_FILE" ] || [ "$USB_KEY" = "yes" ]; then
echo "    cryptsetup luksDump ${PI_ROOT_PART} | grep -cE '^\\s+[0-9]+: luks2\$'   # USB key: prints 3 (passphrase, clevis, USB key)"
echo "    cryptsetup open --test-passphrase --key-file ${USB_KEY_ROOT_PATH} ${PI_ROOT_PART}   # USB key: exit 0"
fi
echo ""
if [ -n "$USB_KEY_FILE" ] || [ "$USB_KEY" = "yes" ]; then
_usbkey_next_steps
fi
echo "  If clevis was not bound (tang unreachable), bind with:"
echo "    sudo /root/setup_clevis_tang.sh"
echo ""
if [ "$SCENARIO" = "rpi_offline" ]; then
echo "  Fully non-interactive run for the next card:"
echo "    sudo ./luks_encrypt.sh --device=/dev/sdX --yes --passphrase-file=/path/to/pass --tang=http://a,http://b --keep-backup${USB_KEY_FILE:+ --usb-key-file=$USB_KEY_FILE}"
echo ""
echo "  After the first boot (offline card), also check:"
echo "    cloud-init status --long             # status: done, no errors"
echo "    cat /etc/machine-id                  # a real ID now"
echo "    ls /etc/ssh/ssh_host_*               # host keys exist"
echo "    lsblk; lvs                           # ${PI_ROOT_PART} over the whole card, ${LVM_VG_NAME}/${LVM_LV_NAME} full size"
echo "    grep -c ' resize' /proc/cmdline      # 0"
echo ""
fi
