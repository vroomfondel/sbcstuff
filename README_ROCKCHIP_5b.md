# Rock 5B NPU Setup (RK3588)

Board: **Radxa Rock 5B** (RK3588, aarch64)

## Hardware

| Property | Value |
|---|---|
| SoC | Rockchip RK3588 |
| NPU | 6 TOPS RKNPU (3x Core @ `fdab0000`) |
| GPU | Mali G610 MP4 (ARM) |
| Architecture | aarch64 |
| OS | Armbian 25.11.x (Ubuntu Noble 24.04) |

## Boot Configuration & SPI Flash

### Boot Order: Two Stages

The boot process consists of two independent stages, each with its own order:

#### Stage 1: BootROM (hardcoded in the SoC, not configurable)

The RK3588 BootROM searches for the **first bootloader** (SPL/TPL) in a fixed order:

1. **SPI NOR Flash** (16 MB on the board)
2. **eMMC** (if populated)
3. **SD card** (`mmcblk1`)

The BootROM **cannot** access NVMe, USB, or network directly — U-Boot must be present in SPI flash for those.

#### Stage 2: U-Boot `boot_targets` (configurable via `fw_setenv`)

Once U-Boot is loaded, it searches for the **operating system** in the order defined by the `boot_targets` variable. For each target device, U-Boot's `distro_bootcmd` scans partitions for boot files (`boot.scr`, then `extlinux/extlinux.conf`):

```bash
# Show current order:
fw_printenv boot_targets
# e.g.: mmc1 nvme mmc0 scsi usb pxe dhcp spi

# Change order (e.g., USB first):
fw_setenv boot_targets "usb mmc1 nvme mmc0 scsi pxe dhcp spi"

# Reset to default:
fw_setenv boot_targets "mmc1 nvme mmc0 scsi usb pxe dhcp spi"
```

The interactive script `scripts/rock5b/rock5b-usb-boot-setup.sh` configures this automatically (including SPI flash + `fw_setenv`).

#### Stage 2b: Partition Scanning (`legacy_boot` flag)

For each boot target device, U-Boot's `distro_bootcmd` uses `part list -bootable` to select which partitions to scan for boot files. This is a **filter, not a priority**:

1. If **any** partition has the GPT `legacy_boot` flag → **only** flagged partitions are scanned (in partition table order)
2. If **no** partition has the flag → **only partition 1** is scanned as fallback

This matters when `/boot` is a separate partition (e.g., after `luks_boot_split.sh`). Without the flag, U-Boot always loads `boot.scr` from partition 1 (rootfs) and uses the old kernel files from there — ignoring the real `/boot` partition entirely. Removing `boot.scr` from partition 1 does **not** help: U-Boot simply fails to boot instead of falling through.

```bash
# Set legacy_boot on boot partition, clear on rootfs:
parted -s /dev/mmcblk1 set 1 legacy_boot off
parted -s /dev/mmcblk1 set 2 legacy_boot on

# Verify:
parted -s /dev/mmcblk1 print
# Partition 2 should show "legacy_boot" in Flags column
```

The `luks_boot_split.sh` script sets this flag automatically.

