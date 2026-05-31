@echo off
REM Build drag-lint-graph.exe Win32 -> bin\Win32\.
setlocal
set RSVARS="C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
call %RSVARS%
if errorlevel 1 exit /b 1

set HERE=%~dp0
set ROOT=%HERE%..

cd /D "%ROOT%\src\viewer"
msbuild /t:Build /p:Config=Debug /p:Platform=Win32 /v:minimal drag_lint_graph.dproj
if errorlevel 1 exit /b 1

echo OK: built bin\Win32\drag_lint_graph.exe
endlocal
