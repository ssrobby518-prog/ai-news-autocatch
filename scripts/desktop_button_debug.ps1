# desktop_button_debug.ps1 — Debug version: verbose errors + window never closes
# Usage (shortcut Target with -NoExit):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File scripts\desktop_button_debug.ps1 -Mode manual
#
# iter45: debug wrapper — $ErrorActionPreference=Stop, full stack on error

param(
    [ValidateSet("manual","daily")]
    [string]$Mode = "manual"
)

$ErrorActionPreference = "Stop"

# --- UTF-8 setup ---
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

# --- Resolve repo root ---
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

# --- Environment: budget + gates ---
$env:PIPELINE_SOFT_TARGET_SEC = "160"
$env:PIPELINE_TIME_BUDGET_SEC = "200"
$env:BIGTECH_GATES_ENFORCE = "1"

# --- Log setup ---
$logDir = Join-Path $repoRoot "outputs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir "desktop_button.log"
$runTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

# --- Log header ---
Add-Content -LiteralPath $logPath -Value "" -Encoding utf8
Add-Content -LiteralPath $logPath -Value ("=" * 72) -Encoding utf8
Write-Log "=== desktop_button_debug.ps1 START (DEBUG MODE) ==="
Write-Log "run_timestamp = $runTs"
Write-Log "Mode          = $Mode"
Write-Log "soft_target   = $($env:PIPELINE_SOFT_TARGET_SEC)s"
Write-Log "hard_budget   = $($env:PIPELINE_TIME_BUDGET_SEC)s"
Write-Log "repo_root     = $repoRoot"
Write-Log "ErrorAction   = Stop (debug)"
Write-Log ""

# --- Run verify_online.ps1 ---
$voScript = Join-Path $repoRoot "scripts\verify_online.ps1"
if (-not (Test-Path $voScript)) {
    Write-Log "FATAL: verify_online.ps1 not found at $voScript"
    Write-Host "Script not found. Window will stay open for inspection."
    return
}

Write-Log "Calling: powershell -NoProfile -ExecutionPolicy Bypass -File `"$voScript`" -Mode $Mode"
Write-Log ""

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$exitCode = 0
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $voScript -Mode $Mode 2>&1 |
        Tee-Object -FilePath $logPath -Append
    $exitCode = $LASTEXITCODE
} catch {
    Write-Log "EXCEPTION: $($_.Exception.Message)"
    Write-Log "STACK TRACE:"
    Write-Log $_.ScriptStackTrace
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
if (Test-Path $lrsPath) {
    $lrsContent = Get-Content $lrsPath -Raw -Encoding UTF8
    Write-Log "--- LAST_RUN_SUMMARY.txt ---"
    foreach ($line in ($lrsContent -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) { Write-Log "  $trimmed" }
        if ($trimmed -match "^status\s*=\s*(.+)") { $status = $Matches[1].Trim() }
        if ($trimmed -match "^fail_reason\s*=\s*(.+)") { $failReason = $Matches[1].Trim() }
    }
    Write-Log "---"
} else {
    Write-Log "WARNING: LAST_RUN_SUMMARY.txt not found"
}

# --- Post-run actions ---
if ($status -eq "OK") {
    $docxPath = Join-Path $repoRoot "outputs\executive_report.docx"
    if (Test-Path $docxPath) {
        Write-Log "STATUS: OK — opening DOCX..."
        Write-Log "DOCX path: $docxPath"
        Start-Process $docxPath
        Write-Log "DOCX opened successfully (Start-Process called)"
    } else {
        Write-Log "STATUS: OK but executive_report.docx not found"
    }
} else {
    Write-Log "STATUS: $status"
    if ($failReason) {
        Write-Log "FAIL REASON: $failReason"
    }
    foreach ($nrf in @("NOT_READY_report.md","NOT_READY_report.docx")) {
        $nrfPath = Join-Path $repoRoot "outputs\$nrf"
        if (Test-Path $nrfPath) {
            Write-Log "  NOT_READY report exists: $nrf"
        }
    }
}

Write-Log ""
Write-Log "=== desktop_button_debug.ps1 END (exit=$exitCode, elapsed=${elapsed}s) ==="

# --- Debug: dump key meta files ---
Write-Host ""
Write-Host "=== DEBUG INFO ==="
foreach ($mf in @("run_timing.meta.json","translation_engine.meta.json","gpu_probe.meta.json","selection_audit.meta.json","digest_density.meta.json")) {
    $mfp = Join-Path $repoRoot "outputs\$mf"
    if (Test-Path $mfp) {
        Write-Host "--- $mf ---"
        Get-Content $mfp -Raw -Encoding UTF8 | Write-Host
    } else {
        Write-Host "--- $mf --- (not found)"
    }
}
Write-Host ""
Write-Host "========================================"
Write-Host "  DEBUG MODE — Window stays open"
Write-Host "  Pipeline status: $status"
if ($failReason) { Write-Host "  Fail reason: $failReason" }
Write-Host "  Elapsed: ${elapsed}s"
Write-Host "  Log: $logPath"
Write-Host "========================================"
Write-Host ""
Write-Host "(Window kept open by -NoExit flag. Close manually.)"
