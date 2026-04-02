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
#    ./scripts/release.sh 1.2.3 --windows-package both --build-windows
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

# ── Windows / winget ──────────────────────────────────────────────────────────
WINGET_PACKAGE_ID="aresnasa.KeyValue"          # Publisher.AppName in winget-pkgs
WINGET_PKGS_FORK="${GITHUB_OWNER}/winget-pkgs" # user's fork of microsoft/winget-pkgs
WINDOWS_DIST_DIR="${PROJECT_ROOT}/windows/dist"
WINDOWS_PROJECT="${PROJECT_ROOT}/windows/KeyValueWin/KeyValueWin.csproj"

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

run_git_push_with_retry() {
    local repo_dir="$1"
    shift
    local attempts=3
    local i out rc

    for ((i=1; i<=attempts; i++)); do
        if [ -n "${RELEASE_PROXY:-}" ]; then
            out="$(git -C "$repo_dir" -c http.proxy="$RELEASE_PROXY" -c https.proxy="$RELEASE_PROXY" push "$@" 2>&1)"
            rc=$?
        else
            out="$(git -C "$repo_dir" push "$@" 2>&1)"
            rc=$?
        fi

        if [ $rc -eq 0 ]; then
            [ -n "$out" ] && echo "$out"
            return 0
        fi

        if echo "$out" | grep -qiE 'SSL_ERROR_SYSCALL|Couldn.t connect|Failed to connect|timed out|Connection reset|HTTP2 framing'; then
            warn "git push network/TLS issue (attempt ${i}/${attempts})"
            [ $i -lt $attempts ] && sleep 2 && continue
        fi

        echo "$out"
        return $rc
    done

    return 1
}

is_windows_host() {
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) return 0 ;;
    esac
    [ "$(uname -s 2>/dev/null || true)" = "MINGW64_NT" ] && return 0
    [ "$(uname -s 2>/dev/null || true)" = "MINGW32_NT" ] && return 0
    [ "${OS:-}" = "Windows_NT" ] && return 0
    return 1
}

msi_version_from_semver() {
    local raw="$1"
    local base="${raw%%-*}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$base"
    major="${major:-1}"
    minor="${minor:-0}"
    patch="${patch:-0}"
    echo "${major}.${minor}.${patch}.0"
}

resolve_windows_asset_path() {
    local expected="$1"
    local fallback="$2"
    if [ -f "$expected" ]; then
        echo "$expected"
        return 0
    fi
    if [ -f "$fallback" ]; then
        cp "$fallback" "$expected"
        echo "$expected"
        return 0
    fi
    echo ""
    return 1
}

build_windows_packages_local() {
    local mode="$1"
    local version="$2"
    local publish_out="${WINDOWS_DIST_DIR}/publish-win-x64"
    local exe_target="${WINDOWS_DIST_DIR}/KeyValueWin-${version}-win-x64.exe"
    local msi_target="${WINDOWS_DIST_DIR}/KeyValueWin-${version}-win-x64.msi"
    local wix_ver
    wix_ver="$(msi_version_from_semver "$version")"

    if ! is_windows_host; then
        warn "Current host is not Windows; attempting cross-build for win-x64 via dotnet/wix"
        warn "If toolchain is incomplete, provide prebuilt files in windows/dist and rerun with --skip-build"
    fi

    command -v dotnet >/dev/null 2>&1 || fail "dotnet not found. Install .NET SDK first."
    mkdir -p "$WINDOWS_DIST_DIR"
    rm -rf "$publish_out"

    step "Building Windows EXE (dotnet publish -r win-x64)"
    dotnet publish "$WINDOWS_PROJECT" \
        -c Release \
        -r win-x64 \
        --self-contained true \
        -p:PublishSingleFile=true \
        -p:IncludeNativeLibrariesForSelfExtract=true \
        -o "$publish_out"

    [ -f "${publish_out}/KeyValueWin.exe" ] || fail "Windows EXE not found in publish output"
    cp "${publish_out}/KeyValueWin.exe" "$exe_target"
    success "Windows EXE built: $(basename "$exe_target")"

    if [ "$mode" = "exe" ]; then
        return 0
    fi

    if ! command -v wix >/dev/null 2>&1; then
        warn "WiX CLI not found; MSI generation skipped"
        warn "Install WiX Toolset v4 and rerun with --build-windows"
        return 1
    fi

    local wxs_file
    wxs_file="$(mktemp -t keyvalue-release-installer.XXXXXX.wxs)"
    cat > "$wxs_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package
      Name="KeyValue"
      Manufacturer="aresnasa"
      Version="${wix_ver}"
      UpgradeCode="A6A3AE31-F1D9-4D0D-8B92-8DCE89977821"
      Language="1033"
      InstallerVersion="500"
      Scope="perMachine">
    <MediaTemplate EmbedCab="yes" />

    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="KeyValue">
        <Component Id="cmpKeyValueExe" Guid="*">
          <File Id="filKeyValueExe" Source="${publish_out}/KeyValueWin.exe" KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>

    <Feature Id="MainFeature" Title="KeyValue" Level="1">
      <ComponentRef Id="cmpKeyValueExe" />
    </Feature>
  </Package>
</Wix>
EOF

    step "Building Windows MSI (WiX v4)"
    wix build "$wxs_file" -arch x64 -o "$msi_target"
    rm -f "$wxs_file"
    success "Windows MSI built: $(basename "$msi_target")"
    return 0
}

