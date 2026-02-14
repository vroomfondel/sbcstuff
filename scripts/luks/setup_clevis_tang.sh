#!/bin/bash
# setup_clevis_tang.sh - Setup/rebind clevis/tang NBDE on LUKS device
#
# This script can be used to (re-)bind clevis/tang to the LUKS device
#
# Usage: sudo /root/setup_clevis_tang.sh [LUKS_PASSPHRASE]
#   If LUKS_PASSPHRASE is omitted, you will be prompted for it.

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Configuration (edit here or leave empty to be prompted) ---
LUKS_DEVICE=""
NETWORK_INTERFACE=""
SSS_THRESHOLD=2
TANG_SERVERS=("" "")

TANG_TIMEOUT=5                    # Timeout in seconds for tang server connectivity checks
IP_METHOD="dhcp"                  # IP config for initramfs (kernel ip= parameter)
                                  # "dhcp" → IP=:::::eth0:dhcp  (auto-builds with NETWORK_INTERFACE)
                                  # For static IP, set the full ip= string instead:
                                  # IP_METHOD="192.168.1.100::192.168.1.1:255.255.255.0::eth0:none"
                                  # Kernel syntax: ip=<client>:<server>:<gw>:<mask>:<host>:<iface>:<proto>

# --- Root check ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script must be run as root (sudo).${NC}"
  exit 1
fi

# --- Prompt for missing configuration ---
if [ -z "$LUKS_DEVICE" ]; then
  # Try to auto-detect LUKS device from /etc/crypttab
  if [ -f /etc/crypttab ]; then
    CRYPTTAB_ENTRY=$(awk '!/^#/ && !/^$/ && /luks/ {print $2; exit}' /etc/crypttab)
    if [ -n "$CRYPTTAB_ENTRY" ]; then
      if [[ "$CRYPTTAB_ENTRY" == UUID=* ]]; then
        _UUID="${CRYPTTAB_ENTRY#UUID=}"
        LUKS_DEVICE=$(blkid -U "$_UUID" 2>/dev/null || true)
      else
        LUKS_DEVICE="$CRYPTTAB_ENTRY"
      fi
      if [ -n "$LUKS_DEVICE" ] && [ -b "$LUKS_DEVICE" ]; then
        echo -e "Auto-detected LUKS device from crypttab: ${YELLOW}${LUKS_DEVICE}${NC}"
      else
        LUKS_DEVICE=""
      fi
    fi
  fi

  if [ -z "$LUKS_DEVICE" ]; then
    read -rp "LUKS device (e.g. /dev/nvme0n1p2): " LUKS_DEVICE
    if [ -z "$LUKS_DEVICE" ]; then
      echo -e "${RED}Error: LUKS_DEVICE must not be empty.${NC}"
      exit 1
    fi
  fi
fi

if [ -z "$NETWORK_INTERFACE" ]; then
  read -rp "Network interface (e.g. eth0, end0): " NETWORK_INTERFACE
  if [ -z "$NETWORK_INTERFACE" ]; then
    echo -e "${RED}Error: NETWORK_INTERFACE must not be empty.${NC}"
    exit 1
  fi
fi

# Prompt for empty tang servers
for i in "${!TANG_SERVERS[@]}"; do
  if [ -z "${TANG_SERVERS[$i]}" ]; then
    read -rp "Tang server $((i+1)) URL (e.g. http://tang.example.com): " url
    if [ -z "$url" ]; then
      echo -e "${RED}Error: Tang server $((i+1)) must not be empty.${NC}"
      exit 1
    fi
    TANG_SERVERS[$i]="$url"
  fi
done

# --- Validate LUKS device ---
if [ ! -b "$LUKS_DEVICE" ]; then
  echo -e "${RED}Error: LUKS device $LUKS_DEVICE not found.${NC}"
  exit 1
fi

LUKS_UUID=$(cryptsetup luksUUID "$LUKS_DEVICE")
echo -e "LUKS device: ${YELLOW}${LUKS_DEVICE}${NC} (UUID: ${LUKS_UUID})"

# --- Auto-detect network driver ---
NETWORK_DRIVER=""
if [ -L "/sys/class/net/${NETWORK_INTERFACE}/device/driver" ]; then
  NETWORK_DRIVER=$(basename "$(readlink "/sys/class/net/${NETWORK_INTERFACE}/device/driver")")
fi
if [ -n "$NETWORK_DRIVER" ]; then
  echo -e "Network interface: ${YELLOW}${NETWORK_INTERFACE}${NC} (driver: ${NETWORK_DRIVER})"
else
  echo -e "Network interface: ${YELLOW}${NETWORK_INTERFACE}${NC} (driver: ${RED}not detected${NC})"
fi

