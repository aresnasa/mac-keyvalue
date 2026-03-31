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
#    5. Update Homebrew tap formula (with brew style + fetch validation)
#
#  Usage:
#    ./scripts/release.sh 1.2.3              # Release v1.2.3
#    ./scripts/release.sh 1.2.3 --dry-run    # Preview without publishing
#    ./scripts/release.sh 1.2.3 --skip-brew  # Skip Homebrew update
#    ./scripts/release.sh 1.2.3 --fix-sha    # Re-download DMGs & fix Cask SHA only
#    ./scripts/release.sh --help             # Show help
#
#  Prerequisites:
#    - gh CLI authenticated (gh auth status)
#    - git with push access to origin
#    - Xcode / Swift toolchain
#
#  Notes on multi-arch:
#    The cask formula only includes on_arm / on_intel blocks for DMG files
#    that are actually present in the GitHub Release.  If you are building
#    on Apple Silicon without a cross-compiled Intel DMG, the cask will be
#    ARM-only — Intel blocks are never synthesised from wrong data.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="${PROJECT_ROOT}/MacKeyValue/build.sh"
DIST_DIR="${PROJECT_ROOT}/MacKeyValue/dist"

GITHUB_OWNER="aresnasa"
GITHUB_REPO="mac-keyvalue"
HOMEBREW_TAP_REPO="homebrew-tap"
APP_NAME="KeyValue"
LOCAL_TAP_CASK="/opt/homebrew/Library/Taps/${GITHUB_OWNER}/homebrew-tap/Casks/keyvalue.rb"

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

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: verify_dmgs_from_github
#
#  Downloads each architecture's DMG from a GitHub Release and computes its
#  SHA256.  An architecture is only flagged as available when the download
#  actually succeeds — there is NO silent fallback to another arch's hash.
#
#  Args : $1 = tag (e.g. "v1.2.3")  $2 = writable temp directory
#  Sets : HAS_ARM  HAS_INTEL  (bool strings "true"/"false")
#         SHA256_ARM  SHA256_INTEL  (hex strings, empty when not available)
#  Exits: non-zero when neither DMG is present (release not yet published)
# ══════════════════════════════════════════════════════════════════════════════
verify_dmgs_from_github() {
    local tag="$1" tmpdir="$2"

    HAS_ARM=false
    HAS_INTEL=false
    SHA256_ARM=""
    SHA256_INTEL=""

    local url_arm="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${VERSION}-apple-silicon.dmg"
    local url_intel="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${VERSION}-intel.dmg"

    info "Downloading ARM DMG from GitHub Release…"
    if curl -fsSL --progress-bar -o "${tmpdir}/arm.dmg" "$url_arm" 2>&1; then
        SHA256_ARM="$(shasum -a 256 "${tmpdir}/arm.dmg" | awk '{print $1}')"
        HAS_ARM=true
        success "SHA256 (arm64):  $SHA256_ARM"
    else
        warn "ARM DMG not found in release ${tag} — on_arm block will be omitted"
    fi

    info "Downloading Intel DMG from GitHub Release…"
    if curl -fsSL --progress-bar -o "${tmpdir}/intel.dmg" "$url_intel" 2>&1; then
        SHA256_INTEL="$(shasum -a 256 "${tmpdir}/intel.dmg" | awk '{print $1}')"
        HAS_INTEL=true
        success "SHA256 (x86_64): $SHA256_INTEL"
    else
        warn "Intel DMG not found in release ${tag} — on_intel block will be omitted"
    fi

    if ! $HAS_ARM && ! $HAS_INTEL; then
        fail "No DMGs found in GitHub Release ${tag}. Is the release published?"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: build_cask_content
#
#  Generates the complete Homebrew cask Ruby file and writes it to stdout.
#  Architecture blocks (on_arm / on_intel) are emitted only for the DMGs
#  that were confirmed to exist in the release by verify_dmgs_from_github.
#
#  Uses globals: VERSION  HAS_ARM  HAS_INTEL  SHA256_ARM  SHA256_INTEL
#                GITHUB_OWNER  GITHUB_REPO  APP_NAME
# ══════════════════════════════════════════════════════════════════════════════
build_cask_content() {
    # Build only the blocks whose DMGs actually exist
    local arch_section=""

    if $HAS_ARM; then
        arch_section+="  on_arm do
    sha256 \"${SHA256_ARM}\"
    url \"https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v#{version}/${APP_NAME}-#{version}-apple-silicon.dmg\"
  end"
    fi

    if $HAS_INTEL; then
        [ -n "$arch_section" ] && arch_section+=$'\n'
        arch_section+="  on_intel do
    sha256 \"${SHA256_INTEL}\"
    url \"https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v#{version}/${APP_NAME}-#{version}-intel.dmg\"
  end"
    fi

    # NOTE: bash expands ${...} variables; Ruby #{...} tokens have no leading $
    # so they pass through the heredoc unchanged — exactly what Homebrew needs.
    cat <<CASK_EOF
cask "keyvalue" do
  version "${VERSION}"

${arch_section}

  name "${APP_NAME}"
  desc "K🔒V — Secure password & key-value manager"
  homepage "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "${APP_NAME}.app"

  postflight do
    # 1. Strip extended attributes (removes quarantine flag)
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/${APP_NAME}.app"],
                   sudo: false

    # 2. Re-sign nested frameworks / dylibs with ad-hoc identity.
    #    Skip .bundle dirs that lack Info.plist (not real signable bundles,
    #    e.g. swift-crypto_Crypto.bundle only contains PrivacyInfo.xcprivacy).
    Dir.glob("#{appdir}/${APP_NAME}.app/Contents/**/*.{framework,dylib}").each do |nested|
      system_command "/usr/bin/codesign",
                     args: ["--force", "--sign", "-", "--timestamp=none", nested],
                     sudo: false
    end
    Dir.glob("#{appdir}/${APP_NAME}.app/Contents/**/*.bundle").each do |nested|
      next unless File.exist?(File.join(nested, "Info.plist"))
      system_command "/usr/bin/codesign",
                     args: ["--force", "--sign", "-", "--timestamp=none", nested],
                     sudo: false
    end

    # 3. Re-sign the main app bundle with ad-hoc identity + entitlements.
    #    The build-machine signature is invalidated when Homebrew copies the
    #    .app; without re-signing macOS 14+ / Sequoia blocks the app.
    ent = "#{appdir}/${APP_NAME}.app/Contents/Resources/MacKeyValue-adhoc.entitlements"
    codesign_args = ["--force", "--sign", "-", "--timestamp=none"]
    codesign_args += ["--entitlements", ent] if File.exist?(ent)
    codesign_args << "#{appdir}/${APP_NAME}.app"
    system_command "/usr/bin/codesign",
                   args: codesign_args,
                   sudo: false

    # 4. Touch the bundle so Launch Services picks up the new signature.
    system_command "/usr/bin/touch",
                   args: ["#{appdir}/${APP_NAME}.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/com.aresnasa.mackeyvalue",
    "~/Library/Preferences/com.aresnasa.mackeyvalue.plist",
    "~/Library/Caches/com.aresnasa.mackeyvalue",
  ]

  caveats <<~EOS
    KeyValue requires two system permissions for keyboard simulation:

      1. Accessibility: System Settings → Privacy & Security → Accessibility
      2. Input Monitoring: System Settings → Privacy & Security → Input Monitoring

    The app will guide you through the setup on first launch.

    If macOS blocks the app after install or upgrade, run:
      xattr -cr /Applications/${APP_NAME}.app
      codesign --force --sign - --timestamp=none /Applications/${APP_NAME}.app
  EOS
end
CASK_EOF
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: push_cask_to_tap
#
#  1. Clones the Homebrew tap repo into a temp directory.
#  2. Writes the cask file.
#  3. Runs brew style --fix (auto-correct), then fails on remaining offenses.
#  4. Commits & pushes to GitHub.
#  5. Overwrites the local tap file for immediate use.
#  6. Runs brew fetch to verify the URL and SHA256 work end-to-end.
#
#  Args: $1 = dry_run ("true"/"false")
#        $2 = cask file content (multi-line string)
#        $3 = git commit message
# ══════════════════════════════════════════════════════════════════════════════
push_cask_to_tap() {
    local dry_run="$1"
    local cask_content="$2"
    local commit_msg="$3"

    if $dry_run; then
        info "[DRY RUN] Would update Casks/keyvalue.rb in ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}"
        echo ""
        echo "$cask_content"
        return 0
    fi

    local brew_tmpdir
    brew_tmpdir="$(mktemp -d)"

    info "Cloning ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}…"
    gh repo clone "${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}" "$brew_tmpdir" -- --depth 1 2>&1 \
        | while IFS= read -r line; do info "$line"; done

    mkdir -p "$brew_tmpdir/Casks"
    # printf '%s\n' avoids echo interpreting escape sequences in the content
    printf '%s\n' "$cask_content" > "$brew_tmpdir/Casks/keyvalue.rb"
    info "Cask written: Casks/keyvalue.rb"

    # ── Style validation ───────────────────────────────────────────────────
    step "Validating cask style (brew style)"

    # Auto-fix what rubocop can; ignore exit code (non-zero when it made fixes)
    brew style --fix "$brew_tmpdir/Casks/keyvalue.rb" 2>&1 \
        | while IFS= read -r line; do info "$line"; done || true

    # Re-run without --fix to get the final verdict
    local style_out
    style_out="$(mktemp)"
    if ! brew style "$brew_tmpdir/Casks/keyvalue.rb" >"$style_out" 2>&1; then
        cat "$style_out" | while IFS= read -r line; do warn "$line"; done
        rm -f "$style_out"
        rm -rf "$brew_tmpdir"
        fail "brew style offenses remain after auto-fix — fix the cask template in release.sh"
    fi
    rm -f "$style_out"
    success "brew style: clean"

    # ── Commit & push ──────────────────────────────────────────────────────
    git -C "$brew_tmpdir" add -A
    if git -C "$brew_tmpdir" diff --cached --quiet; then
        info "Homebrew formula already up to date (no changes to push)"
    else
        git -C "$brew_tmpdir" commit -m "$commit_msg"
        git -C "$brew_tmpdir" push origin main 2>&1 \
            | while IFS= read -r line; do info "$line"; done
        success "Formula pushed to ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}"
    fi

    # ── Update local tap for immediate availability ────────────────────────
    if [ -f "$LOCAL_TAP_CASK" ]; then
        printf '%s\n' "$cask_content" > "$LOCAL_TAP_CASK"
        success "Local tap updated: $LOCAL_TAP_CASK"
    fi

    rm -rf "$brew_tmpdir"

    # ── End-to-end download verification ──────────────────────────────────
    # brew fetch reads the local tap (just updated), downloads the DMG, and
    # validates the SHA256.  Uses the Homebrew cache, so re-runs are fast.
    step "Verifying cask download (brew fetch)"
    if brew fetch --cask "${GITHUB_OWNER}/tap/keyvalue" 2>&1 \
            | while IFS= read -r line; do info "$line"; done; then
        success "brew fetch: URL reachable and SHA256 verified ✓"
    else
        warn "brew fetch reported an issue (non-fatal — release already published)"
        warn "Manual check: brew fetch --cask ${GITHUB_OWNER}/tap/keyvalue"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════

VERSION=""
DRY_RUN=false
SKIP_BREW=false
SKIP_BUILD=false
PRERELEASE=false
FORCE=false
FIX_SHA=false

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
║    --dry-run       Preview all steps without executing       ║
║    --skip-brew     Skip Homebrew formula update              ║
║    --skip-build    Skip DMG build (use existing dist/)       ║
║    --fix-sha       Re-download DMGs & fix Cask SHA only      ║
║    --force         Force release even if tag exists          ║
║    --help          Show this help                            ║
║                                                              ║
║  EXAMPLES                                                    ║
║    ./scripts/release.sh 1.0.0                                ║
║    ./scripts/release.sh 1.1.0 --dry-run                      ║
║    ./scripts/release.sh 2.0.0-beta.1 --skip-brew             ║
║    ./scripts/release.sh 0.1.1 --fix-sha                      ║
║                                                              ║
║  NOTES                                                       ║
║    • Cask includes only on_arm/on_intel blocks for DMGs      ║
║      that actually exist in the GitHub Release.              ║
║    • brew style is validated & auto-fixed before commit.     ║
║    • brew fetch is run after push to confirm end-to-end.     ║
║    • Pre-releases skip the Homebrew update automatically.    ║
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
        --dry-run)    DRY_RUN=true ;;
        --skip-brew)  SKIP_BREW=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --fix-sha)    FIX_SHA=true; SKIP_BUILD=true ;;
        --force)      FORCE=true ;;
        --help|-h)    show_help ;;
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
    echo "Run '$0 --help' for full documentation"
    exit 1
