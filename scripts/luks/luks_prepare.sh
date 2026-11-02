#!/bin/bash
# luks_prepare.sh - Prepare a Linux SBC for LUKS encryption with clevis/tang
#
# Supports:
#   - Raspberry Pi (SD card / NVMe with separate FAT32 boot partition)
#   - Armbian/U-Boot boards like Rock 5B (single root partition, /boot on root)
#   - Raspberry Pi OS card that was never booted, prepared offline on a workstation
#     (--offline=<device> --board=<model>, aarch64 chroot via qemu on x86_64 hosts)
#
# After running this script:
#   RPi:     Shut down, move SD/NVMe to external machine, run luks_encrypt.sh
#   Armbian: For NVMe/USB migration, run luks_encrypt.sh directly on the same machine
#            For in-place eMMC, boot from SD, run luks_encrypt.sh against eMMC
#   Offline: Run luks_encrypt.sh --device=<device> on the same workstation
#
# Usage: sudo ./luks_prepare.sh
#        sudo ./luks_prepare.sh --offline=/dev/sdX --board=pi5

set -euo pipefail

# --- Configuration ---
TANG_SERVERS=("" "")
LUKS_MAPPER_NAME="rootfs"
STAGED_DIR="/root/luks-staged"
USE_LVM=true                  # Set to false for LUKS-only (no LVM layer)
LVM_VG_NAME="pivg"            # Volume group name
LVM_LV_NAME="root"            # Logical volume name for root filesystem
BOOT_PARTITION_SIZE_MB=1536   # Boot partition size in MiB (1.5 GB)
BOOT_PARTITION_LABEL="armbi_boot"  # Filesystem label for the boot partition
TANG_TIMEOUT=5                # Timeout in seconds for tang server connectivity checks
CRYPTO_MODULES=(algif_skcipher dm-crypt aes_arm64 sha256)  # Kernel crypto modules for initramfs
PARTPROBE_DELAY=2             # Seconds to wait after partprobe for partition table refresh
IP_METHOD="dhcp"              # IP config for initramfs (kernel ip= parameter)
                              # "dhcp" → IP=:::::eth0:dhcp  (auto-builds with detected IFACE)
                              # For static IP, set the full ip= string instead:
                              # IP_METHOD="192.168.1.100::192.168.1.1:255.255.255.0::eth0:none"
                              # Kernel syntax: ip=<client>:<server>:<gw>:<mask>:<host>:<iface>:<proto>

# Derived: root device path depends on LVM mode
if [ "$USE_LVM" = true ]; then
  ROOT_DEV="/dev/${LVM_VG_NAME}/${LVM_LV_NAME}"
else
  ROOT_DEV="/dev/mapper/${LUKS_MAPPER_NAME}"
fi

# --- Offline mode configuration ---
TARGET_ROOT=""                # Empty: act on the running system. Offline: mount point of the card's root
OFFLINE_REQUESTED=false       # --offline=... given
OFFLINE_DEVICE=""             # Whole card as seen on this workstation (e.g. /dev/sdX)
BOARD_ARG=""                  # pi5, pi4, pi3bplus, pi3b or all
IFACE_ARG=""                  # Interface name inside the Pi (default eth0)
ASSUME_YES=false              # --yes: answer every "Continue?" question with yes
TANG_ARG=""                   # --tang=<url1>,<url2>: replaces TANG_SERVERS
ALLOW_LOOP=false              # Test only: accept /dev/loopN with partitions /dev/loopNp1 and p2
NET_DRIVERS=()                # Ethernet driver modules for the initramfs
MIN_FREE_AFTER_P2_SECTORS=131072  # Offline: free space behind partition 2 (512-byte sectors, 64 MiB) proving "not grown"
MAX_MBR_SECTOR=4294967295     # Last sector an MBR partition can end at

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
# Report a problem without leaving the script (used where the caller collects several problems)
soft_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }

# --- Help ---
usage() {
  cat << 'EOF'
Usage: sudo ./luks_prepare.sh
       sudo ./luks_prepare.sh --offline=<device> --board=<model> [--iface=<name>] [--yes] [--tang=<url1>,<url2>]

Prepare a Linux SBC for LUKS encryption with clevis/tang.

Supports:
  - Raspberry Pi (SD card / NVMe with separate FAT32 boot partition)
  - Armbian/U-Boot boards like Rock 5B (single root partition, /boot on root)
  - Raspberry Pi OS card that was never booted (offline mode, see below)

Online mode (default): runs ON the board to install packages, configure initramfs,
and stage boot configs. After running:
  RPi:     Shut down, move SD/NVMe to external machine, run luks_encrypt.sh
  Armbian: For NVMe/USB migration, run luks_encrypt.sh on the same machine
           For in-place eMMC, boot from SD, run luks_encrypt.sh against eMMC

Offline mode: runs on the workstation with the freshly written, never booted card
(Raspberry Pi Imager 2.x with cloud-init customisation, Trixie). The card gets its
partition 2 grown and a new disk ID, the packages and initramfs hooks are installed
in an aarch64 chroot, and the first-boot state (machine-id, SSH keys, cloud-init)
is kept intact. Then run luks_encrypt.sh --device=<device> on the same workstation.

Options:
  -h, --help          Show this help
  --offline=<device>  Prepare the card in <device> (whole disk, e.g. /dev/sdX) on this
                      workstation instead of the running system. Needs root, parted,
                      sfdisk, e2fsck, cryptsetup, clevis, jq, curl, lsinitramfs, findmnt
                      and, on a non-aarch64 host, a binfmt_misc entry for aarch64 with
                      flag F (package qemu-user-static)
  --board=<model>     Required with --offline. Selects the Ethernet driver for the
                      initramfs: pi5 (macb), pi4 (bcmgenet), pi3bplus (lan78xx),
                      pi3b (smsc95xx) or all (all four, larger initramfs)
  --iface=<name>      Interface name inside the Pi for the initramfs network
                      configuration (default: eth0), only with --offline
  --allow-loop        Test only: accept /dev/loopN (partitions /dev/loopNp1 and
                      /dev/loopNp2, attach with losetup -P), only with --offline
  --yes               Answer every "Continue? [y/N]" question with yes. Needed when stdin is
                      not a terminal. The scenario menu and the "Type 'YES' to partition"
                      questions of the Armbian migrate flows stay interactive
  --tang=<u1>,<u2>    The two tang server URLs, comma separated (replaces the TANG_SERVERS
                      array of this script and avoids the URL prompts)

Examples:
  Online (on the board):    sudo ./luks_prepare.sh
  Offline (on workstation): sudo ./luks_prepare.sh --offline=/dev/sdX --board=pi5 --yes --tang=http://a,http://b
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --offline=*) OFFLINE_REQUESTED=true; OFFLINE_DEVICE="${arg#--offline=}" ;;
    --board=*)   BOARD_ARG="${arg#--board=}" ;;
    --iface=*)   IFACE_ARG="${arg#--iface=}" ;;
    --allow-loop) ALLOW_LOOP=true ;;
    --yes)       ASSUME_YES=true ;;
    --tang=*)    TANG_ARG="${arg#--tang=}" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ -n "$TANG_ARG" ] || [[ " $* " == *" --tang="* ]]; then
  IFS=',' read -ra _TANG_LIST <<<"$TANG_ARG"
  if [ "${#_TANG_LIST[@]}" -ne "${#TANG_SERVERS[@]}" ]; then
    fail "--tang needs exactly ${#TANG_SERVERS[@]} comma separated URLs (got ${#_TANG_LIST[@]}), e.g. --tang=http://a,http://b"
  fi
  for _u in "${_TANG_LIST[@]}"; do
    [[ "$_u" =~ ^https?://[^[:space:],\"\']+$ ]] || fail "Invalid tang URL in --tang: '${_u}' (expected http://host[:port] or https://...)"
  done
  TANG_SERVERS=("${_TANG_LIST[@]}")
fi

if [ "$OFFLINE_REQUESTED" = true ]; then
  OFFLINE_DEVICE="${OFFLINE_DEVICE%/}"
  [ -n "$OFFLINE_DEVICE" ] || fail "--offline needs a device, e.g. --offline=/dev/sdX"
  [ -n "$BOARD_ARG" ] || fail "--offline needs --board=pi5|pi4|pi3bplus|pi3b|all"
  case "$BOARD_ARG" in
    pi5|pi4|pi3bplus|pi3b|all) ;;
    *) fail "Unknown --board=$BOARD_ARG (use pi5, pi4, pi3bplus, pi3b or all)" ;;
  esac
  IFACE_ARG="${IFACE_ARG:-eth0}"
  [[ "$IFACE_ARG" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,14}$ ]] || fail "Invalid --iface=$IFACE_ARG"
elif [ -n "$BOARD_ARG" ] || [ -n "$IFACE_ARG" ] || [ "$ALLOW_LOOP" = true ]; then
  fail "--board, --iface and --allow-loop only work together with --offline=<device>"
fi

# Run a command in the target system: directly when TARGET_ROOT is empty (online),
# inside a chroot of the mounted card otherwise (offline)
_in_target() {
  if [ -z "$TARGET_ROOT" ]; then
    "$@"
  else
    chroot "$TARGET_ROOT" "$@"
  fi
}

# Print the Ethernet driver module(s) of a --board value (section "network driver" of the plan)
board_net_drivers() {
  case "$1" in
    pi5)      echo "macb" ;;
    pi4)      echo "bcmgenet" ;;
    pi3bplus) echo "lan78xx" ;;
    pi3b)     echo "smsc95xx" ;;
    all)      echo "macb bcmgenet lan78xx smsc95xx" ;;
  esac
}

# Fail with a clear message if a question would have to be answered without a terminal.
# Usage: _need_terminal "<what is asked>" ["<option that avoids the question>"]
_need_terminal() {
  if [ ! -t 0 ]; then
    fail "${1} needs an answer, but stdin is not a terminal${2:+. Pass ${2} to avoid the question}."
  fi
}

# Ask a yes/no question. Returns 0 for yes. --yes answers it, no terminal fails.
# Usage: _ask_confirm "<prompt>" "<option that avoids it>"
_ask_confirm() {
  local prompt="$1" option="$2" answer
  if [ "$ASSUME_YES" = true ]; then
    info "${prompt}yes (--yes)"
    return 0
  fi
  _need_terminal "'${prompt}'" "$option"
  read -rp "$prompt" answer
  [[ "$answer" == [yY] ]]
}

# --- Prompt for empty tang servers ---
_prompt_tang_servers() {
  for i in "${!TANG_SERVERS[@]}"; do
    if [ -z "${TANG_SERVERS[$i]}" ]; then
      _need_terminal "Tang server $((i+1)) URL" "--tang=<url1>,<url2>"
      read -rp "Tang server $((i+1)) URL (e.g. http://tang.example.com): " url
      if [ -z "$url" ]; then
        fail "Tang server $((i+1)) must not be empty."
      fi
      TANG_SERVERS[$i]="$url"
    fi
  done
}

# =====================================================================
# Steps 6 to 13: shared by the online flow and the offline flow.
# Every written path carries "${TARGET_ROOT}" (empty when online).
# =====================================================================

# 6. Install packages
install_packages() {
  info "Installing required packages..."
  local apt_env=()
  if [ -n "$TARGET_ROOT" ]; then
    apt_env=(env DEBIAN_FRONTEND=noninteractive)
  fi
  _in_target "${apt_env[@]}" apt-get update -qq

  LVM_PKGS=""
  if [ "$USE_LVM" = true ]; then
    LVM_PKGS="lvm2"
  fi

  _in_target "${apt_env[@]}" apt-get install -y \
    cryptsetup cryptsetup-initramfs \
    clevis clevis-luks clevis-initramfs clevis-systemd \
    curl jq $LVM_PKGS
  ok "Packages installed"
}

