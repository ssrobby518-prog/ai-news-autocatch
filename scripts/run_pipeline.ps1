# FILE: scripts\run_pipeline.ps1
# Desktop-button entry point ??ALWAYS produces a visible output file.
#
# Success path : updates outputs\executive_report.pptx/.docx ??AutoOpen pptx
# Failure path : generates outputs\NOT_READY_report.pptx/.docx ??AutoOpen that
# Both paths   : write outputs\LAST_RUN_SUMMARY.txt + outputs\desktop_button.last_run.log
#
# Params:
#   -Mode       manual|demo|daily  (default: manual; demo = guaranteed 6-12 AI events for presentations)
#   -ReportMode brief|legacy       (default: brief)
#   -AutoOpen   true|false         (default: true;   pass false for headless/scheduled runs)
param(
    [string]$Mode     = "manual",
    [string]$ReportMode = "brief",
    [string]$AutoOpen = "true"
)
$ErrorActionPreference = 'Continue'   # don't stop on errors ??we handle them explicitly

# ?? Canonical paths (always derived from $PSScriptRoot, never from CWD) ???????
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$OutputsDir = Join-Path $RepoRoot "outputs"
$LogFile    = Join-Path $OutputsDir "desktop_button.last_run.log"
$DocxPath   = Join-Path $OutputsDir "executive_report.docx"
$PptxPath   = Join-Path $OutputsDir "executive_report.pptx"
$NotReadyPath = Join-Path $OutputsDir "NOT_READY.md"
$NotReadyDocxPath = Join-Path $OutputsDir "NOT_READY_report.docx"
$NotReadyPptxPath = Join-Path $OutputsDir "NOT_READY_report.pptx"

if (-not (Test-Path $OutputsDir)) { New-Item -ItemType Directory -Path $OutputsDir | Out-Null }

# ?? Timing ????????????????????????????????????????????????????????????????????
$RunId      = (Get-Date -Format "yyyyMMdd_HHmmss")
$StartObj   = Get-Date
$StartISO   = $StartObj.ToString("o")

# ?? Initialise log (overwrite for each run) ???????????????????????????????????
@"
========================================
 AI Intel Pipeline
 run_id     = $RunId
 mode       = $Mode
 report_mode= $ReportMode
 started_at = $StartISO
========================================
"@ | Out-File $LogFile -Encoding UTF8

Write-Host "=== AI 情資摘要系統  run_id=$RunId ===" -ForegroundColor Cyan

# Snapshot canonical executive artifacts before run so FAIL can never overwrite delivery files.
$ExecSnapshot = @{}
foreach ($Name in @("executive_report.docx", "executive_report.pptx")) {
    $Path = Join-Path $OutputsDir $Name
    $Bak  = Join-Path $OutputsDir (".pre_fail_guard_{0}.bak" -f $Name)
    if (Test-Path $Bak) { Remove-Item $Bak -Force -ErrorAction SilentlyContinue }

    if (Test-Path $Path) {
        $Item = Get-Item $Path
        Copy-Item $Path $Bak -Force
        $ExecSnapshot[$Name] = [ordered]@{
            exists         = $true
            backup         = $Bak
            last_write_utc = $Item.LastWriteTimeUtc
        }
    } else {
        $ExecSnapshot[$Name] = [ordered]@{
            exists         = $false
            backup         = $Bak
            last_write_utc = $null
        }
    }
}

# ?? Locate Python ?????????????????????????????????????????????????????????????
$py = "python"

# ?? Env vars for run_once.py ??????????????????????????????????????????????????
$env:PIPELINE_RUN_ID       = $RunId
$env:PIPELINE_TRIGGERED_BY = "run_pipeline.ps1"
$env:PIPELINE_MODE         = $Mode
$env:PIPELINE_REPORT_MODE  = $ReportMode

