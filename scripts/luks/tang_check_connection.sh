#!/bin/bash

# --- Configuration ---
CLEVIS_TIMEOUT=15                 # Timeout in seconds for clevis luks pass

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if an argument was provided
if [ -z "$1" ]; then
    echo -e "${YELLOW}Usage: sudo $0 <path-to-LUKS-device>${NC}"
    echo "Example: sudo $0 /dev/sda2"
    exit 1
fi

DEVICE=$1

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script must be run as root (sudo).${NC}"
  exit 1
fi

# Check if the device exists
if [ ! -b "$DEVICE" ]; then
    echo -e "${RED}Error: Device $DEVICE not found.${NC}"
    exit 1
fi

echo "Checking clevis bindings on $DEVICE..."

# Get list of clevis slots
# Format is "Slot: Pin: Config"
SLOTS_INFO=$(clevis luks list -d "$DEVICE" 2>/dev/null)

if [ -z "$SLOTS_INFO" ]; then
    echo -e "${RED}No clevis binding found on $DEVICE!${NC}"
    echo "Did you run 'clevis luks bind'?"
    exit 1
fi

echo -e "Bindings found:\n$SLOTS_INFO\n"

# Iterate through slots and test
while IFS= read -r line; do
    # Use awk to safely split fields
    # $1 is the slot (e.g. "1:"), $2 is the pin (e.g. "sss")

    # Slot number: take first field and remove colon
    SLOT=$(echo "$line" | awk '{print $1}' | tr -d :)

    # Pin type: take second field
    PIN=$(echo "$line" | awk '{print $2}')

    if [ "$PIN" == "tang" ] || [ "$PIN" == "sss" ]; then
        echo -e "Testing decryption for slot ${YELLOW}$SLOT${NC} (type: $PIN)..."

        # The actual test:
        START_TIME=$(date +%s%N)
        if timeout "${CLEVIS_TIMEOUT}s" clevis luks pass -d "$DEVICE" -s "$SLOT" > /dev/null; then
            END_TIME=$(date +%s%N)
            DURATION=$((($END_TIME - $START_TIME)/1000000))
            echo -e "${GREEN}[OK] Successfully authenticated.${NC} (duration: ${DURATION}ms)"
        else
            echo -e "${RED}[FAIL] Could not authenticate.${NC}"
            echo "Possible causes:"
            echo " - Tang server not reachable"
            echo " - DNS issues"
            echo " - Firewall blocking port"
        fi
    else
        echo "Skipping slot $SLOT (type: $PIN is not relevant)"
    fi
    echo "---------------------------------------------------"
done <<< "$SLOTS_INFO"
