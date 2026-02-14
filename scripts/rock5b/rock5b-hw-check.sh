#!/bin/bash
###############################################################################
#  rock5b-hw-check.sh
#  Prüft NPU & GPU auf einem Rock 5B unter Armbian (RK3588)
#
#  Nutzung:  sudo ./rock5b-hw-check.sh [--fix]
#
#  Ohne --fix:  Nur Diagnose (read-only)
#  Mit  --fix:  Versucht fehlende Kernel-Module zu laden und prüft auf
#               schädliche Overlays
#
#  NPU-Erkennung:
#    Vendor-Kernel (6.1.x, rknpu 0.9.x):
#      DRM-Subsystem: /dev/dri/renderD129 (platform-fdab0000.npu-render).
#      Der alte /dev/rknpu* Pfad existiert NICHT mehr.
#      Der Vendor-DTB hat die NPU bereits mit status="okay" — ein separates
#      Overlay ist NICHT nötig und verursacht Konflikte.
#
#    Mainline-Kernel ab 6.18+ (Rocket-Treiber):
#      DRM accel subsystem: /dev/accel/accel0 (rocket.ko, upstream GPL)
#      Userspace: Mesa Teflon TFLite-Delegate (statt rknn-toolkit2)
#      Modellformat: .tflite (statt .rknn)
#      panthor GPU-Treiber (ersetzt panfrost für Mali G610 / Valhall)
#
#  Kernel-Familie:
#    Armbian hat die RK3588-Kernel-Pakete umbenannt:
#      Alt: linux-image-edge-rockchip-rk3588  (6.12.x)
#      Neu: linux-image-edge-rockchip64       (6.18.x+)
#    Beide Pakete können parallel im Repo existieren.
#
#  CLI Kernel-Wechsel:
#    armbian-config --cmd KER001                        # interaktiver TUI-Selector
#    apt install linux-image-edge-rockchip64 \          # direkt per apt
#                linux-dtb-edge-rockchip64
#
#  Referenzen:
#    - https://docs.armbian.com/User-Guide_Armbian_overlays/
#    - https://github.com/armbian/linux-rockchip (Overlay-Quellen)
#    - https://github.com/Pelochus/ezrknpu (NPU-Nutzung)
###############################################################################

set -euo pipefail

# ── Farben ──────────────────────────────────────────────────────────────────
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

# ── Konfiguration ────────────────────────────────────────────────────────────
# Hardware-spezifische Pfade (RK3588)
NPU_DRM_DEVICE="/dev/dri/by-path/platform-fdab0000.npu-render"
GPU_DRM_DEVICE="/dev/dri/by-path/platform-display-subsystem-render"
NPU_DEVFREQ_PATH="/sys/class/devfreq/fdab0000.npu"
GPU_UTIL_PATH="/sys/devices/platform/fb000000.gpu/utilisation"
OVERLAY_USER_DIR="/boot/overlay-user"

# Kernel-Version-Schwellwerte
KERNEL_PANTHOR_MIN="6.12"         # Minimum für panthor GPU-Support
KERNEL_NPU_EXPERIMENTAL_MIN="6.14"  # Experimenteller NPU-Support ab hier
KERNEL_NPU_STABLE_MIN="6.18"     # Stabiler NPU-Support (Rocket-Treiber)

# U-Boot
UBOOT_MIN_YEAR_NVME=202301       # Minimale U-Boot-Version für zuverlässigen NVMe/USB-Boot
SPI_DD_BLOCK_SIZE=4096            # Block-Größe für SPI-Flash dd-Operationen (Bytes)

# Ausgabe
DMESG_NPU_LINES=10               # Anzahl der NPU dmesg-Zeilen
DMESG_GPU_LINES=8                 # Anzahl der GPU dmesg-Zeilen
MODPROBE_WAIT=1                   # Sekunden Wartezeit nach modprobe

FIX_MODE=false
[[ "${1:-}" == "--fix" ]] && FIX_MODE=true

ARMBIAN_ENV="/boot/armbianEnv.txt"
REBOOT_NEEDED=false
ISSUES_FOUND=0

###############################################################################
#  Hilfsfunktionen
###############################################################################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Dieses Script muss als root ausgeführt werden (sudo).${NC}"
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
#  1. Systemübersicht
###############################################################################

header "System-Übersicht"

echo -e "  Hostname:     $(hostname)"
echo -e "  Kernel:       $(uname -r)"
echo -e "  Architektur:  $(uname -m)"

if [[ -f /etc/armbian-release ]]; then
    source /etc/armbian-release 2>/dev/null || true
    echo -e "  Armbian:      ${BOARD_NAME:-?} / ${DISTRIBUTION_CODENAME:-?} / Branch: ${BRANCH:-?}"
    echo -e "  Image:        ${IMAGE_TYPE:-?} / ${LINUXFAMILY:-?}"
else
    warn "/etc/armbian-release nicht gefunden – ist das wirklich Armbian?"
fi

# Kernel-Typ einschätzen
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | grep -oP '^\d+\.\d+' || echo "0.0")
IS_VENDOR_KERNEL=false
IS_MODERN_MAINLINE=false  # Mainline ≥6.12 mit panthor/RKNPU Support
if [[ "$KERNEL_VER" == *-vendor-rk35xx ]] || [[ "$KERNEL_VER" == 5.10.* ]] || [[ "$KERNEL_VER" == 6.1.*rk* ]]; then
    ok "Vendor/BSP-Kernel erkannt ($KERNEL_VER) – NPU & GPU Support erwartet"
    IS_VENDOR_KERNEL=true
elif [[ "$KERNEL_VER" == 6.1.* ]]; then
    ok "Vendor/BSP-Kernel erkannt ($KERNEL_VER) – NPU & GPU Support erwartet"
    IS_VENDOR_KERNEL=true
elif awk "BEGIN {exit !($KERNEL_MAJOR >= $KERNEL_PANTHOR_MIN)}" 2>/dev/null; then
    IS_MODERN_MAINLINE=true
    if awk "BEGIN {exit !($KERNEL_MAJOR >= $KERNEL_NPU_STABLE_MIN)}" 2>/dev/null; then
        ok "Moderner Mainline-Kernel ($KERNEL_VER) – ${BOLD}NPU & GPU Support erwartet${NC}"
        info "panthor (GPU) und RKNPU (NPU) sind ab $KERNEL_NPU_STABLE_MIN stabil im Mainline"
    elif awk "BEGIN {exit !($KERNEL_MAJOR >= $KERNEL_NPU_EXPERIMENTAL_MIN)}" 2>/dev/null; then
        ok "Mainline-Kernel ($KERNEL_VER) – NPU & GPU Support möglich (experimentell)"
        info "RKNPU-Treiber ab ~$KERNEL_NPU_EXPERIMENTAL_MIN im Mainline, panthor ab ~$KERNEL_PANTHOR_MIN"
        info "Ab ${KERNEL_NPU_STABLE_MIN}+ gilt der Support als stabil"
    else
        ok "Mainline-Kernel ($KERNEL_VER) – GPU via panthor erwartet, NPU evtl. noch nicht"
        info "RKNPU-Treiber erst ab ~$KERNEL_NPU_EXPERIMENTAL_MIN im Mainline"
    fi
else
    warn "Älterer Mainline-Kernel ($KERNEL_VER) – NPU funktioniert wahrscheinlich NICHT"
    warn "GPU eingeschränkt (panfrost statt panthor für Mali G610)"
    echo ""
    info "Zwei Optionen:"
    echo -e "    ${CYAN}1.${NC} Vendor-Kernel (6.1.x): voller NPU+GPU Support, Rockchip-BSP-Patches"
    echo -e "       ${CYAN}→ sudo armbian-config --cmd KER001${NC}"
    echo -e "    ${BOLD}${GREEN}2.${NC}${BOLD} Mainline ≥6.18 (empfohlen):${NC} panthor GPU + RKNPU im Mainline, bessere Security"
    echo -e "       ${CYAN}→ sudo armbian-config --cmd KER001${NC}  (edge/current wählen)"
    ((ISSUES_FOUND++)) || true
