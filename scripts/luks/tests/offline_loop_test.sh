#!/usr/bin/env bash
# offline_loop_test.sh - hardware-free test of the offline LUKS mode (LUKS_OFFLINE_PLAN.md, section 6.2)
#
# Simulates a never-booted Raspberry Pi OS card with an image file on a loop device, applies the cloud-init
# seed like Raspberry Pi Imager 2.x, runs "luks_prepare.sh --offline" and "luks_encrypt.sh --device" against
# it and checks the result. Needs root (losetup, mount, cryptsetup). Test only: it never touches a real card.
#
# Usage: sudo ./offline_loop_test.sh --tang=<url1>,<url2> [options]
#        ./offline_loop_test.sh --help | --dry-run
#
# Non-interactive operation: the repo scripts are run directly, stdin is /dev/null (a forgotten prompt fails
# instead of hanging):
#   - luks_prepare.sh --offline=<loop> --board=<board> --allow-loop --yes --tang=<url1>,<url2>
#   - luks_encrypt.sh --device=<loop> --allow-loop --yes --tang=<url1>,<url2> --passphrase-file=<work>/passphrase
#                     --keep-backup --backup-dir=<work>/backup
#   The passphrase is generated per run and written to <work>/passphrase.
#
# With --usb-key the USB key stick unlock is tested as well: luks_prepare.sh runs with --usb-key, luks_encrypt.sh
# with --usb-key-file=<work>/usbkey (the file does not exist beforehand, the script must generate it). The
# initramfs scripts (identical to the keyfile fallback of the Ansible clevis role: hooks, local-top and
# local-bottom "clevis-keyfile", config etc/clevis-keyfile/keyfile.conf) are not run here: the local-top script
# waits for cryptroot's askpass and its passphrase FIFO and reads a stick labelled LUKSKEY, so it needs the real
# initramfs environment and hardware; that part stays a hardware test.

set -euo pipefail

# Explicit tool locations: no shims from ~/.local/bin
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
PARTED=/usr/sbin/parted
SFDISK=/usr/sbin/sfdisk
LOSETUP=/usr/sbin/losetup
CRYPTSETUP=/usr/sbin/cryptsetup
BLOCKDEV=/usr/sbin/blockdev
LSINITRAMFS=/usr/bin/lsinitramfs
UNMKINITRAMFS=/usr/bin/unmkinitramfs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUKS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Defaults and option parsing ---
_home="${HOME:-/root}"
if [ -n "${SUDO_USER:-}" ]; then
  _home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
IMAGE="${_home}/.cache/Raspberry Pi/Imager/lastdownload.cache"
WORK=""
SIZE="16G"
BOARD="pi5"
TANG_ARG=""
PREPARE_ONLY=false
KEEP=false
NEGATIVE=false
USB_KEY=false
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: sudo ./offline_loop_test.sh --tang=<url1>,<url2> [options]

Test the offline LUKS mode on an image file attached as loop device (no hardware, test only).

Options:
  --image=<path>       Raspberry Pi OS image, .img or .img.xz (default: Imager download cache,
                       ~/.cache/Raspberry Pi/Imager/lastdownload.cache)
  --work=<dir>         Parent of the work directory (default: /var/tmp); a fresh offline-loop-test.XXXXXX
                       subdirectory is created in it and removed on exit unless --keep
  --size=<size>        Size of the simulated card (default: 16G)
  --board=<model>      Board passed to luks_prepare.sh: pi5, pi4, pi3bplus, pi3b, all (default: pi5)
  --tang=<u1>,<u2>     Two tang server URLs (required unless --prepare-only or --negative)
  --prepare-only       Stop after luks_prepare.sh and its assertions
  --negative           Run only the negative tests (three images that must be refused)
  --usb-key            Also test the USB key stick unlock: luks_prepare.sh --usb-key, luks_encrypt.sh
                       --usb-key-file=<work>/usbkey; expects three keyslots instead of two and the
                       clevis-keyfile scripts and keyfile.conf (never the key) in every initramfs; the
                       scripts themselves need the initramfs and a stick, they are not run
  --keep               Do not delete the work directory on exit
  --dry-run            Print the plan and check tools and image, do nothing else (works without root)
  -h, --help           Show this help

Example:
  sudo ./offline_loop_test.sh --tang=http://tang.heidk8.elasticc.io,http://tang.roep12b.elasticc.io:9090
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --image=*) IMAGE="${arg#--image=}" ;;
    --work=*) WORK="${arg#--work=}" ;;
    --size=*) SIZE="${arg#--size=}" ;;
    --board=*) BOARD="${arg#--board=}" ;;
    --tang=*) TANG_ARG="${arg#--tang=}" ;;
    --prepare-only) PREPARE_ONLY=true ;;
    --keep) KEEP=true ;;
    --negative) NEGATIVE=true ;;
    --usb-key) USB_KEY=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Ethernet driver(s) that must be inside every initramfs (LUKS_OFFLINE_PLAN.md, section 3.6)
