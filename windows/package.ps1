param(
    [Parameter(Position=0)]
    [ValidateSet("exe", "msi", "both")]
    [string]$Package = "both",

    [string]$Version = "",

    [string]$Configuration = "Release",

    [switch]$SelfContained
)

$ErrorActionPreference = "Stop"

function Write-Step($message) {
    Write-Host "`n==> $message" -ForegroundColor Cyan
}

function Get-Version {
    param([string]$InputVersion)

    if ($InputVersion -and $InputVersion.Trim().Length -gt 0) {
        return $InputVersion.Trim()
    }

    try {
        $tag = (git describe --tags --abbrev=0 2>$null)
        if ($LASTEXITCODE -eq 0 -and $tag) {
            return $tag.TrimStart('v')
        }
    } catch {
    }

    return "1.0.0"
}

function Get-MsiVersion {
    param([string]$Semver)

    $base = $Semver.Split('-')[0]
    $parts = $base.Split('.')
    $major = if ($parts.Length -gt 0 -and $parts[0]) { $parts[0] } else { "1" }
    $minor = if ($parts.Length -gt 1 -and $parts[1]) { $parts[1] } else { "0" }
    $patch = if ($parts.Length -gt 2 -and $parts[2]) { $parts[2] } else { "0" }
    return "$major.$minor.$patch.0"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
$project = Join-Path $scriptDir "KeyValueWin/KeyValueWin.csproj"
$distDir = Join-Path $scriptDir "dist"
$publishDir = Join-Path $distDir "publish-win-x64"

$versionResolved = Get-Version -InputVersion $Version
$msiVersion = Get-MsiVersion -Semver $versionResolved

$exeTarget = Join-Path $distDir "KeyValueWin-$versionResolved-win-x64.exe"
$msiTarget = Join-Path $distDir "KeyValueWin-$versionResolved-win-x64.msi"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found. Please install .NET SDK first."
}

if (-not (Test-Path $project)) {
    throw "Project file not found: $project"
}

Write-Step "Preparing output folders"
if (Test-Path $publishDir) {
    Remove-Item -Recurse -Force $publishDir
}
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir | Out-Null
}

$publishArgs = @(
    "publish", $project,
    "-c", $Configuration,
    "-r", "win-x64",
    "-p:PublishSingleFile=true",
    "-p:IncludeNativeLibrariesForSelfExtract=true",
    "-o", $publishDir
)

if ($SelfContained.IsPresent) {
    $publishArgs += @("--self-contained", "true")
} else {
    $publishArgs += @("--self-contained", "false")
}

Write-Step "Building EXE (dotnet publish)"
& dotnet @publishArgs
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed"
}

$builtExe = Join-Path $publishDir "KeyValueWin.exe"
if (-not (Test-Path $builtExe)) {
    throw "EXE not found in publish output: $builtExe"
}
Copy-Item $builtExe $exeTarget -Force
Write-Host "EXE: $exeTarget" -ForegroundColor Green

if ($Package -eq "exe") {
    Write-Host "Done. EXE package completed." -ForegroundColor Green
    exit 0
}

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    Write-Warning "WiX CLI (wix) not found. MSI package skipped."
    Write-Warning "Install WiX Toolset v4 and rerun: .\windows\package.ps1 msi"
    if ($Package -eq "msi") {
        exit 1
    }
    Write-Host "Done. EXE package completed." -ForegroundColor Yellow
    exit 0
}

$wxsPath = Join-Path $env:TEMP ("keyvalue-installer-{0}.wxs" -f [Guid]::NewGuid().ToString("N"))

@"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package
      Name="KeyValue"
      Manufacturer="aresnasa"
      Version="$msiVersion"
      UpgradeCode="A6A3AE31-F1D9-4D0D-8B92-8DCE89977821"
      Language="1033"
      InstallerVersion="500"
      Scope="perMachine">
    <MediaTemplate EmbedCab="yes" />

    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="KeyValue">
        <Component Id="cmpKeyValueExe" Guid="*">
          <File Id="filKeyValueExe" Source="$builtExe" KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>

    <Feature Id="MainFeature" Title="KeyValue" Level="1">
      <ComponentRef Id="cmpKeyValueExe" />
    </Feature>
  </Package>
</Wix>
"@ | Set-Content -Encoding UTF8 $wxsPath

Write-Step "Building MSI (WiX v4)"
& wix build $wxsPath -arch x64 -o $msiTarget
if ($LASTEXITCODE -ne 0) {
    Remove-Item $wxsPath -Force -ErrorAction SilentlyContinue
    throw "wix build failed"
}
Remove-Item $wxsPath -Force -ErrorAction SilentlyContinue

Write-Host "MSI: $msiTarget" -ForegroundColor Green
Write-Host "Done. $Package package completed." -ForegroundColor Green
