@echo off
setlocal EnableExtensions
if /i "%~1"=="arm64" goto archok
if /i "%~1"=="arm64ec" goto archok
echo Unsupported architecture
exit /b 2
:archok
set "ASTRA_BUILD_ARCH=%~1"
call "C:\AstraLab\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=arm64 -host_arch=arm64 -startdir=none -no_logo
if errorlevel 1 exit /b 1
set "INCLUDE=C:\AstraLab\DriverBuild\wdk-headers\c\Include\10.0.26100.0\um;C:\AstraLab\DriverBuild\wdk-headers\c\Include\10.0.26100.0\shared;%INCLUDE%"
set "PATH=C:\AstraLab\Python;C:\AstraLab\Python\Scripts;C:\AstraLab\DriverBuild\cross;%PATH%"
set "PYTHONNOUSERSITE=1"
cd /d C:\AstraLab\DriverBuild
if errorlevel 1 exit /b 1
if /i "%ASTRA_BUILD_ARCH%"=="arm64ec" (
  cl /nologo /O2 /MT /DSHIM_LIB /Fe:cross\arm64ec-lib.exe /Fo:cross\arm64ec-lib.obj cross\arm64ec-machine-shim.c
  if errorlevel 1 exit /b 1
  cl /nologo /O2 /MT /DSHIM_LINK /Fe:cross\arm64ec-link.exe /Fo:cross\arm64ec-link.obj cross\arm64ec-machine-shim.c
  if errorlevel 1 exit /b 1
)
if /i "%ASTRA_BUILD_ARCH%"=="arm64ec" set "LIB=%VCToolsInstallDir%lib\arm64ec;%WindowsSdkDir%Lib\%WindowsSDKVersion%um\arm64ec;%WindowsSdkDir%Lib\%WindowsSDKVersion%ucrt\arm64ec;%LIB%"
C:\AstraLab\Python\python.exe -m mesonbuild.mesonmain setup build-%ASTRA_BUILD_ARCH% mesa-src ^
  --cross-file cross\meson-%ASTRA_BUILD_ARCH%.txt --wrap-mode=nodownload ^
  --prefix C:\AstraLab\DriverBuild\install-%ASTRA_BUILD_ARCH% ^
  --default-library=static -Dbuildtype=release -Db_ndebug=true -Db_vscrt=mt ^
  -Dllvm=disabled -Dplatforms=windows -Dvideo-codecs= ^
  -Dgallium-drivers= -Dvulkan-drivers= -Degl=disabled -Dgles1=disabled ^
  -Dgles2=disabled -Dopengl=false -Dglx=disabled -Dshared-glapi=disabled ^
  -Dneptune=true -Dnpt_wine=false -Dnpt_umd=ddi -Dbuild-tests=false
if errorlevel 1 exit /b 1
C:\AstraLab\Python\python.exe -m mesonbuild.mesonmain compile -C build-%ASTRA_BUILD_ARCH% -j 4 neptune_umd
exit /b %errorlevel%
