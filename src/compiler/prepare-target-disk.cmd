@echo off
setlocal

echo ================================================================
echo   REGLAZE WINPE TARGET DISK PREPARATION AND PARTITIONING ENGINE
echo ================================================================

rem 1. Determine installation media drive letter
set "MEDIA_DRIVE=%~1"
set "EXPECTED_TAG=%~2"
if not "%MEDIA_DRIVE%"=="" (
    rem Strip trailing backslash or colon if present
    set "MEDIA_DRIVE=%MEDIA_DRIVE:~0,1%:"
    goto :media_arg_check
)

if not "%EXPECTED_TAG%"=="" (
    for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\Reglaze\reglaze.tag" (
            findstr /i /c:"%EXPECTED_TAG%" "%%d:\Reglaze\reglaze.tag" >nul 2>&1
            if not errorlevel 1 (
                if exist "%%d:\Reglaze\prepare-target-disk.vbs" (
                    set "MEDIA_DRIVE=%%d:"
                )
            )
        )
    )
)

if "%MEDIA_DRIVE%"=="" (
    for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if exist "%%d:\Reglaze\reglaze.tag" (
            if exist "%%d:\Reglaze\prepare-target-disk.vbs" (
                set "MEDIA_DRIVE=%%d:"
            )
        )
    )
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

:media_arg_check
if not "%MEDIA_DRIVE%"=="" goto :media_found

echo [!] ERROR: Could not locate Reglaze installation media drive letter.
echo     Dropping to WinPE Command Prompt for manual inspection.
echo.
echo Press any key to exit...
pause >nul
exit /b 1

:media_found
echo [i] Reglaze installation media located on: %MEDIA_DRIVE%

set "VBS_SCRIPT=%MEDIA_DRIVE%\Reglaze\prepare-target-disk.vbs"
set "CONFIG_FILE=%MEDIA_DRIVE%\Reglaze\payload\disk-config.json"
if not exist "%CONFIG_FILE%" (
    if exist "%MEDIA_DRIVE%\payload\disk-config.json" (
        set "CONFIG_FILE=%MEDIA_DRIVE%\payload\disk-config.json"
    )
)
set "PREPARE_SCRIPT=X:\prepare-disk.txt"

if exist "%VBS_SCRIPT%" goto :vbs_found
if exist "%MEDIA_DRIVE%\prepare-target-disk.vbs" (
    set "VBS_SCRIPT=%MEDIA_DRIVE%\prepare-target-disk.vbs"
    goto :vbs_found
)

echo [!] ERROR: prepare-target-disk.vbs was not found on %MEDIA_DRIVE%\Reglaze or %MEDIA_DRIVE%\.
echo     Target disk cannot be automatically prepared.
echo     Dropping to WinPE Command Prompt for manual inspection.
echo.
echo Press any key to exit...
pause >nul
exit /b 1

:vbs_found
rem 2. Run prepare-target-disk.vbs to discover target disk and generate diskpart script
echo [i] Querying connected disks via WMI...
echo.
cscript.exe //nologo "%VBS_SCRIPT%" /configFile:"%CONFIG_FILE%" /mediaLetter:"%MEDIA_DRIVE%" /outputScript:"%PREPARE_SCRIPT%"
set "VBS_EXIT=%ERRORLEVEL%"

if "%VBS_EXIT%"=="0" goto :vbs_ok

echo.
echo [!] ERROR: Target disk discovery failed [exit code %VBS_EXIT%].
echo     No modifications have been made to any disk.
echo     Dropping to WinPE Command Prompt for manual inspection.
echo.
echo Press any key to exit...
pause >nul
exit /b %VBS_EXIT%

:vbs_ok
if exist "%PREPARE_SCRIPT%" goto :script_ok

echo.
echo [!] ERROR: Partitioning script '%PREPARE_SCRIPT%' was not generated.
echo.
echo Press any key to exit...
pause >nul
exit /b 1

:script_ok
rem 3. Interactive confirmation prompt
echo.
echo ================================================================
echo   WARNING: ALL DATA ON THE TARGET DISK WILL BE PERMANENTLY ERASED!
echo ================================================================
echo   The disk will be wiped, converted to GPT, and formatted with:
echo     1. EFI System Partition   [260 MB, FAT32, "System"]
echo     2. Microsoft Reserved     [16 MB, MSR]
echo     3. Windows OS Partition   [NTFS, "Windows"]
echo     4. Windows Recovery       [1000 MB, NTFS, "Recovery"]
echo ================================================================
echo.

set "USER_CONFIRM="
set /p "USER_CONFIRM=Are you sure you want to clean and partition this disk for Windows? [Y/N]: "

if /i "%USER_CONFIRM%"=="Y" goto :do_partition
if /i "%USER_CONFIRM%"=="YES" goto :do_partition

echo.
echo [x] Preparation canceled by user. No disk modifications were made.
echo     Dropping to WinPE Command Prompt for manual inspection.
echo.
echo Press any key to exit...
pause >nul
exit /b 1

:do_partition
rem 4. Execute DiskPart
echo.
echo [i] Applying standard UEFI/GPT partition layout via diskpart.exe...
diskpart.exe /s "%PREPARE_SCRIPT%"
set "DP_EXIT=%ERRORLEVEL%"

if "%DP_EXIT%"=="0" goto :dp_ok

echo.
echo [!] ERROR: DiskPart failed with exit code %DP_EXIT%.
echo.
echo Press any key to exit...
pause >nul
exit /b %DP_EXIT%

:dp_ok
echo.
echo [OK] Target disk successfully partitioned and formatted!
echo      Windows Setup will now launch. Please select Partition 3 ["Windows"]
echo      to begin installation.
echo ================================================================
echo.
echo Press any key to continue to Windows Setup...
pause >nul
exit /b 0