# ?? Run pipeline ??tee stdout+stderr to log AND console ??????????????????????
Set-Location $RepoRoot
Write-Host "[1/3] 透過 verify_online.ps1 執行 Pipeline（GPU 前置檢查 + Z0 收集 + 所有關卡）..." -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\verify_online.ps1" -Mode $Mode 2>&1 | Tee-Object -FilePath $LogFile -Append
$ExitCode = $LASTEXITCODE

$env:PIPELINE_RUN_ID       = $null
$env:PIPELINE_TRIGGERED_BY = $null
$env:PIPELINE_MODE         = $null
$env:PIPELINE_REPORT_MODE  = $null

$FinishObj  = Get-Date
$FinishISO  = $FinishObj.ToString("o")
"pipeline exit_code=$ExitCode  finished_at=$FinishISO" | Add-Content $LogFile -Encoding UTF8

# ?? Evaluate success ??????????????????????????????????????????????????????????
$NotReadyExists = Test-Path $NotReadyPath
$DocxUpdated    = (Test-Path $DocxPath) -and ((Get-Item $DocxPath).LastWriteTime -gt $StartObj)
$PptxUpdated    = (Test-Path $PptxPath) -and ((Get-Item $PptxPath).LastWriteTime -gt $StartObj)

# DoD-1: OK requires showcase_ready=true (ai_selected_events >= threshold) in showcase_ready.meta.json
$ShowcaseMetaPath = Join-Path $OutputsDir "showcase_ready.meta.json"
$ShowcaseReady    = $false
$AiSelectedEvents = 0
$SelectedEvents   = 0
$ShowcaseThreshold = 6
if (Test-Path $ShowcaseMetaPath) {
    try {
        $srMeta = Get-Content $ShowcaseMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ShowcaseReady    = [bool]($srMeta.PSObject.Properties["showcase_ready"] -and $srMeta.showcase_ready)
        $AiSelectedEvents = if ($srMeta.PSObject.Properties["ai_selected_events"]) { [int]$srMeta.ai_selected_events } else { 0 }
        $SelectedEvents   = if ($srMeta.PSObject.Properties["selected_events"])    { [int]$srMeta.selected_events }    else { $AiSelectedEvents }
        $ShowcaseThreshold = if ($srMeta.PSObject.Properties["threshold"]) { [int]$srMeta.threshold } else { 6 }
    } catch { $ShowcaseReady = $false }
}

$IsSuccess = ($ExitCode -eq 0) -and (-not $NotReadyExists) -and $DocxUpdated -and $PptxUpdated -and $ShowcaseReady

"success_eval: IsSuccess=$IsSuccess NotReadyExists=$NotReadyExists DocxUpdated=$DocxUpdated PptxUpdated=$PptxUpdated ShowcaseReady=$ShowcaseReady AiSelectedEvents=$AiSelectedEvents ExitCode=$ExitCode" |
    Add-Content $LogFile -Encoding UTF8

# Hard fail-guard: when run is FAIL, never leave updated canonical executive artifacts behind.
if (-not $IsSuccess) {
    foreach ($Name in @("executive_report.docx", "executive_report.pptx")) {
        $Path = Join-Path $OutputsDir $Name
        $Snap = $ExecSnapshot[$Name]
        if ($null -eq $Snap) { continue }

        if ([bool]$Snap.exists) {
            if (Test-Path $Snap.backup) {
                Copy-Item $Snap.backup $Path -Force
                if ($Snap.last_write_utc) {
                    try {
                        (Get-Item $Path).LastWriteTimeUtc = [datetime]$Snap.last_write_utc
                    } catch {}
                }
            }
        } else {
            if (Test-Path $Path) {
                Remove-Item $Path -Force -ErrorAction SilentlyContinue
            }
        }
    }
    "fail_guard: canonical executive_report artifacts restored to pre-run state" |
        Add-Content $LogFile -Encoding UTF8
}

