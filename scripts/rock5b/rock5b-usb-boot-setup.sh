#!/bin/bash
#
# rock5b-usb-boot-setup.sh
# ========================
# Interaktives Script zum Einrichten des USB-Boots auf dem Radxa Rock 5B
# - Prüft den aktuellen Zustand des SPI-Flash
# - Flasht bei Bedarf einen U-Boot Bootloader auf SPI
# - Konfiguriert die Boot-Reihenfolge (USB vor SD/eMMC)
#
# Voraussetzung: Laufendes Armbian auf SD-Karte (Vendor Kernel 6.x)
# KEIN serieller Zugang nötig.
#
# Aufruf: sudo bash rock5b-usb-boot-setup.sh
#

set -euo pipefail

# ============================================================
# Konfiguration
# ============================================================
# Radxa offizielles SPI-Image (URL wird bei Bedarf heruntergeladen)
RADXA_SPI_IMAGE_URL="https://dl.radxa.com/rock5/sw/images/loader/rock-5b/release/rock-5b-spi-image-gd1cf491-20240523.img"
SPI_DOWNLOAD_DIR="/tmp/rock5b-spi"

# DTB-Overlay-Pfad und Overlay-Namen für SPI-Flash
DTB_OVERLAY_DIR="/boot/dtb/rockchip/overlay"
SPI_OVERLAY_NAMES=("rk3588-spi-flash" "rock-5b-spi-flash" "spi-flash")

# Armbian SPI-Image Suchpfade
ARMBIAN_SPI_CANDIDATES=(
    "/usr/lib/linux-u-boot-*/u-boot-rockchip-spi.bin"
    "/usr/lib/u-boot/rock-5b/u-boot-rockchip-spi.bin"
    "/usr/share/armbian/u-boot/rock-5b/u-boot-rockchip-spi.bin"
)

# SPI-Flash dd Block-Größe (Bytes)
SPI_DD_BLOCK_SIZE=4096

# Boot-Reihenfolge
DEFAULT_BOOT_ORDER="mmc1 nvme mmc0 scsi usb pxe dhcp spi"
USB_FIRST_BOOT_ORDER="usb mmc1 nvme mmc0 scsi pxe dhcp spi"

# U-Boot Environment Konfiguration (Armbian Rock 5B)
UBOOT_ENV_OFFSET="0xc00000"      # 12 MB ins 16 MB SPI
UBOOT_ENV_SIZE="0x20000"         # 128 KB
UBOOT_ENV_SECTOR_SIZE="0x1000"   # 4 KB Erase-Block

# lsblk Ausgabelimit
LSBLK_DISPLAY_LIMIT=30

# ============================================================
# Farben und Hilfsfunktionen
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[FEHLER]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}\n"; }
ask()     { echo -en "${YELLOW}» $* ${NC}"; }

confirm() {
    local prompt="${1:-Fortfahren?}"
    ask "$prompt [j/N]: "
    read -r answer
    [[ "$answer" =~ ^[jJyY]$ ]]
}

pause() {
    echo ""
    ask "Weiter mit Enter..."
    read -r
}

# ============================================================
# Root-Check
# ============================================================
if [[ $EUID -ne 0 ]]; then
    err "Dieses Script muss als root ausgeführt werden!"
    echo "  → sudo bash $0"
    exit 1
fi

# grep -P (Perl-Regex) wird benötigt (z.B. für mtdinfo-Parsing)
if ! echo "test123" | grep -oP '\K[0-9]+' &>/dev/null; then
    err "grep unterstützt keine Perl-Regex (-P)."
    err "Bitte GNU grep installieren: apt-get install grep"
    exit 1
fi

# ============================================================
# Cleanup-Trap
# ============================================================
CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        rm -f "$f"
    done
}
trap cleanup EXIT

# ============================================================
# Board-Erkennung
# ============================================================
header "Schritt 1: System-Check"

info "Prüfe Board-Typ..."

BOARD_NAME=""
if [[ -f /proc/device-tree/model ]]; then
    BOARD_NAME=$(tr -d '\0' < /proc/device-tree/model)
    ok "Board erkannt: ${BOLD}$BOARD_NAME${NC}"
else
    warn "Konnte Board-Modell nicht auslesen."
fi

