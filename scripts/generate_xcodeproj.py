#!/usr/bin/env python3
"""
Generate an Xcode project for MacKeyValue suitable for App Store submission.

This script creates a minimal but complete .xcodeproj/project.pbxproj that:
- References all Swift source files
- Includes Assets.xcassets and Info.plist
- Configures Debug/Release build settings
- Sets up SPM package dependencies (swift-crypto, KeyboardShortcuts, SwiftSoup)
- Configures code signing, sandbox, entitlements
- Targets macOS 13.0+
"""

import hashlib
import os
import sys
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# Deterministic UUID generator (so re-runs produce stable IDs)
# ---------------------------------------------------------------------------

_uuid_counter = 0

def make_id(label: str = "") -> str:
    """Generate a 24-char hex string used as a PBX object identifier."""
    global _uuid_counter
    _uuid_counter += 1
    seed = f"MacKeyValue-{label}-{_uuid_counter}"
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


# ---------------------------------------------------------------------------
# Project structure constants
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent / "MacKeyValue"
SOURCES_DIR = PROJECT_ROOT / "Sources"
RESOURCES_DIR = PROJECT_ROOT / "Resources"
TESTS_DIR = PROJECT_ROOT / "Tests"

BUNDLE_ID = "com.aresnasa.mackeyvalue"
PRODUCT_NAME = "MacKeyValue"
DEPLOYMENT_TARGET = "13.0"
SWIFT_VERSION = "5.9"
MARKETING_VERSION = "1.0.0"
CURRENT_PROJECT_VERSION = "1"
TEAM_ID = ""  # Set your Apple Developer Team ID here or leave empty

# ---------------------------------------------------------------------------
# Discover source files
# ---------------------------------------------------------------------------

def discover_swift_files(base: Path, relative_to: Path) -> list:
    """Return a sorted list of (relative_path, filename) tuples for .swift files."""
    results = []
    for f in sorted(base.rglob("*.swift")):
        rel = f.relative_to(relative_to)
        results.append((str(rel), f.name))
    return results


def discover_groups(base: Path, relative_to: Path) -> dict:
    """Return {relative_dir_path: [filenames]} mapping."""
    groups = {}
    for f in sorted(base.rglob("*.swift")):
        rel_dir = str(f.parent.relative_to(relative_to))
        groups.setdefault(rel_dir, []).append(f.name)
    return groups


# ---------------------------------------------------------------------------
# Gather all files and assign IDs
# ---------------------------------------------------------------------------

source_files = discover_swift_files(SOURCES_DIR, PROJECT_ROOT)
test_files = discover_swift_files(TESTS_DIR, PROJECT_ROOT)

# Groups discovered under Sources/
source_groups = discover_groups(SOURCES_DIR, PROJECT_ROOT)
test_groups = discover_groups(TESTS_DIR, PROJECT_ROOT)

# Assign IDs to every file reference and build file
file_refs = {}   # relative_path -> file_ref_id
build_files = {} # relative_path -> build_file_id
groups = {}      # relative_dir  -> group_id

for rel_path, name in source_files + test_files:
    file_refs[rel_path] = make_id(f"fileref-{rel_path}")
    build_files[rel_path] = make_id(f"buildfile-{rel_path}")

for rel_dir in list(source_groups.keys()) + list(test_groups.keys()):
    groups[rel_dir] = make_id(f"group-{rel_dir}")

# Resource references
ASSETS_REF = make_id("fileref-Assets.xcassets")
ASSETS_BUILD = make_id("buildfile-Assets.xcassets")
INFO_PLIST_REF = make_id("fileref-Info.plist")
ENTITLEMENTS_REF = make_id("fileref-Entitlements")
ICNS_REF = make_id("fileref-AppIcon.icns")
ICNS_BUILD = make_id("buildfile-AppIcon.icns")

# Check if icns exists
ICNS_EXISTS = (RESOURCES_DIR / "AppIcon.appiconset" / "AppIcon.icns").exists()

# Top-level group IDs
ROOT_GROUP = make_id("group-root")
SOURCES_GROUP = make_id("group-Sources")
RESOURCES_GROUP = make_id("group-Resources")
TESTS_GROUP = make_id("group-Tests")
FRAMEWORKS_GROUP = make_id("group-Frameworks")
PRODUCTS_GROUP = make_id("group-Products")
PACKAGES_GROUP = make_id("group-Packages")

# Target IDs
APP_TARGET = make_id("target-app")
TEST_TARGET = make_id("target-tests")
APP_PRODUCT_REF = make_id("productref-app")
TEST_PRODUCT_REF = make_id("productref-tests")

# Build phase IDs
APP_SOURCES_PHASE = make_id("phase-app-sources")
APP_RESOURCES_PHASE = make_id("phase-app-resources")
APP_FRAMEWORKS_PHASE = make_id("phase-app-frameworks")
TEST_SOURCES_PHASE = make_id("phase-test-sources")
TEST_FRAMEWORKS_PHASE = make_id("phase-test-frameworks")

# Build configuration IDs
PROJECT_BCL = make_id("bcl-project")
PROJECT_DEBUG_BC = make_id("bc-project-debug")
PROJECT_RELEASE_BC = make_id("bc-project-release")
APP_BCL = make_id("bcl-app")
APP_DEBUG_BC = make_id("bc-app-debug")
APP_RELEASE_BC = make_id("bc-app-release")
TEST_BCL = make_id("bcl-test")
TEST_DEBUG_BC = make_id("bc-test-debug")
TEST_RELEASE_BC = make_id("bc-test-release")