# ?? Determine fail reason (human-readable one-liner) ?????????????????????????
$FailReason = ""
$_canonicalGates = @("SERVER_NOT_READY","GPU_NOT_ACTIVE","TRANSLATION_ENGINE_DOWN","TIME_BUDGET_EXCEEDED")
if (-not $IsSuccess) {
    if ($NotReadyExists) {
        try {
            $nrRaw = Get-Content $NotReadyPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
            # Extract gate: XYZ line and map to canonical fail_reason
            if ($nrRaw -match '(?m)^gate:\s*(\S+)') {
                $_gateVal = $Matches[1].Trim()
                if ($_gateVal -eq "TRANSLATION_DELIVERY_HARD") { $_gateVal = "TRANSLATION_ENGINE_DOWN" }
                if ($_canonicalGates -contains $_gateVal) {
                    $FailReason = $_gateVal
                } else {
                    $FailReason = "PIPELINE_GATE_FAIL: $_gateVal"
                }
            } else {
                $FailReason = ($nrRaw -replace '[\r\n\s]+', ' ').Trim()
                if ($FailReason.Length -gt 200) { $FailReason = $FailReason.Substring(0,200) }
            }
        } catch { $FailReason = "PIPELINE_GATE_FAIL: NOT_READY.md exists (read error)" }
    }
    if (-not $FailReason -and -not $ShowcaseReady) {
        $FailReason = "PIPELINE_GATE_FAIL: EXEC_NEWS_QUALITY ai_selected_events=$AiSelectedEvents < $ShowcaseThreshold"
    }
    if (-not $FailReason) {
        if ($ExitCode -ne 0) {
            $FailReason = "PIPELINE_GATE_FAIL: exit_code=$ExitCode"
        } elseif (-not $PptxUpdated -and -not $DocxUpdated) {
            $FailReason = "PIPELINE_GATE_FAIL: executive_report not updated"
        } elseif (-not $PptxUpdated) {
            $FailReason = "PIPELINE_GATE_FAIL: executive_report.pptx not updated"
        } else {
            $FailReason = "PIPELINE_GATE_FAIL: executive_report.docx not updated"
        }
    }
}

