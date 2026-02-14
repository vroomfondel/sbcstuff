#!/bin/bash
# luks_prepare.sh - Prepare a Linux SBC for LUKS encryption with clevis/tang
#
# Supports:
#   - Raspberry Pi (SD card / NVMe with separate FAT32 boot partition)
#   - Armbian/U-Boot boards like Rock 5B (single root partition, /boot on root)
#
# After running this script:
#   RPi:     Shut down, move SD/NVMe to external machine, run luks_encrypt.sh
#   Armbian: For NVMe/USB migration, run luks_encrypt.sh directly on the same machine
#            For in-place eMMC, boot from SD, run luks_encrypt.sh against eMMC
#
# Usage: sudo ./luks_prepare.sh

set -euo pipefail

# --- Help ---
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: sudo ./luks_prepare.sh"
      echo ""
      echo "Prepare a Linux SBC for LUKS encryption with clevis/tang."
      echo ""
      echo "Supports:"
      echo "  - Raspberry Pi (SD card / NVMe with separate FAT32 boot partition)"
      echo "  - Armbian/U-Boot boards like Rock 5B (single root partition, /boot on root)"
      echo ""
      echo "This script runs ON the board to install packages, configure initramfs,"
      echo "and stage boot configs. After running:"
      echo "  RPi:     Shut down, move SD/NVMe to external machine, run luks_encrypt.sh"
      echo "  Armbian: For NVMe/USB migration, run luks_encrypt.sh on the same machine"
      echo "           For in-place eMMC, boot from SD, run luks_encrypt.sh against eMMC"
      echo ""
      echo "Options:"
      echo "  -h, --help    Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# --- Configuration ---
TANG_SERVERS=("" "")
SSS_THRESHOLD=2
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

# =====================================================================
# 1. Safety checks
# =====================================================================

if [ "$EUID" -ne 0 ]; then
  fail "This script must be run as root (sudo)."
fi

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  warn "Expected aarch64 architecture, got: $ARCH"
  read -rp "Continue anyway? [y/N] " CONFIRM
  [[ "$CONFIRM" == [yY] ]] || exit 0
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
    # NVMe already partitioned (likely from a previous run) — skip partitioning
    info "NVMe already partitioned — skipping partitioning and /boot copy"
    lsblk "$DEVICE"
    echo ""
  else
    echo ""
    echo -e "${RED}WARNING: This will ERASE all data on ${DEVICE}!${NC}"
    echo "  Partition 1: $((BOOT_PARTITION_SIZE_MB)) MB ext4 (/boot)"
    echo "  Partition 2: remainder (for LUKS+LVM)"
    echo ""
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
    # USB already partitioned (likely from a previous run) — skip partitioning
    info "USB device already partitioned — skipping partitioning and /boot copy"
    lsblk "$DEVICE"
    echo ""
  else
    echo ""
    echo -e "${RED}WARNING: This will ERASE all data on ${DEVICE}!${NC}"
    echo "  Partition 1: $((BOOT_PARTITION_SIZE_MB)) MB ext4 (/boot)"
    echo "  Partition 2: remainder (for LUKS+LVM)"
    echo ""
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
  # Already has separate /boot — determine partition paths
  BOOT_PART=$(findmnt -n -o SOURCE /boot)
  ROOT_PART=$(findmnt -n -o SOURCE /)
  info "Using existing separate /boot partition: $BOOT_PART"
fi

# =====================================================================
# 4. Network detection
# =====================================================================

# Detect primary network interface (the one carrying the default route)
IFACE=""

# Prefer the interface with the default route — that's what needs to work at boot
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
  for candidate in eth0 end0 $(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|enx|en)'); do
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
read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" == [yY] ]] || { echo "Aborted."; exit 0; }

# =====================================================================
# 6. Install packages
# =====================================================================

info "Installing required packages..."
apt-get update -qq

LVM_PKGS=""
if [ "$USE_LVM" = true ]; then
  LVM_PKGS="lvm2"
fi

apt-get install -y \
  cryptsetup cryptsetup-initramfs \
  clevis clevis-luks clevis-initramfs clevis-systemd \
  curl jq $LVM_PKGS
ok "Packages installed"

# =====================================================================
# 7. Configure initramfs modules
# =====================================================================

info "Configuring initramfs modules..."

MODULES_FILE="/etc/initramfs-tools/modules"

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

if [ -n "$NETWORK_DRIVER" ]; then
  if ! grep -qxF "$NETWORK_DRIVER" "$MODULES_FILE" 2>/dev/null; then
    echo "$NETWORK_DRIVER" >> "$MODULES_FILE"
    info "  Added network driver module: $NETWORK_DRIVER"
  else
    info "  Network driver already present: $NETWORK_DRIVER"
  fi
fi

ok "Initramfs modules configured"

# =====================================================================
# 8. Create initramfs hooks
# =====================================================================

info "Creating initramfs hooks..."