# Project root
PROJECT_OBJ = make_id("project-root")

# SPM Package references
PKG_CRYPTO_REF = make_id("pkg-swift-crypto")
PKG_KEYBOARD_REF = make_id("pkg-keyboard-shortcuts")
PKG_SWIFTSOUP_REF = make_id("pkg-swiftsoup")

# SPM Product dependency references (in target)
PKG_CRYPTO_PROD = make_id("pkgprod-Crypto")
PKG_KEYBOARD_PROD = make_id("pkgprod-KeyboardShortcuts")
PKG_SWIFTSOUP_PROD = make_id("pkgprod-SwiftSoup")

# Framework build file refs for SPM products
PKG_CRYPTO_BUILD = make_id("pkgbuild-Crypto")
PKG_KEYBOARD_BUILD = make_id("pkgbuild-KeyboardShortcuts")
PKG_SWIFTSOUP_BUILD = make_id("pkgbuild-SwiftSoup")

# Framework references for SPM products
PKG_CRYPTO_FWREF = make_id("pkgfwref-Crypto")
PKG_KEYBOARD_FWREF = make_id("pkgfwref-KeyboardShortcuts")
PKG_SWIFTSOUP_FWREF = make_id("pkgfwref-SwiftSoup")

# Target dependency for tests -> app
TEST_TARGET_DEP = make_id("targetdep-test-app")
TEST_TARGET_PROXY = make_id("proxy-test-app")

# ---------------------------------------------------------------------------
# PBX helper: quote strings if needed
# ---------------------------------------------------------------------------

def q(s: str) -> str:
    """Quote a string for pbxproj if it contains special characters."""
    if not s:
        return '""'
    safe = all(c.isalnum() or c in "._/-" for c in s)
    if safe and not s[0].isdigit():
        return s
    return f'"{s}"'


# ---------------------------------------------------------------------------
# Build the pbxproj content
# ---------------------------------------------------------------------------

lines = []

def w(line: str = ""):
    lines.append(line)


def build_file_entry(bid: str, fref: str, name: str, settings: str = ""):
    s = f"\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fref} /* {name} */;"
    if settings:
        s += f" settings = {settings};"
    s += " };"
    w(s)


def resource_build_file_entry(bid: str, fref: str, name: str):
    w(f"\t\t{bid} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {fref} /* {name} */; }};")


def framework_build_file_entry(bid: str, fref: str, name: str):
    w(f"\t\t{bid} /* {name} in Frameworks */ = {{isa = PBXBuildFile; productRef = {fref} /* {name} */; }};")


# ===== Begin pbxproj =====
w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 60;")
w("\tobjects = {")
w("")

# --- PBXBuildFile ---
w("/* Begin PBXBuildFile section */")

# App source files
for rel_path, name in source_files:
    build_file_entry(build_files[rel_path], file_refs[rel_path], name)

# App resources
resource_build_file_entry(ASSETS_BUILD, ASSETS_REF, "Assets.xcassets")
if ICNS_EXISTS:
    resource_build_file_entry(ICNS_BUILD, ICNS_REF, "AppIcon.icns")

# Test source files
for rel_path, name in test_files:
    build_file_entry(build_files[rel_path], file_refs[rel_path], name)

# SPM framework build files
framework_build_file_entry(PKG_CRYPTO_BUILD, PKG_CRYPTO_PROD, "Crypto")
framework_build_file_entry(PKG_KEYBOARD_BUILD, PKG_KEYBOARD_PROD, "KeyboardShortcuts")
framework_build_file_entry(PKG_SWIFTSOUP_BUILD, PKG_SWIFTSOUP_PROD, "SwiftSoup")

w("/* End PBXBuildFile section */")
w("")

# --- PBXContainerItemProxy ---
w("/* Begin PBXContainerItemProxy section */")
w(f"\t\t{TEST_TARGET_PROXY} /* PBXContainerItemProxy */ = {{")
w(f"\t\t\tisa = PBXContainerItemProxy;")
w(f"\t\t\tcontainerPortal = {PROJECT_OBJ} /* Project object */;")
w(f"\t\t\tproxyType = 1;")
w(f"\t\t\tremoteGlobalIDString = {APP_TARGET};")
w(f'\t\t\tremoteInfo = MacKeyValue;')
w(f"\t\t}};")
w("/* End PBXContainerItemProxy section */")
w("")

# --- PBXFileReference ---
w("/* Begin PBXFileReference section */")

# App product
w(f'\t\t{APP_PRODUCT_REF} /* MacKeyValue.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MacKeyValue.app; sourceTree = BUILT_PRODUCTS_DIR; }};')

# Test product
w(f'\t\t{TEST_PRODUCT_REF} /* MacKeyValueTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = MacKeyValueTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')

# Source files
for rel_path, name in source_files:
    w(f'\t\t{file_refs[rel_path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(name)}; sourceTree = "<group>"; }};')

# Test files
for rel_path, name in test_files:
    w(f'\t\t{file_refs[rel_path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(name)}; sourceTree = "<group>"; }};')

