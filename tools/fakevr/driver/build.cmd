@echo off
rem Builds driver_qdfake.dll (x64, static CRT). SteamVR must be closed (the DLL is locked while vrserver runs).
setlocal
set "HERE=%~dp0"
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
if not defined VCVARS for /f "delims=" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find "VC\Auxiliary\Build\vcvars64.bat"') do set "VCVARS=%%i"
call "%VCVARS%" >nul || (echo vcvars64.bat failed: %VCVARS% & exit /b 1)
if not exist "%HERE%obj" mkdir "%HERE%obj"
if not exist "%HERE%qdfake\bin\win64" mkdir "%HERE%qdfake\bin\win64"
pushd "%HERE%obj"
cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /permissive- /DNOMINMAX /D_CRT_SECURE_NO_WARNINGS ^
   /external:W0 /external:I"%HERE%..\third_party\openvr\headers" ^
   "%HERE%src\provider.cpp" "%HERE%src\devices.cpp" ^
   /LD /link /OUT:"%HERE%qdfake\bin\win64\driver_qdfake.dll" /IMPLIB:"%HERE%obj\driver_qdfake.lib" ws2_32.lib
set ERR=%ERRORLEVEL%
popd
if %ERR% neq 0 (echo BUILD FAILED & exit /b %ERR%)
echo built %HERE%qdfake\bin\win64\driver_qdfake.dll
