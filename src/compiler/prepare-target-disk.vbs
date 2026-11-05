' =============================================================================
' Reglaze WinPE Target Disk Preparation Engine (prepare-target-disk.vbs)
' Part of the Reglaze Operating System Provisioning Toolkit.
'
' Executed in Windows PE prior to Windows Setup disk selection.
' Uses native WMI (Win32_DiskDrive) to:
'   1. Parse target OS disk and preserved disk requirements from disk-config.json (or CLI).
'   2. Locate the USB installation media physical disk to strictly protect it from modification.
'   3. Dynamically match the Target OS Disk by SerialNumber (or fallback Index/BusType).
'   4. Verify the matched disk is NOT in the preserved disks list or the install media.
'   5. Output a detailed human-readable summary of the detected disk, its properties,
'      and all existing partitions/volumes for operator review.
'   6. Generate a standard Microsoft UEFI/GPT 4-partition DiskPart script
'      (260MB EFI FAT32 "System", 16MB MSR, Primary NTFS "Windows", 1000MB NTFS "Recovery").
' =============================================================================

Option Explicit

Dim objFSO, objWMIService, objShell
Set objFSO = CreateObject("Scripting.FileSystemObject")
Set objShell = CreateObject("WScript.Shell")

' -----------------------------------------------------------------------------
' Helper: Normalize serial numbers for robust substring/case-insensitive matching
' -----------------------------------------------------------------------------
Function NormalizeSerial(s)
    Dim res, i, ch
    res = ""
    If IsNull(s) Or IsEmpty(s) Then
        NormalizeSerial = ""
        Exit Function
    End If
    s = Trim(CStr(s))
    For i = 1 To Len(s)
        ch = Mid(s, i, 1)
        If ch <> "_" And ch <> "-" And ch <> " " And ch <> "." And ch <> ":" Then
            res = res & UCase(ch)
        End If
    Next
    NormalizeSerial = res
End Function

' -----------------------------------------------------------------------------
' Helper: Format byte counts into human-readable MB, GB, or TB
' -----------------------------------------------------------------------------
Function FormatSize(bytes)
    Dim dblBytes, gb, tb, mb
    On Error Resume Next
    dblBytes = CDbl(bytes)
    If Err.Number <> 0 Or dblBytes <= 0 Then
        FormatSize = "0 MB"
        Exit Function
    End If
    On Error GoTo 0
    
    gb = dblBytes / (1024 * 1024 * 1024)
    If gb >= 1000 Then
        tb = gb / 1024
        FormatSize = FormatNumber(tb, 2) & " TB (" & FormatNumber(gb, 1) & " GB)"
    ElseIf gb >= 1 Then
        FormatSize = FormatNumber(gb, 2) & " GB"
    Else
        mb = dblBytes / (1024 * 1024)
        FormatSize = FormatNumber(mb, 0) & " MB"
    End If
End Function

' -----------------------------------------------------------------------------
' Helper: Find physical disk index for a mounted drive letter via WMI
' -----------------------------------------------------------------------------
Function GetDiskIndexForDriveLetter(driveLetter)
    On Error Resume Next
    Dim cleanLetter, query, colDisks, objDisk, colParts, objPart, colLogicals, objLogical
    GetDiskIndexForDriveLetter = -1
    If IsNull(driveLetter) Or Len(driveLetter) = 0 Then Exit Function
    cleanLetter = UCase(Left(Trim(driveLetter), 1)) & ":"
    
    Set colDisks = objWMIService.ExecQuery("Select DeviceID, Index from Win32_DiskDrive")
    For Each objDisk In colDisks
        query = "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='" & objDisk.DeviceID & "'} WHERE AssocClass = Win32_DiskDriveToDiskPartition"
        Set colParts = objWMIService.ExecQuery(query)
        For Each objPart In colParts
            query = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='" & objPart.DeviceID & "'} WHERE AssocClass = Win32_LogicalDiskToPartition"
            Set colLogicals = objWMIService.ExecQuery(query)
            For Each objLogical In colLogicals
                If UCase(objLogical.DeviceID) = cleanLetter Then
                    GetDiskIndexForDriveLetter = objDisk.Index
                    Exit Function
                End If
            Next
        Next
    Next
    On Error GoTo 0