if ! echo "$BOARD_NAME" | grep -qi "rock.5b\|rk3588"; then
    warn "Dieses Script ist für den Radxa Rock 5B (RK3588) gedacht."
    warn "Erkanntes Board: $BOARD_NAME"
    if ! confirm "Trotzdem fortfahren?"; then
        echo "Abgebrochen."
        exit 0
    fi
fi

# Kernel-Info
info "Kernel: $(uname -r)"
info "Architektur: $(uname -m)"

# ============================================================
# Prüfe ob Armbian
# ============================================================
if [[ -f /etc/armbian-release ]]; then
    source /etc/armbian-release 2>/dev/null || true
    ok "Armbian Release: ${BOARD:-unbekannt} / ${BRANCH:-unbekannt} / ${VERSION:-unbekannt}"
else
    warn "Keine Armbian-Release-Datei gefunden. Ist das wirklich Armbian?"
    if ! confirm "Trotzdem fortfahren?"; then
        exit 0
    fi
fi

# ============================================================
# SPI-Flash Status
# ============================================================
header "Schritt 2: SPI-Flash prüfen"

SPI_MTD=""
SPI_SIZE=0
SPI_EMPTY=true

info "Suche MTD-Devices (SPI-Flash)..."

if [[ -e /dev/mtd0 ]]; then
    ok "/dev/mtd0 gefunden."

    # MTD-Info auslesen
    if [[ -f /proc/mtd ]]; then
        echo ""
        info "MTD-Partitionen:"
        cat /proc/mtd
        echo ""
    fi

    SPI_MTD="/dev/mtd0"

    # Größe ermitteln
    if command -v mtdinfo &>/dev/null; then
        SPI_SIZE=$(mtdinfo /dev/mtd0 2>/dev/null | grep "Amount of eraseblocks" | head -1 | grep -oP '\(\K[0-9]+' || echo "0")
        if [[ "$SPI_SIZE" -gt 0 ]]; then
            info "SPI-Flash Größe: ca. $((SPI_SIZE / 1024 / 1024)) MB ($SPI_SIZE Bytes)"
        fi
    fi

    # Prüfe ob SPI-Flash leer (nur 0xFF Bytes = leer)
    info "Prüfe ob SPI-Flash Daten enthält (lese erste 4KB)..."
    FIRST_BYTES=$(dd if=/dev/mtd0ro bs=$SPI_DD_BLOCK_SIZE count=1 2>/dev/null | xxd -p | tr -d '\n')

    # Prüfe ob alles FF ist (= leer)
    CLEAN_BYTES="${FIRST_BYTES//f/}"
    if [[ -z "$CLEAN_BYTES" ]]; then
        SPI_EMPTY=true
        warn "SPI-Flash scheint LEER zu sein (nur 0xFF)."
    else
        SPI_EMPTY=false
        ok "SPI-Flash enthält Daten (Bootloader vorhanden)."

        # Versuche U-Boot Signatur zu finden
        if echo "$FIRST_BYTES" | grep -q "3b8cfc00\|55424f4f"; then
            info "Erkannt: Sieht nach einem RK3588 Bootloader aus."
        fi
    fi
