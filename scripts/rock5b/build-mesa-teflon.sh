#!/usr/bin/env bash
# build-mesa-teflon.sh — Build Mesa libteflon.so (Rocket/RK3588 NPU) from source
#
# Usage:
#   sudo ./build-mesa-teflon.sh              # Build + install
#   sudo ./build-mesa-teflon.sh --deps-only  # Install dependencies only
#   sudo ./build-mesa-teflon.sh --no-deps    # Build without apt (dependencies already present)
#   sudo ./build-mesa-teflon.sh --package    # Build + tarball for GitHub Release
#
# Installs ONLY libteflon.so to /usr/local/lib/teflon/ —
# system Mesa (GPU/display) is NOT touched.

set -euo pipefail

# -- Configuration -------------------------------------------------------------
# IMPORTANT: MESA_VERSION must match between build-mesa-teflon.sh and release-mesa-teflon.sh
MESA_VERSION="mesa-25.3.5"
MESA_MESON_MIN="1.4.0"
MESA_GIT_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="/tmp/mesa-teflon-build"
INSTALL_DIR="/usr/local/lib/teflon"
TEFLON_SO_REL="build/src/gallium/targets/teflon/libteflon.so"
PACKAGE_DIR="/tmp/mesa-teflon-build/dist"

# -- Colors --------------------------------------------------------------------
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
fail() { echo -e "  ${RED}✘${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${CYAN}ℹ${NC} $*"; }

# -- Root check ----------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (sudo)"
    exit 1
fi

# -- Arguments -----------------------------------------------------------------
SKIP_DEPS=false
DEPS_ONLY=false
PACKAGE=false
BUILD_JOBS=""

for arg in "$@"; do
    case "$arg" in
        --no-deps)    SKIP_DEPS=true ;;
        --deps-only)  DEPS_ONLY=true ;;
        --package)    PACKAGE=true ;;
        --jobs=*)     BUILD_JOBS="${arg#--jobs=}" ;;
        -j*)          BUILD_JOBS="${arg#-j}" ;;
        -h|--help)
            echo "Usage: sudo $0 [--deps-only|--no-deps|--package|--jobs=N|-jN]"
            exit 0
            ;;
        *)
            fail "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# -- Architecture check -------------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    fail "This script is for aarch64 (Rock 5B), not $ARCH"
    exit 1
fi

# -- Dependencies --------------------------------------------------------------
install_deps() {
    echo -e "\n${BOLD}══ Installing build dependencies ══${NC}"

    # Try build-dep (requires deb-src in sources.list)
    if apt-get build-dep -y mesa 2>/dev/null; then
        ok "Mesa build-dep installed"
    else
        warn "apt-get build-dep failed (no deb-src?) — installing manually"
        apt-get install -y \
            gcc g++ \
            git meson ninja-build python3-mako python3-yaml python3-ply \
            libdrm-dev libelf-dev libexpat1-dev libwayland-dev \
            libwayland-egl-backend-dev wayland-protocols \
            llvm-dev libclang-dev \
            bison flex glslang-tools \
            pkg-config cmake \
            zlib1g-dev libzstd-dev \
            libx11-dev libxext-dev libxfixes-dev libxcb-shm0-dev \
            libxcb-randr0-dev libxrandr-dev libxshmfence-dev \
            libxxf86vm-dev
        ok "Packages installed manually"
    fi

    # Verify required tools
    for cmd in meson ninja git; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found: $(command -v "$cmd")"
        else
            fail "$cmd not found"
            exit 1
        fi
    done

    # Check meson minimum version (Mesa 25.x requires >= 1.4.0)
    MESON_VER=$(meson --version)
    if printf '%s\n' "$MESA_MESON_MIN" "$MESON_VER" | sort -V | head -1 | grep -qx "$MESA_MESON_MIN"; then
        ok "meson $MESON_VER >= $MESA_MESON_MIN"
    else
        warn "meson $MESON_VER is too old (Mesa $MESA_VERSION requires >= $MESA_MESON_MIN)"
        info "Installing newer version via pip ..."
        pip3 install --break-system-packages "meson>=$MESA_MESON_MIN"
        # Prefer pip version (installed to /usr/local/bin)
        hash -r
        MESON_VER=$(meson --version)
        if printf '%s\n' "$MESA_MESON_MIN" "$MESON_VER" | sort -V | head -1 | grep -qx "$MESA_MESON_MIN"; then
            ok "meson $MESON_VER installed via pip"
        else
            fail "meson upgrade failed (still $MESON_VER)"
            exit 1
        fi
    fi
}

if [[ "$SKIP_DEPS" == false ]]; then
    install_deps
fi

if [[ "$DEPS_ONLY" == true ]]; then
    ok "Dependencies installed — done (--deps-only)"
    exit 0
fi

# -- Clone / checkout Mesa -----------------------------------------------------
echo -e "\n${BOLD}══ Preparing Mesa ${MESA_VERSION} ══${NC}"

if [[ -d "$BUILD_DIR/mesa" ]]; then
    info "Existing Mesa directory found: $BUILD_DIR/mesa"
    cd "$BUILD_DIR/mesa"
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_TAG" == "$MESA_VERSION" ]]; then
        ok "Already on $MESA_VERSION"
    else
        info "Currently on $CURRENT_TAG — switching to $MESA_VERSION"
        git fetch --tags
        git checkout "$MESA_VERSION"
        # Remove old build on version change
        rm -rf build
    fi
