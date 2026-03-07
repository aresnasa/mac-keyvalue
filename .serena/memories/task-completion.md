# Task Completion Checklist

1. Run `cd MacKeyValue && swift build -c release` to verify the code compiles
2. Run `cd MacKeyValue && ./build.sh` to build the full .app bundle with signing
3. Verify no new errors (warnings about Sendable are acceptable)
4. Test manually if the change involves UI or keyboard simulation

## Icon Pipeline
- `scripts/generate_icon.swift` is the single source of truth for all icons
- `./build.sh --icons` forces icon regeneration (or just touch generate_icon.swift — build.sh auto-regens when script is newer than AppIcon.icns)
- Icons go to: `Resources/AppIcon.appiconset/` + `Resources/Assets.xcassets/AppIcon.appiconset/` + `Resources/AppIcon.icns`
- actool compiles xcassets → Assets.car; source AppIcon.icns is then copied over actool's version
- savePNG uses sRGB CGContext (not deviceRGB) for correct colour rendering
- lockTotalH = capH * 0.88 so shackle top is visibly below K/V tops
- MenuBarExtra uses `lock.fill` SF Symbol (not `key.viewfinder`)
