# Build the release zip (SHIP-1).
#
# CurseForge (and WowUp, and the client itself) take ONE zip containing ONE addon folder holding
# every flavour's .toc. The flavour is chosen by the suffix on the file name — Kitbag.toc for
# Classic Era plus Kitbag_Mists / Kitbag_Cata / Kitbag_Mainline — which is why the names have to be
# Blizzard's vocabulary and not ours.
#
# It does NOT ship every .toc in the repo. A .toc in the zip is a promise that the addon runs on that
# flavour, and two of the four have never had a frame drawn on them. See $SHIPPED_TOCS below.
#
#   .\package.ps1                 # -> dist\Kitbag-0.1.0.zip
#   .\package.ps1 -OutDir build
#
# The gate runs first. Publishing an addon whose tests are red is the one mistake that reaches
# players, so it is not a flag you can pass.
param(
    [string]$OutDir = "dist",
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $SkipTests) {
    & pwsh -File (Join-Path $root "Tests\run-all.ps1")
    if ($LASTEXITCODE -ne 0) { Write-Error "Tests are red. Not packaging." }
}

# The version is read from the .toc rather than kept in a second place. Two version numbers that can
# disagree will disagree, and the one players see is the one in the .toc.
$tocPath = Join-Path $root "Kitbag.toc"
$version = (Select-String -Path $tocPath -Pattern '^##\s*Version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
if (-not $version) { Write-Error "No '## Version:' line in Kitbag.toc." }

# Every .toc must agree on it too: CurseForge reads one of them and the players on the others would
# be told they are running a version they are not.
foreach ($toc in Get-ChildItem $root -Filter "Kitbag*.toc") {
    $found = (Select-String -Path $toc.FullName -Pattern '^##\s*Version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
    if ($found -ne $version) {
        Write-Error "$($toc.Name) says version '$found' but Kitbag.toc says '$version'."
    }
}

$out = Join-Path $root $OutDir
$staging = Join-Path $out "Kitbag"
$zip = Join-Path $out "Kitbag-$version.zip"

# Rebuilt from nothing each time: a stale module left in the staging folder from a rename would be
# shipped, and it would load.
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

# The flavours this release ships. A flavour joins this list when there is evidence the addon has RUN
# on it — not when its .toc exists. Retail has never been launched (its interface number is read off
# .build.info, but the C_Item/C_Spell shims are reasoned rather than observed) and Cataclysm Classic
# no longer exists as a client at all, so both stay in the repo, under every parity check in
# Tests/toc_test.lua, and out of the zip. That test reads this list rather than restating it, and
# also holds the README's "Supports …" line to the same set.
$SHIPPED_TOCS = @(
    "Kitbag.toc"        # Classic Era
    "Kitbag_Mists.toc"  # Mists Classic
)

# Only what the client loads. The test suite, the working notes and the scripts are the workshop,
# not the product; nobody installing an addon wants them in their AddOns folder.
Copy-Item (Join-Path $root "*.lua") $staging
foreach ($toc in $SHIPPED_TOCS) {
    $path = Join-Path $root $toc
    if (-not (Test-Path $path)) { Write-Error "$toc is shipped but does not exist." }
    Copy-Item $path $staging
}
foreach ($doc in @("README.md", "LICENSE")) {
    $path = Join-Path $root $doc
    if (Test-Path $path) { Copy-Item $path $staging }
}

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal

$files = (Get-ChildItem $staging -File).Count
$size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host ""
Write-Host "Packaged Kitbag $version — $files file(s), $size KB" -ForegroundColor Green
Write-Host "  $zip" -ForegroundColor Cyan
Write-Host "Flavours in this zip:" -ForegroundColor Cyan
foreach ($toc in Get-ChildItem $staging -Filter "Kitbag*.toc" | Sort-Object Name) {
    $interface = (Select-String -Path $toc.FullName -Pattern '^##\s*Interface:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
    Write-Host ("  {0,-24} Interface {1}" -f $toc.Name, $interface)
}
