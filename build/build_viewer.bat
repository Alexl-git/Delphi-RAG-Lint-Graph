@echo off
REM Build drag-lint-graph.exe Win64 -> bin\Win64\.
REM (Win64: the viewer is a separate process, not bound to the 32-bit IDE, so it
REM gets the memory headroom for large projects / indexes.)
setlocal
set RSVARS="C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
call %RSVARS%
if errorlevel 1 exit /b 1

set HERE=%~dp0
set ROOT=%HERE%..

cd /D "%ROOT%\src\viewer"
msbuild /t:Build /p:Config=Debug /p:Platform=Win64 /v:minimal drag_lint_graph.dproj
if errorlevel 1 exit /b 1

echo OK: built bin\Win64\drag_lint_graph.exe
endlocal