# Resources
w(f'\t\t{ASSETS_REF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
w(f'\t\t{INFO_PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
w(f'\t\t{ENTITLEMENTS_REF} /* MacKeyValue.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = MacKeyValue.entitlements; sourceTree = "<group>"; }};')
if ICNS_EXISTS:
    w(f'\t\t{ICNS_REF} /* AppIcon.icns */ = {{isa = PBXFileReference; lastKnownFileType = image.icns; path = AppIcon.icns; sourceTree = "<group>"; }};')

w("/* End PBXFileReference section */")
w("")

# --- PBXFrameworksBuildPhase ---
w("/* Begin PBXFrameworksBuildPhase section */")

# App frameworks phase
w(f"\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */ = {{")
w(f"\t\t\tisa = PBXFrameworksBuildPhase;")
w(f"\t\t\tbuildActionMask = 2147483647;")
w(f"\t\t\tfiles = (")
w(f"\t\t\t\t{PKG_CRYPTO_BUILD} /* Crypto in Frameworks */,")
w(f"\t\t\t\t{PKG_KEYBOARD_BUILD} /* KeyboardShortcuts in Frameworks */,")
w(f"\t\t\t\t{PKG_SWIFTSOUP_BUILD} /* SwiftSoup in Frameworks */,")
w(f"\t\t\t);")
w(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w(f"\t\t}};")

# Test frameworks phase
w(f"\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */ = {{")
w(f"\t\t\tisa = PBXFrameworksBuildPhase;")
w(f"\t\t\tbuildActionMask = 2147483647;")
w(f"\t\t\tfiles = (")
w(f"\t\t\t);")
w(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w(f"\t\t}};")

w("/* End PBXFrameworksBuildPhase section */")
w("")

# --- PBXGroup ---
w("/* Begin PBXGroup section */")

# Root group
root_children = [SOURCES_GROUP, RESOURCES_GROUP, TESTS_GROUP, PACKAGES_GROUP, FRAMEWORKS_GROUP, PRODUCTS_GROUP]
w(f"\t\t{ROOT_GROUP} = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
for c in root_children:
    w(f"\t\t\t\t{c},")
w(f"\t\t\t);")
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Products group
w(f"\t\t{PRODUCTS_GROUP} /* Products */ = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
w(f"\t\t\t\t{APP_PRODUCT_REF} /* MacKeyValue.app */,")
w(f"\t\t\t\t{TEST_PRODUCT_REF} /* MacKeyValueTests.xctest */,")
w(f"\t\t\t);")
w(f'\t\t\tname = Products;')
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Frameworks group
w(f"\t\t{FRAMEWORKS_GROUP} /* Frameworks */ = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
w(f"\t\t\t);")
w(f'\t\t\tname = Frameworks;')
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Packages group
w(f"\t\t{PACKAGES_GROUP} /* Packages */ = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
w(f"\t\t\t);")
w(f'\t\t\tname = Packages;')
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Resources group
resources_children = [ASSETS_REF, INFO_PLIST_REF, ENTITLEMENTS_REF]
if ICNS_EXISTS:
    resources_children.append(ICNS_REF)
w(f"\t\t{RESOURCES_GROUP} /* Resources */ = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
for c in resources_children:
    w(f"\t\t\t\t{c},")
w(f"\t\t\t);")
w(f'\t\t\tpath = Resources;')
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Tests group
tests_children_ids = [file_refs[rp] for rp, _ in test_files]
w(f"\t\t{TESTS_GROUP} /* Tests */ = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
for c in tests_children_ids:
    w(f"\t\t\t\t{c},")
w(f"\t\t\t);")
w(f'\t\t\tpath = Tests;')
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Sources group - build hierarchical groups
# First, compute the direct children of Sources/
source_subdirs = set()
source_root_files = []
for rel_path, name in source_files:
    parts = Path(rel_path).parts  # e.g. ('Sources', 'App', 'MacKeyValueApp.swift')
    if len(parts) == 2:
        source_root_files.append(rel_path)
    elif len(parts) >= 3:
        source_subdirs.add(parts[1])

source_subdir_list = sorted(source_subdirs)

# Sources group
w(f"\t\t{SOURCES_GROUP} /* Sources */ = {{")
w(f"\t\t\tisa = PBXGroup;")
w(f"\t\t\tchildren = (")
for sd in source_subdir_list:
    gkey = f"Sources/{sd}"
    w(f"\t\t\t\t{groups[gkey]} /* {sd} */,")
for rp in source_root_files:
    w(f"\t\t\t\t{file_refs[rp]},")
w(f"\t\t\t);")
w(f'\t\t\tpath = Sources;')
w(f'\t\t\tsourceTree = "<group>";')
w(f"\t\t}};")

# Sub-groups under Sources (App, Models, Services, ViewModels, Views, Utilities)
for sd in source_subdir_list:
    gkey = f"Sources/{sd}"
    gid = groups[gkey]
    # Collect files in this subdir
    children_ids = []
    for rel_path, name in source_files:
        parts = Path(rel_path).parts
        if len(parts) >= 3 and parts[1] == sd:
            children_ids.append((file_refs[rel_path], name))

    w(f"\t\t{gid} /* {sd} */ = {{")
    w(f"\t\t\tisa = PBXGroup;")
    w(f"\t\t\tchildren = (")
    for cid, cname in children_ids:
        w(f"\t\t\t\t{cid} /* {cname} */,")
    w(f"\t\t\t);")
    w(f'\t\t\tpath = {q(sd)};')
    w(f'\t\t\tsourceTree = "<group>";')
    w(f"\t\t}};")

w("/* End PBXGroup section */")
w("")

# --- PBXNativeTarget ---
w("/* Begin PBXNativeTarget section */")

# App target
w(f"\t\t{APP_TARGET} /* MacKeyValue */ = {{")
w(f"\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {APP_BCL} /* Build configuration list for PBXNativeTarget \"MacKeyValue\" */;")
w(f"\t\t\tbuildPhases = (")
w(f"\t\t\t\t{APP_SOURCES_PHASE} /* Sources */,")
w(f"\t\t\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */,")
w(f"\t\t\t\t{APP_RESOURCES_PHASE} /* Resources */,")
w(f"\t\t\t);")
w(f"\t\t\tbuildRules = (")
w(f"\t\t\t);")
w(f"\t\t\tdependencies = (")
w(f"\t\t\t);")
w(f"\t\t\tname = MacKeyValue;")
w(f"\t\t\tpackageProductDependencies = (")
w(f"\t\t\t\t{PKG_CRYPTO_PROD} /* Crypto */,")
w(f"\t\t\t\t{PKG_KEYBOARD_PROD} /* KeyboardShortcuts */,")
w(f"\t\t\t\t{PKG_SWIFTSOUP_PROD} /* SwiftSoup */,")
w(f"\t\t\t);")
w(f"\t\t\tproductName = MacKeyValue;")
w(f"\t\t\tproductReference = {APP_PRODUCT_REF} /* MacKeyValue.app */;")
w(f'\t\t\tproductType = "com.apple.product-type.application";')
w(f"\t\t}};")

# Test target
w(f"\t\t{TEST_TARGET} /* MacKeyValueTests */ = {{")
w(f"\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {TEST_BCL} /* Build configuration list for PBXNativeTarget \"MacKeyValueTests\" */;")
w(f"\t\t\tbuildPhases = (")
w(f"\t\t\t\t{TEST_SOURCES_PHASE} /* Sources */,")
w(f"\t\t\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */,")
w(f"\t\t\t);")
w(f"\t\t\tbuildRules = (")
w(f"\t\t\t);")
w(f"\t\t\tdependencies = (")
w(f"\t\t\t\t{TEST_TARGET_DEP} /* PBXTargetDependency */,")
w(f"\t\t\t);")
w(f"\t\t\tname = MacKeyValueTests;")
w(f"\t\t\tproductName = MacKeyValueTests;")
w(f"\t\t\tproductReference = {TEST_PRODUCT_REF} /* MacKeyValueTests.xctest */;")
w(f'\t\t\tproductType = "com.apple.product-type.bundle.unit-test";')
w(f"\t\t}};")

w("/* End PBXNativeTarget section */")
w("")

# --- PBXProject ---
w("/* Begin PBXProject section */")
w(f"\t\t{PROJECT_OBJ} /* Project object */ = {{")
w(f"\t\t\tisa = PBXProject;")
w(f"\t\t\tattributes = {{")
w(f"\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w(f"\t\t\t\tLastSwiftUpdateCheck = 1500;")
w(f"\t\t\t\tLastUpgradeCheck = 1500;")
w(f"\t\t\t\tTargetAttributes = {{")
w(f"\t\t\t\t\t{APP_TARGET} = {{")
w(f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
w(f"\t\t\t\t\t}};")
w(f"\t\t\t\t\t{TEST_TARGET} = {{")
w(f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
w(f"\t\t\t\t\t\tTestTargetID = {APP_TARGET};")
w(f"\t\t\t\t\t}};")
w(f"\t\t\t\t}};")
w(f"\t\t\t}};")
w(f"\t\t\tbuildConfigurationList = {PROJECT_BCL} /* Build configuration list for PBXProject \"MacKeyValue\" */;")
w(f'\t\t\tcompatibilityVersion = "Xcode 14.0";')
w(f"\t\t\tdevelopmentRegion = \"zh-Hans\";")
w(f"\t\t\thasScannedForEncodings = 0;")
w(f"\t\t\tknownRegions = (")
w(f"\t\t\t\ten,")
w(f'\t\t\t\t"zh-Hans",')
w(f"\t\t\t\tBase,")
w(f"\t\t\t);")
w(f"\t\t\tmainGroup = {ROOT_GROUP};")
w(f"\t\t\tpackageReferences = (")
w(f"\t\t\t\t{PKG_CRYPTO_REF} /* XCRemoteSwiftPackageReference \"swift-crypto\" */,")
w(f"\t\t\t\t{PKG_KEYBOARD_REF} /* XCRemoteSwiftPackageReference \"KeyboardShortcuts\" */,")
w(f"\t\t\t\t{PKG_SWIFTSOUP_REF} /* XCRemoteSwiftPackageReference \"SwiftSoup\" */,")
w(f"\t\t\t);")
w(f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;")
w(f"\t\t\tprojectDirPath = \"\";")
w(f'\t\t\tprojectRoot = "";')
w(f"\t\t\ttargets = (")
w(f"\t\t\t\t{APP_TARGET} /* MacKeyValue */,")
w(f"\t\t\t\t{TEST_TARGET} /* MacKeyValueTests */,")
w(f"\t\t\t);")
w(f"\t\t}};")

w("/* End PBXProject section */")
w("")

# --- PBXResourcesBuildPhase ---
w("/* Begin PBXResourcesBuildPhase section */")
w(f"\t\t{APP_RESOURCES_PHASE} /* Resources */ = {{")
w(f"\t\t\tisa = PBXResourcesBuildPhase;")
w(f"\t\t\tbuildActionMask = 2147483647;")
w(f"\t\t\tfiles = (")
w(f"\t\t\t\t{ASSETS_BUILD} /* Assets.xcassets in Resources */,")
if ICNS_EXISTS:
    w(f"\t\t\t\t{ICNS_BUILD} /* AppIcon.icns in Resources */,")
w(f"\t\t\t);")
w(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w(f"\t\t}};")
w("/* End PBXResourcesBuildPhase section */")
w("")

# --- PBXSourcesBuildPhase ---
w("/* Begin PBXSourcesBuildPhase section */")

# App sources
w(f"\t\t{APP_SOURCES_PHASE} /* Sources */ = {{")
w(f"\t\t\tisa = PBXSourcesBuildPhase;")
w(f"\t\t\tbuildActionMask = 2147483647;")
w(f"\t\t\tfiles = (")
for rel_path, name in source_files:
    w(f"\t\t\t\t{build_files[rel_path]} /* {name} in Sources */,")
w(f"\t\t\t);")
w(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w(f"\t\t}};")

# Test sources
w(f"\t\t{TEST_SOURCES_PHASE} /* Sources */ = {{")
w(f"\t\t\tisa = PBXSourcesBuildPhase;")
w(f"\t\t\tbuildActionMask = 2147483647;")
w(f"\t\t\tfiles = (")
for rel_path, name in test_files:
    w(f"\t\t\t\t{build_files[rel_path]} /* {name} in Sources */,")
w(f"\t\t\t);")
w(f"\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w(f"\t\t}};")

w("/* End PBXSourcesBuildPhase section */")
w("")

# --- PBXTargetDependency ---
w("/* Begin PBXTargetDependency section */")
w(f"\t\t{TEST_TARGET_DEP} /* PBXTargetDependency */ = {{")
w(f"\t\t\tisa = PBXTargetDependency;")
w(f"\t\t\ttarget = {APP_TARGET} /* MacKeyValue */;")
w(f"\t\t\ttargetProxy = {TEST_TARGET_PROXY} /* PBXContainerItemProxy */;")
w(f"\t\t}};")
w("/* End PBXTargetDependency section */")
w("")

# --- XCBuildConfiguration ---
w("/* Begin XCBuildConfiguration section */")

# Project-level Debug
w(f"\t\t{PROJECT_DEBUG_BC} /* Debug */ = {{")
w(f"\t\t\tisa = XCBuildConfiguration;")
w(f"\t\t\tbuildSettings = {{")
w(f"\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
w(f"\t\t\t\tASYNC_COMPILATION = YES;")
w(f"\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
w(f"\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;")
w(f"\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";")
w(f"\t\t\t\tCLANG_ENABLE_MODULES = YES;")
w(f"\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
w(f"\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;")
w(f"\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;")
w(f"\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_COMMA = YES;")
w(f"\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;")
w(f"\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;")
w(f"\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;")
w(f"\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;")
w(f"\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;")
w(f"\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;")
w(f"\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;")
w(f"\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;")
w(f"\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;")
w(f"\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;")
w(f"\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;")
w(f"\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;")
w(f"\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;")
w(f"\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;")
w(f"\t\t\t\tCOPY_PHASE_STRIP = NO;")
w(f"\t\t\t\tDEAD_CODE_STRIPPING = YES;")
w(f"\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
w(f"\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
w(f"\t\t\t\tENABLE_TESTABILITY = YES;")
w(f"\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;")
w(f"\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;")
w(f"\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
w(f"\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
w(f"\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
w(f"\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
w(f'\t\t\t\t\t"DEBUG=1",')
w(f'\t\t\t\t\t"$(inherited)",')
w(f"\t\t\t\t);")
w(f"\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;")
w(f"\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;")
w(f"\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;")
w(f"\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;")
w(f"\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;")
w(f"\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;")
w(f"\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};")
w(f"\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
w(f"\t\t\t\tMTL_FAST_MATH = YES;")
w(f"\t\t\t\tONLY_ACTIVE_ARCH = YES;")
w(f"\t\t\t\tSDKROOT = macosx;")
w(f'\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) DEBUG";')
w(f"\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
w(f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
w(f"\t\t\t}};")
w(f"\t\t\tname = Debug;")
w(f"\t\t}};")

# Project-level Release
w(f"\t\t{PROJECT_RELEASE_BC} /* Release */ = {{")
w(f"\t\t\tisa = XCBuildConfiguration;")
w(f"\t\t\tbuildSettings = {{")
w(f"\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
w(f"\t\t\t\tASYNC_COMPILATION = YES;")
w(f"\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
w(f"\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;")
w(f"\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = \"gnu++20\";")
w(f"\t\t\t\tCLANG_ENABLE_MODULES = YES;")
w(f"\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
w(f"\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;")
w(f"\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;")
w(f"\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_COMMA = YES;")
w(f"\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;")
w(f"\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;")
w(f"\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;")
w(f"\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;")
w(f"\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;")
w(f"\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;")
w(f"\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;")
w(f"\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;")
w(f"\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;")
w(f"\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;")
w(f"\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;")
w(f"\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;")
w(f"\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;")
w(f"\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;")
w(f"\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;")
w(f"\t\t\t\tCOPY_PHASE_STRIP = NO;")
w(f"\t\t\t\tDEAD_CODE_STRIPPING = YES;")
w(f"\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
w(f"\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
w(f"\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
w(f"\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;")
w(f"\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;")
w(f"\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
w(f"\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;")
w(f"\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;")
w(f"\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;")
w(f"\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;")
w(f"\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;")
w(f"\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;")
w(f"\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};")
w(f"\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
w(f"\t\t\t\tMTL_FAST_MATH = YES;")
w(f"\t\t\t\tSDKROOT = macosx;")
w(f"\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
w(f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
w(f"\t\t\t\tVALIDATE_PRODUCT = YES;")
w(f"\t\t\t}};")
w(f"\t\t\tname = Release;")
w(f"\t\t}};")

# App target Debug
w(f"\t\t{APP_DEBUG_BC} /* Debug */ = {{")
w(f"\t\t\tisa = XCBuildConfiguration;")
w(f"\t\t\tbuildSettings = {{")
w(f'\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
w(f'\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
w(f'\t\t\t\tCODE_SIGN_ENTITLEMENTS = Resources/MacKeyValue.entitlements;')
w(f'\t\t\t\tCODE_SIGN_IDENTITY = "-";')
w(f'\t\t\t\tCODE_SIGN_STYLE = Automatic;')
w(f'\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
w(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
if TEAM_ID:
    w(f'\t\t\t\tDEVELOPMENT_TEAM = {TEAM_ID};')
else:
    w(f'\t\t\t\tDEVELOPMENT_TEAM = "";')
w(f'\t\t\t\tENABLE_APP_SANDBOX = YES;')
w(f'\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
w(f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;')
w(f'\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;')
w(f'\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = MacKeyValue;')
w(f'\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";')
w(f'\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © 2024 MacKeyValue. All rights reserved.";')
w(f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
w(f'\t\t\t\t\t"$(inherited)",')
w(f'\t\t\t\t\t"@executable_path/../Frameworks",')
w(f'\t\t\t\t);')
w(f'\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};')
w(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
w(f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};')
w(f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
w(f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
w(f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
w(f"\t\t\t}};")
w(f"\t\t\tname = Debug;")
w(f"\t\t}};")

# App target Release
w(f"\t\t{APP_RELEASE_BC} /* Release */ = {{")
w(f"\t\t\tisa = XCBuildConfiguration;")
w(f"\t\t\tbuildSettings = {{")
w(f'\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
w(f'\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
w(f'\t\t\t\tCODE_SIGN_ENTITLEMENTS = Resources/MacKeyValue.entitlements;')
w(f'\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";')
w(f'\t\t\t\tCODE_SIGN_STYLE = Automatic;')
w(f'\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
w(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
if TEAM_ID:
    w(f'\t\t\t\tDEVELOPMENT_TEAM = {TEAM_ID};')
else:
    w(f'\t\t\t\tDEVELOPMENT_TEAM = "";')
w(f'\t\t\t\tENABLE_APP_SANDBOX = YES;')
w(f'\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
w(f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;')
w(f'\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;')
w(f'\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = MacKeyValue;')
w(f'\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";')
w(f'\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © 2024 MacKeyValue. All rights reserved.";')
w(f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
w(f'\t\t\t\t\t"$(inherited)",')
w(f'\t\t\t\t\t"@executable_path/../Frameworks",')
w(f'\t\t\t\t);')
w(f'\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};')
w(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
w(f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};')
w(f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
w(f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
w(f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
w(f"\t\t\t}};")
w(f"\t\t\tname = Release;")
w(f"\t\t}};")

# Test target Debug
w(f"\t\t{TEST_DEBUG_BC} /* Debug */ = {{")
w(f"\t\t\tisa = XCBuildConfiguration;")
w(f"\t\t\tbuildSettings = {{")
w(f'\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";')
w(f'\t\t\t\tCODE_SIGN_STYLE = Automatic;')
w(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
if TEAM_ID:
    w(f'\t\t\t\tDEVELOPMENT_TEAM = {TEAM_ID};')
w(f'\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
w(f'\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};')
w(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
w(f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}.tests;')
w(f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
w(f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;')
w(f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
w(f'\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/MacKeyValue.app/Contents/MacOS/MacKeyValue";')
w(f"\t\t\t}};")
w(f"\t\t\tname = Debug;")
w(f"\t\t}};")

# Test target Release
w(f"\t\t{TEST_RELEASE_BC} /* Release */ = {{")
w(f"\t\t\tisa = XCBuildConfiguration;")
w(f"\t\t\tbuildSettings = {{")
w(f'\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";')
w(f'\t\t\t\tCODE_SIGN_STYLE = Automatic;')
w(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
if TEAM_ID:
    w(f'\t\t\t\tDEVELOPMENT_TEAM = {TEAM_ID};')
w(f'\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
w(f'\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};')
w(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
w(f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}.tests;')
w(f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
w(f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;')
w(f"\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};")
w(f'\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/MacKeyValue.app/Contents/MacOS/MacKeyValue";')
w(f"\t\t\t}};")
w(f"\t\t\tname = Release;")
w(f"\t\t}};")

w("/* End XCBuildConfiguration section */")
w("")

# --- XCBuildConfigurationList ---
w("/* Begin XCConfigurationList section */")

w(f'\t\t{PROJECT_BCL} /* Build configuration list for PBXProject "MacKeyValue" */ = {{')
w(f"\t\t\tisa = XCConfigurationList;")
w(f"\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{PROJECT_DEBUG_BC} /* Debug */,")
w(f"\t\t\t\t{PROJECT_RELEASE_BC} /* Release */,")
w(f"\t\t\t);")
w(f"\t\t\tdefaultConfigurationIsVisible = 0;")
w(f"\t\t\tdefaultConfigurationName = Release;")
w(f"\t\t}};")

w(f'\t\t{APP_BCL} /* Build configuration list for PBXNativeTarget "MacKeyValue" */ = {{')
w(f"\t\t\tisa = XCConfigurationList;")
w(f"\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{APP_DEBUG_BC} /* Debug */,")
w(f"\t\t\t\t{APP_RELEASE_BC} /* Release */,")
w(f"\t\t\t);")
w(f"\t\t\tdefaultConfigurationIsVisible = 0;")
w(f"\t\t\tdefaultConfigurationName = Release;")
w(f"\t\t}};")

w(f'\t\t{TEST_BCL} /* Build configuration list for PBXNativeTarget "MacKeyValueTests" */ = {{')
w(f"\t\t\tisa = XCConfigurationList;")
w(f"\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{TEST_DEBUG_BC} /* Debug */,")
w(f"\t\t\t\t{TEST_RELEASE_BC} /* Release */,")
w(f"\t\t\t);")
w(f"\t\t\tdefaultConfigurationIsVisible = 0;")
w(f"\t\t\tdefaultConfigurationName = Release;")
w(f"\t\t}};")

w("/* End XCConfigurationList section */")
w("")

# --- XCRemoteSwiftPackageReference ---
w("/* Begin XCRemoteSwiftPackageReference section */")

w(f'\t\t{PKG_CRYPTO_REF} /* XCRemoteSwiftPackageReference "swift-crypto" */ = {{')
w(f"\t\t\tisa = XCRemoteSwiftPackageReference;")
w(f'\t\t\trepositoryURL = "https://github.com/apple/swift-crypto.git";')
w(f"\t\t\trequirement = {{")
w(f"\t\t\t\tkind = upToNextMajorVersion;")
w(f'\t\t\t\tminimumVersion = "3.0.0";')
w(f"\t\t\t}};")
w(f"\t\t}};")

w(f'\t\t{PKG_KEYBOARD_REF} /* XCRemoteSwiftPackageReference "KeyboardShortcuts" */ = {{')
w(f"\t\t\tisa = XCRemoteSwiftPackageReference;")
w(f'\t\t\trepositoryURL = "https://github.com/sindresorhus/KeyboardShortcuts.git";')
w(f"\t\t\trequirement = {{")
w(f"\t\t\t\tkind = upToNextMajorVersion;")
w(f'\t\t\t\tminimumVersion = "1.16.0";')
w(f"\t\t\t}};")
w(f"\t\t}};")

w(f'\t\t{PKG_SWIFTSOUP_REF} /* XCRemoteSwiftPackageReference "SwiftSoup" */ = {{')
w(f"\t\t\tisa = XCRemoteSwiftPackageReference;")
w(f'\t\t\trepositoryURL = "https://github.com/scinfu/SwiftSoup.git";')
w(f"\t\t\trequirement = {{")
w(f"\t\t\t\tkind = upToNextMajorVersion;")
w(f'\t\t\t\tminimumVersion = "2.6.0";')
w(f"\t\t\t}};")
w(f"\t\t}};")

w("/* End XCRemoteSwiftPackageReference section */")
w("")

# --- XCSwiftPackageProductDependency ---
w("/* Begin XCSwiftPackageProductDependency section */")

w(f"\t\t{PKG_CRYPTO_PROD} /* Crypto */ = {{")
w(f"\t\t\tisa = XCSwiftPackageProductDependency;")
w(f"\t\t\tpackage = {PKG_CRYPTO_REF} /* XCRemoteSwiftPackageReference \"swift-crypto\" */;")
w(f'\t\t\tproductName = Crypto;')
w(f"\t\t}};")

w(f"\t\t{PKG_KEYBOARD_PROD} /* KeyboardShortcuts */ = {{")
w(f"\t\t\tisa = XCSwiftPackageProductDependency;")
w(f"\t\t\tpackage = {PKG_KEYBOARD_REF} /* XCRemoteSwiftPackageReference \"KeyboardShortcuts\" */;")
w(f'\t\t\tproductName = KeyboardShortcuts;')
w(f"\t\t}};")

w(f"\t\t{PKG_SWIFTSOUP_PROD} /* SwiftSoup */ = {{")
w(f"\t\t\tisa = XCSwiftPackageProductDependency;")
w(f"\t\t\tpackage = {PKG_SWIFTSOUP_REF} /* XCRemoteSwiftPackageReference \"SwiftSoup\" */;")
w(f'\t\t\tproductName = SwiftSoup;')
w(f"\t\t}};")

w("/* End XCSwiftPackageProductDependency section */")
w("")

# Close objects and root
w("\t};")
w(f"\trootObject = {PROJECT_OBJ} /* Project object */;")
w("}")

# ---------------------------------------------------------------------------
# Write the output
# ---------------------------------------------------------------------------

xcodeproj_dir = PROJECT_ROOT / "MacKeyValue.xcodeproj"
xcodeproj_dir.mkdir(parents=True, exist_ok=True)

pbxproj_path = xcodeproj_dir / "project.pbxproj"
content = "\n".join(lines) + "\n"
pbxproj_path.write_text(content, encoding="utf-8")

# Also write xcshareddata/xcschemes for the scheme
schemes_dir = xcodeproj_dir / "xcshareddata" / "xcschemes"
schemes_dir.mkdir(parents=True, exist_ok=True)

scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{APP_TARGET}"
               BuildableName = "MacKeyValue.app"
               BlueprintName = "MacKeyValue"
               ReferencedContainer = "container:MacKeyValue.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TEST_TARGET}"
               BuildableName = "MacKeyValueTests.xctest"
               BlueprintName = "MacKeyValueTests"
               ReferencedContainer = "container:MacKeyValue.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET}"
            BuildableName = "MacKeyValue.app"
            BlueprintName = "MacKeyValue"
            ReferencedContainer = "container:MacKeyValue.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET}"
            BuildableName = "MacKeyValue.app"
            BlueprintName = "MacKeyValue"
            ReferencedContainer = "container:MacKeyValue.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

scheme_path = schemes_dir / "MacKeyValue.xcscheme"
scheme_path.write_text(scheme_xml.strip() + "\n", encoding="utf-8")

# Write xcshareddata management plist
mgmt_plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SchemeUserState</key>
	<dict>
		<key>MacKeyValue.xcscheme_^#shared#^_</key>
		<dict>
			<key>orderHint</key>
			<integer>0</integer>
		</dict>
	</dict>
</dict>
</plist>
"""

# Write workspace settings
ws_shared = xcodeproj_dir / "project.xcworkspace" / "xcshareddata"
ws_shared.mkdir(parents=True, exist_ok=True)

ws_settings = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key>
	<false/>
</dict>
</plist>
"""

(ws_shared / "WorkspaceSettings.xcsettings").write_text(ws_settings.strip() + "\n", encoding="utf-8")

# Workspace data
ws_data = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""

ws_data_dir = xcodeproj_dir / "project.xcworkspace"
(ws_data_dir / "contents.xcworkspacedata").write_text(ws_data.strip() + "\n", encoding="utf-8")

# ---------------------------------------------------------------------------
# Write the build script for convenience
# ---------------------------------------------------------------------------

build_script = PROJECT_ROOT / "build.sh"
build_script_content = """#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="MacKeyValue.xcodeproj"
SCHEME="MacKeyValue"
CONFIG="${1:-Release}"
ARCHIVE_PATH="./build/MacKeyValue.xcarchive"
EXPORT_PATH="./build/export"

echo "🔨 Building MacKeyValue ($CONFIG)..."

# Clean build
xcodebuild clean -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" 2>&1 | tail -3

# Build archive
echo ""
echo "📦 Creating archive..."
xcodebuild archive \\
    -project "$PROJECT" \\
    -scheme "$SCHEME" \\
    -configuration Release \\
    -archivePath "$ARCHIVE_PATH" \\
    -destination "generic/platform=macOS" \\
    CODE_SIGN_IDENTITY="-" \\
    CODE_SIGNING_REQUIRED=NO \\
    CODE_SIGNING_ALLOWED=NO \\
    2>&1 | tail -5

if [ -d "$ARCHIVE_PATH" ]; then
    echo ""
    echo "✅ Archive created at: $ARCHIVE_PATH"
    echo ""
    echo "📍 App location: $ARCHIVE_PATH/Products/Applications/MacKeyValue.app"

    # Copy .app to build/ for easy access
    APP_PATH="$ARCHIVE_PATH/Products/Applications/MacKeyValue.app"
    if [ -d "$APP_PATH" ]; then
        cp -R "$APP_PATH" "./build/MacKeyValue.app"
        echo "📍 Copied to: ./build/MacKeyValue.app"
    fi
else
    echo "❌ Archive failed"
    exit 1
fi

echo ""
echo "=== App Store Submission ==="
echo "To submit to the App Store:"
echo "1. Open MacKeyValue.xcodeproj in Xcode"
echo "2. Set your Development Team in Signing & Capabilities"
echo "3. Product → Archive"
echo "4. Window → Organizer → Distribute App"
echo "5. Select 'App Store Connect' and follow the wizard"
"""

build_script.write_text(build_script_content.strip() + "\n", encoding="utf-8")
os.chmod(str(build_script), 0o755)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print(f"""
{'='*60}
  ✅  Xcode project generated successfully!
{'='*60}

  📁 Project:   {xcodeproj_dir}
  📁 Scheme:    {scheme_path}
  📁 pbxproj:   {pbxproj_path}
  🔨 Build:     {build_script}

  Source files:  {len(source_files)}
  Test files:    {len(test_files)}
  SPM packages:  3 (swift-crypto, KeyboardShortcuts, SwiftSoup)
  Icon sizes:    10 (16→1024px)

  Next steps:
  1. Open MacKeyValue.xcodeproj in Xcode
  2. Set your Apple Developer Team ID in project settings
  3. Build & Run (⌘R) to verify everything works
  4. Product → Archive for App Store submission
  5. Window → Organizer → Distribute App → App Store Connect

  Or use the build script:
    cd MacKeyValue && ./build.sh

{'='*60}
""")