# 7. Configure initramfs modules
configure_modules() {
  info "Configuring initramfs modules..."

  MODULES_FILE="${TARGET_ROOT}/etc/initramfs-tools/modules"

  if [ "$USE_LVM" = true ]; then
    CRYPTO_MODULES+=(dm-mod)
  fi

  for mod in "${CRYPTO_MODULES[@]}"; do
    if ! grep -qxF "$mod" "$MODULES_FILE" 2>/dev/null; then
      echo "$mod" >> "$MODULES_FILE"
      info "  Added module: $mod"
    else
      info "  Already present: $mod"
    fi
  done

  for drv in "${NET_DRIVERS[@]}"; do
    if ! grep -qxF "$drv" "$MODULES_FILE" 2>/dev/null; then
      echo "$drv" >> "$MODULES_FILE"
      info "  Added network driver module: $drv"
    else
      info "  Network driver already present: $drv"
    fi
  done

  ok "Initramfs modules configured"
}

# 8. Create initramfs hooks
create_hooks() {
  info "Creating initramfs hooks..."

  # copycrypttab hook
  cat > "${TARGET_ROOT}/etc/initramfs-tools/hooks/copycrypttab" << 'HOOKEOF'
#!/bin/sh
cp /etc/crypttab "${DESTDIR}/etc/crypttab"
exit 0
HOOKEOF
  chmod +x "${TARGET_ROOT}/etc/initramfs-tools/hooks/copycrypttab"
  info "  Created /etc/initramfs-tools/hooks/copycrypttab"

  # luks_hooks - copy required binaries into initramfs
  cat > "${TARGET_ROOT}/etc/initramfs-tools/hooks/luks_hooks" << 'HOOKEOF'
#!/bin/sh -e

PREREQS=""
case $1 in
prereqs) echo "${PREREQS}"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /lib/cryptsetup/scripts/passdev /usr/sbin/passdev
copy_exec /usr/lib/aarch64-linux-gnu/libgcc_s.so.1 /usr/lib/aarch64-linux-gnu
copy_exec /sbin/resize2fs /sbin
copy_exec /sbin/fdisk /sbin
copy_exec /sbin/cryptsetup /sbin
HOOKEOF
  chmod +x "${TARGET_ROOT}/etc/initramfs-tools/hooks/luks_hooks"
  info "  Created /etc/initramfs-tools/hooks/luks_hooks"

  # cleanup-netplan init-bottom script - removes stale netplan YAML from initramfs DHCP
  SCRIPT_DIR_HOOKS="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "${SCRIPT_DIR_HOOKS}/initramfs_local-bottom_cleanup-netplan" ]; then
    mkdir -p "${TARGET_ROOT}/etc/initramfs-tools/scripts/init-bottom"
    cp "${SCRIPT_DIR_HOOKS}/initramfs_local-bottom_cleanup-netplan" \
      "${TARGET_ROOT}/etc/initramfs-tools/scripts/init-bottom/cleanup-netplan"
    chmod 755 "${TARGET_ROOT}/etc/initramfs-tools/scripts/init-bottom/cleanup-netplan"
    info "  Created /etc/initramfs-tools/scripts/init-bottom/cleanup-netplan"

    # Remove old incorrect location if present
    if [ -f "${TARGET_ROOT}/etc/initramfs-tools/scripts/local-bottom/cleanup-netplan" ]; then
      rm -f "${TARGET_ROOT}/etc/initramfs-tools/scripts/local-bottom/cleanup-netplan"
      info "  Removed old /etc/initramfs-tools/scripts/local-bottom/cleanup-netplan"
    fi

  else
    warn "initramfs_local-bottom_cleanup-netplan not found in script directory - skipping"
  fi

  ok "Initramfs hooks created"
}

# 9. Configure initramfs networking (for clevis tang at boot)
configure_networking() {
  info "Configuring initramfs networking..."

  INITRAMFS_CONF="${TARGET_ROOT}/etc/initramfs-tools/initramfs.conf"

  # Set DEVICE
  if grep -q "^DEVICE=" "$INITRAMFS_CONF"; then
    sed -i "s/^DEVICE=.*/DEVICE=${IFACE}/" "$INITRAMFS_CONF"
  else
    echo "DEVICE=${IFACE}" >> "$INITRAMFS_CONF"
  fi
  info "  Set DEVICE=${IFACE}"

  # Set IP for boot-time network (kernel IP autoconfiguration format)
  if [ "$IP_METHOD" = "dhcp" ]; then
    IP_LINE="IP=:::::${IFACE}:dhcp"
  else
    # Static: IP_METHOD contains the full ip= value (e.g., 192.168.1.100::192.168.1.1:255.255.255.0::eth0:none)
    IP_LINE="IP=${IP_METHOD}"
  fi
  if grep -q "^IP=" "$INITRAMFS_CONF"; then
    sed -i "s/^IP=.*/${IP_LINE}/" "$INITRAMFS_CONF"
  else
    sed -i "/^DEVICE=/a ${IP_LINE}" "$INITRAMFS_CONF"
  fi
  info "  Set $IP_LINE"

  # Set FSTYPE based on board type
  if [ "$BOARD_TYPE" = "rpi" ]; then
    FSTYPE_VALUE="ext4,vfat"
  else
    FSTYPE_VALUE="ext4"
  fi
  if grep -q "^FSTYPE=" "$INITRAMFS_CONF"; then
    sed -i "s/^FSTYPE=.*$/FSTYPE=${FSTYPE_VALUE}/" "$INITRAMFS_CONF"
  else
    echo "FSTYPE=${FSTYPE_VALUE}" >> "$INITRAMFS_CONF"
  fi
  info "  Set FSTYPE=${FSTYPE_VALUE}"

  ok "Initramfs networking configured"
}

# 10. Create kernel postinst hook (RPi only)
create_postinst_hook() {
  if [ "$BOARD_TYPE" = "rpi" ]; then
    info "Creating kernel postinst hook..."

    cat > "${TARGET_ROOT}/etc/kernel/postinst.d/initramfs-rebuild" << 'HOOKEOF'
#!/bin/sh -e

# Rebuild initramfs.gz after kernel upgrade to include new kernel's modules.
# https://github.com/Robpol86/robpol86.com/blob/master/docs/_static/initramfs-rebuild.sh
# Save as (chmod +x): /etc/kernel/postinst.d/initramfs-rebuild

# Remove splash from cmdline.
if grep -q '\bsplash\b' /boot/firmware/cmdline.txt; then
  sed -i 's/ \?splash \?/ /' /boot/firmware/cmdline.txt
fi

# Exit if not building kernel for this Raspberry Pi's hardware version.
version="$1"
current_version="$(uname -r)"
case "${current_version}" in
  *-v7+)
    case "${version}" in
      *-v7+) ;;
      *) exit 0
    esac
  ;;
  *+)
    case "${version}" in
      *-v7+) exit 0 ;;
    esac
  ;;
esac

# Exit if rebuild cannot be performed or not needed.
[ -x /usr/sbin/mkinitramfs ] || exit 0
[ -f /boot/firmware/initramfs.gz ] || exit 0
lsinitramfs /boot/firmware/initramfs.gz |grep -q "/$version$" && exit 0 # Already in initramfs.

# Rebuild.
mkinitramfs -o /boot/firmware/initramfs.gz "$version"
HOOKEOF
    chmod +x "${TARGET_ROOT}/etc/kernel/postinst.d/initramfs-rebuild"
    ok "Kernel postinst hook created"
  else
    info "Skipping kernel postinst hook (Armbian has its own initramfs hooks)"
  fi
}

# 11. Stage boot configuration files
stage_boot_files() {
  local sd="${TARGET_ROOT}${STAGED_DIR}"
  local bd="${TARGET_ROOT}${BOOT_DIR}"

  info "Staging boot configuration files in $STAGED_DIR..."
  mkdir -p "$sd"

  if [ "$BOARD_TYPE" = "rpi" ]; then
    # --- RPi: stage cmdline.txt ---
    CURRENT_CMDLINE=""
    if [ -f "${bd}/cmdline.txt" ]; then
      CURRENT_CMDLINE=$(cat "${bd}/cmdline.txt")
    fi
    NEW_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed \
      -e 's|root=[^ ]*||g' \
      -e 's|cryptdevice=[^ ]*||g' \
      -e 's|  *| |g' \
      -e 's|^ ||' \
      -e 's| $||')
    NEW_CMDLINE="${NEW_CMDLINE} root=${ROOT_DEV} cryptdevice=${ROOT_PART}:${LUKS_MAPPER_NAME}"
    cat > "${sd}/cmdline.txt" << EOF
${NEW_CMDLINE}
EOF
    info "  Staged cmdline.txt"

  elif [ "$BOARD_TYPE" = "armbian" ]; then
    # --- Armbian: stage armbianEnv.txt ---
    cp "${bd}/armbianEnv.txt" "${sd}/armbianEnv.txt.orig"
    sed "s|^rootdev=.*|rootdev=${ROOT_DEV}|" \
      "${bd}/armbianEnv.txt" > "${sd}/armbianEnv.txt"
    info "  Staged armbianEnv.txt (rootdev=${ROOT_DEV})"
  fi

  # Staged crypttab (clevis/tang, no keyfile - uses luks,initramfs for clevis)
  cat > "${sd}/crypttab" << EOF
# <target name>	<source device>		<key file>	<options>
${LUKS_MAPPER_NAME}	${ROOT_PART}	none	luks,initramfs
EOF
  info "  Staged crypttab"

  # Staged fstab
  if [ -f "${TARGET_ROOT}/etc/fstab" ]; then
    # Replace the root mount line (whatever currently points to /)
    sed -e "s|^[^ ]*\([ \t]\+/[ \t]\+\)|${ROOT_DEV}\1|" \
      "${TARGET_ROOT}/etc/fstab" > "${sd}/fstab"
  else
    if [ "$BOARD_TYPE" = "rpi" ]; then
      cat > "${sd}/fstab" << EOF
proc            /proc           proc    defaults          0       0
${BOOT_PART}  /boot/firmware  vfat    defaults          0       2
${ROOT_DEV}  /               ext4    defaults,noatime  0       1
EOF
    else
      cat > "${sd}/fstab" << EOF
proc            /proc           proc    defaults          0       0
${BOOT_PART}  /boot           ext4    defaults          0       2
${ROOT_DEV}  /               ext4    defaults,noatime  0       1
EOF
    fi
  fi

  # Ensure /boot mount is correct in staged fstab
  if [ "$BOARD_TYPE" = "armbian" ]; then
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
    if grep -qE "^\S+\s+/boot\s+" "${sd}/fstab"; then
      sed -i -E "s|^[^ ]+(\s+/boot\s+)|UUID=${BOOT_UUID}\1|" "${sd}/fstab"
    else
      echo "UUID=${BOOT_UUID}  /boot  ext4  defaults  0  2" >> "${sd}/fstab"
    fi
  fi
  info "  Staged fstab"

  # Write config file with device info (used by luks_encrypt.sh)
  cat > "${sd}/luks.conf" << EOF
