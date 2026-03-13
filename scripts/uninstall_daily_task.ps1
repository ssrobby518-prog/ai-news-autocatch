# uninstall_daily_task.ps1
# Remove the AIIntelScraper_Daily_0900_BJ scheduled task and update scheduler.meta.json.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\uninstall_daily_task.ps1
# Requires: Administrator privileges

$ErrorActionPreference = "Stop"

$taskName = "AIIntelScraper_Daily_0900_BJ"
$repoRoot = (Split-Path $PSScriptRoot -Parent)
$metaPath = Join-Path $repoRoot "outputs\scheduler.meta.json"

Write-Host "=== Uninstalling Scheduled Task ===" -ForegroundColor Cyan
Write-Host ("  Task Name: {0}" -f $taskName)

$existing = schtasks /Query /TN $taskName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ("  Task '{0}' not found — nothing to remove." -f $taskName) -ForegroundColor Yellow
} else {
    schtasks /Delete /TN $taskName /F | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  Task '{0}' removed." -f $taskName) -ForegroundColor Green
    } else {
        Write-Host ("  ERROR: schtasks /Delete failed (exit {0})." -f $LASTEXITCODE) -ForegroundColor Red
        exit 1
    }
}

# Update scheduler.meta.json: set installed=false
$outDir = Join-Path $repoRoot "outputs"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$existing_meta = $null
if (Test-Path $metaPath) {
    try {
        $existing_meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {}
}

# Compute next 09:00 Beijing for the meta (so gate can read valid next_run after uninstall)
$uninstNextRunBj = ""
try {
    $uninstCz     = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
    $uninstNowCst = [System.TimeZoneInfo]::ConvertTimeFromUtc([System.DateTime]::UtcNow, $uninstCz)
    $uninstT09    = [System.DateTime]::new($uninstNowCst.Year, $uninstNowCst.Month, $uninstNowCst.Day, 9, 0, 0)
    if ($uninstNowCst -ge $uninstT09) { $uninstT09 = $uninstT09.AddDays(1) }
    $uninstNextRunBj = $uninstT09.ToString("yyyy-MM-ddTHH:mm:ss") + "+08:00"
} catch {
    $uninstNextRunBj = "(unknown)"
}

$meta = [ordered]@{
    generated_at         = (Get-Date -Format "o")
    timezone             = "Asia/Shanghai"
    daily_time           = "09:00"
    task_name            = $taskName
    installed            = $false
    trigger_time_local   = if ($existing_meta -and $existing_meta.PSObject.Properties['trigger_time_local']) { $existing_meta.trigger_time_local } else { $null }
    trigger_tz_source    = if ($existing_meta -and $existing_meta.PSObject.Properties['trigger_tz_source'])  { $existing_meta.trigger_tz_source }  else { $null }
    last_run             = if ($existing_meta -and $existing_meta.PSObject.Properties['last_run'])           { $existing_meta.last_run }           else { $null }
    next_run_at_beijing  = $uninstNextRunBj
    script_path          = if ($existing_meta -and $existing_meta.PSObject.Properties['script_path'])        { $existing_meta.script_path }        else { $null }
    uninstalled_at       = (Get-Date -Format "o")
}
$meta | ConvertTo-Json -Depth 3 | Out-File -FilePath $metaPath -Encoding UTF8 -NoNewline
Write-Host ("scheduler.meta.json updated: installed=false" ) -ForegroundColor Green
Write-Host ""
Write-Host "=== Uninstall complete ===" -ForegroundColor Green