# copycrypttab hook
cat > /etc/initramfs-tools/hooks/copycrypttab << 'HOOKEOF'
#!/bin/sh
cp /etc/crypttab "${DESTDIR}/etc/crypttab"
exit 0
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/copycrypttab
info "  Created /etc/initramfs-tools/hooks/copycrypttab"

# luks_hooks - copy required binaries into initramfs
cat > /etc/initramfs-tools/hooks/luks_hooks << 'HOOKEOF'
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
chmod +x /etc/initramfs-tools/hooks/luks_hooks
info "  Created /etc/initramfs-tools/hooks/luks_hooks"

# cleanup-netplan init-bottom script — removes stale netplan YAML from initramfs DHCP
SCRIPT_DIR_HOOKS="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR_HOOKS}/initramfs_local-bottom_cleanup-netplan" ]; then
  mkdir -p /etc/initramfs-tools/scripts/init-bottom
  cp "${SCRIPT_DIR_HOOKS}/initramfs_local-bottom_cleanup-netplan" \
    /etc/initramfs-tools/scripts/init-bottom/cleanup-netplan
  chmod 755 /etc/initramfs-tools/scripts/init-bottom/cleanup-netplan
  info "  Created /etc/initramfs-tools/scripts/init-bottom/cleanup-netplan"

  # Remove old incorrect location if present
  if [ -f /etc/initramfs-tools/scripts/local-bottom/cleanup-netplan ]; then
    rm -f /etc/initramfs-tools/scripts/local-bottom/cleanup-netplan
    info "  Removed old /etc/initramfs-tools/scripts/local-bottom/cleanup-netplan"
  fi

else
  warn "initramfs_local-bottom_cleanup-netplan not found in script directory — skipping"
fi

ok "Initramfs hooks created"

# =====================================================================
# 9. Configure initramfs networking (for clevis tang at boot)
# =====================================================================

info "Configuring initramfs networking..."

INITRAMFS_CONF="/etc/initramfs-tools/initramfs.conf"

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

# =====================================================================
# 10. Create kernel postinst hook (RPi only)
# =====================================================================

if [ "$BOARD_TYPE" = "rpi" ]; then
  info "Creating kernel postinst hook..."

  cat > /etc/kernel/postinst.d/initramfs-rebuild << 'HOOKEOF'
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
  chmod +x /etc/kernel/postinst.d/initramfs-rebuild
  ok "Kernel postinst hook created"
else
  info "Skipping kernel postinst hook (Armbian has its own initramfs hooks)"
fi

# =====================================================================
# 11. Stage boot configuration files
# =====================================================================

info "Staging boot configuration files in $STAGED_DIR..."
mkdir -p "$STAGED_DIR"

if [ "$BOARD_TYPE" = "rpi" ]; then
  # --- RPi: stage cmdline.txt ---
  CURRENT_CMDLINE=""
  if [ -f "${BOOT_DIR}/cmdline.txt" ]; then
    CURRENT_CMDLINE=$(cat "${BOOT_DIR}/cmdline.txt")
  fi
  NEW_CMDLINE=$(echo "$CURRENT_CMDLINE" | sed \
    -e 's|root=[^ ]*||g' \
    -e 's|cryptdevice=[^ ]*||g' \
    -e 's|  *| |g' \
    -e 's|^ ||' \
    -e 's| $||')
  NEW_CMDLINE="${NEW_CMDLINE} root=${ROOT_DEV} cryptdevice=${ROOT_PART}:${LUKS_MAPPER_NAME}"
  cat > "${STAGED_DIR}/cmdline.txt" << EOF
${NEW_CMDLINE}
EOF
  info "  Staged cmdline.txt"

elif [ "$BOARD_TYPE" = "armbian" ]; then
  # --- Armbian: stage armbianEnv.txt ---
  cp "${BOOT_DIR}/armbianEnv.txt" "${STAGED_DIR}/armbianEnv.txt.orig"
  sed "s|^rootdev=.*|rootdev=${ROOT_DEV}|" \
    "${BOOT_DIR}/armbianEnv.txt" > "${STAGED_DIR}/armbianEnv.txt"
  info "  Staged armbianEnv.txt (rootdev=${ROOT_DEV})"
fi

# Staged crypttab (clevis/tang, no keyfile — uses luks,initramfs for clevis)
cat > "${STAGED_DIR}/crypttab" << EOF
# <target name>	<source device>		<key file>	<options>
${LUKS_MAPPER_NAME}	${ROOT_PART}	none	luks,initramfs
EOF
info "  Staged crypttab"

# Staged fstab
if [ -f /etc/fstab ]; then
  # Replace the root mount line (whatever currently points to /)
  sed -e "s|^[^ ]*\([ \t]\+/[ \t]\+\)|${ROOT_DEV}\1|" \
    /etc/fstab > "${STAGED_DIR}/fstab"
else
  if [ "$BOARD_TYPE" = "rpi" ]; then
    cat > "${STAGED_DIR}/fstab" << EOF