# Auto-generated by luks_prepare.sh - device paths and board info
BOARD_TYPE="${BOARD_TYPE}"
BOOT_DIR="${BOOT_DIR}"
PI_DEVICE="${DEVICE}"
PI_BOOT_PART="${BOOT_PART}"
PI_ROOT_PART="${ROOT_PART}"
SOURCE_DEVICE="${CURRENT_ROOT_DISK:-}"
SCENARIO="${SCENARIO}"
TANG_SERVER_1="${TANG_SERVERS[0]}"
TANG_SERVER_2="${TANG_SERVERS[1]}"
EOF
  if [ -n "$TARGET_ROOT" ]; then
    # Offline mode: extra keys for luks_encrypt.sh (device paths above are the paths inside the Pi)
    cat >> "${sd}/luks.conf" << EOF
DEVICE="${IFACE}"
NET_DRIVERS="${NET_DRIVERS[*]}"
OFFLINE_HOST_DEVICE="${OFFLINE_DEVICE}"
FIRST_BOOT_PENDING="yes"
EOF
  fi
  info "  Staged luks.conf (BOARD_TYPE=${BOARD_TYPE}, DEVICE=${DEVICE})"

  # Copy the encrypt script to staged dir so it's available on the storage
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "${SCRIPT_DIR}/luks_encrypt.sh" ]; then
    cp "${SCRIPT_DIR}/luks_encrypt.sh" "${sd}/luks_encrypt.sh"
    chmod +x "${sd}/luks_encrypt.sh"
    info "  Staged luks_encrypt.sh"
  fi

  # Copy tang_check_connection.sh to staged dir
  if [ -f "${SCRIPT_DIR}/tang_check_connection.sh" ]; then
    cp "${SCRIPT_DIR}/tang_check_connection.sh" "${sd}/tang_check_connection.sh"
    chmod +x "${sd}/tang_check_connection.sh"
    info "  Staged tang_check_connection.sh"
  fi

  # Copy cleanup-netplan hook to staged dir
  if [ -f "${SCRIPT_DIR}/initramfs_local-bottom_cleanup-netplan" ]; then
    cp "${SCRIPT_DIR}/initramfs_local-bottom_cleanup-netplan" "${sd}/cleanup-netplan"
    info "  Staged cleanup-netplan"
  fi

  # RPi-specific: ensure auto_initramfs=1 in config.txt
  if [ "$BOARD_TYPE" = "rpi" ] && [ -f "${bd}/config.txt" ]; then
    if ! grep -q "^auto_initramfs=1" "${bd}/config.txt"; then
      echo "auto_initramfs=1" >> "${bd}/config.txt"
      info "  Added auto_initramfs=1 to ${BOOT_DIR}/config.txt"
    else
      info "  auto_initramfs=1 already in config.txt"
    fi
  fi

  ok "Boot configuration files staged"
}

# Show staged files for review
show_staged_files() {
  local sd="${TARGET_ROOT}${STAGED_DIR}"
  echo ""
  if [ "$BOARD_TYPE" = "rpi" ]; then
    info "Staged cmdline.txt:"
    echo -e "  ${CYAN}$(cat "${sd}/cmdline.txt")${NC}"
    echo ""
  elif [ "$BOARD_TYPE" = "armbian" ]; then
    info "Staged armbianEnv.txt (diff):"
    diff --color=always "${sd}/armbianEnv.txt.orig" "${sd}/armbianEnv.txt" || true
    echo ""
  fi
  info "Staged crypttab:"
  echo -e "  ${CYAN}$(cat "${sd}/crypttab")${NC}"
  echo ""
  info "Staged fstab (root + boot lines):"
  echo -e "  ${CYAN}$(grep -E "[ \t]+/([ \t]|boot)" "${sd}/fstab" | head -3)${NC}"
}

# 12. Rebuild initramfs
rebuild_initramfs() {
  echo ""
  info "Rebuilding initramfs..."
  _in_target update-initramfs -u -k all || return $?
  ok "Initramfs rebuilt"
}

# 13. Verify tang server connectivity
verify_tang_connectivity() {
  echo ""
  info "Verifying tang server connectivity..."
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
    warn "Not all tang servers are reachable. Clevis binding will fail in the encrypt script."
    warn "Ensure tang servers are running before proceeding."
  else
    ok "All tang servers reachable"
  fi
}

# =====================================================================
# Offline mode: card in this workstation, never booted
# Phases: preflight, partition, chroot, packages, configure, initramfs, restore
# =====================================================================

OFFLINE_P1=""                   # Boot partition as seen on this host
OFFLINE_P2=""                   # Root partition as seen on this host
OFFLINE_MNT=""                  # Mount point of the card's root (becomes TARGET_ROOT)
OFFLINE_MOUNTS=()               # Everything mounted by this script, in mount order
OFFLINE_STATE_DIR=""            # Saved first-boot state
OFFLINE_STATE_SAVED=false
OFFLINE_STATE_RESTORED=false
OFFLINE_RESTORE_FAILED=false
POLICY_CREATED=false
QEMU_COPIED=false
BINFMT_INTERP=""
OLD_DISK_ID=""
NEW_DISK_ID=""
SCRIPT_START_EPOCH=$(date +%s)
TARGET_KNAMES=""                # Kernel names (sdc, sdc2, ...) of the card, for the kernel log check

# Mount something and remember its mount point (last argument) for the cleanup
_off_mount() {
  mount "$@"
  OFFLINE_MOUNTS+=("${!#}")
}

# Unmount everything in reverse order (lazy as fallback), then flush
_off_umount_all() {
  local i m
  sync
  for (( i=${#OFFLINE_MOUNTS[@]}-1 ; i>=0 ; i-- )); do
    m="${OFFLINE_MOUNTS[$i]}"
    if mountpoint -q "$m" 2>/dev/null; then
      if ! umount "$m" 2>/dev/null; then
        warn "Could not unmount $m cleanly, using a lazy unmount"
        umount -l "$m" 2>/dev/null || warn "Could not unmount $m at all"
      fi
    fi
  done
  OFFLINE_MOUNTS=()
  sync
}

# --- Host and device preflight ---

# binfmt_misc entry for aarch64 with flag F (interpreter loaded at registration, usable in a chroot)
_check_binfmt_aarch64() {
  local d=/proc/sys/fs/binfmt_misc f magic flags found=false seen_no_f=""
  if [ ! -e "$d/status" ]; then
    fail "binfmt_misc is not available ($d/status missing). Install qemu-user-static (with binfmt-support) or run: mount -t binfmt_misc binfmt_misc $d"
  fi
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in register|status) continue ;; esac
    magic=$(sed -n 's/^magic //p' "$f" 2>/dev/null || true)
    case "$magic" in 7f454c4602*b700) ;; *) continue ;; esac
    head -n 1 "$f" 2>/dev/null | grep -qx enabled || continue
    flags=$(sed -n 's/^flags: //p' "$f" 2>/dev/null || true)
    if [[ "$flags" == *F* ]]; then
      found=true
      BINFMT_INTERP=$(sed -n 's/^interpreter //p' "$f")
      info "  binfmt_misc: $(basename "$f") -> ${BINFMT_INTERP} (flags: ${flags})"
      break
    fi
    seen_no_f="$(basename "$f") (flags: ${flags:-none})"
  done
  if [ "$found" != true ]; then
    if [ -n "$seen_no_f" ]; then
      fail "binfmt_misc entry for aarch64 found but without flag F: ${seen_no_f}. Without F the interpreter is not loaded at registration and fails inside the chroot. Re-register it with the F flag (qemu-user-static does this)."
    fi
    fail "No enabled binfmt_misc entry for aarch64 on this ${ARCH_HOST} host. Install qemu-user-static (with binfmt-support) and make sure it registers with flag F."
  fi
}

_offline_check_host() {
  info "Preflight: host"
  ARCH_HOST=$(uname -m)
  if [ "$EUID" -ne 0 ]; then
    fail "This script must be run as root (sudo)."
  fi
  local missing=() cmd
  for cmd in parted sfdisk e2fsck cryptsetup clevis jq curl lsinitramfs findmnt \
             lsblk blkid blockdev partprobe chroot mktemp mount umount mountpoint \
             sync sha256sum cmp od awk sed grep; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "Missing host tools: ${missing[*]} (Debian/Ubuntu: parted fdisk e2fsprogs cryptsetup-bin clevis jq curl initramfs-tools-core util-linux coreutils)"
  fi
  if [ "$ARCH_HOST" != "aarch64" ]; then
    _check_binfmt_aarch64
  else
    info "  Host is aarch64, no emulation needed"
  fi
  ok "Host tools and emulation available"
}

_offline_check_device() {
  info "Preflight: device ${OFFLINE_DEVICE}"
  local dev name type rm tran pttype mnts bad_types rootsrc suffix
  [ -b "$OFFLINE_DEVICE" ] || fail "$OFFLINE_DEVICE is not a block device"
  dev=$(readlink -f "$OFFLINE_DEVICE")
  [ -b "$dev" ] || fail "$dev is not a block device"
  OFFLINE_DEVICE="$dev"
  name=$(basename "$dev")

  type=$(lsblk -dnro TYPE "$dev" | head -n 1)
  if [ "$type" = "loop" ]; then
    [ "$ALLOW_LOOP" = true ] || fail "$dev is a loop device. Loop devices are accepted for tests only: add --allow-loop"
    [[ "$dev" =~ ^/dev/loop[0-9]+$ ]] || fail "Unsupported loop device name: $dev"
    warn "Loop device accepted (--allow-loop, test only)"
  else
    [ "$type" = "disk" ] || fail "$dev is of type '${type}', expected a whole disk (not a partition)"
    rm=$(lsblk -dnro RM "$dev" | head -n 1)
    tran=$(lsblk -dnro TRAN "$dev" | head -n 1)
    if [ "$rm" != "1" ] && [ "$tran" != "usb" ] && [[ "$name" != mmcblk* ]]; then
      fail "$dev is neither removable nor USB/MMC attached (RM=${rm:-?}, TRAN=${tran:-none}). Refusing to touch a fixed disk."
    fi
  fi

  # Not mounted, not in use by the running system
  mnts=$(lsblk -nro MOUNTPOINT "$dev" | grep -v '^$' || true)
  if [ -n "$mnts" ]; then
    fail "$dev (or a partition on it) is mounted or used as swap: $(tr '\n' ' ' <<<"$mnts")- unmount it first"
  fi
  rootsrc=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [ -b "$rootsrc" ] && lsblk -nrso NAME "$rootsrc" 2>/dev/null | grep -qx "$name"; then
    fail "$dev carries the running root filesystem"
  fi
  bad_types=$(lsblk -nro TYPE "$dev" | grep -vxE 'disk|part|loop' || true)
  if [ -n "$bad_types" ]; then
    fail "$dev has device-mapper/RAID children ($(tr '\n' ' ' <<<"$bad_types")): the card looks encrypted or in use already"
  fi

  # Partition table: MBR, exactly two partitions
  pttype=$(lsblk -dnro PTTYPE "$dev" | head -n 1)
  [ "$pttype" = "dos" ] || fail "$dev has partition table type '${pttype:-none}', expected 'dos' (MBR) as written by Raspberry Pi Imager"
  local nparts
  nparts=$(lsblk -nro TYPE "$dev" | grep -cx part || true)
  [ "$nparts" -eq 2 ] || fail "$dev has ${nparts} partitions, expected exactly 2 (bootfs + rootfs)"
  if [[ "$name" =~ [0-9]$ ]]; then suffix="p"; else suffix=""; fi
  OFFLINE_P1="${dev}${suffix}1"
  OFFLINE_P2="${dev}${suffix}2"
  [ -b "$OFFLINE_P1" ] || fail "Partition $OFFLINE_P1 not found (loop devices need: losetup -P)"
  [ -b "$OFFLINE_P2" ] || fail "Partition $OFFLINE_P2 not found (loop devices need: losetup -P)"

  local fs1 fs2 l1 l2
  fs1=$(blkid -p -s TYPE -o value "$OFFLINE_P1" 2>/dev/null || true)
  fs2=$(blkid -p -s TYPE -o value "$OFFLINE_P2" 2>/dev/null || true)
  [ "$fs1" = "vfat" ] || fail "$OFFLINE_P1 is '${fs1:-unknown}', expected vfat (bootfs)"
  [ "$fs2" = "ext4" ] || fail "$OFFLINE_P2 is '${fs2:-unknown}', expected ext4 (rootfs)"
  l1=$(blkid -p -s LABEL -o value "$OFFLINE_P1" 2>/dev/null || true)
  l2=$(blkid -p -s LABEL -o value "$OFFLINE_P2" 2>/dev/null || true)
  [ "$l1" = "bootfs" ] || warn "$OFFLINE_P1 has label '${l1}', Raspberry Pi OS images use 'bootfs'"
  [ "$l2" = "rootfs" ] || warn "$OFFLINE_P2 has label '${l2}', Raspberry Pi OS images use 'rootfs'"

  # Partition 2 must not be grown yet
  local start size total free
  start=$(cat "/sys/class/block/$(basename "$OFFLINE_P2")/start")
  size=$(cat "/sys/class/block/$(basename "$OFFLINE_P2")/size")
  total=$(cat "/sys/class/block/${name}/size")
  free=$((total - start - size))
  if [ "$free" -lt "$MIN_FREE_AFTER_P2_SECTORS" ]; then
    fail "Partition 2 already reaches the end of the card (only $((free / 2048)) MiB free behind it): it was grown by a first boot already, or the card is not larger than the image"
  fi
  info "  $((free / 2048)) MiB free behind partition 2 (not grown yet)"

  info "  Checking the root filesystem of $OFFLINE_P2 (read-only fsck)..."
  local fsck_out
  if ! fsck_out=$(e2fsck -fn "$OFFLINE_P2" 2>&1); then
    tail -n 15 <<<"$fsck_out"
    fail "e2fsck reports errors on $OFFLINE_P2: refusing to continue"
  fi
  ok "Device ${dev}: ${OFFLINE_P1} (vfat), ${OFFLINE_P2} (ext4)"
}