build_other_macos_dmg() {
    local version="$1"
    local primary_arch_name="$2"
    local target_arch=""
    local target_label=""

    if [ "$primary_arch_name" = "apple-silicon" ]; then
        target_arch="x86_64"
        target_label="intel"
    elif [ "$primary_arch_name" = "intel" ]; then
        target_arch="arm64"
        target_label="apple-silicon"
    else
        return 0
    fi

    local target_dmg="${DIST_DIR}/${APP_NAME}-${version}-${target_label}.dmg"
    if [ -f "$target_dmg" ]; then
        info "Other-arch DMG already present: $(basename "$target_dmg")"
        return 0
    fi

    step "Building additional macOS DMG for ${target_label}"
    (
        cd "${PROJECT_ROOT}/MacKeyValue"
        MARKETING_VERSION="$version" bash build.sh --ci --dmg --target-arch "$target_arch"
    )

    [ -f "$target_dmg" ] || fail "Other-arch DMG not found after cross-build: $target_dmg"
    success "Additional macOS DMG built: $(basename "$target_dmg")"
}

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
    local curl_common=(--retry 2 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 45)
    local network_error=false

    # Fast preflight: if GitHub itself is unreachable, fail fast instead of
    # waiting through per-asset retries/timeouts.
    if ! curl -fsSIL --connect-timeout 8 --max-time 12 https://github.com >/dev/null 2>&1; then
        warn "GitHub connectivity check failed (github.com unreachable)"
        return 2
    fi

    HAS_UNIVERSAL=false; SHA256_UNIVERSAL=""
    HAS_ARM=false;       SHA256_ARM=""
    HAS_INTEL=false;     SHA256_INTEL=""

    local url_univ="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${VERSION}-universal.dmg"
    local url_arm="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${VERSION}-apple-silicon.dmg"
    local url_intel="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${VERSION}-intel.dmg"

    local err_univ="${tmpdir}/curl-universal.err"
    local err_arm="${tmpdir}/curl-arm.err"
    local err_intel="${tmpdir}/curl-intel.err"

    info "Downloading universal DMG from GitHub Release…"
    if curl -fsSL "${curl_common[@]}" --progress-bar -o "${tmpdir}/universal.dmg" "$url_univ" 2>"$err_univ"; then
        SHA256_UNIVERSAL="$(shasum -a 256 "${tmpdir}/universal.dmg" | awk '{print $1}')"
        HAS_UNIVERSAL=true
        success "SHA256 (universal): $SHA256_UNIVERSAL"
    else
        if grep -qiE 'Couldn.t connect|Failed to connect|timed out|HTTP2 framing|Connection reset|SSL|network' "$err_univ"; then
            network_error=true
            warn "Universal DMG download failed due to network issues"
        else
            warn "Universal DMG not found in release ${tag} — checking arch-specific DMGs"
        fi
    fi

    info "Downloading ARM DMG from GitHub Release…"
    if curl -fsSL "${curl_common[@]}" --progress-bar -o "${tmpdir}/arm.dmg" "$url_arm" 2>"$err_arm"; then
        SHA256_ARM="$(shasum -a 256 "${tmpdir}/arm.dmg" | awk '{print $1}')"
        HAS_ARM=true
        success "SHA256 (arm64):    $SHA256_ARM"
    else
        if grep -qiE 'Couldn.t connect|Failed to connect|timed out|HTTP2 framing|Connection reset|SSL|network' "$err_arm"; then
            network_error=true
            warn "ARM DMG download failed due to network issues"
        else
            warn "ARM DMG not found in release ${tag} — on_arm block will be omitted"
        fi
    fi

    info "Downloading Intel DMG from GitHub Release…"
    if curl -fsSL "${curl_common[@]}" --progress-bar -o "${tmpdir}/intel.dmg" "$url_intel" 2>"$err_intel"; then
        SHA256_INTEL="$(shasum -a 256 "${tmpdir}/intel.dmg" | awk '{print $1}')"
        HAS_INTEL=true
        success "SHA256 (x86_64):   $SHA256_INTEL"
    else
        if grep -qiE 'Couldn.t connect|Failed to connect|timed out|HTTP2 framing|Connection reset|SSL|network' "$err_intel"; then
            network_error=true
            warn "Intel DMG download failed due to network issues"
        else
            warn "Intel DMG not found in release ${tag} — on_intel block will be omitted"
        fi
    fi

    if ! $HAS_UNIVERSAL && ! $HAS_ARM && ! $HAS_INTEL; then
        if $network_error; then
            return 2
        fi
        return 1
    fi

    return 0
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
    # ── Common bottom section (postflight / zap / caveats) ────────────────
    # Captured once so it can be shared between the universal and arch branches.
    local bottom
    bottom="$(cat <<BOTTOM_EOF

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
    "~/Library/Caches/com.aresnasa.mackeyvalue",
    "~/Library/Preferences/com.aresnasa.mackeyvalue.plist",
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
BOTTOM_EOF
)"

    if $HAS_UNIVERSAL; then
        # ── Universal binary template ──────────────────────────────────────
        # Stanza grouping rules for top-level (non-arch-block) casks:
        #   • version + sha256 → SAME group → no blank line between them
        #   • sha256 + url     → DIFFERENT groups → one blank line between them
        #   • url + name + desc + homepage → SAME group → no blank lines between them
        cat <<CASK_EOF
cask "keyvalue" do
  version "${VERSION}"
  sha256 "${SHA256_UNIVERSAL}"

  url "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v#{version}/${APP_NAME}-#{version}-universal.dmg"
  name "${APP_NAME}"
  desc "KV - Secure password & key-value manager"
  homepage "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
${bottom}
CASK_EOF
    else
        # ── Arch-specific template (on_arm / on_intel) ─────────────────────
        # Stanza grouping rules:
        #   • version + on_arm/on_intel → DIFFERENT groups → blank line between them
        #   • on_arm and on_intel       → SAME group → no blank line between them
        #   • inside each block: sha256 + url → DIFFERENT sub-groups → blank line between them
        #   • last arch block + name    → DIFFERENT groups → blank line between them
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

        cat <<CASK_EOF
cask "keyvalue" do
  version "${VERSION}"

${arch_section}

  name "${APP_NAME}"
  desc "KV - Secure password & key-value manager"
  homepage "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
${bottom}
CASK_EOF
    fi
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
#  Helper: build_winget_manifests
#
#  Generates the three YAML manifest files required by microsoft/winget-pkgs:
#    • <PackageId>.yaml          (version manifest)
#    • <PackageId>.installer.yaml
#    • <PackageId>.locale.en-US.yaml
#
#  Args : $1 = dest directory (manifests/<char>/<Publisher>/<App>/<version>/)
#         $2 = Windows EXE installer URL
#         $3 = Windows EXE SHA256
# ══════════════════════════════════════════════════════════════════════════════
build_winget_manifests() {
    local dest="$1" url="$2" sha256="$3"
    mkdir -p "$dest"

    # ── version manifest ─────────────────────────────────────────────────────
    cat > "${dest}/${WINGET_PACKAGE_ID}.yaml" <<YAML_EOF
PackageIdentifier: ${WINGET_PACKAGE_ID}
PackageVersion: ${VERSION}
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
YAML_EOF

    # ── locale manifest ──────────────────────────────────────────────────────
    cat > "${dest}/${WINGET_PACKAGE_ID}.locale.en-US.yaml" <<YAML_EOF
PackageIdentifier: ${WINGET_PACKAGE_ID}
PackageVersion: ${VERSION}
PackageLocale: en-US
Publisher: ${GITHUB_OWNER}
PublisherUrl: https://github.com/${GITHUB_OWNER}
PublisherSupportUrl: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/issues
PackageName: ${APP_NAME}
PackageUrl: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}
License: MIT
LicenseUrl: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/blob/main/LICENSE
ShortDescription: Secure key-value manager and password vault for Windows
Description: |-
  KeyValue is a cross-platform secure key-value / password manager.
  It supports AES-256-GCM encryption, import/export with Bitwarden/1Password/Chrome CSV,
  and encrypted .mkve bundles compatible with the macOS app.
