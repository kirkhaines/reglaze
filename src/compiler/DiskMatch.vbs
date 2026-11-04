' =============================================================================
' Reglaze WinPE Disk Matching & Isolation Engine (DiskMatch.vbs)
' Part of the Reglaze Operating System Provisioning Toolkit.
'
' Executed in Windows PE via cscript.exe prior to Windows Setup disk selection.
' Uses native WMI (Win32_DiskDrive) to:
'   1. Parse target OS disk and preserved disk requirements from disk-config.json (or CLI).
'   2. Locate the USB installation media physical disk and protect it from modification.
'   3. Match the Target OS Disk by SerialNumber (or fallback BusType + Disk ID).
'   4. Generate an automated diskpart script to OFFLINE and set READONLY on all
'      secondary/preserved disks, strictly preventing Windows Setup from altering
'      secondary bootloaders, EFI partitions, or user data.
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
Dim targetSerial, targetBus, targetId, mediaLetter, preservedSerials, outputPath, configFile
Dim targetNormSerial, targetDiskIndex, mediaDiskIndex
Dim colDisks, objDisk
Dim diskCount, protectedCount
Dim outFile, fsoOutDir

targetSerial     = ""
targetBus        = ""
targetId         = -1
mediaLetter      = ""
preservedSerials = ""
outputPath       = "X:\offline-disks.txt"
configFile       = ""

' Parse Named Command Line Arguments
If WScript.Arguments.Named.Exists("targetSerial") Then targetSerial = WScript.Arguments.Named("targetSerial")
If WScript.Arguments.Named.Exists("targetBus") Then targetBus = WScript.Arguments.Named("targetBus")
If WScript.Arguments.Named.Exists("targetId") Then targetId = CInt(WScript.Arguments.Named("targetId"))
If WScript.Arguments.Named.Exists("mediaLetter") Then mediaLetter = WScript.Arguments.Named("mediaLetter")
If WScript.Arguments.Named.Exists("preservedSerials") Then preservedSerials = WScript.Arguments.Named("preservedSerials")
If WScript.Arguments.Named.Exists("outputPath") Then outputPath = WScript.Arguments.Named("outputPath")
If WScript.Arguments.Named.Exists("configFile") Then configFile = WScript.Arguments.Named("configFile")

WScript.Echo "================================================================"
WScript.Echo "  REGLAZE WINPE DISK ISOLATION & PROTECTION ENGINE"
WScript.Echo "================================================================"

' Parse disk-config.json if provided and not explicitly overridden on CLI
If Len(configFile) > 0 And objFSO.FileExists(configFile) Then
    On Error Resume Next
    Dim jsonText, regExp, matches
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
        WScript.Echo "[+] Installation Media Drive " & UCase(Left(mediaLetter, 1)) & ": located on Physical Disk " & mediaDiskIndex
    End If
End If

' Query All Disks
Set colDisks = objWMIService.ExecQuery("Select * from Win32_DiskDrive")
diskCount = colDisks.Count
WScript.Echo "[+] Discovered " & diskCount & " physical disk(s) in WinPE."

targetNormSerial = NormalizeSerial(targetSerial)
targetDiskIndex = -1

' Pass 1: Identify Target OS Disk by SerialNumber
For Each objDisk In colDisks
    Dim curNormSerial, curIndex
    curIndex = objDisk.Index
    curNormSerial = NormalizeSerial(objDisk.SerialNumber)
    
    If Len(targetNormSerial) > 0 And Len(curNormSerial) > 0 Then
        If InStr(curNormSerial, targetNormSerial) > 0 Or InStr(targetNormSerial, curNormSerial) > 0 Then
            targetDiskIndex = curIndex
            WScript.Echo "[+] MATCHED Target OS Disk: Disk " & curIndex & " (" & objDisk.Model & ") by SerialNumber"
        End If
    End If
Next

' Fallback matching by DiskId if serial number did not match
If targetDiskIndex = -1 And targetId >= 0 Then
    For Each objDisk In colDisks
        If objDisk.Index = targetId Then
            targetDiskIndex = targetId
            WScript.Echo "[+] Matched Target OS Disk by fallback Index: Disk " & targetId & " (" & objDisk.Model & ")"
        End If
    Next
End If

If targetDiskIndex >= 0 Then
    WScript.Echo "[*] Target OS Disk:   Disk " & targetDiskIndex
Else
    WScript.Echo "[!] Notice: Target OS disk not uniquely matched prior to setup."
    WScript.Echo "    All secondary and preserved disks will be offlined for safety."
End If

' Pass 2: Generate Diskpart Script for All Secondary/Preserved Disks
fsoOutDir = objFSO.GetParentFolderName(outputPath)
If Len(fsoOutDir) > 0 And Not objFSO.FolderExists(fsoOutDir) Then
    On Error Resume Next
    objFSO.CreateFolder(fsoOutDir)
    On Error GoTo 0
End If

Set outFile = objFSO.CreateTextFile(outputPath, True)
outFile.WriteLine "rem ================================================================"
outFile.WriteLine "rem Reglaze WinPE Disk Isolation Script (Generated by DiskMatch.vbs)"
outFile.WriteLine "rem ================================================================"

protectedCount = 0

For Each objDisk In colDisks
    Dim dIndex, dModel, dSerial, dInterface, dPnp, dMedia
    dIndex = objDisk.Index
    dModel = objDisk.Model
    dSerial = Trim(objDisk.SerialNumber & "")
    dInterface = UCase(Trim(objDisk.InterfaceType & ""))
    dPnp = UCase(Trim(objDisk.PNPDeviceID & ""))
    dMedia = UCase(Trim(objDisk.MediaType & ""))
    
    Dim isMedia, isTarget
    isMedia = False
    isTarget = False
    
    If dIndex = mediaDiskIndex Then isMedia = True
    If dInterface = "USB" Or InStr(dPnp, "USB") > 0 Or InStr(dMedia, "REMOVABLE") > 0 Then isMedia = True
    If targetDiskIndex >= 0 And dIndex = targetDiskIndex Then isTarget = True
    
    If isMedia Then
        WScript.Echo " [i] Disk " & dIndex & ": " & dModel & " -> PROTECTED INSTALL MEDIA (Skip)"
    ElseIf isTarget Then
        WScript.Echo " [>] Disk " & dIndex & ": " & dModel & " -> TARGET OS DISK (Keep Online & Writable)"
    Else
        WScript.Echo " [x] Disk " & dIndex & ": " & dModel & " -> SECONDARY DISK (Setting OFFLINE & READONLY)"
        WScript.Echo " [i]     PNPDeviceID: " & dPnp & " InterfaceType: " & dInterface & " MediaType: " & dMedia
        outFile.WriteLine "select disk " & dIndex
        Dim isNvme
        isNvme = False
        If InStr(dPnp, "NVME") > 0 Or InStr(dInterface, "NVME") > 0 Or InStr(dInterface, "PCIE") > 0 Or InStr(UCase(dModel), "NVME") > 0 Then
            isNvme = True
        End If
        If isNvme Then
            WScript.Echo " [i]     Skipping READONLY attribute for NVMe disk (not supported by stornvme)"
        Else
            outFile.WriteLine "attribute disk set readonly"
        End If
        outFile.WriteLine "offline disk"
        protectedCount = protectedCount + 1
    End If
Next

outFile.WriteLine "rescan"
outFile.Close

WScript.Echo ""
WScript.Echo "[+] Diskpart isolation script generated: " & outputPath
WScript.Echo "[+] Disks to offline & protect: " & protectedCount
WScript.Echo "================================================================"

WScript.Quit 0
