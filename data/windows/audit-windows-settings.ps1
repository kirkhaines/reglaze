<#
.SYNOPSIS
    Audits current Windows Explorer, Taskbar, and System settings.
.DESCRIPTION
    Reads user preferences from Registry and powercfg to emit a structured report.
#>
[CmdletBinding()]
param()

$Settings = [PSCustomObject]@{
    explorer = [PSCustomObject]@{
        show_hidden_files      = $false
        show_file_extensions   = $false
        launch_to              = "QuickAccess"
    }
    taskbar  = [PSCustomObject]@{
        alignment              = "Center"
        search_mode            = "IconOnly"
        widgets_visible        = $true
        chat_visible           = $true
    }
    power    = [PSCustomObject]@{
        active_scheme_name     = "Balanced"
        ac_sleep_minutes       = 30
    }
}

# 1. Explorer settings
$AdvKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
if (Test-Path $AdvKey) {
    $Hidden = (Get-ItemProperty -Path $AdvKey -Name "Hidden" -ErrorAction SilentlyContinue).Hidden
    $Settings.explorer.show_hidden_files = ($Hidden -eq 1)

    $HideExt = (Get-ItemProperty -Path $AdvKey -Name "HideFileExt" -ErrorAction SilentlyContinue).HideFileExt
    $Settings.explorer.show_file_extensions = ($HideExt -eq 0)

    $LaunchTo = (Get-ItemProperty -Path $AdvKey -Name "LaunchTo" -ErrorAction SilentlyContinue).LaunchTo
    $Settings.explorer.launch_to = if ($LaunchTo -eq 1) { "ThisPC" } else { "QuickAccess" }

    $TaskbarAl = (Get-ItemProperty -Path $AdvKey -Name "TaskbarAl" -ErrorAction SilentlyContinue).TaskbarAl
    $Settings.taskbar.alignment = if ($TaskbarAl -eq 0) { "Left" } else { "Center" }

    $Widgets = (Get-ItemProperty -Path $AdvKey -Name "TaskbarDa" -ErrorAction SilentlyContinue).TaskbarDa
    $Settings.taskbar.widgets_visible = ($Widgets -ne 0)

    $Chat = (Get-ItemProperty -Path $AdvKey -Name "TaskbarMn" -ErrorAction SilentlyContinue).TaskbarMn
    $Settings.taskbar.chat_visible = ($Chat -ne 0)
}

# 2. Search mode
$SearchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
if (Test-Path $SearchKey) {
    $SearchVal = (Get-ItemProperty -Path $SearchKey -Name "SearchboxTaskbarMode" -ErrorAction SilentlyContinue).SearchboxTaskbarMode
    $Settings.taskbar.search_mode = switch ($SearchVal) {
        0 { "Hidden" }
        1 { "IconOnly" }
        2 { "Box" }
        default { "IconOnly" }
    }
}

# 3. Power scheme
$ActivePower = powercfg /getactivescheme
if ($ActivePower -match "\((?<name>[^)]+)\)") {
    $Settings.power.active_scheme_name = $Matches['name']
}

return $Settings