End Function

' -----------------------------------------------------------------------------
' Main Execution
' -----------------------------------------------------------------------------
Dim targetSerial, targetBus, targetId, mediaLetter, outputPath, configFile
Dim targetNormSerial, targetDiskIndex, mediaDiskIndex
Dim colDisks, objDisk
Dim diskCount, matchedDisk
Dim preservedSerialsList

targetSerial     = ""
targetBus        = ""
targetId         = -1
mediaLetter      = ""
outputPath       = "X:\prepare-disk.txt"
configFile       = ""
Set preservedSerialsList = CreateObject("Scripting.Dictionary")

' Parse Named Command Line Arguments
If WScript.Arguments.Named.Exists("targetSerial") Then targetSerial = WScript.Arguments.Named("targetSerial")
If WScript.Arguments.Named.Exists("targetBus")    Then targetBus    = WScript.Arguments.Named("targetBus")
If WScript.Arguments.Named.Exists("targetId")     Then targetId     = CInt(WScript.Arguments.Named("targetId"))
If WScript.Arguments.Named.Exists("mediaLetter")  Then mediaLetter  = WScript.Arguments.Named("mediaLetter")
If WScript.Arguments.Named.Exists("outputScript") Then outputPath   = WScript.Arguments.Named("outputScript")
If WScript.Arguments.Named.Exists("configFile")   Then configFile   = WScript.Arguments.Named("configFile")

WScript.Echo "================================================================"
WScript.Echo "  REGLAZE WINPE TARGET DISK PREPARATION ENGINE"
WScript.Echo "================================================================"