else
    warn "/dev/mtd0 nicht gefunden!"
    echo ""
    info "Mögliche Ursachen:"
    info "  - SPI-Flash ist nicht im Device-Tree aktiviert"
    info "  - SPI-Overlay fehlt"
    echo ""
    info "Prüfe verfügbare Overlays..."

    # Suche nach SPI-Flash Overlay
    OVERLAY_DIR="$DTB_OVERLAY_DIR"
    if [[ -d "$OVERLAY_DIR" ]]; then
        SPI_OVERLAYS=$(find "$OVERLAY_DIR" -maxdepth 1 -type f \( -name "*spi*" -o -name "*flash*" \) 2>/dev/null || true)
        if [[ -n "$SPI_OVERLAYS" ]]; then
            info "Gefundene SPI-Overlays:"
            echo "$SPI_OVERLAYS" | while read -r f; do echo "    $f"; done
        fi
    fi

    # Prüfe auch in armbianEnv.txt
    if [[ -f /boot/armbianEnv.txt ]]; then
        info "Aktuelle armbianEnv.txt Overlays:"
        grep "^overlays=" /boot/armbianEnv.txt 2>/dev/null || echo "    (keine overlays gesetzt)"
    fi

    echo ""
    warn "Ohne MTD-Device kann der SPI-Flash nicht direkt geflasht werden."
    info "Optionen:"
    info "  1) SPI-Flash Overlay in /boot/armbianEnv.txt aktivieren und rebooten"
    info "  2) Per Maskrom-Modus (USB-OTG + PC) flashen"
    echo ""

    if [[ -f /boot/armbianEnv.txt ]]; then
        # Versuche SPI-Flash Overlay automatisch zu aktivieren
        FOUND_SPI_OVERLAY=""
        for ov in "${SPI_OVERLAY_NAMES[@]}"; do
            if [[ -f "$OVERLAY_DIR/${ov}.dtbo" ]]; then
                FOUND_SPI_OVERLAY="$ov"
                break
            fi
        done

        if [[ -n "$FOUND_SPI_OVERLAY" ]]; then
            info "Gefundenes SPI-Overlay: $FOUND_SPI_OVERLAY"
            if confirm "Soll das SPI-Flash Overlay aktiviert werden? (Reboot nötig)"; then
                CURRENT_OVERLAYS=$(grep "^overlays=" /boot/armbianEnv.txt 2>/dev/null | cut -d= -f2 || true)
                if echo "$CURRENT_OVERLAYS" | grep -qw "$FOUND_SPI_OVERLAY"; then
                    ok "Overlay '$FOUND_SPI_OVERLAY' ist bereits aktiviert."
                elif [[ -n "$CURRENT_OVERLAYS" ]]; then
                    sed -i "s/^overlays=.*/overlays=$CURRENT_OVERLAYS $FOUND_SPI_OVERLAY/" /boot/armbianEnv.txt
                else
                    echo "overlays=$FOUND_SPI_OVERLAY" >> /boot/armbianEnv.txt
                fi
                ok "Overlay hinzugefügt. Bitte rebooten und Script erneut starten."
                info "  → sudo reboot"
                exit 0
            fi
        else
            warn "Kein passendes SPI-Flash Overlay gefunden."
            info "Versuche alternativ, ob mtdblock-Device existiert..."
            if [[ -e /dev/mtdblock0 ]]; then
                ok "/dev/mtdblock0 existiert! Fahre fort..."
                SPI_MTD="/dev/mtdblock0"
            else
                err "Kein SPI-Flash-Zugang möglich. Bitte prüfe dein Setup."
                info "Hinweis: Manche Armbian-Images aktivieren den SPI-Flash nicht standardmäßig."
                info "Du kannst versuchen:"
                info "  modprobe spi-rockchip-sfc"
                info "  ... und dann das Script erneut starten."
                exit 1
            fi
        fi
    fi
fi

pause

# ============================================================
# Schritt 3: Aktuellen Bootloader analysieren / U-Boot SPI Image beschaffen
# ============================================================
header "Schritt 3: U-Boot SPI Image"

UBOOT_SPI_IMG=""

# Prüfe ob Armbian ein SPI-Image mitliefert
info "Suche vorhandene U-Boot SPI-Images..."

shopt -s nullglob
for pattern in "${ARMBIAN_SPI_CANDIDATES[@]}"; do
    # shellcheck disable=SC2206  # intentional glob expansion
    candidates=($pattern)
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            UBOOT_SPI_IMG="$candidate"
            ok "Armbian SPI-Image gefunden: $UBOOT_SPI_IMG"
            ls -lh "$UBOOT_SPI_IMG"
            break 2
        fi
    done
done
shopt -u nullglob

