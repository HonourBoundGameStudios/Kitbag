# Copy the addon into a WoW AddOns folder so it can be tested in the client.
#
# Copies rather than symlinks on purpose: a symlinked addon folder confuses some launchers' addon
# scanners, and the copy is fast enough that "edit, deploy, /reload" is still a tight loop.
#
#   .\deploy.ps1                                  # the installed client, read from the registry
#   .\deploy.ps1 -WowPath "D:\World of Warcraft\_classic_era_"    # or another flavour
#
# Tests are NOT part of the shipped addon and are excluded — Tests/ is the offline harness.
param(
    [string]$WowPath
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# Where WoW actually is, asked of the installer rather than guessed. The default used to be
# "C:\Program Files (x86)\..." which is not where this machine's client lives, so every single
# deploy needed -WowPath — a default that is always wrong is worse than no default.
#
# The installer records the flavour folder itself (…\_classic_era_\), which is exactly what this
# script wants. Deploying to a DIFFERENT flavour still needs -WowPath: the registry only remembers
# one, and silently guessing which flavour you meant would be the same mistake again.
function Get-WowPathFromRegistry {
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
        'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft'
    )
    foreach ($key in $keys) {
        if (-not (Test-Path $key)) { continue }
        $path = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallPath
        if ($path) { return $path.TrimEnd('\') }
    }
    return $null
}

if (-not $WowPath) {
    $WowPath = Get-WowPathFromRegistry
    if ($WowPath) {
        Write-Host "Using the installed client at $WowPath" -ForegroundColor DarkGray
    } else {
        $WowPath = "C:\Program Files (x86)\World of Warcraft\_classic_era_"
    }
}

$dest = Join-Path $WowPath "Interface\AddOns\Kitbag"

if (-not (Test-Path $WowPath)) {
    Write-Error "No WoW install at '$WowPath'. Pass -WowPath with the flavour folder (e.g. _classic_era_)."
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Clear only the files we own, so a stale module from a rename can't linger and get loaded.
Get-ChildItem $dest -Filter *.lua -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $dest -Filter *.toc -ErrorAction SilentlyContinue | Remove-Item -Force

Copy-Item (Join-Path $root "*.lua") $dest
Copy-Item (Join-Path $root "*.toc") $dest

$count = (Get-ChildItem $dest -File).Count
Write-Host "Deployed $count file(s) to $dest" -ForegroundColor Green
Write-Host "In-game: /reload  then  /kit" -ForegroundColor Cyan
