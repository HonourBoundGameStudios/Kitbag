# Push the addon to the PUBLIC repository (SHIP-2).
#
# This repository is the workshop and is not the thing that gets published. It holds working notes
# (Process/, Research/, Design/) and agent instructions (CLAUDE.md) that are deliberately not part of
# the public project. The public repository gets the addon, its tests and its CI — nothing else.
#
#   .\publish.ps1                 # sync, commit and push
#   .\publish.ps1 -DryRun         # show what would be published and stop
#
# Two deliberate design choices, both about not leaking by accident:
#
#   * THE PUBLIC REPO IS NOT A REMOTE OF THIS ONE. Its history is separate and this script syncs
#     files into a working checkout under .publish\. If it were a remote, one absent-minded
#     `git push --all` would publish every working note in every commit, permanently. It cannot,
#     because there is nothing here to push to.
#   * PUBLISH IS A WHITELIST, never a list of exclusions. A new working document added to this repo
#     is private by default; only a file matching something below can ever reach the public tree.
#     An exclusion list gets it backwards — anything new is public until someone remembers.
param(
    [string]$Repo = "https://github.com/HonourBoundGameStudios/Kitbag.git",
    [string]$Message,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$work = Join-Path $root ".publish"

# THE WHITELIST. Everything the public repository may contain, and nothing else.
$filePatterns = @("*.lua", "*.toc", "README.md", "LICENSE", ".gitignore", "deploy.ps1", "package.ps1")
$directories  = @("Tests", ".github")

& pwsh -File (Join-Path $root "Tests\run-all.ps1")
if ($LASTEXITCODE -ne 0) { Write-Error "Tests are red. Not publishing." }

if (-not (Test-Path $work)) {
    Write-Host "Cloning $Repo into .publish ..." -ForegroundColor Cyan
    git clone $Repo $work
    if ($LASTEXITCODE -ne 0) { Write-Error "Could not clone '$Repo'. Does it exist yet?" }
} else {
    git -C $work fetch origin --quiet
    # Hard reset rather than pull: the working checkout is disposable and a merge conflict in it
    # would be a puzzle about a tree nobody edits by hand.
    $branch = (git -C $work symbolic-ref --short HEAD).Trim()
    git -C $work reset --hard "origin/$branch" --quiet 2>$null
}

# Clear the tree (except .git) and re-copy, so a file DELETED here is deleted there too. Syncing
# additively would leave a removed module in the public repo, where the .toc would still load it.
Get-ChildItem $work -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force

foreach ($pattern in $filePatterns) {
    Get-ChildItem $root -Filter $pattern -File -Force -ErrorAction SilentlyContinue |
        Copy-Item -Destination $work
}
foreach ($dir in $directories) {
    $source = Join-Path $root $dir
    if (Test-Path $source) { Copy-Item $source $work -Recurse -Force }
}

# Belt and braces. The whitelist above should make this impossible; if it ever fires, the whitelist
# is wrong and publishing must stop rather than proceed and be discovered later.
$forbidden = @("CLAUDE.md", "Process", "Research", "Design", ".claude")
foreach ($name in $forbidden) {
    if (Test-Path (Join-Path $work $name)) {
        Write-Error "'$name' reached the publish tree. The whitelist in publish.ps1 is wrong; nothing pushed."
    }
}

Write-Host ""
Write-Host "Public tree:" -ForegroundColor Cyan
Get-ChildItem $work -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    ForEach-Object { "  " + $_.FullName.Substring($work.Length + 1) } |
    Sort-Object

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run — nothing committed or pushed." -ForegroundColor Yellow
    return
}

git -C $work add -A
if (-not (git -C $work status --porcelain)) {
    Write-Host ""
    Write-Host "Public repository is already up to date." -ForegroundColor Green
    return
}

if (-not $Message) {
    $version = (Select-String -Path (Join-Path $root "Kitbag.toc") -Pattern '^##\s*Version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
    $Message = "Kitbag $version"
}

git -C $work commit -m $Message
git -C $work push origin HEAD

Write-Host ""
Write-Host "Published to $Repo" -ForegroundColor Green