# --- Check existing bindings ---
EXISTING=$(clevis luks list -d "$LUKS_DEVICE" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo -e "\n${GREEN}Existing clevis bindings found:${NC}"
  echo "$EXISTING"

  # Check if existing bindings already match the desired configuration
  # Extract tang URLs from existing bindings
  EXISTING_URLS=()
  while IFS= read -r url; do
    [ -n "$url" ] && EXISTING_URLS+=("$url")
  done < <(echo "$EXISTING" | grep -oP '"url"\s*:\s*"\K[^"]+' | sort)

  DESIRED_URLS=()
  for srv in "${TANG_SERVERS[@]}"; do
    [ -n "$srv" ] && DESIRED_URLS+=("$srv")
  done
  IFS=$'\n' DESIRED_URLS_SORTED=($(printf '%s\n' "${DESIRED_URLS[@]}" | sort)); unset IFS

  if [ "${#EXISTING_URLS[@]}" -eq "${#DESIRED_URLS_SORTED[@]}" ]; then
    URLS_MATCH=true
    for i in "${!EXISTING_URLS[@]}"; do
      if [ "${EXISTING_URLS[$i]}" != "${DESIRED_URLS_SORTED[$i]}" ]; then
        URLS_MATCH=false
        break
      fi
    done
  else
    URLS_MATCH=false
  fi

  if [ "$URLS_MATCH" = true ]; then
    echo -e "\n${GREEN}Bindings already match configuration. Nothing to do.${NC}"
    exit 0
  fi

  echo ""
  read -rp "Bindings exist but differ from configuration. Remove and rebind? [y/N] " CONFIRM
  if [[ "$CONFIRM" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi
  # Remove existing bindings
  while IFS= read -r line; do
    SLOT=$(echo "$line" | awk '{print $1}' | tr -d :)
    echo "Removing binding in slot $SLOT..."
    clevis luks unbind -d "$LUKS_DEVICE" -s "$SLOT" -f
  done <<< "$EXISTING"
  echo -e "${GREEN}Existing bindings removed.${NC}"
fi

# --- Get LUKS passphrase ---
if [ -n "${1:-}" ]; then
  LUKS_PASSPHRASE="$1"
else
  read -rsp "Enter LUKS passphrase: " LUKS_PASSPHRASE
  echo ""
fi

# --- Verify tang server connectivity ---
echo -e "\nChecking tang server connectivity..."
ALL_OK=true
for SERVER in "${TANG_SERVERS[@]}"; do
  if curl -sf --max-time $TANG_TIMEOUT "${SERVER}/adv" > /dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC} $SERVER"
  else
    echo -e "  ${RED}[FAIL]${NC} $SERVER"
    ALL_OK=false
  fi
done

if [ "$ALL_OK" != "true" ]; then
  echo -e "${RED}Not all tang servers are reachable. Aborting.${NC}"
  exit 1
fi

# --- Build SSS config and bind ---
echo -e "\nBuilding clevis SSS configuration (threshold: $SSS_THRESHOLD)..."

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

echo "Binding clevis/tang to $LUKS_DEVICE..."
KEYFILE=$(mktemp)
trap 'rm -f "$KEYFILE"' EXIT
echo -n "$LUKS_PASSPHRASE" > "$KEYFILE"
chmod 600 "$KEYFILE"

clevis luks bind -k "$KEYFILE" -d "$LUKS_DEVICE" sss "$CONFIG"
echo -e "${GREEN}Clevis binding successful.${NC}"

# --- Configure initramfs networking ---
echo -e "\nConfiguring initramfs networking..."

if [ -n "$NETWORK_DRIVER" ]; then
  if ! grep -qxF "$NETWORK_DRIVER" /etc/initramfs-tools/modules 2>/dev/null; then
    echo "$NETWORK_DRIVER" >> /etc/initramfs-tools/modules
    echo "  Added $NETWORK_DRIVER to initramfs modules"
  else
    echo "  $NETWORK_DRIVER already in initramfs modules"
  fi
fi

sed -i "s/^DEVICE=.*/DEVICE=${NETWORK_INTERFACE}/" /etc/initramfs-tools/initramfs.conf
if ! grep -q "^DEVICE=" /etc/initramfs-tools/initramfs.conf; then
  echo "DEVICE=${NETWORK_INTERFACE}" >> /etc/initramfs-tools/initramfs.conf
fi

if [ "$IP_METHOD" = "dhcp" ]; then
  IP_LINE="IP=:::::${NETWORK_INTERFACE}:dhcp"
else
  IP_LINE="IP=${IP_METHOD}"
fi
if grep -q "^IP=" /etc/initramfs-tools/initramfs.conf; then
  sed -i "s/^IP=.*/${IP_LINE}/" /etc/initramfs-tools/initramfs.conf
else
  sed -i "/^DEVICE=/a ${IP_LINE}" /etc/initramfs-tools/initramfs.conf
fi

echo "  DEVICE=${NETWORK_INTERFACE}, ${IP_LINE}"

# --- Rebuild initramfs ---
echo -e "\nRebuilding initramfs..."
update-initramfs -u -k all
echo -e "${GREEN}Initramfs rebuilt.${NC}"

# --- Verify ---
echo -e "\n--- Verification ---"
echo "Clevis bindings:"
clevis luks list -d "$LUKS_DEVICE"

CLEVIS_COUNT=$(lsinitramfs /boot/initrd.img-"$(uname -r)" 2>/dev/null | grep -c clevis || echo "0")
echo "Clevis hooks in initramfs: $CLEVIS_COUNT files"

if [ -n "$NETWORK_DRIVER" ]; then
  DRIVER_COUNT=$(lsinitramfs /boot/initrd.img-"$(uname -r)" 2>/dev/null | grep -c "$NETWORK_DRIVER" || echo "0")
  echo "Network driver ($NETWORK_DRIVER) in initramfs: $DRIVER_COUNT files"
fi

echo -e "\n${GREEN}Setup complete.${NC}"
echo "Test with: /root/tang_check_connection.sh $LUKS_DEVICE"