# Check that a mounted card root is a Trixie style image that never booted.
# Usage: _image_checks <root> pre|post
#   pre : before our changes (cmdline.txt must still carry " resize")
#   post: after our changes (no " resize", new disk ID everywhere)
# Prints every violation and returns 1 if there is any.
_image_checks() {
  local root="$1" mode="$2" boot="$1/boot/firmware" bad=0
  local cmdfile="$boot/cmdline.txt" cmdline f arch

  if [ ! -f "$cmdfile" ]; then
    soft_fail "/boot/firmware/cmdline.txt is missing"
    bad=1
  else
    cmdline=$(cat "$cmdfile")
    if [[ "$cmdline" == *"init=/usr/lib/raspberrypi-sys-mods/firstboot"* ]]; then
      soft_fail "cmdline.txt uses init=/usr/lib/raspberrypi-sys-mods/firstboot: this is a Bookworm style image, the first-boot mechanism differs and is not supported"
      bad=1
    fi
    if [ "$mode" = "pre" ]; then
      if [[ " $cmdline " != *" resize "* ]]; then
        soft_fail "cmdline.txt has no ' resize' parameter: the image was booted already or is not a stock Raspberry Pi OS image"
        bad=1
      fi
    else
      if [[ " $cmdline " == *" resize "* ]]; then
        soft_fail "cmdline.txt still contains ' resize'"
        bad=1
      fi
    fi
    if [[ "$cmdline" != *"ds=nocloud;i="* ]]; then
      soft_fail "cmdline.txt has no 'ds=nocloud;i=' (cloud-init instance ID lost or not an Imager 2.x image)"
      bad=1
    fi
    if [ "$mode" = "post" ] && [ -n "$NEW_DISK_ID" ]; then
      if ! grep -qiE "PARTUUID=${NEW_DISK_ID}-02" <<<"$cmdline"; then
        soft_fail "cmdline.txt does not reference the new disk ID (PARTUUID=${NEW_DISK_ID}-02)"
        bad=1
      fi
      if grep -qi "PARTUUID=${OLD_DISK_ID}" "$cmdfile" "$root/etc/fstab"; then
        soft_fail "The old disk ID ${OLD_DISK_ID} is still referenced in cmdline.txt or fstab"
        bad=1
      fi
      if ! grep -qiE "PARTUUID=${NEW_DISK_ID}-0[12]" "$root/etc/fstab"; then
        soft_fail "fstab does not reference the new disk ID ${NEW_DISK_ID}"
        bad=1
      fi
    fi
  fi

  if [ "$(cat "$root/etc/machine-id" 2>/dev/null || true)" != "uninitialized" ]; then
    soft_fail "/etc/machine-id is not 'uninitialized': the image was booted (or the first-boot state was damaged)"
    bad=1
  fi
  if compgen -G "$root/etc/ssh/ssh_host_*" >/dev/null; then
    soft_fail "SSH host keys exist in /etc/ssh: the image was booted (or a package created them)"
    bad=1
  fi
  if [ -e "$root/var/lib/cloud/instance" ] || [ -L "$root/var/lib/cloud/instance" ]; then
    soft_fail "/var/lib/cloud/instance exists: cloud-init has run already"
    bad=1
  fi
  for f in user-data meta-data; do
    if [ ! -f "$boot/$f" ]; then
      soft_fail "/boot/firmware/$f is missing: the Imager 2.x customisation was not applied, the Pi would be unreachable later"
      bad=1
    fi
  done
  if [ -e "$root/usr/sbin/policy-rc.d" ] || [ -L "$root/usr/sbin/policy-rc.d" ]; then
    soft_fail "/usr/sbin/policy-rc.d exists"
    bad=1
  fi
  if [ -e "$root/usr/bin/qemu-aarch64-static" ] || [ -L "$root/usr/bin/qemu-aarch64-static" ]; then
    soft_fail "/usr/bin/qemu-aarch64-static exists in the card"
    bad=1
  fi
  if [ "$mode" = "pre" ]; then
    if [ -f "$root/usr/bin/dpkg" ]; then
      arch=$(od -An -tx1 -j18 -N2 "$root/usr/bin/dpkg" | tr -d ' \n')
      if [ "$arch" != "b700" ]; then
        soft_fail "The card is not an aarch64 image (ELF machine ${arch}); only 64-bit Raspberry Pi OS is supported"
        bad=1
      fi
    else
      soft_fail "/usr/bin/dpkg is missing: this is not a Debian based root filesystem"
      bad=1
    fi
  fi
  return "$bad"
}

# Mount the card read-only in a scratch directory and run the "never booted" checks
_offline_check_image_ro() {
  info "Preflight: image checks (read-only mount)"
  local probe rc=0
  probe=$(mktemp -d /tmp/luks-prepare-probe.XXXXXX)
  OFFLINE_MNT="$probe"
  _off_mount -o ro,noload "$OFFLINE_P2" "$probe"
  [ -d "$probe/boot/firmware" ] || fail "$OFFLINE_P2 has no /boot/firmware directory: not a Raspberry Pi OS Trixie root filesystem"
  _off_mount -o ro "$OFFLINE_P1" "$probe/boot/firmware"
  _image_checks "$probe" pre || rc=1
  _off_umount_all
  rmdir "$probe"
  OFFLINE_MNT=""
  [ "$rc" -eq 0 ] || fail "The card is not a pristine, never booted Raspberry Pi OS Trixie image (see above). Nothing was changed."
  ok "Image looks pristine (never booted)"
}

_offline_confirm() {
  echo ""
  echo -e "${YELLOW}Offline mode will:${NC}"
  echo "  - Grow partition 2 to the end of the card and give the card a new random disk ID"
  echo "  - Install cryptsetup, clevis/tang and related packages in an aarch64 chroot"
  echo "  - Configure the initramfs (crypto modules, Ethernet driver, hooks) and rebuild it"
  echo "  - Stage boot configuration files in $STAGED_DIR on the card"
  echo "  - Keep the first-boot state (machine-id, SSH keys, cloud-init) intact"
  echo ""
  echo -e "  Card:            ${YELLOW}${OFFLINE_DEVICE}${NC} (boot ${OFFLINE_P1}, root ${OFFLINE_P2})"
  echo -e "  Board:           ${YELLOW}${BOARD_ARG}${NC}"
  echo -e "  Network:         ${YELLOW}${IFACE}${NC} (drivers: ${NET_DRIVERS[*]})"
  echo -e "  Tang servers:    ${YELLOW}${TANG_SERVERS[0]}${NC}, ${YELLOW}${TANG_SERVERS[1]}${NC}"
  echo -e "  Root device:     ${YELLOW}${ROOT_DEV}${NC}"
  echo ""
  _ask_confirm "Continue? [y/N] " "--yes" || { echo "Aborted."; exit 0; }
}

# --- Phase: partition ---

_offline_partition() {
  echo ""
  info "Phase: partition (grow partition 2, new disk ID)"
  local dev="$OFFLINE_DEVICE" ss bytes total end cur_end got

  OLD_DISK_ID=$(sfdisk --disk-id "$dev")
  OLD_DISK_ID="${OLD_DISK_ID#0x}"
  OLD_DISK_ID="${OLD_DISK_ID,,}"
  [[ "$OLD_DISK_ID" =~ ^[0-9a-f]{8}$ ]] || fail "Could not read the disk ID of $dev (got '${OLD_DISK_ID}')"

  ss=$(blockdev --getss "$dev")
  bytes=$(blockdev --getsize64 "$dev")
  total=$((bytes / ss))
  end=$((total - 1))
  if [ "$end" -gt "$MAX_MBR_SECTOR" ]; then
    end="$MAX_MBR_SECTOR"
  fi
  info "  Growing partition 2 to sector $end (of $total)"
  parted -s "$dev" unit s resizepart 2 "${end}s"

  while :; do
    NEW_DISK_ID=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')
    if [ "$NEW_DISK_ID" != "00000000" ] && [ "$NEW_DISK_ID" != "$OLD_DISK_ID" ]; then
      break
    fi
  done
  info "  Disk ID: 0x${OLD_DISK_ID} -> 0x${NEW_DISK_ID}"
  sfdisk --disk-id "$dev" "0x${NEW_DISK_ID}"

  partprobe "$dev"
  sleep "$PARTPROBE_DELAY"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi

  got=$(sfdisk --disk-id "$dev")
  got="${got#0x}"
  [ "${got,,}" = "$NEW_DISK_ID" ] || fail "Disk ID of $dev is ${got}, expected ${NEW_DISK_ID}"
  cur_end=$(parted -sm "$dev" unit s print | awk -F: '$1 == "2" {print $3}')
  [ "$cur_end" = "${end}s" ] || fail "Partition 2 ends at ${cur_end}, expected ${end}s"
  [ -b "$OFFLINE_P1" ] && [ -b "$OFFLINE_P2" ] || fail "Partition nodes vanished after partprobe"
  ok "Partition 2 grown to the end of the card, new disk ID 0x${NEW_DISK_ID}"
}

# --- Phase: chroot ---

