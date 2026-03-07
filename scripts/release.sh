#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KeyValue – Release Automation Script
#
#  Automates the full release cycle:
#    1. Validate environment & prerequisites
#    2. Build DMG via build.sh
#    3. Create git tag & push
#    4. Create GitHub Release with assets
#    5. Update Homebrew tap formula
#
#  Usage:
#    ./scripts/release.sh 1.2.3              # Release v1.2.3
#    ./scripts/release.sh 1.2.3 --dry-run    # Preview without publishing
#    ./scripts/release.sh 1.2.3 --skip-brew  # Skip Homebrew update
#    ./scripts/release.sh --help             # Show help
#
#  Prerequisites:
#    - gh CLI authenticated (gh auth status)
#    - git with push access to origin
#    - Xcode / Swift toolchain
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/MacKeyValue/build.sh"
DIST_DIR="${PROJECT_ROOT}/MacKeyValue/dist"

GITHUB_OWNER="aresnasa"
GITHUB_REPO="mac-keyvalue"
HOMEBREW_TAP_REPO="homebrew-tap"
APP_NAME="KeyValue"

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

step()    { echo -e "\n${BLUE}${BOLD}▸ $1${RESET}"; }
success() { echo -e "  ${GREEN}✅ $1${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${RESET}"; }
fail()    { echo -e "  ${RED}❌ $1${RESET}"; exit 1; }
info()    { echo -e "  ${DIM}$1${RESET}"; }

# ── Parse arguments ──────────────────────────────────────────────────────────
VERSION=""
DRY_RUN=false
SKIP_BREW=false
SKIP_BUILD=false
PRERELEASE=false
FORCE=false

show_help() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  KeyValue – Release Script                                   ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  USAGE                                                       ║
║    ./scripts/release.sh VERSION [OPTIONS]                    ║
║                                                              ║
║  VERSION FORMAT                                              ║
║    Major.Minor.Patch    e.g. 1.0.0, 1.2.3                   ║
║    With pre-release     e.g. 1.2.3-beta.1, 1.2.3-rc.1       ║
║                                                              ║
║  OPTIONS                                                     ║
║    --dry-run       Preview all steps without executing        ║
║    --skip-brew     Skip Homebrew formula update               ║
║    --skip-build    Skip DMG build (use existing dist/)        ║
║    --force         Force release even if tag exists           ║
║    --help          Show this help                             ║
║                                                              ║
║  EXAMPLES                                                    ║
║    ./scripts/release.sh 1.0.0                                ║
║    ./scripts/release.sh 1.1.0 --dry-run                      ║
║    ./scripts/release.sh 2.0.0-beta.1 --skip-brew             ║
║                                                              ║
║  PREREQUISITES                                               ║
║    • gh CLI authenticated: gh auth status                    ║
║    • git with push access to origin                          ║
║    • Xcode / Swift toolchain for building                    ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --skip-brew)   SKIP_BREW=true ;;
        --skip-build)  SKIP_BUILD=true ;;
        --force)       FORCE=true ;;
        --help|-h)     show_help ;;
        -*)
            echo -e "${RED}Unknown option: $arg${RESET}"
            echo "Run: $0 --help"
            exit 1
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            else
                echo -e "${RED}Unexpected argument: $arg${RESET}"
                exit 1
            fi
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: VERSION is required${RESET}"
    echo ""
    echo "Usage: $0 VERSION [--dry-run] [--skip-brew] [--skip-build] [--force]"
    echo ""
    echo "Example: $0 1.0.0"
    echo "Run: $0 --help for full documentation"
    exit 1
fi

# Validate semantic version format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
    fail "Invalid version format: '$VERSION' (expected: MAJOR.MINOR.PATCH[-prerelease])"
fi

# Detect pre-release
if echo "$VERSION" | grep -qE '-(alpha|beta|rc|dev)'; then
    PRERELEASE=true
fi