case "$BOARD" in
  pi5) DRIVERS=(macb) ;;
  pi4) DRIVERS=(bcmgenet) ;;
  pi3bplus) DRIVERS=(lan78xx) ;;
  pi3b) DRIVERS=(smsc95xx) ;;
  all) DRIVERS=(macb bcmgenet lan78xx smsc95xx) ;;
  *) echo "Unknown board: $BOARD (expected pi5, pi4, pi3bplus, pi3b, all)" >&2; exit 2 ;;
esac

TANG1=""
TANG2=""
if [ -n "$TANG_ARG" ]; then
  TANG1="${TANG_ARG%%,*}"
  TANG2="${TANG_ARG#*,}"
  if [ -z "$TANG1" ] || [ "$TANG2" = "$TANG_ARG" ] || [ -z "$TANG2" ]; then
    echo "--tang needs two comma separated URLs: --tang=<url1>,<url2>" >&2
    exit 2
  fi
fi
if [ "$PREPARE_ONLY" = false ] && [ "$NEGATIVE" = false ] && [ -z "$TANG_ARG" ] && [ "$DRY_RUN" = false ]; then
  echo "--tang=<url1>,<url2> is required (unless --prepare-only or --negative)" >&2
  exit 2
fi

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${YELLOW}[INFO]${NC} $*" >&2; }
die() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# --- Test result bookkeeping ---
RES_NAME=()
RES_STATUS=()
RES_DETAIL=()
FAILED=0

# record <PASS|FAIL> <name> [detail]
record() {
  RES_STATUS+=("$1")
  RES_NAME+=("$2")
  RES_DETAIL+=("${3:--}")
  if [ "$1" = PASS ]; then
    echo -e "${GREEN}[PASS]${NC} $2" >&2
  else
    FAILED=$((FAILED + 1))
    echo -e "${RED}[FAIL]${NC} $2${3:+: $3}" >&2
  fi
}

# check <name> <detail on failure> <command...>: PASS if the command succeeds
check() {
  local name="$1" detail="$2"
  shift 2
  if "$@"; then
    record PASS "$name"
  else
    record FAIL "$name" "$detail"
  fi
}

print_summary() {
  local i w_name=5 w_stat=6 w_det=6
  for i in "${!RES_NAME[@]}"; do
    [ "${#RES_NAME[$i]}" -gt "$w_name" ] && w_name="${#RES_NAME[$i]}"
    [ "${#RES_DETAIL[$i]}" -gt "$w_det" ] && w_det="${#RES_DETAIL[$i]}"
  done
  sep_line() { printf '|-%s-|-%s-|-%s-|\n' "$(printf '%*s' "$w_name" '' | tr ' ' '-')" \
    "$(printf '%*s' "$w_stat" '' | tr ' ' '-')" "$(printf '%*s' "$w_det" '' | tr ' ' '-')"; }
  echo ""
  printf '| %-*s | %-*s | %-*s |\n' "$w_name" "Check" "$w_stat" "Result" "$w_det" "Detail"
  sep_line
  for i in "${!RES_NAME[@]}"; do
    printf '| %-*s | %-*s | %-*s |\n' "$w_name" "${RES_NAME[$i]}" "$w_stat" "${RES_STATUS[$i]}" \
      "$w_det" "${RES_DETAIL[$i]}"
  done
  echo ""
  echo "Checks: ${#RES_NAME[@]}, failed: ${FAILED}"
}

# --- Image handling ---
image_is_xz() { file -b "$IMAGE" | grep -q 'XZ compressed'; }

if [ "$DRY_RUN" = true ]; then
  echo "offline_loop_test.sh dry run (no root needed, nothing is changed)"
  echo "  image:        $IMAGE"
  if [ -f "$IMAGE" ]; then
    echo "  image type:   $(file -b "$IMAGE")"
  else
    echo "  image type:   MISSING"
  fi
  echo "  card size:    $SIZE"
  echo "  board:        $BOARD (drivers: ${DRIVERS[*]})"
  echo "  tang servers: ${TANG1:-<none>} ${TANG2:-}"
  echo "  usb key:      $([ "$USB_KEY" = true ] && echo 'yes (prepare --usb-key, encrypt --usb-key-file=<work>/usbkey)' || echo no)"
  echo "  mode:         $([ "$NEGATIVE" = true ] && echo negative || { [ "$PREPARE_ONLY" = true ] && echo prepare-only || echo 'prepare + encrypt'; })"
  echo "  scripts:      $LUKS_DIR/luks_prepare.sh, $LUKS_DIR/luks_encrypt.sh"
  _missing=0
  for t in "$PARTED" "$SFDISK" "$LOSETUP" "$CRYPTSETUP" "$BLOCKDEV" "$LSINITRAMFS" "$UNMKINITRAMFS" /usr/bin/xz /usr/bin/ssh-keygen \
    /usr/bin/numfmt /usr/bin/file /usr/bin/findmnt "$LUKS_DIR/luks_prepare.sh" "$LUKS_DIR/luks_encrypt.sh"; do
    if [ -e "$t" ]; then echo "  ok:           $t"; else echo "  MISSING:      $t"; _missing=1; fi
  done
  echo "Steps: decompress, truncate, losetup -fP, write cloud-init seed, luks_prepare.sh --offline --allow-loop,"
  echo "       assertions, luks_encrypt.sh --device --allow-loop, assertions, cleanup."
  [ "$USB_KEY" = true ] && echo "       (--usb-key: both scripts get the USB key option, extra assertions on key file, keyslots, initramfs, root files)"
  [ -f "$IMAGE" ] || _missing=1
  exit "$_missing"
