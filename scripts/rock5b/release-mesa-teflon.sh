#!/usr/bin/env bash
# release-mesa-teflon.sh — Create a GitHub Release with libteflon.so
#
# Usage:
#   ./release-mesa-teflon.sh [DIST_DIR]
#
# Workflow on the Rock 5B:
#   1. sudo ./build-mesa-teflon.sh --package    # Build + package
#   2. scp /tmp/mesa-teflon-build/dist/* user@workstation:sbcstuff/  # Optional: copy to dev machine
#   3. ./release-mesa-teflon.sh /tmp/mesa-teflon-build/dist          # Create release
#
# Prerequisite: gh CLI installed and authenticated (gh auth login)

set -euo pipefail

# -- Configuration -------------------------------------------------------------
# IMPORTANT: MESA_VERSION must match between build-mesa-teflon.sh and release-mesa-teflon.sh
MESA_VERSION="mesa-25.3.5"
MESA_GIT_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
VERSION_SHORT="${MESA_VERSION#mesa-}"
RELEASE_TAG="teflon-v${VERSION_SHORT}"
DEFAULT_DIST_DIR="/tmp/mesa-teflon-build/dist"

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

# -- Check for newer Mesa version --------------------------------------------
check_mesa_version() {
    info "Checking current Mesa version on GitLab ..."
    # Fetch stable release tags (mesa-XX.Y.Z), ignore RCs and pre-releases
    LATEST_TAG=$(git ls-remote --tags --refs "$MESA_GIT_URL" 'refs/tags/mesa-*' 2>/dev/null \
        | awk '{print $2}' \
        | sed 's|refs/tags/||' \
        | grep -E '^mesa-[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1)

    if [[ -z "$LATEST_TAG" ]]; then
        warn "Could not determine current Mesa version (network issue?)"
        return
    fi

    ok "Configured version: ${BOLD}${MESA_VERSION}${NC}"
    ok "Latest stable version: ${BOLD}${LATEST_TAG}${NC}"

    if [[ "$LATEST_TAG" != "$MESA_VERSION" ]]; then
        # Check if configured version is older
        NEWER=$(printf '%s\n' "$MESA_VERSION" "$LATEST_TAG" | sort -V | tail -1)
        if [[ "$NEWER" == "$LATEST_TAG" ]]; then
            warn "Newer Mesa version available: ${BOLD}${LATEST_TAG}${NC} (current: ${MESA_VERSION})"
            if [[ -t 0 ]]; then
                info "Options:"
                echo "    [1] Use newer version (${LATEST_TAG})"
                echo "    [2] Continue with configured version (${MESA_VERSION})"
                echo "    [3] Abort"
                read -r -p "  Choice [1/2/3]: " choice
                case "$choice" in
                    1)
                        info "Using ${BOLD}${LATEST_TAG}${NC} instead of ${MESA_VERSION}"
                        MESA_VERSION="$LATEST_TAG"
                        VERSION_SHORT="${MESA_VERSION#mesa-}"
                        RELEASE_TAG="teflon-v${VERSION_SHORT}"
                        warn "build-mesa-teflon.sh must be updated manually to ${LATEST_TAG}."
                        ;;
                    3)
                        info "Aborted."
                        exit 0
                        ;;
                    *)
                        info "Continuing with configured version ${BOLD}${MESA_VERSION}${NC}."
                        ;;
                esac
            else
                warn "Update MESA_VERSION in this script and build-mesa-teflon.sh to upgrade."
            fi
        else
            info "Configured version (${MESA_VERSION}) is newer than latest stable release (${LATEST_TAG})"
        fi
    else
        ok "Mesa version is up to date"
    fi
}
check_mesa_version

# -- Arguments -----------------------------------------------------------------
DIST_DIR="${1:-$DEFAULT_DIST_DIR}"

if [[ ! -d "$DIST_DIR" ]]; then
    fail "Dist directory not found: $DIST_DIR"
    info "Build first: sudo ./build-mesa-teflon.sh --package"
    exit 1
fi

# -- Checks --------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
    fail "gh CLI not found"
    info "Install: https://cli.github.com/"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    fail "gh not authenticated"
    info "Log in: gh auth login"
    exit 1
fi

ok "gh CLI authenticated"

# Check repo
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
if [[ -z "$REPO" ]]; then
    fail "No GitHub repo found (git remote?)"
    info "Run from repo directory or configure remote"
    exit 1
fi
ok "Repo: $REPO"

# -- Collect assets ------------------------------------------------------------
ASSETS=()
for f in "$DIST_DIR"/libteflon.so "$DIST_DIR"/libteflon-*.tar.gz; do
    if [[ -f "$f" ]]; then
        ASSETS+=("$f")
        ok "Asset: $(basename "$f") ($(stat -c%s "$f" | numfmt --to=iec))"
    fi
done

if [[ ${#ASSETS[@]} -eq 0 ]]; then
    fail "No assets found in $DIST_DIR"
    info "Build first: sudo ./build-mesa-teflon.sh --package"
    exit 1
fi

# BUILD_INFO for release notes
BUILD_INFO=""
if [[ -f "$DIST_DIR/libteflon-${VERSION_SHORT}/BUILD_INFO.txt" ]]; then
    BUILD_INFO=$(cat "$DIST_DIR/libteflon-${VERSION_SHORT}/BUILD_INFO.txt")
fi

# -- Create release ------------------------------------------------------------
echo -e "\n${BOLD}══ Creating GitHub Release ══${NC}"
info "Tag: $RELEASE_TAG"
info "Assets: ${#ASSETS[@]} files"

# Check if release already exists
if gh release view "$RELEASE_TAG" &>/dev/null; then
    fail "Release $RELEASE_TAG already exists"
    info "Delete: gh release delete $RELEASE_TAG --yes"
    info "Or choose a different tag"
    exit 1
fi

RELEASE_BODY="$(cat <<EOF
## libteflon.so — Mesa ${VERSION_SHORT} (Rocket/RK3588 NPU)

Pre-built Mesa Teflon TFLite delegate for RK3588 NPU acceleration (mainline kernel ≥6.18).

### Quick Install

\`\`\`bash
mkdir -p /usr/local/lib/teflon
wget -O /usr/local/lib/teflon/libteflon.so \\
  \$(gh release view ${RELEASE_TAG} --json assets -q '.assets[] | select(.name=="libteflon.so") | .url')
chmod 755 /usr/local/lib/teflon/libteflon.so
\`\`\`

Or directly:

\`\`\`bash
gh release download ${RELEASE_TAG} -p 'libteflon.so' -D /usr/local/lib/teflon/
chmod 755 /usr/local/lib/teflon/libteflon.so
\`\`\`

### Requirements

- **Board:** Rock 5B / RK3588-based SBC
- **Kernel:** ≥6.18 with \`rocket.ko\` (\`/dev/accel/accel0\`)
- **Arch:** aarch64

### Build Info

\`\`\`
${BUILD_INFO:-Built from Mesa ${VERSION_SHORT} with -Dgallium-drivers=rocket -Dteflon=true}
\`\`\`

### Build from Source

\`\`\`bash
sudo ./scripts/rock5b/build-mesa-teflon.sh
\`\`\`
EOF
)"

gh release create "$RELEASE_TAG" \
    --title "libteflon.so ${VERSION_SHORT} (RK3588 Rocket)" \
    --notes "$RELEASE_BODY" \
    "${ASSETS[@]}"

echo ""
ok "Release created!"
RELEASE_URL=$(gh release view "$RELEASE_TAG" --json url -q .url)
info "URL: $RELEASE_URL"
echo ""