TAG="v${VERSION}"
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] && ARCH_NAME="intel"
[ "$ARCH" = "arm64" ]  && ARCH_NAME="apple-silicon"
ARCH_NAME="${ARCH_NAME:-$(uname -m)}"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH_NAME}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   KeyValue – Release Automation                  ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}Version:${RESET}     ${BOLD}${VERSION}${RESET} (tag: ${TAG})"
echo -e "  ${DIM}Arch:${RESET}        ${ARCH_NAME}"
echo -e "  ${DIM}Pre-release:${RESET} $($PRERELEASE && echo "yes" || echo "no")"
echo -e "  ${DIM}Dry run:${RESET}     $($DRY_RUN && echo "${YELLOW}YES — no changes will be made${RESET}" || echo "no")"
echo -e "  ${DIM}Skip build:${RESET}  $($SKIP_BUILD && echo "yes" || echo "no")"
echo -e "  ${DIM}Skip brew:${RESET}   $($SKIP_BREW && echo "yes" || echo "no")"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 0: Validate prerequisites
# ══════════════════════════════════════════════════════════════════════════════

step "Validating prerequisites"

# Check gh CLI
if ! command -v gh &>/dev/null; then
    fail "gh CLI not found. Install: brew install gh"
fi
if ! gh auth status &>/dev/null 2>&1; then
    fail "gh CLI not authenticated. Run: gh auth login"
fi
success "gh CLI authenticated"

# Check git
if ! git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null; then
    fail "Not a git repository: $PROJECT_ROOT"
fi

# Check clean working tree (allow untracked files)
if [ -n "$(git -C "$PROJECT_ROOT" diff --cached --name-only)" ]; then
    fail "Staged changes detected. Commit or stash before releasing."
fi

DIRTY_FILES="$(git -C "$PROJECT_ROOT" diff --name-only)"
if [ -n "$DIRTY_FILES" ]; then
    warn "Unstaged changes detected:"
    echo "$DIRTY_FILES" | while IFS= read -r f; do info "  $f"; done
    if ! $DRY_RUN && ! $FORCE; then
        echo ""
        echo -en "  ${YELLOW}Continue anyway? [y/N]${RESET} "
        read -r CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            fail "Aborted. Commit or stash changes first."
        fi
    fi
fi

# Check if tag already exists
if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
    if $FORCE; then
        warn "Tag $TAG already exists — will be overwritten (--force)"
    else
        fail "Tag $TAG already exists. Use --force to overwrite."
    fi
fi

# Check remote
REMOTE_URL="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
    fail "No git remote 'origin' configured"
fi
info "Remote: $REMOTE_URL"
success "All prerequisites met"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1: Build DMG
# ══════════════════════════════════════════════════════════════════════════════

if ! $SKIP_BUILD; then
    step "Building DMG (v${VERSION})"

    if [ ! -f "$BUILD_SCRIPT" ]; then
        fail "Build script not found: $BUILD_SCRIPT"
    fi

    if $DRY_RUN; then
        info "[DRY RUN] Would run: MARKETING_VERSION=$VERSION $BUILD_SCRIPT --ci --dmg"
    else
        cd "${PROJECT_ROOT}/MacKeyValue"
        MARKETING_VERSION="$VERSION" bash build.sh --ci --dmg
        cd "$PROJECT_ROOT"

        if [ ! -f "$DMG_PATH" ]; then
            fail "DMG not found after build: $DMG_PATH"
        fi
        success "DMG built: $DMG_NAME"
    fi
else
    step "Skipping build (--skip-build)"
    if [ ! -f "$DMG_PATH" ]; then
        fail "DMG not found at $DMG_PATH — remove --skip-build to build it"
    fi
    info "Using existing DMG: $DMG_PATH"
    success "DMG verified"
fi

# Read SHA256
if [ -f "$SHA_PATH" ]; then
    SHA256="$(cat "$SHA_PATH" | awk '{print $1}')"
else
    if ! $DRY_RUN; then
        SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    else
        SHA256="<will-be-computed-after-build>"
    fi
