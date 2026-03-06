#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KeyValue – Build, Package & Distribute Script
#
#  Usage:
#    ./build.sh                  # Build Release .app
#    ./build.sh debug            # Build Debug .app
#    ./build.sh --run            # Build Release and launch
#    ./build.sh --dmg            # Build Release .app + package as DMG
#    ./build.sh --icons          # Regenerate app icons only
#    ./build.sh --clean          # Remove all build artefacts
#    ./build.sh --ci             # CI mode: build + dmg, no TCC reset, no run
#    ./build.sh --help           # Show this help
#
#  Combined:
#    ./build.sh debug --run      # Debug build + launch
#    ./build.sh --dmg --run      # Release build + DMG + launch
#    ./build.sh --ci --dmg       # CI pipeline: build + DMG (no interactive)
#
#  Environment variables (optional):
#    SIGN_IDENTITY     Code-sign identity (default: "-" for ad-hoc)
#    MARKETING_VERSION Override version string (default: from git tag or 1.0.0)
#    BUILD_NUMBER      Override build number  (default: git commit count)
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Configuration ────────────────────────────────────────────────────────────
APP_NAME="KeyValue"
EXECUTABLE_NAME="MacKeyValue"
BUNDLE_ID="com.aresnasa.mackeyvalue"
BUNDLE_DISPLAY_NAME="KeyValue"
COPYRIGHT="Copyright © 2024-2025 KeyValue Contributors. MIT License."
MIN_MACOS="13.0"
DEV_LANGUAGE="zh-Hans"

# ── Paths ────────────────────────────────────────────────────────────────────
BUILD_DIR="./build"
DIST_DIR="./dist"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="./Resources/MacKeyValue.entitlements"
INFO_PLIST="./Resources/Info.plist"
ICON_FILE="./Resources/AppIcon.icns"
ASSETS_DIR="./Resources/Assets.xcassets"
ICON_SCRIPT="../scripts/generate_icon.swift"

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

# ── Logging helpers ──────────────────────────────────────────────────────────
step()    { echo -e "\n${BLUE}${BOLD}▸ $1${RESET}"; }
success() { echo -e "  ${GREEN}✅ $1${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${RESET}"; }
fail()    { echo -e "  ${RED}❌ $1${RESET}"; exit 1; }
info()    { echo -e "  ${DIM}$1${RESET}"; }

# ── Parse arguments ──────────────────────────────────────────────────────────
CONFIG="Release"
DO_RUN=false
DO_DMG=false
DO_ICONS=false
DO_CLEAN=false
DO_CI=false
DO_HELP=false

for arg in "$@"; do
    case "$arg" in
        debug|Debug)       CONFIG="Debug" ;;
        release|Release)   CONFIG="Release" ;;
        --run|-r)          DO_RUN=true ;;
        --dmg|-d)          DO_DMG=true ;;
        --icons|-i)        DO_ICONS=true ;;
        --clean|-c)        DO_CLEAN=true ;;
        --ci)              DO_CI=true; DO_DMG=true ;;
        --help|-h)         DO_HELP=true ;;
        *)
            echo -e "${RED}Unknown argument: $arg${RESET}"
            echo "Run: $0 --help"
            exit 1
            ;;
    esac
done

# ── Help ─────────────────────────────────────────────────────────────────────
if $DO_HELP; then
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  KeyValue – Build Script                                     ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  COMMANDS                                                    ║
║    ./build.sh              Build Release .app                ║
║    ./build.sh debug        Build Debug .app                  ║
║    ./build.sh --run        Build + launch                    ║
║    ./build.sh --dmg        Build + package as DMG            ║
║    ./build.sh --icons      Regenerate icons only             ║
║    ./build.sh --clean      Remove build artefacts            ║
║    ./build.sh --ci         CI mode (build + DMG, no prompts) ║
║    ./build.sh --help       This help                         ║
║                                                              ║
║  ENVIRONMENT                                                 ║
║    SIGN_IDENTITY      Signing identity (default: ad-hoc "-") ║
║    MARKETING_VERSION  Version override (default: git tag)    ║
║    BUILD_NUMBER       Build number override                  ║
║                                                              ║
║  EXAMPLES                                                    ║
║    ./build.sh --dmg --run                                    ║
║    SIGN_IDENTITY="Developer ID Application: ..." ./build.sh  ║
║    MARKETING_VERSION=2.0.0 ./build.sh --dmg --ci             ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    exit 0
fi

# ── Clean ────────────────────────────────────────────────────────────────────
if $DO_CLEAN; then
    step "Cleaning build artefacts"
    rm -rf "$BUILD_DIR" "$DIST_DIR" .build
    success "Clean complete"
    exit 0
fi

