# MacKeyValue - Project Overview

## Purpose
A macOS desktop app for intelligent copy/paste management with password support. Features:
- Smart clipboard copy/paste
- Hotkey-triggered password input
- Simulated keyboard character-by-character typing (for password fields that block paste)
- AES-256-GCM encryption for stored passwords
- Privacy mode (local-only storage)
- Gist sync for common clipboard entries
- Touch ID / biometric authentication

## Tech Stack
- **Language**: Swift (SPM-based project)
- **UI**: SwiftUI
- **Platform**: macOS 13+ (Ventura and above)
- **Architecture**: MVVM (Views → ViewModels → Services)
- **Key frameworks**: Combine, CGEvent (keyboard simulation), IOKit (HID access check)

## Project Structure
```
MacKeyValue/
├── Package.swift          # SPM manifest
├── build.sh               # Build & sign script
├── Sources/
│   ├── App/               # App entry point
│   ├── Views/             # SwiftUI views (ContentView.swift)
│   ├── ViewModels/        # AppViewModel.swift
│   ├── Models/            # Data models
│   ├── Services/          # Business logic services
│   │   ├── ClipboardService.swift    # Clipboard monitoring, CGEvent typing, paste intercept
│   │   ├── HotkeyService.swift       # Carbon hotkey registration & dispatch
│   │   ├── BiometricService.swift    # Touch ID / password auth
│   │   ├── EncryptionService.swift   # AES-256-GCM encryption
│   │   ├── StorageService.swift      # Local persistence
│   │   └── GistSyncService.swift     # GitHub Gist sync
│   └── Utilities/
├── Resources/             # Info.plist, entitlements, AppIcon.icns, Assets.xcassets
└── Tests/
```

## Build Commands
- `cd MacKeyValue && swift build -c release` — Build release
- `cd MacKeyValue && ./build.sh` — Build + assemble .app + ad-hoc sign
- `cd MacKeyValue && ./build.sh --run` — Build and launch
- `cd MacKeyValue && ./build.sh debug --run` — Build debug and launch

## Key Design Patterns
- Singleton services (ClipboardService.shared, HotkeyService.shared, etc.)
- Combine publishers for reactive data flow
- CGEvent-based keyboard simulation with lazy-init CGEventSource (re-created after TCC permission granted)
- Full US ANSI virtual keycode mapping for correct noVNC/VNC keysym translation
- checkAccessibilityPermission() requires AXIsProcessTrusted() ONLY (IOHIDCheckAccess is NOT sufficient for cross-process CGEvent posting)
- build.sh auto-resets TCC Accessibility entry (tccutil reset) to handle ad-hoc signature changes
- detectAndResetStaleTCCEntry() at startup: detects stale TCC entries (IOHIDCheckAccess=true but AXIsProcessTrusted=false), auto-resets for .app (by bundleId) or all entries (bare exec) via tccutil, then re-prompts
- AccessibilityGuideOverlay: animated step-by-step SwiftUI overlay guiding user through Accessibility permission grant; auto-dismisses with success animation when AXIsProcessTrusted flips to true via polling
- autoGrantAccessibility() now shows the AccessibilityGuideOverlay instead of opening System Settings + Finder directly
- AppDelegate posts Notification.Name.showAccessibilityGuide 1.5s after launch if permission not granted
- showAccessibilityGuide @Published property on AppViewModel controls the overlay visibility
- UIMode enum: .compact (paste-focused list) vs .full (3-column management); persisted to UserDefaults
- CompactView: slim searchable list with hover action buttons (Copy/Paste/Type); default mode
- ⌘1 toggles between compact and full mode; also available in View menu and MenuBarExtra
- Search supports regex when wrapped in /pattern/ (both compact and full mode)
- EntryDetailView shows bound hotkey for each entry with link to hotkey settings
- CompactEntryRow shows hotkey badge inline when entry has a bound shortcut
- toggleUIMode() calls resizeWindowForCurrentMode() for animated window resize
- autoGrantAccessibility() writes TCC.db via `osascript with administrator privileges` (sudo sqlite3)
- AccessibilityGuideOverlay primary action: "一键授权" → system password dialog → TCC write → auto-restart
- Falls back to manual System Settings navigation if auto-grant fails (user cancels or SIP blocks)
- openInputMonitoringSystemSettings() opens Privacy_ListenEvent anchor in System Settings
- openAllPermissionSettings() opens both settings pages sequentially
- Unified permission flow: system prompt → (fallback) manual settings → restart app