fi
info "SHA256: $SHA256"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Create git tag
# ══════════════════════════════════════════════════════════════════════════════

step "Creating git tag: $TAG"

TAG_MESSAGE="${APP_NAME} ${TAG}

Release ${VERSION}
Built on $(date '+%Y-%m-%d %H:%M:%S')
Architecture: ${ARCH_NAME}
SHA256: ${SHA256}"

if $DRY_RUN; then
    info "[DRY RUN] Would create annotated tag: $TAG"
    info "[DRY RUN] Would push tag to origin"
else
    # Delete existing tag if --force
    if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
        git -C "$PROJECT_ROOT" tag -d "$TAG" 2>/dev/null || true
        git -C "$PROJECT_ROOT" push origin ":refs/tags/$TAG" 2>/dev/null || true
        info "Deleted existing tag $TAG"
    fi

    # Commit any outstanding changes (like version bumps)
    if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
        git -C "$PROJECT_ROOT" add -A
        git -C "$PROJECT_ROOT" commit -m "release: ${TAG}" || true
    fi

    # Push latest commits
    git -C "$PROJECT_ROOT" push origin main 2>&1 || warn "Push to main failed (may already be up to date)"

    # Create and push tag
    git -C "$PROJECT_ROOT" tag -a "$TAG" -m "$TAG_MESSAGE"
    git -C "$PROJECT_ROOT" push origin "$TAG"
    success "Tag $TAG created and pushed"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3: Create GitHub Release
# ══════════════════════════════════════════════════════════════════════════════

step "Creating GitHub Release"

RELEASE_NOTES="## ${APP_NAME} ${TAG}

### 📦 Installation

