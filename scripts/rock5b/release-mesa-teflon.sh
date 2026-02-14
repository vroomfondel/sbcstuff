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
VERSION_SHORT="${MESA_VERSION#mesa-}"
RELEASE_TAG="teflon-v${VERSION_SHORT}"
DEFAULT_DIST_DIR="/tmp/mesa-teflon-build/dist"

# -- Colors --------------------------------------------------------------------
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
fail() { echo -e "  ${RED}✘${NC} $*"; }
info() { echo -e "  ${CYAN}ℹ${NC} $*"; }

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
