# Implementation plan: offline LUKS encryption of a never-booted Raspberry Pi OS card

Status: implemented on 2026-11-02 (M1 to M5 and the README part of M6, not yet run on hardware; the loop test
needs root). Follow-ups in section 8.

## 1. Goal

Encrypt the root partition of a freshly written Raspberry Pi OS card on the workstation, **before the Pi has ever
booted it**. Today the RPi workflow needs a first boot on the Pi (`luks_prepare.sh` runs on the board), a shutdown, the
card in the workstation (`luks_encrypt.sh`) and a second boot. The offline mode replaces the first boot:

```bash
# card written with Raspberry Pi Imager 2.x (cloud-init customisation), never booted
sudo ./luks_prepare.sh --offline=/dev/sdX --board=pi5
sudo ./luks_encrypt.sh --device=/dev/sdX
# card into the Pi, cable connected: tang unlock, then the normal first boot (cloud-init etc.)
```

Use cases: several demo Pis from one image, cards prepared in advance, no SSH access needed before encryption, the
cloud-init secrets (Wi-Fi PSK, SSH keys) never land on an unencrypted root.

Out of scope for the first version: Armbian, NVMe/USB targets, Bookworm images (different first-boot mechanism, see
section 2), Raspberry Pi OS Lite vs. Desktop makes no difference.

## 2. What the first boot does today (Trixie)

Observed on the image written on 2026-11-02 by Imager 2.0.12 (`raspberrypi-sys-mods 1:20260914`,
`cloud-init 25.2-1~bpo13+1+rpt20`, `rpi-cloud-init-mods 1:20260119`, `initramfs-tools 0.148.4+rpt2`):

| Mechanism                                            | What it does                                                              | Impact on an already encrypted root                                                        |
|------------------------------------------------------|---------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| ` resize` in `cmdline.txt`, initramfs `resize_early` | `parted resizepart 2` to the end of the disk                              | breaks: it resolves the partition behind `$ROOT`, which is `/dev/pivg/root` (dm, no part.) |
| initramfs `local-bottom/set_partuuid`                | new random disk ID, rewrites `fstab` and `cmdline.txt`, removes ` resize` | must be done offline instead, else every card from one image shares the disk ID            |
| `rpi-resize.service` pulls `systemd-growfs-root`     | grows the root ext4 online (`ConditionFirstBoot=yes`)                     | harmless: `luks_encrypt.sh` creates the ext4 on the full LV, growfs is a no-op             |
| `regenerate_ssh_host_keys.service`                   | creates the SSH host keys (the image ships none)                          | fine, as long as nothing creates keys in the chroot                                        |
| `/etc/machine-id` = `uninitialized`                  | makes systemd treat the boot as first boot (`ConditionFirstBoot`)         | trap: `apt`/`dbus` in the chroot may initialise it, then the first boot logic is skipped   |
| cloud-init NoCloud, seed in `/boot/firmware`         | user, hostname, SSH keys, Wi-Fi, `runcmd` (enables ssh), packages         | fine: runs after the root is unlocked, reads the unencrypted boot partition                |
| `ds=nocloud;i=rpi-imager-<id>` in `cmdline.txt`      | instance ID for cloud-init                                                | must survive the `cmdline.txt` rewrite in phase `bootconfig`                               |

Bookworm images use `init=/usr/lib/raspberrypi-sys-mods/firstboot` instead. The offline mode detects that and refuses.

## 3. Design

Keep the scripts standalone (each one is copied alone to a board today). No shared library file. Instead:

- `luks_prepare.sh` gets an **offline mode** (`--offline=<device> --board=<model>`). The detection steps (1 to 5) are
  replaced by arguments and image checks, the writing steps (6 to 12) run against a target root instead of `/`.
- `luks_encrypt.sh` gets `--device=<device>` (non-interactive device selection, useful for the online RPi flow too)
  and treats the new scenario `rpi_offline` like `rpi`.
- Both scripts stay usable as today without the new options.

### 3.1 Target-root prefix in `luks_prepare.sh`

