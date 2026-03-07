#!/usr/bin/env python3
"""
Patch MacKeyValue.xcodeproj/project.pbxproj to:
  1. Remove the redundant standalone AppIcon.icns from the Resources build phase
     (actool already handles it via Assets.xcassets)
  2. Add a "Copy AppIcon.icns" Run Script build phase AFTER the Resources phase
     so the hand-crafted AppIcon.icns always wins over actool's cached output.
"""

import sys, os, re

PBXPROJ = os.path.join(
    os.path.dirname(__file__),
    "../MacKeyValue/MacKeyValue.xcodeproj/project.pbxproj"
)

with open(PBXPROJ) as f:
    content = f.read()

SCRIPT_UUID = "B3C7D9E1F2A34B56C78D9E0F"

# ── Guard: already patched? ──────────────────────────────────────────────────
if SCRIPT_UUID in content:
    print("Already patched — nothing to do.")
    sys.exit(0)

# ── 1. Remove standalone AppIcon.icns from Resources build phase ─────────────
OLD_RESOURCES = (
    "\t\t\t\tD150A85CEEEAE2924AF97027 /* Assets.xcassets in Resources */,\n"
    "\t\t\t\t0BE2763B5F18AC90C1E52162 /* AppIcon.icns in Resources */,\n"
)
NEW_RESOURCES = (
    "\t\t\t\tD150A85CEEEAE2924AF97027 /* Assets.xcassets in Resources */,\n"
)
assert OLD_RESOURCES in content or NEW_RESOURCES in content, \
    "Resources build phase not found in expected form"
content = content.replace(OLD_RESOURCES, NEW_RESOURCES)

# ── 2. Insert PBXShellScriptBuildPhase section ───────────────────────────────
SCRIPT_BLOCK = (
    "\n/* Begin PBXShellScriptBuildPhase section */\n"
    "\t\t" + SCRIPT_UUID + " /* Copy AppIcon.icns */ = {\n"
    "\t\t\tisa = PBXShellScriptBuildPhase;\n"
    "\t\t\talwaysOutOfDate = 1;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t);\n"
    "\t\t\tinputFileListPaths = (\n"
    "\t\t\t);\n"
    "\t\t\tinputPaths = (\n"
    '\t\t\t\t"$(PROJECT_DIR)/Resources/AppIcon.icns",\n'
    "\t\t\t);\n"
    '\t\t\tname = "Copy AppIcon.icns";\n'
    "\t\t\toutputFileListPaths = (\n"
    "\t\t\t);\n"
    "\t\t\toutputPaths = (\n"
    '\t\t\t\t"$(CODESIGNING_FOLDER_PATH)/Contents/Resources/AppIcon.icns",\n'
    "\t\t\t);\n"
    "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
    "\t\t\tshellPath = /bin/sh;\n"
    '\t\t\tshellScript = "SRC=\\"$PROJECT_DIR/Resources/AppIcon.icns\\"\\n'
    'DST=\\"$CODESIGNING_FOLDER_PATH/Contents/Resources/AppIcon.icns\\"\\n'
    'if [ -f \\"$SRC\\" ]; then\\n'
    '  cp -f \\"$SRC\\" \\"$DST\\"\\n'
    '  echo \\"note: AppIcon.icns overwritten with hand-crafted version\\"\\n'
    'fi\\n";\n'
    "\t\t};\n"
    "/* End PBXShellScriptBuildPhase section */\n"
)

MARKER = "/* End PBXSourcesBuildPhase section */"
assert MARKER in content, "PBXSourcesBuildPhase end marker not found"
content = content.replace(MARKER, MARKER + SCRIPT_BLOCK, 1)

# ── 3. Add script UUID to MacKeyValue target buildPhases ────────────────────
OLD_PHASES = (
    "\t\t\tbuildPhases = (\n"
    "\t\t\t\t3D3287BFCA0FF58A62A56D5D /* Sources */,\n"
    "\t\t\t\t94E9F5EA046F2AA249F30DE3 /* Frameworks */,\n"
    "\t\t\t\tD4F18BC070EF48AF19D88B6A /* Resources */,\n"
    "\t\t\t);"
)
NEW_PHASES = (
    "\t\t\tbuildPhases = (\n"
    "\t\t\t\t3D3287BFCA0FF58A62A56D5D /* Sources */,\n"
    "\t\t\t\t94E9F5EA046F2AA249F30DE3 /* Frameworks */,\n"
    "\t\t\t\tD4F18BC070EF48AF19D88B6A /* Resources */,\n"
    "\t\t\t\t" + SCRIPT_UUID + " /* Copy AppIcon.icns */,\n"
    "\t\t\t);"
)
assert OLD_PHASES in content, "buildPhases list not found in expected form"
content = content.replace(OLD_PHASES, NEW_PHASES, 1)

with open(PBXPROJ, "w") as f:
    f.write(content)

print("OK: project.pbxproj patched successfully.")
print("  - Removed standalone AppIcon.icns from Resources build phase")
print("  - Added 'Copy AppIcon.icns' Run Script build phase")
