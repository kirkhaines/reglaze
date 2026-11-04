@echo off
setlocal enabledelayedexpansion

echo ================================================================
echo   REGLAZE WINPE TARGET DISK PREPARATION & PARTITIONING ENGINE
echo ================================================================

rem 1. Determine installation media drive letter
set "MEDIA_DRIVE=%~1"
if not "%MEDIA_DRIVE%"=="" (
    rem Strip trailing backslash or colon if present
    set "MEDIA_DRIVE=%MEDIA_DRIVE:~0,1%:"
)

if "%MEDIA_DRIVE%"=="" (
    for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\Reglaze\prepare-target-disk.vbs" (
            set "MEDIA_DRIVE=%%d:"
        )
    )
)

if "%MEDIA_DRIVE%"=="" (
    if exist "%~d0\Reglaze\prepare-target-disk.vbs" (
        set "MEDIA_DRIVE=%~d0"
    )
)

if "%MEDIA_DRIVE%"=="" (
    for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\prepare-target-disk.vbs" (
            set "MEDIA_DRIVE=%%d:"
        )
    )
)

if "%MEDIA_DRIVE%"=="" (
    echo [!] ERROR: Could not locate Reglaze installation media drive letter.
    echo     Dropping to WinPE Command Prompt for manual inspection.
    echo.
    echo Press any key to exit...
    pause >nul
    exit /b 1
)

echo [i] Reglaze installation media located on: %MEDIA_DRIVE%

set "VBS_SCRIPT=%MEDIA_DRIVE%\Reglaze\prepare-target-disk.vbs"
set "CONFIG_FILE=%MEDIA_DRIVE%\payload\disk-config.json"
set "PREPARE_SCRIPT=X:\prepare-disk.txt"

if not exist "%VBS_SCRIPT%" (
    if exist "%MEDIA_DRIVE%\prepare-target-disk.vbs" (
        set "VBS_SCRIPT=%MEDIA_DRIVE%\prepare-target-disk.vbs"
    )
)

if not exist "%VBS_SCRIPT%" (
    echo [!] ERROR: prepare-target-disk.vbs was not found on %MEDIA_DRIVE%\Reglaze or %MEDIA_DRIVE%\.
    echo     Target disk cannot be automatically prepared.
    echo     Dropping to WinPE Command Prompt for manual inspection.
    echo.
    echo Press any key to exit...
    pause >nul
    exit /b 1
)

rem 2. Run prepare-target-disk.vbs to discover target disk and generate diskpart script
echo [i] Querying connected disks via WMI...
echo.
cscript.exe //nologo "%VBS_SCRIPT%" /configFile:"%CONFIG_FILE%" /mediaLetter:"%MEDIA_DRIVE%" /outputScript:"%PREPARE_SCRIPT%"
set "VBS_EXIT=%ERRORLEVEL%"

if not "%VBS_EXIT%"=="0" (
    echo.
    echo [!] ERROR: Target disk discovery failed (exit code %VBS_EXIT%).
    echo     No modifications have been made to any disk.
    echo     Dropping to WinPE Command Prompt for manual inspection.
    echo.
    echo Press any key to exit...
    pause >nul
    exit /b %VBS_EXIT%
)

if not exist "%PREPARE_SCRIPT%" (
    echo.
    echo [!] ERROR: Partitioning script '%PREPARE_SCRIPT%' was not generated.
    echo.
    echo Press any key to exit...
    pause >nul
    exit /b 1
)

rem 3. Interactive confirmation prompt
echo.
echo ================================================================
echo   WARNING: ALL DATA ON THE TARGET DISK WILL BE PERMANENTLY ERASED!
echo ================================================================
echo   The disk will be wiped, converted to GPT, and formatted with:
echo     1. EFI System Partition   (100 MB, FAT32, "System")
echo     2. Microsoft Reserved     (16 MB, MSR)
echo     3. Windows OS Partition   (NTFS, "Windows")
echo     4. Windows Recovery       (1000 MB, NTFS, "Recovery")
echo ================================================================
echo.

set "USER_CONFIRM="
set /p "USER_CONFIRM=Are you sure you want to clean and partition this disk for Windows? [Y/N]: "

if /i not "!USER_CONFIRM!"=="Y" if /i not "!USER_CONFIRM!"=="YES" (
    echo.
    echo [x] Preparation canceled by user. No disk modifications were made.
    echo     Dropping to WinPE Command Prompt for manual inspection.
    echo.
    echo Press any key to exit...
    pause >nul
    exit /b 1
)

rem 4. Execute DiskPart
echo.
echo [i] Applying standard UEFI/GPT partition layout via diskpart.exe...
diskpart.exe /s "%PREPARE_SCRIPT%"
set "DP_EXIT=!ERRORLEVEL!"

if not "!DP_EXIT!"=="0" (
    echo [!] ERROR: DiskPart failed with exit code !DP_EXIT!.
    echo.
    echo Press any key to exit...
    pause >nul
    exit /b !DP_EXIT!
)

echo.
echo [OK] Target disk successfully partitioned and formatted!
echo      Windows Setup will now launch. Please select Partition 3 ("Windows")
echo      to begin installation.
echo ================================================================
echo.
echo Press any key to continue to Windows Setup...
pause >nul
exit /b 0
