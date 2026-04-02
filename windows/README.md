# KeyValue for Windows

A Windows companion app for [MacKeyValue](../README.md) — compatible encrypted storage, import/export, and cross-platform password management.

## Features

- **AES-256-GCM encryption** — byte-for-byte compatible with the Mac app (import/export `.mkve` files between platforms)
- **Import** CSV (Chrome, 1Password, LastPass, KeePass, generic), Bitwarden JSON, MacKeyValue JSON / encrypted `.mkve`
- **Export** native JSON, encrypted `.mkve`, plaintext CSV
- **Windows credential store** — master key protected by DPAPI (`ProtectedData`)
- **Search** entries by title, username, URL, notes, tags
- Two-pane UI: entry list + detail view with reveal/copy password

## Requirements

- .NET SDK: 9.0+
- Windows: 10 / 11
- Visual Studio: 2022+ (optional, for IDE)

## Quick Start

```powershell
# 1. Install .NET 9 SDK (if not already installed)
#    https://dotnet.microsoft.com/download

# 2. Clone / navigate to the windows directory
cd windows

# 3. Restore packages and build
dotnet build KeyValueWin/KeyValueWin.csproj

# 4. Run
dotnet run --project KeyValueWin/KeyValueWin.csproj
```

Or open `windows/KeyValueWin.sln` in Visual Studio 2022 and press **F5**.

## Publish a self-contained executable

```powershell
dotnet publish KeyValueWin/KeyValueWin.csproj `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -o dist/
```

The output `dist/KeyValueWin.exe` runs without needing .NET installed.

## One-click packaging (EXE / MSI)

For local Windows packaging, use the dedicated script from repository root:

```powershell
pwsh .\windows\package.ps1 exe
pwsh .\windows\package.ps1 msi
pwsh .\windows\package.ps1 both
```

Optional parameters:

```powershell
pwsh .\windows\package.ps1 both -Version 1.2.3 -Configuration Release -SelfContained
```

Outputs are generated in `windows/dist/`:

- `KeyValueWin-<VERSION>-win-x64.exe`
- `KeyValueWin-<VERSION>-win-x64.msi`

> MSI build requires WiX Toolset v4 (`wix` CLI). If WiX is missing, EXE still builds and MSI is skipped.

## Build MSI installer (WiX v4)

If you need an installer package for enterprise distribution, install WiX Toolset v4 and run:

```powershell
# From repository root (Windows host)
bash MacKeyValue/build.sh --win-msi --win-only
```

Or via release pipeline:

```powershell
bash scripts/release.sh 1.2.3 --build-windows --windows-package msi --skip-build
```

Artifacts are generated under `windows/dist/` with versioned names:

- `KeyValueWin-<VERSION>-win-x64.exe`
- `KeyValueWin-<VERSION>-win-x64.msi`

## Data location

Entries are stored in:

```text
%LOCALAPPDATA%\MacKeyValue\entries.json
```

The DPAPI-protected master key is at:

```text
%LOCALAPPDATA%\MacKeyValue\master.key
```

> **Note:** The master key is tied to the Windows user account. Entries encrypted on one user/machine cannot be decrypted on another — use the **Export Encrypted (.mkve)** option and a password to transfer data between machines.

## Cross-platform import / export

- `.mkve` encrypted: Mac → Win ✅, Win → Mac ✅
- Native JSON: Mac → Win ✅, Win → Mac ✅
- CSV: Mac → Win ✅ (import), Win → Mac ✅ (import)

Use **File → Export Encrypted (.mkve)** on either platform, then **Import** on the other.

## Project structure

```text
windows/
├── KeyValueWin.sln
└── KeyValueWin/
    ├── App.xaml / App.xaml.cs        — Application entry, global styles
    ├── MainWindow.xaml / .cs         — Two-pane main window
    ├── Assets/
    │   └── app.ico                   — Application icon
    ├── Models/
    │   └── KeyValueEntry.cs          — Data model (matches Swift model)
    ├── Services/
    │   ├── EncryptionService.cs      — AES-256-GCM, DPAPI master key
    │   ├── StorageService.cs         — JSON persistence
    │   └── ImportExportService.cs    — Multi-format import / export
    ├── ViewModels/
    │   └── MainViewModel.cs          — CommunityToolkit.Mvvm ViewModel
    ├── Views/
    │   ├── EntryEditWindow.xaml/.cs  — Add / edit entry dialog
    │   └── PasswordDialog.xaml/.cs   — Password prompt dialog
    └── Converters/
        └── Converters.cs             — WPF value converters
```