All files written in steps 7 to 11 use absolute paths today (`/etc/initramfs-tools/modules`,
`/etc/initramfs-tools/hooks/copycrypttab`, `/etc/initramfs-tools/hooks/luks_hooks`,
`/etc/initramfs-tools/scripts/init-bottom/cleanup-netplan`, `/etc/initramfs-tools/initramfs.conf`,
`/etc/kernel/postinst.d/initramfs-rebuild`, `/root/luks-staged/*`, `config.txt`). Introduce `TARGET_ROOT=""` (online)
or the mount point of the card (offline) and prefix every path: `"${TARGET_ROOT}/etc/..."`. Commands that must run
with the target's tools (`apt-get`, `update-initramfs`) go through a helper `_in_target`:

```bash
_in_target() {   # run a command in the target system
  if [ -z "$TARGET_ROOT" ]; then "$@"; else chroot "$TARGET_ROOT" "$@"; fi
}
```

The online path must produce byte-identical files to today (regression check, see section 6).

### 3.2 Offline phases in `luks_prepare.sh --offline`

| #   | Phase     | Steps                                                                                                                             |
|-----|-----------|-----------------------------------------------------------------------------------------------------------------------------------|
| 1   | preflight | host tools, device checks, image checks (section 3.3); refuse with a clear message if anything does not fit                       |
| 2   | partition | grow partition 2 to the end of the card, new random disk ID, remove ` resize` from `cmdline.txt` (section 3.4)                    |
| 3   | chroot    | mount p2 rw and p1 at `/boot/firmware`, bind `/dev`, `/dev/pts`, `/proc`, `/sys`, temporary `resolv.conf` and `policy-rc.d` (3.5) |
| 4   | packages  | `apt-get install` of the same package list as step 6 today, inside the chroot (qemu-aarch64 on x86_64)                            |
| 5   | configure | steps 7 to 11 of today with `TARGET_ROOT`; network driver from `--board` instead of detection (section 3.6); stage `luks.conf`    |
| 6   | initramfs | `update-initramfs -u -k all` in the chroot plus the hard verification from `luks_encrypt.sh` (`cryptroot/crypttab`, clevis)       |
| 7   | restore   | restore first-boot state (section 3.5), tear down the chroot, re-run the image checks, tang check from the host                   |

A trap restores the first-boot state and unmounts on every exit path, success or failure.

### 3.3 Preflight checks (refuse instead of guessing)

Host:

- running as root; `parted`, `sfdisk`, `e2fsck`, `cryptsetup`, `clevis`, `jq`, `curl`, `lsinitramfs`, `findmnt`
- aarch64 host, or `binfmt_misc` entry for aarch64 with flag `F` (interpreter usable inside a chroot)

Device:

- block device, removable or USB/MMC transport, not mounted, not part of the running system (same rules as
  `luks_encrypt.sh` device detection), exactly two partitions: p1 vfat (`bootfs`), p2 ext4 (`rootfs`)

Image ("never booted"), all must hold:

- `cmdline.txt` contains ` resize` and `ds=nocloud;i=`, no `init=/usr/lib/raspberrypi-sys-mods/firstboot` (Bookworm)
- `/etc/machine-id` contains exactly `uninitialized`
- no `/etc/ssh/ssh_host_*` keys, no `/var/lib/cloud/instance`
- `user-data` and `meta-data` present on p1 (Imager 2.x customisation applied; otherwise the Pi is unreachable later)
- partition 2 ends well before the end of the card (not yet grown)

### 3.4 Partition growth and disk ID

- `parted -s <dev> unit s resizepart 2 <end>` with `<end>` = last sector, capped at 4294967295 for MBR (same rule as
  `resize_early`). No `resize2fs`: `luks_encrypt.sh` reformats the partition anyway and backs up only files.
- New disk ID: 32 random bits from `/dev/urandom`, `sfdisk --disk-id <dev> 0x<id>`. Rewrite the old ID in the target
  `fstab` (`PARTUUID=<id>-01`, `-02`) and in `cmdline.txt` (`root=PARTUUID=<id>-02`), like `set_partuuid` does.
- Remove ` resize` from `cmdline.txt`. Keep every other parameter, especially `ds=nocloud;i=...`.
- Order matters: this phase runs **before** `luks.conf` and the staged `cmdline.txt` are written, so the staged copy
  already has the new disk ID and no ` resize`.