# ── Icons only ───────────────────────────────────────────────────────────────
if $DO_ICONS; then
    step "Regenerating app icons"
    if [ -f "$ICON_SCRIPT" ]; then
        swift "$ICON_SCRIPT"
        success "Icons regenerated"
    else
        fail "Icon script not found: $ICON_SCRIPT"
    fi
    exit 0
fi

# ── Version detection ────────────────────────────────────────────────────────
detect_version() {
    if [ -n "${MARKETING_VERSION:-}" ]; then
        echo "$MARKETING_VERSION"
        return
    fi
    # Try git tag (e.g. v1.2.3 → 1.2.3)
    local tag
    tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$tag" ]; then
        echo "${tag#v}"
        return
    fi
    echo "1.0.0"
}

detect_build_number() {
    if [ -n "${BUILD_NUMBER:-}" ]; then
        echo "$BUILD_NUMBER"
        return
    fi
    git rev-list --count HEAD 2>/dev/null || echo "1"
}

VERSION="$(detect_version)"
BUILD_NUM="$(detect_build_number)"
SIGN_ID="${SIGN_IDENTITY:--}"

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   KeyValue – K🔒V  Build System                 ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}Version:   ${RESET}${BOLD}${VERSION}${RESET} (build ${BUILD_NUM})"
echo -e "  ${DIM}Config:    ${RESET}${CONFIG}"
echo -e "  ${DIM}Sign:      ${RESET}$([ "$SIGN_ID" = "-" ] && echo "ad-hoc" || echo "$SIGN_ID")"
echo -e "  ${DIM}DMG:       ${RESET}$(${DO_DMG} && echo "yes" || echo "no")"
echo -e "  ${DIM}CI mode:   ${RESET}$(${DO_CI} && echo "yes" || echo "no")"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1: Swift Build
# ══════════════════════════════════════════════════════════════════════════════

step "Building with Swift Package Manager ($CONFIG)"

SWIFT_CONFIG="release"
[ "$CONFIG" = "Debug" ] && SWIFT_CONFIG="debug"

swift build -c "$SWIFT_CONFIG" 2>&1 | while IFS= read -r line; do
    # Show only interesting lines during build
    case "$line" in
        *"Compiling"*|*"Linking"*|*"Build complete"*|*error*|*warning*)
            info "$line"
            ;;
    esac
done

EXECUTABLE=".build/${SWIFT_CONFIG}/${EXECUTABLE_NAME}"
if [ ! -f "$EXECUTABLE" ]; then
    fail "Build failed: executable not found at $EXECUTABLE"
fi
success "Swift build complete"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Assemble .app bundle
# ══════════════════════════════════════════════════════════════════════════════

step "Assembling ${APP_NAME}.app bundle"

# Clean previous build
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# ── Executable ──
cp "$EXECUTABLE" "$MACOS_DIR/${EXECUTABLE_NAME}"
chmod +x "$MACOS_DIR/${EXECUTABLE_NAME}"
info "Executable copied"

# ── Info.plist (resolve all build-setting variables) ──
if [ ! -f "$INFO_PLIST" ]; then
    fail "Info.plist not found: $INFO_PLIST"
fi

sed \
    -e "s|\$(EXECUTABLE_NAME)|${EXECUTABLE_NAME}|g" \
    -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|${BUNDLE_ID}|g" \
    -e "s|\$(PRODUCT_NAME)|${EXECUTABLE_NAME}|g" \
    -e "s|\$(PRODUCT_BUNDLE_PACKAGE_TYPE)|APPL|g" \
    -e "s|\$(MARKETING_VERSION)|${VERSION}|g" \
    -e "s|\$(CURRENT_PROJECT_VERSION)|${BUILD_NUM}|g" \
    -e "s|\$(DEVELOPMENT_LANGUAGE)|${DEV_LANGUAGE}|g" \
    -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|${MIN_MACOS}|g" \
    "$INFO_PLIST" > "${CONTENTS_DIR}/Info.plist"

# Override display name and copyright in the resolved plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${BUNDLE_DISPLAY_NAME}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright ${COPYRIGHT}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
info "Info.plist resolved (v${VERSION} build ${BUILD_NUM})"

# ── PkgInfo ──
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# ── Asset Catalog ──
if [ -d "$ASSETS_DIR" ]; then
    if command -v actool &>/dev/null; then
        actool --compile "$RESOURCES_DIR" \
               --platform macosx \
               --minimum-deployment-target "$MIN_MACOS" \
               --app-icon AppIcon \
               --accent-color AccentColor \
               --output-partial-info-plist /dev/null \
               "$ASSETS_DIR" 2>/dev/null && {
            info "Asset catalog compiled"
        } || {
            warn "actool failed, copying raw assets"
            cp -R "$ASSETS_DIR" "$RESOURCES_DIR/"
        }
    else
        cp -R "$ASSETS_DIR" "$RESOURCES_DIR/"
        info "Asset catalog copied (actool not available)"
    fi