if [[ -z "$UBOOT_SPI_IMG" ]]; then
    warn "Kein vorinstalliertes SPI-Image gefunden."
    echo ""
    info "Optionen:"
    info "  1) Radxa offizielles SPI-Image herunterladen"
    info "  2) Eigenes Image angeben (Pfad)"
    info "  3) Abbrechen"
    echo ""
    ask "Wahl [1/2/3]: "
    read -r choice

    case "$choice" in
        1)
            info "Lade offizielles Radxa SPI-Image herunter..."
            SPI_URL="$RADXA_SPI_IMAGE_URL"
            DOWNLOAD_DIR="$SPI_DOWNLOAD_DIR"
            mkdir -p "$DOWNLOAD_DIR"

            if command -v wget &>/dev/null; then
                wget -O "$DOWNLOAD_DIR/rock-5b-spi-image.img" "$SPI_URL" || {
                    err "Download fehlgeschlagen!"
                    info "Bitte lade das Image manuell herunter:"
                    info "  $SPI_URL"
                    info "Und starte das Script erneut mit Option 2."
                    exit 1
                }
            elif command -v curl &>/dev/null; then
                curl -L -o "$DOWNLOAD_DIR/rock-5b-spi-image.img" "$SPI_URL" || {
                    err "Download fehlgeschlagen!"
                    exit 1
                }
            else
                err "Weder wget noch curl verfügbar!"
                exit 1
            fi
            UBOOT_SPI_IMG="$DOWNLOAD_DIR/rock-5b-spi-image.img"
            ok "Download erfolgreich: $UBOOT_SPI_IMG"
            ;;
        2)
            ask "Pfad zum SPI-Image: "
            read -r custom_path
            if [[ -f "$custom_path" ]]; then
                UBOOT_SPI_IMG="$custom_path"
                ok "Image: $UBOOT_SPI_IMG"
            else
                err "Datei nicht gefunden: $custom_path"
                exit 1
            fi
            ;;
        *)
            echo "Abgebrochen."
            exit 0
            ;;
    esac
fi

echo ""
info "Zu flashendes Image:"
ls -lh "$UBOOT_SPI_IMG"

pause

# ============================================================
# Schritt 4: SPI-Flash beschreiben
# ============================================================
header "Schritt 4: SPI-Flash beschreiben"

if [[ "$SPI_EMPTY" == false ]]; then
    warn "Der SPI-Flash enthält bereits Daten!"
    info "Der vorhandene Bootloader wird überschrieben."
fi

echo ""
echo -e "${RED}${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}  ║  ACHTUNG: Flash-Vorgang!                    ║${NC}"
echo -e "${RED}${BOLD}  ║                                              ║${NC}"
echo -e "${RED}${BOLD}  ║  - Unterbreche den Vorgang NICHT             ║${NC}"
echo -e "${RED}${BOLD}  ║  - Stelle eine stabile Stromversorgung       ║${NC}"
echo -e "${RED}${BOLD}  ║    sicher                                    ║${NC}"
echo -e "${RED}${BOLD}  ║  - Ein fehlerhafter Flash kann dazu führen,  ║${NC}"
echo -e "${RED}${BOLD}  ║    dass der Maskrom-Modus nötig wird         ║${NC}"
echo -e "${RED}${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
echo ""

if ! confirm "SPI-Flash JETZT beschreiben?"; then
    echo "Abgebrochen."
    exit 0
fi

# Prüfe ob armbian-install verfügbar ist (bevorzugt)
if command -v armbian-install &>/dev/null && [[ -n "$UBOOT_SPI_IMG" ]]; then
    info "armbian-install ist verfügbar."
    info "Nutze trotzdem direkten Flash-Weg für mehr Kontrolle."
fi