### 3.5 Keeping the first-boot state intact

Saved before the chroot is used, restored in the trap and verified afterwards:

| Item                           | Handling                                                                                  |
|--------------------------------|-------------------------------------------------------------------------------------------|
| `/etc/machine-id`              | save content, restore exactly (`uninitialized`)                                           |
| `/var/lib/dbus/machine-id`     | save state (absent, file or symlink), restore exactly                                     |
| `/etc/ssh/ssh_host_*`          | must stay absent; delete if a package created keys, then warn                             |
| `/var/lib/cloud/`              | must stay absent; fail if cloud-init ran in the chroot                                    |
| `/etc/resolv.conf`             | save (may be a symlink), replace with host resolver for `apt`, restore exactly            |
| `/usr/sbin/policy-rc.d`        | create with `exit 101` (no service starts in the chroot), remove afterwards               |
| `/usr/bin/qemu-aarch64-static` | remove the copy after use (`luks_encrypt.sh` phase 5 copies it too, remove there as well) |

### 3.6 Network driver for the initramfs without detection

Online mode detects interface and driver from the default route. Offline there is no running system, so `--board`
selects the driver; `--iface` overrides the interface name (default `eth0`):

| `--board`  | Ethernet driver  | Note                                       |
|------------|------------------|--------------------------------------------|
| `pi5`      | `macb`           | verified on kikube-rpi5-demo1 (2026-11-02) |
| `pi4`      | `bcmgenet`       | to verify on hardware                      |
| `pi3bplus` | `lan78xx`        | USB Ethernet, to verify                    |
| `pi3b`     | `smsc95xx`       | USB Ethernet, to verify                    |
| `all`      | all of the above | larger initramfs, one card for every model |

Wi-Fi in the initramfs stays unsupported (tang unlock needs Ethernet), as today. See section 8.1 for the follow-up.

### 3.7 Changes in `luks_encrypt.sh`

- `--device=<dev>`: skip the interactive device prompt, still show `lsblk` and ask for the final confirmation.
- Scenario `rpi_offline` behaves like `rpi` (external mode, chroot initramfs rebuild).
- Phase `bootconfig`: the staged `cmdline.txt` is used as is; add a check that it contains no ` resize` and still
  contains `ds=nocloud;i=` when the original had it.
- Phase `initramfs`: same first-boot protection as 3.5 (`machine-id`, `policy-rc.d`, remove the qemu copy).
- Phase `verify`: re-run the image checks from 3.3 except "partition not grown" and fail on any violation.

### 3.8 USB key stick

Optional extra unlock path besides tang and the typed passphrase (`--usb-key` in `luks_prepare.sh`,
`--usb-key-file=<path>` in `luks_encrypt.sh`). It is not a new mechanism: the initramfs scripts are byte-identical
copies of the keyfile fallback of the Ansible clevis role that already runs on the cluster hosts (tested there).
Source: `../dgxarley/roles/clevis/files/initramfs_hooks_clevis-keyfile`, `initramfs_local-top_clevis-keyfile` and
`initramfs_local-bottom_clevis-keyfile`. Both copies must be kept in sync; a change goes into the role first.

Files installed on the target by `luks_prepare.sh --usb-key` (online and offline, offline through `TARGET_ROOT`):

| File                                                      | Purpose                                                                                                          |
|-----------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `etc/initramfs-tools/hooks/clevis-keyfile`                | copies `keyfile.conf` (never the key) into the image, adds `usb_storage uas sd_mod vfat exfat ext4 nls_*`        |
| `etc/initramfs-tools/scripts/local-top/clevis-keyfile`    | the watcher, started in the background; see below                                                                |
| `etc/initramfs-tools/scripts/local-bottom/clevis-keyfile` | stops the watcher and unmounts the stick                                                                         |
| `etc/clevis-keyfile/keyfile.conf`                         | `USB=1`, `USB_LABEL='LUKSKEY'`, `USB_FILE='luks-fallback.key'`, `USB_DIR='luks-keys'`, `HOST='<host>'`, `BOOT=0` |