#### Option 1: Homebrew (Recommended)
\`\`\`bash
brew tap ${GITHUB_OWNER}/tap
brew install --cask keyvalue
\`\`\`

#### Option 2: Download DMG
1. Download the \`.dmg\` file below
2. Open the DMG and drag **KeyValue.app** into **Applications**
3. First launch: right-click KeyValue.app → select **Open**

> ⚠️ This is a free, open-source app with ad-hoc signing. macOS will warn about an unverified developer on first launch — right-click → Open to bypass.
> Alternatively: \`xattr -cr /Applications/KeyValue.app\`

### 🔐 Permissions

On first launch, the app will guide you through granting:
- **Accessibility** — simulate keyboard input
- **Input Monitoring** — create keyboard events

### 🛠️ Requirements
- macOS 13.0+ (Ventura or later)
- Apple Silicon (arm64)

---

**SHA256:** \`${SHA256}\`

**License:** [MIT](https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/blob/main/LICENSE)"

if $DRY_RUN; then
    info "[DRY RUN] Would create release: $TAG"
    info "[DRY RUN] Would upload: $DMG_NAME"
    if [ -f "$SHA_PATH" ]; then
        info "[DRY RUN] Would upload: ${DMG_NAME}.sha256"
    fi
else
    RELEASE_FLAGS=(
        --title "${APP_NAME} ${TAG}"
        --notes "$RELEASE_NOTES"
    )

    if $PRERELEASE; then
        RELEASE_FLAGS+=(--prerelease)
    fi

    # Delete existing release if --force
    if $FORCE; then
        gh release delete "$TAG" --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --yes 2>/dev/null || true
    fi

    # Build the list of assets to upload
    ASSETS=("$DMG_PATH")
    if [ -f "$SHA_PATH" ]; then
        ASSETS+=("$SHA_PATH")
    fi

    gh release create "$TAG" \
        "${ASSETS[@]}" \
        --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
        "${RELEASE_FLAGS[@]}"

    RELEASE_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    success "Release created: $RELEASE_URL"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4: Update Homebrew formula
# ══════════════════════════════════════════════════════════════════════════════

if ! $SKIP_BREW && ! $PRERELEASE; then
    step "Updating Homebrew formula"

    CASK_CONTENT="cask \"keyvalue\" do
  version \"${VERSION}\"
  sha256 \"${SHA256}\"

  url \"https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v#{version}/${APP_NAME}-#{version}-apple-silicon.dmg\"
  name \"${APP_NAME}\"
  desc \"K🔒V — Secure password & key-value manager for macOS\"
  homepage \"https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}\"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: \">= :ventura\"

  app \"${APP_NAME}.app\"

  postflight do
    # Remove quarantine attribute for ad-hoc signed app
    system_command \"/usr/bin/xattr\",
                   args: [\"-cr\", \"#{appdir}/${APP_NAME}.app\"],
                   sudo: false
  end

  zap trash: [
    \"~/Library/Application Support/com.aresnasa.mackeyvalue\",
    \"~/Library/Preferences/com.aresnasa.mackeyvalue.plist\",
    \"~/Library/Caches/com.aresnasa.mackeyvalue\",
  ]

  caveats <<~EOS
    KeyValue requires two system permissions for keyboard simulation:

      1. Accessibility: System Settings → Privacy & Security → Accessibility
      2. Input Monitoring: System Settings → Privacy & Security → Input Monitoring

    The app will guide you through the setup on first launch.

    Since this is an ad-hoc signed open-source app, if macOS blocks it:
      xattr -cr /Applications/${APP_NAME}.app
  EOS
end
"

    if $DRY_RUN; then
        info "[DRY RUN] Would update Casks/keyvalue.rb in ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}"
        info "[DRY RUN] New version: $VERSION"
        info "[DRY RUN] New SHA256:  $SHA256"
    else
        # Clone the tap repo, update the formula, push
        BREW_TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$BREW_TMPDIR"' EXIT

        info "Cloning ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}…"
        gh repo clone "${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}" "$BREW_TMPDIR" -- --depth 1 2>&1 | while IFS= read -r line; do
            info "$line"
        done

        # Ensure Casks directory exists
        mkdir -p "$BREW_TMPDIR/Casks"

        # Write the updated formula
        echo "$CASK_CONTENT" > "$BREW_TMPDIR/Casks/keyvalue.rb"
        info "Formula written: Casks/keyvalue.rb"

        # Commit and push
        cd "$BREW_TMPDIR"
        git add -A
        if git diff --cached --quiet; then
            info "No changes to Homebrew formula (already up to date)"
        else
            git commit -m "Update keyvalue to ${VERSION}

SHA256: ${SHA256}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"

            git push origin main 2>&1 | while IFS= read -r line; do
                info "$line"
            done
            success "Homebrew formula updated to ${VERSION}"
        fi

        cd "$PROJECT_ROOT"
        rm -rf "$BREW_TMPDIR"
        trap - EXIT
    fi
elif $PRERELEASE; then
    step "Skipping Homebrew update (pre-release)"
    info "Pre-release versions are not published to Homebrew"
elif $SKIP_BREW; then
    step "Skipping Homebrew update (--skip-brew)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Summary
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
if $DRY_RUN; then
    echo -e "${YELLOW}${BOLD}  🏜️  Dry run complete — no changes were made${RESET}"
else
    echo -e "${GREEN}${BOLD}  🎉  Release ${TAG} published successfully!${RESET}"
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""

if ! $DRY_RUN; then
    echo -e "  ${DIM}GitHub Release:${RESET}"
    echo -e "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo -e "  ${DIM}DMG Download:${RESET}"
    echo -e "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${TAG}/${DMG_NAME}"
    echo ""
    if ! $SKIP_BREW && ! $PRERELEASE; then
        echo -e "  ${DIM}Homebrew Install:${RESET}"
        echo -e "    brew tap ${GITHUB_OWNER}/tap"
        echo -e "    brew install --cask keyvalue"
        echo ""
    fi
    echo -e "  ${DIM}SHA256:${RESET} ${SHA256}"
fi

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "  ${DIM}GitHub:${RESET}  https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
echo -e "  ${DIM}License:${RESET} MIT"
echo -e "  ${DIM}Donate:${RESET}  在应用内 关于 → 请喝咖啡 ☕"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