_offline_mount() {
  echo ""
  info "Phase: chroot (mount card, bind /dev /dev/pts /proc /sys)"
  OFFLINE_MNT=$(mktemp -d /tmp/luks-prepare-target.XXXXXX)
  _off_mount "$OFFLINE_P2" "$OFFLINE_MNT"
  [ -d "$OFFLINE_MNT/boot/firmware" ] || fail "No /boot/firmware directory on $OFFLINE_P2"
  _off_mount "$OFFLINE_P1" "$OFFLINE_MNT/boot/firmware"
  TARGET_ROOT="$OFFLINE_MNT"
  _off_mount --bind /dev "$TARGET_ROOT/dev"
  _off_mount --bind /dev/pts "$TARGET_ROOT/dev/pts"
  _off_mount --bind /proc "$TARGET_ROOT/proc"
  _off_mount --bind /sys "$TARGET_ROOT/sys"
  info "  Card mounted at $TARGET_ROOT"
}

# Save one path (file, symlink or absent) of the target. Usage: _state_save <path inside card> <slot>
_state_save() {
  local p="${TARGET_ROOT}$1" slot="${OFFLINE_STATE_DIR}/$2"
  if [ -L "$p" ]; then
    echo link > "$slot.kind"
    cp -a "$p" "$slot"
  elif [ -e "$p" ]; then
    echo file > "$slot.kind"
    cp -a "$p" "$slot"
  else
    echo absent > "$slot.kind"
  fi
}

# Put a saved path back exactly. Usage: _state_restore <path inside card> <slot>
_state_restore() {
  local p="${TARGET_ROOT}$1" slot="${OFFLINE_STATE_DIR}/$2" kind
  kind=$(cat "$slot.kind")
  rm -f "$p"
  if [ "$kind" != "absent" ]; then
    cp -a "$slot" "$p"
  fi
}

# Compare the current path with the saved one. Usage: _state_same <path inside card> <slot>
_state_same() {
  local p="${TARGET_ROOT}$1" slot="${OFFLINE_STATE_DIR}/$2" kind now
  kind=$(cat "$slot.kind")
  if [ -L "$p" ]; then now="link"; elif [ -e "$p" ]; then now="file"; else now="absent"; fi
  [ "$kind" = "$now" ] || return 1
  case "$kind" in
    link) [ "$(readlink "$p")" = "$(readlink "$slot")" ] ;;
    file) cmp -s "$p" "$slot" && [ "$(stat -c '%a %u %g' "$p")" = "$(stat -c '%a %u %g' "$slot")" ] ;;
    *)    return 0 ;;
  esac
}

# Listing of /var/lib/cloud (empty when absent) for the before/after comparison
_cloud_listing() {
  if [ -d "${TARGET_ROOT}/var/lib/cloud" ]; then
    echo present
    find "${TARGET_ROOT}/var/lib/cloud" -printf '%P %y\n' | sort
  else
    echo absent
  fi
}

_offline_save_state() {
  info "Saving the first-boot state of the card"
  OFFLINE_STATE_DIR=$(mktemp -d /tmp/luks-prepare-state.XXXXXX)
  [ -f "$TARGET_ROOT/etc/machine-id" ] || fail "No /etc/machine-id on the card"
  _state_save /etc/machine-id machine-id
  _state_save /var/lib/dbus/machine-id dbus-machine-id
  _state_save /etc/resolv.conf resolv.conf
  _cloud_listing > "$OFFLINE_STATE_DIR/cloud.list"
  OFFLINE_STATE_SAVED=true
  ok "First-boot state saved (machine-id, dbus machine-id, resolv.conf, cloud-init dir)"
}

# Rewrite the old disk ID in fstab and cmdline.txt and drop ' resize' (like the initramfs set_partuuid does)
_offline_rewrite_bootconfig() {
  info "Rewriting fstab and cmdline.txt (new disk ID, no ' resize')"
  local cmd="$TARGET_ROOT/boot/firmware/cmdline.txt" fst="$TARGET_ROOT/etc/fstab"
  local n_fstab n_cmd ds_before ds_after

  [ -f "$fst" ] || fail "No /etc/fstab on the card"
  n_fstab=$(grep -ciE "PARTUUID=${OLD_DISK_ID}-0[12]" "$fst" || true)
  n_cmd=$(grep -ciE "PARTUUID=${OLD_DISK_ID}-0[12]" "$cmd" || true)
  [ "$n_fstab" -gt 0 ] || warn "fstab does not reference PARTUUID=${OLD_DISK_ID}-0x"
  [ "$n_cmd" -gt 0 ] || warn "cmdline.txt does not reference PARTUUID=${OLD_DISK_ID}-0x"

  ds_before=$(grep -o 'ds=nocloud;i=[^ ]*' "$cmd" || true)
  sed -i -E "s/PARTUUID=${OLD_DISK_ID}-0([12])/PARTUUID=${NEW_DISK_ID}-0\1/Ig" "$fst" "$cmd"
  sed -i -E -e 's/ resize( |$)/\1/g' -e 's/^resize( |$)//' "$cmd"

  ds_after=$(grep -o 'ds=nocloud;i=[^ ]*' "$cmd" || true)
  [ -n "$ds_before" ] && [ "$ds_before" = "$ds_after" ] || fail "The cloud-init parameter 'ds=nocloud;i=...' was lost while rewriting cmdline.txt"
  if grep -qiE "PARTUUID=${OLD_DISK_ID}" "$fst" "$cmd"; then
    fail "The old disk ID is still referenced after the rewrite"
  fi
  if [[ " $(cat "$cmd") " == *" resize "* ]]; then
    fail "' resize' is still in cmdline.txt after the rewrite"
  fi
  info "  cmdline.txt: $(cat "$cmd")"
  ok "fstab and cmdline.txt rewritten"
}

_offline_chroot_prepare() {
  info "Preparing the chroot (resolv.conf, policy-rc.d, qemu)"
  local q QEMU_BIN=""

  # Temporary resolver for apt. The saved original is put back by the restore phase.
  rm -f "$TARGET_ROOT/etc/resolv.conf"
  if [ -s /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "$TARGET_ROOT/etc/resolv.conf"
  elif [ -s /run/systemd/resolve/resolv.conf ]; then
    cp -L /run/systemd/resolve/resolv.conf "$TARGET_ROOT/etc/resolv.conf"
  else
    fail "The host has no usable /etc/resolv.conf, apt in the chroot could not resolve names"
  fi

  # No service may start inside the chroot
  POLICY_CREATED=true
  printf '#!/bin/sh\nexit 101\n' > "$TARGET_ROOT/usr/sbin/policy-rc.d"
  chmod 755 "$TARGET_ROOT/usr/sbin/policy-rc.d"

  # aarch64 target on a non-aarch64 host: same handling as luks_encrypt.sh
  if [ "$(uname -m)" != "aarch64" ]; then
    for q in /usr/bin/qemu-aarch64-static /usr/bin/qemu-aarch64; do
      if [ -f "$q" ]; then QEMU_BIN="$q"; break; fi
    done
    if [ -z "$QEMU_BIN" ] && [ -f "$BINFMT_INTERP" ]; then
      QEMU_BIN="$BINFMT_INTERP"
    fi
    if [ -n "$QEMU_BIN" ]; then
      QEMU_COPIED=true
      cp "$QEMU_BIN" "$TARGET_ROOT/usr/bin/qemu-aarch64-static"
      info "  Copied $QEMU_BIN for cross-arch chroot"
    else
      warn "No qemu-aarch64 binary found. The chroot relies on the binfmt_misc F flag alone."
    fi
  fi

  if ! _in_target /bin/true; then
    fail "A test command does not run inside the aarch64 chroot (check qemu-user-static and binfmt_misc)"
  fi
  ok "Chroot ready"
}

# --- Target storage health (card reader resets, I/O errors) ---

_remember_target_knames() {
  local name
  [ -n "${OFFLINE_DEVICE:-}" ] && [ -b "$OFFLINE_DEVICE" ] || return 0
  for name in $(lsblk -nlo KNAME "$OFFLINE_DEVICE" 2>/dev/null); do
    case " $TARGET_KNAMES " in
      *" $name "*) ;;
      *) TARGET_KNAMES="${TARGET_KNAMES:+$TARGET_KNAMES }$name" ;;
    esac
  done
}

# Kernel messages since this script started (dmesg ring buffer as fallback)
_kernel_log_since_start() {
  if command -v journalctl >/dev/null 2>&1 \
     && journalctl -k -q --no-pager --since "@${SCRIPT_START_EPOCH}" 2>/dev/null; then
    return 0
  fi
  dmesg 2>/dev/null || true
}

# Fail hard on any sign of trouble on the card: writeback errors, read-only remount,
# I/O, ext4 or jbd2 errors in the kernel log.
# Usage: _check_target_health "<context>"
_check_target_health() {
  local context="$1" mnt names_re hits
  _remember_target_knames

  for mnt in "${OFFLINE_MNT:-}" "${OFFLINE_MNT:+$OFFLINE_MNT/boot/firmware}"; do
    [ -n "$mnt" ] && mountpoint -q "$mnt" 2>/dev/null || continue
    if ! sync -f "$mnt"; then
      fail "${context}: writeback to ${mnt} failed. The card reported write errors; the written data cannot be trusted."
    fi
    if findmnt -no OPTIONS "$mnt" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
      fail "${context}: ${mnt} is read-only now. The kernel remounted it after an error on the card."
    fi
  done

  [ -n "$TARGET_KNAMES" ] || return 0
  names_re=$(tr ' ' '|' <<<"$TARGET_KNAMES")
  hits=$(_kernel_log_since_start \
    | grep -E "\\b(${names_re})\\b" \
    | grep -iE 'I/O error|EXT4-fs (error|warning)|Aborting journal|JBD2|read-only|offline|FAILED Result' \
    || true)
  if [ -n "$hits" ]; then
    echo -e "${RED}[FAIL]${NC} Kernel log errors on the card (${TARGET_KNAMES}):" >&2
    head -n 20 <<<"$hits" >&2
    fail "${context}: the card had I/O errors during this run (card reader / USB reset?). Do not boot this card. Re-run on a reliable reader (directly on the host, no hub)."
  fi
}

# --- Phase: initramfs verification ---

_offline_initramfs_images() {
  find "$TARGET_ROOT/boot/firmware" -maxdepth 1 -type f -name 'initramfs*' | sort
}

# Is a module (.ko, optionally compressed) in the initramfs listing? Usage: <listing> <module>
_module_in_listing() {
  local pat="${2//[-_]/[-_]}"
  grep -Eq "(^|/)${pat}\.ko(\.[a-z0-9]+)?$" <<<"$1"
}

# Is a kernel module in the initramfs listing, or built into that kernel? Usage: <listing> <kernel version> <module>
_module_available() {
  local listing="$1" ver="$2" mod="$3"
  if _module_in_listing "$listing" "$mod"; then
    return 0
  fi
  [ -n "$ver" ] && _module_in_index "$TARGET_ROOT/lib/modules/$ver/modules.builtin" "$mod" builtin
}

# Is a module name listed in a kernel index file? Usage: <file> <module> <kind: builtin|dep>
# modules.builtin has one path per line; modules.dep has "path: dependencies", only the path counts.
_module_in_index() {
  local file="$1" mod="$2" kind="$3" pat
  pat="${mod//[-_]/[-_]}"
  [ -f "$file" ] || return 1
  if [ "$kind" = "builtin" ]; then
    grep -Eq "(^|/)${pat}\.ko$" "$file"
  else
    grep -Eq "^([^:]*/)?${pat}\.ko(\.[a-z0-9]+)?:" "$file"
  fi
}