> Reference: [U-Boot Distro Boot Documentation](https://docs.u-boot.org/en/latest/develop/distro.html), [`config_distro_bootcmd.h`](https://github.com/u-boot/u-boot/blob/master/include/config_distro_bootcmd.h) (`scan_dev_for_boot_part` → `part list -bootable`), [`cmd/part.c`](https://github.com/u-boot/u-boot/blob/master/cmd/part.c) (bootable filter implementation).

> **Important:** `fw_setenv` requires `/etc/fw_env.config` with the correct environment offset. For **Armbian** Rock 5B (SPI NOR, Macronix MX25U12835F): Offset `0xc00000` (12 MB), Size `0x20000` (128 KB), Sector `0x1000` (4 KB) — from Armbian `config/boards/rock-5b.conf`. Upstream U-Boot and official Radxa builds may use different offsets (e.g., `CONFIG_ENV_IS_IN_MMC` instead of SPI). The setup script creates this file if needed.

### SPI Flash Devices

| Device | Description |
|---|---|
| `/dev/mtd0` | SPI Flash — read/write, character device (byte-level) |
| `/dev/mtd0ro` | SPI Flash — read-only (safer for reading/checking) |
| `/dev/mtdblock0` | SPI Flash — block device (for `dd` flashing) |

Metadata in `/proc/mtd`:

```
dev:    size   erasesize  name
mtd0: 01000000 00001000 "loader"
       16 MB    4 KB erase block
```

### Checking SPI Flash Status

```bash
# Does the SPI flash exist?
ls -la /dev/mtd* /dev/mtdblock*

# Flash chip and size (dmesg):
dmesg | grep -iE 'spi-nor|sfc'
# Expected: spi-nor spi5.0: XT25F128B (16384 Kbytes) read_data x4

# Check content — is U-Boot present or is it empty?
# Empty flash = all 0xFF, zeroed flash = all 0x00
dd if=/dev/mtd0ro bs=4096 count=1 2>/dev/null | od -A x -t x1z | head -5

# Count non-zero bytes in the entire SPI (0 = completely empty/zeroed):
dd if=/dev/mtd0ro bs=65536 2>/dev/null | tr -d '\000' | wc -c

# Read U-Boot environment (only if U-Boot is in SPI):
fw_printenv boot_targets 2>/dev/null
fw_printenv bootcmd 2>/dev/null
```

Interpretation:

| First bytes | Meaning |
|---|---|
| `ff ff ff ff ...` | Flash empty (factory erased) — BootROM skips SPI |
| `00 00 00 00 ...` | Flash zeroed (manually erased via `dd if=/dev/zero`) — BootROM skips SPI |
| Data present | U-Boot is flashed — SPI is used as boot source |

### Current State (as of Feb 2026)

```
BootROM → SPI (U-Boot, GPT format) → NVMe ✓

nvme0n1       465.8G  NVMe (LUKS + LVM)
├─nvme0n1p1     1.5G  /boot (ext4, unencrypted)
└─nvme0n1p2   464.3G  LUKS2 → LVM pivg/root → / (ext4)

Clevis/Tang: SSS t=2 → Auto-Unlock
Kernel: 6.18.0-rc6-edge-rockchip64 (panthor GPU, Rocket NPU ✓)
```

### Changing Boot Source

**Boot from NVMe instead of SD** (write U-Boot to SPI flash):

```bash
# Armbian usually ships the SPI image:
ls /usr/lib/linux-u-boot-*/u-boot-rockchip-spi.bin

# Write U-Boot to SPI flash:
sudo dd if=/usr/lib/linux-u-boot-*/u-boot-rockchip-spi.bin of=/dev/mtdblock0

# Check/adjust U-Boot boot order (stage 2):
fw_printenv boot_targets
fw_setenv boot_targets "nvme mmc1 mmc0 scsi usb pxe dhcp spi"
```

**Set up USB boot** (interactive):

```bash
# All-in-one: flash SPI + set boot_targets to USB-first:
sudo bash scripts/rock5b/rock5b-usb-boot-setup.sh
```

**Revert to SD-only boot** (erase SPI):

```bash
# Erase SPI completely — BootROM falls back to eMMC/SD:
sudo flash_erase /dev/mtd0 0 0

# Alternative (less clean, writes 0x00 instead of 0xFF):
sudo dd if=/dev/zero of=/dev/mtdblock0 bs=4096 count=4096
```

**Maskrom mode (emergency recovery):** If nothing boots — hold the Maskrom button on the board while powering on. Use USB and `rkdeveloptool` (on another machine) to re-flash SPI or load an image directly.

## Kernel & NPU: Three Options

### Overview

| Kernel | Package name | NPU driver | Userspace | NPU device |
|---|---|---|---|---|
| `6.12.x-current-rockchip64` | `linux-image-current-rockchip64` | **none** | — | — |
| `6.1.115-vendor-rk35xx` | `linux-image-vendor-rk35xx` | `rknpu.ko` 0.9.8 (proprietary) | rknn-toolkit2 / rknpu2 / rknn-llm | `/dev/dri/renderD129` |
| **`6.18.x-edge-rockchip64`** | **`linux-image-edge-rockchip64`** | **`rocket.ko` (upstream GPL)** | **Mesa Teflon / TFLite** | **`/dev/accel/accel0`** |

> **Package rename:** Armbian merged the RK3588 kernel family into `rockchip64` (shared with RK3568/RK3566). Old packages (`linux-image-edge-rockchip-rk3588`, 6.12.x) and new ones (`linux-image-edge-rockchip64`, 6.18.x) can coexist. For NPU support, the new `rockchip64` package must be installed.

### NVMe Stability: Mainline vs. Vendor

The mainline kernel uses the upstream `pcie-dw-rockchip` driver, which has matured significantly since ~6.6+ — better NVMe power management, fewer link retraining errors. The vendor kernel has its own Rockchip PCIe PHY configuration with known Gen3 instabilities and I/O timeouts under load.

### Option A: Edge Kernel 6.18 with Rocket Driver (recommended)

The open-source **Rocket** driver (by Tomeu Vizoso / Collabora, ~6200 LoC) has been upstream since kernel 6.18-rc1 and is already enabled in the Armbian edge config (`CONFIG_DRM_ACCEL_ROCKET=m`).

**Pros:** NPU + stable NVMe + mainline maintenance. **Con:** Different userspace stack (TFLite instead of rknn-toolkit2).

#### Device Tree: Already Complete in Mainline

All 3 NPU cores + IOMMUs + regulator are enabled with `status = "okay"` in the shared mainline DTSI [`rk3588-rock-5b-5bp-5t.dtsi`](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/rockchip/rk3588-rock-5b-5bp-5t.dtsi). **No DTBO needed.**

```dts
/* NPU regulator (I2C, rk8602) */
vdd_npu_s0: regulator@42 {
    compatible = "rockchip,rk8602";
    regulator-name = "vdd_npu_s0";
    regulator-min-microvolt = <550000>;
    regulator-max-microvolt = <950000>;
    vin-supply = <&vcc5v0_sys>;
};

&pd_npu { domain-supply = <&vdd_npu_s0>; };

/* All 3 cores enabled */
&rknn_core_0 { npu-supply = <&vdd_npu_s0>; sram-supply = <&vdd_npu_s0>; status = "okay"; };
&rknn_core_1 { npu-supply = <&vdd_npu_s0>; sram-supply = <&vdd_npu_s0>; status = "okay"; };
&rknn_core_2 { npu-supply = <&vdd_npu_s0>; sram-supply = <&vdd_npu_s0>; status = "okay"; };
&rknn_mmu_0 { status = "okay"; };
&rknn_mmu_1 { status = "okay"; };
&rknn_mmu_2 { status = "okay"; };
```

SoC-level NPU nodes (3 cores @ `fdab0000`, `fdac0000`, `fdad0000`) are defined in [`rk3588-base.dtsi`](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi) with compatible string `"rockchip,rk3588-rknn-core"`.

#### Rocket Userspace Stack

```
TensorFlow Lite model (.tflite)
        │
   libteflon.so  (Mesa 25.3+ Teflon TFLite delegate)
        │
   rocket Gallium driver  (Mesa 25.3+)
        │
   /dev/accel/accel0  (Kernel DRM accel subsystem)
        │
   rocket.ko  (Kernel 6.18+, CONFIG_DRM_ACCEL_ROCKET=m)
        │
   NPU Hardware (3x Cores @ RK3588, 6 TOPS)
```

**Important:** `rknn-toolkit2` / `rknpu2` / `rknn-llm` do NOT work with the Rocket driver. Models must be in `.tflite` format (not `.rknn`).

#### Installation

```bash
# ── Method 1: CLI directly (recommended) ─────────────────────────────
apt update
apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64

# ── Method 2: armbian-config TUI ─────────────────────────────────────
armbian-config --cmd KER001
# → Select "linux-image-edge-rockchip64"

# ── Method 3: armbian-config interactive ─────────────────────────────
armbian-config
# → System → Alternative kernels → edge (6.18.x)
```

**CRITICAL for LUKS/Clevis/OVS systems:** Verify initramfs before rebooting!

```bash
# Check initramfs — all components must be present:
lsinitramfs /boot/initrd.img-6.18*-edge-rockchip64 | grep -E "r8169|dm.crypt|clevis|crypttab|cleanup-netplan"
# Expected: r8169.ko, dm-crypt.ko, clevis*, crypttab, cleanup-netplan

# Check boot symlinks (should automatically point to new kernel):
ls -la /boot/Image /boot/uInitrd /boot/dtb

# If symlinks were not updated:
KVER=$(ls /boot/vmlinuz-*-edge-rockchip64 | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
ln -sf vmlinuz-${KVER} /boot/Image
ln -sf uInitrd-${KVER} /boot/uInitrd
ln -sf dtb-${KVER} /boot/dtb

# Reboot
reboot
```

Post-reboot verification:

```bash
uname -r                    # 6.18.x-edge-rockchip64
ls /dev/accel/              # accel0
lsmod | grep rocket         # rocket  <size>  0
cryptsetup status rootfs    # LUKS active
ovs-vsctl show              # OVS OK
systemctl --failed          # empty
```

#### Mesa Teflon Userspace (libteflon.so)

`libteflon.so` is the TFLite delegate that forwards inference requests to the Rocket driver.
It is **not** statically linked — dynamic dependencies include `libdrm`, `libelf`, `libstdc++`, `zlib`
(all present on a standard Armbian installation).

**Option 1 — Pre-built from GitHub Release (recommended):**

```bash
sudo mkdir -p /usr/local/lib/teflon
gh release download teflon-v25.3.5 -p 'libteflon.so' -D /usr/local/lib/teflon/
sudo chmod 755 /usr/local/lib/teflon/libteflon.so
```

**Option 2 — Build script:**

```bash
sudo ./scripts/rock5b/build-mesa-teflon.sh
```

Builds Mesa 25.3.5 from source and installs only `libteflon.so` to `/usr/local/lib/teflon/`.
System Mesa (GPU/display) is not touched. The script automatically checks the
meson minimum version (≥1.4.0) and installs it via pip if needed.

```bash
sudo ./build-mesa-teflon.sh --deps-only   # Install build dependencies only
sudo ./build-mesa-teflon.sh --no-deps     # Build without apt (dependencies already present)
sudo ./build-mesa-teflon.sh --package     # Build + tarball for GitHub Release
sudo ./build-mesa-teflon.sh --jobs=4      # Limit build threads (or -j4)
```

**Option 3 — Manual build from source:**

```bash
apt-get build-dep mesa && apt install git meson ninja-build python3-mako
git clone --depth 1 --branch mesa-25.3.5 https://gitlab.freedesktop.org/mesa/mesa.git && cd mesa
meson setup build -Dgallium-drivers=rocket -Dteflon=true -Dvulkan-drivers=
meson compile -C build
sudo mkdir -p /usr/local/lib/teflon
sudo cp build/src/gallium/targets/teflon/libteflon.so /usr/local/lib/teflon/
sudo chmod 755 /usr/local/lib/teflon/libteflon.so
```

**Verification:**

```bash
# Quick test
python3 scripts/rock5b/rock5b-npu-test.py --check-only

# Or manually
python3 -c "
import tflite_runtime.interpreter as tflite
delegate = tflite.load_delegate('/usr/local/lib/teflon/libteflon.so')
interpreter = tflite.Interpreter(
    model_path='ssdlite_mobiledet.tflite',
    experimental_delegates=[delegate])
interpreter.allocate_tensors()
print('NPU Inference OK')
"

# Check dynamic dependencies
ldd /usr/local/lib/teflon/libteflon.so
```

#### Creating a GitHub Release (after build with --package)

On the Rock 5B:
```bash
sudo ./scripts/rock5b/build-mesa-teflon.sh --package
```

On the dev workstation (requires `gh` CLI):
```bash
make teflon-release                                    # fetch from Rock 5B + create GitHub Release
make teflon-release ROCK5B_HOST=root@10.0.0.5          # custom host
make teflon-fetch                                      # fetch only, no release
```

Or manually:
```bash
mkdir -p dist && rsync -av --progress root@rock5b:/tmp/mesa-teflon-build/dist/ dist/
./scripts/rock5b/release-mesa-teflon.sh dist/
```

Creates release `teflon-v25.3.5` with `libteflon.so` and tarball (including `BUILD_INFO.txt` with `ldd` output).

> **Note:** The `.so` is linked against the build distribution's libraries.
> On boards with the same Armbian/Ubuntu base (e.g. both Noble) the binary works directly.
> For different distro versions, build from source instead (Option 2/3).

```bash
# Docker (e.g. Frigate)
# devices: ["/dev/accel:/dev/accel"]
# volumes: ["./libteflon.so:/usr/lib/teflon/libteflon.so:ro"]
```

#### Frigate NVR with NPU Acceleration (Edge Kernel + Rocket)

Starting with **Frigate 0.17**, the Teflon TFLite delegate is natively supported. This enables object detection on the RK3588 NPU at ~30 FPS per core — comparable to the proprietary rknpu driver.

**Important:** Use the **`standard-arm64`** image, not the `-rk` image (which is for the vendor kernel with rknpu).

`docker-compose.yml`:

```yaml
services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:0.17-standard-arm64  # NOT -rk!
    devices:
      - /dev/dri/:/dev/dri/
      - /dev/accel/:/dev/accel/
    volumes:
      - ./config:/config
      - ./libteflon.so:/usr/lib/teflon/libteflon.so:ro  # if not included in the image
      - /etc/localtime:/etc/localtime:ro
    # ...
```

`frigate.yml`:

```yaml
detectors:
  npu:
    type: teflon_tfl

cameras:
  # ...
```

Prerequisites:
- Edge kernel 6.18+ with `rocket.ko` loaded (`/dev/accel/accel0` present)
- Mesa 25.3.5+ `libteflon.so` (see installation options above, or mount as volume)
- Frigate 0.17+ (`standard-arm64` variant)

### Option B: Vendor Kernel 6.1 with rknpu (proprietary)

For existing `.rknn` models or `rknn-llm`.

#### Switching Kernels

```bash
# CLI directly:
apt install linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx linux-headers-vendor-rk35xx
reboot

# Or interactively:
armbian-config --cmd KER001
# → Select "linux-image-vendor-rk35xx"
```

#### NPU Device After Kernel Switch

The vendor kernel registers the NPU as a **DRM device** (not as `/dev/rknpu*`):

```
/dev/dri/renderD129  →  NPU (platform-fdab0000.npu-render)
/dev/dri/renderD128  →  GPU (platform-display-subsystem-render)
```

Verification:

```bash
ls -la /dev/dri/by-path/
# platform-fdab0000.npu-render -> ../renderD129

cat /sys/class/devfreq/fdab0000.npu/cur_freq
# 1000000000  (1 GHz)

dmesg | grep -i rknpu
# [drm] Initialized rknpu 0.9.8 20240828 for fdab0000.npu on minor 1
```

### Option C: Current/Edge Kernel 6.12–6.17 (no NPU)

On kernels 6.12.x through 6.17.x, the NPU is **not usable** — neither via overlay nor via out-of-tree build (see next section). The Rocket driver is only available from 6.18 onwards in mainline.

> **Note:** The older package `linux-image-edge-rockchip-rk3588` provides kernel 6.12.1 and has **no** NPU support. For NPU, the newer `linux-image-edge-rockchip64` (6.18+) must be installed.

```bash
# Show available kernel packages and versions:
apt-cache search linux-image | grep -iE 'rockchip|rk3588'
```

### Why the Vendor rknpu Driver Cannot Be Ported to Mainline 6.12

The driver source code is at [`armbian/linux-rockchip` @ `rk-6.1-rkr5.1/drivers/rknpu/`](https://github.com/armbian/linux-rockchip/tree/rk-6.1-rkr5.1/drivers/rknpu) (~10 source files: `rknpu_drv.c`, `rknpu_job.c`, `rknpu_gem.c`, `rknpu_mem.c`, etc.).

A DKMS attempt exists at [bmilde/rknpu-driver-dkms](https://github.com/bmilde/rknpu-driver-dkms), but it does not compile:

> *"The driver does not compile currently. Please help me to make this a thing!"*

| Problem | Detail |
|---------|--------|
| DRM/GEM API incompatibility | Uses `CONFIG_ROCKCHIP_RKNPU_DRM_GEM` with Rockchip-specific DRM extensions |
| Missing vendor headers | `rockchip/rockchip_iommu.h`, `soc/rockchip/rockchip_ipa.h`, `soc/rockchip/rockchip_opp_select.h`, `soc/rockchip/rockchip_system_monitor.h` |
| Missing Kconfig symbols | `CONFIG_ROCKCHIP_RKNPU`, `CONFIG_DMABUF_HEAPS_ROCKCHIP_CMA_HEAP` not present in mainline |
| Missing DT nodes on 6.12 | The NPU nodes (`rknn_core_0/1/2`, compatible `rockchip,rk3588-rknn-core`) only exist from mainline DTS ~6.18 onwards |

Effort required: stub headers, rewrite DRM-GEM to mainline APIs, create DTBO, maintain on every kernel update. **Not worthwhile**, since Rocket is available upstream from 6.18.

### Comparison: rknn-toolkit2 vs. Rocket/Teflon

| | rknn-toolkit2 (Vendor) | Rocket/Teflon (Mainline) |
|---|---|---|
| Kernel | 6.1 Vendor | 6.18+ Mainline |
| Driver | `rknpu.ko` (proprietary) | `rocket.ko` (GPL, upstream) |
| Model format | `.rknn` (converted) | `.tflite` (standard TFLite) |
| API | RKNN C/Python API | TensorFlow Lite Delegate |
| Multi-core | Yes (3 cores) | Yes (3 cores) |
| LLM support | rknn-llm (direct) | Not direct (TFLite-based) |
| Performance | ~30 FPS SSDLite MobileDet | ~30 FPS SSDLite MobileDet |
| Long-term support | Rockchip-dependent | Upstream kernel + Mesa |

## Device Tree Overlays

The vendor DTB (`rk3588-rock-5b.dtb`) already has the NPU enabled with `status = "okay"`. A separate NPU overlay is **not needed** and causes conflicts (`can't request region for resource`).

If an old overlay is present, remove it:

```bash
# Remove line from armbianEnv.txt
sed -i '/^user_overlays=rk3588-enable-npu/d' /boot/armbianEnv.txt

# Delete compiled .dtbo file
rm -f /boot/overlay-user/rk3588-enable-npu.dtbo
```

### armbianEnv.txt (clean, current state with LUKS/LVM)

```
verbosity=1
bootlogo=false
console=both
extraargs=cma=256M
overlay_prefix=rockchip-rk3588
fdtfile=rockchip/rk3588-rock-5b.dtb
rootdev=/dev/pivg/root
rootfstype=ext4
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
```

## Python & RKNN Toolkit

### Installed Python Versions

| Version | Path | Purpose |
|---|---|---|
| Python 3.12.3 | `/usr/bin/python3` | System Python, **RKNN-compatible** |
| Python 3.14.3 | `/usr/bin/python3.14` | deadsnakes PPA, for everything without RKNN |

Python 3.14 installed via:

```bash
apt install software-properties-common
add-apt-repository ppa:deadsnakes/ppa
apt install python3.14 python3.14-venv python3.14-dev
```

### RKNN venv

```
/root/npu-venv/  →  Python 3.12 venv with rknn-toolkit-lite2
```

**rknn-toolkit-lite2 supports only Python 3.7, 3.8, 3.9, 3.10, 3.12** (not 3.14).

```bash
# Activate
source /root/npu-venv/bin/activate

# Test
python3 -c "from rknnlite.api import RKNNLite; print('OK')"
```

Installed packages in the venv:

- `rknn-toolkit-lite2==2.3.2`
- `numpy`
- `psutil`
- `ruamel.yaml`

### Model Workflow

1. **On x86 machine:** Convert model (ONNX/TFLite → `.rknn`) with `rknn-toolkit2`
2. **On Rock 5B:** Inference with `rknn-toolkit-lite2`

```python
from rknnlite.api import RKNNLite

rknn = RKNNLite()
rknn.load_rknn('model.rknn')
rknn.init_runtime()
outputs = rknn.inference(inputs=[input_data])
rknn.release()
```

## Known Notes

- **`can't request region for resource`** in dmesg: Non-fatal IOMMU overlap warning, NPU works regardless (vendor kernel)
- **No HDMI on vendor kernel?** Different GPU driver (Mali-Bifrost instead of Panthor). Use serial console (UART, 1500000 baud) for debugging
- **No `/dev/rknpu*`:** From RKNPU driver 0.9.x onwards, the DRM subsystem is used (`/dev/dri/renderD129`). From kernel 6.18+, the Rocket driver uses `/dev/accel/accel0`
- **No `/dev/accel/accel0`:** Rocket driver requires kernel ≥6.18 (`linux-image-edge-rockchip64`). Kernels 6.12–6.17 have no NPU support
- **Package confusion `rockchip-rk3588` vs. `rockchip64`:** Armbian renamed the kernel family. `linux-image-edge-rockchip-rk3588` (old, 6.12.x) and `linux-image-edge-rockchip64` (new, 6.18.x) are different packages. For NPU: `rockchip64`
- **LUKS/Clevis during kernel switch:** Always check `lsinitramfs` before rebooting — r8169, dm-crypt, clevis, crypttab, cleanup-netplan must be present in the initramfs of the new kernel
- **Diagnostic script:** `scripts/rock5b/rock5b-hw-check.sh` (with `--fix` for auto-repair). Detects both rocket and rknpu, shows kernel upgrade commands
- **Kernel upgrade has no effect (eMMC with separate `/boot` partition):** U-Boot's `distro_bootcmd` finds `boot.scr` on **partition 1** (rootfs) first. Removing `boot.scr` from partition 1 prevents boot entirely (U-Boot does not fall through). If `/boot` is a separate partition 2 (`mmcblk1p2`), kernel upgrades update files on partition 2, but U-Boot loads the old kernel from the hidden `/boot/` on the root partition. **Fix:** Set the GPT `legacy_boot` flag on the boot partition (and clear it on rootfs) — U-Boot's `distro_bootcmd` scans partitions with this flag before others: `parted -s /dev/mmcblk1 set 1 legacy_boot off && parted -s /dev/mmcblk1 set 2 legacy_boot on`. Does **not** apply to NVMe boot (SPI → NVMe), where `/boot` is typically `nvme0n1p1` = partition 1. The `luks_boot_split.sh` script handles this automatically

## LUKS Encryption (NVMe Migration)

The scripts `scripts/luks/luks_prepare.sh` and `scripts/luks/luks_encrypt.sh` natively support the Rock 5B. See [README.md](README.md) for full LUKS documentation.

### Current State (after LUKS migration, as of Feb 2026)

| Property | Value |
|---|---|
| Boot medium | NVMe (`nvme0n1`) via SPI U-Boot |
| U-Boot / SPI flash | 16MB SPI NOR (`mtd0`), U-Boot GPT format (active) |
| NVMe layout | `nvme0n1p1` = `/boot` (1.5GB ext4), `nvme0n1p2` = LUKS2 → LVM `pivg/root` |
| Clevis/Tang | SSS t=2 → Auto-Unlock |
| OVS | active (bridge + VLANs) |
| Network | `enP4p65s0` (r8169 driver) — included in initramfs for Clevis/Tang |
| Boot config | `/boot/armbianEnv.txt` with `rootdev=/dev/pivg/root` |
| Initramfs | `initrd.img-*` + `uInitrd-*` (U-Boot wrapped), with clevis + r8169 + cleanup-netplan |

### Pre-LUKS State (historical)

| Property | Value |
|---|---|
| Boot medium | SD card (`mmcblk1p1`, 59GB, single partition) |
| U-Boot / SPI flash | 16MB SPI NOR (`mtd0`), empty/zeroed — BootROM fell back to SD |
| NVMe | 466GB (`/dev/nvme0n1`), unpartitioned |
| `/boot` | Directory on the root partition (no separate mount) |

### Fundamental Difference from RPi

RPi has a separate FAT32 boot partition (`/boot/firmware`). Rock 5B has `/boot` on the root partition. For LUKS, `/boot` must first be split out as a separate unencrypted partition — U-Boot cannot read LUKS.

### Recommended Scenario: NVMe Migration

The NVMe **cannot be removed** — everything runs directly on the Rock 5B. The system boots from eMMC, so the NVMe can be freely partitioned/encrypted.

```bash
# 1. Prepare: board detection, partition NVMe, copy /boot, configure initramfs
sudo ./scripts/luks/luks_prepare.sh
# → Choose "1) Migrate to NVMe"
# → NVMe is partitioned: p1=1.5GB ext4 (/boot), p2=rest (LUKS+LVM)
# → /boot copied to NVMe p1, armbianEnv.txt with rootdev=/dev/pivg/root staged

# 2. Encrypt: directly on the Rock 5B (local mode, NVMe ≠ boot disk)
sudo ./scripts/luks/luks_encrypt.sh
# → Auto-detects local mode (migration scenario)
# → Copies directly from running root to encrypted NVMe (no intermediate backup)
# → NVMe p2 LUKS-encrypted, LVM created, data restored
# → armbianEnv.txt on NVMe p1 updated
# → Initramfs rebuilt in chroot + uInitrd created
# → Clevis/Tang bound
# → No intermediate backup needed — data is copied directly from live root to encrypted NVMe

# 3. Reboot, U-Boot finds NVMe, Clevis decrypts automatically

# 4. After successful NVMe boot: disable eMMC boot
parted /dev/mmcblk1 set 1 boot off
```

### Storage Stack After Migration

```
/dev/nvme0n1p1 (1.5GB ext4) → /boot (unencrypted, armbianEnv.txt + kernel + uInitrd)
/dev/nvme0n1p2 → LUKS2 → /dev/mapper/rootfs → LVM PV → VG "pivg" → LV "root" → /dev/pivg/root (ext4 /)
```

### Board-Specific Script Details

| Aspect | RPi | Rock 5B (Armbian) |
|--------|-----|-------------------|
| Board detection | `/boot/firmware/config.txt` | `/boot/armbianEnv.txt` |
| Boot directory | `/boot/firmware` (vfat) | `/boot` (ext4) |
| Boot config | `cmdline.txt` + `config.txt` | `armbianEnv.txt` |
| Root device param | `root=` + `cryptdevice=` in cmdline | `rootdev=` in armbianEnv.txt |
| Kernel postinst | Custom initramfs-rebuild hook | Skip (Armbian's own hooks) |
| Initramfs format | `initramfs.gz` | `initrd.img-*` + `uInitrd-*` (mkimage wrapped) |
| FSTYPE | `ext4,vfat` | `ext4` |
| Encrypt workflow | External (remove SD/NVMe) | Local (NVMe directly on Rock 5B) |

### Prerequisites

```bash
# Required on the Rock 5B (installed by luks_prepare.sh):
apt install cryptsetup cryptsetup-initramfs clevis clevis-luks clevis-initramfs clevis-systemd curl jq lvm2

# For uInitrd creation:
apt install u-boot-tools
```

### Post-Boot Verification

```bash
lsblk                                    # nvme0n1p1 → /boot, pivg-root → /
pvs                                      # /dev/mapper/rootfs in VG pivg
lvs                                      # root LV in pivg
clevis luks list -d /dev/nvme0n1p2       # SSS binding with tang servers
cat /boot/armbianEnv.txt                 # rootdev=/dev/pivg/root
```

### Troubleshooting

**U-Boot doesn't find NVMe:** SPI flash must contain U-Boot with NVMe support. Check with `sudo nand-sata-install` or Armbian docs.

**uInitrd missing after kernel update:** Armbian has its own hooks that normally create `uInitrd`. If not:
```bash
KVER=$(uname -r)
mkimage -A arm64 -T ramdisk -C gzip -n "uInitrd ${KVER}" -d /boot/initrd.img-${KVER} /boot/uInitrd-${KVER}
ln -sf uInitrd-${KVER} /boot/uInitrd
```

**Clevis/Tang binding failed:** Tang servers must be reachable. After booting with passphrase, re-bind manually:
```bash
clevis luks bind -d /dev/nvme0n1p2 sss '{"t":2,"pins":{"tang":[{"url":"..."},{"url":"..."}]}}'
```

## Kernel Switching Quick Reference

```bash
# ── Show available kernels ───────────────────────────────────────────
apt-cache search linux-image | grep -iE 'rockchip|rk3588|rk35xx'

# ── Edge 6.18+ (Rocket NPU) ─────────────────────────────────────────
apt install linux-image-edge-rockchip64 linux-dtb-edge-rockchip64

# ── Current 6.12.x (no NPU) ─────────────────────────────────────────
apt install linux-image-current-rockchip64 linux-dtb-current-rockchip64

# ── Vendor 6.1.x (rknpu) ────────────────────────────────────────────
apt install linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx

# ── Interactive (TUI) ───────────────────────────────────────────────
armbian-config --cmd KER001

# ── Remove old kernel packages (after successful boot!) ─────────────
apt remove linux-image-edge-rockchip-rk3588 linux-dtb-edge-rockchip-rk3588  # old 6.12 edge
apt remove linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx                # vendor

# ── LUKS/Clevis: ALWAYS check before reboot! ────────────────────────
KVER=$(ls /boot/vmlinuz-*-edge-rockchip64 | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
lsinitramfs /boot/initrd.img-${KVER} | grep -E "r8169|dm.crypt|clevis|crypttab|cleanup-netplan"
ls -la /boot/Image /boot/uInitrd /boot/dtb

# ── Diagnostics ─────────────────────────────────────────────────────
sudo bash scripts/rock5b/rock5b-hw-check.sh          # read-only check
sudo bash scripts/rock5b/rock5b-hw-check.sh --fix    # auto-repair + kernel suggestions
```

## References

### Kernel & NPU
- https://docs.kernel.org/accel/rocket/index.html (Rocket driver kernel docs)
- https://www.collabora.com/news-and-blog/news-and-events/rockchip-rk3588-upstream-support-progress-future-plans.html (Collabora: RK3588 upstream status)
- https://gitlab.collabora.com/hardware-enablement/rockchip-3588/notes-for-rockchip-3588/-/blob/main/mainline-status.md (Mainline status tracker)
- https://blog.tomeuvizoso.net/2025/07/rockchip-npu-update-6-we-are-in-mainline.html (Tomeu Vizoso: Rocket merged in mainline)
- https://blog.tomeuvizoso.net/2024/06/rockchip-npu-update-4-kernel-driver-for.html (Tomeu Vizoso: Rocket NPU driver)
- https://www.phoronix.com/news/Rockchip-NPU-Linux-Mesa (Phoronix: Rocket + Mesa 25.3)
- https://github.com/blakeblackshear/frigate/discussions/18311 (Frigate: RK3588 HW accel discussion)
- https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/rockchip/rk3588-rock-5b-5bp-5t.dtsi (Mainline DTS with NPU nodes)
- https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/rockchip/rk3588-base.dtsi (SoC DTS: NPU core definitions)
- https://github.com/armbian/build/blob/main/config/boards/rock-5b.conf (Armbian board config: `KERNEL_TARGET="current,edge,vendor"`)
- https://github.com/armbian/build/blob/main/config/kernel/linux-rockchip-rk3588-edge.config (Edge kernel config: `CONFIG_DRM_ACCEL_ROCKET=m`)
- https://forum.armbian.com/topic/56993-npu-and-rkllm-support-on-rockchip-rk3588-nanopc-t6-and-rk3576-nanopi-m5/ (Armbian forum: NPU + RKLLM)

### Vendor rknpu (out-of-tree porting failed)
- https://github.com/armbian/linux-rockchip/tree/rk-6.1-rkr5.1/drivers/rknpu (Vendor driver source code)
- https://github.com/bmilde/rknpu-driver-dkms (Failed DKMS attempt)
- https://github.com/home-assistant/operating-system/issues/3089 (HAOS: rknpu not portable to mainline)

### rknn-toolkit2 (vendor userspace)
- https://github.com/airockchip/rknn-toolkit2 (RKNN Toolkit2 + Lite2)
- https://github.com/Pelochus/ezrknn-toolkit2 (Simplified installation)
- https://docs.radxa.com/en/rock5/rock5c/app-development/rknn_install (Radxa RKNN docs)

### Board & Boot
- https://wiki.radxa.com/Rock5/guide/spi-nvme-boot (SPI flash & NVMe boot)
- https://forum.radxa.com/t/rock-5b-boot-order/12396 (Boot order discussion)
- https://docs.armbian.com/User-Guide_Armbian_overlays/ (Armbian overlays)