fi

# Validate semantic version
if ! echo "$VERSION" | grep -qE -e '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
    fail "Invalid version format: '$VERSION' (expected: MAJOR.MINOR.PATCH[-prerelease])"
fi

# Detect pre-release suffix
if echo "$VERSION" | grep -qE -e '-(alpha|beta|rc|dev)'; then
    PRERELEASE=true
fi

TAG="v${VERSION}"
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] && ARCH_NAME="intel" || ARCH_NAME="apple-silicon"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH_NAME}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"

# "Other" arch — cross-compiled or copied from another machine into dist/
if [ "$ARCH_NAME" = "apple-silicon" ]; then
    OTHER_ARCH_NAME="intel"
else
    OTHER_ARCH_NAME="apple-silicon"
fi
OTHER_DMG_NAME="${APP_NAME}-${VERSION}-${OTHER_ARCH_NAME}.dmg"
OTHER_DMG_PATH="${DIST_DIR}/${OTHER_DMG_NAME}"

# ══════════════════════════════════════════════════════════════════════════════
#  --fix-sha: Re-download DMGs, recompute SHA256, update the tap formula.
#  No build, no tag, no GitHub Release — just fix the cask.
# ══════════════════════════════════════════════════════════════════════════════

if $FIX_SHA; then
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║   KeyValue – Fix Cask SHA256                     ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${DIM}Version:${RESET} ${BOLD}${VERSION}${RESET} (tag: ${TAG})"
    echo -e "  ${DIM}Dry run:${RESET} $($DRY_RUN && echo "${YELLOW}YES${RESET}" || echo "no")"
    echo ""

    step "Downloading DMGs from GitHub Release to verify SHA256"
    VTMPDIR="$(mktemp -d)"
    verify_dmgs_from_github "$TAG" "$VTMPDIR"
    rm -rf "$VTMPDIR"

    step "Building Homebrew cask formula"
    CASK_CONTENT="$(build_cask_content)"

    step "Updating Homebrew tap"
    COMMIT_MSG="Fix SHA256 for keyvalue ${VERSION}"
    if $HAS_ARM && $HAS_INTEL; then
        COMMIT_MSG+="

