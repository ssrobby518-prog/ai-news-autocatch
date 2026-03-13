# FILE: scripts\install_daily_task.ps1
# Stage 4 Scheduler — install Windows Task Scheduler entry for AI Intel Scraper.
# Task name : AIIntelScraper_Daily_0900_BJ
# Schedule  : Daily 09:00 Asia/Shanghai; trigger converted to local TZ via .NET TimeZoneInfo
# Action    : powershell.exe -ExecutionPolicy Bypass -File "...\scheduler_wrapper.ps1"
# Writes    : outputs\scheduler.meta.json (installed=true, timezone, daily_time, next_run_at_beijing)
# Usage     : powershell -ExecutionPolicy Bypass -File scripts\install_daily_task.ps1
# Requires  : Administrator privileges (schtasks /Create /RL HIGHEST)
# Idempotent: removes existing task before re-creating

$ErrorActionPreference = "Stop"

$taskName   = "AIIntelScraper_Daily_0900_BJ"
$repoRoot   = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot "scripts\scheduler_wrapper.ps1"
$outDir     = Join-Path $repoRoot "outputs"
$metaPath   = Join-Path $outDir "scheduler.meta.json"

Write-Host "=== Install Daily Scheduled Task (Beijing 09:00) ===" -ForegroundColor Cyan
Write-Host "  Task Name : $taskName"
Write-Host "  Script    : $scriptPath"
Write-Host "  Schedule  : Daily 09:00 Asia/Shanghai (China Standard Time)"
Write-Host ""

if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: Script not found: $scriptPath" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Convert Beijing 09:00 -> local machine time using .NET TimeZoneInfo
# ---------------------------------------------------------------------------
try {
    $cstZone    = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
    $localZone  = [System.TimeZoneInfo]::Local
    # Build CST reference for today at 09:00
    $todayUtc   = [System.DateTime]::UtcNow.Date
    $todayCst   = [System.TimeZoneInfo]::ConvertTimeFromUtc($todayUtc, $cstZone)
    $cst0900    = [System.DateTime]::new($todayCst.Year, $todayCst.Month, $todayCst.Day, 9, 0, 0)
    $local0900  = [System.TimeZoneInfo]::ConvertTime($cst0900, $cstZone, $localZone)
    $triggerTime = $local0900.ToString("HH:mm")
    $localTzId   = $localZone.Id
    Write-Host ("  Beijing 09:00 = local {0} ({1})" -f $triggerTime, $localTzId) -ForegroundColor DarkGray
} catch {
    Write-Host ("  WARN: TZ conversion failed ({0}); falling back to 09:00 local" -f $_) -ForegroundColor Yellow
    $triggerTime = "09:00"
    $localTzId   = "local"
}

# ---------------------------------------------------------------------------
# Remove existing task (idempotent)
# ---------------------------------------------------------------------------
schtasks /Query /TN $taskName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host ("  Removing existing task '{0}'..." -f $taskName) -ForegroundColor Yellow
    schtasks /Delete /TN $taskName /F | Out-Null
    Write-Host "  Removed." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Build action args
# Canonical path: scheduled task -> scheduler_wrapper.ps1 -> verify_online.ps1 -Mode daily
# ---------------------------------------------------------------------------
$scriptAbs = (Resolve-Path $scriptPath).Path
$trAction  = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptAbs`""

Write-Host ("  Creating task DAILY /ST {0} /RL HIGHEST..." -f $triggerTime)

schtasks /Create `
    /TN  $taskName `
    /TR  "`"$trAction`"" `
    /SC  DAILY `
    /ST  $triggerTime `
    /RL  HIGHEST `
    /F

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: schtasks /Create failed (exit $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "  Try running this script as Administrator." -ForegroundColor Yellow
    exit 1
}

Write-Host ("  Task created: '{0}' fires at {1} local" -f $taskName, $triggerTime) -ForegroundColor Green

# ---------------------------------------------------------------------------
# Compute next 09:00 Beijing (ISO-8601 with +08:00 offset)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Write outputs\scheduler.meta.json
# ---------------------------------------------------------------------------
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$meta = [ordered]@{
    generated_at        = (Get-Date -Format "o")
    timezone            = "Asia/Shanghai"
    daily_time          = "09:00"
    task_name           = $taskName
    installed           = $true
    trigger_time_local  = $triggerTime
    trigger_tz_source   = "China Standard Time -> $localTzId"
    last_run            = [ordered]@{
        run_id          = $null
        started_at      = $null
        finished_at     = $null
        status          = "never"
        outputs_written = @()
    }
    next_run_at_beijing = $nextRunBj
    script_path         = $scriptAbs
}
$meta | ConvertTo-Json -Depth 5 | Out-File -FilePath $metaPath -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host ("scheduler.meta.json written: installed=true  timezone=Asia/Shanghai  daily=09:00  next_run={0}" -f $nextRunBj) -ForegroundColor Green
Write-Host ""
Write-Host "=== Task installed successfully ===" -ForegroundColor Green
Write-Host ("  '{0}' fires at {1} local (= 09:00 Beijing)" -f $taskName, $triggerTime)
Write-Host ("  Next run (Beijing): {0}" -f $nextRunBj)
Write-Host ""
Write-Host "  To run now : schtasks /Run /TN $taskName"
Write-Host "  To uninstall: powershell -ExecutionPolicy Bypass -File scripts\uninstall_daily_task.ps1"
Write-Host ""

# ---------------------------------------------------------------------------
# Self-check: verify task was created and show full detail
# ---------------------------------------------------------------------------
Write-Host "=== Self-check: schtasks /Query ===" -ForegroundColor Cyan
schtasks /Query /TN $taskName /V /FO LIST
if ($LASTEXITCODE -ne 0) {
    Write-Host ("WARN: schtasks /Query returned exit {0} — task may not be visible yet." -f $LASTEXITCODE) -ForegroundColor Yellow
} else {
    Write-Host "Self-check: task found in Task Scheduler." -ForegroundColor Green
}
