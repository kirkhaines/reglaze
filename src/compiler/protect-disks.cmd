@echo off
setlocal enabledelayedexpansion

echo ================================================================
echo   REGLAZE WINPE DISK PROTECTION & ISOLATION ENGINE
echo ================================================================

rem 1. Determine installation media drive letter
set "MEDIA_DRIVE=%~1"
if not "%MEDIA_DRIVE%"=="" (
    rem Strip trailing backslash or colon if present
    set "MEDIA_DRIVE=%MEDIA_DRIVE:~0,1%:"
)

if "%MEDIA_DRIVE%"=="" (
    for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\Reglaze\DiskMatch.vbs" (
            set "MEDIA_DRIVE=%%d:"
        )
    )
)

if "%MEDIA_DRIVE%"=="" (
    if exist "%~d0\Reglaze\DiskMatch.vbs" (
        set "MEDIA_DRIVE=%~d0"
    )
)

if "%MEDIA_DRIVE%"=="" (
    echo [!] WARNING: Could not automatically detect Reglaze installation media drive letter.
    echo     Proceeding with fallback search...
) else (
    echo [i] Reglaze installation media located on: %MEDIA_DRIVE%
)

set "VBS_SCRIPT=%MEDIA_DRIVE%\Reglaze\DiskMatch.vbs"
set "CONFIG_FILE=%MEDIA_DRIVE%\payload\disk-config.json"
set "OFFLINE_SCRIPT=X:\offline-disks.txt"

if not exist "%VBS_SCRIPT%" (
    if exist "%MEDIA_DRIVE%\DiskMatch.vbs" (
        set "VBS_SCRIPT=%MEDIA_DRIVE%\DiskMatch.vbs"
    )
)

if not exist "%VBS_SCRIPT%" (
    echo [!] ERROR: DiskMatch.vbs could not be found on %MEDIA_DRIVE%\Reglaze or %MEDIA_DRIVE%\.
    echo     Secondary disks will not be isolated automatically.
    exit /b 0
)

rem 2. Execute DiskMatch.vbs to identify disks and construct diskpart script
echo [i] Running DiskMatch.vbs via cscript.exe...
cscript.exe //nologo "%VBS_SCRIPT%" /configFile:"%CONFIG_FILE%" /mediaLetter:"%MEDIA_DRIVE%" /outputPath:"%OFFLINE_SCRIPT%"
set "VBS_EXIT=%ERRORLEVEL%"

if not "%VBS_EXIT%"=="0" (
    echo [!] WARNING: DiskMatch.vbs exited with code %VBS_EXIT%.
)

rem 3. Execute diskpart if isolation script was produced
if exist "%OFFLINE_SCRIPT%" (
    echo.
    echo [i] Applying secondary disk isolation via diskpart.exe...
    diskpart.exe /s "%OFFLINE_SCRIPT%"
    echo [OK] Secondary and preserved disks are now offline and read-only.
) else (
    echo [i] No disks required isolation.
)

echo ================================================================
echo   WinPE Disk Protection Complete. Starting Windows Setup UI...
echo ================================================================
exit /b 0