' Parse disk-config.json if provided
If Len(configFile) > 0 And objFSO.FileExists(configFile) Then
    On Error Resume Next
    Dim jsonText, regExp, matches, m
    jsonText = objFSO.OpenTextFile(configFile, 1).ReadAll()
    If Err.Number = 0 Then
        ' Extract TargetOsDisk SerialNumber
        If Len(targetSerial) = 0 Then
            Set regExp = New RegExp
            regExp.IgnoreCase = True
            regExp.Global = False
            regExp.Pattern = """TargetOsDisk""\s*:\s*\{[^}]*""SerialNumber""\s*:\s*""([^""]*)"""
            Set matches = regExp.Execute(jsonText)
            If matches.Count > 0 Then
                targetSerial = matches(0).SubMatches(0)
                WScript.Echo "[i] Loaded target serial from disk-config.json: " & targetSerial
            End If
        End If

        ' Extract TargetOsDisk BusType
        If Len(targetBus) = 0 Then
            Set regExp = New RegExp
            regExp.IgnoreCase = True
            regExp.Global = False
            regExp.Pattern = """TargetOsDisk""\s*:\s*\{[^}]*""BusType""\s*:\s*""([^""]*)"""
            Set matches = regExp.Execute(jsonText)
            If matches.Count > 0 Then
                targetBus = matches(0).SubMatches(0)
            End If
        End If

        ' Extract TargetOsDisk DiskId
        If targetId = -1 Then
            Set regExp = New RegExp
            regExp.IgnoreCase = True
            regExp.Global = False
            regExp.Pattern = """TargetOsDisk""\s*:\s*\{[^}]*""DiskId""\s*:\s*([0-9]+)"
            Set matches = regExp.Execute(jsonText)
            If matches.Count > 0 Then
                targetId = CInt(matches(0).SubMatches(0))
            End If
        End If

        ' Extract PreservedDisks SerialNumbers
        Set regExp = New RegExp
        regExp.IgnoreCase = True
        regExp.Global = True
        regExp.Pattern = """SerialNumber""\s*:\s*""([^""]+)"""
        Set matches = regExp.Execute(jsonText)
        For Each m In matches
            Dim sNum
            sNum = NormalizeSerial(m.SubMatches(0))
            If Len(sNum) > 0 And sNum <> NormalizeSerial(targetSerial) Then
                If Not preservedSerialsList.Exists(sNum) Then
                    preservedSerialsList.Add sNum, True
                End If
            End If
        Next
    End If
    On Error GoTo 0
End If

' Connect to WMI
On Error Resume Next
Set objWMIService = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
If Err.Number <> 0 Then
    WScript.Echo "[!] CRITICAL: Failed to connect to WMI (" & Err.Description & ")"
    WScript.Quit 1
End If
On Error GoTo 0

' Determine Installation Media Disk Index
mediaDiskIndex = -1
If Len(mediaLetter) > 0 Then
    mediaDiskIndex = GetDiskIndexForDriveLetter(mediaLetter)
    If mediaDiskIndex >= 0 Then
        WScript.Echo "[+] Installation Media Drive " & UCase(Left(mediaLetter, 1)) & ": verified on Physical Disk " & mediaDiskIndex
    End If
End If

' Query All Disks
Set colDisks = objWMIService.ExecQuery("Select * from Win32_DiskDrive")
diskCount = colDisks.Count
WScript.Echo "[+] Discovered " & diskCount & " physical disk(s) in WinPE."
WScript.Echo ""

targetNormSerial = NormalizeSerial(targetSerial)
targetDiskIndex = -1
Set matchedDisk = Nothing

' Pass 1: Identify Target OS Disk by SerialNumber
For Each objDisk In colDisks
    Dim curNormSerial, curIndex
    curIndex = objDisk.Index
    curNormSerial = NormalizeSerial(objDisk.SerialNumber)
    
    If Len(targetNormSerial) > 0 And Len(curNormSerial) > 0 Then
        If InStr(curNormSerial, targetNormSerial) > 0 Or InStr(targetNormSerial, curNormSerial) > 0 Then
            targetDiskIndex = curIndex
            Set matchedDisk = objDisk
            Exit For
        End If
    End If
Next

' Pass 2: Fallback matching by DiskId if serial number was not matched
If targetDiskIndex = -1 And targetId >= 0 Then
    For Each objDisk In colDisks
        If objDisk.Index = targetId Then
            targetDiskIndex = targetId
            Set matchedDisk = objDisk
            Exit For
        End If
    Next
End If

' Validation: Target Disk Must Be Found
If targetDiskIndex = -1 Or matchedDisk Is Nothing Then
    WScript.Echo "[-] ERROR: Could not uniquely resolve Target OS Disk in WinPE!"
    WScript.Echo "    Expected Serial: '" & targetSerial & "' (Fallback Index: " & targetId & ")"
    WScript.Echo ""
    WScript.Echo "Connected Disks in WinPE:"
    For Each objDisk In colDisks
        WScript.Echo "  - Disk " & objDisk.Index & ": " & objDisk.Model & " (Serial: " & Trim(objDisk.SerialNumber & "") & ", Size: " & FormatSize(objDisk.Size) & ")"
    Next
    WScript.Echo "================================================================"
    WScript.Quit 2
End If

' Safety Check 1: Target Disk CANNOT be the Installation Media USB
If targetDiskIndex = mediaDiskIndex Then
    WScript.Echo "[!] CRITICAL SAFETY VIOLATION: Resolved Target Disk " & targetDiskIndex & " is the Reglaze Installation Media!"
    WScript.Echo "    Aborting target disk preparation to protect installer."
    WScript.Echo "================================================================"
    WScript.Quit 3
End If

' Safety Check 2: Target Disk CANNOT be in Preserved Disks list
Dim matchedNormSerial
matchedNormSerial = NormalizeSerial(matchedDisk.SerialNumber)
If preservedSerialsList.Exists(matchedNormSerial) Then
    WScript.Echo "[!] CRITICAL SAFETY VIOLATION: Resolved Target Disk " & targetDiskIndex & " (" & matchedDisk.SerialNumber & ") matches a declared PRESERVED disk!"
    WScript.Echo "    Aborting target disk preparation to protect preserved user data."
    WScript.Echo "================================================================"
    WScript.Quit 4
End If

' Determine Bus Type
Dim detectedBus
detectedBus = Trim(matchedDisk.InterfaceType & "")
If InStr(UCase(matchedDisk.PNPDeviceID & ""), "NVME") > 0 Or InStr(UCase(matchedDisk.Model & ""), "NVME") > 0 Then
    detectedBus = "NVMe"
ElseIf Len(targetBus) > 0 Then
    detectedBus = targetBus & " (" & detectedBus & ")"
End If

' Output Detailed Confirmation Summary
WScript.Echo "----------------------------------------------------------------"
WScript.Echo "  DETECTED TARGET OS DISK"
WScript.Echo "----------------------------------------------------------------"
WScript.Echo "  Disk Number:       Disk " & targetDiskIndex
WScript.Echo "  Device Model:      " & matchedDisk.Model
WScript.Echo "  Serial Number:     " & Trim(matchedDisk.SerialNumber & "")
WScript.Echo "  Bus / Interface:   " & detectedBus
WScript.Echo "  Total Capacity:    " & FormatSize(matchedDisk.Size)
WScript.Echo "  Partition Count:   " & matchedDisk.Partitions
WScript.Echo "  Media Type:        " & Trim(matchedDisk.MediaType & "")
WScript.Echo ""
WScript.Echo "  Existing Partitions and Volumes on Disk " & targetDiskIndex & ":"

On Error Resume Next
Dim partQuery, colTargetParts, objPart, partFound
partQuery = "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='" & matchedDisk.DeviceID & "'} WHERE AssocClass = Win32_DiskDriveToDiskPartition"
Set colTargetParts = objWMIService.ExecQuery(partQuery)
partFound = False

For Each objPart In colTargetParts
    partFound = True
    Dim logQuery, colLog, objLog, volInfo
    volInfo = "[Unmounted]"
    
    logQuery = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='" & objPart.DeviceID & "'} WHERE AssocClass = Win32_LogicalDiskToPartition"
    Set colLog = objWMIService.ExecQuery(logQuery)
    For Each objLog In colLog
        volInfo = "[" & objLog.DeviceID & " " & Trim(objLog.VolumeName & "") & "] (" & objLog.FileSystem & ")"
    Next
    
    WScript.Echo "    * " & objPart.Name & ": " & objPart.Type & " (" & FormatSize(objPart.Size) & ") -> " & volInfo
Next

If Not partFound Then
    WScript.Echo "    * [No existing partitions detected - drive is clean / unpartitioned]"
End If
On Error GoTo 0

WScript.Echo "----------------------------------------------------------------"

' Generate UEFI/GPT 4-Partition Layout Diskpart Script
Dim fsoOutDir, outFile
fsoOutDir = objFSO.GetParentFolderName(outputPath)
If Len(fsoOutDir) > 0 And Not objFSO.FolderExists(fsoOutDir) Then
    On Error Resume Next
    objFSO.CreateFolder(fsoOutDir)
    On Error GoTo 0
End If

Set outFile = objFSO.CreateTextFile(outputPath, True)
outFile.WriteLine "rem ================================================================"
outFile.WriteLine "rem Reglaze Standard Microsoft UEFI/GPT Layout for Disk " & targetDiskIndex
outFile.WriteLine "rem Target Model: " & matchedDisk.Model & " (Serial: " & Trim(matchedDisk.SerialNumber & "") & ")"
outFile.WriteLine "rem ================================================================"
outFile.WriteLine "select disk " & targetDiskIndex
outFile.WriteLine "clean"
outFile.WriteLine "convert gpt"
outFile.WriteLine "create partition efi size=260"
outFile.WriteLine "format quick fs=fat32 label=""System"""
outFile.WriteLine "create partition msr size=16"
outFile.WriteLine "create partition primary"
outFile.WriteLine "shrink minimum=1000"
outFile.WriteLine "format quick fs=ntfs label=""Windows"""
outFile.WriteLine "create partition primary"
outFile.WriteLine "format quick fs=ntfs label=""Recovery"""
outFile.WriteLine "set id=""de94bba4-06d1-4d40-a16a-bfd50179d6ac"""
outFile.WriteLine "gpt attributes=0x8000000000000001"
outFile.WriteLine "rescan"
outFile.Close

WScript.Echo "[+] Partitioning script generated: " & outputPath
WScript.Echo "================================================================"

WScript.Quit 0