Tags:
  - password
  - security
  - clipboard
  - keyvalue
  - vault
ReleaseNotesUrl: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/v${VERSION}
ManifestType: locale
ManifestVersion: 1.6.0
YAML_EOF

    # ── installer manifest ───────────────────────────────────────────────────
    cat > "${dest}/${WINGET_PACKAGE_ID}.installer.yaml" <<YAML_EOF
PackageIdentifier: ${WINGET_PACKAGE_ID}
PackageVersion: ${VERSION}
InstallerLocale: en-US
InstallerType: portable
Commands:
  - KeyValueWin
Installers:
  - Architecture: x64
    InstallerUrl: ${url}
    InstallerSha256: ${sha256}
ManifestType: installer
ManifestVersion: 1.6.0
YAML_EOF

    success "winget manifests written to ${dest}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: push_winget_pr
#
#  1. Clones the user's fork of microsoft/winget-pkgs.
#  2. Writes the three manifest files.
#  3. Commits to a new branch and pushes.
#  4. Opens a PR against microsoft/winget-pkgs:master.
#
#  Args: $1 = dry_run ("true"/"false")
#        $2 = installer URL
#        $3 = installer SHA256
# ══════════════════════════════════════════════════════════════════════════════
push_winget_pr() {
    local dry_run="$1" url="$2" sha256="$3"
    local branch="add-${WINGET_PACKAGE_ID}-${VERSION}"
    # Path inside the repo: manifests/<first-char>/<Publisher>/<App>/<version>/
    local first_char="${WINGET_PACKAGE_ID:0:1}"
    local publisher="${WINGET_PACKAGE_ID%%.*}"
    local app_name="${WINGET_PACKAGE_ID#*.}"
    local manifest_rel="manifests/${first_char}/${publisher}/${app_name}/${VERSION}"

    if $dry_run; then
        info "[DRY RUN] Would clone ${WINGET_PKGS_FORK} and create branch '${branch}'"
        info "[DRY RUN] Would write manifests to ${manifest_rel}/"
        info "[DRY RUN] Would open PR: ${WINGET_PKGS_FORK} → microsoft/winget-pkgs"
        echo ""
        build_winget_manifests "/dev/null" "$url" "$sha256" 2>/dev/null || true
        # Print what manifests would look like
        local tmpshow; tmpshow="$(mktemp -d)"
        build_winget_manifests "$tmpshow" "$url" "$sha256"
        for f in "${tmpshow}/"*.yaml; do
            info "── $(basename "$f") ──"
            while IFS= read -r line; do info "  $line"; done < "$f"
        done
        rm -rf "$tmpshow"
        return 0
    fi

    # ── Ensure user fork exists ───────────────────────────────────────────────
    if ! gh repo view "${WINGET_PKGS_FORK}" &>/dev/null; then
        info "Fork ${WINGET_PKGS_FORK} not found — forking microsoft/winget-pkgs…"
        gh repo fork "microsoft/winget-pkgs" --clone=false
        info "Fork created. Waiting for GitHub to initialise it…"
        sleep 5
    fi

    local wg_tmpdir; wg_tmpdir="$(mktemp -d)"

    info "Cloning ${WINGET_PKGS_FORK} (shallow)…"
    gh repo clone "${WINGET_PKGS_FORK}" "$wg_tmpdir" -- \
        --depth 1 --filter=blob:none --sparse 2>&1 \
        | while IFS= read -r line; do info "$line"; done

    # Sparse-checkout: only the path we need + the manifests root
    git -C "$wg_tmpdir" sparse-checkout set "manifests" 2>&1 | \
        while IFS= read -r line; do info "$line"; done

    # Branch directly from the fork's current HEAD — no upstream fetch needed.
    # The fork may lag upstream by a few commits but that is fine for a PR
    # that only adds new manifest files; GitHub will auto-merge.
    git -C "$wg_tmpdir" checkout -b "$branch" 2>&1 | \
        while IFS= read -r line; do info "$line"; done

    # Write manifests
    build_winget_manifests "${wg_tmpdir}/${manifest_rel}" "$url" "$sha256"

    # Commit
    git -C "$wg_tmpdir" add -A
    local commit_msg="Add ${WINGET_PACKAGE_ID} version ${VERSION}"
    git -C "$wg_tmpdir" commit -m "$commit_msg"
    git -C "$wg_tmpdir" push origin "$branch" 2>&1 \
        | while IFS= read -r line; do info "$line"; done
    success "Pushed branch '${branch}' to ${WINGET_PKGS_FORK}"

    # Open PR against microsoft/winget-pkgs
    # Write body to a temp file to avoid shell-escaping / GraphQL EOF issues
    local pr_body_file; pr_body_file="$(mktemp)"
    cat > "$pr_body_file" <<PR_BODY_EOF
## Automatic submission from release.sh

**Package:** \`${WINGET_PACKAGE_ID}\`
**Version:** \`${VERSION}\`
**Release:** https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/v${VERSION}

---
*Generated by [KeyValue release.sh](https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/blob/main/scripts/release.sh)*
PR_BODY_EOF

    gh pr create \
        --repo "microsoft/winget-pkgs" \
        --head "${GITHUB_OWNER}:${branch}" \
        --base "master" \
        --title "Add ${WINGET_PACKAGE_ID} ${VERSION}" \
        --body-file "$pr_body_file" 2>&1 | while IFS= read -r line; do info "$line"; done
    local pr_exit="${PIPESTATUS[0]}"
    rm -f "$pr_body_file"
    if [[ "$pr_exit" -ne 0 ]]; then
        warn "gh pr create exited with $pr_exit — the branch is already pushed."
        warn "You can open the PR manually at:"
        warn "  https://github.com/microsoft/winget-pkgs/compare/master...${GITHUB_OWNER}:${branch}"
    else
        success "winget PR opened against microsoft/winget-pkgs"
    fi
    rm -rf "$wg_tmpdir"
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
UNIVERSAL=false   # --universal: build & publish a single arm64+x86_64 fat DMG
SKIP_WINGET=false # --skip-winget: skip winget manifest PR
BUILD_WINDOWS=false
WINDOWS_PACKAGE_MODE="auto" # auto | exe | msi | both
RELEASE_PROXY=""
AUTO_UNIVERSAL=false

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
║    --dry-run        Preview all steps without executing      ║
║    --skip-brew      Skip Homebrew formula update             ║
║    --skip-winget    Skip winget manifest PR                  ║
║    --skip-build     Skip DMG build (use existing dist/)      ║
║    --fix-sha        Re-download DMGs & fix Cask SHA only     ║
║    --force          Force release even if tag exists         ║
║    --universal      Build & publish universal (arm64+x86_64) ║
║    --build-windows  Build Windows package(s) locally          ║
║    --windows-package MODE (auto|exe|msi|both)               ║
║    --proxy URL      Use HTTP(S) proxy for curl/gh operations ║
║    --help           Show this help                           ║
║                                                              ║
║  EXAMPLES                                                    ║
║    ./scripts/release.sh 1.0.0                                ║
║    ./scripts/release.sh 1.1.0 --dry-run                      ║
║    ./scripts/release.sh 2.0.0-beta.1 --skip-brew             ║
║    ./scripts/release.sh 0.1.1 --fix-sha                      ║
║    ./scripts/release.sh 1.0.0 --skip-winget                  ║
║    ./scripts/release.sh 1.2.0 --build-windows --windows-package both ║
║    ./scripts/release.sh 1.2.0 --proxy http://127.0.0.1:7890  ║
║                                                              ║
║  RELEASE PIPELINE                                            ║
║    STEP 1 – Build macOS DMG (via MacKeyValue/build.sh)       ║
║    STEP 2 – Create annotated git tag & push                  ║
║    STEP 3 – Create GitHub Release + upload assets:           ║
║              • macOS DMG (arm64 / intel / universal)         ║
║              • Windows EXE  windows/dist/KeyValueWin-*.exe   ║
║              • Windows MSI  windows/dist/KeyValueWin-*.msi   ║
║    STEP 4 – Update Homebrew tap formula (aresnasa/tap)       ║
║    STEP 5 – Submit winget manifest PR (microsoft/winget-pkgs)║
║                                                              ║
║  WINDOWS EXE                                                 ║
║    Build on a Windows machine or CI runner, then copy to:    ║
║      windows/dist/KeyValueWin-<VERSION>-win-x64.exe          ║
║    Command:                                                   ║
║      dotnet publish windows/KeyValueWin/KeyValueWin.csproj \ ║
║        -c Release -r win-x64 --self-contained \              ║
║        -p:PublishSingleFile=true -o windows/dist/            ║
║                                                              ║
║  WINDOWS MSI                                                 ║
║    Install WiX v4 and build using:                           ║
║      ./scripts/release.sh <VERSION> --build-windows --windows-package msi ║
║                                                              ║
║  NOTES                                                       ║
║    • Cask includes only on_arm/on_intel blocks for DMGs      ║
║      that actually exist in the GitHub Release.              ║
║    • brew style is validated & auto-fixed before commit.     ║
║    • brew fetch is run after push to confirm end-to-end.     ║
║    • Pre-releases skip Homebrew and winget automatically.    ║
║    • Homebrew releases auto-prefer a universal DMG so Intel  ║
║      and Apple Silicon can share one cask artifact.          ║
║    • winget PR requires your fork of microsoft/winget-pkgs;  ║
║      gh CLI will auto-fork if it doesn't exist.              ║
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

EXPECT_WINDOWS_MODE=false
EXPECT_PROXY=false
for arg in "$@"; do
    if $EXPECT_WINDOWS_MODE; then
        WINDOWS_PACKAGE_MODE="$arg"
        EXPECT_WINDOWS_MODE=false
        continue
    fi
    if $EXPECT_PROXY; then
        RELEASE_PROXY="$arg"
        EXPECT_PROXY=false
        continue
    fi

    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --skip-brew)  SKIP_BREW=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --fix-sha)    FIX_SHA=true; SKIP_BUILD=true ;;
        --force)      FORCE=true ;;
        --universal)  UNIVERSAL=true ;;
        --skip-winget) SKIP_WINGET=true ;;
        --build-windows) BUILD_WINDOWS=true ;;
        --proxy=*)
            RELEASE_PROXY="${arg#*=}"
            ;;
        --proxy)
            EXPECT_PROXY=true
            ;;
        --windows-package=*)
            WINDOWS_PACKAGE_MODE="${arg#*=}"
            ;;
        --windows-package)
            EXPECT_WINDOWS_MODE=true
            ;;
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

if $EXPECT_WINDOWS_MODE; then
    fail "--windows-package requires a value: auto|exe|msi|both"
fi
if $EXPECT_PROXY; then
    fail "--proxy requires a value, e.g. --proxy http://127.0.0.1:7890"
fi

if [ -n "$RELEASE_PROXY" ]; then
    export http_proxy="$RELEASE_PROXY"
    export https_proxy="$RELEASE_PROXY"
    export HTTP_PROXY="$RELEASE_PROXY"
    export HTTPS_PROXY="$RELEASE_PROXY"
    export all_proxy="$RELEASE_PROXY"
    export ALL_PROXY="$RELEASE_PROXY"
fi

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

case "$WINDOWS_PACKAGE_MODE" in
    auto|exe|msi|both) ;;
    *) fail "Invalid --windows-package value: ${WINDOWS_PACKAGE_MODE} (expected: auto|exe|msi|both)" ;;
esac

# If user explicitly asks local Windows build without choosing a mode,
# build both EXE + MSI so release assets are complete by default.
if $BUILD_WINDOWS && [ "$WINDOWS_PACKAGE_MODE" = "auto" ]; then
    WINDOWS_PACKAGE_MODE="both"
    info "--build-windows detected: --windows-package auto -> both"
fi

# Detect pre-release suffix
if echo "$VERSION" | grep -qE -e '-(alpha|beta|rc|dev)'; then
    PRERELEASE=true
fi

# Homebrew cask should ideally serve both Apple Silicon and Intel. When a
# release is going to update Homebrew, prefer building a universal DMG unless
# the user already selected otherwise.
if ! $SKIP_BREW && ! $PRERELEASE && ! $UNIVERSAL && ! $SKIP_BUILD; then
    UNIVERSAL=true
    AUTO_UNIVERSAL=true
fi

TAG="v${VERSION}"
ARCH="$(uname -m)"
if $UNIVERSAL; then
    ARCH_NAME="universal"
else
    [ "$ARCH" = "x86_64" ] && ARCH_NAME="intel" || ARCH_NAME="apple-silicon"
fi
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH_NAME}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"

# For non-universal builds: the "other" arch DMG may exist if cross-compiled
# or copied from another machine.  Not used for universal builds.
if ! $UNIVERSAL; then
    if [ "$ARCH_NAME" = "apple-silicon" ]; then
        OTHER_ARCH_NAME="intel"
    else
        OTHER_ARCH_NAME="apple-silicon"
    fi
    OTHER_DMG_NAME="${APP_NAME}-${VERSION}-${OTHER_ARCH_NAME}.dmg"
    OTHER_DMG_PATH="${DIST_DIR}/${OTHER_DMG_NAME}"
else
    OTHER_ARCH_NAME=""
    OTHER_DMG_NAME=""
    OTHER_DMG_PATH=""
fi

# Windows EXE — built by `dotnet publish` on a Windows runner or CI.
# Place it at windows/dist/KeyValueWin-<version>-win-x64.exe before releasing.
WINDOWS_EXE_NAME="KeyValueWin-${VERSION}-win-x64.exe"
WINDOWS_EXE_PATH="${WINDOWS_DIST_DIR}/${WINDOWS_EXE_NAME}"
WINDOWS_MSI_NAME="KeyValueWin-${VERSION}-win-x64.msi"
WINDOWS_MSI_PATH="${WINDOWS_DIST_DIR}/${WINDOWS_MSI_NAME}"

WINDOWS_REQUIRE_EXE=false
WINDOWS_REQUIRE_MSI=false
case "$WINDOWS_PACKAGE_MODE" in
    exe)
        WINDOWS_REQUIRE_EXE=true
        ;;
    msi)
        WINDOWS_REQUIRE_MSI=true
        ;;
    both)
        WINDOWS_REQUIRE_EXE=true
        WINDOWS_REQUIRE_MSI=true
        ;;
esac

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
    if ! verify_dmgs_from_github "$TAG" "$VTMPDIR"; then
        VERIFY_RC=$?
        rm -rf "$VTMPDIR"
        if [ "$VERIFY_RC" -eq 2 ]; then
            fail "Cannot verify DMG SHA256 due to GitHub network/connectivity errors. Retry later or check network/proxy settings."
        fi
        fail "No DMGs found in GitHub Release ${TAG}. Is the release published?"
    fi
    rm -rf "$VTMPDIR"

    step "Building Homebrew cask formula"
    CASK_CONTENT="$(build_cask_content)"

    step "Updating Homebrew tap"
    COMMIT_MSG="Fix SHA256 for keyvalue ${VERSION}"
    if $HAS_UNIVERSAL; then
        COMMIT_MSG+=" (universal)

universal: ${SHA256_UNIVERSAL}"
    elif $HAS_ARM && $HAS_INTEL; then
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
    $HAS_UNIVERSAL && echo -e "  ${DIM}universal:${RESET} ${SHA256_UNIVERSAL}"
    $HAS_ARM       && echo -e "  ${DIM}arm64:${RESET}     ${SHA256_ARM}"
    $HAS_INTEL     && echo -e "  ${DIM}x86_64:${RESET}    ${SHA256_INTEL}"
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
echo -e "  ${DIM}Skip build:${RESET}   $($SKIP_BUILD && echo "yes" || echo "no")"
echo -e "  ${DIM}Skip brew:${RESET}    $($SKIP_BREW && echo "yes" || echo "no")"
echo -e "  ${DIM}Skip winget:${RESET}  $($SKIP_WINGET && echo "yes" || echo "no")"
echo -e "  ${DIM}Win mode:${RESET}     ${WINDOWS_PACKAGE_MODE}"
echo -e "  ${DIM}Build win:${RESET}    $($BUILD_WINDOWS && echo "yes" || echo "no")"
echo -e "  ${DIM}Proxy:${RESET}        ${RELEASE_PROXY:-<from env or none>}"
echo -e "  ${DIM}Universal:${RESET}    $($UNIVERSAL && echo "yes" || echo "no")"
if $AUTO_UNIVERSAL; then
    echo -e "  ${DIM}Universal mode:${RESET} auto-enabled for Homebrew compatibility"
fi
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

INCLUDE_MACOS_DMG=true

if ! $SKIP_BUILD; then
    step "Building DMG (v${VERSION})"

    if [ ! -f "$BUILD_SCRIPT" ]; then
        fail "Build script not found: $BUILD_SCRIPT"
    fi

    build_flags=(--ci --dmg)
    $UNIVERSAL && build_flags+=(--universal)

    if $DRY_RUN; then
        info "[DRY RUN] Would run: MARKETING_VERSION=${VERSION} bash build.sh ${build_flags[*]}"
        if ! $UNIVERSAL; then
            if [ "$ARCH_NAME" = "apple-silicon" ]; then
                info "[DRY RUN] Would also run: MARKETING_VERSION=${VERSION} bash build.sh --ci --dmg --target-arch x86_64"
            elif [ "$ARCH_NAME" = "intel" ]; then
                info "[DRY RUN] Would also run: MARKETING_VERSION=${VERSION} bash build.sh --ci --dmg --target-arch arm64"
            fi
        fi
    else
        cd "${PROJECT_ROOT}/MacKeyValue"
        MARKETING_VERSION="$VERSION" bash build.sh "${build_flags[@]}"
        cd "$PROJECT_ROOT"

        if [ ! -f "$DMG_PATH" ]; then
            fail "DMG not found after build: $DMG_PATH"
        fi
        success "DMG built: $DMG_NAME"

        if ! $UNIVERSAL && [ "$(uname -s)" = "Darwin" ]; then
            build_other_macos_dmg "$VERSION" "$ARCH_NAME"
        fi
    fi
else
    step "Skipping build (--skip-build)"
    if ! $DRY_RUN && [ ! -f "$DMG_PATH" ]; then
        if $WINDOWS_REQUIRE_EXE || $WINDOWS_REQUIRE_MSI; then
            INCLUDE_MACOS_DMG=false
            SKIP_BREW=true
            warn "DMG not found at $DMG_PATH — switching to Windows-only release mode"
            warn "Homebrew update is disabled automatically for this release"
        else
            fail "DMG not found at $DMG_PATH — remove --skip-build to build it"
        fi
    fi
    if $INCLUDE_MACOS_DMG; then
        info "Using existing DMG: ${DMG_PATH}"
        success "DMG verified"
    fi
fi

# Local SHA256 — used in the tag message and release notes.
# The cask formula always uses the re-verified SHA from GitHub (STEP 4).
LOCAL_SHA256=""
if ! $INCLUDE_MACOS_DMG; then
    LOCAL_SHA256="N/A (windows-only release)"
elif [ -f "$SHA_PATH" ]; then
    LOCAL_SHA256="$(awk '{print $1}' "$SHA_PATH")"
elif ! $DRY_RUN && [ -f "$DMG_PATH" ]; then
    LOCAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
else
    LOCAL_SHA256="<computed-after-build>"
fi
info "SHA256 (local, ${ARCH_NAME}): $LOCAL_SHA256"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1B: Build / resolve Windows assets
# ══════════════════════════════════════════════════════════════════════════════

WINDOWS_UPLOAD_EXE=false
WINDOWS_UPLOAD_MSI=false
WINDOWS_EXE_SHA256=""
WINDOWS_MSI_SHA256=""

if $BUILD_WINDOWS; then
    step "Building Windows package(s) locally"
    if $DRY_RUN; then
        info "[DRY RUN] Would build Windows mode: ${WINDOWS_PACKAGE_MODE}"
    else
        case "$WINDOWS_PACKAGE_MODE" in
            auto|exe) build_windows_packages_local "exe" "$VERSION" || true ;;
            msi|both) build_windows_packages_local "both" "$VERSION" || true ;;
        esac
    fi
fi

# Resolve versioned asset names; fallback to non-versioned outputs in windows/dist.
RESOLVED_WINDOWS_EXE=""
RESOLVED_WINDOWS_MSI=""
if [ "$WINDOWS_PACKAGE_MODE" = "auto" ] || [ "$WINDOWS_PACKAGE_MODE" = "exe" ] || [ "$WINDOWS_PACKAGE_MODE" = "both" ]; then
    RESOLVED_WINDOWS_EXE="$(resolve_windows_asset_path "$WINDOWS_EXE_PATH" "${WINDOWS_DIST_DIR}/KeyValueWin.exe" || true)"
fi
if [ "$WINDOWS_PACKAGE_MODE" = "auto" ] || [ "$WINDOWS_PACKAGE_MODE" = "msi" ] || [ "$WINDOWS_PACKAGE_MODE" = "both" ]; then
    RESOLVED_WINDOWS_MSI="$(resolve_windows_asset_path "$WINDOWS_MSI_PATH" "${WINDOWS_DIST_DIR}/KeyValueWin.msi" || true)"
fi

if ! $DRY_RUN; then
    if $WINDOWS_REQUIRE_EXE && [ -z "$RESOLVED_WINDOWS_EXE" ]; then
        fail "Windows EXE is required by --windows-package=${WINDOWS_PACKAGE_MODE}, but no asset found under ${WINDOWS_DIST_DIR}. Build it with --build-windows or place KeyValueWin-${VERSION}-win-x64.exe in windows/dist."
    fi
    if $WINDOWS_REQUIRE_MSI && [ -z "$RESOLVED_WINDOWS_MSI" ]; then
        if is_windows_host; then
            fail "Windows MSI is required by --windows-package=${WINDOWS_PACKAGE_MODE}, but no asset found under ${WINDOWS_DIST_DIR}. Install WiX v4 (wix CLI) and rerun with --build-windows, or place KeyValueWin-${VERSION}-win-x64.msi in windows/dist."
        else
            fail "Windows MSI is required by --windows-package=${WINDOWS_PACKAGE_MODE}, but no asset found under ${WINDOWS_DIST_DIR}. MSI should be built on a Windows host (WiX officially supports Windows), then copy KeyValueWin-${VERSION}-win-x64.msi to windows/dist and rerun."
        fi
    fi
fi

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
    # In force mode, clear stale local/remote tag refs first (best effort).
    if $FORCE; then
        if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
            git -C "$PROJECT_ROOT" tag -d "$TAG" 2>/dev/null || true
        fi
        run_git_push_with_retry "$PROJECT_ROOT" origin ":refs/tags/$TAG" >/dev/null 2>&1 || true
        info "Force mode: cleared existing tag refs for $TAG"
    fi

    # Commit any outstanding file changes (e.g. version bumps)
    if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
        git -C "$PROJECT_ROOT" add -A
        git -C "$PROJECT_ROOT" commit -m "release: ${TAG}" || true
    fi

    PUSH_BRANCH="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
    if [ "$PUSH_BRANCH" = "HEAD" ]; then
        fail "Detached HEAD detected. Check out a branch before running release.sh"
    fi

    PUSH_OUTPUT=""
    if ! PUSH_OUTPUT="$(run_git_push_with_retry "$PROJECT_ROOT" origin "$PUSH_BRANCH" 2>&1)"; then
        echo "$PUSH_OUTPUT"
        if echo "$PUSH_OUTPUT" | grep -qiE 'non-fast-forward|\[rejected\]'; then
            fail "Push to origin/${PUSH_BRANCH} rejected (non-fast-forward). Run: git pull --rebase origin ${PUSH_BRANCH}, resolve conflicts if any, then rerun release.sh"
        fi
        fail "Push to origin/${PUSH_BRANCH} failed. Resolve git errors and rerun release.sh"
    fi

    if [ -n "$PUSH_OUTPUT" ]; then
        info "$PUSH_OUTPUT"
    fi

    if $FORCE; then
        git -C "$PROJECT_ROOT" tag -f -a "$TAG" -m "$TAG_MESSAGE"
        TAG_PUSH_OUTPUT="$(run_git_push_with_retry "$PROJECT_ROOT" origin "refs/tags/$TAG" --force 2>&1)" || {
            echo "$TAG_PUSH_OUTPUT"
            fail "Tag push failed for ${TAG}. Check network/proxy and rerun release.sh"
        }
        [ -n "$TAG_PUSH_OUTPUT" ] && info "$TAG_PUSH_OUTPUT"
    else
        git -C "$PROJECT_ROOT" tag -a "$TAG" -m "$TAG_MESSAGE"
        TAG_PUSH_OUTPUT="$(run_git_push_with_retry "$PROJECT_ROOT" origin "$TAG" 2>&1)" || {
            echo "$TAG_PUSH_OUTPUT"
            fail "Tag push failed for ${TAG}. Check network/proxy and rerun release.sh"
        }
        [ -n "$TAG_PUSH_OUTPUT" ] && info "$TAG_PUSH_OUTPUT"
    fi
    success "Tag $TAG created and pushed"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3: Create GitHub Release
# ══════════════════════════════════════════════════════════════════════════════

step "Creating GitHub Release"

RELEASE_NOTES="$(cat <<EOF
## ${APP_NAME} ${TAG}

### 📦 Installation

#### macOS — Option 1: Homebrew (Recommended)
~~~bash
brew tap ${GITHUB_OWNER}/tap
brew install --cask keyvalue
~~~

#### macOS — Option 2: Download DMG
1. Download the .dmg file below
2. Open the DMG and drag **KeyValue.app** into **Applications**
3. First launch: right-click KeyValue.app → select **Open**

> ⚠️ This is a free, open-source app with ad-hoc signing. macOS may warn about an unverified developer on first launch — right-click → Open to bypass.
> Alternatively: xattr -cr /Applications/KeyValue.app

#### Windows — Option 3: winget
~~~powershell
winget install ${WINGET_PACKAGE_ID}
~~~
*(Available after the winget PR is merged into microsoft/winget-pkgs)*

#### Windows — Option 4: Direct Download
Download one of the assets below:
- ${WINDOWS_EXE_NAME} — portable single-file EXE (no installer)
- ${WINDOWS_MSI_NAME} — standard MSI installer

### 🔐 Permissions (macOS)

On first launch, the app will guide you through granting:
- **Accessibility** — simulate keyboard input
- **Input Monitoring** — create keyboard events

### 🛠️ Requirements
| Platform | Requirement |
|----------|-------------|
| macOS    | 13.0+ (Ventura or later), Apple Silicon or Intel |
| Windows  | Windows 10 / 11, x64 |

### ⬆️ Upgrading

**Homebrew (macOS):**
~~~bash
brew update && brew upgrade --cask keyvalue
~~~

**winget (Windows):**
~~~powershell
winget upgrade ${WINGET_PACKAGE_ID}
~~~

**DMG / Direct download** — the app auto-downloads the matching DMG, replaces itself, and restarts.

---

**SHA256 (${ARCH_NAME}):** ${LOCAL_SHA256}

**License:** [MIT](https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/blob/main/LICENSE)
EOF
)"

if $DRY_RUN; then
    info "[DRY RUN] Would create GitHub Release: $TAG"
    if $INCLUDE_MACOS_DMG; then
        info "[DRY RUN] Primary asset:  $DMG_NAME"
        [ -f "$SHA_PATH" ]       && info "[DRY RUN] Checksum file: ${DMG_NAME}.sha256"
        [ -f "$OTHER_DMG_PATH" ] && info "[DRY RUN] Other arch:    $OTHER_DMG_NAME"
    else
        info "[DRY RUN] macOS DMG: skipped (Windows-only release mode)"
    fi
    [ -n "$RESOLVED_WINDOWS_EXE" ] && info "[DRY RUN] Windows EXE:  $(basename "$RESOLVED_WINDOWS_EXE")"
    [ -n "$RESOLVED_WINDOWS_MSI" ] && info "[DRY RUN] Windows MSI:  $(basename "$RESOLVED_WINDOWS_MSI")"
    WINDOWS_EXE_SHA256="<computed-after-build>"
    WINDOWS_MSI_SHA256="<computed-after-build>"
else
    # Write release notes to a temp file — avoids gh CLI hanging on large
    # inline --notes strings (observed with long markdown + code fences).
    RELEASE_NOTES_FILE="$(mktemp -t keyvalue-release-notes.XXXXXX.md)"
    printf '%s\n' "$RELEASE_NOTES" > "$RELEASE_NOTES_FILE"

    RELEASE_FLAGS=(
        --title "${APP_NAME} ${TAG}"
        --notes-file "$RELEASE_NOTES_FILE"
    )
    $PRERELEASE && RELEASE_FLAGS+=(--prerelease)

    # Remove stale release when --force
    if $FORCE; then
        gh release delete "$TAG" --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --yes 2>/dev/null || true
    fi

    # Collect assets: macOS DMGs (optional) + Windows artifacts (if provided).
    ASSETS=()
    if $INCLUDE_MACOS_DMG; then
        ASSETS+=("$DMG_PATH")
        [ -f "$SHA_PATH" ] && ASSETS+=("$SHA_PATH")

        if $UNIVERSAL; then
            info "Universal DMG covers both arm64 and x86_64 — no separate arch DMGs needed"
        elif [ -n "$OTHER_DMG_PATH" ] && [ -f "$OTHER_DMG_PATH" ]; then
            ASSETS+=("$OTHER_DMG_PATH")
            OTHER_SHA_PATH="${OTHER_DMG_PATH}.sha256"
            [ -f "$OTHER_SHA_PATH" ] && ASSETS+=("$OTHER_SHA_PATH")
            info "Including other-arch DMG: $OTHER_DMG_NAME"
        else
            warn "Other-arch DMG not found — cask will be ${ARCH_NAME}-only."
            warn "Use --universal to build both architectures in one step."
        fi
    else
        warn "macOS DMG not included in this release (Windows-only mode)"
    fi

    # Windows assets — configurable via --windows-package.
    case "$WINDOWS_PACKAGE_MODE" in
        auto|exe|both)
            if [ -n "$RESOLVED_WINDOWS_EXE" ] && [ -f "$RESOLVED_WINDOWS_EXE" ]; then
                WINDOWS_UPLOAD_EXE=true
                ASSETS+=("$RESOLVED_WINDOWS_EXE")
                WINDOWS_EXE_SHA256="$(shasum -a 256 "$RESOLVED_WINDOWS_EXE" | awk '{print $1}')"
                WINDOWS_EXE_SHA_FILE="${RESOLVED_WINDOWS_EXE}.sha256"
                echo "$WINDOWS_EXE_SHA256  $(basename "$RESOLVED_WINDOWS_EXE")" > "$WINDOWS_EXE_SHA_FILE"
                ASSETS+=("$WINDOWS_EXE_SHA_FILE")
                info "Including Windows EXE: $(basename "$RESOLVED_WINDOWS_EXE") (SHA256: $WINDOWS_EXE_SHA256)"
            elif [ "$WINDOWS_PACKAGE_MODE" = "exe" ] || [ "$WINDOWS_PACKAGE_MODE" = "both" ]; then
                warn "Requested Windows EXE but no asset found in ${WINDOWS_DIST_DIR}"
            fi
            ;;
    esac

    case "$WINDOWS_PACKAGE_MODE" in
        auto|msi|both)
            if [ -n "$RESOLVED_WINDOWS_MSI" ] && [ -f "$RESOLVED_WINDOWS_MSI" ]; then
                WINDOWS_UPLOAD_MSI=true
                ASSETS+=("$RESOLVED_WINDOWS_MSI")
                WINDOWS_MSI_SHA256="$(shasum -a 256 "$RESOLVED_WINDOWS_MSI" | awk '{print $1}')"
                WINDOWS_MSI_SHA_FILE="${RESOLVED_WINDOWS_MSI}.sha256"
                echo "$WINDOWS_MSI_SHA256  $(basename "$RESOLVED_WINDOWS_MSI")" > "$WINDOWS_MSI_SHA_FILE"
                ASSETS+=("$WINDOWS_MSI_SHA_FILE")
                info "Including Windows MSI: $(basename "$RESOLVED_WINDOWS_MSI") (SHA256: $WINDOWS_MSI_SHA256)"
            elif [ "$WINDOWS_PACKAGE_MODE" = "msi" ] || [ "$WINDOWS_PACKAGE_MODE" = "both" ]; then
                warn "Requested Windows MSI but no asset found in ${WINDOWS_DIST_DIR}"
            fi
            ;;
    esac

    if ! $WINDOWS_UPLOAD_EXE; then
        SKIP_WINGET=true
        WINDOWS_EXE_SHA256=""
        if [ "$WINDOWS_PACKAGE_MODE" = "exe" ] || [ "$WINDOWS_PACKAGE_MODE" = "both" ] || [ "$WINDOWS_PACKAGE_MODE" = "auto" ]; then
            warn "Windows EXE unavailable — winget step will be skipped"
        fi
    fi

    gh release create "$TAG" \
        "${ASSETS[@]}" \
        --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
        "${RELEASE_FLAGS[@]}"
    local gh_rc=$?
    rm -f "$RELEASE_NOTES_FILE"
    [ $gh_rc -ne 0 ] && fail "gh release create failed (exit $gh_rc)"

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
        HAS_UNIVERSAL=false; SHA256_UNIVERSAL=""
        HAS_ARM=false;       SHA256_ARM=""
        HAS_INTEL=false;     SHA256_INTEL=""
        if $UNIVERSAL; then
            HAS_UNIVERSAL=true
            SHA256_UNIVERSAL="<verified-after-upload>"
        else
            SHA256_ARM="<verified-after-upload>"
            SHA256_INTEL="<verified-after-upload>"
            [ "$ARCH_NAME" = "apple-silicon" ] && HAS_ARM=true
            [ "$ARCH_NAME" = "intel" ]         && HAS_INTEL=true
            [ -n "$OTHER_DMG_PATH" ] && [ -f "$OTHER_DMG_PATH" ] && {
                [ "$OTHER_ARCH_NAME" = "apple-silicon" ] && HAS_ARM=true
                [ "$OTHER_ARCH_NAME" = "intel" ]         && HAS_INTEL=true
            }
        fi
    else
        VTMPDIR="$(mktemp -d)"
        if ! verify_dmgs_from_github "$TAG" "$VTMPDIR"; then
            VERIFY_RC=$?
            rm -rf "$VTMPDIR"
            if [ "$VERIFY_RC" -eq 2 ]; then
                warn "Skipping Homebrew update due to GitHub network/connectivity errors while downloading release DMGs"
                SKIP_BREW=true
            else
                fail "No DMGs found in GitHub Release ${TAG}. Is the release published?"
            fi
        fi
        rm -rf "$VTMPDIR"
    fi

    if $SKIP_BREW; then
        step "Skipping Homebrew update (network issue)"
    else

        CASK_CONTENT="$(build_cask_content)"

    # Build a descriptive commit message showing the actual SHA values
    BREW_COMMIT_MSG="Update keyvalue to ${VERSION}"
    if $HAS_UNIVERSAL; then
        BREW_COMMIT_MSG+=" (universal)

universal: ${SHA256_UNIVERSAL}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    elif $HAS_ARM && $HAS_INTEL; then
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
    fi

elif $PRERELEASE; then
    step "Skipping Homebrew update (pre-release)"
    info "Pre-release versions are not published to Homebrew tap"
elif $SKIP_BREW; then
    step "Skipping Homebrew update (--skip-brew)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 5: Update winget manifest (microsoft/winget-pkgs)
#
#  Forks microsoft/winget-pkgs (if needed), writes the three YAML manifests,
#  commits to a new branch and opens a PR automatically via gh CLI.
#  Skipped when: --skip-winget, --prerelease, or Windows EXE was not uploaded.
# ══════════════════════════════════════════════════════════════════════════════

if ! $SKIP_WINGET && ! $PRERELEASE; then
    step "Updating winget manifest (microsoft/winget-pkgs)"

    WINGET_EXE_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${TAG}/${WINDOWS_EXE_NAME}"

    if $DRY_RUN; then
        push_winget_pr true "$WINGET_EXE_URL" "${WINDOWS_EXE_SHA256:-<sha256>}"
    else
        if [ -z "${WINDOWS_EXE_SHA256:-}" ]; then
            warn "WINDOWS_EXE_SHA256 is empty — winget step skipped."
            warn "Place the Windows EXE at ${WINDOWS_EXE_PATH} and re-run with --skip-brew."
        else
            push_winget_pr false "$WINGET_EXE_URL" "$WINDOWS_EXE_SHA256"
        fi
    fi
elif $PRERELEASE; then
    step "Skipping winget update (pre-release)"
    info "Pre-release versions are not submitted to microsoft/winget-pkgs"
elif $SKIP_WINGET; then
    step "Skipping winget update (--skip-winget)"
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
        if $HAS_UNIVERSAL; then
            echo -e "  ${DIM}Architecture:${RESET}        universal (arm64 + x86_64)"
            echo -e "  ${DIM}SHA256 (universal):${RESET}  ${SHA256_UNIVERSAL}"
        elif $HAS_ARM && $HAS_INTEL; then
            echo -e "  ${DIM}Architectures:${RESET}       arm64 + x86_64"
            echo -e "  ${DIM}SHA256 (arm64):${RESET}      ${SHA256_ARM}"
            echo -e "  ${DIM}SHA256 (x86_64):${RESET}     ${SHA256_INTEL}"
        elif $HAS_ARM; then
            echo -e "  ${DIM}Architecture:${RESET}        arm64 only"
            echo -e "  ${DIM}SHA256 (arm64):${RESET}      ${SHA256_ARM}"
        else
            echo -e "  ${DIM}Architecture:${RESET}        x86_64 only"
            echo -e "  ${DIM}SHA256 (x86_64):${RESET}     ${SHA256_INTEL}"
        fi
        echo ""
    else
        echo -e "  ${DIM}SHA256 (${ARCH_NAME}):${RESET} ${LOCAL_SHA256}"
        echo ""
    fi

    if ! $SKIP_WINGET && ! $PRERELEASE && [ -n "${WINDOWS_EXE_SHA256:-}" ]; then
        echo -e "  ${DIM}Windows (winget):${RESET}"
        echo -e "    winget install ${WINGET_PACKAGE_ID}"
        echo -e "    ${DIM}(after PR is merged into microsoft/winget-pkgs)${RESET}"
        echo ""
    fi

    if [ -n "${WINDOWS_EXE_SHA256:-}" ] || [ -n "${WINDOWS_MSI_SHA256:-}" ]; then
        echo -e "  ${DIM}Windows Direct Download:${RESET}"
        if [ -n "${WINDOWS_EXE_SHA256:-}" ]; then
            echo -e "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${TAG}/${WINDOWS_EXE_NAME}"
            echo -e "  ${DIM}SHA256 (exe):${RESET}        ${WINDOWS_EXE_SHA256}"
        fi
        if [ -n "${WINDOWS_MSI_SHA256:-}" ]; then
            echo -e "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${TAG}/${WINDOWS_MSI_NAME}"
            echo -e "  ${DIM}SHA256 (msi):${RESET}        ${WINDOWS_MSI_SHA256}"
        fi
        echo ""
    fi
fi

echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "  ${DIM}GitHub:${RESET}  https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
echo -e "  ${DIM}License:${RESET} MIT"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
