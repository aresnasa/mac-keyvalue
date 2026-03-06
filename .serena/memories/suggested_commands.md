# Suggested Commands

## Build
- `cd MacKeyValue && swift build -c release` — Swift release build
- `cd MacKeyValue && swift build -c debug` — Swift debug build
- `cd MacKeyValue && ./build.sh` — Full build: compile + assemble .app bundle + ad-hoc sign
- `cd MacKeyValue && ./build.sh --run` — Build and launch
- `cd MacKeyValue && ./build.sh debug --run` — Debug build and launch

## Run
- `open MacKeyValue/build/MacKeyValue.app` — Launch the built app

## System
- `codesign -vv MacKeyValue/build/MacKeyValue.app` — Verify code signature
- `codesign -d --entitlements :- MacKeyValue/build/MacKeyValue.app` — Show entitlements