else
    mkdir -p "$BUILD_DIR"
    info "Cloning Mesa (shallow) ..."
    git clone --depth 1 --branch "$MESA_VERSION" "$MESA_GIT_URL" "$BUILD_DIR/mesa"
    cd "$BUILD_DIR/mesa"
    ok "Mesa $MESA_VERSION cloned"
fi

# -- Configure meson -----------------------------------------------------------
echo -e "\n${BOLD}══ Configuring Mesa (Rocket + Teflon only) ══${NC}"

if [[ -f build/build.ninja ]]; then
    info "Build directory already exists — skipping meson setup"
else
    rm -rf build
    meson setup build \
        -Dgallium-drivers=rocket \
        -Dteflon=true \
        -Dvulkan-drivers= \
        -Dglx=disabled \
        -Dplatforms= \
        -Dprefix=/usr/local
    ok "Meson configured"
fi

# -- Build ---------------------------------------------------------------------
echo -e "\n${BOLD}══ Building ══${NC}"

NPROC="${BUILD_JOBS:-$(nproc)}"
info "Compiling with $NPROC threads ..."

meson compile -C build -j "$NPROC"
ok "Build complete"

# -- Verify libteflon.so exists ------------------------------------------------
if [[ ! -f "$TEFLON_SO_REL" ]]; then
    fail "libteflon.so not found at $TEFLON_SO_REL"
    info "Check meson configuration"
    exit 1
fi

FILESIZE=$(stat -c%s "$TEFLON_SO_REL")
ok "libteflon.so built ($((FILESIZE / 1024)) KB)"

# -- Package (--package) -------------------------------------------------------
if [[ "$PACKAGE" == true ]]; then
    echo -e "\n${BOLD}══ Packaging for GitHub Release ══${NC}"

    # Version string without "mesa-" prefix
    VERSION_SHORT="${MESA_VERSION#mesa-}"
    DISTRO_ID=$(. /etc/os-release && echo "${ID}-${VERSION_CODENAME}")
    TARBALL_NAME="libteflon-${VERSION_SHORT}-aarch64-${DISTRO_ID}.tar.gz"

    mkdir -p "$PACKAGE_DIR"

    # Standalone .so for easy download
    cp "$TEFLON_SO_REL" "$PACKAGE_DIR/libteflon.so"

    # Tarball with metadata
    STAGING="$PACKAGE_DIR/libteflon-${VERSION_SHORT}"
    mkdir -p "$STAGING"
    cp "$TEFLON_SO_REL" "$STAGING/libteflon.so"
    chmod 755 "$STAGING/libteflon.so"
    # Document dynamic dependencies
    LDD_OUTPUT=$(ldd "$TEFLON_SO_REL" 2>&1 || true)

    cat > "$STAGING/BUILD_INFO.txt" <<BUILDEOF
Mesa Version:    $MESA_VERSION
Build Date:      $(date -Iseconds)
Architecture:    $(uname -m)
Kernel:          $(uname -r)
Distribution:    $(. /etc/os-release && echo "$PRETTY_NAME")
GCC:             $(gcc --version | head -1)
Meson Options:   -Dgallium-drivers=rocket -Dteflon=true -Dvulkan-drivers=
Install Path:    /usr/local/lib/teflon/libteflon.so

Dynamic Dependencies (ldd):
$LDD_OUTPUT
BUILDEOF

    info "Dynamic dependencies:"
    echo "$LDD_OUTPUT" | while read -r line; do
        info "  $line"
    done

    tar czf "$PACKAGE_DIR/$TARBALL_NAME" -C "$PACKAGE_DIR" "libteflon-${VERSION_SHORT}"
    rm -rf "$STAGING"

    ok "Packages created in $PACKAGE_DIR:"
    info "  $PACKAGE_DIR/libteflon.so  (standalone)"
    info "  $PACKAGE_DIR/$TARBALL_NAME"
    info ""
    info "Create release with:"
    info "  ./release-mesa-teflon.sh $PACKAGE_DIR"
    echo
    exit 0
fi

# -- Install -------------------------------------------------------------------
echo -e "\n${BOLD}══ Installing ══${NC}"

mkdir -p "$INSTALL_DIR"
cp "$TEFLON_SO_REL" "$INSTALL_DIR/libteflon.so"
chmod 755 "$INSTALL_DIR/libteflon.so"
ok "Installed: $INSTALL_DIR/libteflon.so"

# Check if path is visible in ldconfig
if ldconfig -p 2>/dev/null | grep -q teflon; then
    ok "libteflon.so visible in ldconfig"
else
    info "$INSTALL_DIR is not in ldconfig — that's OK"
    info "rock5b-npu-test.py searches $INSTALL_DIR directly"
fi

# -- Summary -------------------------------------------------------------------
echo -e "\n${BOLD}══ Done ══${NC}"
ok "Mesa $MESA_VERSION — libteflon.so successfully built and installed"
info "Test with: python3 rock5b-npu-test.py --check-only"
info "Build directory: $BUILD_DIR/mesa (can be deleted)"
echo