proc            /proc           proc    defaults          0       0
${BOOT_PART}  /boot/firmware  vfat    defaults          0       2
${ROOT_DEV}  /               ext4    defaults,noatime  0       1
EOF
  else
    cat > "${STAGED_DIR}/fstab" << EOF
proc            /proc           proc    defaults          0       0
${BOOT_PART}  /boot           ext4    defaults          0       2
${ROOT_DEV}  /               ext4    defaults,noatime  0       1
EOF
  fi
fi

# Ensure /boot mount is correct in staged fstab
if [ "$BOARD_TYPE" = "armbian" ]; then
  BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
  if grep -qE "^\S+\s+/boot\s+" "${STAGED_DIR}/fstab"; then
    sed -i -E "s|^[^ ]+(\s+/boot\s+)|UUID=${BOOT_UUID}\1|" "${STAGED_DIR}/fstab"
  else
    echo "UUID=${BOOT_UUID}  /boot  ext4  defaults  0  2" >> "${STAGED_DIR}/fstab"
  fi
fi
info "  Staged fstab"

# Write config file with device info (used by luks_encrypt.sh)
cat > "${STAGED_DIR}/luks.conf" << EOF
# Auto-generated by luks_prepare.sh — device paths and board info
BOARD_TYPE="${BOARD_TYPE}"
BOOT_DIR="${BOOT_DIR}"
PI_DEVICE="${DEVICE}"
PI_BOOT_PART="${BOOT_PART}"
PI_ROOT_PART="${ROOT_PART}"
SOURCE_DEVICE="${CURRENT_ROOT_DISK:-}"
SCENARIO="${SCENARIO}"
EOF
info "  Staged luks.conf (BOARD_TYPE=${BOARD_TYPE}, DEVICE=${DEVICE})"

# Copy the encrypt script to staged dir so it's available on the storage
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/luks_encrypt.sh" ]; then
  cp "${SCRIPT_DIR}/luks_encrypt.sh" "${STAGED_DIR}/luks_encrypt.sh"
  chmod +x "${STAGED_DIR}/luks_encrypt.sh"
  info "  Staged luks_encrypt.sh"
fi

# Copy tang_check_connection.sh to staged dir
if [ -f "${SCRIPT_DIR}/tang_check_connection.sh" ]; then
  cp "${SCRIPT_DIR}/tang_check_connection.sh" "${STAGED_DIR}/tang_check_connection.sh"
  chmod +x "${STAGED_DIR}/tang_check_connection.sh"
  info "  Staged tang_check_connection.sh"
fi

# Copy cleanup-netplan hook to staged dir
if [ -f "${SCRIPT_DIR}/initramfs_local-bottom_cleanup-netplan" ]; then
  cp "${SCRIPT_DIR}/initramfs_local-bottom_cleanup-netplan" "${STAGED_DIR}/cleanup-netplan"
  info "  Staged cleanup-netplan"
fi

# RPi-specific: ensure auto_initramfs=1 in config.txt
if [ "$BOARD_TYPE" = "rpi" ] && [ -f "${BOOT_DIR}/config.txt" ]; then
  if ! grep -q "^auto_initramfs=1" "${BOOT_DIR}/config.txt"; then
    echo "auto_initramfs=1" >> "${BOOT_DIR}/config.txt"
    info "  Added auto_initramfs=1 to ${BOOT_DIR}/config.txt"
  else
    info "  auto_initramfs=1 already in config.txt"
  fi
fi

ok "Boot configuration files staged"

# Show staged files for review
echo ""
if [ "$BOARD_TYPE" = "rpi" ]; then
  info "Staged cmdline.txt:"
  echo -e "  ${CYAN}$(cat "${STAGED_DIR}/cmdline.txt")${NC}"
  echo ""
elif [ "$BOARD_TYPE" = "armbian" ]; then
  info "Staged armbianEnv.txt (diff):"
  diff --color=always "${STAGED_DIR}/armbianEnv.txt.orig" "${STAGED_DIR}/armbianEnv.txt" || true
  echo ""
fi
info "Staged crypttab:"
echo -e "  ${CYAN}$(cat "${STAGED_DIR}/crypttab")${NC}"
echo ""
info "Staged fstab (root + boot lines):"
echo -e "  ${CYAN}$(grep -E "[ \t]+/([ \t]|boot)" "${STAGED_DIR}/fstab" | head -3)${NC}"

# =====================================================================
# 12. Rebuild initramfs
# =====================================================================

echo ""
info "Rebuilding initramfs..."
update-initramfs -u -k all
ok "Initramfs rebuilt"

# =====================================================================
# 13. Verify tang server connectivity
# =====================================================================

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
  echo "    2. Disable old eMMC boot:"
  echo "       mount ${CURRENT_ROOT_DISK}p1 /mnt"
  echo "       mv /mnt/boot/boot.scr /mnt/boot/boot.scr.disabled"
  echo "       umount /mnt"

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