fi

[ "$EUID" -eq 0 ] || die "Run as root (sudo): losetup, mount and cryptsetup need it."
[ -f "$IMAGE" ] || die "Image not found: $IMAGE (use --image=<path>)"
for t in "$PARTED" "$SFDISK" "$LOSETUP" "$CRYPTSETUP" "$BLOCKDEV" "$LSINITRAMFS" "$UNMKINITRAMFS" /usr/bin/xz /usr/bin/ssh-keygen \
  /usr/bin/numfmt /usr/bin/file /usr/bin/findmnt; do
  [ -x "$t" ] || die "Required tool missing: $t"
done
[ -x "$LUKS_DIR/luks_prepare.sh" ] || die "Not executable: $LUKS_DIR/luks_prepare.sh"
[ -x "$LUKS_DIR/luks_encrypt.sh" ] || die "Not executable: $LUKS_DIR/luks_encrypt.sh"

SIZE_BYTES="$(numfmt --from=iec "$SIZE")" || die "Invalid --size: $SIZE"

# --- Work directory and cleanup ---
# Always a fresh subdirectory, so cleanup never deletes anything the user already had
mkdir -p "${WORK:-/var/tmp}"
WORK="$(mktemp -d "${WORK:-/var/tmp}/offline-loop-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
MNT="${WORK}/mnt"
MNT_ROOT="${MNT}/root"
MNT_BOOT="${MNT}/boot"
mkdir -p "$MNT_ROOT" "$MNT_BOOT"

LOOP=""
MAPPER="offtest_root"
OPENED_VG=""
MAPPER_OPEN=false

# Unmount everything below the work directory (deepest first)
unmount_all() {
  local m
  while read -r m; do
    umount "$m" 2>/dev/null || true
  done < <(findmnt -rn -o TARGET | grep -F "${WORK}/" | sort -r || true)
}

close_encrypted() {
  if [ -n "$OPENED_VG" ]; then
    vgchange -an "$OPENED_VG" >/dev/null 2>&1 || true
    OPENED_VG=""
  fi
  if [ "$MAPPER_OPEN" = true ]; then
    "$CRYPTSETUP" close "$MAPPER" >/dev/null 2>&1 || true
    MAPPER_OPEN=false
  fi
}

detach_loop() {
  if [ -n "$LOOP" ]; then
    "$LOSETUP" -d "$LOOP" 2>/dev/null || true
    LOOP=""
  fi
}