arm64:  ${SHA256_ARM}
x86_64: ${SHA256_INTEL}"
    elif $HAS_ARM; then
        COMMIT_MSG+=" (ARM-only)

arm64: ${SHA256_ARM}"
    else
        COMMIT_MSG+=" (Intel-only)

x86_64: ${SHA256_INTEL}"
    fi

    push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "$COMMIT_MSG"

    echo ""
    echo -e "${GREEN}${BOLD}  ✅  SHA256 fixed for ${TAG}${RESET}"
    echo ""
    $HAS_ARM   && echo -e "  ${DIM}arm64:${RESET}  ${SHA256_ARM}"
    $HAS_INTEL && echo -e "  ${DIM}x86_64:${RESET} ${SHA256_INTEL}"
    echo ""
    echo -e "  ${DIM}To install / upgrade:${RESET}"
    echo -e "    brew tap ${GITHUB_OWNER}/tap && brew install --cask keyvalue"
    echo -e "    ${DIM}# or${RESET}"
    echo -e "    brew update && brew upgrade --cask keyvalue"
    echo ""
    exit 0
fi

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

if ! command -v gh &>/dev/null; then
    fail "gh CLI not found. Install: brew install gh"
fi
if ! gh auth status &>/dev/null 2>&1; then
    fail "gh CLI not authenticated. Run: gh auth login"