`HOST` is the hostname (offline: from `user-data`) or the value of `--usb-key-host=<name>`. `luks.conf` gets
`USB_KEY="yes"`, `USB_KEY_LABEL="LUKSKEY"` and `USB_KEY_HOST="<host>"`.

Watcher (`local-top/clevis-keyfile`): like the clevis initramfs script it waits in the background for cryptroot's
`askpass` and writes a key into its passphrase FIFO (`passfifo`); crypttab stays untouched. It looks (once per second,
the stick may be plugged in while the prompt is shown) for a filesystem with the label `LUKSKEY` (vfat, exfat or
ext4), mounts it read-only and tries `luks-keys/<host>.key` first, then every other `luks-keys/*.key`, and the old
single file `luks-fallback.key` in the root of the stick. A key is written into the FIFO only after
`cryptsetup open --test-passphrase` accepted it, and a rejected key is not retried for the same prompt. Tang, the
stick and a typed passphrase answer the same prompt; the first valid answer wins. One stick can carry the keys of
several hosts (cluster hosts and Pis).

`luks_encrypt.sh --usb-key-file=<path>`:

- If the file does not exist it is generated (64 base64 characters, one line, mode 600). Its first line becomes a
  third LUKS keyslot (passphrase, clevis, USB key). A directory (the mounted stick) means
  `<dir>/luks-keys/<host>.key` with `<host>` from `USB_KEY_HOST` in `luks.conf`; `luks-keys/` is created and the
  filesystem label is compared with `LUKSKEY` (warning only), so the key is generated on the stick directly.
- The master copy of the key is `/etc/clevis-keyfile/fallback.key` on the encrypted root (mode 600, no trailing
  newline). `/root/clevis_keyfile_write_usb.sh <partition>` copies it to a stick labelled `LUKSKEY` as
  `luks-keys/<host>.key` and verifies it with `--test-passphrase`.
- Verification: keyslot count (`cryptsetup luksDump <dev> | grep -cE '^\s+[0-9]+: luks2$'` must be 3, otherwise 2), a
  `--test-passphrase` open with the key, every initramfs contains `scripts/local-top/clevis-keyfile` and
  `etc/clevis-keyfile/keyfile.conf`, and none contains `etc/clevis-keyfile/fallback.key`.
- If `luks.conf` has `USB_KEY="yes"` and the option is missing, the script fails early (otherwise the card would be
  encrypted without the keyslot the initramfs expects).

Limitations:

- The label is fixed to `LUKSKEY`.
- The key is plain text on the stick: stick plus card unlock the system. The stick must be kept apart from the Pi.
- The watcher does not detect removal of the stick; a stick that is pulled after the unlock does nothing further.
- Only the first line of the key file is used, and the file on the stick must not have a trailing newline (the
  watcher passes the file to `cryptsetup --key-file` as it is).
- Not covered by the loop test: the initramfs scripts need the initramfs environment and a real stick (hardware
  test, section 8.2).

## 4. First boot on the Pi (expected)

1. Firmware loads `initramfs_2712`, initramfs brings up `eth0` per DHCP, clevis unlocks via both tang servers.
2. LVM activates `pivg/root`, root is mounted, no `resize_early` (parameter removed).
3. systemd sees `machine-id` = `uninitialized`: first boot. `rpi-resize` and `systemd-growfs-root` run (no-op),
   `regenerate_ssh_host_keys` creates host keys.
4. cloud-init applies `user-data` and `network-config` from `/boot/firmware` (user, hostname, SSH keys, ssh on).

Checks after the first boot, to be added to the README:

```bash
cloud-init status --long            # status: done, no errors
cat /etc/machine-id                 # a real ID now
ls /etc/ssh/ssh_host_*              # keys exist
lsblk; lvs                          # mmcblk0p2 over the whole card, pivg/root full size
grep -c ' resize' /proc/cmdline     # 0
clevis luks list -d /dev/mmcblk0p2  # sss binding
/root/tang_check_connection.sh /dev/mmcblk0p2
```

## 5. Milestones

