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
    
    # Query physical disks
    $PhysicalDisks = Get-PhysicalDisk | Sort-Object DeviceId
    $CimDisks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue

    foreach ($Phys in $PhysicalDisks) {
        $DiskNumber = [int]$Phys.DeviceId

        # Get partitions for this disk
        $PartitionsList = @()
        $Partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
        $PartStyle = "Unknown"

        if ($Partitions) {
            $PartStyle = (Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue).PartitionStyle
            foreach ($Part in $Partitions) {
                $Mount = $null
                $Label = $null

                if ($Part.DriveLetter) {
                    $Mount = "$($Part.DriveLetter):"
                    $Vol = Get-Volume -DriveLetter $Part.DriveLetter -ErrorAction SilentlyContinue
                    if ($Vol) {
                        $Label = $Vol.FileSystemLabel
                    }
                }

                $PartitionsList += [PSCustomObject]@{
                    partition_number = $Part.PartitionNumber
                    type             = $Part.Type
                    size_bytes       = [int64]$Part.Size
                    mount_point      = $Mount
                    label            = $Label
                }
            }
        }

        # Resolve clean serial number and friendly model name
        $Serial = if ($Phys.SerialNumber) { $Phys.SerialNumber.Trim() } else { "UNKNOWN" }
        $Model = if ($Phys.FriendlyName) { $Phys.FriendlyName.Trim() } else { "Disk $DiskNumber" }
        $BusType = if ($Phys.BusType) { "$($Phys.BusType)" } else { "Unknown" }

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

    # Query system hardware overview
    $ComputerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $Processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    return [PSCustomObject]@{
        system_summary   = [PSCustomObject]@{
            manufacturer    = $ComputerSystem.Manufacturer
            model           = $ComputerSystem.Model
            total_ram_bytes = [int64]$ComputerSystem.TotalPhysicalMemory
            cpu_name        = if ($Processor) { $Processor.Name.Trim() } else { "Unknown" }
        }
        storage_topology = [PSCustomObject]@{
            disks = $DisksList
        }
    }
}

