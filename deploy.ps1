# Copy the addon into a WoW AddOns folder so it can be tested in the client.
#
# Copies rather than symlinks on purpose: a symlinked addon folder confuses some launchers' addon
# scanners, and the copy is fast enough that "edit, deploy, /reload" is still a tight loop.
#
#   .\deploy.ps1                                  # default Classic Era path below
#   .\deploy.ps1 -WowPath "D:\World of Warcraft\_classic_era_"
#
# Tests are NOT part of the shipped addon and are excluded — Tests/ is the offline harness.
param(
    [string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_classic_era_"
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
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