cleanup() {
  local rc=$?
  set +e
  unmount_all
  close_encrypted
  detach_loop
  if [ "$KEEP" = true ]; then
    info "Work directory kept: $WORK"
  elif findmnt -rn -o TARGET | grep -qF "${WORK}/"; then
    echo "[WARN] Something is still mounted below $WORK, not deleting it" >&2
  else
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Seed material ---
SSH_KEY="${WORK}/id_offline_test"
ssh-keygen -q -t ed25519 -N '' -C offline-loop-test -f "$SSH_KEY"
PASS="offline-test-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"

# Tang servers for the scripts; the negative tests are refused before tang is used, so a dummy is enough there
TANG_OPT="${TANG_ARG:-http://tang.invalid,http://tang.invalid}"
printf '%s\n' "$PASS" > "${WORK}/passphrase"
chmod 600 "${WORK}/passphrase"
mkdir -p "${WORK}/backup"

# --- Image and loop device helpers ---

# make_card <file>: decompress or copy the source image, grow the file to the card size
make_card() {
  local dst="$1" img_bytes
  if image_is_xz; then
    info "Decompressing $IMAGE -> $dst"
    xz -dc "$IMAGE" > "$dst"
  else
    info "Copying $IMAGE -> $dst"
    cp --sparse=always --reflink=auto "$IMAGE" "$dst"
  fi
  img_bytes="$(stat -c %s "$dst")"
  [ "$img_bytes" -lt "$SIZE_BYTES" ] || die "Image ($img_bytes bytes) is not smaller than --size=$SIZE"
  truncate -s "$SIZE" "$dst"
}

# attach_card <file>: sets LOOP
attach_card() {
  LOOP="$("$LOSETUP" -fP --show "$1")"
  local i
  for i in $(seq 1 50); do
    [ -b "${LOOP}p2" ] && break
    sleep 0.2
  done
  [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || die "Partitions of $LOOP did not appear"
  info "Card attached as $LOOP"
}

# mount_boot <ro|rw>: only p1 on MNT_BOOT (p2 is LUKS after the encrypt step)
mount_boot() {
  if [ "$1" = ro ]; then mount -o ro "${LOOP}p1" "$MNT_BOOT"; else mount "${LOOP}p1" "$MNT_BOOT"; fi
}

# mount_card <ro|rw>: p2 on MNT_ROOT, p1 on MNT_BOOT
mount_card() {
  if [ "$1" = ro ]; then
    mount -o ro,noload "${LOOP}p2" "$MNT_ROOT"
    mount -o ro "${LOOP}p1" "$MNT_BOOT"
  else
    mount "${LOOP}p2" "$MNT_ROOT"
    mount "${LOOP}p1" "$MNT_BOOT"
  fi
}

umount_card() {
  umount "$MNT_BOOT" 2>/dev/null || true
  umount "$MNT_ROOT" 2>/dev/null || true
}

# seed_boot: write the cloud-init seed on the mounted boot partition like Imager 2.x does
seed_boot() {
  local pub cmd
  pub="$(cat "${SSH_KEY}.pub")"
  cat > "${MNT_BOOT}/user-data" <<EOF
#cloud-config
hostname: offline-test
manage_etc_hosts: true
enable_ssh: true
ssh_pwauth: false
users:
  - name: administrator
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,sudo
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${pub}
EOF
  cat > "${MNT_BOOT}/meta-data" <<'EOF'
instance_id: rpi-imager-test
EOF
  cat > "${MNT_BOOT}/network-config" <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
EOF
  # cmdline.txt: one line, keep " resize", replace any previous ds= parameter
  cmd="$(tr -d '\n' < "${MNT_BOOT}/cmdline.txt")"
  cmd="$(echo "$cmd" | sed -E 's/ ds=nocloud;i=[^ ]*//; s/[[:space:]]+$//')"
  if ! echo "$cmd" | grep -Eq '(^| )resize( |$)'; then
    cmd="${cmd} resize"
  fi
  echo "${cmd} ds=nocloud;i=rpi-imager-test" > "${MNT_BOOT}/cmdline.txt"
}

# disk_id <dev>: 8 hex digits, lowercase, without 0x
disk_id() { "$SFDISK" --disk-id "$1" | sed 's/^0x//' | tr 'A-F' 'a-f'; }

# end_sector <dev> <partnum>
end_sector() {
  "$PARTED" -m -s "$1" unit s print | awk -F: -v n="$2" '$1 == n { gsub("s", "", $3); print $3 }'
}

# snap_root_state <outfile>: first-boot relevant state of the mounted root
snap_root_state() {
  local out="$1" f
  {
    if [ -L "${MNT_ROOT}/etc/resolv.conf" ]; then
      echo "resolv.conf: symlink $(readlink "${MNT_ROOT}/etc/resolv.conf")"
    elif [ -e "${MNT_ROOT}/etc/resolv.conf" ]; then
      echo "resolv.conf: file $(sha256sum < "${MNT_ROOT}/etc/resolv.conf")"
    else
      echo "resolv.conf: absent"
    fi
    for f in etc/machine-id var/lib/dbus/machine-id; do
      if [ -L "${MNT_ROOT}/${f}" ]; then
        echo "${f}: symlink $(readlink "${MNT_ROOT}/${f}")"
      elif [ -e "${MNT_ROOT}/${f}" ]; then
        echo "${f}: file $(cat "${MNT_ROOT}/${f}")"
      else
        echo "${f}: absent"
      fi
    done
  } > "$out"
}

# fresh_card <label> <build-from-base: yes|no>: build, attach and seed a card; sets LOOP, ORIG_DISK_ID
fresh_card() {
  local label="$1" img="${WORK}/card.img"
  if [ "${2:-no}" = yes ]; then
    cp --sparse=always --reflink=auto "${WORK}/base.img" "$img"
    truncate -s "$SIZE" "$img"
  else
    make_card "$img"
  fi
  attach_card "$img"
  ORIG_DISK_ID="$(disk_id "$LOOP")"
  mount_card rw
  seed_boot
  snap_root_state "${WORK}/state.before.${label}"
  sync
  umount_card
}

drop_card() {
  unmount_all
  detach_loop
  rm -f "${WORK}/card.img"
}

# --- Assertions ---

assert_partition() {  # <stage>
  local want have total
  total="$("$BLOCKDEV" --getsz "$LOOP")"
  want=$((total - 1))
  [ "$want" -gt 4294967295 ] && want=4294967295
  have="$(end_sector "$LOOP" 2)"
  check "$1: partition 2 ends at last sector" "end ${have}, expected ${want}" [ "$have" = "$want" ]
}

assert_boot() {  # <stage>; boot partition mounted
  local stage="$1" id cmd
  id="$(disk_id "$LOOP")"
  cmd="$(cat "${MNT_BOOT}/cmdline.txt")"
  check "$stage: new disk ID differs from original" "still ${id}" [ "$id" != "$ORIG_DISK_ID" ]
  check "$stage: no ' resize' in cmdline.txt" "cmdline: ${cmd}" \
    bash -c '! printf "%s" "$1" | grep -Eq "(^| )resize( |\$)"' _ "$cmd"
  check "$stage: ds=nocloud;i= kept in cmdline.txt" "cmdline: ${cmd}" \
    bash -c 'printf "%s" "$1" | grep -q "ds=nocloud;i="' _ "$cmd"
  check "$stage: old disk ID gone from cmdline.txt" "found ${ORIG_DISK_ID}" \
    bash -c '! printf "%s" "$1" | grep -qi "$2"' _ "$cmd" "$ORIG_DISK_ID"
  if [ "$stage" = prepare ]; then
    check "$stage: new disk ID in cmdline.txt" "cmdline: ${cmd}" \
      bash -c 'printf "%s" "$1" | grep -qi "PARTUUID=$2-02"' _ "$cmd" "$id"
  fi
}

assert_root() {  # <stage> <label>; root mounted at MNT_ROOT (plain or opened LV)
  local stage="$1" label="$2" id
  id="$(disk_id "$LOOP")"
  snap_root_state "${WORK}/state.after.${label}"
  if [ "$stage" = prepare ]; then
    check "$stage: new disk ID in fstab" "fstab lacks ${id}-01/-02 or has ${ORIG_DISK_ID}" \
      bash -c 'grep -qi "PARTUUID=$2-0[12]" "$1/etc/fstab" && ! grep -qi "$3" "$1/etc/fstab"' _ \
      "$MNT_ROOT" "$id" "$ORIG_DISK_ID"
  fi
  check "$stage: machine-id is 'uninitialized'" "$(cat "${MNT_ROOT}/etc/machine-id" 2>/dev/null || echo absent)" \
    [ "$(cat "${MNT_ROOT}/etc/machine-id" 2>/dev/null)" = uninitialized ]
  check "$stage: no SSH host keys" "$(compgen -G "${MNT_ROOT}/etc/ssh/ssh_host_*" | tr '\n' ' ')" \
    bash -c '! compgen -G "$1/etc/ssh/ssh_host_*" >/dev/null' _ "$MNT_ROOT"
  check "$stage: no /var/lib/cloud" "exists" [ ! -e "${MNT_ROOT}/var/lib/cloud" ]
  check "$stage: no policy-rc.d" "usr/sbin/policy-rc.d exists" [ ! -e "${MNT_ROOT}/usr/sbin/policy-rc.d" ]
  check "$stage: no qemu binary" "qemu-aarch64* left in usr/bin" \
    bash -c '! compgen -G "$1/usr/bin/qemu-aarch64*" >/dev/null' _ "$MNT_ROOT"
  check "$stage: resolv.conf and dbus machine-id unchanged" "$(diff "${WORK}/state.before.${label}" \
    "${WORK}/state.after.${label}" 2>&1 | tr '\n' ' ')" \
    diff -q "${WORK}/state.before.${label}" "${WORK}/state.after.${label}"
}

# kmod_listed <modules.* file> <name>: is the module named in a modules.builtin / modules.dep style file?
# '-' and '_' are equivalent in module names.
kmod_listed() {
  local want="${2//-/_}"
  awk -F: '{ print $1 }' "$1" | sed -E 's#.*/##; s#\.ko.*$##; s#-#_#g' | grep -qx "$want"
}

# find_kfile <kver> <name> <extract dir> <use root: yes|no>: path of modules.<name> for the kernel, preferring the
# mounted root (full module list), else the copy inside the extracted initramfs
find_kfile() {
  local kver="$1" name="$2" dir="$3" use_root="$4" f
  if [ "$use_root" = yes ]; then
    for f in "${MNT_ROOT}/lib/modules/${kver}/${name}" "${MNT_ROOT}/usr/lib/modules/${kver}/${name}"; do
      [ -f "$f" ] && { echo "$f"; return 0; }
    done
  fi
  find "$dir" -path "*/lib/modules/${kver}/${name}" -type f 2>/dev/null | head -1
}

# check_drivers <stage> <image> <listing> <use root>: board network drivers of one initramfs image.
# kfile_source <path>: "root", "image" or "none", for the detail column
kfile_source() {
  if [ -z "$1" ]; then echo none
  elif [ "${1#"$MNT_ROOT"/}" != "$1" ]; then echo root
  else echo image
  fi
}

# Rule: builtin in the kernel -> fine; else a module (listed in modules.dep) -> must be <name>.ko* in the image;
# else skipped with a note. FAIL if a needed module is missing or the image has no driver of the board at all.
check_drivers() {
  local stage="$1" f="$2" list="$3" use_root="$4" name kver tmp builtin dep drv re
  local notes=() missing=() present=0
  name="$(basename "$f")"
  kver="$(grep -oE '^(usr/)?lib/modules/[^/]+/' "$list" | head -1 | sed -E 's#^(usr/)?lib/modules/##; s#/$##' || true)"
  if [ -z "$kver" ]; then
    record FAIL "$stage: $name network driver" "no usr/lib/modules/<kver>/ in the image"
    return 0
  fi
  tmp="$(mktemp -d "${WORK}/unmk.XXXXXX")"
  "$UNMKINITRAMFS" "$f" "$tmp" >/dev/null 2>&1 || true
  builtin="$(find_kfile "$kver" modules.builtin "$tmp" "$use_root")"
  dep="$(find_kfile "$kver" modules.dep "$tmp" "$use_root")"
  # where the module indexes came from (root, image or nowhere): shown in the detail column
  notes+=("builtin=$(kfile_source "$builtin")" "dep=$(kfile_source "$dep")")
  for drv in "${DRIVERS[@]}"; do
    re="${drv//[-_]/[-_]}"
    if [ -n "$builtin" ] && kmod_listed "$builtin" "$drv"; then
      notes+=("${drv}=builtin"); present=$((present + 1))
    elif [ -n "$dep" ] && kmod_listed "$dep" "$drv"; then
      if grep -Eq "/${re}\.ko" "$list"; then
        notes+=("${drv}=module"); present=$((present + 1))
      else
        notes+=("${drv}=MISSING"); missing+=("$drv")
      fi
    else
      notes+=("${drv}=skipped(not in kernel)")
    fi
  done
  rm -rf "$tmp"
  if [ "${#missing[@]}" -gt 0 ]; then
    record FAIL "$stage: $name network driver (${kver})" "module missing in image: ${missing[*]} (${notes[*]})"
  elif [ "$present" -eq 0 ]; then
    record FAIL "$stage: $name network driver (${kver})" "no driver of board ${BOARD} (${notes[*]})"
  else
    record PASS "$stage: $name network driver (${kver})" "${notes[*]}"
  fi
}

# assert_initramfs_usbkey <stage> <image name> <listing>: clevis-keyfile scripts and config in (or not in) one
# initramfs; the key itself (etc/clevis-keyfile/fallback.key) must never be in an image
assert_initramfs_usbkey() {
  local stage="$1" name="$2" list="$3" p
  for p in scripts/local-top/clevis-keyfile scripts/local-bottom/clevis-keyfile etc/clevis-keyfile/keyfile.conf; do
    if [ "$USB_KEY" = true ]; then
      check "$stage: $name has $p" "missing in the image" grep -Eq "(^|/)${p//./\\.}\$" "$list"
    else
      check "$stage: $name has no $p" "present without --usb-key" \
        bash -c '! grep -Eq "(^|/)$2\$" "$1"' _ "$list" "${p//./\\.}"
    fi
  done
  check "$stage: $name has no etc/clevis-keyfile/fallback.key" "the key is inside the image" \
    bash -c '! grep -Eq "(^|/)etc/clevis-keyfile/fallback\.key\$" "$1"' _ "$list"
}

assert_initramfs() {  # <stage> <root mounted: yes|no>; boot partition mounted
  local stage="$1" use_root="${2:-no}" f list n=0
  list="${WORK}/initramfs.list"
  for f in "${MNT_BOOT}"/initramfs*; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    "$LSINITRAMFS" "$f" > "$list" 2>/dev/null || true
    check "$stage: $(basename "$f") has cryptroot/crypttab" \
      "etc/crypttab present: $(grep -c '^etc/crypttab$' "$list" || true)" \
      grep -q 'cryptroot/crypttab' "$list"
    check "$stage: $(basename "$f") has clevis" "no bin/clevis in the image" grep -q 'bin/clevis' "$list"
    check_drivers "$stage" "$f" "$list" "$use_root"
    assert_initramfs_usbkey "$stage" "$(basename "$f")" "$list"
  done
  if [ "$n" -eq 0 ]; then
    record FAIL "$stage: initramfs images on boot partition" "none found"
  fi
}

assert_luks_keyslots() {
  local n want=2 desc="two keyslots"
  if [ "$USB_KEY" = true ]; then want=3; desc="three keyslots (passphrase, clevis, USB key)"; fi
  local dump="" err="" try
  # the partition nodes may be re-read right after luks_encrypt.sh has closed the device: settle and retry
  for try in 1 2 3 4 5; do
    udevadm settle 2>/dev/null || true
    if dump="$(LC_ALL=C "$CRYPTSETUP" luksDump "${LOOP}p2" 2>"${WORK}/luksdump.err")"; then err=""; break; fi
    err="try ${try}: $(tr '\n' ' ' < "${WORK}/luksdump.err")"
    sleep 1
  done
  n="$(grep -cE '^\s+[0-9]+: luks2$' <<<"$dump" || true)"
  check "encrypt: luksDump shows ${desc}" "found ${n}${err:+ (luksDump: ${err})}" [ "$n" = "$want" ]
}

# assert_usbkey_file: the key file generated by luks_encrypt.sh --usb-key-file exists, is one line of 64 base64
# characters with mode 600, and opens the LUKS device (--test-passphrase, first line without trailing newline)
assert_usbkey_file() {
  local f="${WORK}/usbkey" lines len mode
  check "encrypt: usb key file exists" "missing: ${f}" [ -f "$f" ]
  [ -f "$f" ] || return 0
  lines="$(awk 'END { print NR }' "$f")"   # counts a last line without newline too (wc -l would not)
  len="$(head -n1 "$f" | tr -d '\n' | wc -c)"
  mode="$(stat -c %a "$f")"
  check "encrypt: usb key file has 64 characters" "first line has ${len} characters" [ "$len" = 64 ]
  check "encrypt: usb key file is one base64 line" "${lines} line(s)" \
    bash -c '[ "$2" = 1 ] && head -n1 "$1" | grep -Eq "^[A-Za-z0-9+/=]{64}\$"' _ "$f" "$lines"
  check "encrypt: usb key file has mode 600" "mode ${mode}" [ "$mode" = 600 ]
  check "encrypt: cryptsetup open --test-passphrase with the usb key" "key from ${f} does not open ${LOOP}p2" \
    bash -c 'head -n1 "$1" | tr -d "\n" | "$2" open --test-passphrase --key-file=- "$3"' _ "$f" "$CRYPTSETUP" "${LOOP}p2"
}

# assert_usbkey_root <stage>: USB key files on the mounted root. luks.conf and keyfile.conf exist after prepare
# already; the master key and the writer script only after encrypt (the key is created by luks_encrypt.sh).
assert_usbkey_root() {
  local stage="$1" conf="${MNT_ROOT}/root/luks-staged/luks.conf" kc="${MNT_ROOT}/etc/clevis-keyfile/keyfile.conf"
  local host="offline-test" hook="${MNT_ROOT}/etc/initramfs-tools/hooks/clevis-keyfile"
  if [ "$USB_KEY" != true ]; then
    check "$stage: luks.conf has no USB_KEY=\"yes\"" "see ${conf}" bash -c '! grep -qx "USB_KEY=\"yes\"" "$1"' _ "$conf"
    check "$stage: no etc/clevis-keyfile/keyfile.conf on the root" "exists" [ ! -e "$kc" ]
    return 0
  fi
  check "$stage: luks.conf has USB_KEY=\"yes\"" "see ${conf}" grep -qx 'USB_KEY="yes"' "$conf"
  check "$stage: luks.conf has USB_KEY_LABEL=\"LUKSKEY\"" "see ${conf}" grep -qx 'USB_KEY_LABEL="LUKSKEY"' "$conf"
  check "$stage: luks.conf has USB_KEY_HOST=\"${host}\" (hostname from user-data)" "see ${conf}" \
    grep -qx "USB_KEY_HOST=\"${host}\"" "$conf"
  check "$stage: hooks/clevis-keyfile is executable" "see ${hook}" [ -x "$hook" ]
  check "$stage: keyfile.conf has USB=1" "see ${kc}" grep -qx 'USB=1' "$kc"
  check "$stage: keyfile.conf has HOST=${host}" "see ${kc}" grep -Eqx "HOST=['\"]?${host}['\"]?" "$kc"
  check "$stage: keyfile.conf has USB_LABEL=LUKSKEY" "see ${kc}" grep -Eqx "USB_LABEL=['\"]?LUKSKEY['\"]?" "$kc"
  if [ "$stage" = encrypt ]; then
    check "$stage: root has /etc/clevis-keyfile/fallback.key equal to the key file" "differs from ${WORK}/usbkey" \
      bash -c 'cmp -s <(head -n1 "$1" | tr -d "\n") "$2"' _ "${WORK}/usbkey" "${MNT_ROOT}/etc/clevis-keyfile/fallback.key"
    check "$stage: fallback.key has mode 600" "mode $(stat -c %a "${MNT_ROOT}/etc/clevis-keyfile/fallback.key" 2>/dev/null || echo absent)" \
      [ "$(stat -c %a "${MNT_ROOT}/etc/clevis-keyfile/fallback.key" 2>/dev/null)" = 600 ]
    check "$stage: /root/clevis_keyfile_write_usb.sh is executable" "missing or not executable" \
      [ -x "${MNT_ROOT}/root/clevis_keyfile_write_usb.sh" ]
  fi
}

# open_encrypted: open LUKS and LVM of p2, mount the root LV read-only on MNT_ROOT
open_encrypted() {
  local lv
  if ! printf '%s' "$PASS" | "$CRYPTSETUP" open "${LOOP}p2" "$MAPPER" --key-file=-; then
    return 1
  fi
  MAPPER_OPEN=true
  OPENED_VG="$(pvs --noheadings -o vg_name "/dev/mapper/${MAPPER}" 2>/dev/null | tr -d ' ' || true)"
  if [ -n "$OPENED_VG" ]; then
    vgchange -ay "$OPENED_VG" >/dev/null 2>&1 || true
    lv="$(lvs --noheadings -o lv_path "$OPENED_VG" 2>/dev/null | head -1 | tr -d ' ' || true)"
  else
    lv="/dev/mapper/${MAPPER}"
  fi
  [ -n "$lv" ] || return 1
  mount -o ro,noload "$lv" "$MNT_ROOT"
}

# run_logged <log> <command...>: stdin from /dev/null, show output, keep a log, return the command's exit code
run_logged() {
  local log="$1" rc=0
  shift
  "$@" < /dev/null 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
  return "$rc"
}

# --- Positive run ---
run_positive() {
  local rc=0
  if [ "$PREPARE_ONLY" = true ]; then
    info "=== Positive run: prepare only, ${SIZE} card ==="
  else
    info "=== Positive run: prepare + encrypt, ${SIZE} card ==="
  fi
  fresh_card main no

  # luks_prepare.sh --offline
  local prep_extra=() enc_extra=()
  if [ "$USB_KEY" = true ]; then
    prep_extra=(--usb-key)
    enc_extra=("--usb-key-file=${WORK}/usbkey")
  fi
  info "Running luks_prepare.sh --offline=$LOOP --board=$BOARD --allow-loop --yes ${prep_extra[*]}"
  run_logged "${WORK}/prepare.log" \
    "$LUKS_DIR/luks_prepare.sh" "--offline=${LOOP}" "--board=${BOARD}" --allow-loop --yes \
    "--tang=${TANG_OPT}" "${prep_extra[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record FAIL "prepare: luks_prepare.sh --offline exits 0" "exit code ${rc}, log ${WORK}/prepare.log"
  else
    record PASS "prepare: luks_prepare.sh --offline exits 0"
    assert_partition prepare
    mount_card ro
    assert_boot prepare
    assert_root prepare main
    assert_usbkey_root prepare
    assert_initramfs prepare yes
    umount_card
  fi

  [ "$PREPARE_ONLY" = true ] && return 0
  [ "$rc" -eq 0 ] || return 0

  # luks_encrypt.sh --device
  info "Running luks_encrypt.sh --device=$LOOP --allow-loop --yes --passphrase-file --keep-backup ${enc_extra[*]}"
  rc=0
  run_logged "${WORK}/encrypt.log" \
    "$LUKS_DIR/luks_encrypt.sh" "--device=${LOOP}" --allow-loop --yes "--tang=${TANG_OPT}" \
    "--passphrase-file=${WORK}/passphrase" --keep-backup "--backup-dir=${WORK}/backup" \
    "${enc_extra[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record FAIL "encrypt: luks_encrypt.sh --device exits 0" "exit code ${rc}, log ${WORK}/encrypt.log"
    return 0
  fi
  record PASS "encrypt: luks_encrypt.sh --device exits 0"
  assert_partition encrypt
  assert_luks_keyslots
  [ "$USB_KEY" = true ] && assert_usbkey_file
  mount_boot ro
  assert_boot encrypt
  if open_encrypted; then
    assert_initramfs encrypt yes
    assert_root encrypt main
    assert_usbkey_root encrypt
  else
    assert_initramfs encrypt no
    record FAIL "encrypt: open LUKS and mount root with the test passphrase" "see ${WORK}/encrypt.log"
  fi
  unmount_all
  close_encrypted
}

# --- Negative tests ---
# neg_case <name> <mutation function>
neg_case() {
  local name="$1" mutate="$2" rc=0 out msg id_after end_before end_after
  info "=== Negative test: $name ==="
  fresh_card "neg" yes
  mount_card rw
  "$mutate"
  sync
  umount_card
  end_before="$(end_sector "$LOOP" 2)"
  out="${WORK}/neg.$(echo "$name" | tr -c 'a-zA-Z0-9\n' '_').log"
  "$LUKS_DIR/luks_prepare.sh" "--offline=${LOOP}" "--board=${BOARD}" --allow-loop --yes \
    "--tang=${TANG_OPT}" < /dev/null > "$out" 2>&1 || rc=$?
  msg="$(sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -E 'FAIL|refus|Refus|ERROR|Error' | tail -1 || true)"
  [ -n "$msg" ] || msg="$(sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -v '^[[:space:]]*$' | tail -1 || true)"
  if [ "$rc" -ne 0 ]; then
    record PASS "negative: ${name} is refused" "exit ${rc}: ${msg:0:110}"
  else
    record FAIL "negative: ${name} is refused" "exit 0, log ${out}"
  fi
  id_after="$(disk_id "$LOOP")"
  end_after="$(end_sector "$LOOP" 2)"
  check "negative: ${name}: card untouched (disk ID, partition end)" \
    "ID ${ORIG_DISK_ID} -> ${id_after}, end ${end_before} -> ${end_after}" \
    bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$id_after" "$ORIG_DISK_ID" "$end_before" "$end_after"
  drop_card
}

mutate_machine_id() { echo "0123456789abcdef0123456789abcdef" > "${MNT_ROOT}/etc/machine-id"; }
mutate_bookworm() {
  local cmd
  cmd="$(tr -d '\n' < "${MNT_BOOT}/cmdline.txt")"
  echo "${cmd} init=/usr/lib/raspberrypi-sys-mods/firstboot" > "${MNT_BOOT}/cmdline.txt"
}
mutate_no_userdata() { rm -f "${MNT_BOOT}/user-data"; }

run_negative() {
  info "Preparing a pristine base image for the negative tests"
  make_card "${WORK}/base.img"
  neg_case "booted image (real machine-id)" mutate_machine_id
  neg_case "Bookworm image (firstboot marker)" mutate_bookworm
  neg_case "image without user-data" mutate_no_userdata
  rm -f "${WORK}/base.img"
}

# --- Main ---
if [ "$NEGATIVE" = true ]; then
  run_negative
else
  run_positive
fi

print_summary
[ "$FAILED" -eq 0 ]