# Direkter Flash-Weg über MTD
if [[ -c "$SPI_MTD" ]]; then
    info "Flashe über MTD-Device $SPI_MTD ..."

    # Sicherung des aktuellen SPI-Inhalts
    info "Erstelle Backup des aktuellen SPI-Flash-Inhalts..."
    BACKUP_FILE=$(mktemp /tmp/spi-flash-backup-XXXXXXXX.bin)
    if dd if="${SPI_MTD}ro" of="$BACKUP_FILE" bs=$SPI_DD_BLOCK_SIZE 2>/dev/null; then
        ok "Backup gespeichert: $BACKUP_FILE"
    else
        warn "Backup konnte nicht erstellt werden (nicht kritisch)."
    fi

    # Flash-Vorgang
    if command -v flashcp &>/dev/null; then
        info "Nutze flashcp..."
        flashcp -v "$UBOOT_SPI_IMG" "$SPI_MTD"
    elif command -v mtd_debug &>/dev/null; then
        info "Nutze mtd_debug..."
        MTD_SIZE=$(wc -c < "$UBOOT_SPI_IMG")
        mtd_debug erase "$SPI_MTD" 0 "$MTD_SIZE" || {
            err "mtd_debug erase fehlgeschlagen! Flash-Vorgang abgebrochen."
            err "Backup liegt unter: $BACKUP_FILE"
            exit 1
        }
        mtd_debug write "$SPI_MTD" 0 "$MTD_SIZE" "$UBOOT_SPI_IMG" || {
            err "mtd_debug write fehlgeschlagen! SPI könnte korrumpiert sein."
            err "Backup liegt unter: $BACKUP_FILE"
            exit 1
        }
    else
        info "Nutze dd (Fallback)..."
        # Erst löschen (mit 0xFF füllen)
        flash_erase "$SPI_MTD" 0 0 2>/dev/null || {
            warn "flash_erase nicht verfügbar, versuche direktes Schreiben..."
        }
        dd if="$UBOOT_SPI_IMG" of="$SPI_MTD" bs=$SPI_DD_BLOCK_SIZE conv=fsync 2>/dev/null
    fi

    # Verifikation
    info "Verifiziere Flash-Inhalt..."
    VERIFY_FILE=$(mktemp /tmp/spi-verify-XXXXXXXX.bin)
    CLEANUP_FILES+=("$VERIFY_FILE")
    IMG_SIZE=$(wc -c < "$UBOOT_SPI_IMG")
    dd if="${SPI_MTD}ro" of="$VERIFY_FILE" bs=$SPI_DD_BLOCK_SIZE count=$(( (IMG_SIZE + 4095) / 4096 )) 2>/dev/null
    truncate -s "$IMG_SIZE" "$VERIFY_FILE"

    if cmp -s "$UBOOT_SPI_IMG" "$VERIFY_FILE"; then
        ok "Verifikation erfolgreich! SPI-Flash wurde korrekt beschrieben."
    else
        err "Verifikation FEHLGESCHLAGEN!"
        err "Die geschriebenen Daten stimmen nicht mit dem Image überein."
        err "Backup liegt unter: $BACKUP_FILE"
        warn "Bitte NICHT rebooten und das Problem zuerst untersuchen."
        exit 1
    fi

elif [[ -b "$SPI_MTD" ]]; then
    info "Flashe über Block-Device $SPI_MTD ..."
    dd if="$UBOOT_SPI_IMG" of="$SPI_MTD" bs=$SPI_DD_BLOCK_SIZE conv=fsync
    sync
    ok "Flash-Vorgang abgeschlossen (keine Verifikation über Block-Device)."
else
    err "Kein geeignetes MTD-Device gefunden!"
    exit 1
fi

ok "SPI-Flash erfolgreich beschrieben!"
echo ""

pause

# ============================================================
# Schritt 5: Boot-Reihenfolge konfigurieren
# ============================================================
header "Schritt 5: Boot-Reihenfolge konfigurieren"

info "Ziel: USB soll VOR SD-Karte und eMMC geprüft werden."
echo ""

# Prüfe ob fw_printenv / fw_setenv verfügbar
FW_ENV_AVAILABLE=false
if command -v fw_printenv &>/dev/null; then
    FW_ENV_AVAILABLE=true
    ok "fw_printenv / fw_setenv ist verfügbar."
else
    warn "fw_printenv nicht gefunden. Installiere libubootenv-tool..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        if apt-get install -y -qq libubootenv-tool 2>/dev/null; then
            FW_ENV_AVAILABLE=true
            ok "libubootenv-tool installiert."
        else
            warn "Installation fehlgeschlagen. Versuche u-boot-tools..."
            if apt-get install -y -qq u-boot-tools 2>/dev/null; then
                FW_ENV_AVAILABLE=true
                ok "u-boot-tools installiert."
            fi
        fi
    fi
fi

# fw_env.config prüfen/erstellen
if [[ "$FW_ENV_AVAILABLE" == true ]]; then
    if [[ ! -f /etc/fw_env.config ]]; then
        warn "/etc/fw_env.config existiert nicht. Erstelle Standard-Konfiguration..."
        info "Für Rock 5B mit SPI-Flash U-Boot Environment (Armbian):"
        # Armbian-spezifische Werte aus config/boards/rock-5b.conf:
        #   CONFIG_ENV_IS_IN_SPI_FLASH=y
        #   CONFIG_ENV_OFFSET=0xc00000  (12 MB ins 16 MB SPI)
        #   CONFIG_ENV_SIZE=0x20000     (128 KB)
        #   CONFIG_ENV_SECT_SIZE_AUTO=y (4 KB Erase-Block, Macronix MX25U12835F)
        # ACHTUNG: Upstream U-Boot und Radxa-offizielle Builds nutzen ggf.
        # andere Offsets (z.B. CONFIG_ENV_IS_IN_MMC statt SPI)!
        cat > /etc/fw_env.config << EOF