| #   | Milestone                                                                                    | Estimate |
|-----|----------------------------------------------------------------------------------------------|---------:|
| M1  | `TARGET_ROOT` prefix and `_in_target` in `luks_prepare.sh`, online behaviour unchanged       |       3h |
| M2  | `--device` and scenario `rpi_offline` in `luks_encrypt.sh`, first-boot protection in phase 5 |       2h |
| M3  | offline phases preflight, partition, chroot, restore in `luks_prepare.sh`                    |       4h |
| M4  | offline packages, configure, initramfs (with hard verification)                              |       3h |
| M5  | loop-device tests with an image file (section 6.2)                                           |       3h |
| M6  | hardware test Pi 5, then Pi 4; README section "Offline mode"                                 |       3h |
| M8  | USB keyfile unlock (watcher in the initramfs, third keyslot)                                 |       3h |

Total roughly two working days, most of the risk in M4 to M6. M7 (Wi-Fi in the initramfs, section 8.1) and M8
(USB key stick, section 3.8) are optional additions on top; M8 adds about three hours.

## 6. Tests

### 6.1 Static

- `bash -n` for all scripts; install `shellcheck` on the workstation and add `make shellcheck` (scripts under
  `scripts/luks/`), run it in the pre-commit hooks or CI.

### 6.2 Image file on a loop device (no hardware)

- Take the Raspberry Pi OS image (`~/.cache/Raspberry Pi/Imager/lastdownload.cache` is the downloaded `.img.xz`),
  decompress it into a scratch directory, `truncate -s 16G` to simulate a card, apply cloud-init seed files as the
  Imager does (`user-data`, `meta-data`, `network-config`, `cmdline.txt` with `ds=nocloud;i=...`).
- `losetup -P`, then `luks_prepare.sh --offline=/dev/loopN --board=pi5` and `luks_encrypt.sh --device=/dev/loopN`.
  The device checks need an override for loop devices (`--allow-loop`, test only).
- Assertions: partition 2 ends at the last sector, new disk ID in `fstab` and `cmdline.txt`, no ` resize`,
  `machine-id` = `uninitialized`, no SSH host keys, no `/var/lib/cloud`, no `policy-rc.d`, no qemu binary,
  `resolv.conf` unchanged, every initramfs contains `cryptroot/crypttab`, clevis and the network driver,
  `cryptsetup luksDump` shows two keyslots (passphrase, clevis).
- With `--usb-key` (harness option): three keyslots, the generated key opens the device (`--test-passphrase`), every
  initramfs contains `scripts/local-top/clevis-keyfile`, `scripts/local-bottom/clevis-keyfile` and
  `etc/clevis-keyfile/keyfile.conf` but never `etc/clevis-keyfile/fallback.key` (and none of the first three without
  the option), `luks.conf` has `USB_KEY="yes"`, `USB_KEY_LABEL="LUKSKEY"` and `USB_KEY_HOST`, the opened root has
  `/etc/clevis-keyfile/fallback.key` equal to the key file and an executable `/root/clevis_keyfile_write_usb.sh`.
- Negative tests: a booted image (machine-id set) must be refused; a Bookworm image must be refused; an image without
  `user-data` must be refused.

### 6.3 Regression of the online flow

- Run `luks_prepare.sh` online on a test Pi before and after M1, diff the written files and `/root/luks-staged/`
  (expected: identical).

### 6.4 Hardware

| Board | Card source                  | Expected                                                                     |
|-------|------------------------------|------------------------------------------------------------------------------|
| Pi 5  | fresh Trixie Desktop image   | tang unlock, cloud-init done, hostname and SSH as configured, full-size root |
| Pi 4  | fresh Trixie Lite image      | same, with `bcmgenet`                                                        |
| Pi 5  | tang unreachable (cable out) | passphrase prompt on the console, boot continues after entering it           |

Not on production hosts (`rpi5node1` etc.); use spare cards.

## 7. Risks and open questions