# ?? Generate NOT_READY_report if failure ?????????????????????????????????????
if (-not $IsSuccess) {
    Write-Host "[2/3] 偵測到失敗 — 產生 NOT_READY 報告中..." -ForegroundColor Red
    "generating NOT_READY_report..." | Add-Content $LogFile -Encoding UTF8
    $nrOut = & $py "$RepoRoot\scripts\run_once.py" --not-ready-report 2>&1
    $nrOut | ForEach-Object {
        $_ | Add-Content $LogFile -Encoding UTF8
        Write-Host "  [report] $_" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "[2/3] 成功 — 輸出已更新。" -ForegroundColor Green
}

# ?? Collect produced files for summary ???????????????????????????????????????
$ProducedList = @()
if ($IsSuccess) {
    foreach ($Name in @("latest_brief.md", "executive_report.docx", "executive_report.pptx")) {
        if (Test-Path (Join-Path $OutputsDir $Name)) {
            $ProducedList += "outputs\$Name"
        }
    }
} else {
    foreach ($Name in @("NOT_READY_report.md", "NOT_READY_report.docx", "NOT_READY_report.pptx")) {
        if (Test-Path (Join-Path $OutputsDir $Name)) {
            $ProducedList += "outputs\$Name"
        }
    }
}
$ProducedStr  = if ($ProducedList) { $ProducedList -join ", " } else { "(none)" }

# cleanup temporary backups
foreach ($Name in @("executive_report.docx", "executive_report.pptx")) {
    $Bak = Join-Path $OutputsDir (".pre_fail_guard_{0}.bak" -f $Name)
    if (Test-Path $Bak) { Remove-Item $Bak -Force -ErrorAction SilentlyContinue }
}

# ?? Write LAST_RUN_SUMMARY.txt (always, human-readable) ??????????????????????
Write-Host "[3/3] 寫入 LAST_RUN_SUMMARY.txt..." -ForegroundColor Yellow
$StatusStr   = if ($IsSuccess) { "OK" } else { "FAIL" }
$FailLine    = if (-not $IsSuccess) { "`nfail_reason         = $FailReason" } else { "" }
$SummaryTxt  = @"
run_id              = $RunId
started_at          = $StartISO
finished_at         = $FinishISO
mode                = $Mode
report_mode         = $ReportMode
status              = $StatusStr
selected_events     = $SelectedEvents
ai_selected_events  = $AiSelectedEvents
canonical_output_dir = outputs\nproduced_files      = $ProducedStr$FailLine
"@
$SummaryPath = Join-Path $OutputsDir "LAST_RUN_SUMMARY.txt"
$SummaryTxt | Out-File $SummaryPath -Encoding UTF8 -NoNewline
"LAST_RUN_SUMMARY.txt written: status=$StatusStr" | Add-Content $LogFile -Encoding UTF8
Write-Host "LAST_RUN_SUMMARY.txt: status=$StatusStr" -ForegroundColor $(if ($IsSuccess) { "Green" } else { "Red" })

# ?? Write desktop_button.meta.json (backward-compat JSON for other scripts) ??
$MetaPath = Join-Path $OutputsDir "desktop_button.meta.json"
[ordered]@{
    run_id       = $RunId
    started_at   = $StartISO
    finished_at  = $FinishISO
    exit_code    = $ExitCode
    success      = [bool]$IsSuccess
    pipeline     = "scripts/run_once.py"
    triggered_by = "run_pipeline.ps1"
} | ConvertTo-Json -Depth 3 | Out-File $MetaPath -Encoding UTF8 -NoNewline

# ?? Write delivery_path.meta.json (backward-compat for open_latest.ps1) ???????
$CanonicalPptx     = Join-Path $RepoRoot "outputs\executive_report.pptx"
$CanonicalPptxHash = $null
if (Test-Path $CanonicalPptx) {
    try { $CanonicalPptxHash = (Get-FileHash -Path $CanonicalPptx -Algorithm SHA256).Hash } catch {}
}
$DeliveryMetaPath = Join-Path $OutputsDir "delivery_path.meta.json"
[ordered]@{
    run_id               = $RunId
    canonical_pptx_path  = $CanonicalPptx
    canonical_pptx_hash  = $CanonicalPptxHash
    autoopen_target_path = $CanonicalPptx
    started_at           = $StartISO
    finished_at          = $FinishISO
} | ConvertTo-Json -Depth 3 | Out-File $DeliveryMetaPath -Encoding UTF8 -NoNewline

# ?? AutoOpen ??ALWAYS opens something visible ?????????????????????????????????
if ($AutoOpen -ne "false") {
    if ($IsSuccess) {
        $OpenTarget = $PptxPath
    } else {
        $NrPptx = Join-Path $OutputsDir "NOT_READY_report.pptx"
        $NrDocx = Join-Path $OutputsDir "NOT_READY_report.docx"
        if    (Test-Path $NrPptx) { $OpenTarget = $NrPptx }
        elseif (Test-Path $NrDocx) { $OpenTarget = $NrDocx }
        else  { $OpenTarget = $null }
    }

    if ($OpenTarget -and (Test-Path $OpenTarget)) {
        Write-Host "AutoOpen ??$OpenTarget" -ForegroundColor Cyan
        "autoopen: $OpenTarget" | Add-Content $LogFile -Encoding UTF8
        Start-Process $OpenTarget
    } else {
        Write-Host "AutoOpen: no file to open (report generation may have failed)" -ForegroundColor Red
        "autoopen: none (no file found)" | Add-Content $LogFile -Encoding UTF8
    }
} else {
    "autoopen: suppressed (AutoOpen=false)" | Add-Content $LogFile -Encoding UTF8
}

Write-Host "=== 完成：run_id=$RunId  status=$StatusStr ===" -ForegroundColor $(if ($IsSuccess) { "Green" } else { "Red" })
exit $ExitCode