fi

###############################################################################
#  1b. SPI-Flash & Boot-Quelle
###############################################################################

header "SPI-Flash & Boot-Quelle"

# Boot-Quelle ermitteln
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
    info "Boot-Quelle: ${BOLD}${BOOT_FROM}${NC}"

    # ── Woher kommt die Boot-Quelle? ──

    # 1. Kernel-Kommandozeile (root= Parameter, vom Bootloader übergeben)
    KCMDLINE=$(cat /proc/cmdline 2>/dev/null || true)
    KROOT=$(echo "$KCMDLINE" | grep -oP 'root=\S+' || true)
    if [[ -n "$KROOT" ]]; then
        info "Kernel root=: ${BOLD}${KROOT}${NC}  (von U-Boot an Kernel übergeben)"
    fi

    # 2. U-Boot Environment (boot_targets = Scan-Reihenfolge)
    if command -v fw_printenv &>/dev/null; then
        BOOT_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$BOOT_TARGETS" ]]; then
            info "U-Boot boot_targets: ${BOLD}${BOOT_TARGETS}${NC}"
        fi
        # devnum/devtype zeigen welches Device U-Boot tatsächlich gewählt hat
        UBOOT_DEVTYPE=$(fw_printenv devtype 2>/dev/null | cut -d= -f2 || true)
        UBOOT_DEVNUM=$(fw_printenv devnum 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$UBOOT_DEVTYPE" ]]; then
            info "U-Boot gewähltes Device: ${BOLD}${UBOOT_DEVTYPE}${UBOOT_DEVNUM:+ #${UBOOT_DEVNUM}}${NC}"
        fi
    else
        info "fw_printenv nicht installiert — U-Boot-Env nicht auslesbar"
        info "  → apt install u-boot-tools  (für fw_printenv/fw_setenv)"
    fi

    # 3. armbianEnv.txt rootdev (explizite Root-Angabe, überschreibt Autodetect)
    if [[ -f "$ARMBIAN_ENV" ]]; then
        ARMBIAN_ROOTDEV=$(grep -oP '(?<=^rootdev=).*' "$ARMBIAN_ENV" 2>/dev/null || true)
        if [[ -n "$ARMBIAN_ROOTDEV" ]]; then
            info "armbianEnv.txt rootdev: ${BOLD}${ARMBIAN_ROOTDEV}${NC}  (explizit gesetzt)"
        fi
    fi

    # 4. DeviceTree boot-device (vom Bootloader/Firmware gesetzt)
    DT_BOOT_DEV=$(cat /proc/device-tree/chosen/u-boot,spl-boot-device 2>/dev/null | tr -d '\0' || true)
    if [[ -n "$DT_BOOT_DEV" ]]; then
        info "DeviceTree SPL-Boot-Device: ${BOLD}${DT_BOOT_DEV}${NC}"
    fi

    # 5. Andere bootbare Medien auflisten
    echo ""
    info "Verfügbare Boot-Medien:"
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
            MARKER=" ${GREEN}← aktive Boot-Quelle${NC}"
        fi
        echo -e "      /dev/${BLK_NAME}  ${BLK_SIZE_GB} GB  ${BOLD}${BLK_MODEL}${NC}${MARKER}"
    done

    # ── RK3588 BootROM-Priorität (Stufe 1: Bootloader laden) ──
    echo ""
    info "RK3588 BootROM-Priorität (fest im SoC, nicht änderbar):"
    info "  Bestimmt, woher der erste Bootloader (SPL/TPL) geladen wird."
    info "  U-Boot boot_targets (änderbar via fw_setenv) bestimmen danach, wo das OS gesucht wird."

    # 1. SPI NOR Flash
    if [[ -b /dev/mtdblock0 ]]; then
        _SPI_MARKER=""
        [[ -n "${DT_BOOT_DEV:-}" ]] && [[ "$DT_BOOT_DEV" == *sfc* || "$DT_BOOT_DEV" == *spi* ]] && _SPI_MARKER=" ${GREEN}← SPL-Boot${NC}"
        echo -e "      ${GREEN}1.${NC} SPI NOR Flash (16 MB)  ${GREEN}✔ vorhanden${NC}${_SPI_MARKER}"
    else
        echo -e "      ${YELLOW}1.${NC} SPI NOR Flash (16 MB)  ${RED}✘ nicht erkannt${NC}"
    fi

    # 2. eMMC (falls bestückt)
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
        [[ "$BOOT_DISK" == "$_EMMC_DEV"* ]] && _EMMC_MARKER=" ${GREEN}← aktive Boot-Quelle${NC}"
        echo -e "      ${GREEN}2.${NC} eMMC ($_EMMC_DEV)  ${GREEN}✔ vorhanden${NC}${_EMMC_MARKER}"
    else
        echo -e "      ${YELLOW}2.${NC} eMMC  ${YELLOW}— nicht bestückt${NC}"
    fi

    # 3. SD-Karte
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
        [[ "$BOOT_DISK" == "$_SD_DEV"* ]] && _SD_MARKER=" ${GREEN}← aktive Boot-Quelle${NC}"
        echo -e "      ${GREEN}3.${NC} SD-Karte ($_SD_DEV)  ${GREEN}✔ vorhanden${NC}${_SD_MARKER}"
    else
        echo -e "      ${YELLOW}3.${NC} SD-Karte  ${YELLOW}— nicht eingesteckt${NC}"
    fi

    echo -e "      ${CYAN}↳${NC}  NVMe/USB/Netzwerk: nur über U-Boot (muss im SPI stehen)"
else
    warn "Boot-Quelle konnte nicht ermittelt werden"
fi

# SPI-Device prüfen
SPI_OK=false
if [[ -b /dev/mtdblock0 ]]; then
    ok "/dev/mtdblock0 vorhanden"

    # Größe aus sysfs
    MTD_SIZE=$(cat /sys/class/mtd/mtd0/size 2>/dev/null || echo "0")
    MTD_NAME=$(cat /sys/class/mtd/mtd0/name 2>/dev/null || echo "?")
    MTD_TYPE=$(cat /sys/class/mtd/mtd0/type 2>/dev/null || echo "?")
    if [[ "$MTD_SIZE" -gt 0 ]]; then
        info "MTD-Device: ${MTD_NAME} (${MTD_TYPE}, $((MTD_SIZE / 1024)) KB)"
    fi

    # Inhalt prüfen (erste 4 KB)
    SPI_CONTENT=$(dd if=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    if [[ -z "$(echo "$SPI_CONTENT" | tr -d '0')" ]]; then
        warn "SPI-Flash ist leer (kein Bootloader)"
    else
        SPI_OK=true

        # ── Rockchip idbloader Magic (Offset 0: "RKNS" = 0x524B4E53) ──
        RK_MAGIC=$(dd if=/dev/mtdblock0 bs=1 count=4 2>/dev/null | od -A n -t x1 | tr -d ' \n')
        if [[ "$RK_MAGIC" == "524b4e53" ]]; then
            ok "Rockchip idbloader erkannt (RKNS-Signatur)"
            # idbloader Sektor-Count (Bytes 4-5, little-endian)
            IDL_SECTORS=$(dd if=/dev/mtdblock0 bs=1 skip=4 count=2 2>/dev/null | od -A n -t u2 --endian=little | tr -d ' ')
            if [[ -n "$IDL_SECTORS" ]] && [[ "$IDL_SECTORS" -gt 0 ]]; then
                info "idbloader Größe: ${IDL_SECTORS} Sektoren ($((IDL_SECTORS * 512 / 1024)) KB)"
            fi
        fi

        # ── GPT / EFI PART Signatur (Offset 0x200) ──
        EFI_SIG=$(dd if=/dev/mtdblock0 bs=1 skip=512 count=8 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 16)
        if [[ "$EFI_SIG" == "4546492050415254" ]]; then
            ok "GPT-Partitionstabelle im SPI erkannt (EFI PART)"
        fi

        # ── U-Boot Version-String extrahieren ──
        # U-Boot bettet Klartextstrings wie "U-Boot 2024.01-armbian..." ein
        UBOOT_VER=$(strings /dev/mtdblock0 2>/dev/null | grep -oP '^U-Boot \d{4}\.\d{2}[^\s]*(\s.*)?$' | head -1 || true)
        if [[ -n "$UBOOT_VER" ]]; then
            ok "U-Boot Version: ${BOLD}${UBOOT_VER}${NC}"
            # Build-Datum extrahieren (Format: "(Mon DD YYYY - HH:MM:SS ...)" oder "YYYY-MM-DD")
            UBOOT_DATE=$(strings /dev/mtdblock0 2>/dev/null | grep -oP '\(\w{3} \d{2} \d{4} - \d{2}:\d{2}:\d{2}' | head -1 | tr -d '(' || true)
            if [[ -z "$UBOOT_DATE" ]]; then
                UBOOT_DATE=$(echo "$UBOOT_VER" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1 || true)
            fi
            if [[ -n "$UBOOT_DATE" ]]; then
                info "Build-Datum: ${BOLD}${UBOOT_DATE}${NC}"
            fi
        else
            # Fallback: weniger strenge Suche
            UBOOT_VER_LOOSE=$(strings /dev/mtdblock0 2>/dev/null | grep -m1 'U-Boot SPL\|U-Boot 20' || true)
            if [[ -n "$UBOOT_VER_LOOSE" ]]; then
                ok "U-Boot erkannt: ${BOLD}${UBOOT_VER_LOOSE}${NC}"
            else
                info "Kein U-Boot Version-String gefunden (proprietärer Loader?)"
            fi
        fi

        # Zusammenfassung SPI-Loader Typ
        if [[ "$RK_MAGIC" == "524b4e53" ]] && [[ "$EFI_SIG" == "4546492050415254" ]]; then
            info "SPI-Loader Typ: Rockchip idbloader + GPT (Standard für NVMe-Boot)"
        elif [[ "$RK_MAGIC" == "524b4e53" ]]; then
            info "SPI-Loader Typ: Rockchip idbloader (Legacy-Format)"
        elif [[ "$EFI_SIG" == "4546492050415254" ]]; then
            info "SPI-Loader Typ: GPT-Format (ohne Rockchip idbloader-Header)"
        else
            info "SPI-Loader Typ: Unbekannt"
        fi
    fi

    # Verfügbare U-Boot SPI-Images + Checksummen-Vergleich
    mapfile -t SPI_IMAGES < <(find /usr/lib/linux-u-boot-* -maxdepth 1 -type f \
        \( -name "rkspi_loader*.img" -o -name "u-boot-rockchip-spi*.bin" \) 2>/dev/null)
    if [[ ${#SPI_IMAGES[@]} -gt 0 ]]; then
        # SPI-Flash Hash berechnen (nur einmal, über die relevante Größe)
        SPI_FLASH_HASH=""
        for img in "${SPI_IMAGES[@]}"; do
            IMG_SIZE=$(stat -c%s "$img" 2>/dev/null || echo "0")
            IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))
            info "SPI-Image verfügbar: $(basename "$img") (${IMG_SIZE_MB} MB)"

            # Vergleich: lese gleiche Anzahl Bytes aus SPI wie Image-Größe
            if [[ "$IMG_SIZE" -gt 0 ]] && $SPI_OK; then
                IMG_HASH=$(md5sum "$img" 2>/dev/null | cut -d' ' -f1)
                if [[ -z "$SPI_FLASH_HASH" ]] || [[ "${LAST_IMG_SIZE:-0}" -ne "$IMG_SIZE" ]]; then
                    SPI_FLASH_HASH=$(dd if=/dev/mtdblock0 bs=1 count="$IMG_SIZE" 2>/dev/null | md5sum | cut -d' ' -f1)
                    LAST_IMG_SIZE=$IMG_SIZE
                fi
                if [[ "$IMG_HASH" == "$SPI_FLASH_HASH" ]]; then
                    ok "SPI-Flash stimmt mit $(basename "$img") überein ${GREEN}(aktuell)${NC}"
                else
                    warn "SPI-Flash weicht von $(basename "$img") ab (Update verfügbar?)"
                    info "  Flash: ${SPI_FLASH_HASH}"
                    info "  Image: ${IMG_HASH}"
                fi
            fi
        done

        # U-Boot Version aus dem Image zum Vergleich
        if [[ ${#SPI_IMAGES[@]} -gt 0 ]]; then
            IMG_UBOOT_VER=$(strings "${SPI_IMAGES[0]}" 2>/dev/null | grep -oP '^U-Boot \d{4}\.\d{2}[^\s]*(\s.*)?$' | head -1 || true)
            if [[ -n "$IMG_UBOOT_VER" ]] && [[ -n "${UBOOT_VER:-}" ]] && [[ "$IMG_UBOOT_VER" != "$UBOOT_VER" ]]; then
                info "Image-Version: ${BOLD}${IMG_UBOOT_VER}${NC} (Flash: ${UBOOT_VER})"
            fi
        fi
    else
        warn "Kein U-Boot SPI-Image in /usr/lib/linux-u-boot-*/ gefunden"
        info "Ggf. u-boot-Paket installieren: apt list --installed 'linux-u-boot-*'"
    fi
else
    warn "/dev/mtdblock0 nicht vorhanden — SPI-Flash nicht verfügbar"
    info "Ggf. Modul laden: modprobe spi-rockchip-sfc"
fi

###############################################################################
#  2. armbianEnv.txt & Overlay-Prüfung
###############################################################################

header "Armbian Boot-Konfiguration"

if [[ ! -f "$ARMBIAN_ENV" ]]; then
    fail "$ARMBIAN_ENV nicht gefunden!"
    exit 1
fi

# Overlay-Prefix
OVERLAY_PREFIX=$(grep -oP '(?<=^overlay_prefix=).*' "$ARMBIAN_ENV" 2>/dev/null || true)
if [[ -z "$OVERLAY_PREFIX" ]]; then
    warn "overlay_prefix nicht in $ARMBIAN_ENV, Standard wäre: rockchip-rk3588"
else
    ok "overlay_prefix = ${BOLD}$OVERLAY_PREFIX${NC}"
fi

# Aktive Overlays anzeigen
echo ""
CURRENT_OVERLAYS=$(get_current_overlays)
USER_OVERLAYS=$(get_user_overlays)

if [[ -n "$CURRENT_OVERLAYS" ]]; then
    info "overlays=${BOLD}$CURRENT_OVERLAYS${NC}"
else
    info "overlays= ${YELLOW}(leer – keine System-Overlays aktiv)${NC}"
fi
if [[ -n "$USER_OVERLAYS" ]]; then
    info "user_overlays=${BOLD}$USER_OVERLAYS${NC}"
fi

# Prüfe auf schädliche NPU-Overlays
# Der Vendor-DTB hat die NPU bereits mit status="okay".
# Jedes NPU-Overlay verursacht "can't request region for resource" Konflikte.
NPU_OVERLAY_CONFLICT=false
for line_key in overlays user_overlays; do
    line_val=$(grep -oP "(?<=^${line_key}=).*" "$ARMBIAN_ENV" 2>/dev/null || true)
    if [[ -n "$line_val" ]] && echo "$line_val" | grep -qiE 'npu|rknpu'; then
        fail "Schädliches NPU-Overlay in ${line_key}= gefunden: $line_val"
        fail "Der Vendor-DTB hat die NPU bereits aktiviert. Overlays verursachen Konflikte!"
        NPU_OVERLAY_CONFLICT=true
        ((ISSUES_FOUND++)) || true
    fi
done

# Prüfe auf user_overlays .dtbo Dateien
if [[ -n "$USER_OVERLAYS" ]] && [[ -d "$OVERLAY_USER_DIR" ]]; then
    for uo in $USER_OVERLAYS; do
        if [[ "$uo" == *npu* ]] || [[ "$uo" == *rknpu* ]]; then
            if [[ -f "${OVERLAY_USER_DIR}/${uo}.dtbo" ]]; then
                fail "NPU-Overlay .dtbo vorhanden: ${OVERLAY_USER_DIR}/${uo}.dtbo"
                NPU_OVERLAY_CONFLICT=true
            fi
        fi
    done
fi

if ! $NPU_OVERLAY_CONFLICT; then
    ok "Keine schädlichen NPU-Overlays aktiv (korrekt — Vendor-DTB reicht)"
fi

###############################################################################
#  3. NPU-Status prüfen
###############################################################################

header "NPU-Status"

NPU_OK=false
NPU_DRIVER=""  # "rocket" (Mainline 6.18+) oder "rknpu" (Vendor)

# ── Option 1: Rocket-Treiber (Mainline 6.18+, /dev/accel/accel0) ──
if [[ -c /dev/accel/accel0 ]]; then
    ok "NPU Accel-Device: ${BOLD}/dev/accel/accel0${NC} (Rocket-Treiber, Mainline)"
    NPU_OK=true
    NPU_DRIVER="rocket"
elif [[ -d /dev/accel ]]; then
    # Verzeichnis existiert, aber kein Device
    info "/dev/accel/ existiert, aber accel0 fehlt"
fi

# ── Option 2: RKNPU DRM-Subsystem (Vendor-Kernel, /dev/dri/renderD129) ──
NPU_DRM_PATH="$NPU_DRM_DEVICE"
if ! $NPU_OK && [[ -L "$NPU_DRM_PATH" ]]; then
    NPU_DRM_DEV=$(readlink -f "$NPU_DRM_PATH")
    NPU_DRM_NODE=$(basename "$(readlink "$NPU_DRM_PATH")")
    ok "NPU DRM-Device: ${BOLD}${NPU_DRM_NODE}${NC} → $NPU_DRM_DEV"
    NPU_OK=true
    NPU_DRIVER="rknpu"
fi

# ── Option 3: Legacy /dev/rknpu* (ältere Kernel/Treiber) ──
if ! $NPU_OK && ls /dev/rknpu* &>/dev/null; then
    ok "/dev/rknpu Device vorhanden (Legacy-Modus):"
    ls -la /dev/rknpu* 2>/dev/null | while read -r line; do echo "      $line"; done
    NPU_OK=true
    NPU_DRIVER="rknpu-legacy"
fi

if ! $NPU_OK; then
    if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
        fail "NPU nicht gefunden — /dev/accel/accel0 fehlt (Rocket-Treiber erwartet auf Kernel ≥6.18)"
    elif $IS_VENDOR_KERNEL; then
        fail "NPU nicht als DRM-Device ($NPU_DRM_PATH) oder /dev/rknpu* gefunden"
    else
        fail "NPU nicht gefunden (Kernel $KERNEL_VER — NPU erfordert Vendor 6.1 oder Mainline ≥6.18)"
    fi
    ((ISSUES_FOUND++)) || true
fi

# Kernel-Modul prüfen
if lsmod 2>/dev/null | grep -qi '^rocket '; then
    ok "rocket Kernel-Modul geladen (Mainline NPU-Treiber)"
    lsmod | grep -i '^rocket ' | while read -r line; do echo "      $line"; done
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rocket"
elif [[ -d /sys/module/rocket ]]; then
    ok "rocket ist Built-in im Kernel"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rocket"
elif lsmod 2>/dev/null | grep -qi rknpu; then
    ok "rknpu Kernel-Modul geladen"
    lsmod | grep -i rknpu | while read -r line; do echo "      $line"; done
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rknpu"
elif [[ -d /sys/module/rknpu ]]; then
    NPU_MOD_VER=$(cat /sys/module/rknpu/version 2>/dev/null || echo "?")
    ok "rknpu Built-in im Kernel (Version: ${BOLD}$NPU_MOD_VER${NC})"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rknpu"
elif zgrep -qi 'CONFIG_ROCKCHIP_RKNPU=y' /proc/config.gz 2>/dev/null; then
    ok "rknpu fest einkompiliert (CONFIG_ROCKCHIP_RKNPU=y)"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rknpu"
elif zgrep -qi 'CONFIG_DRM_ACCEL_ROCKET=m' /proc/config.gz 2>/dev/null; then
    info "rocket als Modul konfiguriert (CONFIG_DRM_ACCEL_ROCKET=m) — aber nicht geladen"
    if ! $NPU_OK; then
        info "Versuch: modprobe rocket"
    fi
elif zgrep -qi 'CONFIG_DRM_ACCEL_ROCKET=y' /proc/config.gz 2>/dev/null; then
    ok "rocket fest einkompiliert (CONFIG_DRM_ACCEL_ROCKET=y)"
    [[ -z "$NPU_DRIVER" ]] && NPU_DRIVER="rocket"
else
    if ! $NPU_OK; then
        fail "Kein NPU-Treiber gefunden (weder rocket noch rknpu)"
        ((ISSUES_FOUND++)) || true
    fi
fi

# NPU-Treiber Typ anzeigen
if [[ -n "$NPU_DRIVER" ]]; then
    case "$NPU_DRIVER" in
        rocket)
            info "NPU-Stack: ${BOLD}Rocket${NC} (Mainline, Userspace: Mesa Teflon / TFLite)"
            ;;
        rknpu)
            info "NPU-Stack: ${BOLD}RKNPU${NC} (Vendor, Userspace: rknn-toolkit2 / .rknn-Modelle)"
            ;;
        rknpu-legacy)
            info "NPU-Stack: ${BOLD}RKNPU Legacy${NC} (älterer Vendor-Treiber)"
            ;;
    esac
fi

# devfreq (NPU-Taktfrequenz) — nur bei Vendor-Kernel/rknpu
NPU_DEVFREQ="$NPU_DEVFREQ_PATH"
if [[ -d "$NPU_DEVFREQ" ]]; then
    NPU_FREQ=$(cat "$NPU_DEVFREQ/cur_freq" 2>/dev/null || echo "?")
    NPU_FREQ_MHZ=$((NPU_FREQ / 1000000))
    NPU_AVAIL=$(cat "$NPU_DEVFREQ/available_frequencies" 2>/dev/null || echo "?")
    ok "NPU-Frequenz: ${BOLD}${NPU_FREQ_MHZ} MHz${NC}"
    info "Verfügbare Frequenzen: $NPU_AVAIL"
fi

# dmesg Meldungen
echo ""
info "Kernel-Meldungen zur NPU:"
DMESG_NPU=$(dmesg 2>/dev/null | grep -iE 'rknpu|rocket|fdab0000\.npu|accel accel' | tail -$DMESG_NPU_LINES || true)
if [[ -n "$DMESG_NPU" ]]; then
    echo "$DMESG_NPU" | while read -r line; do echo "      $line"; done
    # Version aus DRM init Meldung
    NPU_VER=$(echo "$DMESG_NPU" | grep -oP 'Initialized rknpu \K[0-9.]+' | tail -1 || true)
    if [[ -z "$NPU_VER" ]]; then
        NPU_VER=$(echo "$DMESG_NPU" | grep -oP 'Initialized rocket \K[0-9.]+' | tail -1 || true)
    fi
    if [[ -z "$NPU_VER" ]]; then
        NPU_VER=$(echo "$DMESG_NPU" | grep -oP 'driver version: \K[0-9.]+' | tail -1 || true)
    fi
    if [[ -n "$NPU_VER" ]]; then
        ok "NPU-Treiber-Version: ${BOLD}$NPU_VER${NC}"
    fi
else
    warn "Keine NPU-Meldungen in dmesg gefunden"
fi

###############################################################################
#  4. GPU-Status prüfen
###############################################################################

header "GPU-Status (Mali G610)"

GPU_OK=false
GPU_DRIVER=""

# GPU ist display-subsystem (fb000000.gpu / renderD128), NICHT fdab0000.npu
GPU_DRM_PATH="$GPU_DRM_DEVICE"
if [[ -L "$GPU_DRM_PATH" ]]; then
    GPU_DRM_NODE=$(basename "$(readlink "$GPU_DRM_PATH")")
    ok "GPU DRM-Device: ${BOLD}${GPU_DRM_NODE}${NC}"
    GPU_OK=true
else
    # Fallback: Prüfe ob /dev/dri/renderD* existiert (ohne NPU mitzuzählen)
    for rd in /dev/dri/renderD*; do
        if [[ -c "$rd" ]]; then
            RD_DRIVER=$(cat "/sys/class/drm/$(basename "$rd")/device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2 || true)
            if [[ "$RD_DRIVER" != "RKNPU" ]]; then
                ok "GPU DRM-Device: ${BOLD}$(basename "$rd")${NC} (Treiber: $RD_DRIVER)"
                GPU_OK=true
                break
            fi
        fi
    done
fi

if ! $GPU_OK; then
    fail "GPU DRM-Device nicht gefunden"
    ((ISSUES_FOUND++)) || true
fi

# Kernel-Module: mali (Vendor-BSP), panfrost (Mainline open), panthor (neuerer Mainline)
for drv in mali panfrost panthor; do
    if lsmod 2>/dev/null | grep -qi "^${drv} "; then
        GPU_DRIVER="$drv"
        ok "$drv Kernel-Modul geladen"
        break
    elif [[ -d "/sys/module/$drv" ]]; then
        GPU_DRIVER="$drv"
        ok "$drv ist Built-in im Kernel"
        break
    fi
done

# Breitere Suche wenn nichts gefunden
if [[ -z "$GPU_DRIVER" ]]; then
    for drv in bifrost valhall mali_kbase; do
        if lsmod 2>/dev/null | grep -qi "$drv" || [[ -d "/sys/module/$drv" ]]; then
            GPU_DRIVER="$drv"
            ok "GPU-Treiber: ${BOLD}$drv${NC}"
            break
        fi
    done
fi

if [[ -z "$GPU_DRIVER" ]] && $GPU_OK; then
    # DRM-Device da aber kein Modul erkannt — Treiber-Name aus uevent nehmen
    GPU_DRIVER=$(cat "/sys/class/drm/card0/device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2 || echo "unbekannt")
    info "GPU-Treiber (aus uevent): ${BOLD}$GPU_DRIVER${NC}"
elif [[ -z "$GPU_DRIVER" ]]; then
    warn "Kein GPU-Treiber erkannt"
fi

# GPU-Utilisation
if [[ -f "$GPU_UTIL_PATH" ]]; then
    GPU_UTIL=$(cat "$GPU_UTIL_PATH" 2>/dev/null || echo "?")
    info "GPU-Auslastung: ${GPU_UTIL}%"
fi

# dmesg GPU
echo ""
info "Kernel-Meldungen zur GPU:"
DMESG_GPU=$(dmesg 2>/dev/null | grep -iE 'mali|panfrost|panthor|fb000000\.gpu' | tail -$DMESG_GPU_LINES || true)
if [[ -n "$DMESG_GPU" ]]; then
    echo "$DMESG_GPU" | while read -r line; do echo "      $line"; done
else
    warn "Keine GPU-Meldungen in dmesg gefunden"
fi

###############################################################################
#  5. DRI-Übersicht
###############################################################################

header "DRI-Devices (/dev/dri)"

if [[ -d /dev/dri/by-path ]]; then
    for link in /dev/dri/by-path/*-render; do
        [[ -L "$link" ]] || continue
        target=$(readlink "$link")
        name=$(basename "$link" | sed 's/-render$//')
        driver=$(cat "/sys/class/drm/$(basename "$target")/device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2 || echo "?")
        info "$(basename "$target")  ←  $name  (Treiber: ${BOLD}$driver${NC})"
    done
else
    warn "/dev/dri/by-path nicht vorhanden"
    if [[ -d /dev/dri ]]; then
        ls -la /dev/dri/ 2>/dev/null | while read -r line; do echo "      $line"; done
    fi
fi

###############################################################################
#  6. Fix-Modus
###############################################################################

if $FIX_MODE; then
    header "Fix-Modus"
    require_root

    FIXED=false

    # ── Schädliche NPU-Overlays entfernen ──
    if $NPU_OVERLAY_CONFLICT; then
        info "Entferne schädliche NPU-Overlays aus $ARMBIAN_ENV ..."

        for line_key in overlays user_overlays; do
            line_val=$(grep -oP "(?<=^${line_key}=).*" "$ARMBIAN_ENV" 2>/dev/null || true)
            if [[ -n "$line_val" ]]; then
                # Entferne NPU-bezogene Einträge
                new_val=$(echo "$line_val" | tr ' ' '\n' | grep -viE 'npu|rknpu' | tr '\n' ' ' | sed 's/ $//')
                if [[ "$new_val" != "$line_val" ]]; then
                    if [[ -z "$new_val" ]]; then
                        sed -i "/^${line_key}=/d" "$ARMBIAN_ENV"
                        ok "Zeile ${line_key}= entfernt (war nur NPU-Overlay)"
                    else
                        sed -i "s|^${line_key}=.*|${line_key}=$new_val|" "$ARMBIAN_ENV"
                        ok "${line_key}= bereinigt: $new_val"
                    fi
                    FIXED=true
                    REBOOT_NEEDED=true
                fi
            fi
        done

        # .dtbo Dateien entfernen
        for dtbo in "$OVERLAY_USER_DIR"/*npu*.dtbo "$OVERLAY_USER_DIR"/*rknpu*.dtbo; do
            if [[ -f "$dtbo" ]]; then
                rm -v "$dtbo"
                ok "Entfernt: $dtbo"
                FIXED=true
            fi
        done
    fi

    # ── NPU-Modul laden (rocket oder rknpu, je nach Kernel) ──
    if ! $NPU_OK; then
        # Welches Modul versuchen?
        if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
            TRY_NPU_MOD="rocket"
        else
            TRY_NPU_MOD="rknpu"
        fi

        if ! [[ -d /sys/module/$TRY_NPU_MOD ]]; then
            info "Versuche ${TRY_NPU_MOD} Kernel-Modul zu laden ..."
            if modprobe "$TRY_NPU_MOD" 2>/dev/null; then
                sleep $MODPROBE_WAIT
                if [[ -c /dev/accel/accel0 ]] || [[ -L "$NPU_DRM_PATH" ]] || ls /dev/rknpu* &>/dev/null 2>&1; then
                    ok "${TRY_NPU_MOD} Modul geladen – NPU ist jetzt aktiv!"
                    FIXED=true
                else
                    warn "Modul geladen, aber NPU-Device erscheint nicht (Reboot nötig?)"
                    REBOOT_NEEDED=true
                fi
            else
                warn "modprobe ${TRY_NPU_MOD} fehlgeschlagen"
                if $IS_VENDOR_KERNEL; then
                    info "Beim Vendor-Kernel ist rknpu normalerweise built-in"
                elif awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
                    info "Kernel ≥6.18 erkannt — rocket sollte verfügbar sein. Prüfe:"
                    echo -e "    ${CYAN}→ zgrep DRM_ACCEL_ROCKET /proc/config.gz${NC}"
                elif $IS_MODERN_MAINLINE; then
                    info "Kernel $KERNEL_VER ist zwischen 6.12 und 6.17 — weder rknpu noch rocket verfügbar"
                    info "Upgrade auf ≥6.18 für Rocket-NPU-Treiber:"
                    echo -e "    ${CYAN}→ apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
                    echo -e "    ${CYAN}→ # oder: armbian-config --cmd KER001${NC}"
                else
                    info "Zwei Optionen für NPU-Support:"
                    echo -e "    ${CYAN}1.${NC} Vendor-Kernel (6.1.x): ${CYAN}apt install linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx${NC}"
                    echo -e "    ${BOLD}${GREEN}2.${NC}${BOLD} Mainline ≥6.18 (empfohlen):${NC} ${CYAN}apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
                fi
            fi
        fi
    fi

    # ── Kernel-Upgrade anbieten (wenn kein Vendor/moderner Mainline) ──
    if ! $IS_VENDOR_KERNEL && ! $IS_MODERN_MAINLINE && (! $NPU_OK || ! $GPU_OK); then
        echo ""
        header "Kernel-Upgrade"
        info "Aktueller Kernel ($KERNEL_VER) hat keinen vollen NPU/GPU-Support."
        info "Suche verfügbare Kernel-Pakete ..."
        echo ""

        # Verfügbare Kernel-Pakete ermitteln
        mapfile -t EDGE_PKGS < <(apt-cache search 'linux-image.*edge.*rockchip' 2>/dev/null | sort || true)
        mapfile -t CURRENT_PKGS < <(apt-cache search 'linux-image.*current.*rockchip' 2>/dev/null | grep -v vendor | sort || true)
        mapfile -t VENDOR_PKGS < <(apt-cache search 'linux-image.*vendor.*rk35' 2>/dev/null | sort || true)

        HAS_CANDIDATES=false

        if [[ ${#EDGE_PKGS[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}${GREEN}Edge-Kernel (empfohlen für ≥6.18):${NC}"
            for pkg in "${EDGE_PKGS[@]}"; do
                PKG_NAME=$(echo "$pkg" | cut -d' ' -f1)
                # Installierte Version prüfen
                PKG_VER=$(apt-cache policy "$PKG_NAME" 2>/dev/null | grep -oP '(?<=Candidate: ).*' || echo "?")
                echo -e "    ${CYAN}${PKG_NAME}${NC}  (${PKG_VER})"
            done
            HAS_CANDIDATES=true
            echo ""
        fi

        if [[ ${#CURRENT_PKGS[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}Current-Kernel:${NC}"
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
            # Beste Option vorschlagen (Edge bevorzugt)
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
                echo -e "  ${BOLD}${YELLOW}║                    ⚠  ACHTUNG  ⚠                           ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║                                                              ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  Ein Kernel-Wechsel ist ein tiefgreifender Eingriff!         ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║                                                              ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • Das System wird einen NEUSTART benötigen                  ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • Hardware-Treiber können sich ändern                       ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • DTB/Overlays müssen ggf. angepasst werden                 ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  • Bei Problemen: alten Kernel im Boot-Menü wählen           ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║                                                              ║${NC}"
                echo -e "  ${BOLD}${YELLOW}║  Vorschlag: ${SUGGESTED_PKG}${NC}"
                echo -e "  ${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -ne "  Kernel-Paket ${BOLD}${SUGGESTED_PKG}${NC} installieren? Tippe ${BOLD}${RED}YES${NC} zum Bestätigen: "
                read -r CONFIRM
                if [[ "$CONFIRM" == "YES" ]]; then
                    echo ""
                    info "Installiere ${SUGGESTED_PKG} ..."
                    if apt-get install -y "$SUGGESTED_PKG" 2>&1 | while read -r line; do echo "      $line"; done; then
                        ok "Kernel-Paket installiert: ${BOLD}${SUGGESTED_PKG}${NC}"
                        FIXED=true
                        REBOOT_NEEDED=true

                        # Passendes DTB-Paket mitinstallieren falls vorhanden
                        DTB_PKG=$(echo "$SUGGESTED_PKG" | sed 's/linux-image/linux-dtb/')
                        if apt-cache show "$DTB_PKG" &>/dev/null; then
                            info "Installiere passendes DTB-Paket: ${DTB_PKG} ..."
                            if apt-get install -y "$DTB_PKG" 2>&1 | while read -r line; do echo "      $line"; done; then
                                ok "DTB-Paket installiert: ${BOLD}${DTB_PKG}${NC}"
                            else
                                warn "DTB-Paket Installation fehlgeschlagen — ggf. manuell nachinstallieren"
                            fi
                        fi

                        # ── Optionales SPI-Bootloader Update ──
                        # U-Boot im SPI ist weitgehend unabhängig vom Kernel.
                        # Es initialisiert Hardware (DRAM, PCIe, USB), lädt dann
                        # Kernel + DTB + initramfs aus /boot/. Das DTB-Paket (nicht
                        # U-Boot) muss zum Kernel passen.
                        # Ein SPI-Update ist nur nötig wenn:
                        #   - U-Boot zu alt für das Boot-Medium (z.B. kein NVMe-Support)
                        #   - Hardware-Init-Bugs im alten U-Boot
                        # Ansonsten ist es nice-to-have (neuere Fixes, bessere Init).

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
                        header "SPI-Bootloader (optional)"
                        info "Der SPI-Bootloader (U-Boot) ist ${BOLD}unabhängig${NC} vom Kernel."
                        info "Er initialisiert Hardware und lädt Kernel/DTB/initramfs aus /boot/."
                        info "Ein Update ist meistens ${BOLD}nicht zwingend nötig${NC}, kann aber helfen bei:"
                        echo "      - Hardware-Init-Bugs im alten U-Boot"
                        echo "      - Fehlendem Support für das Boot-Medium"
                        echo "      - Neueren Fixes und besserer Kompatibilität"

                        # Prüfe ob Boot-Medium problematisch sein könnte
                        SPI_UPDATE_RECOMMENDED=false
                        if [[ -b /dev/mtdblock0 ]] && $SPI_OK; then
                            # Prüfe ob NVMe/USB Boot aber U-Boot evtl. ohne Support
                            SPI_UBOOT_AGE=""
                            if [[ -n "${UBOOT_VER:-}" ]]; then
                                SPI_UBOOT_YEAR=$(echo "$UBOOT_VER" | grep -oP '\d{4}\.\d{2}' | head -1 || true)
                                if [[ -n "$SPI_UBOOT_YEAR" ]]; then
                                    UBOOT_YEAR_NUM=$(echo "$SPI_UBOOT_YEAR" | tr -d '.')
                                    # U-Boot vor 2023.01 hatte teilweise NVMe/USB-Boot-Probleme auf RK3588
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
                                        warn "Boot von ${BOOT_FROM} mit altem U-Boot (${UBOOT_VER:-?})!"
                                        warn "Ältere U-Boot-Versionen (<2023.01) haben bekannte NVMe/USB-Boot-Probleme."
                                        info "Ein SPI-Update wird hier ${BOLD}empfohlen${NC}."
                                    fi
                                    ;;
                            esac
                        fi

                        if [[ ${#UBOOT_CANDIDATES[@]} -gt 0 ]]; then
                            echo ""
                            info "Verfügbare U-Boot Pakete für Branch '${SUGGESTED_BRANCH}':"
                            for uc in "${UBOOT_CANDIDATES[@]}"; do
                                UC_VER=$(apt-cache policy "$uc" 2>/dev/null | grep -oP '(?<=Candidate: ).*' || echo "?")
                                UC_INSTALLED=$(apt-cache policy "$uc" 2>/dev/null | grep -oP '(?<=Installed: ).*' || echo "(none)")
                                if [[ "$UC_INSTALLED" == "(none)" ]]; then
                                    echo -e "    ${CYAN}${uc}${NC}  (${UC_VER}) — ${YELLOW}nicht installiert${NC}"
                                else
                                    echo -e "    ${CYAN}${uc}${NC}  (installiert: ${UC_INSTALLED}, verfügbar: ${UC_VER})"
                                fi
                            done

                            UBOOT_INSTALL="${UBOOT_CANDIDATES[0]}"

                            if [[ -b /dev/mtdblock0 ]]; then
                                echo ""
                                if $SPI_UPDATE_RECOMMENDED; then
                                    echo -e "  ${BOLD}${YELLOW}SPI-Update empfohlen (alter U-Boot + NVMe/USB Boot)${NC}"
                                else
                                    info "SPI-Update ist optional. Der aktuelle Bootloader funktioniert wahrscheinlich weiterhin."
                                fi
                                echo ""
                                echo -e "  ${CYAN}Was passiert:${NC}"
                                echo "    1. U-Boot Paket installieren (apt install)"
                                echo "    2. SPI-Image auf /dev/mtdblock0 flashen (dd)"
                                echo "    3. Checksumme verifizieren"
                                echo ""
                                echo -e "  ${YELLOW}Bei fehlgeschlagenem Flash: SD-Karte mit Armbian-Image → davon booten → SPI neu flashen${NC}"
                                echo ""
                                echo -ne "  SPI-Bootloader aktualisieren? [j/N]: "
                                read -r SPI_CONFIRM
                                if [[ "$SPI_CONFIRM" =~ ^[jJyY]$ ]]; then
                                    echo ""
                                    # Nochmal explizit bestätigen beim tatsächlichen Flash
                                    info "Installiere ${UBOOT_INSTALL} ..."
                                    if apt-get install -y "$UBOOT_INSTALL" 2>&1 | while read -r line; do echo "      $line"; done; then
                                        ok "U-Boot Paket installiert: ${BOLD}${UBOOT_INSTALL}${NC}"

                                        mapfile -t NEW_SPI_IMAGES < <(find /usr/lib/linux-u-boot-* -maxdepth 1 -type f \
                                            \( -name "rkspi_loader*.img" -o -name "u-boot-rockchip-spi*.bin" \) 2>/dev/null | sort -t/ -k5 -V)
                                        if [[ ${#NEW_SPI_IMAGES[@]} -gt 0 ]]; then
                                            SPI_IMG="${NEW_SPI_IMAGES[-1]}"
                                            SPI_IMG_SIZE=$(stat -c%s "$SPI_IMG" 2>/dev/null || echo "0")

                                            SPI_BEFORE_HASH=$(dd if=/dev/mtdblock0 bs=1 count="$SPI_IMG_SIZE" 2>/dev/null | md5sum | cut -d' ' -f1)
                                            SPI_IMG_HASH=$(md5sum "$SPI_IMG" 2>/dev/null | cut -d' ' -f1)

                                            if [[ "$SPI_BEFORE_HASH" == "$SPI_IMG_HASH" ]]; then
                                                ok "SPI-Flash ist bereits aktuell (Checksumme stimmt überein)"
                                            else
                                                echo ""
                                                info "Image: $(basename "$SPI_IMG") ($((SPI_IMG_SIZE / 1024 / 1024)) MB)"
                                                echo -ne "  ${BOLD}${RED}Jetzt auf SPI flashen?${NC} Tippe ${BOLD}${RED}YES${NC} zum Bestätigen: "
                                                read -r FLASH_CONFIRM
                                                if [[ "$FLASH_CONFIRM" == "YES" ]]; then
                                                    info "Flashe SPI: $(basename "$SPI_IMG") → /dev/mtdblock0 ..."
                                                    if dd if="$SPI_IMG" of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE 2>&1 | while read -r line; do echo "      $line"; done; then
                                                        sync
                                                        SPI_AFTER_HASH=$(dd if=/dev/mtdblock0 bs=1 count="$SPI_IMG_SIZE" 2>/dev/null | md5sum | cut -d' ' -f1)
                                                        if [[ "$SPI_AFTER_HASH" == "$SPI_IMG_HASH" ]]; then
                                                            ok "SPI-Flash erfolgreich aktualisiert und verifiziert"
                                                        else
                                                            fail "SPI-Flash Verifikation fehlgeschlagen!"
                                                            fail "  Erwartet: ${SPI_IMG_HASH}"
                                                            fail "  Gelesen:  ${SPI_AFTER_HASH}"
                                                            warn "Recovery: SD-Karte mit Armbian-Image → davon booten → SPI neu flashen"
                                                        fi
                                                    else
                                                        fail "SPI-Flash fehlgeschlagen!"
                                                        info "Manuell: dd if=${SPI_IMG} of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE"
                                                    fi
                                                else
                                                    info "Flash übersprungen. Paket ist installiert, manuell flashen:"
                                                    echo -e "    ${CYAN}→ sudo dd if=${SPI_IMG} of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE${NC}"
                                                fi
                                            fi
                                        else
                                            warn "Kein SPI-Image im U-Boot Paket gefunden"
                                        fi
                                    else
                                        fail "U-Boot Installation fehlgeschlagen!"
                                        info "Manuell: sudo apt install ${UBOOT_INSTALL}"
                                    fi
                                else
                                    ok "SPI-Update übersprungen."
                                    info "Später manuell möglich:"
                                    echo -e "    ${CYAN}→ sudo apt install ${UBOOT_INSTALL}${NC}"
                                    echo -e "    ${CYAN}→ sudo dd if=/usr/lib/linux-u-boot-*/rkspi_loader*.img of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE${NC}"
                                fi
                            else
                                info "/dev/mtdblock0 nicht vorhanden — SPI kann gerade nicht geflasht werden"
                                info "Paket installieren und SPI später flashen:"
                                echo -e "    ${CYAN}→ sudo apt install ${UBOOT_INSTALL}${NC}"
                                echo -e "    ${CYAN}→ modprobe spi-rockchip-sfc && dd if=... of=/dev/mtdblock0 bs=$SPI_DD_BLOCK_SIZE${NC}"
                            fi
                        else
                            info "Kein passendes U-Boot-Paket für Branch '${SUGGESTED_BRANCH}' gefunden."
                            info "Das ist OK — der aktuelle SPI-Bootloader funktioniert in der Regel weiterhin."
                            info "Bei Bedarf manuell suchen:"
                            echo -e "    ${CYAN}→ apt-cache search linux-u-boot.*rock${NC}"
                        fi
                    else
                        fail "Installation fehlgeschlagen!"
                        info "Manuell versuchen: sudo apt install ${SUGGESTED_PKG}"
                    fi
                else
                    info "Abgebrochen. Manuell installieren:"
                    echo -e "    ${CYAN}→ sudo apt install ${SUGGESTED_PKG}${NC}"
                    echo -e "    ${CYAN}→ sudo reboot${NC}"
                    if [[ -b /dev/mtdblock0 ]]; then
                        info "SPI-Bootloader Update ist optional — der aktuelle funktioniert in der Regel weiter."
                    fi
                fi
            fi
        else
            warn "Keine passenden Kernel-Pakete gefunden"
            info "Armbian-Repos prüfen oder manuell installieren:"
            echo -e "    ${CYAN}→ sudo armbian-config --cmd KER001${NC}"
            echo -e "    ${CYAN}→ apt-cache search linux-image.*rockchip${NC}"
        fi
    fi

    if ! $FIXED && [[ $ISSUES_FOUND -eq 0 ]]; then
        ok "Nichts zu fixen – alles in Ordnung"
    fi
else
    # Kein Fix-Modus – Empfehlungen ausgeben
    if [[ $ISSUES_FOUND -gt 0 ]]; then
        header "Empfehlungen"

        if $NPU_OVERLAY_CONFLICT; then
            warn "Schädliche NPU-Overlays entfernen:"
            echo -e "    ${CYAN}→ sudo $0 --fix${NC}"
        fi

        if ! $NPU_OK && ! $IS_VENDOR_KERNEL && ! $IS_MODERN_MAINLINE; then
            info "NPU benötigt einen kompatiblen Kernel:"
            echo -e "    ${CYAN}1.${NC} Vendor-Kernel (6.1.x): ${CYAN}apt install linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx${NC}"
            echo -e "    ${BOLD}${GREEN}2.${NC}${BOLD} Mainline ≥6.18 (empfohlen):${NC} ${CYAN}apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
            echo -e "    ${CYAN}   oder interaktiv: armbian-config --cmd KER001${NC}"
        elif ! $NPU_OK && $IS_MODERN_MAINLINE; then
            if awk "BEGIN {exit !(${KERNEL_MAJOR} < 6.18)}" 2>/dev/null; then
                warn "Kernel ${KERNEL_VER} ist zwischen 6.12–6.17 — NPU erfordert ≥6.18 (Rocket-Treiber)"
                info "Upgrade:"
                echo -e "    ${CYAN}→ apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64${NC}"
                echo -e "    ${CYAN}→ # Initramfs verifizieren (LUKS/Clevis!), dann reboot${NC}"
                echo -e "    ${CYAN}→ # oder interaktiv: armbian-config --cmd KER001${NC}"
            else
                info "Mainline ≥6.18 erkannt — Rocket-NPU sollte verfügbar sein. Prüfe:"
                echo -e "    ${CYAN}→ zgrep DRM_ACCEL_ROCKET /proc/config.gz${NC}  (Kernel-Config)"
                echo -e "    ${CYAN}→ sudo $0 --fix${NC}  (versucht Modul zu laden)"
                echo -e "    ${CYAN}→ dmesg | grep -iE 'rocket|accel'${NC}  (Fehlermeldungen prüfen)"
            fi
        elif ! $NPU_OK && $IS_VENDOR_KERNEL; then
            info "NPU-Treiber scheint nicht geladen:"
            echo -e "    ${CYAN}→ sudo $0 --fix${NC}  (versucht Modul zu laden)"
            echo -e "    ${CYAN}→ dmesg | grep -i rknpu${NC}  (Fehlermeldungen prüfen)"
        fi

        if ! $GPU_OK; then
            info "GPU prüfen:"
            echo -e "    ${CYAN}→ dmesg | grep -iE 'mali|panthor|panfrost'${NC}"
            if $IS_MODERN_MAINLINE; then
                echo -e "    ${CYAN}→ zgrep -E 'PANTHOR|PANFROST' /proc/config.gz${NC}  (Kernel-Config)"
            else
                echo -e "    ${CYAN}→ sudo armbian-config --cmd KER001${NC}  (Kernel prüfen)"
                info "Mainline ≥6.12 nutzt ${BOLD}panthor${NC} statt panfrost für Mali G610"
            fi
        fi
    fi
fi

###############################################################################
#  7. Zusammenfassung
###############################################################################

header "Zusammenfassung"

echo ""
KERNEL_TYPE="unbekannt"
if $IS_VENDOR_KERNEL; then
    KERNEL_TYPE="Vendor/BSP (rknpu)"
elif $IS_MODERN_MAINLINE; then
    if awk "BEGIN {exit !($KERNEL_MAJOR >= 6.18)}" 2>/dev/null; then
        KERNEL_TYPE="Mainline (panthor + Rocket NPU)"
    else
        KERNEL_TYPE="Mainline (panthor, kein NPU — ≥6.18 nötig)"
    fi
else
    KERNEL_TYPE="Mainline (älterer, eingeschränkt)"
fi
printf "  %-20s  %s\n" "Kernel:" "$KERNEL_VER ($KERNEL_TYPE)"
printf "  %-20s  %s\n" "Overlay-Prefix:" "${OVERLAY_PREFIX:-nicht gesetzt}"

if $NPU_OK; then
    NPU_SUMMARY="✔ Aktiv"
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
        echo -e "  NPU:                ${YELLOW}⚠ Nicht verfügbar (Kernel $KERNEL_VER — benötigt ≥6.18 für Rocket)${NC}"
    else
        echo -e "  NPU:                ${RED}✘ Nicht aktiv${NC}"
    fi
fi

if $GPU_OK; then
    echo -e "  GPU:                ${GREEN}✔ Aktiv${NC} (Treiber: ${GPU_DRIVER:-unbekannt})"
else
    echo -e "  GPU:                ${RED}✘ Nicht aktiv / eingeschränkt${NC}"
fi

if $SPI_OK; then
    SPI_SUMMARY="✔ Bootloader vorhanden"
    [[ -n "${UBOOT_VER:-}" ]] && SPI_SUMMARY+=" (${UBOOT_VER})"
    echo -e "  SPI-Flash:          ${GREEN}${SPI_SUMMARY}${NC}"
elif [[ -b /dev/mtdblock0 ]]; then
    echo -e "  SPI-Flash:          ${YELLOW}⚠ Leer (kein Bootloader)${NC}"
else
    echo -e "  SPI-Flash:          ${RED}✘ Nicht verfügbar${NC}"
fi
printf "  %-20s  %s\n" "Boot-Quelle:" "${BOOT_FROM:-unbekannt}"

echo ""
if $REBOOT_NEEDED; then
    echo -e "  ${YELLOW}${BOLD}⚡ NEUSTART ERFORDERLICH, damit die Änderungen wirksam werden!${NC}"
    echo -e "  ${YELLOW}   → sudo reboot${NC}"
fi

if [[ $ISSUES_FOUND -eq 0 ]] && ! $REBOOT_NEEDED; then
    echo -e "  ${GREEN}${BOLD}Alles sieht gut aus! NPU und GPU sind betriebsbereit.${NC}"
elif [[ $ISSUES_FOUND -gt 0 ]] && ! $FIX_MODE; then
    echo ""
    echo -e "  ${YELLOW}Probleme gefunden. Starte das Script mit --fix um sie zu beheben:${NC}"
    echo -e "  ${BOLD}  sudo $0 --fix${NC}"
fi

echo ""
info "Nützliche Befehle:"
echo "    cat /boot/armbianEnv.txt                           # Boot-Konfiguration"
echo "    ls -la /dev/dri/by-path/ /dev/accel/ 2>/dev/null   # DRM/Accel-Devices"
echo "    cat /sys/class/devfreq/fdab0000.npu/cur_freq       # NPU-Frequenz (Vendor)"
echo "    dmesg | grep -iE 'rknpu|rocket|fdab0000.npu|accel' # NPU Kernel-Meldungen"
echo "    dmesg | grep -iE 'mali|panthor|panfrost'           # GPU Kernel-Meldungen"
echo "    dd if=/dev/mtdblock0 bs=512 count=1 | od -t x1    # SPI-Flash Inhalt prüfen"
echo "    strings /dev/mtdblock0 | grep 'U-Boot'            # U-Boot Version im SPI"
echo "    cat /sys/class/mtd/mtd0/{size,name,type}           # MTD-Device Info"
echo "    zgrep -E 'ROCKET|RKNPU|PANTHOR' /proc/config.gz   # Kernel-Config prüfen"
echo ""
echo "  Kernel-Wechsel:"
echo "    armbian-config --cmd KER001                        # interaktiver TUI-Selector"
echo "    apt install linux-image-edge-rockchip64 \\           # direkt: Edge 6.18+ (NPU)"
echo "                linux-dtb-edge-rockchip64"
echo "    apt install linux-image-current-rockchip64 \\        # direkt: Current 6.12.x"
echo "                linux-dtb-current-rockchip64"
echo "    apt install linux-image-vendor-rk35xx \\             # direkt: Vendor 6.1.x"
echo "                linux-dtb-vendor-rk35xx"
echo ""