# Verify every initramfs image: clevis, cryptsetup, dm-crypt and the Ethernet driver(s).
# Driver rule, from the target's kernel tree (kernel version read from the image listing): builtin
# in modules.builtin counts as present; listed in modules.dep it must be inside the image as a
# module, else fatal; listed in neither: this kernel has no such driver, warn only. At least one
# driver of NET_DRIVERS must be present per image.
# cryptroot/crypttab is reported but not required here: it only exists once /etc/crypttab has
# entries, which luks_encrypt.sh writes (and rebuilds the initramfs) later.
# Usage: _offline_verify_initramfs "<sha256sum output before the rebuild>"
_offline_verify_initramfs() {
  local pre_sums="$1" img name listing pre_sum ver drv present kdir bad=0 ibad
  local images=()
  mapfile -t images < <(_offline_initramfs_images)
  if [ "${#images[@]}" -eq 0 ]; then
    soft_fail "No initramfs image found in /boot/firmware"
    return 1
  fi
  for img in "${images[@]}"; do
    name=$(basename "$img")
    ibad=0
    if [ -n "$pre_sums" ]; then
      pre_sum=$(awk -v p="$img" '$2 == p {print $1}' <<<"$pre_sums")
      if [ -n "$pre_sum" ] && [ "$pre_sum" = "$(sha256sum "$img" | cut -d' ' -f1)" ]; then
        soft_fail "${name}: unchanged, it was NOT rebuilt in this run"
        bad=1
        continue
      fi
    fi
    if ! listing=$(lsinitramfs "$img" 2>&1); then
      soft_fail "${name}: cannot list its contents"
      bad=1
      continue
    fi
    ver=$(awk -F/ '{ for (i = 2; i < NF; i++) if ($i == "modules" && $(i-1) == "lib") { print $(i+1); exit } }' <<<"$listing")

    if ! grep -Eq '(^|/)bin/clevis$' <<<"$listing"; then
      soft_fail "${name}: no clevis binary inside, no tang auto-unlock"
      ibad=1
    fi
    if ! grep -Eq '(^|/)s?bin/cryptsetup$' <<<"$listing"; then
      soft_fail "${name}: no cryptsetup binary inside"
      ibad=1
    fi
    if ! _module_available "$listing" "$ver" dm-crypt; then
      soft_fail "${name}: dm-crypt module missing (kernel ${ver:-unknown})"
      ibad=1
    fi

    present=0
    kdir="$TARGET_ROOT/lib/modules/${ver}"
    if [ -z "$ver" ] || [ ! -f "$kdir/modules.dep" ]; then
      soft_fail "${name}: cannot read the kernel tree of '${ver:-unknown}' (${kdir}/modules.dep), cannot judge the network drivers"
      ibad=1
    else
      for drv in "${NET_DRIVERS[@]}"; do
        if _module_in_index "$kdir/modules.builtin" "$drv" builtin; then
          info "  ${name}: ${drv} is built into kernel ${ver}"
          present=$((present + 1))
        elif _module_in_index "$kdir/modules.dep" "$drv" dep; then
          if _module_in_listing "$listing" "$drv"; then
            present=$((present + 1))
          else
            soft_fail "${name}: network driver '${drv}' is a module of kernel ${ver} but missing in the image, no network in the initramfs"
            ibad=1
          fi
        else
          warn "${name}: kernel ${ver} has no network driver '${drv}', not expected in this image"
        fi
      done
      if [ "$present" -eq 0 ]; then
        soft_fail "${name}: none of the network drivers (${NET_DRIVERS[*]}) is present for kernel ${ver}"
        ibad=1
      fi
    fi

    if grep -q 'cryptroot/crypttab' <<<"$listing"; then
      info "  ${name}: cryptroot/crypttab present"
    else
      info "  ${name}: no cryptroot/crypttab yet (expected: /etc/crypttab gets its entry in luks_encrypt.sh)"
    fi
    if [ "$ibad" -ne 0 ]; then bad=1; fi
    if [ "$ibad" -eq 0 ]; then
      ok "${name}: clevis, cryptsetup, dm-crypt and ${present} network driver(s) present (kernel ${ver:-unknown})"
    fi
  done
  return "$bad"
}

# --- Phase: restore ---

# Put the first-boot state back and verify it. Idempotent. Returns 1 if the verification fails.
_restore_first_boot_state() {
  [ "$OFFLINE_STATE_SAVED" = true ] || return 0
  OFFLINE_STATE_RESTORED=true
  local rc=0 f
  info "Restoring the first-boot state of the card..."
  if [ -z "$TARGET_ROOT" ] || ! mountpoint -q "$TARGET_ROOT" 2>/dev/null; then
    soft_fail "The card root is not mounted, the first-boot state cannot be restored"
    OFFLINE_RESTORE_FAILED=true
    return 1
  fi

  if [ "$POLICY_CREATED" = true ]; then rm -f "$TARGET_ROOT/usr/sbin/policy-rc.d"; fi
  if [ "$QEMU_COPIED" = true ]; then rm -f "$TARGET_ROOT/usr/bin/qemu-aarch64-static"; fi
  _state_restore /etc/machine-id machine-id || rc=1
  _state_restore /var/lib/dbus/machine-id dbus-machine-id || rc=1
  _state_restore /etc/resolv.conf resolv.conf || rc=1
  if compgen -G "$TARGET_ROOT/etc/ssh/ssh_host_*" >/dev/null; then
    warn "SSH host keys were created in the chroot, removing them"
    for f in "$TARGET_ROOT"/etc/ssh/ssh_host_*; do rm -f "$f" || rc=1; done
  fi
  sync

  # Verification
  _state_same /etc/machine-id machine-id || { soft_fail "/etc/machine-id differs from the saved state"; rc=1; }
  _state_same /var/lib/dbus/machine-id dbus-machine-id || { soft_fail "/var/lib/dbus/machine-id differs from the saved state"; rc=1; }
  _state_same /etc/resolv.conf resolv.conf || { soft_fail "/etc/resolv.conf differs from the saved state"; rc=1; }
  if compgen -G "$TARGET_ROOT/etc/ssh/ssh_host_*" >/dev/null; then
    soft_fail "SSH host keys still exist"
    rc=1
  fi
  if [ "$(_cloud_listing)" != "$(cat "$OFFLINE_STATE_DIR/cloud.list")" ] || [ -e "$TARGET_ROOT/var/lib/cloud/instance" ]; then
    soft_fail "/var/lib/cloud changed: cloud-init ran (or was initialised) in the chroot"
    rc=1
  fi
  if [ -e "$TARGET_ROOT/usr/sbin/policy-rc.d" ] || [ -L "$TARGET_ROOT/usr/sbin/policy-rc.d" ]; then
    soft_fail "/usr/sbin/policy-rc.d still exists"
    rc=1
  fi
  if [ -e "$TARGET_ROOT/usr/bin/qemu-aarch64-static" ] || [ -L "$TARGET_ROOT/usr/bin/qemu-aarch64-static" ]; then
    soft_fail "/usr/bin/qemu-aarch64-static still exists"
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    OFFLINE_RESTORE_FAILED=true
    return 1
  fi
  ok "First-boot state restored and verified"
}

# Unmount everything and remove scratch directories. Idempotent.
_offline_teardown() {
  _off_umount_all
  if [ -n "$OFFLINE_MNT" ]; then
    rmdir "$OFFLINE_MNT" 2>/dev/null || true
  fi
  if [ -n "$OFFLINE_STATE_DIR" ] && [ -d "$OFFLINE_STATE_DIR" ]; then
    if [ "$OFFLINE_RESTORE_FAILED" = true ]; then
      echo "Saved first-boot state kept for inspection in: $OFFLINE_STATE_DIR"
    else
      rm -rf "$OFFLINE_STATE_DIR"
    fi
  fi
}

# EXIT trap: restore the first-boot state on every path, then unmount
_offline_on_exit() {
  local rc=$?
  set +e
  trap - EXIT INT TERM
  if [ "$OFFLINE_STATE_SAVED" = true ] && [ "$OFFLINE_STATE_RESTORED" != true ]; then
    echo ""
    _restore_first_boot_state || rc=1
  fi
  if [ "$OFFLINE_RESTORE_FAILED" = true ]; then rc=1; fi
  _offline_teardown
  if [ "$rc" -ne 0 ]; then
    echo -e "${RED}[FAIL]${NC} Offline preparation of ${OFFLINE_DEVICE} did not finish (exit code ${rc}). The card is NOT ready; do not boot it."
    if [ -n "$NEW_DISK_ID" ]; then
      echo "       The partition table was changed already. If in doubt, write the image to the card again."
    fi
  fi
  exit "$rc"
}

_offline_summary() {
  echo ""
  echo "================================================================="
  echo -e "${GREEN}Offline preparation complete!${NC}"
  echo "================================================================="
  echo ""
  echo "Card:               $OFFLINE_DEVICE (new disk ID 0x${NEW_DISK_ID}, partition 2 grown)"
  echo "Staged files are in: $STAGED_DIR (on the card)"
  echo "First-boot state:    restored and verified (the card still counts as never booted)"
  echo ""
  echo -e "${YELLOW}Next step:${NC} encrypt the card on this workstation"
  echo ""
  echo -e "     ${CYAN}sudo ./luks_encrypt.sh --device=${OFFLINE_DEVICE}${NC}"
  echo ""
  echo "  Non-interactive:"
  echo ""
  echo -e "     ${CYAN}sudo ./luks_encrypt.sh --device=${OFFLINE_DEVICE} --yes --passphrase-file=/path/to/pass --tang=${TANG_SERVERS[0]},${TANG_SERVERS[1]} --keep-backup${NC}"
  echo ""
  echo "  (the script is also on the card at: /root/luks-staged/luks_encrypt.sh)"
  echo "  Do not boot the card before the encryption has finished."
  echo ""
}

offline_main() {
  trap _offline_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export LC_ALL=C
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

  # Board facts for the shared steps: no detection, everything comes from the arguments
  BOARD_TYPE="rpi"
  BOOT_DIR="/boot/firmware"
  BOOT_FS="vfat"
  SCENARIO="rpi_offline"
  CURRENT_ROOT_DISK=""
  DEVICE="/dev/mmcblk0"             # Paths as seen on the Pi, not on this host
  BOOT_PART="${DEVICE}p1"
  ROOT_PART="${DEVICE}p2"
  IFACE="$IFACE_ARG"
  read -ra NET_DRIVERS <<<"$(board_net_drivers "$BOARD_ARG")"

  echo ""
  echo "================================================================="
  echo -e "${YELLOW}Offline LUKS preparation (never booted Raspberry Pi OS card)${NC}"
  echo "================================================================="
  echo ""

  # Phase: preflight
  info "Phase: preflight"
  _offline_check_host
  _prompt_tang_servers
  _offline_check_device
  _offline_check_image_ro
  _offline_confirm

  # Phase: partition
  _offline_partition

  # Phase: chroot
  _offline_mount
  _offline_save_state
  _offline_rewrite_bootconfig
  _offline_chroot_prepare

  # Phase: packages
  echo ""
  info "Phase: packages (inside the chroot)"
  install_packages
  _check_target_health "Phase packages"

  # Phase: configure (the staged cmdline.txt is written here, after the partition phase)
  echo ""
  info "Phase: configure"
  configure_modules
  create_hooks
  configure_networking
  create_postinst_hook
  stage_boot_files
  show_staged_files
  _check_target_health "Phase configure"

  # Phase: initramfs
  echo ""
  info "Phase: initramfs"
  local pre_sums
  pre_sums=$(_offline_initramfs_images | xargs -r -d '\n' sha256sum)
  if ! rebuild_initramfs; then
    # A storage error is the more fundamental cause; report it first if present.
    _check_target_health "Phase initramfs"
    fail "Initramfs rebuild in the chroot failed (see the update-initramfs output above): the card would not boot."
  fi
  _check_target_health "Phase initramfs"
  info "Verifying the rebuilt initramfs images..."
  if ! _offline_verify_initramfs "$pre_sums"; then
    fail "Initramfs verification failed (see above): the card would not unlock at boot."
  fi

  # Phase: restore
  echo ""
  info "Phase: restore"
  if ! _restore_first_boot_state; then
    fail "The first-boot state could not be restored and verified (see above): do not boot this card."
  fi
  info "Re-running the image checks..."
  if ! _image_checks "$TARGET_ROOT" post; then
    fail "Image checks failed after the run (see above): do not boot this card."
  fi
  ok "Image checks passed"
  _check_target_health "Phase restore"
  _offline_teardown
  verify_tang_connectivity
  _offline_summary
}

