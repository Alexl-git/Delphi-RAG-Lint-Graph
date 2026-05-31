# drag-lint-graph smoke autotest
#
# Mirrors the pattern of the main drag-lint repo's autotest:
# - Build viewer EXE
# - Sanity-launch with each fixture and check it stays alive ~2s without crashing
# - Validate the JSON loader parses the fixture without error (via a tiny
#   probe TForm that reports OK and exits — phase 1 work)
#
# Exit 0 on pass, non-zero on first failure.

[CmdletBinding()]
param(
    [string] $Exe        = "$PSScriptRoot\..\..\bin\Win32\drag_lint_graph.exe",
    [string] $FixtureDir = "$PSScriptRoot\..\fixtures"
)

$ErrorActionPreference = 'Stop'
$script:Failed = $false
$script:Results = @()

function Write-Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '', [double] $Ms = 0)
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color  = if ($Ok) { 'Green' } else { 'Red' }
    $msStr  = if ($Ms -gt 0) { "{0,6:N0}ms" -f $Ms } else { '         ' }
    Write-Host ("  [{0}] {1} {2,-50} {3}" -f $status, $msStr, $Name, $Detail) -ForegroundColor $color
    $script:Results += [PSCustomObject]@{
        Name = $Name; Ok = $Ok; Detail = $Detail; Ms = $Ms
    }
    if (-not $Ok) { $script:Failed = $true }
}

Write-Host "drag-lint-graph autotest harness" -ForegroundColor Cyan
Write-Host "  exe:      $Exe"
Write-Host "  fixtures: $FixtureDir"

if (-not (Test-Path $Exe)) {
    Write-Host "FATAL: viewer EXE not found. Build with build\build_viewer.bat first." -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $FixtureDir)) {
    Write-Host "FATAL: fixture dir not found: $FixtureDir" -ForegroundColor Red
    exit 2
}

Write-Host "`n== Viewer launch smoke ==" -ForegroundColor Cyan

foreach ($fixture in Get-ChildItem $FixtureDir -Filter '*.json') {
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $Exe -ArgumentList '--data',$fixture.FullName -PassThru
    Start-Sleep -Seconds 2
    $alive = -not $proc.HasExited
    if ($alive) {
        Stop-Process -Id $proc.Id -Force
    }
    $t0.Stop()
    Write-Check "$($fixture.Name) loads without crash" $alive "exit=$($proc.ExitCode)" $t0.Elapsed.TotalMilliseconds
}

Write-Host ''
$passes = ($script:Results | Where-Object Ok).Count
$fails  = ($script:Results | Where-Object { -not $_.Ok }).Count
$summary = "{0} pass / {1} fail / {2} total" -f $passes, $fails, $script:Results.Count
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host $summary -ForegroundColor $color

if ($script:Failed) { exit 1 } else { exit 0 }
