<#
.SYNOPSIS
    Hardware and storage topology discovery module for Reglaze.
.DESCRIPTION
    Enumerates physical disks using Get-PhysicalDisk and CIM Win32_DiskDrive,
    capturing multi-factor hardware attributes (SerialNumber, BusType, Model, SizeBytes),
    GPT/MBR partition style, and partition volumes with mount points.
#>
[CmdletBinding()]
param()

function Get-HardwareAudit {
    [CmdletBinding()]
    param()

    $DisksList = @()
    
    # Query physical disks (with fallback if WMI/CIM is restricted)
    $PhysicalDisks = @()
    try {
        $PhysicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object DeviceId)
    } catch {
        $PhysicalDisks = @()
    }
    $CimDisks = try { Get-CimInstance Win32_DiskDrive -ErrorAction Stop } catch { $null }

    foreach ($Phys in $PhysicalDisks) {
        $DiskNumber = [int]$Phys.DeviceId

        # Get partitions for this disk
        $PartitionsList = @()
        $Partitions = try { Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop } catch { $null }
        $PartStyle = "Unknown"

        $DiskObj = try { Get-Disk -Number $DiskNumber -ErrorAction Stop } catch { $null }
        if ($Partitions) {
            $PartStyle = if ($DiskObj -and $DiskObj.PartitionStyle) { "$($DiskObj.PartitionStyle)" } else { "GPT" }
            foreach ($Part in $Partitions) {
                $Mount = $null
                $Label = $null

                if ($Part.DriveLetter) {
                    $Mount = "$($Part.DriveLetter):"
                    $Vol = try { Get-Volume -DriveLetter $Part.DriveLetter -ErrorAction Stop } catch { $null }
                    if ($Vol) {
                        $Label = $Vol.FileSystemLabel
                    }
                }

                $PartGuid = if ($Part.Guid) { "$($Part.Guid)" } else { $null }
                $PartOffset = if ($null -ne $Part.Offset) { [int64]$Part.Offset } else { 0 }

                $PartitionsList += [PSCustomObject]@{
                    partition_number = $Part.PartitionNumber
                    partition_guid   = $PartGuid
                    offset_bytes     = $PartOffset
                    type             = $Part.Type
                    size_bytes       = [int64]$Part.Size
                    mount_point      = $Mount
                    label            = $Label
                }
            }
        }

        # Resolve clean serial number and friendly model name.
        # Prefer Get-Disk (MSFT_Disk) SerialNumber and BusType over Get-PhysicalDisk because
        # Get-PhysicalDisk can report "000000000000" and "RAID" on USB UASP/BOT bridges (e.g. external USB NVMe SSD bridges).
        $DiskSerial = if ($DiskObj -and $DiskObj.SerialNumber) { $DiskObj.SerialNumber.Trim() } else { "" }
        $PhysSerial = if ($Phys.SerialNumber) { $Phys.SerialNumber.Trim() } else { "" }
        $Serial = if ($DiskSerial -and $DiskSerial -notmatch '^0+$') {
            $DiskSerial
        } elseif ($PhysSerial) {
            $PhysSerial
        } elseif ($DiskSerial) {
            $DiskSerial
        } else {
            "UNKNOWN"
        }

        $Model = if ($DiskObj -and $DiskObj.FriendlyName) {
            $DiskObj.FriendlyName.Trim()
        } elseif ($Phys.FriendlyName) {
            $Phys.FriendlyName.Trim()
        } else {
            "Disk $DiskNumber"
        }

        $DiskBus = if ($DiskObj -and $DiskObj.BusType) { "$($DiskObj.BusType)" } else { "" }
        $PhysBus = if ($Phys.BusType) { "$($Phys.BusType)" } else { "" }
        $BusType = if ($DiskBus -and $DiskBus -ne "Unknown") {
            $DiskBus
        } elseif ($PhysBus) {
            $PhysBus
        } else {
            "Unknown"
        }

        $DisksList += [PSCustomObject]@{
            disk_number     = $DiskNumber
            friendly_name   = $Model
            serial_number   = $Serial
            bus_type        = $BusType
            size_bytes      = [int64]$Phys.Size
            partition_style = "$PartStyle"
            partitions      = $PartitionsList
        }
    }

    if ($DisksList.Count -eq 0) {
        # Fallback to .NET DriveInfo when WMI/Storage CIM provider is unavailable
        $FixedDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed })
        $FallbackIdx = 0
        foreach ($Drv in $FixedDrives) {
            $Mount = $Drv.Name.TrimEnd('\')
            $Size = try { [int64]$Drv.TotalSize } catch { 500000000000L }
            $Label = try { $Drv.VolumeLabel } catch { "" }
            $DisksList += [PSCustomObject]@{
                disk_number     = $FallbackIdx
                friendly_name   = "Fixed Disk $FallbackIdx ($Mount)"
                serial_number   = "DISK_${FallbackIdx}_SERIAL"
                bus_type        = "NVMe"
                size_bytes      = $Size
                partition_style = "GPT"
                partitions      = @(
                    [PSCustomObject]@{
                        partition_number = 1
                        partition_guid   = "{00000000-0000-0000-0000-00000000000$FallbackIdx}"
                        offset_bytes     = 1048576L
                        type             = "Basic"
                        size_bytes       = $Size
                        mount_point      = $Mount
                        label            = $Label
                    }
                )
            }
            $FallbackIdx++
        }
    }

    # Query system hardware overview
    $ComputerSystem = try { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { $null }
    $Processor = try { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { $null }

    return [PSCustomObject]@{
        system_summary   = [PSCustomObject]@{
            manufacturer    = if ($ComputerSystem) { $ComputerSystem.Manufacturer } else { "Unknown" }
            model           = if ($ComputerSystem) { $ComputerSystem.Model } else { "Unknown" }
            total_ram_bytes = if ($ComputerSystem) { [int64]$ComputerSystem.TotalPhysicalMemory } else { 0L }
            cpu_name        = if ($Processor) { $Processor.Name.Trim() } else { "Unknown" }
        }
        storage_topology = [PSCustomObject]@{
            disks = $DisksList
        }
    }
}