if [ "$OFFLINE_REQUESTED" = true ]; then
  offline_main
  exit 0
fi

# =====================================================================
# 1. Safety checks
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  fail "This script must be run as root (sudo)."
fi

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  warn "Expected aarch64 architecture, got: $ARCH"
  _ask_confirm "Continue anyway? [y/N] " "--yes" || exit 0
fi

_prompt_tang_servers

info "Detecting board model..."
if [ -f /proc/device-tree/model ]; then
  BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
  info "Model: $BOARD_MODEL"
else
  warn "Could not detect board model (no /proc/device-tree/model)"
  BOARD_MODEL="Unknown"
fi

# =====================================================================
# 2. Board detection
# =====================================================================

BOARD_TYPE=""
BOOT_DIR=""
BOOT_FS=""
HAS_SEPARATE_BOOT=false

if [ -f /boot/armbianEnv.txt ]; then
  BOARD_TYPE="armbian"
  BOOT_DIR="/boot"
  BOOT_FS="ext4"
  info "Board type: Armbian (U-Boot)"
elif [ -f /boot/firmware/config.txt ]; then
  BOARD_TYPE="rpi"
  BOOT_DIR="/boot/firmware"
  BOOT_FS="vfat"
  info "Board type: Raspberry Pi"
else
  fail "Unsupported board (neither /boot/armbianEnv.txt nor /boot/firmware/config.txt found)"
fi

if mountpoint -q /boot 2>/dev/null; then
  HAS_SEPARATE_BOOT=true
  info "Separate /boot partition detected"
fi

# =====================================================================
# 3. Storage detection
# =====================================================================

DEVICE=""
BOOT_PART=""
ROOT_PART=""
SCENARIO=""          # "rpi", "nvme_migrate", "usb_migrate", "inplace"
CURRENT_ROOT_DISK="" # Armbian: disk the system currently boots from
USB_PARTITIONED=false

if [ "$BOARD_TYPE" = "rpi" ]; then
  # RPi: NVMe or SD auto-detect (existing logic)
  if [ -b /dev/nvme0n1 ]; then
    DEVICE="/dev/nvme0n1"
    BOOT_PART="${DEVICE}p1"
    ROOT_PART="${DEVICE}p2"
    info "Detected NVMe storage: $DEVICE"
  elif [ -b /dev/mmcblk0 ]; then
    DEVICE="/dev/mmcblk0"
    BOOT_PART="${DEVICE}p1"
    ROOT_PART="${DEVICE}p2"
    info "Detected SD card storage: $DEVICE"
  else
    fail "No supported storage device found (/dev/mmcblk0 or /dev/nvme0n1)"
  fi
  SCENARIO="rpi"

elif [ "$BOARD_TYPE" = "armbian" ]; then
  # Armbian: determine current root device and available targets
  CURRENT_ROOT_DEV=$(findmnt -n -o SOURCE /)
  CURRENT_ROOT_DISK="/dev/$(lsblk -n -o PKNAME "$CURRENT_ROOT_DEV" | head -1)"
  info "Current root device: $CURRENT_ROOT_DEV (disk: $CURRENT_ROOT_DISK)"

  # Check for NVMe
  NVME_FOUND=false
  NVME_PARTITIONED=false
  if [ -b /dev/nvme0n1 ]; then
    NVME_FOUND=true
    NVME_SIZE=$(lsblk -n -o SIZE -d /dev/nvme0n1 2>/dev/null | tr -d ' ')
    NVME_PART_COUNT=$(lsblk -n -o TYPE /dev/nvme0n1 2>/dev/null | grep -c part || true)
    if [ "$NVME_PART_COUNT" -eq 0 ]; then
      info "NVMe found (/dev/nvme0n1, ${NVME_SIZE}, unpartitioned)"
    else
      NVME_PARTITIONED=true
      info "NVMe found (/dev/nvme0n1, ${NVME_SIZE}, ${NVME_PART_COUNT} partitions)"
    fi
  fi

  # Check for USB storage devices
  USB_DEVICES=()
  USB_PARTITIONED_MAP=()
  while IFS= read -r line; do
    USB_DEV_NAME=$(echo "$line" | awk '{print $1}')
    USB_DEV="/dev/${USB_DEV_NAME}"
    # Skip if it's the current root disk
    [ "$USB_DEV" = "$CURRENT_ROOT_DISK" ] && continue
    USB_SIZE=$(lsblk -n -o SIZE -d "$USB_DEV" 2>/dev/null | tr -d ' ')
    USB_MODEL=$(lsblk -n -o MODEL -d "$USB_DEV" 2>/dev/null | sed 's/^ *//;s/ *$//')
    USB_PART_COUNT=$(lsblk -n -o TYPE "$USB_DEV" 2>/dev/null | grep -c part || true)
    USB_DEVICES+=("$USB_DEV")
    if [ "$USB_PART_COUNT" -eq 0 ]; then
      USB_PARTITIONED_MAP+=(false)
      info "USB found (${USB_DEV}, ${USB_SIZE}, ${USB_MODEL:-unknown model}, unpartitioned)"
    else
      USB_PARTITIONED_MAP+=(true)
      info "USB found (${USB_DEV}, ${USB_SIZE}, ${USB_MODEL:-unknown model}, ${USB_PART_COUNT} partitions)"
    fi
  done < <(lsblk -d -n -o NAME,TRAN 2>/dev/null | grep 'usb$' || true)

  # Build dynamic menu
  echo ""
  MENU_OPTIONS=()
  MENU_NUM=1
  if [ "$NVME_FOUND" = true ]; then
    echo -e "${YELLOW}Available migration targets:${NC}"
    echo "  ${MENU_NUM}) Migrate to NVMe (/dev/nvme0n1, ${NVME_SIZE})"
    MENU_OPTIONS+=("nvme")
    MENU_NUM=$((MENU_NUM + 1))
  fi
  for i in "${!USB_DEVICES[@]}"; do
    _USB_DEV="${USB_DEVICES[$i]}"
    _USB_SIZE=$(lsblk -n -o SIZE -d "$_USB_DEV" 2>/dev/null | tr -d ' ')
    _USB_MODEL=$(lsblk -n -o MODEL -d "$_USB_DEV" 2>/dev/null | sed 's/^ *//;s/ *$//')
    if [ "$MENU_NUM" -eq 1 ]; then
      echo -e "${YELLOW}Available migration targets:${NC}"
    fi
    echo "  ${MENU_NUM}) Migrate to USB (${_USB_DEV}, ${_USB_SIZE}, ${_USB_MODEL:-unknown})"
    MENU_OPTIONS+=("usb:$i")
    MENU_NUM=$((MENU_NUM + 1))
  done
  if [ "${#MENU_OPTIONS[@]}" -gt 0 ]; then
    echo "  ${MENU_NUM}) Encrypt current disk in-place (requires booting from another medium)"
  else
    echo -e "${YELLOW}No NVMe or USB storage found. Using in-place encryption.${NC}"
  fi
  MENU_OPTIONS+=("inplace")

  if [ "${#MENU_OPTIONS[@]}" -eq 1 ]; then
    # Only in-place available
    SCENARIO_CHOICE="inplace"
  else
    _need_terminal "The scenario menu (--yes cannot choose a scenario)"
    read -rp "Choice [1-${#MENU_OPTIONS[@]}]: " CHOICE_NUM
    if [[ "$CHOICE_NUM" =~ ^[0-9]+$ ]] && [ "$CHOICE_NUM" -ge 1 ] && [ "$CHOICE_NUM" -le "${#MENU_OPTIONS[@]}" ]; then
      SCENARIO_CHOICE="${MENU_OPTIONS[$((CHOICE_NUM - 1))]}"
    else
      echo "Invalid choice. Aborting."
      exit 1
    fi
  fi

  if [ "$SCENARIO_CHOICE" = "nvme" ]; then
    SCENARIO="nvme_migrate"
    DEVICE="/dev/nvme0n1"
  elif [[ "$SCENARIO_CHOICE" == usb:* ]]; then
    USB_IDX="${SCENARIO_CHOICE#usb:}"
    SCENARIO="usb_migrate"
    DEVICE="${USB_DEVICES[$USB_IDX]}"
    USB_PARTITIONED="${USB_PARTITIONED_MAP[$USB_IDX]}"
  else
    SCENARIO="inplace"
    DEVICE="$CURRENT_ROOT_DISK"
  fi
fi

info "Scenario: $SCENARIO"
info "Current partition layout:"
lsblk "$DEVICE"
echo ""

# =====================================================================
# 3b. NVMe partitioning (Armbian NVMe migration only)
# =====================================================================

if [ "$SCENARIO" = "nvme_migrate" ]; then
  BOOT_PART="${DEVICE}p1"
  ROOT_PART="${DEVICE}p2"

  if [ "$NVME_PARTITIONED" = true ] && [ -b "$BOOT_PART" ] && [ -b "$ROOT_PART" ]; then
    # NVMe already partitioned (likely from a previous run) - skip partitioning
    info "NVMe already partitioned - skipping partitioning and /boot copy"
    lsblk "$DEVICE"
    echo ""
  else
    echo ""
    echo -e "${RED}WARNING: This will ERASE all data on ${DEVICE}!${NC}"
    echo "  Partition 1: $((BOOT_PARTITION_SIZE_MB)) MB ext4 (/boot)"
    echo "  Partition 2: remainder (for LUKS+LVM)"
    echo ""
    _need_terminal "The partitioning confirmation for ${DEVICE} (--yes does not cover it)"
    read -rp "Type 'YES' to partition ${DEVICE}: " CONFIRM
    [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }

    info "Partitioning $DEVICE..."
    parted -s "$DEVICE" mklabel gpt
    parted -s "$DEVICE" mkpart boot ext4 1MiB "$((BOOT_PARTITION_SIZE_MB + 1))MiB"
    parted -s "$DEVICE" mkpart root ext4 "$((BOOT_PARTITION_SIZE_MB + 1))MiB" 100%

    # Wait for kernel to re-read partition table
    partprobe "$DEVICE"
    sleep $PARTPROBE_DELAY

    if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOT_PART" ]; then
      fail "Partitions not created: $BOOT_PART and/or $ROOT_PART not found"
    fi

    info "Creating ext4 filesystem on $BOOT_PART..."
    mkfs.ext4 -L "$BOOT_PARTITION_LABEL" "$BOOT_PART"

    info "Copying /boot to NVMe boot partition..."
    MOUNT_NEWBOOT=$(mktemp -d /tmp/luks-newboot.XXXXXX)
    mount "$BOOT_PART" "$MOUNT_NEWBOOT"
    rsync -aHAXx /boot/ "$MOUNT_NEWBOOT/"
    umount "$MOUNT_NEWBOOT"
    rmdir "$MOUNT_NEWBOOT"

    ok "NVMe partitioned and /boot copied"
    lsblk "$DEVICE"
    echo ""
  fi
