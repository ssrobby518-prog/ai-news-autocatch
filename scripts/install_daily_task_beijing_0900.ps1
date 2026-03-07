# install_daily_task_beijing_0900.ps1 — Register Windows Scheduled Task for daily 09:00 Beijing (UTC+8)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_daily_task_beijing_0900.ps1
#
# iter45: daily scheduler installer (CurrentUser, no admin required)

$ErrorActionPreference = "Stop"

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path $PSScriptRoot -Parent
$taskName = "AIIntelScraper_Daily_0900_BJ"
$scriptPath = Join-Path $repoRoot "scripts\desktop_button.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: desktop_button.ps1 not found at $scriptPath"
    exit 1
}

# Beijing 09:00 = UTC 01:00
# Windows Task Scheduler uses local time; calculate local equivalent
$utcTarget = [TimeSpan]::new(1, 0, 0)  # 01:00 UTC
$localOffset = [System.TimeZoneInfo]::Local.BaseUtcOffset
$localTime = $utcTarget.Add($localOffset)
# Handle day wrap
if ($localTime.TotalHours -lt 0) { $localTime = $localTime.Add([TimeSpan]::new(24, 0, 0)) }
if ($localTime.TotalHours -ge 24) { $localTime = $localTime.Subtract([TimeSpan]::new(24, 0, 0)) }
$triggerTimeStr = "{0:D2}:{1:D2}" -f [int]$localTime.Hours, [int]$localTime.Minutes

Write-Host "=== AIIntelScraper Daily Task Installer ==="
Write-Host ""
Write-Host "Task name   : $taskName"
Write-Host "Beijing time: 09:00 (UTC+8)"
Write-Host "UTC time    : 01:00"
Write-Host "Local time  : $triggerTimeStr ($(([System.TimeZoneInfo]::Local).DisplayName))"
Write-Host "Script      : $scriptPath"
Write-Host "Working dir : $repoRoot"
Write-Host ""

# Remove existing task if present
$existingTask = $null
try {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
} catch {}

if ($existingTask) {
    Write-Host "Existing task '$taskName' found — removing..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  Removed."
}

# Create task
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode daily" `
    -WorkingDirectory $repoRoot

$trigger = New-ScheduledTaskTrigger -Daily -At $triggerTimeStr

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "AI Intel Scraper daily pipeline (Beijing 09:00 / UTC 01:00). Mode=daily, budget=200s."

Register-ScheduledTask -TaskName $taskName -InputObject $task | Out-Null

Write-Host ""
Write-Host "Task '$taskName' registered successfully."
Write-Host ""
Write-Host "=== Verification Commands ==="
Write-Host ""
Write-Host "1) View task details:"
Write-Host "   schtasks /Query /TN `"$taskName`" /V /FO LIST"
Write-Host ""
Write-Host "2) Run task manually (immediate):"
Write-Host "   schtasks /Run /TN `"$taskName`""
Write-Host ""
Write-Host "3) Check last run result:"
Write-Host "   schtasks /Query /TN `"$taskName`" /FO LIST | Select-String 'Last Run','Status','Next Run'"
Write-Host ""
Write-Host "4) Remove task:"
Write-Host "   Unregister-ScheduledTask -TaskName `"$taskName`" -Confirm:`$false"
Write-Host ""
Write-Host "=== Done ==="