# Device name    Device offset    Env. size    Flash sector size
# Armbian Rock 5B: ENV im SPI NOR @ 12MB, 128KB, 4KB Sektoren
/dev/mtd0        $UBOOT_ENV_OFFSET         $UBOOT_ENV_SIZE      $UBOOT_ENV_SECTOR_SIZE
EOF
        ok "/etc/fw_env.config erstellt."
    fi

    echo ""
    info "Versuche aktuelle U-Boot Umgebungsvariablen zu lesen..."
    echo ""

    CURRENT_BOOT_TARGETS=""
    if fw_printenv boot_targets 2>/dev/null; then
        CURRENT_BOOT_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2)
        echo ""
        ok "Aktuelle boot_targets: $CURRENT_BOOT_TARGETS"
    else
        warn "Konnte boot_targets nicht lesen."
        info "Das kann bedeuten:"
        info "  - Die Environment-Offsets stimmen nicht"
        info "  - Der U-Boot nutzt Compile-Time Defaults (kein gespeichertes Env)"
        info "  - Der SPI-Flash wurde gerade erst beschrieben und hat noch kein Env"
        echo ""
        info "Standardmäßige Boot-Reihenfolge bei Armbian Rock 5B:"
        info "  mmc1 nvme mmc0 scsi usb pxe dhcp spi"
        CURRENT_BOOT_TARGETS="$DEFAULT_BOOT_ORDER"
    fi

    echo ""
    info "Gewünschte neue Reihenfolge (USB zuerst):"
    NEW_BOOT_TARGETS="$USB_FIRST_BOOT_ORDER"
    echo -e "  ${GREEN}$NEW_BOOT_TARGETS${NC}"
    echo ""
    info "Erklärung:"
    info "  usb   = USB-Massenspeicher (dein USB-Stick)"
    info "  mmc1  = SD-Karte"
    info "  nvme  = NVMe SSD"
    info "  mmc0  = eMMC"
    info "  scsi  = SATA/SCSI"
    info "  pxe   = Netzwerk-Boot (PXE)"
    info "  dhcp  = Netzwerk-Boot (DHCP)"
    info "  spi   = SPI NOR Flash"
    echo ""

    ask "Eigene Reihenfolge eingeben oder Enter für Standard: "
    read -r custom_order
    if [[ -n "$custom_order" ]]; then
        NEW_BOOT_TARGETS="$custom_order"
        info "Verwende: $NEW_BOOT_TARGETS"
    fi

    echo ""
    if confirm "Boot-Reihenfolge auf '$NEW_BOOT_TARGETS' setzen?"; then
        if fw_setenv boot_targets "$NEW_BOOT_TARGETS" 2>/dev/null; then
            ok "boot_targets erfolgreich gesetzt!"

            # Verifizierung
            VERIFY_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2 || true)
            if [[ "$VERIFY_TARGETS" == "$NEW_BOOT_TARGETS" ]]; then
                ok "Verifiziert: $VERIFY_TARGETS"
            else
                warn "Verifikation unklar. Bitte nach Reboot prüfen."
            fi
        else
            err "fw_setenv fehlgeschlagen!"
            echo ""
            info "Alternative: Boot-Reihenfolge über /boot/armbianEnv.txt konfigurieren."
        fi
    fi
else
    warn "fw_printenv/fw_setenv nicht verfügbar."
fi

# ============================================================
# Alternative/Ergänzung: armbianEnv.txt
# ============================================================
echo ""
info "Prüfe /boot/armbianEnv.txt als ergänzende Konfiguration..."