| Risk / question                                                 | Mitigation                                                                                          |
|-----------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `apt` under qemu is slow and package scripts behave differently | install only the listed packages, `policy-rc.d`, `DEBIAN_FRONTEND=noninteractive`, no `apt upgrade` |
| something initialises `machine-id` or SSH keys in the chroot    | save, restore and verify (3.5), fail if verification fails                                          |
| future Raspberry Pi OS changes the first-boot mechanism         | preflight checks for the known markers, refuse on anything unknown                                  |
| `ds=nocloud;i=...` lost in `cmdline.txt`, cloud-init skipped    | explicit check in `bootconfig` and `verify`                                                         |
| `systemd-growfs-root` on LVM root                               | expected no-op, confirm on hardware (M6)                                                            |
| `apt` needs network and the host resolver inside the chroot     | temporary `resolv.conf`, restored by the trap                                                       |
| card reader resets during the run                               | health checks already in `luks_encrypt.sh`, add the same to the offline phases of `luks_prepare.sh` |
| Bookworm support                                                | later: replace `init=.../firstboot` handling instead of ` resize`, separate milestone               |

## 8. Follow-ups

### 8.1 Wi-Fi in the initramfs (M7, not started)

Decided on 2026-11-02: not part of the first version, the demo Pi boots with a cable. Wanted later so that the tang
unlock also works on a Pi that only has Wi-Fi.

The driver alone is not enough. The Trixie initramfs brings up an interface with `configure_networking` (`ip=`
parameter, DHCP only) and cannot associate with an access point. Needed:

| Piece             | Detail                                                                                                                                                                                                                      |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| modules           | `brcmfmac`, `brcmutil`, `cfg80211` (plus `rfkill`); Pi 5 and Pi 4 both use the CYW43455                                                                                                                                     |
| firmware          | `/lib/firmware/brcm/brcmfmac43455-sdio.{bin,txt,clm_blob}` with the board symlinks (`raspberrypi,5-model-b` etc.), `/lib/firmware/regulatory.db` and `regulatory.db.p7s`                                                    |
| user space        | `wpa_supplicant` binary with its libraries (`copy_exec`), `wpa_supplicant.conf` with SSID and PSK                                                                                                                           |
| hook              | new `hooks/luks_wifi`: copies the pieces above into the image                                                                                                                                                               |
| premount script   | new `scripts/init-premount/luks_wifi`: `wpa_supplicant -B -i wlan0 -c ...`, wait for association (`wpa_cli status`, timeout 30 s), then `configure_networking` on `wlan0`; on timeout fall through to the passphrase prompt |
| `luks_prepare.sh` | option `--wifi`; offline mode reads SSID and PSK from `network-config` on the boot partition (written by Imager 2.x), online mode from `wpa_cli` or NetworkManager; `DEVICE=wlan0` and the `ip=` line follow                |
| `luks_encrypt.sh` | `_verify_initramfs_images` must also check firmware and `wpa_supplicant` when `WIFI="yes"` is in `luks.conf`                                                                                                                |
| tests             | loop test assertion for the Wi-Fi pieces; hardware test on Pi 5 without a cable; tang unreachable over Wi-Fi                                                                                                                |

Trade-offs to accept: the PSK is stored in clear text inside the initramfs on the unencrypted boot partition (the
Imager already stores it in clear text in `network-config` there, so the exposure does not get worse); the boot
takes 5 to 15 s longer; roaming, 5 GHz DFS channels and a weak signal are new failure modes that end at the
passphrase prompt. Estimate: half a day plus the hardware test.

### 8.2 Other open items

- Run the loop test (section 6.2) and the hardware matrix (6.4); both need root and were not run on 2026-11-02.
- `cryptroot/crypttab` is only reported, not required, by `luks_prepare.sh --offline`, because `/etc/crypttab` has
  no entry before `luks_encrypt.sh` runs. `luks_encrypt.sh` requires it after its own rebuild.
- `--backup-dir=` on a fresh run of `luks_encrypt.sh` now selects where the backup is created (it used to apply
  only with `--start-phase`). Mention in the changelog when releasing.
- Bookworm images (section 7, last row).
- The hardware test of the USB key stick (section 3.8) is still open: a Pi 5 with tang unreachable and the stick
  plugged in before and during the prompt, a wrong key on the stick, no stick at all (typed passphrase), the same
  stick carrying the key of a cluster host. The loop test only covers the files in the image and the keyslot.

