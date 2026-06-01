# drag-lint-graph viewer smoke autotest
#
# Builds the viewer EXE (msbuild), then launches it:
#   - with --db C:\Projects\DB\ORM3\drag-lint.sqlite  (if the file exists)
#   - with no args otherwise (shows the no-db message)
# Asserts the process stays alive ~3s without exiting (crash = FAIL).
# Asserts the process has a visible top-level window within ~5s (F5 guard).
# Kills the process after the check.
#
# Exit 0 = PASS, non-zero = FAIL.

[CmdletBinding()]
param(
    [string] $Exe = "$PSScriptRoot\..\..\bin\Win32\drag_lint_graph.exe",
    [string] $OrmDb = "C:\Projects\DB\ORM3\drag-lint.sqlite"
)

$ErrorActionPreference = 'Stop'
$script:Failed = $false
$script:Results = @()

function Write-Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '', [double] $Ms = 0)
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color  = if ($Ok) { 'Green' } else { 'Red' }
    $msStr  = if ($Ms -gt 0) { "{0,6:N0}ms" -f $Ms } else { '         ' }
    Write-Host ("  [{0}] {1} {2,-52} {3}" -f $status, $msStr, $Name, $Detail) -ForegroundColor $color
    $script:Results += [PSCustomObject]@{
        Name = $Name; Ok = $Ok; Detail = $Detail; Ms = $Ms
    }
    if (-not $Ok) { $script:Failed = $true }
}

Write-Host "drag-lint-graph viewer smoke" -ForegroundColor Cyan

# --- Step 1: build viewer EXE ---
Write-Host "`n== Build ==" -ForegroundColor Cyan
$dproj = "$PSScriptRoot\..\..\src\viewer\drag_lint_graph.dproj"
$rsvars = "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"

$t0 = [Diagnostics.Stopwatch]::StartNew()
$buildOutput = & cmd.exe /c "call `"$rsvars`" && msbuild /t:Build /p:Config=Debug /p:Platform=Win32 /v:minimal `"$dproj`"" 2>&1
$buildOk = ($LASTEXITCODE -eq 0)
$t0.Stop()
Write-Check "viewer EXE builds" $buildOk "exit=$LASTEXITCODE" $t0.Elapsed.TotalMilliseconds
if (-not $buildOk) {
    Write-Host "Build output:" -ForegroundColor Yellow
    $buildOutput | ForEach-Object { Write-Host "  $_" }
    exit 1
}

# --- Step 2: verify EXE exists ---
if (-not (Test-Path $Exe)) {
    Write-Check "viewer EXE exists on disk" $false "not found: $Exe"
    exit 1
}
Write-Check "viewer EXE exists on disk" $true $Exe

# --- Step 3: launch smoke ---
Write-Host "`n== Launch smoke ==" -ForegroundColor Cyan

if (Test-Path $OrmDb) {
    $launchArgs = @('--db', $OrmDb)
    $launchDesc = "launch with ORM3 DB"
} else {
    $launchArgs = @()
    $launchDesc = "launch with no args (no-db message)"
}

$t1 = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $Exe -ArgumentList $launchArgs -PassThru
Start-Sleep -Seconds 3
$alive = -not $proc.HasExited
if (-not $alive) {
    # process already exited -- kill attempt is a no-op but record the check
}
$t1.Stop()
$exitStr = if ($proc.HasExited) { "exit=$($proc.ExitCode)" } else { "alive" }
Write-Check $launchDesc $alive $exitStr $t1.Elapsed.TotalMilliseconds

# --- Step 4: window visible check (F5 guard) ---
Write-Host "`n== Window visible (F5 guard) ==" -ForegroundColor Cyan

$tWin = [Diagnostics.Stopwatch]::StartNew()
$visible = $false
$winMs = 0.0
if ($alive) {
    # Poll up to 5s for MainWindowHandle to become non-zero
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.Elapsed.TotalSeconds -lt 5) {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne 0) {
            $visible = $true
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $winMs = $deadline.Elapsed.TotalMilliseconds
} else {
    # Process crashed -- window can never appear
    $visible = $false
    $winMs = 0.0
}
$tWin.Stop()

$winDetail = if ($visible) {
    "MainWindowHandle non-zero after {0:N0}ms" -f $winMs
} else {
    "MainWindowHandle still 0 after 5s (F5 reproducing)"
}
Write-Check "window visible after load" $visible $winDetail $tWin.Elapsed.TotalMilliseconds

# --- Kill process after checks ---
if ($alive -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

# --- Summary ---
Write-Host ''
$passes = ($script:Results | Where-Object Ok).Count
$fails  = ($script:Results | Where-Object { -not $_.Ok }).Count
$summary = "{0} pass / {1} fail / {2} total" -f $passes, $fails, $script:Results.Count
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host $summary -ForegroundColor $color

if ($script:Failed) { exit 1 } else { exit 0 }