fi

# =====================================================================
# 3c. USB partitioning (Armbian USB migration only)
# =====================================================================

if [ "$SCENARIO" = "usb_migrate" ]; then
  BOOT_PART="${DEVICE}1"
  ROOT_PART="${DEVICE}2"

  if [ "$USB_PARTITIONED" = true ] && [ -b "$BOOT_PART" ] && [ -b "$ROOT_PART" ]; then
    # USB already partitioned (likely from a previous run) - skip partitioning
    info "USB device already partitioned - skipping partitioning and /boot copy"
    lsblk "$DEVICE"
    echo ""
  else
    echo ""
    echo -e "${RED}WARNING: This will ERASE all data on ${DEVICE}!${NC}"
    echo "  Partition 1: $((BOOT_PARTITION_SIZE_MB)) MB ext4 (/boot)"
    echo "  Partition 2: remainder (for LUKS+LVM)"
    echo ""
    _need_terminal "The partitioning confirmation for ${DEVICE} (--yes does not cover it)"
    read -rp "Type 'YES' to partition ${DEVICE}: " CONFIRM
    [ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 0; }

    info "Partitioning $DEVICE..."
    parted -s "$DEVICE" mklabel gpt
    parted -s "$DEVICE" mkpart boot ext4 1MiB "$((BOOT_PARTITION_SIZE_MB + 1))MiB"
    parted -s "$DEVICE" mkpart root ext4 "$((BOOT_PARTITION_SIZE_MB + 1))MiB" 100%

    # Wait for kernel to re-read partition table
    partprobe "$DEVICE"
    sleep $PARTPROBE_DELAY

    if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOT_PART" ]; then
      fail "Partitions not created: $BOOT_PART and/or $ROOT_PART not found"
    fi

    info "Creating ext4 filesystem on $BOOT_PART..."
    mkfs.ext4 -L "$BOOT_PARTITION_LABEL" "$BOOT_PART"

    info "Copying /boot to USB boot partition..."
    MOUNT_NEWBOOT=$(mktemp -d /tmp/luks-newboot.XXXXXX)
    mount "$BOOT_PART" "$MOUNT_NEWBOOT"
    rsync -aHAXx /boot/ "$MOUNT_NEWBOOT/"
    umount "$MOUNT_NEWBOOT"
    rmdir "$MOUNT_NEWBOOT"

    ok "USB device partitioned and /boot copied"
    lsblk "$DEVICE"
    echo ""
  fi
fi

# =====================================================================
# 3d. In-place boot partition split (Armbian in-place only)
# =====================================================================

if [ "$SCENARIO" = "inplace" ] && [ "$HAS_SEPARATE_BOOT" = false ]; then
  echo ""
  fail "Armbian in-place encryption requires a separate /boot partition.

  The root filesystem cannot be shrunk online (ext4 does not support it).
  Use luks_boot_split.sh to create a separate /boot partition via initramfs:

    sudo ./luks_boot_split.sh   # installs initramfs hooks
    sudo reboot                 # split happens offline during boot
    sudo ./luks_prepare.sh      # then re-run this script

  luks_boot_split.sh shrinks the root filesystem offline (in initramfs,
  before root is mounted) and creates a ${BOOT_PARTITION_SIZE_MB}MB /boot partition."

elif [ "$SCENARIO" = "inplace" ] && [ "$HAS_SEPARATE_BOOT" = true ]; then
  # Already has separate /boot - determine partition paths
  BOOT_PART=$(findmnt -n -o SOURCE /boot)
  ROOT_PART=$(findmnt -n -o SOURCE /)
  info "Using existing separate /boot partition: $BOOT_PART"
fi

# =====================================================================
# 4. Network detection
# =====================================================================

# Detect primary network interface (the one carrying the default route)
IFACE=""

# Prefer the interface with the default route - that's what needs to work at boot
DEFAULT_ROUTE_IFACE=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "$DEFAULT_ROUTE_IFACE" ] && [ -d "/sys/class/net/$DEFAULT_ROUTE_IFACE" ]; then
  IFACE="$DEFAULT_ROUTE_IFACE"
  info "Network interface: $IFACE (default route)"
fi

# Fallback: first UP ethernet interface
if [ -z "$IFACE" ]; then
  for candidate in $(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(eth|end|enx|en)'); do
    if [ -d "/sys/class/net/$candidate" ]; then
      IFACE="$candidate"
      info "Network interface: $IFACE (first UP ethernet)"
      break
    fi
  done
fi

# Last resort: any ethernet interface that exists
if [ -z "$IFACE" ]; then
  NET_CANDIDATES=(eth0 end0)
  for candidate in /sys/class/net/*; do
    candidate="${candidate##*/}"
    if [[ "$candidate" =~ ^(eth|enx|en) ]]; then
      NET_CANDIDATES+=("$candidate")
    fi
  done
  for candidate in "${NET_CANDIDATES[@]}"; do
    if [ -d "/sys/class/net/$candidate" ]; then
      IFACE="$candidate"
      info "Network interface: $IFACE (fallback)"
      break
    fi
  done
fi

if [ -z "$IFACE" ]; then
  fail "Could not detect a suitable network interface"
fi

# Detect network driver
NETWORK_DRIVER=""
if [ -L "/sys/class/net/${IFACE}/device/driver" ]; then
  NETWORK_DRIVER=$(basename "$(readlink "/sys/class/net/${IFACE}/device/driver")")
  info "Network driver: $NETWORK_DRIVER"
else
  warn "Could not detect network driver for $IFACE"
fi
if [ -n "$NETWORK_DRIVER" ]; then
  NET_DRIVERS=("$NETWORK_DRIVER")
fi

# =====================================================================
# 5. Summary and confirmation
# =====================================================================

echo ""
echo -e "${YELLOW}This script will:${NC}"
echo "  - Install cryptsetup, clevis/tang, and related packages"
echo "  - Configure initramfs with crypto modules and network support"
echo "  - Create initramfs hooks for LUKS"
echo "  - Stage boot configuration files in $STAGED_DIR"
echo "  - Rebuild initramfs"
echo ""
echo -e "  Board type:      ${YELLOW}${BOARD_TYPE}${NC} (${BOARD_MODEL})"
echo -e "  Scenario:        ${YELLOW}${SCENARIO}${NC}"
echo -e "  Storage device:  ${YELLOW}${DEVICE}${NC}"
echo -e "  Boot partition:  ${YELLOW}${BOOT_PART}${NC}"
echo -e "  Root partition:  ${YELLOW}${ROOT_PART}${NC}"
echo -e "  Boot directory:  ${YELLOW}${BOOT_DIR}${NC} (${BOOT_FS})"
echo -e "  Network:         ${YELLOW}${IFACE}${NC} (driver: ${NETWORK_DRIVER:-unknown})"
if [ "$USE_LVM" = true ]; then
  echo -e "  LVM:             ${YELLOW}enabled${NC} (VG: ${LVM_VG_NAME}, LV: ${LVM_LV_NAME})"
  echo -e "  Root device:     ${YELLOW}${ROOT_DEV}${NC}"
else
  echo -e "  LVM:             ${YELLOW}disabled${NC}"
  echo -e "  Root device:     ${YELLOW}${ROOT_DEV}${NC}"
fi
echo ""
_ask_confirm "Continue? [y/N] " "--yes" || { echo "Aborted."; exit 0; }

# =====================================================================
# 6. to 13. Install packages, configure, stage, rebuild initramfs, verify tang
# =====================================================================

install_packages          # 6. Install packages
configure_modules         # 7. Configure initramfs modules
create_hooks              # 8. Create initramfs hooks
configure_networking      # 9. Configure initramfs networking
create_postinst_hook      # 10. Create kernel postinst hook (RPi only)
stage_boot_files          # 11. Stage boot configuration files
show_staged_files
rebuild_initramfs         # 12. Rebuild initramfs
verify_tang_connectivity  # 13. Verify tang server connectivity

# =====================================================================
# 14. Summary and next steps
# =====================================================================

echo ""
echo "================================================================="
echo -e "${GREEN}Preparation complete!${NC}"
echo "================================================================="
echo ""
echo "Staged files are in: $STAGED_DIR"
echo ""

if [ "$SCENARIO" = "rpi" ]; then
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Shut down: sudo shutdown -h now"
  echo "  2. Remove the SD card (or NVMe drive)"
  echo "  3. Plug it into an external Linux machine"
  echo "  4. Run the encryption script:"
  echo ""
  echo -e "     ${CYAN}sudo ./luks_encrypt.sh${NC}"
  echo ""
  echo "     (also available on the storage at: /root/luks-staged/luks_encrypt.sh)"
  echo ""
  echo "  The encryption script will:"
  echo "    - Back up the root partition"
  echo "    - LUKS-encrypt the root partition"
  if [ "$USE_LVM" = true ]; then
    echo "    - Create LVM (VG: $LVM_VG_NAME, LV: $LVM_LV_NAME) inside LUKS"
  fi
  echo "    - Restore data to the encrypted partition"
  echo "    - Activate the staged boot configuration"
  echo "    - Bind clevis/tang for automatic decryption"
  echo ""
  echo -e "${YELLOW}Important:${NC}"
  echo "  - The internal device path is: $ROOT_PART"
  echo "  - When plugged into another machine, it will appear as /dev/sdX"
  echo "  - The encryption script will ask you for both paths"

elif [ "$SCENARIO" = "nvme_migrate" ] || [ "$SCENARIO" = "usb_migrate" ]; then
  if [ "$SCENARIO" = "nvme_migrate" ]; then
    STORAGE_TYPE="NVMe"
  else
    STORAGE_TYPE="USB"
  fi
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  Run the encryption script directly on this machine:"
  echo ""
  echo -e "     ${CYAN}sudo ./luks_encrypt.sh${NC}"
  echo ""
  echo "  The script will detect that it's running locally (${STORAGE_TYPE} != boot disk)"
  echo "  and encrypt ${ROOT_PART} while the system runs from ${CURRENT_ROOT_DISK}."
  echo ""
  echo "  The encryption script will offer to flash U-Boot to SPI for ${STORAGE_TYPE} boot."
  echo "  If skipped, you can flash later with: sudo ./luks_encrypt.sh --spi-only"
  echo ""
  echo "  After encryption and reboot:"
  echo "    1. Verify LUKS auto-unlock via clevis/tang"
  echo "    2. Disable old eMMC boot by clearing its bootable flag:"
  echo "       parted ${CURRENT_ROOT_DISK} set 1 boot off"

elif [ "$SCENARIO" = "inplace" ]; then
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Shut down: sudo shutdown -h now"
  echo "  2. Boot from an SD card (or other medium)"
  echo "  3. Run the encryption script against the eMMC:"
  echo ""
  echo -e "     ${CYAN}sudo ./luks_encrypt.sh${NC}"
  echo ""
  echo "  The encryption script is also on the eMMC at: /root/luks-staged/luks_encrypt.sh"
fi

echo ""
