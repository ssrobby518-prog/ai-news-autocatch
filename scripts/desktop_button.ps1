# desktop_button.ps1 — One-click desktop wrapper for ai-intel-scraper-mvp pipeline
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\desktop_button.ps1 -Mode manual
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\desktop_button.ps1 -Mode daily
#
# iter45: desktop button wrapper with logging, auto-open DOCX, and window persistence
# iter66: P0 fingerprint (RUN_ID, GIT_HEAD, ENTRYPOINT, DOMAIN_COUNTS, MAX_DOMAIN_SHARE, DENSITY_MULTIPLIER_TARGET)

param(
    [ValidateSet("daily")]
    [string]$Mode = "daily"
)

$ErrorActionPreference = "Continue"

# --- UTF-8 setup ---
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

# --- Resolve repo root ---
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

# --- Environment: budget + gates + entrypoint ---
$env:PIPELINE_SOFT_TARGET_SEC = "140"   # iter73: optimization target soft
$env:PIPELINE_TIME_BUDGET_SEC = "230"   # iter73b: align with verify_online DAILY default (10 items need ~200s all-miss)
# Enable bigtech gates for both manual and daily (bigtech>=5, official_or_media>=4)
$env:BIGTECH_GATES_ENFORCE = "1"
# iter72c: always force entrypoint (was conditional; child powershell needs explicit env)
$env:PIPELINE_ENTRYPOINT = "desktop_button"

# --- Log setup ---
$logDir = Join-Path $repoRoot "outputs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir "desktop_button.log"
$runTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# --- Tee helper: write to both console and log ---
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

# --- P0 fingerprint ---
$gitHead = "unknown"
try { $gitHead = (git rev-parse --short HEAD 2>$null) } catch {}

Add-Content -LiteralPath $logPath -Value "" -Encoding utf8
Add-Content -LiteralPath $logPath -Value ("=" * 72) -Encoding utf8
Write-Log "=== desktop_button.ps1 START ==="
Write-Log "run_timestamp           = $runTs"
Write-Log "Mode                    = $Mode"
Write-Log "ENTRYPOINT              = $($env:PIPELINE_ENTRYPOINT)"
Write-Log "GIT_HEAD                = $gitHead"
Write-Log "DENSITY_MULTIPLIER_TARGET = 1.5"
Write-Log "soft_target             = $($env:PIPELINE_SOFT_TARGET_SEC)s"
Write-Log "hard_budget             = $($env:PIPELINE_TIME_BUDGET_SEC)s"
Write-Log "repo_root               = $repoRoot"
Write-Log ""

# --- Run verify_online.ps1 ---
$voScript = Join-Path $repoRoot "scripts\verify_online.ps1"
if (-not (Test-Path $voScript)) {
    Write-Log "ERROR: verify_online.ps1 not found at $voScript"
    Read-Host "Press Enter to close / 按 Enter 關閉"
    exit 1
}

