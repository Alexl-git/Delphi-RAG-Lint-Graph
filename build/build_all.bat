@echo off
REM build_all.bat  -- build all packages + viewer, then run both test gates.
REM Order: DragLintGraph (runtime) -> DragLintGraphDb (DB) -> DragLintGraphDcl (design-time) -> viewer EXE -> console suite -> smoke.
setlocal

set RSVARS="C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
echo Calling rsvars...
call %RSVARS%
if errorlevel 1 ( echo ERROR: rsvars failed & exit /b 1 )

set HERE=%~dp0
set ROOT=%HERE%..

REM Ensure bin\Win32 exists for .bpl / .dcp output
if not exist "%ROOT%\bin\Win32" mkdir "%ROOT%\bin\Win32"

REM --------------------------------------------------------------------------
REM 1. DragLintGraph (runtime core - VCL, no FireDAC)
echo.
echo === Building DragLintGraph.bpl ===
msbuild /t:Build /p:Config=Debug /p:Platform=Win32 /v:minimal "%ROOT%\src\pkg\DragLintGraph.dproj"
if errorlevel 1 ( echo ERROR: DragLintGraph.bpl build FAILED & exit /b 1 )
echo OK: DragLintGraph.bpl

REM --------------------------------------------------------------------------
REM 2. DragLintGraphDb (runtime DB - requires FireDAC + DragLintGraph.dcp)
echo.
echo === Building DragLintGraphDb.bpl ===
msbuild /t:Build /p:Config=Debug /p:Platform=Win32 /v:minimal "%ROOT%\src\pkg\DragLintGraphDb.dproj"
if errorlevel 1 ( echo ERROR: DragLintGraphDb.bpl build FAILED & exit /b 1 )
echo OK: DragLintGraphDb.bpl

REM --------------------------------------------------------------------------
REM 3. DragLintGraphDcl (design-time - requires designide + DragLintGraph.dcp)
echo.
echo === Building DragLintGraphDcl.bpl ===
msbuild /t:Build /p:Config=Debug /p:Platform=Win32 /v:minimal "%ROOT%\src\dclpkg\DragLintGraphDcl.dproj"
if errorlevel 1 ( echo ERROR: DragLintGraphDcl.bpl build FAILED & exit /b 1 )
echo OK: DragLintGraphDcl.bpl

REM --------------------------------------------------------------------------
REM 4. Viewer EXE (links units directly, demo host). Win64: separate process,
REM    not bound to the 32-bit IDE -> memory headroom for large indexes.
echo.
echo === Building drag_lint_graph.exe (Win64) ===
msbuild /t:Build /p:Config=Debug /p:Platform=Win64 /v:minimal "%ROOT%\src\viewer\drag_lint_graph.dproj"
if errorlevel 1 ( echo ERROR: drag_lint_graph.exe build FAILED & exit /b 1 )
echo OK: drag_lint_graph.exe

REM --------------------------------------------------------------------------
REM 5. Console test suite (32 unit tests)
echo.
echo === Running console test suite ===
pwsh -NonInteractive -File "%ROOT%\tests\console\run.ps1"
if errorlevel 1 ( echo ERROR: Console test suite FAILED & exit /b 1 )
echo OK: Console suite green

REM --------------------------------------------------------------------------
REM 6. Smoke test
echo.
echo === Running smoke test ===
pwsh -NonInteractive -File "%ROOT%\tests\autotest\run_smoke.ps1"
if errorlevel 1 ( echo ERROR: Smoke test FAILED & exit /b 1 )
echo OK: Smoke green

echo.
echo =============================================
echo ALL STEPS PASSED
echo =============================================
endlocal