fi
success "gh CLI authenticated"

if ! git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null; then
    fail "Not a git repository: $PROJECT_ROOT"
fi

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

if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
    if $FORCE; then
        warn "Tag $TAG already exists — will be overwritten (--force)"
    else
        fail "Tag $TAG already exists. Use --force to overwrite."
    fi
fi

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
        info "[DRY RUN] Would run: MARKETING_VERSION=${VERSION} bash build.sh --ci --dmg"
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
    if ! $DRY_RUN && [ ! -f "$DMG_PATH" ]; then
        fail "DMG not found at $DMG_PATH — remove --skip-build to build it"
    fi
    info "Using existing DMG: ${DMG_PATH}"
    success "DMG verified"
fi

# Local SHA256 — used in the tag message and release notes.
# The cask formula always uses the re-verified SHA from GitHub (STEP 4).
LOCAL_SHA256=""
if [ -f "$SHA_PATH" ]; then
    LOCAL_SHA256="$(awk '{print $1}' "$SHA_PATH")"
elif ! $DRY_RUN && [ -f "$DMG_PATH" ]; then
    LOCAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
else
    LOCAL_SHA256="<computed-after-build>"
fi
info "SHA256 (local, ${ARCH_NAME}): $LOCAL_SHA256"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Create git tag
# ══════════════════════════════════════════════════════════════════════════════