Write-Log "Calling: powershell -NoProfile -ExecutionPolicy Bypass -File `"$voScript`" -Mode $Mode"
Write-Log ""

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # Use & operator to capture all output; Tee-Object sends to both console and log
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $voScript -Mode $Mode 2>&1 |
        Tee-Object -FilePath $logPath -Append
    $exitCode = $LASTEXITCODE
} catch {
    Write-Log "EXCEPTION during pipeline: $_"
    $exitCode = 99
}
$sw.Stop()
$elapsed = [int]$sw.Elapsed.TotalSeconds

Write-Log ""
Write-Log "Pipeline exited with code: $exitCode (elapsed: ${elapsed}s)"

# --- Read LAST_RUN_SUMMARY.txt ---
$lrsPath = Join-Path $repoRoot "outputs\LAST_RUN_SUMMARY.txt"
$status = "UNKNOWN"
$failReason = ""
$runId = "unknown"
if (Test-Path $lrsPath) {
    $lrsContent = Get-Content $lrsPath -Raw -Encoding UTF8
    Write-Log "--- LAST_RUN_SUMMARY.txt ---"
    foreach ($line in ($lrsContent -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) { Write-Log "  $trimmed" }
        if ($trimmed -match "^status\s*=\s*(.+)") { $status = $Matches[1].Trim() }
        if ($trimmed -match "^fail_reason\s*=\s*(.+)") { $failReason = $Matches[1].Trim() }
        if ($trimmed -match "^run_id\s*=\s*(.+)") { $runId = $Matches[1].Trim() }
    }
    Write-Log "---"
} else {
    Write-Log "WARNING: LAST_RUN_SUMMARY.txt not found"
}

# --- P0 fingerprint: read domain/density meta ---
Write-Log ""
Write-Log "=== P0 FINGERPRINT ==="
Write-Log "RUN_ID                  = $runId"
Write-Log "GIT_HEAD                = $gitHead"
Write-Log "ENTRYPOINT              = $($env:PIPELINE_ENTRYPOINT)"
Write-Log "DENSITY_MULTIPLIER_TARGET = 1.5"

# Domain counts from bigtech_diversity.meta.json
$bdmPath = Join-Path $repoRoot "outputs\bigtech_diversity.meta.json"
if (Test-Path $bdmPath) {
    try {
        $bdmMeta = Get-Content $bdmPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $domCounts = $bdmMeta.domain_counts
        $maxDom = if ($bdmMeta.PSObject.Properties['max_domain_count']) { [int]$bdmMeta.max_domain_count } else { 0 }
        $selEv = if ($bdmMeta.PSObject.Properties['selected_events']) { [int]$bdmMeta.selected_events } else { 7 }
        $domShare = if ($selEv -gt 0) { [math]::Round($maxDom / $selEv, 4) } else { 0 }
        Write-Log "DOMAIN_COUNTS           = $($domCounts | ConvertTo-Json -Compress)"
        Write-Log "MAX_DOMAIN_SHARE        = $maxDom / $selEv = $domShare"
    } catch {
        Write-Log "DOMAIN_COUNTS           = (parse error)"
    }
} else {
    Write-Log "DOMAIN_COUNTS           = (bigtech_diversity.meta.json not found)"
}

# Density from source_density.meta.json
$sdmPath = Join-Path $repoRoot "outputs\source_density.meta.json"
if (Test-Path $sdmPath) {
    try {
        $sdmMeta = Get-Content $sdmPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sdmAvg = if ($sdmMeta.PSObject.Properties['selected_avg_density_score']) { $sdmMeta.selected_avg_density_score } else { "N/A" }
        $sdmMin = if ($sdmMeta.PSObject.Properties['selected_min_density_score']) { $sdmMeta.selected_min_density_score } else { "N/A" }
        $sdmNew = if ($sdmMeta.PSObject.Properties['new_density_min']) { $sdmMeta.new_density_min } else { "N/A" }
        Write-Log "DENSITY_AVG             = $sdmAvg"
        Write-Log "DENSITY_MIN             = $sdmMin"
        Write-Log "DENSITY_THRESHOLD(1.5x) = $sdmNew"
    } catch {
        Write-Log "DENSITY                 = (parse error)"
    }
} else {
    Write-Log "DENSITY                 = (source_density.meta.json not found)"
}

# iter72b: strategic fields from content_mix.meta.json + source_density.meta.json
$cmPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
if (Test-Path $cmPath) {
    try {
        $cmMeta = Get-Content $cmPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log "selected_events         = $(if ($cmMeta.PSObject.Properties['selected_events']) { $cmMeta.selected_events } else { 'N/A' })"
        Write-Log "bigtech_actionable_count = $(if ($cmMeta.PSObject.Properties['bigtech_actionable_count']) { $cmMeta.bigtech_actionable_count } else { 'N/A' })"
        Write-Log "bigtech_official_media_count = $(if ($cmMeta.PSObject.Properties['bigtech_official_media_count']) { $cmMeta.bigtech_official_media_count } else { 'N/A' })"
        Write-Log "leadership_politics_ai_count = $(if ($cmMeta.PSObject.Properties['leadership_politics_ai_count']) { $cmMeta.leadership_politics_ai_count } else { 'N/A' })"
        Write-Log "china_ai_gov_count      = $(if ($cmMeta.PSObject.Properties['china_ai_gov_count']) { $cmMeta.china_ai_gov_count } else { 'N/A' })"
        Write-Log "platform_total          = $(if ($cmMeta.PSObject.Properties['platform_total']) { $cmMeta.platform_total } else { 'N/A' })"
        Write-Log "research_tutorial_total  = $(if ($cmMeta.PSObject.Properties['research_tutorial_total']) { $cmMeta.research_tutorial_total } else { 'N/A' })"
        Write-Log "google_research_total    = $(if ($cmMeta.PSObject.Properties['google_research_total']) { $cmMeta.google_research_total } else { 'N/A' })"
        Write-Log "strategic_buckets_distinct = $(if ($cmMeta.PSObject.Properties['selected_strategic_buckets_distinct']) { $cmMeta.selected_strategic_buckets_distinct } else { 'N/A' })"
    } catch {}
}
if (Test-Path $sdmPath) {
    try {
        $sdmMeta2 = Get-Content $sdmPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log "strategic_density_target_avg = $(if ($sdmMeta2.PSObject.Properties['target_avg_density_1p5']) { $sdmMeta2.target_avg_density_1p5 } else { 'N/A' })"
        Write-Log "strategic_density_target_min = $(if ($sdmMeta2.PSObject.Properties['target_min_density_1p5']) { $sdmMeta2.target_min_density_1p5 } else { 'N/A' })"
        Write-Log "selected_avg_strategic_density = $(if ($sdmMeta2.PSObject.Properties['selected_avg_strategic_density_score']) { $sdmMeta2.selected_avg_strategic_density_score } else { 'N/A' })"
        Write-Log "selected_min_strategic_density = $(if ($sdmMeta2.PSObject.Properties['selected_min_strategic_density_score']) { $sdmMeta2.selected_min_strategic_density_score } else { 'N/A' })"
    } catch {}
}
# iter76: overlap policy fields
$saPath = Join-Path $repoRoot "outputs\selection_audit.meta.json"
if (Test-Path $saPath) {
    try {
        $saMeta = Get-Content $saPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log "OVERLAP_POLICY          = $(if ($saMeta.PSObject.Properties['overlap_policy']) { $saMeta.overlap_policy } else { 'N/A' })"
        Write-Log "DAILY_DUP_GATE_ENABLED  = $(if ($saMeta.PSObject.Properties['daily_dup_gate_enabled']) { $saMeta.daily_dup_gate_enabled } else { 'N/A' })"
        Write-Log "DAILY_LAST_IDS_READ     = $(if ($saMeta.PSObject.Properties['daily_last_ids_read']) { $saMeta.daily_last_ids_read } else { 'N/A' })"
        Write-Log "DAILY_LAST_IDS_WRITTEN  = $(if ($saMeta.PSObject.Properties['daily_dup_gate_enabled'] -and $saMeta.daily_dup_gate_enabled -eq $true -and $status -eq 'OK') { 'true' } else { 'false' })"
    } catch {}
}
Write-Log "=== END P0 FINGERPRINT ==="
Write-Log ""

# --- Post-run actions ---
if ($status -eq "OK") {
    $docxPath = Join-Path $repoRoot "outputs\executive_report.docx"
    if (Test-Path $docxPath) {
        Write-Log "STATUS: OK — opening DOCX..."
        Write-Log "DOCX path: $docxPath"
        Start-Process $docxPath
        Write-Log "DOCX opened successfully (Start-Process called)"
    } else {
        Write-Log "STATUS: OK but executive_report.docx not found at $docxPath"
    }
} else {
    Write-Log "STATUS: $status"
    if ($failReason) {
        Write-Log "FAIL REASON: $failReason"
    }
    # Check for NOT_READY reports
    foreach ($nrf in @("NOT_READY_report.md","NOT_READY_report.docx")) {
        $nrfPath = Join-Path $repoRoot "outputs\$nrf"
        if (Test-Path $nrfPath) {
            Write-Log "  NOT_READY report exists: $nrf"
        }
    }
}

Write-Log ""
Write-Log "=== desktop_button.ps1 END (exit=$exitCode, elapsed=${elapsed}s) ==="
Write-Log ""

# --- Keep window open ---
Write-Host ""
Write-Host "========================================"
Write-Host "  Pipeline complete. Status: $status"
if ($failReason) { Write-Host "  Fail reason: $failReason" }
Write-Host "  Elapsed: ${elapsed}s"
Write-Host "  Log: $logPath"
Write-Host "========================================"
Write-Host ""
Read-Host "Press Enter to close / 按 Enter 關閉"
exit $exitCode
