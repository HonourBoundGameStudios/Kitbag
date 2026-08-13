# Run every pure-logic test in Tests/. Exits non-zero if any test file fails, so this is the gate.
# Tests load `Tests/harness.lua` and each module by a root-relative path, so they must run from the
# project root.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $lua = (Get-Command lua -ErrorAction SilentlyContinue).Source
    if (-not $lua) { $lua = "G:\tools\lua-5.1.5\bin\lua.exe" }
    if (-not (Test-Path $lua)) {
        Write-Error "No Lua interpreter found. Expected 'lua' on PATH or G:\tools\lua-5.1.5\bin\lua.exe."
    }

    $files = Get-ChildItem "$root\Tests\*_test.lua" | Sort-Object Name
    if (-not $files) { Write-Warning "No *_test.lua files in Tests/."; exit 0 }

    $failed = @()
    foreach ($f in $files) {
        & $lua "Tests\$($f.Name)"
        if ($LASTEXITCODE -ne 0) { $failed += $f.Name }
    }

    Write-Host ""
    if ($failed.Count -gt 0) {
        Write-Host "FAILED ($($failed.Count)/$($files.Count)): $($failed -join ', ')" -ForegroundColor Red
        exit 1
    }
    Write-Host "All $($files.Count) test file(s) passed." -ForegroundColor Green
}
finally { Pop-Location }