step "Creating git tag: $TAG"

TAG_MESSAGE="${APP_NAME} ${TAG}

Release ${VERSION}
Built on $(date '+%Y-%m-%d %H:%M:%S')
Architecture: ${ARCH_NAME}
SHA256: ${LOCAL_SHA256}"

if $DRY_RUN; then
    info "[DRY RUN] Would create annotated tag: $TAG"
    info "[DRY RUN] Would push tag to origin"
else
    # Delete existing local + remote tag when --force
    if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
        git -C "$PROJECT_ROOT" tag -d "$TAG" 2>/dev/null || true
        git -C "$PROJECT_ROOT" push origin ":refs/tags/$TAG" 2>/dev/null || true
        info "Deleted existing tag $TAG"
    fi

    # Commit any outstanding file changes (e.g. version bumps)
    if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
        git -C "$PROJECT_ROOT" add -A
        git -C "$PROJECT_ROOT" commit -m "release: ${TAG}" || true
    fi

    git -C "$PROJECT_ROOT" push origin main 2>&1 \
        || warn "Push to main skipped (already up to date)"

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

> ⚠️ This is a free, open-source app with ad-hoc signing. macOS may warn about an unverified developer on first launch — right-click → Open to bypass.
> Alternatively: \`xattr -cr /Applications/KeyValue.app\`

### 🔐 Permissions

On first launch, the app will guide you through granting:
- **Accessibility** — simulate keyboard input
- **Input Monitoring** — create keyboard events

### 🛠️ Requirements
- macOS 13.0+ (Ventura or later)
- Apple Silicon (arm64) or Intel (x86_64)

### ⬆️ Upgrading

**Homebrew:**
\`\`\`bash
brew update && brew upgrade --cask keyvalue
\`\`\`

**DMG / Direct download** — the app auto-downloads the matching DMG, replaces itself, and restarts.

---

**SHA256 (${ARCH_NAME}):** \`${LOCAL_SHA256}\`

**License:** [MIT](https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/blob/main/LICENSE)"

if $DRY_RUN; then
    info "[DRY RUN] Would create GitHub Release: $TAG"
    info "[DRY RUN] Primary asset:  $DMG_NAME"
    [ -f "$SHA_PATH" ]       && info "[DRY RUN] Checksum file: ${DMG_NAME}.sha256"
    [ -f "$OTHER_DMG_PATH" ] && info "[DRY RUN] Other arch:    $OTHER_DMG_NAME"
else
    RELEASE_FLAGS=(
        --title "${APP_NAME} ${TAG}"
        --notes "$RELEASE_NOTES"
    )
    $PRERELEASE && RELEASE_FLAGS+=(--prerelease)

    # Remove stale release when --force
    if $FORCE; then
        gh release delete "$TAG" --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --yes 2>/dev/null || true
    fi

    # Collect assets: primary arch DMG + optional checksum + optional other arch
    ASSETS=("$DMG_PATH")
    [ -f "$SHA_PATH" ] && ASSETS+=("$SHA_PATH")

    if [ -f "$OTHER_DMG_PATH" ]; then
        ASSETS+=("$OTHER_DMG_PATH")
        OTHER_SHA_PATH="${OTHER_DMG_PATH}.sha256"
        [ -f "$OTHER_SHA_PATH" ] && ASSETS+=("$OTHER_SHA_PATH")
        info "Including other-arch DMG: $OTHER_DMG_NAME"
    else
        warn "Other-arch DMG not found at: $OTHER_DMG_PATH"
        warn "Cask will be ${ARCH_NAME}-only until the other DMG is uploaded."
        warn "Cross-compile or copy the DMG to dist/ and re-run with --skip-build."
    fi

    gh release create "$TAG" \
        "${ASSETS[@]}" \
        --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
        "${RELEASE_FLAGS[@]}"

    success "Release created: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4: Update Homebrew formula
#
#  Re-downloads the DMGs that were just published to GitHub and computes their
#  SHA256 values fresh.  Only architectures with a real download get a block
#  in the cask — no silent SHA fallback to another architecture.
# ══════════════════════════════════════════════════════════════════════════════

if ! $SKIP_BREW && ! $PRERELEASE; then
    step "Updating Homebrew formula"

    if $DRY_RUN; then
        # Simulate the arch flags based on what we plan to upload
        HAS_ARM=false
        HAS_INTEL=false
        SHA256_ARM="<verified-after-upload>"
        SHA256_INTEL="<verified-after-upload>"
        [ "$ARCH_NAME" = "apple-silicon" ] && HAS_ARM=true
        [ "$ARCH_NAME" = "intel" ]         && HAS_INTEL=true
        [ -f "$OTHER_DMG_PATH" ] && {
            [ "$OTHER_ARCH_NAME" = "apple-silicon" ] && HAS_ARM=true
            [ "$OTHER_ARCH_NAME" = "intel" ]         && HAS_INTEL=true
        }
    else
        VTMPDIR="$(mktemp -d)"
        verify_dmgs_from_github "$TAG" "$VTMPDIR"
        rm -rf "$VTMPDIR"
    fi

    CASK_CONTENT="$(build_cask_content)"

    # Build a descriptive commit message showing the actual SHA values
    BREW_COMMIT_MSG="Update keyvalue to ${VERSION}"
    if $HAS_ARM && $HAS_INTEL; then
        BREW_COMMIT_MSG+="

arm64:  ${SHA256_ARM}
x86_64: ${SHA256_INTEL}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    elif $HAS_ARM; then
        BREW_COMMIT_MSG+=" (ARM-only)

arm64:  ${SHA256_ARM}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    else
        BREW_COMMIT_MSG+=" (Intel-only)

x86_64: ${SHA256_INTEL}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    fi

    push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "$BREW_COMMIT_MSG"

elif $PRERELEASE; then
    step "Skipping Homebrew update (pre-release)"
    info "Pre-release versions are not published to Homebrew tap"
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
        echo -e "  ${DIM}Homebrew Upgrade:${RESET}"
        echo -e "    brew update && brew upgrade --cask keyvalue"
        echo ""
        if $HAS_ARM && $HAS_INTEL; then
            echo -e "  ${DIM}Architectures published:${RESET} arm64 + x86_64"
            echo -e "  ${DIM}SHA256 (arm64):${RESET}  ${SHA256_ARM}"
            echo -e "  ${DIM}SHA256 (x86_64):${RESET} ${SHA256_INTEL}"
        elif $HAS_ARM; then
            echo -e "  ${DIM}Architectures published:${RESET} arm64 only"
            echo -e "  ${DIM}SHA256 (arm64):${RESET} ${SHA256_ARM}"
        else
            echo -e "  ${DIM}Architectures published:${RESET} x86_64 only"
            echo -e "  ${DIM}SHA256 (x86_64):${RESET} ${SHA256_INTEL}"
        fi
        echo ""
    else
        echo -e "  ${DIM}SHA256 (${ARCH_NAME}):${RESET} ${LOCAL_SHA256}"
        echo ""
    fi
fi

echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "  ${DIM}GitHub:${RESET}  https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
echo -e "  ${DIM}License:${RESET} MIT"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