fi

# ── Icon (hand-crafted .icns, overwrites actool's version) ──
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
    info "AppIcon.icns copied"
else
    warn "No AppIcon.icns found at $ICON_FILE"
fi

# ── SwiftPM resource bundles ──
BUNDLE_COUNT=0
for bundle in .build/${SWIFT_CONFIG}/*.bundle; do
    if [ -d "$bundle" ]; then
        BUNDLE_NAME="$(basename "$bundle")"
        cp -R "$bundle" "$RESOURCES_DIR/${BUNDLE_NAME}"
        BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
    fi
done
[ $BUNDLE_COUNT -gt 0 ] && info "Copied $BUNDLE_COUNT resource bundle(s)"

success "App bundle assembled"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3: Code signing
# ══════════════════════════════════════════════════════════════════════════════

step "Code signing"

if [ ! -f "$ENTITLEMENTS" ]; then
    fail "Entitlements file not found: $ENTITLEMENTS"
fi

# Sign nested bundles first
NESTED_COUNT=0
while IFS= read -r -d '' nested; do
    codesign --force --sign "$SIGN_ID" \
        --timestamp=none \
        --options runtime \
        "$nested" 2>/dev/null && NESTED_COUNT=$((NESTED_COUNT + 1)) || true
done < <(find "$APP_BUNDLE" \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -print0 2>/dev/null)

[ $NESTED_COUNT -gt 0 ] && info "Signed $NESTED_COUNT nested component(s)"

# Sign the app itself
SIGN_FLAGS=(--force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" --options runtime)
if [ "$SIGN_ID" = "-" ]; then
    # Ad-hoc: no timestamp
    SIGN_FLAGS+=(--timestamp=none)
else
    # Developer ID: include secure timestamp
    SIGN_FLAGS+=(--timestamp)
fi

codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
success "Code signing complete ($([ "$SIGN_ID" = "-" ] && echo "ad-hoc" || echo "Developer ID"))"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4: Verify signature
# ══════════════════════════════════════════════════════════════════════════════

step "Verifying code signature"
codesign -vv "$APP_BUNDLE" 2>&1 | while IFS= read -r line; do
    info "$line"
done
success "Signature valid"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 5: Clear icon cache
# ══════════════════════════════════════════════════════════════════════════════

step "Clearing icon cache"
touch "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$APP_BUNDLE" 2>/dev/null || true
success "Icon cache invalidated"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 6: Reset TCC (skip in CI mode)
# ══════════════════════════════════════════════════════════════════════════════

if ! $DO_CI; then
    step "Resetting TCC Accessibility entry"
    info "Ad-hoc signing changes the code hash each build."
    info "Resetting stale TCC entry so the app gets a clean permission prompt."

    if tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null; then
        success "TCC reset for ${BUNDLE_ID}"
    else
        warn "tccutil reset failed (this is normal on some macOS versions)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 7: Package DMG (optional)
# ══════════════════════════════════════════════════════════════════════════════

DMG_PATH=""

if $DO_DMG; then
    step "Packaging DMG"

    mkdir -p "$DIST_DIR"

    # Determine architecture
    ARCH="$(uname -m)"
    [ "$ARCH" = "x86_64" ] && ARCH="intel"
    [ "$ARCH" = "arm64" ]  && ARCH="apple-silicon"

    DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
    DMG_PATH="${DIST_DIR}/${DMG_NAME}"

    # Create a temporary staging directory for the DMG content
    DMG_STAGING="$(mktemp -d)"
    trap 'rm -rf "$DMG_STAGING"' EXIT

    # Copy .app into staging
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"

    # Create a symbolic link to /Applications for drag-install
    ln -s /Applications "$DMG_STAGING/Applications"

    # Create a README.txt for the DMG with install instructions
    cat > "$DMG_STAGING/安装说明.txt" <<INSTALL_EOF
╔══════════════════════════════════════════════════════════╗
║  KeyValue – 安装说明                                      ║
╚══════════════════════════════════════════════════════════╝

📦 安装步骤：
   1. 将 ${APP_NAME}.app 拖入右侧的 Applications 文件夹
   2. 从启动台 (Launchpad) 或 /Applications 打开 KeyValue

🔓 首次打开（解除 macOS 门禁）：
   由于本应用是开源免费软件，没有 Apple 付费签名，
   macOS 会阻止首次打开。解除方法：

   方法一（推荐）：
     右键点击 ${APP_NAME}.app → 选择「打开」→ 弹窗中点击「打开」

   方法二（命令行）：
     xattr -cr /Applications/${APP_NAME}.app

   方法三（系统设置）：
     系统设置 → 隐私与安全性 → 下方会显示"KeyValue 已被阻止"
     → 点击「仍要打开」

🔐 权限授予（首次启动后）：
   应用启动后会引导你授予两个权限：
     • 辅助功能 (Accessibility) — 用于模拟键盘输入
     • 输入监控 (Input Monitoring) — 用于创建键盘事件
   按照应用内引导操作，两个开关都打开后重启应用即可。

💡 更多信息：
   GitHub: https://github.com/aresnasa/mac-keyvalue
   问题反馈: https://github.com/aresnasa/mac-keyvalue/issues

☕ 如果这个工具对你有帮助，欢迎在 GitHub 上 Star ⭐
   或者请作者喝杯咖啡：在应用内点击 关于 → 请喝咖啡 ☕
INSTALL_EOF

    info "DMG staging prepared"

    # Remove any previous DMG
    rm -f "$DMG_PATH"

    # Create DMG
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_PATH" 2>&1 | while IFS= read -r line; do
        case "$line" in
            *created*|*Creating*) info "$line" ;;
        esac
    done

    if [ -f "$DMG_PATH" ]; then
        DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
        success "DMG created: ${DMG_NAME} (${DMG_SIZE})"

        # Generate SHA256 checksum
        CHECKSUM_FILE="${DIST_DIR}/${DMG_NAME}.sha256"
        shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$CHECKSUM_FILE"
        CHECKSUM="$(cat "$CHECKSUM_FILE")"
        info "SHA256: ${CHECKSUM}"
        success "Checksum written to ${DMG_NAME}.sha256"
    else
        fail "DMG creation failed"
    fi

    # Clean up staging
    rm -rf "$DMG_STAGING"
    trap - EXIT
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Summary
# ══════════════════════════════════════════════════════════════════════════════

APP_SIZE="$(du -sh "$APP_BUNDLE" | cut -f1 | tr -d ' ')"

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✅  Build complete!${RESET}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${DIM}App:${RESET}      ${APP_BUNDLE}"
echo -e "  ${DIM}Size:${RESET}     ${APP_SIZE}"
echo -e "  ${DIM}Version:${RESET}  ${VERSION} (build ${BUILD_NUM})"
echo -e "  ${DIM}Config:${RESET}   ${CONFIG}"
echo -e "  ${DIM}Signed:${RESET}   $([ "$SIGN_ID" = "-" ] && echo "ad-hoc (open-source distribution)" || echo "$SIGN_ID")"

if [ -n "$DMG_PATH" ] && [ -f "$DMG_PATH" ]; then
    echo ""
    echo -e "  ${DIM}DMG:${RESET}      ${DMG_PATH}"
    echo -e "  ${DIM}SHA256:${RESET}   ${CHECKSUM}"
fi

echo ""
echo -e "  ${DIM}Run:${RESET}      open ${APP_BUNDLE}"
echo -e "  ${DIM}Or:${RESET}       $0 --run"

if ! $DO_CI; then
    echo ""
    echo -e "${YELLOW}${BOLD}  📌 首次启动指南${RESET}"
    echo ""
    echo -e "  ${DIM}1.${RESET} 启动应用"
    echo -e "     ${DIM}open ${APP_BUNDLE}${RESET}"
    echo ""
    echo -e "  ${DIM}2.${RESET} 如遇「无法打开」弹窗，右键 → 打开，或执行："
    echo -e "     ${DIM}xattr -cr ${APP_BUNDLE}${RESET}"
    echo ""
    echo -e "  ${DIM}3.${RESET} 应用内会引导授权两个系统权限："
    echo -e "     • 辅助功能 (Accessibility) — 模拟键盘输入"
    echo -e "     • 输入监控 (Input Monitoring) — 创建键盘事件源"
    echo ""
    echo -e "  ${DIM}4.${RESET} 两个开关都打开后，点击「重启应用」使权限生效"
    echo ""
    if [ "$SIGN_ID" = "-" ]; then
        echo -e "  ${DIM}ℹ️  Ad-hoc 签名每次编译后哈希会变化，需要重新授权。${RESET}"
        echo -e "  ${DIM}   如果键盘模拟不生效，在辅助功能列表中删除旧条目后重新添加。${RESET}"
    fi
fi

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "  ${DIM}GitHub:${RESET}  https://github.com/aresnasa/mac-keyvalue"
echo -e "  ${DIM}License:${RESET} MIT"
echo -e "  ${DIM}Donate:${RESET}  在应用内 关于 → 请喝咖啡 ☕"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  Optional: Launch
# ══════════════════════════════════════════════════════════════════════════════

if $DO_RUN && ! $DO_CI; then
    echo -e "🚀 Launching ${APP_NAME}..."
    # Clear quarantine attribute so macOS doesn't block locally-built app
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    open "$APP_BUNDLE"
fi
