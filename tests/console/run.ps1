# Compile and run the drag-lint-graph console test suite.
# Exit 0 = all green; 2 = compile failure; N = N failed tests.
$ErrorActionPreference = 'Stop'
$IDE  = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $repo
try {
    New-Item -ItemType Directory -Force 'bin\Win32\dcu' | Out-Null
    $dpr   = 'tests\console\drag_lint_graph_tests.dpr'
    $build = "call `"$IDE\bin\rsvars.bat`" && dcc32 -B -NSSystem " +
             "-U`"src\control`";`"tests\console`" " +
             "-E`"bin\Win32`" -N0`"bin\Win32\dcu`" `"$dpr`""
    cmd.exe /c $build
    if ($LASTEXITCODE -ne 0) { Write-Host 'COMPILE FAILED' -ForegroundColor Red; exit 2 }
    & 'bin\Win32\drag_lint_graph_tests.exe'
    $code = $LASTEXITCODE
    if ($code -eq 0) { Write-Host 'GREEN' -ForegroundColor Green }
    else { Write-Host ("RED ({0} failed)" -f $code) -ForegroundColor Red }
    exit $code
} finally { Pop-Location }