if [[ -f /boot/armbianEnv.txt ]]; then
    echo ""
    info "Aktuelle /boot/armbianEnv.txt:"
    echo "  ─────────────────────────────"
    sed 's/^/  │ /' /boot/armbianEnv.txt
    echo "  ─────────────────────────────"
    echo ""

    # Prüfe ob rootdev angepasst werden soll
    info "Falls du das Root-Dateisystem auf dem USB-Stick hast,"
    info "muss 'rootdev' in /boot/armbianEnv.txt angepasst werden."
    echo ""

    # USB-Geräte anzeigen
    info "Erkannte Block-Devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,FSTYPE 2>/dev/null | head -$LSBLK_DISPLAY_LIMIT
    echo ""

    if confirm "Möchtest du rootdev in armbianEnv.txt auf ein USB-Device setzen?"; then
        # USB-Geräte filtern
        info "Verfügbare USB-Speicher:"
        USB_DEVS=$(lsblk -dpno NAME,SIZE,TRAN 2>/dev/null | grep "usb" || true)
        if [[ -z "$USB_DEVS" ]]; then
            warn "Kein USB-Speichergerät erkannt."
            info "Stecke den USB-Stick ein und starte diesen Schritt erneut."
        else
            echo "$USB_DEVS"
            echo ""
            ask "Device für rootdev (z.B. /dev/sda1): "
            read -r usb_rootdev
            if [[ -b "$usb_rootdev" ]]; then
                # Backup
                cp /boot/armbianEnv.txt /boot/armbianEnv.txt.bak
                ok "Backup erstellt: /boot/armbianEnv.txt.bak"

                if grep -q "^rootdev=" /boot/armbianEnv.txt; then
                    sed -i "s|^rootdev=.*|rootdev=$usb_rootdev|" /boot/armbianEnv.txt
                else
                    echo "rootdev=$usb_rootdev" >> /boot/armbianEnv.txt
                fi
                ok "rootdev gesetzt auf: $usb_rootdev"
            else
                warn "Device '$usb_rootdev' existiert nicht. Überspringe."
            fi
        fi
    fi
fi

pause

# ============================================================
# Zusammenfassung
# ============================================================
header "Zusammenfassung"

echo -e "${GREEN}Durchgeführte Aktionen:${NC}"
echo ""

if [[ -n "$UBOOT_SPI_IMG" ]]; then
    echo -e "  ✓ U-Boot auf SPI-Flash geschrieben"
    echo -e "    Image: $UBOOT_SPI_IMG"
fi

if [[ "$FW_ENV_AVAILABLE" == true ]]; then
    echo -e "  ✓ Boot-Reihenfolge konfiguriert"
    FINAL_TARGETS=$(fw_printenv boot_targets 2>/dev/null | cut -d= -f2 || echo "(konnte nicht gelesen werden)")
    echo -e "    boot_targets: $FINAL_TARGETS"
fi

if [[ -f /boot/armbianEnv.txt.bak ]]; then
    echo -e "  ✓ armbianEnv.txt angepasst (Backup: armbianEnv.txt.bak)"
fi

echo ""
echo -e "${YELLOW}Nächste Schritte:${NC}"
echo ""
echo "  1. Stelle sicher, dass dein USB-Stick ein bootfähiges System enthält"
echo "     (z.B. mit Armbian geflasht via dd oder Etcher)"
echo ""
echo "  2. Stecke den USB-Stick ein"
echo ""
echo "  3. Reboot:"
echo "     → sudo reboot"
echo ""
echo "  4. Das System sollte nun vom USB-Stick booten"
echo "     (sofern ein gültiges System darauf ist)"
echo ""
echo -e "${YELLOW}Troubleshooting:${NC}"
echo ""
echo "  - Falls das System nicht vom USB bootet:"
echo "    → Prüfe ob der USB-Stick korrekt formatiert/geflasht ist"
echo "    → Versuche einen USB 2.0 Port (bessere U-Boot-Unterstützung)"
echo "    → SD-Karte entfernen und nur USB-Stick nutzen"
echo ""
echo "  - Falls das System gar nicht mehr bootet:"
echo "    → SD-Karte mit funktionierendem Armbian einlegen"
echo "    → Im Notfall: Maskrom-Modus (goldener Button) + rkdeveloptool"
echo "    → SPI-Flash Backup: ${BACKUP_FILE:-nicht erstellt}"
echo ""
echo "  - Boot-Reihenfolge zurücksetzen:"
echo "    → sudo fw_setenv boot_targets \"mmc1 nvme mmc0 scsi usb pxe dhcp spi\""
echo ""

ok "Script abgeschlossen. Viel Erfolg!"
