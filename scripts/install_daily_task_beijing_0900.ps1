# install_daily_task_beijing_0900.ps1 — Register Windows Scheduled Task for daily 09:00 Beijing (UTC+8)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_daily_task_beijing_0900.ps1
#
# iter45: daily scheduler installer (CurrentUser, no admin required)
# iter83: canonical scheduled-task installer now calls scheduler_wrapper.ps1

$ErrorActionPreference = "Stop"

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path $PSScriptRoot -Parent
$taskName = "AIIntelScraper_Daily_0900_BJ"
$wrapperScript = Join-Path $repoRoot "scripts\scheduler_wrapper.ps1"
$schedulerMeta = Join-Path $repoRoot "outputs\scheduler.meta.json"

if (-not (Test-Path $wrapperScript)) {
    Write-Host "ERROR: scheduler_wrapper.ps1 not found at $wrapperScript"
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
Write-Host "Script      : $wrapperScript"
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

# Canonical path: scheduled task -> scheduler_wrapper.ps1 -> verify_online.ps1 -Mode daily
$actionArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", ('"{0}"' -f $wrapperScript)
) -join " "

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument $actionArgs `
    -WorkingDirectory $repoRoot

$trigger = New-ScheduledTaskTrigger -Daily -At $triggerTimeStr

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "AI Intel Scraper daily pipeline (Beijing 09:00 / UTC 01:00). Mode=daily, ENTRYPOINT=scheduled_task, budget=200s."

Register-ScheduledTask -TaskName $taskName -InputObject $task | Out-Null

if (-not (Test-Path (Split-Path $schedulerMeta -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $schedulerMeta -Parent) -Force | Out-Null
}

$nextRunBj = ""
try {
    $cstZone2   = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
    $nowUtc     = [System.DateTime]::UtcNow
    $nowCst     = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $cstZone2)
    $next09     = [System.DateTime]::new($nowCst.Year, $nowCst.Month, $nowCst.Day, 9, 0, 0)
    if ($nowCst -ge $next09) { $next09 = $next09.AddDays(1) }
    $nextRunBj  = $next09.ToString("yyyy-MM-ddTHH:mm:ss") + "+08:00"
} catch {
    $nextRunBj = "(unknown)"
}

$meta = [ordered]@{
    generated_at        = (Get-Date -Format "o")
    timezone            = "Asia/Shanghai"
    daily_time          = "09:00"
    task_name           = $taskName
    installed           = $true
    trigger_time_local  = $triggerTimeStr
    trigger_tz_source   = "China Standard Time -> $(([System.TimeZoneInfo]::Local).Id)"
    last_run            = [ordered]@{
        run_id          = $null
        started_at      = $null
        finished_at     = $null
        status          = "never"
        outputs_written = @()
    }
    next_run_at_beijing = $nextRunBj
    script_path         = $wrapperScript
}
$meta | ConvertTo-Json -Depth 5 | Out-File -FilePath $schedulerMeta -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host "Task '$taskName' registered successfully."
Write-Host "  Scheduler meta: $schedulerMeta"
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
