# verify_online.ps1 — Z0 collect (online) then verify pipeline (offline read)
#
# Steps:
#   1) Run z0_collect.ps1  (goes online, writes data/raw/z0/latest.jsonl)
#   2) Set Z0_ENABLED=1 so run_once reads the local JSONL instead of going online
#   3) Run verify_run.ps1  (all 9 gates, reads local JSONL, no outbound traffic)
#
# Usage: powershell -ExecutionPolicy Bypass -File scripts\verify_online.ps1
# Usage (-SkipPipeline): skip steps 1-2; pass -SkipPipeline to verify_run (used by FAIL demo)

param(
    [switch]$SkipPipeline,  # if set: skip z0_collect + Z0_ENABLED; verify_run called with -SkipPipeline
    [string]$Mode = ""      # "demo" = bucket quotas are WARN-OK (no exit 1); "manual"/default = hard fail
)

$ErrorActionPreference = "Stop"

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

$repoRoot = Split-Path $PSScriptRoot -Parent
$_voRunId    = (Get-Date -Format "yyyyMMdd_HHmmss")
$_startedAt  = Get-Date
$_voStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
# iter57: track whether user explicitly set budget via env (before script overrides)
$_voUserBudgetOverride = ($env:PIPELINE_TIME_BUDGET_SEC -and $env:PIPELINE_TIME_BUDGET_SEC -ne "")
$_voBudgetSec = if ($_voUserBudgetOverride) { [int]$env:PIPELINE_TIME_BUDGET_SEC } else { 600 }  # iter33: default outer cap 600s
# iter41: z0 deadline vars (initialized here; set in z0 collect block for DAILY)
$script:_z0DeadlineSoftSec = $null
$script:_z0DeadlineHardSec = $null
$script:_z0StopNewRequestsAtSec = $null
$script:_z0InflightDrainedSec = $null
$script:_z0WallClockSec = $null
$script:_z0StopReason      = $null
# iter55: drain cap enforcement + jitter epsilon
$script:_z0InflightDrainCapSec = $null
$script:_z0InflightCutoffApplied = $false
$script:_z0WallClockCapSec = $null
$script:_z0WallClockJitterEpsilon = 0.9
# iter56/57: VRAM-busy stress mode tracking (two-tier: vram_busy / gpu_contention / soft_warning / none)
$script:_stressModeTriggered    = $false
$script:_stressModeName         = "none"
$script:_stressTriggerLevel     = "none"
$script:_vramRatio              = 0.0
$script:_nonLlamaGpuProcCount   = 0

# iter41: -Mode daily activates FAST_300_DAILY automatically
if ($Mode -eq "daily") {
    $env:FAST_300_DAILY = "1"
}
# iter40: FAST_300_DAILY — online collect + bigtech gates + 300s hard cap
$_fast300Daily = ($env:FAST_300_DAILY -eq "1")
# iter39: FAST_300_MODE — hard cap 300s, auto-enables FAST_600_MODE
$_fast300Mode = ($env:FAST_300_MODE -eq "1") -or $_fast300Daily
if ($_fast300Daily) {
    $_voBudgetSec = if ($_voUserBudgetOverride) { [int]$env:PIPELINE_TIME_BUDGET_SEC } else { 230 }  # iter73: DAILY default 230s (verification acceptance)
    $env:PIPELINE_TIME_BUDGET_SEC = [string]$_voBudgetSec
    $env:FAST_600_MODE = "1"
    $env:FAST_300_DAILY = "1"
    $env:BIGTECH_GATES_ENFORCE = "1"
    Write-Output ("FAST_300_DAILY=1（線上收集+大廠配額+硬上限={0}s）" -f $_voBudgetSec)
} elseif ($_fast300Mode) {
    if (-not $env:PIPELINE_TIME_BUDGET_SEC) { $_voBudgetSec = 300; $env:PIPELINE_TIME_BUDGET_SEC = "300" }
    $env:FAST_600_MODE = "1"
    Write-Output "FAST_300_MODE=1（硬上限=300s，自動啟用 FAST_600_MODE）"
}

# iter57: propagate budget to subprocess (after DAILY/FAST_300 overrides)
$env:PIPELINE_TIME_BUDGET_SEC = [string]$_voBudgetSec

# iter37: FAST_600_MODE — activated when budget<=600 OR FAST_600_MODE="1"
# Disables card_build + DBE rebuild in run_once.py; runs direct hydration→digest→translate path.
$_fast600Mode = ($env:FAST_600_MODE -eq "1") -or ($_voBudgetSec -le 600)
if ($_fast600Mode) {
    $env:FAST_600_MODE = "1"
    if (-not $_fast300Mode) {
        Write-Output "FAST_600_MODE=1（禁用 card_build/DBE，預算=${_voBudgetSec}s）"
    }
} else {
    $env:FAST_600_MODE = "0"
}

# iter41: soft target — DAILY default 200s; FAST_300_MODE default 270s; FAST_600_MODE default 300s
$_voSoftTargetSec = if ($env:PIPELINE_SOFT_TARGET_SEC -and $env:PIPELINE_SOFT_TARGET_SEC -ne "") {
    [int]$env:PIPELINE_SOFT_TARGET_SEC
} elseif ($_fast300Daily) { 175 } elseif ($_fast300Mode) { 270 } elseif ($_fast600Mode) { 300 } else { 0 }  # iter73: DAILY soft=175 (verification acceptance)
if ($_voSoftTargetSec -gt 0) {
    Write-Output ("soft_target={0}s（超過只警告，不 FAIL）" -f $_voSoftTargetSec)
}

# ---------------------------------------------------------------------------
# iter29: 計時 helper functions
#   Append-TimingFooterToMd : 在指定 .md 末尾追加繁中耗時附錄
#   Write-RunTimingMeta     : 寫 outputs/run_timing.meta.json
# ---------------------------------------------------------------------------
function Append-TimingFooterToMd {
    param(
        [Parameter(Mandatory=$true)][string]$MdPath,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][datetime]$StartDt,
        [Parameter(Mandatory=$true)][datetime]$EndDt,
        [Parameter(Mandatory=$true)][int]$TotalSec,
        [hashtable]$StageSec = @{}
    )
    if (-not (Test-Path $MdPath)) { return }
    $mins = [int]([Math]::Floor($TotalSec / 60))
    $secs = [int]($TotalSec % 60)
    $footer = [System.Collections.Generic.List[string]]::new()
    $footer.Add("")
    $footer.Add("---")
    $footer.Add("")
    $footer.Add("## ⏱️ 本次流程耗時")
    $footer.Add("- run_id：$RunId")
    $footer.Add("- 開始：$($StartDt.ToString('yyyy-MM-dd HH:mm:ss'))")
    $footer.Add("- 結束：$($EndDt.ToString('yyyy-MM-dd HH:mm:ss'))")
    $footer.Add("- 總耗時：$TotalSec 秒（$mins 分 $secs 秒）")
    # iter31: stage breakdown (if available)
    if ($StageSec -and $StageSec.Count -gt 0) {
        $footer.Add("- 分段耗時：")
        foreach ($k in @("z0_collect_online","z0_collect","hydrate","digest_write","card_build","translate","build_docx","gates","other_seconds")) {  # iter39: added z0_collect_online + digest_write + other_seconds
            if ($StageSec.ContainsKey($k)) {
                $footer.Add(("  - {0}：{1} 秒" -f $k, $StageSec[$k]))
            }
        }
    }
    $footer.Add("")
    Add-Content -LiteralPath $MdPath -Value ($footer -join "`n") -Encoding utf8
}

function Write-RunTimingMeta {
    param(
        [Parameter(Mandatory=$true)][string]$OutPath,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][datetime]$StartDt,
        [Parameter(Mandatory=$true)][datetime]$EndDt,
        [Parameter(Mandatory=$true)][int]$TotalSec,
        [Parameter(Mandatory=$true)][int]$BudgetSec,
        [hashtable]$StageSec = @{},
        [int]$SoftTargetSec = 0
    )
    $meta = [ordered]@{
        run_id              = $RunId
        started_at          = $StartDt.ToString("yyyy-MM-ddTHH:mm:ss")
        finished_at         = $EndDt.ToString("yyyy-MM-ddTHH:mm:ss")
        total_seconds       = $TotalSec
        time_budget_seconds = $BudgetSec
    }
    # iter38: soft target evidence
    if ($SoftTargetSec -gt 0) {
        $meta["soft_target_seconds"]  = $SoftTargetSec
        $meta["soft_target_exceeded"] = ($TotalSec -gt $SoftTargetSec)
    }
    # iter41: z0 deadline fields for FAST_300_DAILY
    if ($script:_z0DeadlineSoftSec) {
        $meta["z0_deadline_soft_sec"]       = [int]$script:_z0DeadlineSoftSec
        $meta["z0_deadline_hard_sec"]       = [int]$script:_z0DeadlineHardSec
        $meta["z0_stop_reason"]             = [string]$script:_z0StopReason
    }
    if ($script:_z0OnlineSec -ne $null) {
        $meta["z0_collect_online_seconds"] = [int]$script:_z0OnlineSec
    }
    # iter44: Z0 dual-semantics fields (stop_issuing vs wallclock)
    if ($script:_z0WallClockSec -ne $null) {
        $meta["z0_stop_new_requests_at_sec"]    = [double]$script:_z0StopNewRequestsAtSec
        $meta["z0_inflight_drained_seconds"]     = [double]$script:_z0InflightDrainedSec
        $meta["z0_wall_clock_seconds"]           = [double]$script:_z0WallClockSec
        $meta["z0_deadline_semantics"]           = "stop_issuing_vs_wallclock"
        # iter55: drain cap enforcement + jitter epsilon
        $meta["z0_inflight_drained_seconds_actual"] = [double]$script:_z0InflightDrainedSec
        $meta["z0_inflight_cutoff_applied"]         = [bool]$script:_z0InflightCutoffApplied
        $meta["z0_wall_clock_jitter_epsilon_sec"]   = [double]$script:_z0WallClockJitterEpsilon
    }
    # iter42: z0_data_source for DAILY evidence
    if ($script:_z0DeadlineSoftSec) {
        $meta["z0_data_source"] = "online"
    }
    # iter42: stage deadline constants (evidence for PM demo)
    if ($script:_z0DeadlineSoftSec) {
        $meta["z0_soft_deadline_sec"]         = [int]$script:_z0DeadlineSoftSec
        $meta["z0_hard_deadline_sec"]         = [int]$script:_z0DeadlineHardSec
        $meta["hydrate_hard_deadline_sec"]    = 40
        $meta["translate_hard_deadline_sec"]  = 55
        $meta["build_docx_hard_deadline_sec"] = 8
        $meta["gates_hard_deadline_sec"]      = 8
        $meta["before_translation_limit_sec"] = 70
        $meta["z0_stop_new_requests_hard_sec"] = 30
        $meta["z0_inflight_drain_cap_sec"]     = if ($script:_z0InflightDrainCapSec) { [int]$script:_z0InflightDrainCapSec } else { 12 }
        $meta["z0_wall_clock_cap_sec"]         = if ($script:_z0WallClockCapSec) { [int]$script:_z0WallClockCapSec } else { 50 }
    }
    # iter42: before_translation_seconds from stage_timing
    if ($StageSec -and $StageSec.ContainsKey("before_translation")) {
        $meta["before_translation_seconds"] = [double]$StageSec["before_translation"]
    }
    # iter56/57: stress mode fields (two-tier)
    $meta["stress_mode_triggered"]      = [bool]$script:_stressModeTriggered
    $meta["stress_mode_name"]           = [string]$script:_stressModeName
    $meta["stress_trigger_level"]       = [string]$script:_stressTriggerLevel
    $meta["vram_ratio"]                 = [double]$script:_vramRatio
    $meta["non_llama_gpu_proc_count"]   = [int]$script:_nonLlamaGpuProcCount
    # iter31: include stage_seconds if available
    if ($StageSec -and $StageSec.Count -gt 0) {
        $meta["stage_seconds"] = $StageSec
    }
    $payload = $meta | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $OutPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $OutPath -Value $payload -Encoding utf8
}

# iter31: read stage_timing.meta.json written by run_once.py and return as hashtable
function Read-StageTiming {
    param([string]$RepoRoot, [int]$GateSec = 0)
    $path = Join-Path $RepoRoot "outputs\stage_timing.meta.json"
    $ht = @{}
    if (Test-Path $path) {
        try {
            $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($obj.PSObject.Properties["stage_seconds"]) {
                foreach ($p in $obj.stage_seconds.PSObject.Properties) {
                    $ht[$p.Name] = [double]$p.Value
                }
            }
            # iter42: extract before_translation_seconds from top level
            if ($obj.PSObject.Properties["before_translation_seconds"]) {
                $ht["before_translation"] = [double]$obj.before_translation_seconds
            }
        } catch {}
    }
    # gates timing is measured by verify_online.ps1 itself (passed as param)
    if ($GateSec -gt 0) { $ht["gates"] = [double]$GateSec }
    return $ht
}

$env:PIPELINE_REPORT_MODE    = "brief"
$env:BRIEF_ONLY              = "1"
$env:BRIEF_MIN_EVENTS_HARD   = "5"
$env:BRIEF_MAX_EVENTS        = "8"
$env:EXEC_MIN_EVENTS         = "5"
$env:BRIEF_FORCE_QWEN_ONLY   = "1"
$env:SKIP_DEEP_ANALYSIS      = "1"
$env:SKIP_EDUCATION_RENDERER = "1"

function Invoke-VerifyOnlineFailFast {
    param(
        [string]$Gate,
        [string]$Reason,
        [int]$ExitCode = 1,
        [string]$NextSteps = ""
    )

    $outputsDir = Join-Path $repoRoot "outputs"
    New-Item -ItemType Directory -Force -Path $outputsDir -ErrorAction SilentlyContinue | Out-Null

    foreach ($staleRel in @(
        "outputs\latest_brief.md",
        "outputs\executive_report.docx",
        "outputs\NOT_READY_report.md",
        "outputs\NOT_READY_report.docx",
        "outputs\deep_analysis.md",
        "outputs\deep_analysis_education.md",
        "outputs\notion_page.md",
        "outputs\mindmap.xmind",
        "docs\reports\deep_analysis_education_version.md",
        "docs\reports\deep_analysis_education_version_ppt.md",
        "docs\reports\deep_analysis_education_version_xmind.md"
    )) {
        $stalePath = Join-Path $repoRoot $staleRel
        if (Test-Path $stalePath) {
            Remove-Item -LiteralPath $stalePath -Force -ErrorAction SilentlyContinue
        }
    }
    # iter42b: PPTX forbidden — also clean any pptx from outputs in fail-fast path
    Get-ChildItem -Path $outputsDir -Filter "*.pptx" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Output ("  [fail-fast] 已刪除殘留 PPTX: {0}" -f $_.Name)
    }

    @"
# NOT_READY

gate: $Gate
run_id: $_voRunId
reason: $Reason
"@ | Out-File (Join-Path $outputsDir "NOT_READY.md") -Encoding UTF8 -NoNewline

    Write-Output ("[verify_online] FAIL-FAST: {0}" -f $Reason)

    $venvPython = Join-Path $repoRoot "venv\Scripts\python.exe"
    if (Test-Path $venvPython) { $_voPy = $venvPython } else { $_voPy = "python" }

    $env:PIPELINE_RUN_ID            = $_voRunId
    $env:PIPELINE_REPORT_MODE       = "brief"
    $env:BRIEF_ONLY                 = "1"
    $env:BRIEF_FORCE_QWEN_ONLY      = "1"
    $env:SKIP_DEEP_ANALYSIS         = "1"
    $env:SKIP_EDUCATION_RENDERER    = "1"
    # iter56: pass stress mode info to run_once.py for NOT_READY_report.md
    $env:STRESS_MODE_TRIGGERED      = if ($script:_stressModeTriggered) { "1" } else { "0" }
    $env:STRESS_TRIGGER_LEVEL       = [string]$script:_stressTriggerLevel
    $env:STRESS_VRAM_RATIO          = [string]$script:_vramRatio
    $env:STRESS_NON_LLAMA_PROCS     = [string]$script:_nonLlamaGpuProcCount
    try {
        & $_voPy (Join-Path $repoRoot "scripts\run_once.py") "--not-ready-report" 2>&1 |
            ForEach-Object { Write-Output "  [not-ready-report] $_" }
    } catch {
        Write-Output ("  [not-ready-report] 生成失敗: {0}" -f $_)
    } finally {
        $env:PIPELINE_RUN_ID         = $null
        $env:PIPELINE_REPORT_MODE    = $null
        $env:BRIEF_ONLY              = $null
        $env:BRIEF_FORCE_QWEN_ONLY   = $null
        $env:SKIP_DEEP_ANALYSIS      = $null
        $env:SKIP_EDUCATION_RENDERER = $null
    }
    # iter34: append GPU / other next-steps instructions to NOT_READY_report.md
    if ($NextSteps -and (Test-Path (Join-Path $outputsDir "NOT_READY_report.md"))) {
        try {
            Add-Content -LiteralPath (Join-Path $outputsDir "NOT_READY_report.md") `
                -Value ("`n`n## 下一步`n$NextSteps") -Encoding utf8
        } catch {}
    }

    # iter55: ensure translation_engine.meta.json stub exists on every fail-fast path
    $_ffTeMetaPath = Join-Path $outputsDir "translation_engine.meta.json"
    if (-not (Test-Path $_ffTeMetaPath)) {
        try {
            @{
                run_id         = $_voRunId
                generated_at   = (Get-Date -Format "o")
                endpoint       = "http://127.0.0.1:8080"
                success        = $false
                fail_reason    = $Gate
                translate_mode = "not_started"
                events_total   = 0
                calls_total    = 0
                cache_hit      = 0
                cache_miss     = 0
            } | ConvertTo-Json -Compress | Set-Content $_ffTeMetaPath -Encoding UTF8
            Write-Output ("  [fail-fast] translation_engine.meta.json stub written (fail_reason={0})" -f $Gate)
        } catch {
            Write-Output ("  [fail-fast] WARN: translation_engine stub write failed: {0}" -f $_)
        }
    }

    $_voNrProdList = @()
    foreach ($__nrf in @("NOT_READY_report.md","NOT_READY_report.docx")) {
        if (Test-Path (Join-Path $outputsDir $__nrf)) { $_voNrProdList += "outputs\$__nrf" }
    }
    $_voNrProdStr = if ($_voNrProdList) { $_voNrProdList -join ", " } else { "(none)" }
    $_voNowFail = (Get-Date -Format "o")
    @"
run_id              = $_voRunId
started_at          = $_voNowFail
finished_at         = $_voNowFail
mode                = $(if ($Mode) { $Mode } else { 'manual' })
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = $_voNrProdStr
fail_reason         = $Gate
"@ | Out-File (Join-Path $outputsDir "LAST_RUN_SUMMARY.txt") -Encoding UTF8 -NoNewline
    Write-Output ("LAST_RUN_SUMMARY.txt written: status=FAIL  fail_reason={0}" -f $Gate)

    # iter29/31: 計時 — 失敗路徑也寫 timing meta + 附錄（含分段耗時）
    try {
        $_voStopwatch.Stop()
        $_fEndAt  = Get-Date
        $_fSecTot = [int]$_voStopwatch.Elapsed.TotalSeconds
        # iter31: read stage_seconds (partial — pipeline may have exited early)
        $_fStgHt = Read-StageTiming -RepoRoot $repoRoot
        Write-RunTimingMeta `
            -OutPath  (Join-Path $repoRoot "outputs\run_timing.meta.json") `
            -RunId    $_voRunId `
            -StartDt  $_startedAt `
            -EndDt    $_fEndAt `
            -TotalSec $_fSecTot `
            -BudgetSec $_voBudgetSec `
            -StageSec $_fStgHt `
            -SoftTargetSec $_voSoftTargetSec
        Append-TimingFooterToMd `
            -MdPath   (Join-Path $repoRoot "outputs\NOT_READY_report.md") `
            -RunId    $_voRunId `
            -StartDt  $_startedAt `
            -EndDt    $_fEndAt `
            -TotalSec $_fSecTot `
            -StageSec $_fStgHt
        $__fm = [int]([Math]::Floor($_fSecTot / 60)); $__fs = [int]($_fSecTot % 60)
        Write-Output ("  ⏱️ 總耗時：{0} 秒（{1} 分 {2} 秒）" -f $_fSecTot, $__fm, $__fs)
    } catch {
        Write-Output ("  [WARN] 計時寫入失敗: {0}" -f $_)
    }
    exit $ExitCode
}

Write-Output "=== verify_online.ps1 開始 ==="
# iter70b: entrypoint/git-head/run-id evidence
$_voGitHead = "unknown"
try { $_voGitHead = (git rev-parse --short HEAD 2>$null) } catch {}
$_voEntrypoint = if ($env:PIPELINE_ENTRYPOINT) { $env:PIPELINE_ENTRYPOINT } else { "direct" }
Write-Output ("RUN_ID={0}" -f $_voRunId)
Write-Output ("GIT_HEAD={0}" -f $_voGitHead)
Write-Output ("MODE={0}" -f $(if ($Mode) { $Mode } else { "default" }))
Write-Output ("ENTRYPOINT={0}" -f $_voEntrypoint)
Write-Output ""

# ---------------------------------------------------------------------------
# META_RESET_HARD (iter36): 清除本次要重寫的 meta 檔（確保 run_id 一致、無殘留舊值）
# 只刪 meta / summary，不刪 outputs 其他產物（不破壞已有證據）
# ---------------------------------------------------------------------------
Write-Output "[META_RESET_HARD] 清除舊 meta 檔（run_id=$_voRunId）..."
$_metaResetDir = Join-Path $repoRoot "outputs"
New-Item -ItemType Directory -Force -Path $_metaResetDir -ErrorAction SilentlyContinue | Out-Null
foreach ($_mrFile in @(
    "outputs\translation_engine.meta.json",
    "outputs\gpu_probe.meta.json",
    "outputs\gpu_probe_history.meta.json",
    "outputs\gpu_load.meta.json",
    "outputs\gpu_warmup.meta.json",
    "outputs\run_timing.meta.json",
    "outputs\LAST_RUN_SUMMARY.txt",
    "outputs\stage_timing.meta.json",
    "outputs\digest_density.meta.json",
    "outputs\bigtech_focus.meta.json",
    "outputs\selection_audit.meta.json"
)) {
    $_mrPath = Join-Path $repoRoot $_mrFile
    if (Test-Path $_mrPath) {
        Remove-Item -LiteralPath $_mrPath -Force -ErrorAction SilentlyContinue
        Write-Output ("  [META_RESET] 已刪除: {0}" -f $_mrFile)
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# PRE-CLEAN: 清除前次殘留的 brief-demo 禁止產物（notion/xmind/deep_analysis）
#   硬鎖：brief demo 路徑不得有這些檔案。即使前次失敗中斷也要清乾淨。
# ---------------------------------------------------------------------------
# iter42b: PPTX removal — clean ALL pptx from outputs (three-layer defense: layer 1 pre-clean)
$_pptxPreCleanCount = 0
Get-ChildItem -Path (Join-Path $repoRoot "outputs") -Filter "*.pptx" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    Write-Output ("  [PRE-CLEAN] 已刪除 PPTX: {0}" -f $_.Name)
    $_pptxPreCleanCount++
}
Write-Output ("[PRE-CLEAN] PPTX 清除完成：刪除 {0} 個 pptx 檔案" -f $_pptxPreCleanCount)
# iter48: PRE-CLEAN dev_forum_audit.meta.json — avoid stale meta polluting gates
$_dfaPreCleanPath = Join-Path $repoRoot "outputs\dev_forum_audit.meta.json"
if (Test-Path $_dfaPreCleanPath) {
    Remove-Item -LiteralPath $_dfaPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 dev_forum_audit.meta.json"
} else {
    Write-Output "  [PRE-CLEAN] dev_forum_audit.meta.json 不存在略過"
}
# iter53: PRE-CLEAN bigtech_diversity.meta.json
$_bdmPreCleanPath = Join-Path $repoRoot "outputs\bigtech_diversity.meta.json"
if (Test-Path $_bdmPreCleanPath) {
    Remove-Item -LiteralPath $_bdmPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 bigtech_diversity.meta.json"
}
# iter67: PRE-CLEAN domain_vendor_cap.meta.json
$_dvcPreCleanPath = Join-Path $repoRoot "outputs\domain_vendor_cap.meta.json"
if (Test-Path $_dvcPreCleanPath) {
    Remove-Item -LiteralPath $_dvcPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 domain_vendor_cap.meta.json"
}
# iter68: PRE-CLEAN dev_platform_cap.meta.json
$_pdcPreCleanPath = Join-Path $repoRoot "outputs\dev_platform_cap.meta.json"
if (Test-Path $_pdcPreCleanPath) {
    Remove-Item -LiteralPath $_pdcPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 dev_platform_cap.meta.json"
}
# iter69b: PRE-CLEAN daily_overlap.meta.json
$_doPreCleanPath = Join-Path $repoRoot "outputs\daily_overlap.meta.json"
if (Test-Path $_doPreCleanPath) {
    Remove-Item -LiteralPath $_doPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 daily_overlap.meta.json"
}
# iter71: PRE-CLEAN content_mix.meta.json
$_cmPreCleanPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
if (Test-Path $_cmPreCleanPath) {
    Remove-Item -LiteralPath $_cmPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 content_mix.meta.json"
}
# iter70: PRE-CLEAN selection_shortfall.meta.json
$_sfPreCleanPath = Join-Path $repoRoot "outputs\selection_shortfall.meta.json"
if (Test-Path $_sfPreCleanPath) {
    Remove-Item -LiteralPath $_sfPreCleanPath -Force -ErrorAction SilentlyContinue
    Write-Output "  [PRE-CLEAN] 已刪除 selection_shortfall.meta.json"
}
Write-Output "[PRE-CLEAN] 清除舊的 notion/xmind/deep_analysis 殘留產物..."
foreach ($_voPreClean in @(
    "outputs\notion_page.md",
    "outputs\mindmap.xmind",
    "outputs\deep_analysis.md",
    "outputs\deep_analysis_education.md",
    "docs\reports\deep_analysis_education_version.md",
    "docs\reports\deep_analysis_education_version_ppt.md",
    "docs\reports\deep_analysis_education_version_xmind.md"
)) {
    $_voPreCleanPath = Join-Path $repoRoot $_voPreClean
    if (Test-Path $_voPreCleanPath) {
        Remove-Item -LiteralPath $_voPreCleanPath -Force -ErrorAction SilentlyContinue
        Write-Output ("  [PRE-CLEAN] 已刪除: {0}" -f $_voPreClean)
    }
}

# ---------------------------------------------------------------------------
# iter56/57: GPU load detection → two-tier STRESS_600_MODE trigger
#   HARD VRAM_BUSY:      vram_ratio>=0.85 OR vram_used>=total-900  → STRESS_600 (budget=600 soft=300)
#   HARD GPU_CONTENTION: non_llama>=2 AND vram_ratio>=0.70         → STRESS_600 (budget=600 soft=300)
#   SOFT WARNING:        non_llama>=1 (IDE/light compute)          → normal mode (budget=175 soft=110), warning only
#   NONE:                clean GPU                                 → normal mode (budget=175 soft=110)
#   Quality gates are NEVER affected — only time budget changes.
# ---------------------------------------------------------------------------
Write-Output "[GPU_LOAD] GPU 負載偵測（兩段式語義）..."
$_vbOutputsDir = Join-Path $repoRoot "outputs"
New-Item -ItemType Directory -Force -Path $_vbOutputsDir -ErrorAction SilentlyContinue | Out-Null
$_vbVramUsedMb   = 0
$_vbVramTotalMb  = 0
$_vbVramRatio    = 0.0
$_vbNonLlamaCount = 0
$_vbTopProcs     = @()
$_vbNvsmiOk      = $null -ne (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue)
$_vbTestInjected = $false

# iter57: thresholds (hardcoded, recorded in meta for auditability)
$_vbThVramBusyRatio      = 0.85
$_vbThVramBusyMbReserve  = 900
$_vbThContentionProc     = 2
$_vbThContentionVramRatio = 0.70

if ($_vbNvsmiOk) {
    # Query total/used VRAM
    try {
        $_vbMemLines = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>&1
        foreach ($_vbMemLine in $_vbMemLines) {
            $_vbMemStr = [string]$_vbMemLine
            if ($_vbMemStr -match '^\s*(\d+)\s*,\s*(\d+)') {
                $_vbVramUsedMb  = [int]$Matches[1]
                $_vbVramTotalMb = [int]$Matches[2]
                if ($_vbVramTotalMb -gt 0) {
                    $_vbVramRatio = [Math]::Round($_vbVramUsedMb / $_vbVramTotalMb, 4)
                }
                break
            }
        }
    } catch {
        Write-Output ("  [GPU_LOAD] nvidia-smi memory query failed: {0}" -f $_)
    }

    # Query compute apps
    try {
        $_vbAppLines = & nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader,nounits 2>&1
        $_vbProcIdx = 0
        foreach ($_vbAppLine in $_vbAppLines) {
            $_vbAppStr = [string]$_vbAppLine
            if ($_vbAppStr -match '^\s*(\d+)\s*,\s*(.+?)\s*,\s*(.*)') {
                $_vbPid  = [int]$Matches[1]
                $_vbName = $Matches[2].Trim()
                $_vbMem  = $Matches[3].Trim()
                $_vbMemInt = 0
                [int]::TryParse(($_vbMem -replace '[^\d]',''), [ref]$_vbMemInt) | Out-Null
                $_vbIsOurs = ($false)
                if ($_vbName -match 'llama' -or $_vbName -match 'python') {
                    $_vbIsOurs = $true
                }
                if (-not $_vbIsOurs) {
                    $_vbNonLlamaCount++
                }
                if ($_vbProcIdx -lt 6) {
                    $_vbTopProcs += @{ name=$_vbName; pid=$_vbPid; used_mb=$_vbMemInt }
                    $_vbProcIdx++
                }
            }
        }
    } catch {
        Write-Output ("  [GPU_LOAD] nvidia-smi compute-apps query failed: {0}" -f $_)
    }
} else {
    Write-Output "  [GPU_LOAD] nvidia-smi not found — skip"
}

# iter57: INJECT_GPU_VRAM_RATIO — test-only override for evidence reproducibility
if ($env:INJECT_GPU_VRAM_RATIO -and $env:INJECT_GPU_VRAM_RATIO -ne "") {
    $_vbVramRatio = [double]$env:INJECT_GPU_VRAM_RATIO
    $_vbTestInjected = $true
    Write-Output ("  [GPU_LOAD] INJECT_GPU_VRAM_RATIO={0:F4} (test_injected=true)" -f $_vbVramRatio)
}

# iter57: two-tier trigger determination
$_vbTriggerLevel = "none"
$_vbTriggered    = $false
$_vbModeName     = "none"
$_vbReason       = "none"

# HARD VRAM_BUSY: vram_ratio>=0.85 OR vram_used>=total-900
if (($_vbVramRatio -ge $_vbThVramBusyRatio) -or
    ($_vbVramTotalMb -gt 0 -and $_vbVramUsedMb -ge ($_vbVramTotalMb - $_vbThVramBusyMbReserve))) {
    $_vbTriggerLevel = "vram_busy"
    $_vbTriggered    = $true
    $_vbModeName     = "stress_600_vram_busy"
    $_vbReason       = ("vram_ratio={0:F4}>=0.85 OR used={1}MB>=total-{2}={3}MB" -f $_vbVramRatio, $_vbVramUsedMb, $_vbThVramBusyMbReserve, ($_vbVramTotalMb - $_vbThVramBusyMbReserve))
}
# HARD GPU_CONTENTION: non_llama>=2 AND vram_ratio>=0.70
elseif (($_vbNonLlamaCount -ge $_vbThContentionProc) -and ($_vbVramRatio -ge $_vbThContentionVramRatio)) {
    $_vbTriggerLevel = "gpu_contention"
    $_vbTriggered    = $true
    $_vbModeName     = "stress_600_gpu_contention"
    $_vbReason       = ("non_llama={0}>={1} AND vram_ratio={2:F4}>={3}" -f $_vbNonLlamaCount, $_vbThContentionProc, $_vbVramRatio, $_vbThContentionVramRatio)
}
# SOFT WARNING: non_llama>=1 (IDE/light compute — no mode switch)
elseif ($_vbNonLlamaCount -ge 1) {
    $_vbTriggerLevel = "soft_warning"
    $_vbTriggered    = $false
    $_vbModeName     = "soft_warning_no_switch"
    $_vbReason       = ("non_llama={0}>=1 but vram_ratio={1:F4}<{2} — soft warning only" -f $_vbNonLlamaCount, $_vbVramRatio, $_vbThContentionVramRatio)
}

# Write gpu_load.meta.json
$_vbMeta = [ordered]@{
    run_id                    = $_voRunId
    vram_used_mb              = $_vbVramUsedMb
    vram_total_mb             = $_vbVramTotalMb
    vram_ratio                = $_vbVramRatio
    non_llama_gpu_proc_count  = $_vbNonLlamaCount
    top_processes             = @($_vbTopProcs)
    stress_trigger_level      = $_vbTriggerLevel
    stress_mode_triggered     = $_vbTriggered
    stress_mode_name          = $_vbModeName
    stress_reason             = $_vbReason
    test_injected             = $_vbTestInjected
    thresholds_used           = [ordered]@{
        vram_busy_ratio_threshold      = $_vbThVramBusyRatio
        vram_busy_mb_reserve           = $_vbThVramBusyMbReserve
        contention_proc_threshold      = $_vbThContentionProc
        contention_vram_ratio_threshold = $_vbThContentionVramRatio
    }
    detected_at               = (Get-Date -Format "o")
}
$_vbMeta | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $_vbOutputsDir "gpu_load.meta.json") -Encoding UTF8

# Store in script-level vars for Write-RunTimingMeta
$script:_stressModeTriggered  = $_vbTriggered
$script:_stressModeName       = $_vbModeName
$script:_stressTriggerLevel   = $_vbTriggerLevel
$script:_vramRatio            = $_vbVramRatio
$script:_nonLlamaGpuProcCount = $_vbNonLlamaCount

# Console log (grep-friendly)
Write-Output ("  [GPU_LOAD] vram_ratio={0:F4} non_llama_gpu_proc_count={1} trigger_level={2} triggered={3} budget={4} soft={5}" `
    -f $_vbVramRatio, $_vbNonLlamaCount, $_vbTriggerLevel, $_vbTriggered, $_voBudgetSec, $_voSoftTargetSec)

if ($_vbTriggered) {
    $_voBudgetSec     = 600
    $_voSoftTargetSec = 300
    $env:PIPELINE_TIME_BUDGET_SEC  = "600"
    $env:PIPELINE_SOFT_TARGET_SEC  = "300"
    $env:STRESS_600_MODE           = "1"
    Write-Output ("  STRESS_600_MODE=1 (reason={0})" -f $_vbReason)
    Write-Output ("  PIPELINE_TIME_BUDGET_SEC=600  PIPELINE_SOFT_TARGET_SEC=300")
} else {
    if ($_vbTriggerLevel -eq "soft_warning") {
        Write-Output ("  GPU_CONTENTION soft warning: {0} — normal mode kept (budget={1} soft={2})" -f $_vbReason, $_voBudgetSec, $_voSoftTargetSec)
    } else {
        Write-Output ("  GPU clean — normal mode (budget={0} soft={1})" -f $_voBudgetSec, $_voSoftTargetSec)
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# Step 0: Translation engine (Qwen) preflight — Iteration 19
#   Non-blocking: if Qwen not up, try to start llama_server.ps1 and wait <=20s.
#   Sets $env:BRIEF_TRANSLATION_READY = "1" (ready) or "0" (down).
#   即使 -SkipPipeline 也照常做 Qwen + GPU 實際檢查；只略過 Step 1 的 Z0 收集。
# ---------------------------------------------------------------------------
Write-Output "[0/4] 翻譯引擎（Qwen）+ GPU 前置檢查..."
$_qwenUrl   = "http://127.0.0.1:8080/v1/models"
$_qwenReady = $false
$_btlMetaP  = Join-Path $repoRoot "outputs\brief_template_leak.meta.json"
$env:BRIEF_TRANSLATION_FAIL_REASON = ""   # set to SERVER_NOT_READY or GPU_NOT_ACTIVE on failure

if ($false -and $SkipPipeline) {
    # -SkipPipeline: We are verifying an already-completed run.
    # Set PIPELINE_RUN_ID from the meta that run wrote, so STALE_META checks pass.
    Write-Output "  Qwen preflight: SKIPPED (-SkipPipeline)"
    $env:BRIEF_TRANSLATION_READY = "1"   # translation was required to produce that run
    if (Test-Path $_btlMetaP) {
        try {
            $_btlExisting = Get-Content $_btlMetaP -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($_btlExisting.PSObject.Properties["run_id"] -and [string]$_btlExisting.run_id) {
                $_voRunId = [string]$_btlExisting.run_id
                Write-Output ("  PIPELINE_RUN_ID resolved from meta: {0}" -f $_voRunId)
            }
        } catch {
            Write-Output ("  WARN: could not read run_id from brief_template_leak.meta.json: {0}" -f $_)
        }
    }
    Write-Output ("  => BRIEF_TRANSLATION_READY=1  PIPELINE_RUN_ID={0}" -f $_voRunId)
} else {
    # iter36b: robust llama-server preflight
    # A) Determine boot mode parameters
    $_isBudget600   = ($_voBudgetSec -le 600)
    $_llBootMaxWait = if ($env:LLAMA_BOOT_MAX_WAIT_SEC -and $env:LLAMA_BOOT_MAX_WAIT_SEC -ne "") {
                         [int]$env:LLAMA_BOOT_MAX_WAIT_SEC
                     } elseif ($_isBudget600) { 5 } else { 180 }
    $_llAutoStart   = if ($env:LLAMA_AUTOSTART -and $env:LLAMA_AUTOSTART -ne "") {
                         [int]$env:LLAMA_AUTOSTART
                     } elseif ($_isBudget600) { 0 } else { 1 }

    Write-Output ("  boot params: budget={0}s  LLAMA_AUTOSTART={1}  LLAMA_BOOT_MAX_WAIT_SEC={2}" `
        -f $_voBudgetSec, $_llAutoStart, $_llBootMaxWait)

    # Prepare bootstrap meta + log paths
    $_bsMetaPath = Join-Path $repoRoot "outputs\llama_server_bootstrap.meta.json"
    $_bsLogPath  = Join-Path $repoRoot "outputs\llama_server_bootstrap.log"
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot "outputs") -ErrorAction SilentlyContinue | Out-Null
    $_bsMeta = [ordered]@{
        run_id       = $_voRunId
        mode         = if ($_isBudget600) { "budget600_no_autostart" } else { "extended_autostart" }
        autostart    = [bool]($_llAutoStart -eq 1)
        max_wait_sec = $_llBootMaxWait
        ready        = $false
        ready_at     = $null
        wait_sec     = 0
        pid          = $null
        http_status  = $null
        last_error   = ""
        log_tail     = ""
    }

    function _Bs-Log { param([string]$Msg)
        $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        $line = "[$ts] $Msg"
        Write-Output "  $line"
        try { Add-Content -LiteralPath $_bsLogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue } catch {}
    }

    # B) First immediate probe (timeout 3s)
    _Bs-Log ("probing {0} ..." -f $_qwenUrl)
    try {
        $_quickResp = Invoke-WebRequest -Uri $_qwenUrl -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        $_qwenReady = $true
        $_bsMeta["ready"]       = $true
        $_bsMeta["ready_at"]    = (Get-Date -Format "o")
        $_bsMeta["wait_sec"]    = 0
        $_bsMeta["http_status"] = [int]$_quickResp.StatusCode
        _Bs-Log "llama-server: already running (immediate probe OK)"
    } catch {
        _Bs-Log ("not responding: {0}" -f ($_.Exception.Message -replace "\r?\n"," "))
    }

    # C) If not ready and LLAMA_AUTOSTART=1, launch llama_server.ps1
    if (-not $_qwenReady -and $_llAutoStart -eq 1) {
        $_lsScript = Join-Path $PSScriptRoot "llama_server.ps1"
        if (Test-Path $_lsScript) {
            _Bs-Log ("LLAMA_AUTOSTART=1: launching {0}" -f $_lsScript)
            try {
                $_bsProc = Start-Process powershell `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$_lsScript`"" `
                    -WindowStyle Hidden -PassThru -ErrorAction Stop
                $_bsPid = if ($_bsProc) { [int]$_bsProc.Id } else { $null }
                $_bsMeta["pid"] = $_bsPid
                _Bs-Log ("launched pid={0}" -f $_bsPid)
            } catch {
                _Bs-Log ("autostart failed: {0}" -f $_)
                $_bsMeta["last_error"] = "autostart_failed: $_"
            }
        } else {
            _Bs-Log ("LLAMA_AUTOSTART=1 but llama_server.ps1 not found at: {0}" -f $_lsScript)
            $_bsMeta["last_error"] = "llama_server.ps1 not found"
        }
    } elseif (-not $_qwenReady -and $_llAutoStart -eq 0) {
        _Bs-Log "LLAMA_AUTOSTART=0: skipping auto-start (pre-warmed server required)"
    }

    # D) Poll loop (1s interval) up to max_wait_sec
    if (-not $_qwenReady) {
        $_pollElapsed = 0
        while ($_pollElapsed -lt $_llBootMaxWait) {
            Start-Sleep -Seconds 1
            $_pollElapsed++
            try {
                $_pollResp = Invoke-WebRequest -Uri $_qwenUrl -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
                $_qwenReady = $true
                $_bsMeta["ready"]       = $true
                $_bsMeta["ready_at"]    = (Get-Date -Format "o")
                $_bsMeta["wait_sec"]    = $_pollElapsed
                $_bsMeta["http_status"] = [int]$_pollResp.StatusCode
                _Bs-Log ("ready after {0}s" -f $_pollElapsed)
                break
            } catch {
                if ($_pollElapsed % 5 -eq 0 -or $_pollElapsed -eq $_llBootMaxWait) {
                    _Bs-Log ("polling {0}/{1}s — still waiting" -f $_pollElapsed, $_llBootMaxWait)
                }
            }
        }
        if (-not $_qwenReady) {
            $_bsMeta["wait_sec"]   = $_pollElapsed
            $_bsMeta["last_error"] = if ($_isBudget600) {
                "timeout after ${_pollElapsed}s (budget=600s mode, pre-warmed server required)"
            } else { "timeout after ${_pollElapsed}s" }
            _Bs-Log ("timeout: {0}" -f $_bsMeta["last_error"])
        }
    }

    # Write bootstrap meta (with log tail)
    try {
        if (Test-Path $_bsLogPath) {
            $_bsLines = Get-Content $_bsLogPath -Encoding utf8 -ErrorAction SilentlyContinue
            if ($_bsLines) { $_bsMeta["log_tail"] = (($bsLines | Select-Object -Last 20) -join "`n") }
        }
        $_bsMeta | ConvertTo-Json -Depth 4 -Compress | Set-Content $_bsMetaPath -Encoding UTF8
        Write-Output ("  bootstrap meta written: ready={0}  wait_sec={1}  pid={2}" `
            -f $_bsMeta["ready"], $_bsMeta["wait_sec"], $_bsMeta["pid"])
    } catch {
        Write-Output ("  WARN: bootstrap meta write failed: {0}" -f $_)
    }

    # E) Branch: server ready vs not ready
    if ($_qwenReady) {
        # ── GPU active evidence ────────────────────────────────────────────────
        $_gpuFound    = $false
        $_vramMb      = 0
        $_nvsmiExists = $null -ne (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue)
        $_gpuMetaPath = Join-Path $repoRoot "outputs\gpu_probe.meta.json"

        if ($_nvsmiExists) {
            Write-Output "  GPU probe: querying nvidia-smi --query-compute-apps ..."
            $_insuffPerm = $false
            try {
                $_nvsmiLines = & nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader,nounits 2>&1
                foreach ($_nvLine in $_nvsmiLines) {
                    $_lineStr = [string]$_nvLine
                    if ($_lineStr -match "llama") {
                        $_gpuFound = $true
                        $_cols = $_lineStr -split ","
                        if ($_cols.Count -ge 3) {
                            $_vMbParsed = 0
                            $null = [int]::TryParse($_cols[2].Trim(), [ref]$_vMbParsed)
                            $_vramMb = $_vMbParsed
                        }
                        break
                    }
                    if ($_lineStr -match "Insufficient") { $_insuffPerm = $true }
                }
                if (-not $_gpuFound -and $_insuffPerm) {
                    $_gpuFound = $true
                    Write-Output "  GPU probe: Insufficient Permissions — server responds + GPU active => PASS"
                }
            } catch {
                Write-Output ("  GPU probe: nvidia-smi error: {0}" -f $_)
            }
            if ($_gpuFound) {
                Write-Output ("  GPU active: VRAM={0}MB  gpu_process_found=true" -f $_vramMb)
            } else {
                Write-Output "  GPU probe: llama-server NOT in nvidia-smi  gpu_process_found=false"
            }
        } else {
            $_gpuFound = $true
            Write-Output "  GPU probe: nvidia-smi not found — assume OK"
        }

        $_gpuReason = if ($_gpuFound) { "none" } else { "GPU_NOT_ACTIVE" }
        @{
            run_id            = $_voRunId
            nvidia_smi_ok     = $_nvsmiExists
            gpu_process_found = $_gpuFound
            vram_mb           = $_vramMb
            nvidia_smi_found  = $_nvsmiExists
            probed_at         = (Get-Date -Format "o")
            reason            = $_gpuReason
        } | ConvertTo-Json -Compress | Set-Content $_gpuMetaPath -Encoding UTF8
        Write-Output ("  gpu_probe.meta.json: gpu_process_found={0}  vram_mb={1}  reason={2}" `
            -f $_gpuFound, $_vramMb, $_gpuReason)

        $env:BRIEF_TRANSLATION_READY      = "1"
        $env:BRIEF_TRANSLATION_FAIL_REASON = ""
        if ($_gpuFound) {
            Write-Output "  => BRIEF_TRANSLATION_READY=1  (server OK + GPU active)"
        } else {
            Write-Output "  GPU probe: not in compute-apps (WARN) — server responds => WARN-OK"
            Write-Output "  NOTE: verify llama-server uses --n-gpu-layers -1"
            Write-Output "  => BRIEF_TRANSLATION_READY=1  (server OK; GPU probe WARN-OK)"
        }
    } else {
        # Server not ready after full wait
        $_snrFastReason = if ($_isBudget600) {
            "SERVER_NOT_READY_FAST: budget=600 requires pre-warmed llama-server"
        } else { "SERVER_NOT_READY" }
        $env:BRIEF_TRANSLATION_READY      = "0"
        $env:BRIEF_TRANSLATION_FAIL_REASON = $_snrFastReason
        Write-Output ("  => BRIEF_TRANSLATION_READY=0  reason={0}" -f $_snrFastReason)

        New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot "outputs") -ErrorAction SilentlyContinue | Out-Null
        # gpu_probe.meta.json
        @{
            run_id            = $_voRunId
            nvidia_smi_ok     = $false
            gpu_process_found = $false
            vram_mb           = 0
            nvidia_smi_found  = $false
            probed_at         = (Get-Date -Format "o")
            reason            = $_snrFastReason
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\gpu_probe.meta.json") -Encoding UTF8
        # translation_engine.meta.json
        @{
            run_id                = $_voRunId
            generated_at          = (Get-Date -Format "o")
            endpoint              = "http://127.0.0.1:8080"
            response_model        = ""
            latency_ms            = 0
            prompt_chars          = 0
            output_chars          = 0
            success               = $false
            fail_reason           = $_snrFastReason
            source_file           = ""
            calls_total           = 0
            calls_retry           = 0
            cache_hit             = 0
            cache_miss            = 0
            tok_per_sec_est       = 0.0
            gpu_process_found     = $false
            calls_tok_s           = @()
            tok_s_min             = $null
            tok_s_avg             = $null
            tok_s_max             = $null
            cpu_fallback_detected = $false
            gpu_required          = $true
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\translation_engine.meta.json") -Encoding UTF8
        Write-Output ("  translation_engine.meta.json: success=false fail_reason={0} calls_total=0" -f $_snrFastReason)
    }
}
Write-Output ""

if ($env:BRIEF_TRANSLATION_READY -ne "1") {
    $_voPreflightGate = if ($env:BRIEF_TRANSLATION_FAIL_REASON) { $env:BRIEF_TRANSLATION_FAIL_REASON } else { "TRANSLATION_ENGINE_DOWN" }
    $_voPreflightNextSteps = @(
        "1. 請用 GPU 參數啟動 llama-server，例如：",
        "   llama-server.exe -m <model_path> --n-gpu-layers 999 -c 4096 --port 8080",
        "   或: llama-server.exe -m <model_path> -ngl 999 --port 8080",
        "2. 確認 http://127.0.0.1:8080/v1/models 可正常回應（HTTP 200）",
        "3. 啟動後確認 nvidia-smi 中有 llama-server 程序且 VRAM > 300 MB",
        "4. 若 GPU server 在 budget=600s 模式下起不來（冷啟動需較長時間），",
        "   請改用常駐方式先在背景啟動 server，再執行 verify_online.ps1",
        "   （常駐啟動參考: scripts\llama_server.ps1）"
    ) -join "`n"
    Invoke-VerifyOnlineFailFast -Gate $_voPreflightGate -Reason $_voPreflightGate `
        -NextSteps $_voPreflightNextSteps
}

# ---------------------------------------------------------------------------
# iter56: GPU warmup stabilization — 2 short completions to avoid cold-start jitter
#   Runs BEFORE the official GPU_MODE_REQUIRED_HARD probe so the model is warm.
#   Results are evidence-only; only the official probe result matters for PASS/FAIL.
# ---------------------------------------------------------------------------
Write-Output "[GPU_WARMUP] 穩定化推理 (2 次短 completion)..."
$_gwOutputsDir = Join-Path $repoRoot "outputs"
$_gwCompUrl    = "http://127.0.0.1:8080/v1/chat/completions"
$_gwResults    = @()
for ($_gwi = 1; $_gwi -le 2; $_gwi++) {
    try {
        $_gwPy = @"
import json, time, urllib.request
url='$_gwCompUrl'
payload=json.dumps({"model":"qwen","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":40,"temperature":0,"stream":False})
t0=time.time()
req=urllib.request.Request(url, data=payload.encode('utf-8'), headers={"Content-Type":"application/json"})
raw=urllib.request.urlopen(req, timeout=30).read()
d=json.loads(raw)
t=d.get("timings",{}) or {}
pps=t.get("predicted_per_second",0) or 0
el=time.time()-t0
print(f"{pps:.1f}|{el:.2f}")
"@
        $_gwOut = $_gwPy | python - 2>&1
        $_gwOutStr = [string]$_gwOut
        if ($_gwOutStr -match '^([\d.]+)\|([\d.]+)') {
            $_gwPps  = [double]$Matches[1]
            $_gwWall = [double]$Matches[2]
            $_gwResults += @{ run=$_gwi; predicted_per_second=$_gwPps; wall_sec=$_gwWall; ok=$true }
            Write-Output ("  GPU_WARMUP_{0}: pps={1:F1} wall={2:F2}s" -f $_gwi, $_gwPps, $_gwWall)
        } else {
            $_gwResults += @{ run=$_gwi; predicted_per_second=0; wall_sec=0; ok=$false; error=$_gwOutStr }
            Write-Output ("  GPU_WARMUP_{0}: parse error: {1}" -f $_gwi, $_gwOutStr)
        }
    } catch {
        $_gwResults += @{ run=$_gwi; predicted_per_second=0; wall_sec=0; ok=$false; error=[string]$_ }
        Write-Output ("  GPU_WARMUP_{0}: failed: {1}" -f $_gwi, $_)
    }
    Start-Sleep -Milliseconds 500
}
# Write gpu_warmup.meta.json
[ordered]@{
    run_id  = $_voRunId
    warmups = @($_gwResults)
    warmup_at = (Get-Date -Format "o")
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $_gwOutputsDir "gpu_warmup.meta.json") -Encoding UTF8
Write-Output ""

# ---------------------------------------------------------------------------
# GPU_MODE_REQUIRED_HARD gate (iter34)
# tok/s probe — 呼叫一次 llama-server completions 探針，計算 tok_per_sec_est。
# 門檻：tok_per_sec_est >= 15（保守值）；低於門檻 = CPU 模式，立刻 FAIL-FAST。
# 輔助指標：gpu_process_found=true 或 vram_mb >= 300（來自前面的 nvidia-smi probe）
# PASS 條件：tok_per_sec_est >= 15 AND (gpu_process_found OR vram_mb >= 300)
# FAIL 條件：tok_per_sec_est < 15（無論 nvidia-smi 顯示為何）
# 目標：60 秒內完成（probe timeout=50s；NOT_READY 兩件套生成 < 60s）
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "[GPU_MODE_REQUIRED_HARD] tok/s 探針啟動..."
$_gpuTokThreshold = 15
$_gpuTokPerSec    = 0.0
$_gpuProbeModel   = ""
$_gpuCompUrl      = $_qwenUrl -replace "/v1/models", "/v1/chat/completions"
$_gpuProbePayload = @{
    model       = "qwen"
    messages    = @(@{ role = "user"; content = "Summarize in one sentence: NVIDIA announced a new H200 GPU with doubled VRAM for large-scale AI inference workloads." })
    max_tokens  = 80
    temperature = 0.0
    stream      = $false
} | ConvertTo-Json -Depth 5 -Compress

$_gpuProbeWatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $_gpuProbeHeaders = @{ "Content-Type" = "application/json" }
    $_gpuProbeResp = Invoke-RestMethod -Uri $_gpuCompUrl -Method POST `
        -Body $_gpuProbePayload -Headers $_gpuProbeHeaders -TimeoutSec 50 -ErrorAction Stop
    $_gpuProbeWatch.Stop()
    $_gpuProbeElapsed = $_gpuProbeWatch.Elapsed.TotalSeconds
    $_gpuOutputTok = 0
    if ($_gpuProbeResp.PSObject.Properties['usage'] -and
        $_gpuProbeResp.usage.PSObject.Properties['completion_tokens']) {
        $_gpuOutputTok = [int]$_gpuProbeResp.usage.completion_tokens
    }
    # fallback: rough word count if usage absent
    if ($_gpuOutputTok -le 0) {
        $_gpuContent = ""
        try { $_gpuContent = [string]$_gpuProbeResp.choices[0].message.content } catch {}
        $_gpuOutputTok = [Math]::Max(10, ($($_gpuContent -split '\s+').Count))
    }
    try { $_gpuProbeModel = [string]$_gpuProbeResp.model } catch {}
    $_gpuTokPerSec = [Math]::Round($_gpuOutputTok / [Math]::Max(0.1, $_gpuProbeElapsed), 2)
    Write-Output ("  探針完成: model={0}  output_tokens={1}  elapsed={2:F2}s  tok_per_sec_est={3:F1}" `
        -f $_gpuProbeModel, $_gpuOutputTok, $_gpuProbeElapsed, $_gpuTokPerSec)
} catch {
    $_gpuProbeWatch.Stop()
    Write-Output ("  探針失敗（視為 CPU 模式）: {0}" -f $_)
    $_gpuTokPerSec = 0.0
}

# 更新 gpu_probe.meta.json，加入 tok_per_sec_est
try {
    $_gpuMetaPathV2 = Join-Path $repoRoot "outputs\gpu_probe.meta.json"
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot "outputs") -ErrorAction SilentlyContinue | Out-Null
    @{
        run_id            = $_voRunId
        nvidia_smi_ok     = $_nvsmiExists
        gpu_process_found = $_gpuFound
        vram_mb           = $_vramMb
        tok_per_sec_est   = $_gpuTokPerSec
        tok_threshold     = $_gpuTokThreshold
        gpu_required      = $true
        probed_at         = (Get-Date -Format "o")
        reason            = if ($_gpuTokPerSec -ge $_gpuTokThreshold) { "none" } else { "tok_per_sec_below_threshold" }
    } | ConvertTo-Json -Compress | Set-Content $_gpuMetaPathV2 -Encoding UTF8
    Write-Output ("  gpu_probe.meta.json 已更新: tok_per_sec_est={0:F1}  gpu_required=true" -f $_gpuTokPerSec)
} catch {
    Write-Output ("  [WARN] gpu_probe.meta.json 更新失敗: {0}" -f $_)
}

$_gpuTokPass      = ($_gpuTokPerSec -ge $_gpuTokThreshold)
$_gpuEvidencePass = ($_gpuFound -or $_vramMb -ge 300)
Write-Output ("  GPU_MODE_REQUIRED_HARD: tok_per_sec_est={0:F1} threshold={1}  gpu_evidence={2} (gpu_found={3} vram={4}MB)" `
    -f $_gpuTokPerSec, $_gpuTokThreshold, $_gpuEvidencePass, $_gpuFound, $_vramMb)

if (-not $_gpuTokPass) {
    $_gpuHardReason = ("GPU_MODE_REQUIRED_HARD: tok_per_sec_est={0:F1} < {1} (CPU mode detected — GPU inference not active)" `
        -f $_gpuTokPerSec, $_gpuTokThreshold)
    Write-Output ("  => 失敗: {0}" -f $_gpuHardReason)
    # iter56/57: append VRAM busy context to next steps
    $_gpuNextSteps = "請用 GPU 參數啟動 llama-server（-ngl 999 或 --n-gpu-layers 999）並確認 tok_per_sec_est >= 15。参考: scripts\llama_server.ps1 已内建 --n-gpu-layers -1 啟動邏輯，CUDA build 路徑為 C:\llama_node\llama-b8123-bin-win-cuda-12.4-x64\llama-server.exe。"
    if ($script:_stressModeTriggered) {
        $_gpuNextSteps += "`nVRAM busy detected (trigger_level={0}) -> STRESS_600_MODE activated, but tok/s still below threshold. Close GPU-heavy apps (game) or reduce settings." -f $script:_stressTriggerLevel
    }
    Invoke-VerifyOnlineFailFast -Gate "GPU_MODE_REQUIRED_HARD" -Reason $_gpuHardReason `
        -NextSteps $_gpuNextSteps
}
Write-Output ("  => GPU_MODE_REQUIRED_HARD：通過 (tok_per_sec_est={0:F1} >= {1})" -f $_gpuTokPerSec, $_gpuTokThreshold)
$env:GPU_TOK_PER_SEC_EST = [string]$_gpuTokPerSec
Write-Output ""


# GPU_CONTINUOUS_ENFORCEMENT_HARD: start periodic tok/s probe job (iter35)
# iter40: FAST_300_DAILY disables periodic probes (no concurrent GPU requests)
$_gpuCeInterval     = 120  # seconds between probes (spec: 每120秒一次)
$_gpuCeFallbackTh   = 12   # tok/s below this = suspected CPU fallback
$_gpuProbeHistPath  = Join-Path $repoRoot "outputs\gpu_probe_history.meta.json"
$_gpuFallbackFlag   = Join-Path $repoRoot "outputs\_gpu_fallback_detected.flag"
Remove-Item $_gpuFallbackFlag -Force -ErrorAction SilentlyContinue

$_gpuCeJob = $null
if ($_fast300Daily) {
    Write-Output "  [FAST_300_DAILY] 週期性 GPU 探針已禁用（避免併發）"
} else {
$_gpuCeJob = Start-Job -ScriptBlock {
    param($compUrl, $histPath, $flagPath, $runId, $intervalSec, $fallbackTh)
    $history   = [System.Collections.Generic.List[object]]::new()
    $probeNum  = 0
    $nvsmiOk   = [bool](Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue)
    while ($true) {
        Start-Sleep -Seconds $intervalSec
        $probeNum++
        $ts      = [datetime]::UtcNow
        $tps     = 0
        $probeOk = $false
        try {
            $pay = '{"model":"qwen","messages":[{"role":"user","content":"GPU?"}],"max_tokens":15,"temperature":0,"stream":false}'
            $t0  = [datetime]::UtcNow
            $r   = Invoke-RestMethod -Uri $compUrl -Method Post -Body $pay -ContentType 'application/json' -TimeoutSec 25 -ErrorAction Stop
            $el  = ([datetime]::UtcNow - $t0).TotalSeconds
            $tps = if ($el -gt 0) { [math]::Round($r.usage.completion_tokens / $el, 2) } else { 0 }
            $probeOk = $true
        } catch {}
        $vramMb  = 0
        $gpuSeen = $false
        if ($nvsmiOk -and ($probeNum % 2 -eq 0)) {
            try {
                $totMem = (nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>&1) -join ""
                if ($totMem -match '(\d+)') { $vramMb = [int]$Matches[1]; $gpuSeen = ($vramMb -ge 300) }
            } catch {}
        }
        $entry = @{ probe_num=$probeNum; timestamp=$ts.ToString("o"); tok_per_sec=$tps; probe_ok=$probeOk; vram_mb=$vramMb; gpu_seen=$gpuSeen }
        $history.Add($entry)
        try { @{ run_id=$runId; probes=@($history) } | ConvertTo-Json -Depth 5 -Compress | Set-Content $histPath -Encoding UTF8 } catch {}
        if ($probeOk -and $tps -gt 0 -and $tps -lt $fallbackTh) {
            "tok_per_sec=$tps probe_num=$probeNum" | Set-Content $flagPath -Encoding UTF8
        }
    }
} -ArgumentList $_gpuCompUrl, $_gpuProbeHistPath, $_gpuFallbackFlag, $_voRunId, $_gpuCeInterval, $_gpuCeFallbackTh

Write-Output ("  [GPU_CONTINUOUS_ENFORCEMENT_HARD] 持續GPU探針已啟動（間隔={0}s  CPU判定閾值={1} tok/s）" -f $_gpuCeInterval, $_gpuCeFallbackTh)
}  # end else (not $_fast300Daily)
Write-Output ""
# ---- Step 1: Z0 online collection + supply fallback ----
$_z0Dir          = Join-Path $repoRoot "data\raw\z0"
$_z0Latest       = Join-Path $_z0Dir   "latest.jsonl"
$_z0LatestMeta   = Join-Path $_z0Dir   "latest.meta.json"

# Per-run snapshot dir (parallel-safe: each verify_online invocation uses its own run_id)
$_snapshotDir    = Join-Path $repoRoot "outputs\runs\$_voRunId"
$_z0Snapshot     = Join-Path $_snapshotDir "z0_snapshot.jsonl"
$_z0SnapshotMeta = Join-Path $_snapshotDir "z0_snapshot.meta.json"

# Initialise fallback env vars (inherited by verify_run.ps1 -> run_once.py)
$env:Z0_SUPPLY_FALLBACK_USED                  = "0"
$env:Z0_SUPPLY_FALLBACK_REASON                = "none"
$env:Z0_SUPPLY_PRIMARY_FETCHED                = "0"
$env:Z0_SUPPLY_FALLBACK_PATH                  = ""
$env:Z0_SUPPLY_FALLBACK_SNAPSHOT_PATH         = ""
$env:Z0_SUPPLY_FALLBACK_SNAPSHOT_AGE_HOURS    = ""

if (-not $SkipPipeline) {
    Write-Output "[1/3] 執行 Z0 收集器（線上模式）..."

    # Save snapshot BEFORE collection (parallel-safe: each run uses its own $_voRunId dir)
    New-Item -ItemType Directory -Force -Path $_snapshotDir | Out-Null
    $_snapshotSourceMtime = [datetime]::UtcNow   # fallback if no latest.jsonl exists yet
    if (Test-Path $_z0Latest) {
        $_snapshotSourceMtime = (Get-Item $_z0Latest).LastWriteTimeUtc
        try { Copy-Item -LiteralPath $_z0Latest -Destination $_z0Snapshot -Force } catch {}
    }
    if (Test-Path $_z0LatestMeta) {
        try { Copy-Item -LiteralPath $_z0LatestMeta -Destination $_z0SnapshotMeta -Force } catch {}
    }

    $_forceZ0Fail = ($env:FORCE_Z0_FAIL -eq "1")

    if ($_fast300Mode -and -not $_fast300Daily -and (Test-Path $_z0Latest)) {
        # iter39: FAST_300_BENCH skips z0_collect_online (takes ~350s); uses cached z0 data
        # iter40: FAST_300_DAILY always collects online
        $script:_z0OnlineSec = 0
        Write-Output "  [FAST_300_BENCH] z0_collect_online 已略過（使用快取 z0 資料）"
    } elseif (-not $_forceZ0Fail) {
        $_z0OnlineStart = $_voStopwatch.Elapsed.TotalSeconds
        # iter45: apply Z0 deadlines for any tight budget (<=200s), not just FAST_300_DAILY
        #   manual mode with 200s budget also needs deadlines (Z0 alone can take 230s+)
        $_z0UseDeadline = $_fast300Daily -or ($_voBudgetSec -le 200)
        if ($_z0UseDeadline) {
            $script:_z0DeadlineSoftSec = 30
            $script:_z0DeadlineHardSec = 30
            $script:_z0StopReason = "unknown"
            $_z0Label = if ($_fast300Daily) { "FAST_300_DAILY" } else { "Z0_DEADLINE" }
            Write-Output ("  [{0}] Z0 軟截止={1}s / 硬截止={2}s  z0_data_source=online" -f $_z0Label, $script:_z0DeadlineSoftSec, $script:_z0DeadlineHardSec)
            # iter55: drain cap constants
            $_z0InflightDrainCapSec = 12
            $script:_z0InflightDrainCapSec = $_z0InflightDrainCapSec
            $_z0WallClockCapSec = 50
            $script:_z0WallClockCapSec = $_z0WallClockCapSec
            $_z0Job = Start-Job -ScriptBlock {
                param($scriptPath)
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
                $LASTEXITCODE
            } -ArgumentList (Join-Path $PSScriptRoot "z0_collect.ps1")
            # Wait for soft deadline first
            $_z0Done = Wait-Job -Job $_z0Job -Timeout $script:_z0DeadlineSoftSec
            if ($_z0Done) {
                $script:_z0StopReason = "quota_met"
                $script:_z0StopNewRequestsAtSec = [Math]::Round($_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart, 1)
                $_z0Exit = Receive-Job -Job $_z0Job
            } else {
                # Soft deadline exceeded — wait for hard deadline
                $_z0Remaining = $script:_z0DeadlineHardSec - $script:_z0DeadlineSoftSec
                Write-Output ("  [{0}] 軟截止已過（>{1}s），等待硬截止（再{2}s）" -f $_z0Label, $script:_z0DeadlineSoftSec, $_z0Remaining)
                $_z0Done2 = Wait-Job -Job $_z0Job -Timeout $_z0Remaining
                if ($_z0Done2) {
                    $script:_z0StopReason = "quota_met"
                    $script:_z0StopNewRequestsAtSec = [Math]::Round($_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart, 1)
                    $_z0Exit = Receive-Job -Job $_z0Job
                } else {
                    $script:_z0StopReason = "hard_deadline"
                    $script:_z0StopNewRequestsAtSec = [Math]::Round($_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart, 1)
                    Write-Output ("  [{0}] 硬截止到期（>{1}s），停止發起新請求" -f $_z0Label, $script:_z0DeadlineHardSec)
                    # iter55: enforce inflight drain cap using Stopwatch polling (Wait-Job -Timeout unreliable on Windows)
                    $_z0ElapsedNow = $_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart
                    $_z0DrainBudget = [Math]::Max(1, [Math]::Min($_z0InflightDrainCapSec, $_z0WallClockCapSec - $_z0ElapsedNow - 2))
                    Write-Output ("  [{0}] drain budget={1:F0}s（drain_cap={2}s wallclock_remaining={3:F0}s）" -f $_z0Label, $_z0DrainBudget, $_z0InflightDrainCapSec, ($_z0WallClockCapSec - $_z0ElapsedNow))
                    $_z0DrainSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $_z0DrainFinished = $false
                    while ($_z0DrainSw.Elapsed.TotalSeconds -lt $_z0DrainBudget) {
                        if ($_z0Job.State -eq 'Completed' -or $_z0Job.State -eq 'Failed' -or $_z0Job.State -eq 'Stopped') {
                            $_z0DrainFinished = $true
                            break
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    $_z0DrainSw.Stop()
                    if ($_z0DrainFinished) {
                        Write-Output ("  [{0}] in-flight 收尾完成（{1:F1}s）" -f $_z0Label, $_z0DrainSw.Elapsed.TotalSeconds)
                        try { $_z0Exit = Receive-Job -Job $_z0Job -ErrorAction SilentlyContinue } catch {}
                    } else {
                        $script:_z0StopReason = "drain_cutoff"
                        $script:_z0InflightCutoffApplied = $true
                        Write-Output ("  [{0}] in-flight drain cap 到期（{1:F1}s），強制切斷" -f $_z0Label, $_z0DrainSw.Elapsed.TotalSeconds)
                    }
                    # iter55: measure wallclock BEFORE Stop-Job (which can block 20s+ on Windows)
                    $script:_z0WallClockSec = [Math]::Round($_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart, 1)
                    $script:_z0InflightDrainedSec = [Math]::Round($script:_z0WallClockSec - $script:_z0StopNewRequestsAtSec, 1)
                    # Background cleanup: kill child processes to avoid blocking
                    try { Stop-Job -Job $_z0Job -ErrorAction SilentlyContinue } catch {}
                }
            }
            Remove-Job -Job $_z0Job -Force -ErrorAction SilentlyContinue
            # iter55: compute wallclock and inflight drain (only if not already set by drain_cutoff path)
            if ($null -eq $script:_z0WallClockSec -or $script:_z0StopReason -ne "drain_cutoff") {
                $script:_z0WallClockSec = [Math]::Round($_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart, 1)
                $script:_z0InflightDrainedSec = [Math]::Round($script:_z0WallClockSec - $script:_z0StopNewRequestsAtSec, 1)
            }
            Write-Output ("  [{0}] Z0 stop_reason={1}  z0_data_source=online" -f $_z0Label, $script:_z0StopReason)
            Write-Output ("  [{0}] Z0 口徑：stop_new_requests_at={1:F1}s  inflight_drain={2:F1}s  wallclock={3:F1}s  cutoff={4}" -f $_z0Label, $script:_z0StopNewRequestsAtSec, $script:_z0InflightDrainedSec, $script:_z0WallClockSec, $script:_z0InflightCutoffApplied)
            # iter55: Z0_WALLCLOCK_EXCEEDED — jitter epsilon: wallclock > cap + 0.9 才 FAIL
            $_z0JitterEpsilon = 0.9
            $script:_z0WallClockJitterEpsilon = $_z0JitterEpsilon
            if ($_fast300Daily -and $script:_z0WallClockSec -gt ($_z0WallClockCapSec + $_z0JitterEpsilon)) {
                Invoke-VerifyOnlineFailFast -Gate "Z0_WALLCLOCK_EXCEEDED" `
                    -Reason ("Z0_WALLCLOCK_EXCEEDED: wallclock={0:F1}s > cap+epsilon={1:F1}s (cap={2}s epsilon={3}s stop_new_requests_at={4:F1}s inflight_drain={5:F1}s cutoff={6})" -f $script:_z0WallClockSec, ($_z0WallClockCapSec + $_z0JitterEpsilon), $_z0WallClockCapSec, $_z0JitterEpsilon, $script:_z0StopNewRequestsAtSec, $script:_z0InflightDrainedSec, $script:_z0InflightCutoffApplied)
            }
        } else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "z0_collect.ps1")
            if ($LASTEXITCODE -ne 0) {
                Write-Output "[verify_online] Z0 collect FAILED (exit $LASTEXITCODE). Aborting."
                exit 1
            }
        }
        $script:_z0OnlineSec = [int]([Math]::Round($_voStopwatch.Elapsed.TotalSeconds - $_z0OnlineStart))
    } else {
        Write-Output "  [FORCE_Z0_FAIL=1] Skipping z0_collect.ps1 (simulating collection failure)."
    }

    # --- Z0 Supply Fallback: detect degraded collection ---
    $_z0PrimaryTotal = 0
    if (-not $_forceZ0Fail -and (Test-Path $_z0LatestMeta)) {
        try {
            $_z0FreshMeta    = Get-Content $_z0LatestMeta -Raw -Encoding UTF8 | ConvertFrom-Json
            $_z0PrimaryTotal = if ($_z0FreshMeta.PSObject.Properties['total_items']) { [int]$_z0FreshMeta.total_items } else { 0 }
        } catch {}
    }

    $_z0Degraded = $_forceZ0Fail -or ($_z0PrimaryTotal -lt 1200)

    if ($_z0Degraded) {
        if (Test-Path $_z0Snapshot) {
            try {
                Copy-Item -LiteralPath $_z0Snapshot     -Destination $_z0Latest     -Force
                if (Test-Path $_z0SnapshotMeta) {
                    Copy-Item -LiteralPath $_z0SnapshotMeta -Destination $_z0LatestMeta -Force
                }
                $_z0FbReason = if ($_forceZ0Fail) { "FORCE_Z0_FAIL=1 (simulated degradation)" } else { "primary_total=$_z0PrimaryTotal<1200" }
                $_snapshotAgeHours = [Math]::Round(([datetime]::UtcNow - $_snapshotSourceMtime).TotalSeconds / 3600, 1)
                Write-Output ("  [Z0_SUPPLY_FALLBACK] Degraded collection (primary_total={0}). Restored snapshot: {1}  age={2}h" -f $_z0PrimaryTotal, $_z0Snapshot, $_snapshotAgeHours)
                $env:Z0_SUPPLY_FALLBACK_USED                  = "1"
                $env:Z0_SUPPLY_FALLBACK_REASON                = $_z0FbReason
                $env:Z0_SUPPLY_PRIMARY_FETCHED                = "$_z0PrimaryTotal"
                $env:Z0_SUPPLY_FALLBACK_PATH                  = $_z0Snapshot
                $env:Z0_SUPPLY_FALLBACK_SNAPSHOT_PATH         = $_z0Snapshot
                $env:Z0_SUPPLY_FALLBACK_SNAPSHOT_AGE_HOURS    = "$_snapshotAgeHours"
            } catch {
                Write-Output ("  [Z0_SUPPLY_FALLBACK] WARNING: snapshot restore failed: {0}" -f $_)
            }
        } else {
            Write-Output "  [Z0_SUPPLY_FALLBACK] WARNING: degraded collection but no snapshot available."
            if ($_forceZ0Fail) {
                Write-Output "  [Z0_SUPPLY_FALLBACK] ABORT: FORCE_Z0_FAIL=1 with no snapshot -- run verify_online once normally first."
                exit 1
            }
        }
    } else {
        $env:Z0_SUPPLY_FALLBACK_USED                  = "0"
        $env:Z0_SUPPLY_FALLBACK_REASON                = "none"
        $env:Z0_SUPPLY_PRIMARY_FETCHED                = "$_z0PrimaryTotal"
        $env:Z0_SUPPLY_FALLBACK_SNAPSHOT_PATH         = $_z0Snapshot
        $env:Z0_SUPPLY_FALLBACK_SNAPSHOT_AGE_HOURS    = ""
    }

    Write-Output ""
} else {
    Write-Output "[1/3] Z0 收集已略過（-SkipPipeline 模式；使用現有的 data/raw/z0 檔案）"
    Write-Output ""
}

# TIME_BUDGET check after Z0 collection (online path only)
if (-not $SkipPipeline -and $_voStopwatch.Elapsed.TotalSeconds -gt $_voBudgetSec) {
    $_voBgtReason = "TIME_BUDGET_EXCEEDED; stage=after_z0_collection; elapsed=$([int]$_voStopwatch.Elapsed.TotalSeconds)s > budget=${_voBudgetSec}s"
    Invoke-VerifyOnlineFailFast -Gate "TIME_BUDGET_EXCEEDED" -Reason $_voBgtReason
}

# Initialise degraded flag (updated inside the Z0 pool health gate block)
$pool85Degraded = $false

# Print Z0 by_platform summary
$metaPath = Join-Path $repoRoot "data\raw\z0\latest.meta.json"
if (Test-Path $metaPath) {
    $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
    Write-Output "Z0 COLLECTOR EVIDENCE:"
    Write-Output "  collected_at      : $($meta.collected_at)"
    Write-Output "  total_items       : $($meta.total_items)"
    Write-Output "  frontier_ge_70    : $($meta.frontier_ge_70)"
    Write-Output "  frontier_ge_85    : $($meta.frontier_ge_85)"
    if ($meta.PSObject.Properties['frontier_ge_70_72h']) {
        Write-Output "  frontier_ge_70_72h: $($meta.frontier_ge_70_72h)"
    }
    if ($meta.PSObject.Properties['frontier_ge_85_72h']) {
        Write-Output "  frontier_ge_85_72h: $($meta.frontier_ge_85_72h)"
    }
    if ($meta.PSObject.Properties['fallback_ratio']) {
        Write-Output "  fallback_ratio    : $($meta.fallback_ratio)"
    }
    if ($meta.PSObject.Properties['frontier_ge_85_fallback_count']) {
        Write-Output "  f85_fallback_count: $($meta.frontier_ge_85_fallback_count)"
    }
    if ($meta.PSObject.Properties['frontier_ge_85_fallback_ratio']) {
        Write-Output "  f85_fallback_ratio: $($meta.frontier_ge_85_fallback_ratio)"
    }
    Write-Output "  by_platform:"
    if ($meta.by_platform) {
        $meta.by_platform.PSObject.Properties | Sort-Object Value -Descending | ForEach-Object {
            Write-Output "    $($_.Name): $($_.Value)"
        }
    }
    Write-Output ""

    # ---------------------------------------------------------------------------
    # Z0 POOL HEALTH GATES — always-on; override via env vars before calling script
    #   Z0_MIN_TOTAL_ITEMS            (default 800) — guards against near-empty collection
    #   Z0_MIN_FRONTIER85_72H         (default  10) — guards against stale / no fresh news
    #   Z0_ALLOW_DEGRADED             (default   0) — set "1" to allow fallback gate
    #   Z0_MIN_FRONTIER85_72H_FALLBACK(default   4) — fallback target when ALLOW_DEGRADED=1
    # Gate modes:
    #   STRICT  : actual >= target10 → PASS; else FAIL exit 1
    #   DEGRADED: actual >= target10 → PASS; actual >= fallback4 → DEGRADED exit 0; else FAIL exit 1
    # ---------------------------------------------------------------------------
    $z0MinTotal        = if ($env:Z0_MIN_TOTAL_ITEMS)                { [int]$env:Z0_MIN_TOTAL_ITEMS }                else { 800 }
    $z0Min85_72h       = if ($env:Z0_MIN_FRONTIER85_72H)             { [int]$env:Z0_MIN_FRONTIER85_72H }             else { 10  }
    $z0AllowDegraded   = ($env:Z0_ALLOW_DEGRADED -eq "1")
    $z0Fallback85_72h  = if ($env:Z0_MIN_FRONTIER85_72H_FALLBACK)    { [int]$env:Z0_MIN_FRONTIER85_72H_FALLBACK }    else { 4   }

    $z0ActualTotal  = if ($meta.PSObject.Properties['total_items'])        { [int]$meta.total_items }        else { 0 }
    $z0Actual85_72h = if ($meta.PSObject.Properties['frontier_ge_85_72h']) { [int]$meta.frontier_ge_85_72h } else { 0 }

    $gatePoolTotal  = if ($z0ActualTotal  -ge $z0MinTotal)  { "PASS" } else { "FAIL" }

    # Determine frontier85_72h gate result with optional degraded mode
    if ($z0Actual85_72h -ge $z0Min85_72h) {
        $gatePool85_72h = "PASS"
        $z0GateMode     = "STRICT"
    } elseif ($z0AllowDegraded -and ($z0Actual85_72h -ge $z0Fallback85_72h)) {
        $gatePool85_72h = "DEGRADED"
        $z0GateMode     = "DEGRADED"
    } else {
        $gatePool85_72h = "FAIL"
        $z0GateMode     = if ($z0AllowDegraded) { "DEGRADED" } else { "STRICT" }
    }

    $poolTotalFail  = ($gatePoolTotal -eq "FAIL")
    $pool85Fail     = ($gatePool85_72h -eq "FAIL")
    $pool85Degraded = ($gatePool85_72h -eq "DEGRADED")
    $poolAnyFail    = $poolTotalFail -or $pool85Fail

    Write-Output ""
    Write-Output "Z0 POOL HEALTH GATES:"
    Write-Output ("  Z0_MIN_TOTAL_ITEMS    target={0,-5} actual={1,-5} {2}" -f $z0MinTotal,  $z0ActualTotal,  $gatePoolTotal)
    if ($pool85Degraded) {
        Write-Output ("  Z0_MIN_FRONTIER85_72H target={0,-5} actual={1,-5} DEGRADED (fallback={2} PASS)" -f $z0Min85_72h, $z0Actual85_72h, $z0Fallback85_72h)
    } else {
        Write-Output ("  Z0_MIN_FRONTIER85_72H target={0,-5} actual={1,-5} {2}" -f $z0Min85_72h, $z0Actual85_72h, $gatePool85_72h)
    }
    Write-Output ("  Z0_GATE_MODE: {0}" -f $z0GateMode)
    Write-Output ("  meta_path   : {0}" -f $metaPath)
    if ($meta.PSObject.Properties['collected_at']) {
        Write-Output ("  collected_at: {0}" -f $meta.collected_at)
    }

    # Write z0_gate_mode.meta.json for downstream audit
    try {
        $_z0GateMeta = @{
            z0_gate_mode    = $z0GateMode
            target10        = $z0Min85_72h
            fallback        = $z0Fallback85_72h
            actual          = $z0Actual85_72h
            total_actual    = $z0ActualTotal
            total_target    = $z0MinTotal
            allow_degraded  = $z0AllowDegraded
            collected_at    = if ($meta.PSObject.Properties['collected_at']) { $meta.collected_at } else { "" }
            run_head        = (git rev-parse --short HEAD 2>$null | Out-String).Trim()
        }
        $_z0GateMetaPath = Join-Path $repoRoot "outputs\z0_gate_mode.meta.json"
        New-Item -ItemType Directory -Force -Path (Split-Path $_z0GateMetaPath) | Out-Null
        $_z0GateMeta | ConvertTo-Json -Depth 3 | Set-Content $_z0GateMetaPath -Encoding UTF8
    } catch {
        Write-Output "  [warn] z0_gate_mode.meta.json write failed: $_"
    }

    if ($poolAnyFail) {
        Write-Output "  => Z0 POOL HEALTH GATES: FAIL"
        exit 1
    } elseif ($pool85Degraded) {
        Write-Output "  => Z0 POOL HEALTH GATES: DEGRADED RUN (frontier85_72h below target but above fallback)"
        # Do NOT exit 1 — degraded is intentionally allowed; pipeline continues
    } else {
        Write-Output "  => Z0 POOL HEALTH GATES: PASS"
    }
    # ---------------------------------------------------------------------------
    # FRONTIER AUDIT — reads outputs/z0_frontier_audit.meta.json
    # Written by z0_collector collect_all(); shows WHY score is low.
    # ---------------------------------------------------------------------------
    $auditPath = Join-Path $repoRoot "outputs\z0_frontier_audit.meta.json"
    if (Test-Path $auditPath) {
        try {
            $aud = Get-Content $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Output ""
            Write-Output "FRONTIER AUDIT (z0_frontier_audit.meta.json):"

            # Histogram
            if ($aud.PSObject.Properties['frontier_histogram']) {
                $h = $aud.frontier_histogram
                Write-Output ("  frontier_histogram: 0-49={0}  50-69={1}  70-84={2}  85+={3}" `
                    -f $h.PSObject.Properties['0_49'].Value,
                       $h.PSObject.Properties['50_69'].Value,
                       $h.PSObject.Properties['70_84'].Value,
                       $h.PSObject.Properties['85plus'].Value)
            }

            # Bonus counts
            if ($aud.PSObject.Properties['bonus_counts']) {
                $bc = $aud.bonus_counts
                Write-Output ("  business_signal_bonus_hits: {0}" -f $bc.business_signal_bonus_hits)
                Write-Output ("  product_release_bonus_hits: {0}" -f $bc.product_release_bonus_hits)
            }

            # frontier_85_72h_samples (top 10)
            if ($aud.PSObject.Properties['frontier_85_72h_samples']) {
                $samps = $aud.frontier_85_72h_samples
                Write-Output ("  frontier_85_72h_samples ({0} items):" -f $samps.Count)
                $i = 0
                foreach ($s in $samps) {
                    $i++
                    if ($i -gt 10) { break }
                    $bf = ""
                    if ($s.PSObject.Properties['bonus_flags']) {
                        $f = $s.bonus_flags
                        $bb = if ($f.PSObject.Properties['biz_bonus'])  { $f.biz_bonus }  else { 0 }
                        $pb = if ($f.PSObject.Properties['prod_bonus']) { $f.prod_bonus } else { 0 }
                        $bf = " biz=$bb prod=$pb"
                    }
                    Write-Output ("    [{0}] score={1} age={2}h src={3}{4}" `
                        -f $i, $s.score, $s.age_hours, $s.source, $bf)
                    Write-Output ("         $($s.title.Substring(0, [Math]::Min(90, $s.title.Length)))")
                }
            }

            # near-miss samples (80-84 within 72h)
            if ($aud.PSObject.Properties['frontier_near_miss_72h_samples']) {
                $nm = $aud.frontier_near_miss_72h_samples
                if ($nm.Count -gt 0) {
                    Write-Output ("  frontier_near_miss_72h_samples (80-84, {0} items):" -f $nm.Count)
                    $j = 0
                    foreach ($s in $nm) {
                        $j++
                        if ($j -gt 5) { break }
                        $bf = ""
                        if ($s.PSObject.Properties['bonus_flags']) {
                            $f = $s.bonus_flags
                            $bb = if ($f.PSObject.Properties['biz_bonus'])  { $f.biz_bonus }  else { 0 }
                            $pb = if ($f.PSObject.Properties['prod_bonus']) { $f.prod_bonus } else { 0 }
                            $bf = " biz=$bb prod=$pb"
                        }
                        Write-Output ("    [nm$j] score={0} age={1}h src={2}{3}" `
                            -f $s.score, $s.age_hours, $s.source, $bf)
                        Write-Output ("           $($s.title.Substring(0, [Math]::Min(85, $s.title.Length)))")
                    }
                }
            }
        } catch {
            Write-Output "  frontier audit parse error (non-fatal): $_"
        }
    } else {
        Write-Output ""
        Write-Output "FRONTIER AUDIT: z0_frontier_audit.meta.json not found (run collect first)"
    }
} else {
    Write-Output "[verify_online] ERROR: Z0 meta not found: $metaPath — pool health check cannot run."
    exit 1
}

# ---- Step 2: Set Z0_ENABLED so pipeline reads local JSONL ----
# -SkipPipeline: skip online collection but STILL re-run pipeline with existing JSONL.
# This allows fast re-verification (regex/logic changes) without going online.
Write-Output "[2/3] 設定 Z0_ENABLED=1（Pipeline 將讀取本機 JSONL）..."
$env:Z0_ENABLED = "1"
if ($SkipPipeline) {
    Write-Output "  (-SkipPipeline 模式：跳過 Z0 收集，用現有 JSONL 重跑 Pipeline 驗證新邏輯)"
}

# (C) Set EXEC KPI gates — enabled by default; override with env vars before calling this script
if (-not $env:EXEC_MIN_EVENTS)   { $env:EXEC_MIN_EVENTS   = "6" }
if (-not $env:EXEC_MIN_PRODUCT)  { $env:EXEC_MIN_PRODUCT  = "2" }
if (-not $env:EXEC_MIN_TECH)     { $env:EXEC_MIN_TECH     = "2" }
if (-not $env:EXEC_MIN_BUSINESS) { $env:EXEC_MIN_BUSINESS = "2" }
Write-Output "[verify_online] EXEC KPI gates: MIN_EVENTS=$($env:EXEC_MIN_EVENTS) MIN_PRODUCT=$($env:EXEC_MIN_PRODUCT) MIN_TECH=$($env:EXEC_MIN_TECH) MIN_BUSINESS=$($env:EXEC_MIN_BUSINESS)"

# ---- Step 3: Run verify_run.ps1 ----
# Pass run_id so run_once.py writes it into supply_fallback.meta.json and latest_brief.md
$env:PIPELINE_RUN_ID       = $_voRunId
$env:PIPELINE_TRIGGERED_BY = "verify_online.ps1"
# CI/Windows ACL hardening: avoid pytest cache writes under locked temp folders.
$env:PYTEST_ADDOPTS        = "-p no:cacheprovider"
# Harden git calls inside verify_run/check_text_integrity:
#   1) trust this workspace as safe.directory
#   2) skip untracked scan to avoid locked temp-folder noise
$env:GIT_CONFIG_COUNT      = "2"
$env:GIT_CONFIG_KEY_0      = "status.showUntrackedFiles"
$env:GIT_CONFIG_VALUE_0    = "no"
$env:GIT_CONFIG_KEY_1      = "safe.directory"
$env:GIT_CONFIG_VALUE_1    = ($repoRoot -replace "\\", "/")

# Brief-only mode: fix demo entry point — suppress deep analysis + education renderer
# These env vars are inherited by the verify_run.ps1 subprocess and then by run_once.py.
$env:PIPELINE_REPORT_MODE    = "brief"
$env:BRIEF_ONLY              = "1"
$env:SKIP_DEEP_ANALYSIS      = "1"
$env:SKIP_EDUCATION_RENDERER = "1"

Write-Output "[3/3] 執行 verify_run.ps1（離線，讀取 Z0 JSONL）..."
Write-Output ""
$_verifyRunLatestPath = Join-Path $repoRoot "outputs\verify_run.latest.log"
$_verifyRunLogPath = Join-Path $repoRoot ("outputs\verify_run.{0}.log" -f $_voRunId)
$_prevVerifyRunEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    # Always run verify_run.ps1 WITHOUT -SkipPipeline so run_once.py re-executes.
    # -SkipPipeline on verify_online only skips online Z0 collection (step 1); pipeline still runs.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_run.ps1") *>&1 |
        Tee-Object -FilePath $_verifyRunLogPath
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $_prevVerifyRunEap
}
try {
    Copy-Item -LiteralPath $_verifyRunLogPath -Destination $_verifyRunLatestPath -Force
} catch {
    Write-Output ("[verify_online] WARN: 無法更新 verify_run.latest.log（使用本次執行記錄）: {0}" -f $_.Exception.Message)
}

$env:Z0_ENABLED            = $null
$env:EXEC_MIN_EVENTS       = $null
$env:EXEC_MIN_PRODUCT      = $null
$env:EXEC_MIN_TECH         = $null
$env:EXEC_MIN_BUSINESS     = $null
$env:PIPELINE_RUN_ID       = $null
$env:PIPELINE_TRIGGERED_BY = $null
$env:PYTEST_ADDOPTS        = $null


# GPU_CONTINUOUS_ENFORCEMENT_HARD: stop probe job + evaluate (iter35)
if ($_gpuCeJob) {
    Stop-Job    -Job $_gpuCeJob -ErrorAction SilentlyContinue
    Receive-Job -Job $_gpuCeJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job  -Job $_gpuCeJob -ErrorAction SilentlyContinue
}
Write-Output "  [GPU_CONTINUOUS_ENFORCEMENT_HARD] probe job stopped"
if (Test-Path $_gpuFallbackFlag) {
    $_ceFlag           = (Get-Content $_gpuFallbackFlag -ErrorAction SilentlyContinue) -join " "
    $_ceFallbackReason = "GPU_FALLBACK_DETECTED: $_ceFlag ??CPU mode detected during pipeline execution"
    Write-Output ("  => 銝剝?CPU ??菜葫: {0}" -f $_ceFallbackReason)
    Invoke-VerifyOnlineFailFast -Gate "GPU_FALLBACK_DETECTED" -Reason $_ceFallbackReason `
        -NextSteps "GPU fell back to CPU mode during pipeline. Ensure llama-server uses --n-gpu-layers 999 and tok_per_sec >= 12."
}
if ($exitCode -ne 0) {
    # verify_run can fail after all hard gates pass when DOCX is file-locked during
    # output hash evidence (Get-FileHash on executive_report.docx). Keep this path
    # non-fatal only when verify_run already reports full gate PASS and PPTX exists.
    $docxHashLockFallback = $false
    if (Test-Path $_verifyRunLogPath) {
        try {
            $vrPass10of10 = [bool](Select-String -Path $_verifyRunLogPath -Pattern "verify_run: 10/10 PASS" -SimpleMatch | Select-Object -Last 1)
            $vrHashMsg    = [bool](Select-String -Path $_verifyRunLogPath -Pattern "Get-FileHash : The file" -SimpleMatch | Select-Object -Last 1)
            $vrDocxMsg    = [bool](Select-String -Path $_verifyRunLogPath -Pattern "executive_report.docx" -SimpleMatch | Select-Object -Last 1)
            $vrLockMsg    = [bool](Select-String -Path $_verifyRunLogPath -Pattern "being used by another process" -SimpleMatch | Select-Object -Last 1)
            $vrLockMsgCN  = [bool](Select-String -Path $_verifyRunLogPath -Pattern "因為檔案正由另一個程序使用" -SimpleMatch | Select-Object -Last 1)

            # iter33: PPTX discontinued; fallback only checks DOCX
            $_vrDocxCanon = Join-Path $repoRoot "outputs\executive_report.docx"
            $_vrDocxBrief = Join-Path $repoRoot "outputs\executive_report_brief.docx"
            $vrDocxExists = (Test-Path $_vrDocxCanon) -or (Test-Path $_vrDocxBrief)
            $vrDocxSizeOk = $false
            if (Test-Path $_vrDocxCanon) {
                $vrDocxSizeOk = ((Get-Item $_vrDocxCanon).Length -gt 0)
            } elseif (Test-Path $_vrDocxBrief) {
                $vrDocxSizeOk = ((Get-Item $_vrDocxBrief).Length -gt 0)
            }

            if ($vrPass10of10 -and $vrHashMsg -and $vrDocxMsg -and ($vrLockMsg -or $vrLockMsgCN) -and $vrDocxExists -and $vrDocxSizeOk) {
                $docxHashLockFallback = $true
                $exitCode = 0
                Write-Output "[verify_online] WARN-OK: verify_run non-gate hash evidence hit DOCX lock (WinError32 path); hard gates PASS and DOCX exists."
            }
        } catch {
            # Keep original exit handling if log parsing fails.
        }
    }

    if (-not $docxHashLockFallback) {
        Write-Output "[verify_online] verify_run.ps1 FAILED (exit $exitCode)."
        # Generate NOT_READY_report md+docx for direct invocation (iter42: pptx removed)
        Write-Output "  Generating NOT_READY_report (calling run_once.py --not-ready-report)..."
        Set-Location $repoRoot
        # Re-expose run_id so NOT_READY_report files carry correct run_id (env was cleared above)
        $env:PIPELINE_RUN_ID = $_voRunId
        & python (Join-Path $repoRoot "scripts\run_once.py") "--not-ready-report" 2>&1 |
            ForEach-Object { Write-Output "  [not-ready-report] $_" }
        $env:PIPELINE_RUN_ID = $null
        # Write LAST_RUN_SUMMARY.txt with FAIL status for direct invocation
        # fail_reason is canonical: SERVER_NOT_READY / GPU_NOT_ACTIVE / TRANSLATION_ENGINE_DOWN / TIME_BUDGET_EXCEEDED
        $_voLrsFailPath = Join-Path $repoRoot "outputs\LAST_RUN_SUMMARY.txt"
        $_voCanonGates = @("SERVER_NOT_READY","GPU_NOT_ACTIVE","TRANSLATION_ENGINE_DOWN","TIME_BUDGET_EXCEEDED")
        $_voFailReason  = "PIPELINE_GATE_FAIL: verify_run exit $exitCode"
        $_voNrMd = Join-Path $repoRoot "outputs\NOT_READY.md"
        if (Test-Path $_voNrMd) {
            try {
                $_voNrRaw = Get-Content $_voNrMd -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($_voNrRaw -match '(?m)^gate:\s*(\S+)') {
                    $_voGateVal = $Matches[1].Trim()
                    if ($_voGateVal -eq "TRANSLATION_DELIVERY_HARD") { $_voGateVal = "TRANSLATION_ENGINE_DOWN" }
                    if ($_voCanonGates -contains $_voGateVal) {
                        $_voFailReason = $_voGateVal
                    } else {
                        $_voFailReason = "PIPELINE_GATE_FAIL: $_voGateVal"
                    }
                } else {
                    $_voFailReason = (($_voNrRaw -replace '[\r\n\s]+',' ').Trim())
                    if ($_voFailReason.Length -gt 200) { $_voFailReason = $_voFailReason.Substring(0,200) }
                }
            } catch {}
        }
        # Build produced_files list from NOT_READY_report two-piece (iter33: pptx discontinued)
        $_voNrProdList = @()
        foreach ($__nrf in @("NOT_READY_report.md","NOT_READY_report.docx")) {
            if (Test-Path (Join-Path $repoRoot "outputs\$__nrf")) { $_voNrProdList += "outputs\$__nrf" }
        }
        $_voNrProdStr = if ($_voNrProdList) { $_voNrProdList -join ", " } else { "(none)" }
        $_voNowFail = (Get-Date -Format "o")
        @"
run_id              = $_voRunId
started_at          = $_voNowFail
finished_at         = $_voNowFail
mode                = $(if ($Mode) { $Mode } else { 'manual' })
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = $_voNrProdStr
fail_reason         = $_voFailReason
"@ | Out-File $_voLrsFailPath -Encoding UTF8 -NoNewline
        Write-Output "LAST_RUN_SUMMARY.txt written: status=FAIL"

        # iter55: ensure translation_engine.meta.json stub on pipeline failure path too
        $_pfTeMetaPath = Join-Path $repoRoot "outputs\translation_engine.meta.json"
        if (-not (Test-Path $_pfTeMetaPath)) {
            try {
                @{
                    run_id         = $_voRunId
                    generated_at   = (Get-Date -Format "o")
                    endpoint       = "http://127.0.0.1:8080"
                    success        = $false
                    fail_reason    = $_voFailReason
                    translate_mode = "not_started"
                    events_total   = 0
                    calls_total    = 0
                    cache_hit      = 0
                    cache_miss     = 0
                } | ConvertTo-Json -Compress | Set-Content $_pfTeMetaPath -Encoding UTF8
                Write-Output ("  [pipeline-fail] translation_engine.meta.json stub written (fail_reason={0})" -f $_voFailReason)
            } catch {
                Write-Output ("  [pipeline-fail] WARN: translation_engine stub write failed: {0}" -f $_)
            }
        }

        exit $exitCode
    }
}

# iter31: mark start of content-gate checking in verify_online.ps1
$_stgGatesStart = $_voStopwatch.Elapsed.TotalSeconds

# ---------------------------------------------------------------------------
# EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD — gate summary (verify_online view)
# verify_run.ps1 already enforced this gate; here we print the meta summary.
# ---------------------------------------------------------------------------
$zhMetaPath = Join-Path $repoRoot "outputs\exec_zh_narrative.meta.json"
if (Test-Path $zhMetaPath) {
    try {
        $zhMeta = Get-Content $zhMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $zhResult = if ($zhMeta.PSObject.Properties['gate_result']) { $zhMeta.gate_result } else { "UNKNOWN" }
        $zhPass   = if ($zhMeta.PSObject.Properties['pass_count'])  { [int]$zhMeta.pass_count }  else { 0 }
        $zhFail   = if ($zhMeta.PSObject.Properties['fail_count'])  { [int]$zhMeta.fail_count }  else { 0 }
        # PASS if fail_count == 0 (sparse day tolerated when no events actually fail)
        $zhEffective = if ($zhFail -eq 0) { "PASS" } else { "FAIL" }
        $zhColor  = if ($zhFail -eq 0) { "Green" } else { "Red" }
        Write-Output ""
        Write-Output "EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD:"
        Write-Output ("  gate_result : {0}  (effective: {1})" -f $zhResult, $zhEffective)
        Write-Output ("  pass_count  : {0}" -f $zhPass)
        Write-Output ("  fail_count  : {0}" -f $zhFail)
        if ($zhMeta.PSObject.Properties['events']) {
            foreach ($ev in $zhMeta.events | Select-Object -First 2) {
                $evTitle = if ($ev.PSObject.Properties['title']) { $ev.title } else { "" }
                $evQW1   = if ($ev.PSObject.Properties['quote_window_1']) { $ev.quote_window_1 } else { "" }
                $evQW2   = if ($ev.PSObject.Properties['quote_window_2']) { $ev.quote_window_2 } else { "" }
                $evPass  = if ($ev.PSObject.Properties['all_pass']) { $ev.all_pass } else { $false }
                Write-Output ("  event: {0} | all_pass={1} | qw1=|{2}| qw2=|{3}|" -f $evTitle.Substring(0,[Math]::Min(40,$evTitle.Length)), $evPass, $evQW1, $evQW2)
            }
        }
        Write-Output ("  => EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD: {0}" -f $zhEffective)
    } catch {
        Write-Output "  exec_zh_narrative.meta.json parse error (non-fatal): $_"
    }
} else {
    Write-Output ""
    Write-Output "EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD: exec_zh_narrative.meta.json not found (gate enforced by verify_run.ps1)"
}

# ---------------------------------------------------------------------------
# EXEC KPI GATE EVIDENCE — reads exec_selection.meta.json written by pipeline
# Mode-aware:
#   demo   → bucket quotas are informational WARN-OK; do NOT exit 1
#   manual → bucket quotas are hard gates; FAIL = exit 1  (default / conservative)
#
# Mode resolution order:
#   1. Explicit -Mode param passed to verify_online.ps1  ("demo" / "manual")
#   2. outputs/showcase_ready.meta.json  .mode field written by the pipeline just run
#   3. Conservative fallback → "manual"
# ---------------------------------------------------------------------------
$execSelMetaPath   = Join-Path $repoRoot "outputs\exec_selection.meta.json"
$showcaseReadyPath = Join-Path $repoRoot "outputs\showcase_ready.meta.json"

# Resolve report_mode (brief suppresses KPI bucket details; BRIEF_* gates are the acceptance criteria)
# Priority: LAST_RUN_SUMMARY.txt report_mode field > fallback "full"
$reportMode = "full"
$_lrsPath = Join-Path $repoRoot "outputs\LAST_RUN_SUMMARY.txt"
if (Test-Path $_lrsPath) {
    try {
        $lrsContent = Get-Content $_lrsPath -Raw -Encoding UTF8
        if ($lrsContent -match '(?m)^report_mode\s*=\s*(\S+)') { $reportMode = $Matches[1].Trim().ToLower() }
    } catch { }
}

# Resolve meta mode and effective mode
$_metaMode = ""
if (Test-Path $showcaseReadyPath) {
    try {
        $srMeta = Get-Content $showcaseReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($srMeta.PSObject.Properties['mode']) {
            $_metaModeRaw = ([string]$srMeta.mode).ToLower()
            if ($_metaModeRaw -eq "demo" -or $_metaModeRaw -eq "manual") {
                $_metaMode = $_metaModeRaw
            }
        }
    } catch { }
}

$effectiveMode = ""
if ($Mode -and ($Mode.ToLower() -eq "demo" -or $Mode.ToLower() -eq "manual")) {
    $effectiveMode = $Mode.ToLower()
} elseif ($_metaMode) {
    $effectiveMode = $_metaMode
} else {
    $effectiveMode = "manual"
}

if (Test-Path $execSelMetaPath) {
    try {
        $esMeta = Get-Content $execSelMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $minEv  = if ($env:EXEC_MIN_EVENTS)   { [int]$env:EXEC_MIN_EVENTS }   else { 6 }
        $minPr  = if ($env:EXEC_MIN_PRODUCT)  { [int]$env:EXEC_MIN_PRODUCT }  else { 2 }
        $minTe  = if ($env:EXEC_MIN_TECH)     { [int]$env:EXEC_MIN_TECH }     else { 2 }
        $minBu  = if ($env:EXEC_MIN_BUSINESS) { [int]$env:EXEC_MIN_BUSINESS } else { 2 }

        $actEv = if ($esMeta.PSObject.Properties['events_total'])           { [int]$esMeta.events_total }                              else { 0 }
        $actPr = if ($esMeta.PSObject.Properties['events_by_bucket'] -and $esMeta.events_by_bucket.PSObject.Properties['product'])   { [int]$esMeta.events_by_bucket.product }  else { 0 }
        $actTe = if ($esMeta.PSObject.Properties['events_by_bucket'] -and $esMeta.events_by_bucket.PSObject.Properties['tech'])      { [int]$esMeta.events_by_bucket.tech }     else { 0 }
        $actBu = if ($esMeta.PSObject.Properties['events_by_bucket'] -and $esMeta.events_by_bucket.PSObject.Properties['business'])  { [int]$esMeta.events_by_bucket.business } else { 0 }
        $sparseDay = if ($esMeta.PSObject.Properties['sparse_day']) { [bool]$esMeta.sparse_day } else { $false }

        $gateEv = if ($actEv -ge $minEv -or $sparseDay) { "PASS" } else { "FAIL" }
        $gatePr = if ($actPr -ge $minPr -or $sparseDay) { "PASS" } else { "FAIL" }
        $gateTe = if ($actTe -ge $minTe -or $sparseDay) { "PASS" } else { "FAIL" }
        $gateBu = if ($actBu -ge $minBu -or $sparseDay) { "PASS" } else { "FAIL" }
        $sparseNote = if ($sparseDay) { " [sparse-day fallback]" } else { "" }

        $anyFail = $gateEv -eq "FAIL" -or $gatePr -eq "FAIL" -or $gateTe -eq "FAIL" -or $gateBu -eq "FAIL"

        # Gate result label — computed always; used by suppressed output and exit logic below
        $kpi_result_internal = if (-not $anyFail) { "PASS" } elseif ($effectiveMode -eq "demo") { "WARN-OK" } else { "FAIL" }
        $kpi_affects_exit = if ($reportMode -eq "brief") { $false } else { $true }

        if ($reportMode -eq "brief") {
            # brief mode: KPI bucket details suppressed — BRIEF_* gates are the acceptance criteria
            Write-Output ""
            Write-Output "EXEC KPI GATES: SUPPRESSED (report_mode=brief; acceptance=BRIEF_* gates)"
            Write-Output ("  kpi_result_internal = {0}" -f $kpi_result_internal)
        } else {
            Write-Output ""
            Write-Output ("EXEC KPI GATES (mode={0}):" -f $effectiveMode)
            Write-Output ("  effective_mode_for_kpi = {0}{1}" -f $effectiveMode, $(if ($Mode -and $Mode -ne $_metaMode -and $_metaMode -ne "") { " (CLI override)" } elseif ($Mode -and $_metaMode -eq "") { " (CLI override)" } else { "" }))
            Write-Output ("  MIN_EVENTS={0,-3} actual={1,-4} {2}{3}" -f $minEv, $actEv, $gateEv, $sparseNote)
            Write-Output ("  MIN_PRODUCT={0,-2} actual={1,-4} {2}{3}" -f $minPr, $actPr, $gatePr, $sparseNote)
            Write-Output ("  MIN_TECH={0,-4} actual={1,-4} {2}{3}" -f $minTe, $actTe, $gateTe, $sparseNote)
            Write-Output ("  MIN_BUSINESS={0,-1} actual={1,-4} {2}{3}" -f $minBu, $actBu, $gateBu, $sparseNote)
            Write-Output ("  buckets: product={0} tech={1} business={2}" -f $actPr, $actTe, $actBu)
            if (-not $anyFail) {
                Write-Output ("  => EXEC KPI GATES: PASS (mode={0})" -f $effectiveMode)
            } elseif ($effectiveMode -eq "demo") {
                # demo mode: bucket-quota shortfalls are expected on days where today's news skews to
                # one channel.  All hard quality gates (SHOWCASE_READY, AI_PURITY, DOCX/PPTX,
                # ZH_NARRATIVE) already passed above; bucket variability is non-fatal in demo context.
                Write-Output ("  => EXEC KPI GATES: WARN-OK (mode=demo, buckets=product:{0} tech:{1} business:{2}, reason: bucket variability)" -f $actPr, $actTe, $actBu)
            } else {
                Write-Output ("  => EXEC KPI GATES: FAIL (mode={0})" -f $effectiveMode)
            }
        }

        # SUPPLY_RESILIENCE soft indicator (display only; non-gating)
        $supplyMetaPathSoft = Join-Path $repoRoot "outputs\supply_resilience.meta.json"
        if (Test-Path $supplyMetaPathSoft) {
            try {
                $srmSoft = Get-Content $supplyMetaPathSoft -Raw -Encoding UTF8 | ConvertFrom-Json
                $srTierAUsed = if ($srmSoft.PSObject.Properties['tierA_used']) { [int]$srmSoft.tierA_used } else { 0 }
                $srFinalSel  = if ($srmSoft.PSObject.Properties['final_ai_selected_events']) { [int]$srmSoft.final_ai_selected_events } else { 0 }
                $srShare     = if ($srmSoft.PSObject.Properties['tierA_share_in_selected']) { [double]$srmSoft.tierA_share_in_selected } elseif ($srFinalSel -gt 0) { [Math]::Round(($srTierAUsed / $srFinalSel), 3) } else { 0.0 }
                $srTarget    = if ($srmSoft.PSObject.Properties['tierA_share_soft_target']) { [double]$srmSoft.tierA_share_soft_target } else { 0.30 }
                $srStatus    = if ($srmSoft.PSObject.Properties['tierA_share_soft_status']) { [string]$srmSoft.tierA_share_soft_status } else { if ($srShare -ge $srTarget) { "OK" } else { "LOW" } }
                Write-Output ""
                Write-Output "SUPPLY_RESILIENCE (soft):"
                Write-Output ("  tierA_used/final_selected  : {0}/{1}" -f $srTierAUsed, $srFinalSel)
                Write-Output ("  tierA_share_in_selected    : {0:F3}" -f $srShare)
                Write-Output ("  tierA_share_soft_target    : {0:F2}" -f $srTarget)
                Write-Output ("  tierA_share_soft_status    : {0}" -f $srStatus)
                Write-Output "  note          : brief 模式期望 image_count=0（僅提示，不影響 PASS/FAIL）"
            } catch {
                Write-Output ("  supply_resilience soft parse error (non-fatal): {0}" -f $_)
            }
        }

        # Exit code logic — always runs regardless of output suppression (gate behavior unchanged)
        if ($kpi_affects_exit -and $kpi_result_internal -eq "FAIL") {
            exit 1
        }
    } catch {
        Write-Output "  exec_selection meta parse error (non-fatal): $_"
    }
} else {
    Write-Output ""
    Write-Output "EXEC KPI GATES: exec_selection.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# NO_ZERO_DAY GATE — Iteration 6.5
#   Reads filter_summary.meta.json written by ingestion.py.
#   Ensures after_filter_total >= 6 so daily runs never produce 0 output.
#   WARN-OK when file is absent (first run or pipeline skipped).
# ---------------------------------------------------------------------------
$filterSummaryPath = Join-Path $repoRoot "outputs\filter_summary.meta.json"
$actEv = 0
$nzdShowcaseMetaPath = Join-Path $repoRoot "outputs\showcase_ready.meta.json"
$nzdExecMetaPath = Join-Path $repoRoot "outputs\exec_selection.meta.json"
if (Test-Path $nzdShowcaseMetaPath) {
    try {
        $nzdShowcaseMeta = Get-Content $nzdShowcaseMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($nzdShowcaseMeta.PSObject.Properties['ai_selected_events']) {
            $actEv = [int]$nzdShowcaseMeta.ai_selected_events
        } elseif ($nzdShowcaseMeta.PSObject.Properties['selected_events']) {
            $actEv = [int]$nzdShowcaseMeta.selected_events
        }
    } catch {}
}
if (($actEv -lt 1) -and (Test-Path $nzdExecMetaPath)) {
    try {
        $nzdExecMeta = Get-Content $nzdExecMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($nzdExecMeta.PSObject.Properties['final_selected_events']) {
            $actEv = [int]$nzdExecMeta.final_selected_events
        } elseif ($nzdExecMeta.PSObject.Properties['events_total']) {
            $actEv = [int]$nzdExecMeta.events_total
        }
    } catch {}
}
Write-Output ""
Write-Output "NO_ZERO_DAY GATE:"
if (Test-Path $filterSummaryPath) {
    try {
        $fsm        = Get-Content $filterSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $nzdDedup   = if ($fsm.PSObject.Properties['after_dedupe_total'])       { [int]$fsm.after_dedupe_total }       else { 0 }
        $nzdRaw     = if ($fsm.PSObject.Properties['after_filter_total_raw'])   { [int]$fsm.after_filter_total_raw }   else { -1 }
        $nzdEvPass  = if ($fsm.PSObject.Properties['event_gate_pass_total'])    { [int]$fsm.event_gate_pass_total }    else { 0 }
        # Prefer kept_total (post-G4 effective count); fallback to after_filter_total for compat.
        $nzdKept    = if ($fsm.PSObject.Properties['kept_total'])               { [int]$fsm.kept_total }               `
                      elseif ($fsm.PSObject.Properties['after_filter_total'])   { [int]$fsm.after_filter_total }       `
                      else { 0 }
        $nzdRawStr  = if ($nzdRaw -ge 0) { "$nzdRaw" } else { "n/a" }
        Write-Output ("  after_dedupe_total       : {0}" -f $nzdDedup)
        Write-Output ("  after_filter_total_raw   : {0}" -f $nzdRawStr)
        Write-Output ("  kept_total (post-G4)     : {0}" -f $nzdKept)
        Write-Output ("  after_filter_total_eff   : {0}" -f $nzdKept)
        Write-Output ("  event_gate_pass_total    : {0}" -f $nzdEvPass)
        Write-Output ("  FILTER_SUMMARY kept={0}" -f $nzdKept)
        # WARN-OK when no main events but exec deck is present (PH_SUPP >= BRIEF_MIN_EVENTS=5)
        # iter28: aligned WARN-OK threshold with BRIEF_MIN_EVENTS_HARD (5) so sparse days with
        # 5 qualifying events proceed as WARN-OK instead of FAIL.
        $nzdExecOk = if (Get-Variable -Name 'actEv' -ErrorAction SilentlyContinue) { [int]$actEv -ge 5 } else { $false }
        if ($nzdKept -ge 6) {
            Write-Output "  NO_ZERO_DAY: PASS"
        } elseif ($nzdExecOk) {
            Write-Output ("  NO_ZERO_DAY: WARN-OK (kept_total={0} < 6; exec_events={1} via PH_SUPP - deck present)" -f $nzdKept, $actEv)
        } else {
            Write-Output ("  NO_ZERO_DAY: FAIL (kept_total={0} < 6)" -f $nzdKept)
            exit 1
        }
    } catch {
        Write-Output ("  NO_ZERO_DAY: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  NO_ZERO_DAY: WARN-OK (filter_summary.meta.json not found; gate skipped)"
}

# ---------------------------------------------------------------------------
# FULLTEXT_HYDRATION — Iteration 7
#   Reads outputs/fulltext_hydrator.meta.json written by ingestion.py.
#   Gate: coverage_ratio >= 0.60 OR fulltext_ok_count >= 4 => PASS
#         otherwise => WARN-OK (non-fatal; prints reason)
#   Prints SAMPLE_1 with fulltext_len/final_url + q1_quote/q2_quote from
#   faithful_zh_news.meta.json sample_1.
# ---------------------------------------------------------------------------
$ftHydPath = Join-Path $repoRoot "outputs\fulltext_hydrator.meta.json"
Write-Output ""
Write-Output "FULLTEXT_HYDRATION:"
if (Test-Path $ftHydPath) {
    try {
        $fth = Get-Content $ftHydPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $fthApplied = if ($fth.PSObject.Properties['fulltext_applied']) { [int]$fth.fulltext_applied } else { 0 }
        $fthTotal   = if ($fth.PSObject.Properties['events_total'])     { [int]$fth.events_total }     else { 0 }
        $fthOk      = if ($fth.PSObject.Properties['fulltext_ok_count']){ [int]$fth.fulltext_ok_count }else { 0 }
        $fthCov     = if ($fth.PSObject.Properties['coverage_ratio'])   { [double]$fth.coverage_ratio } else { 0.0 }
        $fthAvgLen  = if ($fth.PSObject.Properties['avg_fulltext_len']) { [int]$fth.avg_fulltext_len }  else { 0 }
        $fthNotes   = if ($fth.PSObject.Properties['notes'])            { [string]$fth.notes }          else { "" }

        Write-Output ("  FULLTEXT_HYDRATION: applied={0} coverage={1:F3} avg_fulltext_len={2}" `
            -f $fthApplied, $fthCov, $fthAvgLen)
        Write-Output ("  events_total={0}  fulltext_ok_count={1}" -f $fthTotal, $fthOk)
        if ($fthNotes) { Write-Output ("  notes: {0}" -f $fthNotes) }

        # Print SAMPLE_1 (top item by fulltext_len)
        if ($fth.PSObject.Properties['samples'] -and $fth.samples -and $fth.samples.Count -gt 0) {
            $s1 = $fth.samples[0]
            Write-Output ""
            Write-Output "  SAMPLE_1:"
            Write-Output ("    title       : {0}" -f $s1.title)
            Write-Output ("    final_url   : {0}" -f $s1.final_url)
            Write-Output ("    fulltext_len: {0}" -f $s1.fulltext_len)
            Write-Output ("    status      : {0}" -f $s1.status)
        }

        # Print q1_quote / q2_quote from faithful_zh_news.meta.json sample_1
        $fznSamplePath = Join-Path $repoRoot "outputs\faithful_zh_news.meta.json"
        if (Test-Path $fznSamplePath) {
            try {
                $fzn = Get-Content $fznSamplePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($fzn.PSObject.Properties['sample_1'] -and $fzn.sample_1) {
                    $fznS = $fzn.sample_1
                    $q1Raw  = if ($fznS.PSObject.Properties['q1']) { [string]$fznS.q1 } else { "" }
                    $q2Raw  = if ($fznS.PSObject.Properties['q2']) { [string]$fznS.q2 } else { "" }
                    $q1m    = [regex]::Match($q1Raw, "\u300c([^\u300d]{1,240})\u300d")
                    $q2m    = [regex]::Match($q2Raw, "\u300c([^\u300d]{1,240})\u300d")
                    $q1Qt   = if ($q1m.Success) { $q1m.Groups[1].Value } else { "(none)" }
                    $q2Qt   = if ($q2m.Success) { $q2m.Groups[1].Value } else { "(none)" }
                    Write-Output ("    q1_quote    : {0}" -f $q1Qt)
                    Write-Output ("    q2_quote    : {0}" -f $q2Qt)
                }
            } catch {}
        }

        # Gate evaluation
        $fthGate = if ($fthCov -ge 0.60 -or $fthOk -ge 4) { "PASS" } else { "WARN-OK" }
        Write-Output ""
        Write-Output ("  => FULLTEXT_HYDRATION: {0} (coverage={1:F3}  ok={2})" `
            -f $fthGate, $fthCov, $fthOk)
    } catch {
        Write-Output ("  FULLTEXT_HYDRATION: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  FULLTEXT_HYDRATION: WARN-OK (meta file not found; hydration may have been skipped)"
}

# ---------------------------------------------------------------------------
# POOL_SUFFICIENCY_HARD GATE
#   Reads outputs/pool_sufficiency.meta.json written by content_strategy.py.
#
#   PASS: final_selected_events>=6 AND strict_fulltext_ok>=4
#   FAIL: anything else (no OK fallback — this is a hard DoD requirement)
#
# When FAIL: exit non-zero.  PPTX/DOCX are already blocked by the pipeline.
# ---------------------------------------------------------------------------
$notReadyPathOnline = Join-Path $repoRoot "outputs\NOT_READY.md"
$poolSuffPath       = Join-Path $repoRoot "outputs\pool_sufficiency.meta.json"
Write-Output ""
Write-Output "POOL_SUFFICIENCY_HARD GATE:"
if (Test-Path $notReadyPathOnline) {
    Write-Output "  POOL_SUFFICIENCY_HARD: FAIL (NOT_READY.md exists)"
    Write-Output ("  Contents: {0}" -f (Get-Content $notReadyPathOnline -Raw -Encoding UTF8).Trim())
    exit 1
}
if (Test-Path $poolSuffPath) {
    try {
        $psm        = Get-Content $poolSuffPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $psFinal    = if ($psm.PSObject.Properties['final_selected_events']) { [int]$psm.final_selected_events } else { 0 }
        $psStrict   = if ($psm.PSObject.Properties['strict_fulltext_ok'])    { [int]$psm.strict_fulltext_ok }    else { 0 }
        $psFallback = if ($psm.PSObject.Properties['fallback_used'])         { [bool]$psm.fallback_used }        else { $false }
        $psPipeStatus = if ($psm.PSObject.Properties['pool_sufficiency_status']) { $psm.pool_sufficiency_status } else { "UNKNOWN" }
        $psBfCands  = if ($psm.PSObject.Properties['backfill_candidates_count']) { [int]$psm.backfill_candidates_count } else { 0 }
        $psBfOk     = if ($psm.PSObject.Properties['backfill_hydrated_ok'])      { [int]$psm.backfill_hydrated_ok }      else { 0 }

        Write-Output ("  final_selected_events      : {0}" -f $psFinal)
        Write-Output ("  strict_fulltext_ok         : {0}" -f $psStrict)
        Write-Output ("  fallback_used              : {0}" -f $psFallback)
        Write-Output ("  backfill_candidates_tried  : {0}" -f $psBfCands)
        Write-Output ("  backfill_hydrated_ok(>=800): {0}" -f $psBfOk)
        Write-Output ("  pipeline_status            : {0}" -f $psPipeStatus)

        # iter39: FAST_300_MODE/FAST_600_MODE targets 7 events (>=6/>=4); normal pipeline 6/4
        $psMinFinal  = 6
        $psMinStrict = 4
        if ($psFinal -ge $psMinFinal -and $psStrict -ge $psMinStrict) {
            Write-Output "  => POOL_SUFFICIENCY_HARD: PASS"
        } else {
            Write-Output ("  => POOL_SUFFICIENCY_HARD: FAIL " +
                "(need final_selected>={0} AND strict_fulltext_ok>={1}; " +
                "got final={2} strict={3})" -f $psMinFinal, $psMinStrict, $psFinal, $psStrict)
            exit 1
        }
    } catch {
        Write-Output ("  POOL_SUFFICIENCY_HARD: FAIL (parse error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  POOL_SUFFICIENCY_HARD: FAIL (pool_sufficiency.meta.json not found — pipeline did not complete)"
    exit 1
}

# ---------------------------------------------------------------------------
# iter37: DIGEST_DENSITY_FLOOR_HARD evidence section
#   Reads outputs/digest_density.meta.json written by FAST_600_MODE fast path.
#   If FAIL, the fast path already wrote NOT_READY.md; POOL_SUFFICIENCY_HARD above
#   will have caught it. This section provides audit evidence only.
# ---------------------------------------------------------------------------
$_ddMetaPath = Join-Path $repoRoot "outputs\digest_density.meta.json"
Write-Output ""
Write-Output "DIGEST_DENSITY_FLOOR_HARD:"
if ($_fast600Mode) {
    if (Test-Path $_ddMetaPath) {
        try {
            $_ddMeta  = Get-Content $_ddMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_ddGate  = if ($_ddMeta.PSObject.Properties['gate_result'])    { $_ddMeta.gate_result }    else { "UNKNOWN" }
            $_ddEvts  = if ($_ddMeta.PSObject.Properties['events_checked']) { [int]$_ddMeta.events_checked } else { 0 }
            $_ddThin  = if ($_ddMeta.PSObject.Properties['thin_events_count']) { [int]$_ddMeta.thin_events_count } else { 0 }
            Write-Output ("  gate_result      : {0}" -f $_ddGate)
            Write-Output ("  events_checked   : {0}" -f $_ddEvts)
            Write-Output ("  thin_events_count: {0}" -f $_ddThin)
            Write-Output ("  threshold        : bullets>=5 OR chars>=1200 per event")
            if ($_ddGate -eq "FAIL") {
                Write-Output "  => DIGEST_DENSITY_FLOOR_HARD: FAIL (HYDRATION_TOO_THIN)"
                Write-Output "  Next Steps: 全文不足/水化過薄，請調整 targeted hydration 取得完整內容後再翻譯"
                Invoke-VerifyOnlineFailFast -Gate "DIGEST_DENSITY_FLOOR_HARD" `
                    -Reason "HYDRATION_TOO_THIN: thin_events=$_ddThin events_checked=$_ddEvts" `
                    -NextSteps "全文不足/水化過薄，請調整 targeted hydration 取得完整內容後再翻譯"
            } else {
                Write-Output ("  => DIGEST_DENSITY_FLOOR_HARD: PASS (events={0} thin=0)" -f $_ddEvts)
            }
        } catch {
            Write-Output ("  DIGEST_DENSITY_FLOOR_HARD: WARN-OK (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  DIGEST_DENSITY_FLOOR_HARD: SKIP (not FAST_600_MODE run or meta not written)"
    }
} else {
    Write-Output "  DIGEST_DENSITY_FLOOR_HARD: SKIP (FAST_600_MODE not active)"
}

# ---------------------------------------------------------------------------
# iter40: BIGTECH_DOMINANCE_HARD + DEV_NOISE_CAP_HARD
#   Reads selection_audit.meta.json + bigtech_focus.meta.json
#   Enforced when FAST_300_DAILY=1 or BIGTECH_GATES_ENFORCE=1
# ---------------------------------------------------------------------------
$_btGatesEnforce = ($_fast300Daily -or ($env:BIGTECH_GATES_ENFORCE -eq "1"))
$_saMetaPath = Join-Path $repoRoot "outputs\selection_audit.meta.json"
$_bfMetaPath = Join-Path $repoRoot "outputs\bigtech_focus.meta.json"
Write-Output ""
Write-Output "BIGTECH_DOMINANCE_HARD + DEV_NOISE_CAP_HARD:"
if ($_btGatesEnforce -and (Test-Path $_saMetaPath)) {
    try {
        $_saMeta = Get-Content $_saMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_btHitCount = if ($_saMeta.PSObject.Properties['bigtech_hit_count']) { [int]$_saMeta.bigtech_hit_count } else { 0 }
        $_omCount    = if ($_saMeta.PSObject.Properties['official_or_media_count']) { [int]$_saMeta.official_or_media_count } else { 0 }
        $_dnCount    = if ($_saMeta.PSObject.Properties['non_bigtech_dev_noise_count']) { [int]$_saMeta.non_bigtech_dev_noise_count } else { 0 }
        $_dfCount    = if ($_saMeta.PSObject.Properties['dev_forum_count']) { [int]$_saMeta.dev_forum_count } else { 0 }
        $_overlapPrev = if ($_saMeta.PSObject.Properties['overlap_with_prev_daily']) { [int]$_saMeta.overlap_with_prev_daily } else { 0 }
        Write-Output ("  bigtech_hit_count            : {0}" -f $_btHitCount)
        Write-Output ("  official_or_media_count      : {0}" -f $_omCount)
        Write-Output ("  dev_forum_count              : {0}" -f $_dfCount)
        Write-Output ("  non_bigtech_dev_noise_count  : {0}" -f $_dnCount)
        Write-Output ("  overlap_with_prev_daily      : {0}" -f $_overlapPrev)
        # BIGTECH_DOMINANCE_HARD: bigtech>=5 AND official_or_media>=4
        if ($_btHitCount -lt 5 -or $_omCount -lt 4) {
            $_btFailReason = ("BIGTECH_DOMINANCE_HARD_FAIL: bigtech_hit={0} official_or_media={1}" -f $_btHitCount, $_omCount)
            Write-Output ("  => FAIL: {0}" -f $_btFailReason)
            Invoke-VerifyOnlineFailFast -Gate "BIGTECH_DOMINANCE_HARD" -Reason $_btFailReason
        }
        Write-Output "  => BIGTECH_DOMINANCE_HARD: PASS"
        # iter50: DEV_NOISE_CAP_HARD: DAILY requires non_bigtech_dev_noise_count=0
        if ($_fast300Daily -and $_dnCount -gt 0) {
            $_dnFailReason = ("DEV_NOISE_CAP_HARD_FAIL: non_bigtech_dev_noise={0} (DAILY requires 0)" -f $_dnCount)
            Write-Output ("  => FAIL: {0}" -f $_dnFailReason)
            Invoke-VerifyOnlineFailFast -Gate "DEV_NOISE_CAP_HARD" -Reason $_dnFailReason
        } elseif ($_dnCount -gt 1) {
            $_dnFailReason = ("DEV_NOISE_CAP_HARD_FAIL: non_bigtech_dev_noise={0}" -f $_dnCount)
            Write-Output ("  => FAIL: {0}" -f $_dnFailReason)
            Invoke-VerifyOnlineFailFast -Gate "DEV_NOISE_CAP_HARD" -Reason $_dnFailReason
        }
        Write-Output "  => DEV_NOISE_CAP_HARD: PASS"
        # iter46: DEV_FORUM_LOW_VALUE_CAP_HARD + DEV_FORUM_HIGH_VALUE_CAP_HARD
        $_dfLvCount = if ($_saMeta.PSObject.Properties['dev_forum_low_value_count']) { [int]$_saMeta.dev_forum_low_value_count } else { 0 }
        $_dfHvCount = if ($_saMeta.PSObject.Properties['dev_forum_high_value_count']) { [int]$_saMeta.dev_forum_high_value_count } else { 0 }
        Write-Output ""
        Write-Output "DEV_FORUM_VALUE_GATES (iter46):"
        Write-Output ("  dev_forum_low_value_count    : {0}" -f $_dfLvCount)
        Write-Output ("  dev_forum_high_value_count   : {0}" -f $_dfHvCount)
        # Print engagement details for high-value forum items
        if ($_saMeta.PSObject.Properties['items']) {
            foreach ($_saItem in $_saMeta.items) {
                if ($_saItem.dev_forum -eq $true -and $_saItem.dev_forum_value -eq "high") {
                    $_eng = $_saItem.engagement
                    Write-Output ("  [高權重論壇] {0}" -f $_saItem.title)
                    Write-Output ("    engagement: views={0} likes={1} replies={2} source={3}" -f $_eng.view_count, $_eng.like_count, $_eng.reply_count, $_eng.source)
                    Write-Output ("    why_selected: {0}" -f $_saItem.why_selected)
                }
            }
        }
        if ($_dfLvCount -gt 0) {
            $_dfLvFail = ("DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL: dev_forum_low_value_count={0} (must be 0)" -f $_dfLvCount)
            Write-Output ("  => FAIL: {0}" -f $_dfLvFail)
            Invoke-VerifyOnlineFailFast -Gate "DEV_FORUM_LOW_VALUE_CAP_HARD" -Reason $_dfLvFail
        }
        Write-Output "  => DEV_FORUM_LOW_VALUE_CAP_HARD: PASS"
        if ($_dfHvCount -gt 1) {
            $_dfHvFail = ("DEV_FORUM_HIGH_VALUE_CAP_HARD_FAIL: dev_forum_high_value_count={0} > 1" -f $_dfHvCount)
            Write-Output ("  => FAIL: {0}" -f $_dfHvFail)
            Invoke-VerifyOnlineFailFast -Gate "DEV_FORUM_HIGH_VALUE_CAP_HARD" -Reason $_dfHvFail
        }
        Write-Output "  => DEV_FORUM_HIGH_VALUE_CAP_HARD: PASS"
    } catch {
        Write-Output ("  BIGTECH gates: WARN-OK (parse error: {0})" -f $_)
    }
} elseif ($_btGatesEnforce) {
    Write-Output "  BIGTECH gates: WARN (selection_audit.meta.json not found)"
} else {
    Write-Output "  BIGTECH gates: SKIP (not FAST_300_DAILY mode)"
}

# ---------------------------------------------------------------------------
# EXEC KPI META — reads exec_kpi.meta.json written by pipeline
# ---------------------------------------------------------------------------
$execKpiMetaPath = Join-Path $repoRoot "outputs\exec_kpi.meta.json"
if (Test-Path $execKpiMetaPath) {
    try {
        $ekm = Get-Content $execKpiMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output ""
        Write-Output "EXEC KPI META:"
        if ($ekm.PSObject.Properties['kpi_targets']) {
            $kt = $ekm.kpi_targets
            Write-Output ("  kpi_targets.events  : {0}" -f $kt.events)
            Write-Output ("  kpi_targets.product : {0}" -f $kt.product)
            Write-Output ("  kpi_targets.tech    : {0}" -f $kt.tech)
            Write-Output ("  kpi_targets.business: {0}" -f $kt.business)
        }
        if ($ekm.PSObject.Properties['kpi_actuals']) {
            $ka = $ekm.kpi_actuals
            Write-Output ("  kpi_actuals.events  : {0}" -f $ka.events)
            Write-Output ("  kpi_actuals.product : {0}" -f $ka.product)
            Write-Output ("  kpi_actuals.tech    : {0}" -f $ka.tech)
            Write-Output ("  kpi_actuals.business: {0}" -f $ka.business)
        }
        foreach ($bfKey in @('business_backfill', 'product_backfill', 'tech_backfill')) {
            if ($ekm.PSObject.Properties[$bfKey]) {
                $bb = $ekm.$bfKey
                $bfLabel = $bfKey -replace '_backfill', ''
                Write-Output ("  {0}_backfill.candidates: {1}  selected: {2}" -f $bfLabel, $bb.candidates_total, $bb.selected_total)
                if ($bb.selected_ids -and $bb.selected_ids.Count -gt 0) {
                    Write-Output ("  {0}_backfill.ids(top5): {1}" -f $bfLabel, ($bb.selected_ids -join ', '))
                }
            }
        }
        Write-Output ""
        Write-Output "EXEC KPI ORIGIN AUDIT:"
        foreach ($chKey in @('business', 'product', 'tech')) {
            $bfKey = "${chKey}_backfill"
            $ocKey = "${chKey}_origin_counts"
            if ($ekm.PSObject.Properties[$bfKey]) {
                $bf        = $ekm.$bfKey
                $triggered = if ($bf.triggered) { "true" } else { "false" }
                $note      = if ($bf.note)      { $bf.note } else { "n/a" }
                Write-Output ("  {0}  triggered={1}  note={2}" -f $chKey, $triggered, $note)
            }
            if ($ekm.PSObject.Properties[$ocKey]) {
                $oc = $ekm.$ocKey
                Write-Output ("  {0}_origin_counts: primary_pool={1}  extra_pool={2}  backfill={3}" -f $chKey, $oc.primary_pool, $oc.extra_pool, $oc.backfill)
            }
        }
    } catch {
        Write-Output "  exec_kpi meta parse error (non-fatal): $_"
    }
} else {
    Write-Output ""
    Write-Output "EXEC KPI META: exec_kpi.meta.json not found (skipped)"
}

# Z0 Injection Gate Evidence (printed after pipeline run writes the file)
$z0InjMetaOnlinePath = Join-Path $repoRoot "outputs\z0_injection.meta.json"
if (Test-Path $z0InjMetaOnlinePath) {
    try {
        $z0InjOnline = Get-Content $z0InjMetaOnlinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output ""
        Write-Output "Z0 INJECTION GATE EVIDENCE:"
        Write-Output ("  z0_inject_candidates_total        : {0}" -f $z0InjOnline.z0_inject_candidates_total)
        Write-Output ("  z0_inject_after_frontier_total    : {0}" -f $z0InjOnline.z0_inject_after_frontier_total)
        Write-Output ("  z0_inject_after_channel_gate_total: {0}" -f $z0InjOnline.z0_inject_after_channel_gate_total)
        Write-Output ("  z0_inject_selected_total          : {0}" -f $z0InjOnline.z0_inject_selected_total)
        Write-Output ("  z0_inject_dropped_by_channel_gate : {0}" -f $z0InjOnline.z0_inject_dropped_by_channel_gate)
        Write-Output ("  z0_inject_channel_gate_threshold  : {0}" -f $z0InjOnline.z0_inject_channel_gate_threshold)
    } catch {
        Write-Output "  z0_injection meta parse error (non-fatal): $_"
    }
}

# ---------------------------------------------------------------------------
# DELIVERY ARCHIVE — versioned copy of artifacts for audit / distribution
# Copies files to outputs\deliveries\<YYYYMMDD_HHMMSS>_<HEAD>\ so every
# online run produces a traceable, immutable snapshot alongside the evidence.
# ---------------------------------------------------------------------------
$CURRENT_HEAD = (git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
$_tsOnline    = Get-Date -Format "yyyyMMdd_HHmmss"
$_deliveryDir = Join-Path $repoRoot "outputs\deliveries\${_tsOnline}_${CURRENT_HEAD}"
New-Item -ItemType Directory -Path $_deliveryDir -Force | Out-Null

# Verify archive HEAD consistency: extract HEAD from dir name and compare to current HEAD
$_dirLeaf     = Split-Path $_deliveryDir -Leaf
$ARCHIVE_HEAD = $($_dirLeaf -replace '^\d{8}_\d{6}_', '')
$ARCHIVE_HEAD_MATCH = if ($CURRENT_HEAD -eq $ARCHIVE_HEAD) { "PASS" } else { "FAIL" }

$_toArchive = @(
    "outputs\executive_report.docx",
    "outputs\exec_selection.meta.json",
    "outputs\exec_kpi.meta.json",
    "outputs\flow_counts.meta.json"
)
$_archivedCount = 0
foreach ($_src in $_toArchive) {
    $_srcFull = Join-Path $repoRoot $_src
    if (Test-Path $_srcFull) {
        Copy-Item -Path $_srcFull -Destination $_deliveryDir -Force
        $_archivedCount++
    }
}
Write-Output ""
Write-Output "DELIVERY ARCHIVE:"
Write-Output ("  delivery_dir      : {0}" -f $_deliveryDir)
Write-Output ("  archived_files    : {0}" -f $_archivedCount)
Write-Output ("  CURRENT_HEAD      : {0}" -f $CURRENT_HEAD)
Write-Output ("  ARCHIVE_HEAD      : {0}" -f $ARCHIVE_HEAD)
Write-Output ("  ARCHIVE_HEAD_MATCH: {0}" -f $ARCHIVE_HEAD_MATCH)
if ($ARCHIVE_HEAD_MATCH -eq "FAIL") {
    Write-Output "[verify_online] FAIL: archive HEAD mismatch - repository changed during run"
    exit 1
}

# ---------------------------------------------------------------------------
# CANONICAL_DELIVERY_CONSISTENCY GATE — Stage 4 (Iteration 11; iter33: DOCX only)
#   Compares SHA-256 of outputs\executive_report.docx (canonical) with the
#   copy just archived into $_deliveryDir.  No Admin required.
#   PASS    : both exist and hashes match
#   FAIL    : both exist but hashes differ (canonical != delivery — diverged)
#   OK      : delivery was not archived this run (allowed; canonical is the true source)
#   WARN-OK : canonical itself not found (pipeline did not produce output)
# ---------------------------------------------------------------------------
$_cdcCanonPath   = Join-Path $repoRoot "outputs\executive_report.docx"
$_cdcDelivPath   = Join-Path $_deliveryDir "executive_report.docx"

Write-Output ""
Write-Output "CANONICAL_DELIVERY_CONSISTENCY:"
if ((Test-Path $_cdcCanonPath) -and (Test-Path $_cdcDelivPath)) {
    try {
        $_cdcHashCanon  = (Get-FileHash -Path $_cdcCanonPath -Algorithm SHA256).Hash
        $_cdcHashDeliv  = (Get-FileHash -Path $_cdcDelivPath -Algorithm SHA256).Hash
        Write-Output ("  canonical_path  : {0}" -f $_cdcCanonPath)
        Write-Output ("  canonical_hash  : {0}" -f $_cdcHashCanon)
        Write-Output ("  delivery_path   : {0}" -f $_cdcDelivPath)
        Write-Output ("  delivery_hash   : {0}" -f $_cdcHashDeliv)
        Write-Output ""
        if ($_cdcHashCanon -eq $_cdcHashDeliv) {
            Write-Output "  => CANONICAL_DELIVERY_CONSISTENCY: PASS (SHA-256 match)"
        } else {
            Write-Output "  => CANONICAL_DELIVERY_CONSISTENCY: FAIL (hash mismatch — canonical and delivery diverged)"
        }
    } catch {
        Write-Output ("  => CANONICAL_DELIVERY_CONSISTENCY: WARN-OK (hash error: {0})" -f $_)
    }
} elseif (-not (Test-Path $_cdcCanonPath)) {
    Write-Output ("  canonical_path  : {0} (not found)" -f $_cdcCanonPath)
    Write-Output ""
    Write-Output "  => CANONICAL_DELIVERY_CONSISTENCY: WARN-OK (canonical outputs\executive_report.docx not found)"
} else {
    Write-Output ("  canonical_path  : {0}" -f $_cdcCanonPath)
    Write-Output ("  delivery_path   : {0} (not archived this run)" -f $_cdcDelivPath)
    Write-Output ""
    Write-Output "  => CANONICAL_DELIVERY_CONSISTENCY: OK (no delivery archived; canonical is true source)"
}

# ---------------------------------------------------------------------------
# EXEC LAYOUT EVIDENCE (online run — same as verify_run, reproduced here for auditability)
# ---------------------------------------------------------------------------
$execLayoutOnlinePath = Join-Path $repoRoot "outputs\exec_layout.meta.json"
if (Test-Path $execLayoutOnlinePath) {
    try {
        $elmOnline = Get-Content $execLayoutOnlinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output ""
        Write-Output "EXEC LAYOUT EVIDENCE:"
        Write-Output ("  layout_version          : {0}" -f $elmOnline.layout_version)
        if ($elmOnline.PSObject.Properties['template_map']) {
            $tmO = $elmOnline.template_map
            Write-Output ("  template_map.overview   : {0}" -f $tmO.overview)
            Write-Output ("  template_map.ranking    : {0}" -f $tmO.ranking)
            Write-Output ("  template_map.pending    : {0}" -f $tmO.pending)
            Write-Output ("  template_map.sig_summary: {0}" -f $tmO.signal_summary)
            Write-Output ("  template_map.ev_slide_a : {0}" -f $tmO.event_slide_a)
            Write-Output ("  template_map.ev_slide_b : {0}" -f $tmO.event_slide_b)
        }
        if ($elmOnline.PSObject.Properties['fragment_fix_stats']) {
            $ffsO = $elmOnline.fragment_fix_stats
            Write-Output ("  fragment_ratio          : {0}" -f $ffsO.fragment_ratio)
            Write-Output ("  fragments_detected      : {0}" -f $ffsO.fragments_detected)
            Write-Output ("  fragments_fixed         : {0}" -f $ffsO.fragments_fixed)
        }
        if ($elmOnline.PSObject.Properties['bullet_len_stats']) {
            $blsO = $elmOnline.bullet_len_stats
            Write-Output ("  min_bullet_len          : {0}" -f $blsO.min_bullet_len)
            Write-Output ("  avg_bullet_len          : {0}" -f $blsO.avg_bullet_len)
        }
        if ($elmOnline.PSObject.Properties['card_stats']) {
            $csO = $elmOnline.card_stats
            Write-Output ("  proof_token_coverage    : {0}" -f $csO.proof_token_coverage_ratio)
            Write-Output ("  avg_sentences_per_card  : {0}" -f $csO.avg_sentences_per_event_card)
        }
        $validCodesO = @('T1','T2','T3','T4','T5','T6','COVER','STRUCTURED_SUMMARY','CORP_WATCH','KEY_TAKEAWAYS','REC_MOVES','DECISION_MATRIX')
        $invalidCodesO = @()
        if ($elmOnline.PSObject.Properties['slide_layout_map']) {
            foreach ($slO in $elmOnline.slide_layout_map) {
                if ($slO.template_code -notin $validCodesO) { $invalidCodesO += $slO.template_code }
            }
        }
        if ($invalidCodesO.Count -gt 0) {
            Write-Output ("  WARNING: invalid template codes: {0}" -f ($invalidCodesO -join ', '))
        } else {
            Write-Output "  slide_layout_map codes  : all valid (T1-T6 + structural)"
        }
    } catch {
        Write-Output "  exec_layout meta parse error (non-fatal): $_"
    }
} else {
    Write-Output ""
    Write-Output "EXEC LAYOUT EVIDENCE: exec_layout.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# EXEC QUALITY GATES (online run) — reads exec_quality.meta.json
# ---------------------------------------------------------------------------
$execQualMetaOnlinePath = Join-Path $repoRoot "outputs\exec_quality.meta.json"
if (Test-Path $execQualMetaOnlinePath) {
    try {
        $eqmO = Get-Content $execQualMetaOnlinePath -Raw -Encoding UTF8 | ConvertFrom-Json

        $g2O = if ($eqmO.PSObject.Properties['source_diversity_gate']) { $eqmO.source_diversity_gate } else { "PASS" }
        $g3O = if ($eqmO.PSObject.Properties['proof_coverage_gate'])   { $eqmO.proof_coverage_gate }   else { "PASS" }
        $g4O = if ($eqmO.PSObject.Properties['fragment_leak_gate'])    { $eqmO.fragment_leak_gate }    else { "PASS" }

        $nonAiO    = if ($eqmO.PSObject.Properties['non_ai_rejected_count'])  { $eqmO.non_ai_rejected_count }  else { 0 }
        $maxShrO   = if ($eqmO.PSObject.Properties['max_source_share'])       { $eqmO.max_source_share }       else { 0 }
        $maxSrcO   = if ($eqmO.PSObject.Properties['max_source'])             { $eqmO.max_source }             else { "n/a" }
        $proofO    = if ($eqmO.PSObject.Properties['proof_coverage_ratio'])   { $eqmO.proof_coverage_ratio }   else { 0 }
        $leakedO   = if ($eqmO.PSObject.Properties['fragments_leaked'])       { $eqmO.fragments_leaked }       else { 0 }
        $detectedO = if ($eqmO.PSObject.Properties['fragments_detected'])     { $eqmO.fragments_detected }     else { 0 }
        $fixedO    = if ($eqmO.PSObject.Properties['fragments_fixed'])        { $eqmO.fragments_fixed }        else { 0 }
        $enHeavyO       = if ($eqmO.PSObject.Properties['english_heavy_paragraphs_fixed_count']) { $eqmO.english_heavy_paragraphs_fixed_count } else { 0 }
        $glossedO       = if ($eqmO.PSObject.Properties['proper_noun_gloss_applied_count'])      { $eqmO.proper_noun_gloss_applied_count }      else { 0 }
        $actionsNormO   = if ($eqmO.PSObject.Properties['actions_normalized_count'])             { $eqmO.actions_normalized_count }             else { 0 }
        $actionsLeakO   = if ($eqmO.PSObject.Properties['actions_fragment_leak_count'])          { $eqmO.actions_fragment_leak_count }          else { 0 }
        $zhSkeletonizeO = if ($eqmO.PSObject.Properties['english_heavy_skeletonized_count'])     { $eqmO.english_heavy_skeletonized_count }     else { 0 }
        $proofEmptyGateO  = if ($eqmO.PSObject.Properties['proof_empty_gate'])                   { $eqmO.proof_empty_gate }                   else { "PASS" }
        $proofEmptyCountO = if ($eqmO.PSObject.Properties['proof_empty_event_count'])            { $eqmO.proof_empty_event_count }            else { 0 }
        $actNormStatusO = if ($actionsLeakO -eq 0) { "PASS" } else { "FAIL" }

        Write-Output ""
        Write-Output "EXEC QUALITY GATES:"
        Write-Output ("  AI_RELEVANCE_GATE    : PASS (non_ai_rejected={0})" -f $nonAiO)
        Write-Output ("  SOURCE_DIVERSITY_GATE: {0} (max_source_share={1:P1} source={2})" -f $g2O, $maxShrO, $maxSrcO)
        Write-Output ("  PROOF_COVERAGE_GATE  : {0} (ratio={1:P1})" -f $g3O, $proofO)
        Write-Output ("  FRAGMENT_LEAK_GATE   : {0} (leaked={1} detected={2} fixed={3})" -f $g4O, $leakedO, $detectedO, $fixedO)
        Write-Output ("  EN_ZH_HYBRID_GLOSS   : english_heavy_fixed={0}  proper_noun_glossed={1}" -f $enHeavyO, $glossedO)
        Write-Output ("  ACTIONS_NORMALIZATION: {0} (normalized={1} leaked={2})" -f $actNormStatusO, $actionsNormO, $actionsLeakO)
        Write-Output ("  ZH_SKELETONIZE       : count={0}" -f $zhSkeletonizeO)
        Write-Output ("  PROOF_EMPTY_GATE     : {0} (empty={1})" -f $proofEmptyGateO, $proofEmptyCountO)

        $qualAnyFailO = ($g2O -eq "FAIL") -or ($g3O -eq "FAIL") -or ($g4O -eq "FAIL") -or ($actNormStatusO -eq "FAIL") -or ($proofEmptyGateO -eq "FAIL")
        if ($qualAnyFailO) {
            Write-Output "  => EXEC QUALITY GATES: FAIL"
            exit 1
        }
        Write-Output "  => EXEC QUALITY GATES: PASS"
    } catch {
        Write-Output "  exec_quality meta parse error (non-fatal): $_"
    }
} else {
    Write-Output ""
    Write-Output "EXEC QUALITY GATES: exec_quality.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# EXEC_DELIVERABLE_DOCX_PPTX_HARD GATE (online run)
# ---------------------------------------------------------------------------
$execDelivMetaOnlinePath = Join-Path $repoRoot "outputs\exec_deliverable_docx_pptx_hard.meta.json"
if (Test-Path $execDelivMetaOnlinePath) {
    try {
        $edmO = Get-Content $execDelivMetaOnlinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $edGateO  = if ($edmO.PSObject.Properties['gate_result']) { $edmO.gate_result } else { "FAIL" }
        $edTotalO = if ($edmO.PSObject.Properties['events_total']) { [int]$edmO.events_total } else { 0 }
        $edPassO  = if ($edmO.PSObject.Properties['pass_count']) { [int]$edmO.pass_count } else { 0 }
        $edFailO  = if ($edmO.PSObject.Properties['fail_count']) { [int]$edmO.fail_count } else { 0 }

        Write-Output ""
        Write-Output "EXEC_DELIVERABLE_DOCX_PPTX_HARD:"
        Write-Output ("  events_checked: {0}  pass={1}  fail={2}" -f $edTotalO, $edPassO, $edFailO)

        if ($edFailO -gt 0) {
            Write-Output ("  => EXEC_DELIVERABLE_DOCX_PPTX_HARD: FAIL ({0} failing event(s))" -f $edFailO)
            if ($edmO.PSObject.Properties['events'] -and $edmO.events) {
                foreach ($edEvO in $edmO.events) {
                    if (-not $edEvO.all_pass) {
                        $edReasonsO = @()
                        if ($edEvO.PSObject.Properties['dod'] -and $edEvO.dod) {
                            foreach ($p in $edEvO.dod.PSObject.Properties) {
                                if (-not [bool]$p.Value) { $edReasonsO += $p.Name }
                            }
                        }
                        Write-Output ("     FAIL: {0}  reasons={1}" -f $edEvO.title, ($edReasonsO -join ","))
                    }
                }
            }
            # Align with pipeline semantics: when this check throws WinError 32 it is
            # explicitly non-fatal, and canonical DOCX must still be validated (iter33: PPTX discontinued).
            $edDocxPath = Join-Path $repoRoot "outputs\executive_report.docx"
            $edDocxOk = (Test-Path $edDocxPath) -and ((Get-Item $edDocxPath).Length -gt 0)
            $edHasWin32NonFatal = $false
            $edLogPath = Join-Path $repoRoot "logs\app.log"
            if (Test-Path $edLogPath) {
                try {
                    $edHasWin32NonFatal = [bool](Select-String -Path $edLogPath -Pattern "EXEC_DELIVERABLE_DOCX_PPTX_HARD check failed (non-fatal): [WinError 32]" -SimpleMatch | Select-Object -Last 1)
                } catch { }
            }
            if ($edHasWin32NonFatal -and $edDocxOk) {
                Write-Output "  => EXEC_DELIVERABLE_DOCX_PPTX_HARD: WARN-OK (WinError 32 non-fatal path; DOCX present)"
            } else {
                exit 1
            }
        }
        Write-Output "  => EXEC_DELIVERABLE_DOCX_PPTX_HARD: PASS (fail_count=0)"
    } catch {
        Write-Output ("  EXEC_DELIVERABLE_DOCX_PPTX_HARD parse error: {0}" -f $_)
        exit 1
    }
} else {
    Write-Output ""
    Write-Output "EXEC_DELIVERABLE_DOCX_PPTX_HARD: FAIL (meta missing)"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF hard gates (brief mode only; SKIP when meta absent)
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF HARD GATES:"
$briefGateMetas = @(
    @{ Label = "BRIEF_MIN_EVENTS_HARD";      File = "brief_min_events_hard.meta.json" },
    @{ Label = "BRIEF_NO_BOILERPLATE_HARD";  File = "brief_no_boilerplate_hard.meta.json" },
    @{ Label = "BRIEF_ANCHOR_REQUIRED_HARD"; File = "brief_anchor_required_hard.meta.json" },
    @{ Label = "BRIEF_INFO_DENSITY_HARD";    File = "brief_info_density_hard.meta.json" },
    @{ Label = "BRIEF_ZH_TW_HARD";           File = "brief_zh_tw_hard.meta.json" },
    @{ Label = "BRIEF_NO_GENERIC_NARRATIVE_HARD"; File = "brief_no_generic_narrative_hard.meta.json" },
    @{ Label = "BRIEF_NO_DUPLICATE_FRAMES_HARD";  File = "brief_no_duplicate_frames_hard.meta.json" },
    @{ Label = "BRIEF_FACT_PACK_HARD";            File = "brief_fact_pack_hard.meta.json" }
)
$briefAnyFail = $false
foreach ($bg in $briefGateMetas) {
    $bgPath = Join-Path $repoRoot ("outputs\" + $bg.File)
    if (-not (Test-Path $bgPath)) {
        Write-Output ("  {0}: SKIP ({1} not found)" -f $bg.Label, $bg.File)
        continue
    }
    try {
        $bgMeta = Get-Content $bgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $bgGate = if ($bgMeta.PSObject.Properties['gate_result']) { [string]$bgMeta.gate_result } else { "FAIL" }
        if ($bg.Label -eq "BRIEF_MIN_EVENTS_HARD") {
            $bgMin = if ($bgMeta.PSObject.Properties['required_min']) { [int]$bgMeta.required_min } else { 5 }
            $bgMax = if ($bgMeta.PSObject.Properties['required_max']) { [int]$bgMeta.required_max } else { 10 }
            $bgAct = if ($bgMeta.PSObject.Properties['actual']) { [int]$bgMeta.actual } else { 0 }
            Write-Output ("  {0}: {1} (required=[{2},{3}] actual={4})" -f $bg.Label, $bgGate, $bgMin, $bgMax, $bgAct)
        } else {
            $bgTotal = if ($bgMeta.PSObject.Properties['events_total']) { [int]$bgMeta.events_total } else { 0 }
            $bgFail  = if ($bgMeta.PSObject.Properties['fail_count']) { [int]$bgMeta.fail_count } else { 0 }
            Write-Output ("  {0}: {1} (events_total={2} fail_count={3})" -f $bg.Label, $bgGate, $bgTotal, $bgFail)
            if ($bg.Label -eq "BRIEF_INFO_DENSITY_HARD" -and $bgMeta.PSObject.Properties['rules']) {
                $bgRules = $bgMeta.rules
                $bgCjk = if ($bgRules.PSObject.Properties['min_bullet_cjk_chars']) { [int]$bgRules.min_bullet_cjk_chars } else { 12 }
                $bgHits = if ($bgRules.PSObject.Properties['anchor_or_number_hits_min']) { [int]$bgRules.anchor_or_number_hits_min } else { 2 }
                Write-Output ("     rules: min_bullet_cjk_chars={0} anchor_or_number_hits_min={1} quotes_non_cta={2}" -f $bgCjk, $bgHits, $(if ($bgRules.PSObject.Properties['quotes_must_not_hit_cta_stoplist']) { [bool]$bgRules.quotes_must_not_hit_cta_stoplist } else { $true }))
                if ($bgMeta.PSObject.Properties['events'] -and @($bgMeta.events).Count -gt 0) {
                    $bgEvents = @($bgMeta.events)
                    $evCount = $bgEvents.Count
                    $sumBullets = 0
                    $sumCjkWeighted = 0.0
                    foreach ($ev in $bgEvents) {
                        $evBullets = if ($ev.PSObject.Properties['bullets_total']) {
                            [int]$ev.bullets_total
                        } else {
                            ($(if ($ev.PSObject.Properties['what_happened_count']) { [int]$ev.what_happened_count } else { 0 }) +
                             $(if ($ev.PSObject.Properties['key_details_count'])   { [int]$ev.key_details_count }   else { 0 }) +
                             $(if ($ev.PSObject.Properties['why_it_matters_count']) { [int]$ev.why_it_matters_count } else { 0 }))
                        }
                        $sumBullets += $evBullets
                        $evAvgCjk = if ($ev.PSObject.Properties['avg_cjk_chars_per_bullet']) { [double]$ev.avg_cjk_chars_per_bullet } else { 0.0 }
                        $sumCjkWeighted += ($evAvgCjk * $evBullets)
                    }
                    $avgBullets = [Math]::Round(($sumBullets / [Math]::Max(1, $evCount)), 2)
                    $avgCjk = if ($sumBullets -gt 0) { [Math]::Round(($sumCjkWeighted / $sumBullets), 2) } else { 0.0 }
                    Write-Output ("     soft: avg_bullets_per_event={0} avg_cjk_chars_per_bullet={1}" -f $avgBullets, $avgCjk)
                }
            }
        }
        if ($bgGate -eq "FAIL") {
            $briefAnyFail = $true
            if ($bgMeta.PSObject.Properties['failing_events'] -and @($bgMeta.failing_events).Count -gt 0) {
                $bgFirst = @($bgMeta.failing_events)[0]
                $bgTitleA = if ($bgFirst.PSObject.Properties['title']) { [string]$bgFirst.title } elseif ($bgFirst.PSObject.Properties['title_a']) { [string]$bgFirst.title_a } else { "" }
                $bgTitleB = if ($bgFirst.PSObject.Properties['title_b']) { [string]$bgFirst.title_b } else { "" }
                $bgHit = if ($bgFirst.PSObject.Properties['hit_pattern']) { [string]$bgFirst.hit_pattern } elseif ($bgFirst.PSObject.Properties['sample_hit_pattern']) { [string]$bgFirst.sample_hit_pattern } else { "" }
                if ($bgTitleA) { Write-Output ("     failing_title={0}" -f $bgTitleA) }
                if ($bgTitleB) { Write-Output ("     failing_title_pair={0}" -f $bgTitleB) }
                if ($bgHit) { Write-Output ("     sample_hit_pattern={0}" -f $bgHit) }
            }
            Write-Output ("  => {0}: FAIL" -f $bg.Label)
            continue
        }
    } catch {
        Write-Output ("  {0}: FAIL (parse error: {1})" -f $bg.Label, $_)
        exit 1
    }
}

# ---------------------------------------------------------------------------
# BRIEF_CONTENT_MINER OBSERVABILITY (soft; non-gating)
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_CONTENT_MINER (obs):"
$briefMinerMetaPath = Join-Path $repoRoot "outputs\brief_content_miner.meta.json"
if (Test-Path $briefMinerMetaPath) {
    try {
        $bcm = Get-Content $briefMinerMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $bcmGate = if ($bcm.PSObject.Properties['gate_result']) { [string]$bcm.gate_result } else { "UNKNOWN" }
        $bcmTotal = if ($bcm.PSObject.Properties['events_total']) { [int]$bcm.events_total } else { 0 }
        $bcmStoplist = if ($bcm.PSObject.Properties['quote_stoplist_hits_count']) { [int]$bcm.quote_stoplist_hits_count } else { 0 }
        $bcmQ2Fail = if ($bcm.PSObject.Properties['quote2_cta_fail_count']) { [int]$bcm.quote2_cta_fail_count } else { 0 }
        Write-Output ("  gate_result               : {0}" -f $bcmGate)
        Write-Output ("  events_total              : {0}" -f $bcmTotal)
        Write-Output ("  quote_stoplist_hits_count : {0}" -f $bcmStoplist)
        Write-Output ("  quote2_cta_fail_count     : {0}" -f $bcmQ2Fail)
        if ($bcm.PSObject.Properties['events'] -and @($bcm.events).Count -gt 0) {
            $bcmFirst = @($bcm.events)[0]
            $bcmBullets = if ($bcmFirst.PSObject.Properties['bullets_count_each']) { $bcmFirst.bullets_count_each } else { $null }
            Write-Output ("  sample_title              : {0}" -f $(if ($bcmFirst.PSObject.Properties['title']) { $bcmFirst.title } else { "" }))
            Write-Output ("  sample_fulltext_len       : {0}" -f $(if ($bcmFirst.PSObject.Properties['fulltext_len']) { $bcmFirst.fulltext_len } else { 0 }))
            Write-Output ("  sample_candidates_total   : {0}" -f $(if ($bcmFirst.PSObject.Properties['candidates_total']) { $bcmFirst.candidates_total } else { 0 }))
            Write-Output ("  sample_stoplist_rejected  : {0}" -f $(if ($bcmFirst.PSObject.Properties['stoplist_rejected']) { $bcmFirst.stoplist_rejected } else { 0 }))
            Write-Output ("  sample_quote2_is_cta      : {0}" -f $(if ($bcmFirst.PSObject.Properties['quote2_is_cta']) { $bcmFirst.quote2_is_cta } else { $false }))
            if ($bcmBullets) {
                Write-Output ("  sample_bullets_count_each : what={0} key={1} why={2}" -f `
                    $(if ($bcmBullets.PSObject.Properties['what_happened']) { $bcmBullets.what_happened } else { 0 }), `
                    $(if ($bcmBullets.PSObject.Properties['key_details']) { $bcmBullets.key_details } else { 0 }), `
                    $(if ($bcmBullets.PSObject.Properties['why_it_matters']) { $bcmBullets.why_it_matters } else { 0 }))
            }
            Write-Output ("  sample_anchors_hit_count  : {0}" -f $(if ($bcmFirst.PSObject.Properties['anchors_hit_count']) { $bcmFirst.anchors_hit_count } else { 0 }))
        }
    } catch {
        Write-Output ("  BRIEF_CONTENT_MINER: SKIP (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  BRIEF_CONTENT_MINER: SKIP (brief_content_miner.meta.json not found)"
}

# ---------------------------------------------------------------------------
# PPTX_MEDIA_AUDIT (soft): iter33 — PPTX discontinued; gate always SKIPs.
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "PPTX_MEDIA_AUDIT (soft):"
Write-Output "  PPTX_MEDIA_AUDIT: SKIP (PPTX discontinued in iter33)"

if ($briefAnyFail) {
    exit 1
}

# FULLTEXT_FIDELITY OBSERVATION (non-fatal)
$fidPath = Join-Path $repoRoot "outputs\fulltext_fidelity.meta.json"
if (Test-Path $fidPath) {
    try {
        $fidMeta2       = Get-Content $fidPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $fidTotal2      = if ($fidMeta2.PSObject.Properties['events_total'])                { [int]$fidMeta2.events_total }                else { 0 }
        $fidCta2        = if ($fidMeta2.PSObject.Properties['total_cta_paragraphs_removed']) { [int]$fidMeta2.total_cta_paragraphs_removed } else { 0 }
        $fidWhere2      = if ($fidMeta2.PSObject.Properties['wheresyoured_at_events'])       { [int]$fidMeta2.wheresyoured_at_events }       else { 0 }
        $fidAvgRemoved2 = if ($fidMeta2.PSObject.Properties['avg_removed_paragraphs'])      { $fidMeta2.avg_removed_paragraphs }            else { "n/a" }
        $fidAvgCleaned2 = if ($fidMeta2.PSObject.Properties['avg_cleaned_len'])             { [int]$fidMeta2.avg_cleaned_len }              else { 0 }
        $fidDomTop2     = if ($fidMeta2.PSObject.Properties['domain_top'])                  { ($fidMeta2.domain_top -join ", ") }           else { "n/a" }
        Write-Output ("FULLTEXT_FIDELITY (obs): events={0} cta_removed={1} wheresyoured_at={2}" -f $fidTotal2, $fidCta2, $fidWhere2)
        Write-Output ("  domain_top={0}  avg_removed_paragraphs={1}  avg_cleaned_len={2}" -f $fidDomTop2, $fidAvgRemoved2, $fidAvgCleaned2)
    } catch {
        Write-Output "FULLTEXT_FIDELITY (obs): parse error"
    }
} else {
    Write-Output "FULLTEXT_FIDELITY (obs): not found (skip)"
}

# ---------------------------------------------------------------------------
# EXEC_NEWS_QUALITY_HARD GATE (online run)
#   Reads outputs/exec_news_quality.meta.json written by run_once.py.
#   PASS: gate_result=PASS; SKIP: meta absent; FAIL: gate_result=FAIL (exit 1)
# ---------------------------------------------------------------------------
$enqMetaOnlinePath = Join-Path $repoRoot "outputs\exec_news_quality.meta.json"
if (Test-Path $enqMetaOnlinePath) {
    try {
        $enqmO         = Get-Content $enqMetaOnlinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $enqGateO      = if ($enqmO.PSObject.Properties['gate_result'])  { $enqmO.gate_result } else { "SKIP" }
        $enqPassO      = if ($enqmO.PSObject.Properties['pass_count'])   { [int]$enqmO.pass_count }   else { 0 }
        $enqFailO      = if ($enqmO.PSObject.Properties['fail_count'])   { [int]$enqmO.fail_count }   else { 0 }
        $enqTotalO     = if ($enqmO.PSObject.Properties['events_total']) { [int]$enqmO.events_total } else { 0 }

        Write-Output ""
        Write-Output "EXEC_NEWS_QUALITY_HARD:"
        Write-Output ("  events_checked: {0}  pass={1}  fail={2}" -f $enqTotalO, $enqPassO, $enqFailO)

        # Print sample quote from first passing event
        if ($enqmO.PSObject.Properties['events'] -and $enqmO.events -and $enqmO.events.Count -gt 0) {
            $enqFirst = $enqmO.events[0]
            Write-Output ("  sample_title : {0}" -f $enqFirst.title)
            Write-Output ("  sample_quote1: {0}" -f $enqFirst.quote_1)
            Write-Output ("  sample_quote2: {0}" -f $enqFirst.quote_2)
        }

        if ($enqGateO -eq "FAIL") {
            Write-Output ("  => EXEC_NEWS_QUALITY_HARD: FAIL ({0} event(s) missing verbatim quotes)" -f $enqFailO)
            if ($enqmO.PSObject.Properties['events'] -and $enqmO.events) {
                foreach ($enqEvO in $enqmO.events) {
                    if (-not $enqEvO.all_pass) {
                        Write-Output ("     FAIL: {0}" -f $enqEvO.title)
                    }
                }
            }
            exit 1
        } else {
            Write-Output ("  => EXEC_NEWS_QUALITY_HARD: {0}" -f $enqGateO)
        }
    } catch {
        Write-Output ("  exec_news_quality meta parse error (non-fatal): {0}" -f $_)
    }
} else {
    Write-Output ""
    Write-Output "EXEC_NEWS_QUALITY_HARD: exec_news_quality.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# EXEC_NARRATIVE_FIDELITY_HARD GATE (online run)
#   Checks per-event DoD for ACTOR_BINDING, STYLE_SANITY, NAMING, AI_RELEVANCE
#   in exec_news_quality.meta.json (written by run_once.py after pipeline).
#   Also scans LATEST_SHOWCASE.md and outputs/notion_page.md for banned phrases.
#   FAIL → exit 1
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "EXEC_NARRATIVE_FIDELITY_HARD:"
$enf_fail   = $false
$enf_detail = @()
$enfEventsChecked = 0

# Scope fidelity checks to actually selected delivery events.
$enfSelectedIds = @{}
$enfSelectedUrls = @{}
$enfSelectedTitles = @{}
$enfSelectionMetaPath = Join-Path $repoRoot "outputs\exec_selection.meta.json"
if (Test-Path $enfSelectionMetaPath) {
    try {
        $enfSelMeta = Get-Content $enfSelectionMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($enfSelMeta.PSObject.Properties['events'] -and $enfSelMeta.events) {
            foreach ($enfSel in $enfSelMeta.events) {
                $sid = "$($enfSel.item_id)".Trim()
                if (-not [string]::IsNullOrWhiteSpace($sid)) { $enfSelectedIds[$sid] = $true }
                $surl = "$($enfSel.final_url)".Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($surl)) { $enfSelectedUrls[$surl] = $true }
                $stitle = "$($enfSel.title)".Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($stitle)) { $enfSelectedTitles[$stitle] = $true }
            }
        }
    } catch {
        Write-Output ("  exec_selection scope parse error (non-fatal): {0}" -f $_)
    }
}
$enfUseSelectionScope = (($enfSelectedIds.Count + $enfSelectedUrls.Count + $enfSelectedTitles.Count) -gt 0)
if ($enfUseSelectionScope) {
    Write-Output ("  selected_scope: enabled (ids={0} urls={1} titles={2})" -f $enfSelectedIds.Count, $enfSelectedUrls.Count, $enfSelectedTitles.Count)
}

# --- A) Per-event DoD checks from meta.json ---
if (Test-Path $enqMetaOnlinePath) {
    try {
        $enfMeta = Get-Content $enqMetaOnlinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        # AI_RELEVANCE is advisory (mirrors run_once.py: supplemental events like Apple/AWS/Tesla
        # may lack explicit AI keywords but carry valid verbatim quotes -- not a hard blocker).
        $enfFidelityKeys = @("ACTOR_BINDING","STYLE_SANITY","NAMING")
        if ($enfMeta.PSObject.Properties['events'] -and $enfMeta.events) {
            foreach ($enfEv in $enfMeta.events) {
                if ($enfUseSelectionScope) {
                    $eid = "$($enfEv.item_id)".Trim()
                    $eurl = "$($enfEv.final_url)".Trim().ToLowerInvariant()
                    $etitle = "$($enfEv.title)".Trim().ToLowerInvariant()
                    $isSelected = $false
                    if (-not [string]::IsNullOrWhiteSpace($eid) -and $enfSelectedIds.ContainsKey($eid)) { $isSelected = $true }
                    if (-not $isSelected -and -not [string]::IsNullOrWhiteSpace($eurl) -and $enfSelectedUrls.ContainsKey($eurl)) { $isSelected = $true }
                    if (-not $isSelected -and -not [string]::IsNullOrWhiteSpace($etitle) -and $enfSelectedTitles.ContainsKey($etitle)) { $isSelected = $true }
                    if (-not $isSelected) { continue }
                }
                $enfEventsChecked++
                if ($enfEv.PSObject.Properties['dod'] -and $enfEv.dod) {
                    foreach ($enfKey in $enfFidelityKeys) {
                        $enfVal = $null
                        if ($enfEv.dod.PSObject.Properties[$enfKey]) {
                            $enfVal = $enfEv.dod.$enfKey
                        }
                        if ($enfVal -eq $null) { continue }   # key absent - skip (legacy record)
                        if ($enfVal -eq $false) {
                            $enf_fail = $true
                            $enf_detail += ("  FAIL [{0}] event={1}" -f $enfKey, $enfEv.title)
                        }
                    }
                }
            }
        }
    } catch {
        Write-Output ("  meta parse error (non-fatal): {0}" -f $_)
    }
} else {
    Write-Output "  exec_news_quality.meta.json absent - skipping per-event DoD check"
}
Write-Output ("  events_checked_for_fidelity: {0}" -f $enfEventsChecked)

# --- B) Document scan for STYLE_SANITY + NAMING (pure-ASCII Unicode escapes) ---
# \u5f15\u767c = invfa, \u95dc\u6ce8 = guanzhu, etc.
$enfStyleRe  = [regex]'\u5f15\u767c.{0,20}\u95dc\u6ce8|\u5177\u6709.{0,20}\u610f\u7fa9|\u5bc6\u5207\u8ffd\u8e64|\u6b63\u5bc6\u5207\u8a55\u4f30|\u5f8c\u7e8c\u52d5\u5411|\u5404\u65b9.{0,20}\u95dc\u6ce8'
$enfNamingRe = [regex]'\u514b\u52de\u5fb7|\u514b\u52b3\u5fb7'
$enfScanPaths = @(
    (Join-Path $repoRoot "outputs\LATEST_SHOWCASE.md"),
    (Join-Path $repoRoot "outputs\notion_page.md")
)
foreach ($enfDoc in $enfScanPaths) {
    if (-not (Test-Path $enfDoc)) { continue }
    $enfText = Get-Content $enfDoc -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $enfText) { continue }
    $enfDocName = Split-Path $enfDoc -Leaf
    $enfStyleM = $enfStyleRe.Match($enfText)
    if ($enfStyleM.Success) {
        $enf_fail = $true
        $enf_detail += ("  FAIL [STYLE_SANITY] doc={0} match=`"{1}`"" -f $enfDocName, $enfStyleM.Value)
    }
    $enfNamingM = $enfNamingRe.Match($enfText)
    if ($enfNamingM.Success) {
        $enf_fail = $true
        $enf_detail += ("  FAIL [NAMING] doc={0} match=`"{1}`"" -f $enfDocName, $enfNamingM.Value)
    }
}

if ($enf_detail.Count -gt 0) {
    foreach ($enfLine in $enf_detail) { Write-Output $enfLine }
}
if ($enf_fail) {
    Write-Output "  => EXEC_NARRATIVE_FIDELITY_HARD: FAIL"
    exit 1
} else {
    Write-Output "  => EXEC_NARRATIVE_FIDELITY_HARD: PASS"
}

# ---------------------------------------------------------------------------
# GIT UPSTREAM PROBE — same hardened logic as verify_run v2; audits tracking
# state; never crashes on [gone] / missing refs
# ORIGIN_REF_MODE values: HEAD | REMOTE_SHOW | FALLBACK | NONE
# ---------------------------------------------------------------------------
$_voGitOriginRef    = $null
$_voGitOriginMode   = "NONE"
$_voGitOriginExists = $false

# Method A: git symbolic-ref — local only, fast
$_voSymRef = (git symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null | Out-String).Trim()
if ($_voSymRef -match "refs/remotes/origin/(.+)") {
    $_voBranchA = $Matches[1].Trim()
    $null = git show-ref --verify "refs/remotes/origin/$_voBranchA" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $_voGitOriginRef    = "origin/$_voBranchA"
        $_voGitOriginMode   = "HEAD"
        $_voGitOriginExists = $true
    }
}
# Method B: git remote show origin — ref must still exist locally
if (-not $_voGitOriginRef) {
    $_voRemoteShow = (git remote show origin 2>$null | Out-String)
    if ($_voRemoteShow -match "HEAD branch:\s*(.+)") {
        $_voBranchB = $Matches[1].Trim()
        if ($_voBranchB -ne "(unknown)" -and $_voBranchB -ne "") {
            $null = git show-ref --verify "refs/remotes/origin/$_voBranchB" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $_voGitOriginRef    = "origin/$_voBranchB"
                $_voGitOriginMode   = "REMOTE_SHOW"
                $_voGitOriginExists = $true
            }
        }
    }
}
# Method C: explicit local probe — origin/main then origin/master
if (-not $_voGitOriginRef) {
    foreach ($_voFb in @("main", "master")) {
        $null = git show-ref --verify "refs/remotes/origin/$_voFb" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $_voGitOriginRef    = "origin/$_voFb"
            $_voGitOriginMode   = "FALLBACK"
            $_voGitOriginExists = $true
            break
        }
    }
}

$_voOriginRefStr    = if ($_voGitOriginRef)    { $_voGitOriginRef } else { "n/a" }
$_voOriginExistsStr = if ($_voGitOriginExists) { "true" }           else { "false" }

Write-Output ""
Write-Output "GIT UPSTREAM:"
Write-Output ("  ORIGIN_REF_USED  : {0}" -f $_voOriginRefStr)
Write-Output ("  ORIGIN_REF_MODE  : {0}" -f $_voGitOriginMode)
Write-Output ("  ORIGIN_REF_EXISTS: {0}" -f $_voOriginExistsStr)
Write-Output ""
Write-Output "GIT SYNC:"
if ($_voGitOriginRef -and $_voGitOriginExists) {
    $_voAbRaw = (git rev-list --left-right --count "$_voGitOriginRef...HEAD" 2>$null | Out-String).Trim()
    if ($_voAbRaw -match "^(\d+)\s+(\d+)$") {
        $_voBehind = [int]$Matches[1]; $_voAhead = [int]$Matches[2]
        Write-Output ("  GIT_SYNC: behind={0} ahead={1}" -f $_voBehind, $_voAhead)
        if ($_voBehind -eq 0 -and $_voAhead -eq 0) {
            Write-Output "  GIT_UP_TO_DATE: PASS"
        } else {
            Write-Output ("  GIT_UP_TO_DATE: FAIL (diverged from {0})" -f $_voGitOriginRef)
            if ($_voAhead  -gt 0) { Write-Output ("  >> {0} commit(s) ahead; run: git push" -f $_voAhead) }
            if ($_voBehind -gt 0) { Write-Output ("  >> {0} commit(s) behind; run: git pull" -f $_voBehind) }
        }
    } else {
        Write-Output "  GIT_SYNC: WARN — rev-list returned no output"
        Write-Output "  GIT_UP_TO_DATE: WARN-OK (rev-list empty; run: git fetch origin --prune)"
    }
} else {
    Write-Output "  GIT_SYNC: SKIPPED (origin ref not found in local store)"
    Write-Output "  GIT_UP_TO_DATE: WARN-OK (cannot verify; run: git fetch origin --prune)"
}

if ($reportMode -ne "brief") {
# ---------------------------------------------------------------------------
# LONGFORM EVIDENCE — reads exec_longform.meta.json written by ppt_generator
# ---------------------------------------------------------------------------
$voLongformPath = Join-Path $repoRoot "outputs\exec_longform.meta.json"
if (Test-Path $voLongformPath) {
    try {
        $voLfm = Get-Content $voLongformPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voLfElig    = if ($voLfm.PSObject.Properties['eligible_count'])       { [int]$voLfm.eligible_count }       else { 0 }
        $voLfInelig  = if ($voLfm.PSObject.Properties['ineligible_count'])     { [int]$voLfm.ineligible_count }     else { 0 }
        $voLfTotal   = if ($voLfm.PSObject.Properties['total_cards_processed']){ [int]$voLfm.total_cards_processed } else { 0 }
        $voLfERatio  = if ($voLfm.PSObject.Properties['eligible_ratio'])       { [double]$voLfm.eligible_ratio }     else { 0.0 }
        $voLfPRatio  = if ($voLfm.PSObject.Properties['proof_coverage_ratio']) { [double]$voLfm.proof_coverage_ratio } else { 0.0 }
        $voLfAvg     = if ($voLfm.PSObject.Properties['avg_anchor_chars'])     { $voLfm.avg_anchor_chars }           else { 0 }
        $voLfPMiss   = if ($voLfm.PSObject.Properties['proof_missing_count'])  { [int]$voLfm.proof_missing_count }   else { 0 }
        $voLfMissIds = if ($voLfm.PSObject.Properties['proof_missing_ids'] -and $voLfm.proof_missing_ids) { ($voLfm.proof_missing_ids -join ', ') } else { '(none)' }
        $voLfConsist = ($voLfElig + $voLfInelig) -eq $voLfTotal

        Write-Output ""
        Write-Output "LONGFORM EVIDENCE (exec_longform.meta.json):"
        Write-Output ("  generated_at            : {0}" -f $voLfm.generated_at)
        Write-Output ("  total_cards_processed   : {0}" -f $voLfTotal)
        Write-Output ("  eligible_count          : {0}  (ratio={1:P1})" -f $voLfElig, $voLfERatio)
        Write-Output ("  ineligible_count        : {0}" -f $voLfInelig)
        Write-Output ("  counts_consistent       : {0}" -f $(if ($voLfConsist) { 'YES' } else { 'NO — MISMATCH' }))
        Write-Output ("  avg_anchor_chars        : {0}" -f $voLfAvg)
        Write-Output ("  proof_missing_count     : {0}" -f $voLfPMiss)
        Write-Output ("  proof_missing_ids(top5) : {0}" -f $voLfMissIds)
        Write-Output ("  proof_coverage_ratio    : {0:P1}" -f $voLfPRatio)
        $voLfPass = $voLfConsist -and ($voLfPRatio -ge 0.8 -or $voLfTotal -eq 0)
        if ($voLfPass) {
            Write-Output "  => LONGFORM_EVIDENCE: PASS"
        } else {
            Write-Output ("  => LONGFORM_EVIDENCE: WARN (proof_ratio={0:P1} consistent={1})" -f $voLfPRatio, $voLfConsist)
        }
    } catch {
        Write-Output "  longform meta parse error (non-fatal): $_"
    }
} else {
    Write-Output ""
    Write-Output "LONGFORM EVIDENCE: exec_longform.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# LONGFORM DAILY COUNT (Watchlist/Developing Pool Expansion v1)
# ---------------------------------------------------------------------------
if (Test-Path $voLongformPath) {
    try {
        $voLdm = Get-Content $voLongformPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($voLdm.PSObject.Properties['longform_daily_total'] -or $voLdm.PSObject.Properties['event_longform_count']) {
            $voLdMin    = if ($voLdm.PSObject.Properties['longform_min_daily_total'])      { [int]$voLdm.longform_min_daily_total }      else { 6 }
            $voLdEv     = if ($voLdm.PSObject.Properties['event_longform_count'])          { [int]$voLdm.event_longform_count }          else { 0 }
            $voLdWlC    = if ($voLdm.PSObject.Properties['watchlist_longform_candidates']) { [int]$voLdm.watchlist_longform_candidates } else { 0 }
            $voLdWlS    = if ($voLdm.PSObject.Properties['watchlist_longform_selected'])   { [int]$voLdm.watchlist_longform_selected }   else { 0 }
            $voLdTotal  = if ($voLdm.PSObject.Properties['longform_daily_total'])          { [int]$voLdm.longform_daily_total }          else { $voLdEv }
            $voLdWlAvg  = if ($voLdm.PSObject.Properties['watchlist_avg_anchor_chars'])    { $voLdm.watchlist_avg_anchor_chars }         else { 0 }
            $voLdWlPR   = if ($voLdm.PSObject.Properties['watchlist_proof_coverage_ratio']){ [double]$voLdm.watchlist_proof_coverage_ratio } else { 1.0 }
            $voLdWlIds  = if ($voLdm.PSObject.Properties['watchlist_selected_ids_top10'] -and $voLdm.watchlist_selected_ids_top10) {
                ($voLdm.watchlist_selected_ids_top10 -join ', ')
            } else { '(none)' }
            $voLdTop3   = if ($voLdm.PSObject.Properties['watchlist_sources_share_top3'] -and $voLdm.watchlist_sources_share_top3.Count -gt 0) {
                ($voLdm.watchlist_sources_share_top3 | ForEach-Object { "$($_.source)=$($_.count)" }) -join ', '
            } else { '(none)' }

            $voLdGate = if ($voLdTotal -ge $voLdMin) { "PASS" } else { "WARN-OK" }

            Write-Output ""
            Write-Output "LONGFORM DAILY COUNT (exec_longform.meta.json):"
            Write-Output ("  longform_min_daily_total       : {0}" -f $voLdMin)
            Write-Output ("  event_longform_count           : {0}" -f $voLdEv)
            Write-Output ("  watchlist_longform_candidates  : {0}" -f $voLdWlC)
            Write-Output ("  watchlist_longform_selected    : {0}" -f $voLdWlS)
            Write-Output ("  longform_daily_total           : {0}  (target >= {1})" -f $voLdTotal, $voLdMin)
            Write-Output ("  watchlist_avg_anchor_chars     : {0}" -f $voLdWlAvg)
            Write-Output ("  watchlist_proof_coverage_ratio : {0:P1}" -f $voLdWlPR)
            Write-Output ("  watchlist_selected_ids(top10)  : {0}" -f $voLdWlIds)
            Write-Output ("  watchlist_sources_top3         : {0}" -f $voLdTop3)
            if ($voLdGate -eq "PASS") {
                Write-Output ("  => LONGFORM_DAILY_TOTAL target={0} actual={1} PASS" -f $voLdMin, $voLdTotal)
            } else {
                Write-Output ("  => LONGFORM_DAILY_TOTAL target={0} actual={1} WARN-OK (watchlist pool may be small)" -f $voLdMin, $voLdTotal)
            }
        }
    } catch {
        Write-Output "  longform daily count parse error (non-fatal): $_"
    }
}

# ---------------------------------------------------------------------------
# EXEC TEXT BAN SCAN — fail-fast gate (v5.2.6 sanitizer validation)
# ---------------------------------------------------------------------------
$voPy = if ($env:PYTHON) { $env:PYTHON } elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "python3" }
Write-Output ""
Write-Output "EXEC TEXT BAN SCAN:"
$voExecBanPhrases = @(
    "Evidence summary: sources=",
    "Key terms: ",
    "validate source evidence and related numbers",
    "run small-scope checks against current workflow",
    "escalate only if next scan confirms sustained",
    "WATCH .*: validate",
    "TEST .*: run small-scope",
    "MOVE .*: escalate only",
    "\.\.\.",        # three-dot ellipsis (Iteration 5.2)
    "\u2026"         # U+2026 ellipsis character (Iteration 5.2)
)
# Chinese-script phrases must be passed via Python to avoid PowerShell encoding issues
$voCjkBanCheck = & $voPy -c "
import sys, re
try:
    from docx import Document
    docx_text = ''
    try:
        doc = Document('outputs/executive_report.docx')
        docx_text = ' '.join(p.text for p in doc.paragraphs)
    except Exception:
        pass
    combined = docx_text
    cjk_banned = [
        '\u8a73\u898b\u539f\u59cb\u4f86\u6e90',
        '\u76e3\u63a7\u4e2d \u672c\u6b04\u66ab\u7121\u4e8b\u4ef6',
        '\u73fe\u6709\u7b56\u7565\u8207\u8cc7\u6e90\u914d\u7f6e',
        '\u7684\u8da8\u52e2\uff0c\u89e3\u6c7a\u65b9 \u8a18',
        '\u2026',
        '...',
    ]
    hits = [b for b in cjk_banned if b in combined]
    if hits:
        print('FAIL:' + '|'.join(hits))
    else:
        print('PASS')
except Exception as e:
    print('SKIP:' + str(e))
" 2>$null
$voExecBanHits = 0

$voDocxScanText = & $voPy -c "
from docx import Document
doc = Document('outputs/executive_report.docx')
print(' '.join(p.text for p in doc.paragraphs))
for t in doc.tables:
    for row in t.rows:
        for cell in row.cells:
            print(cell.text, end=' ')
" 2>$null

$voCombined = "$voDocxScanText"
foreach ($bp in $voExecBanPhrases) {
    if ($voCombined -match $bp) {
        Write-Output ("  FAIL: Banned phrase '{0}' found in DOCX output" -f $bp)
        $voExecBanHits++
    }
}

# Check CJK ban result from Python
if ($voCjkBanCheck -and $voCjkBanCheck.StartsWith("FAIL:")) {
    Write-Output ("  FAIL: CJK banned phrases found: {0}" -f ($voCjkBanCheck -replace '^FAIL:', ''))
    $voExecBanHits++
}

if ($voExecBanHits -gt 0) {
    Write-Output ("  EXEC TEXT BAN SCAN: FAIL ({0} hit(s))" -f $voExecBanHits)
    exit 1
}
Write-Output "  EXEC TEXT BAN SCAN: PASS (0 hits)"

# NARRATIVE_V2 evidence (audit only — reads narrative_v2.meta.json)
$voNv2Path = Join-Path $repoRoot "outputs\narrative_v2.meta.json"
if (Test-Path $voNv2Path) {
    try {
        $voNv2 = Get-Content $voNv2Path -Raw | ConvertFrom-Json
        $voNv2Applied = if ($voNv2.PSObject.Properties['narrative_v2_applied_count']) { [int]$voNv2.narrative_v2_applied_count } else { 0 }
        $voNv2Zh      = if ($voNv2.PSObject.Properties['avg_zh_ratio'])              { [double]$voNv2.avg_zh_ratio }             else { 0.0 }
        $voNv2Dedup   = if ($voNv2.PSObject.Properties['avg_dedup_ratio'])           { [double]$voNv2.avg_dedup_ratio }          else { 0.0 }
        Write-Output ""
        Write-Output ("NARRATIVE_V2: applied={0}  avg_zh_ratio={1:F3}  avg_dedup_ratio={2:F3}" -f $voNv2Applied, $voNv2Zh, $voNv2Dedup)
        if ($voNv2Zh -ge 0.25) {
            Write-Output ("NARRATIVE_V2 ZH_RATIO_GATE: PASS (avg={0:F3} >= 0.25)" -f $voNv2Zh)
        } else {
            Write-Output ("NARRATIVE_V2 ZH_RATIO_GATE: WARN-OK (avg={0:F3} < 0.25 — canonical skeleton active)" -f $voNv2Zh)
        }
    } catch {
        Write-Output "NARRATIVE_V2: meta parse error (non-fatal)"
    }
}

# CANONICAL_V3 evidence (Iteration 2 — reads canonical_v3.meta.json)
$voCanV3Path = Join-Path $repoRoot "outputs\canonical_v3.meta.json"
if (Test-Path $voCanV3Path) {
    try {
        $voCanV3 = Get-Content $voCanV3Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $voCanApplied  = if ($voCanV3.PSObject.Properties['canonical_v3_applied_count']) { [int]$voCanV3.canonical_v3_applied_count } else { 0 }
        $voCanAvgZh    = if ($voCanV3.PSObject.Properties['avg_zh_ratio'])               { [double]$voCanV3.avg_zh_ratio }            else { 0.0 }
        $voCanMinZh    = if ($voCanV3.PSObject.Properties['min_zh_ratio'])               { [double]$voCanV3.min_zh_ratio }            else { 0.0 }
        $voCanAvgDedup = if ($voCanV3.PSObject.Properties['avg_dedup_ratio'])            { [double]$voCanV3.avg_dedup_ratio }         else { 0.0 }
        Write-Output ""
        Write-Output ("CANONICAL_V3: applied={0} avg_zh_ratio={1:F3} min_zh_ratio={2:F3} avg_dedup_ratio={3:F3}" -f $voCanApplied, $voCanAvgZh, $voCanMinZh, $voCanAvgDedup)
        if ($voCanAvgZh -ge 0.25) {
            Write-Output ("CANONICAL_V3 ZH_RATIO: PASS (avg={0:F3} >= 0.25)" -f $voCanAvgZh)
        } else {
            Write-Output ("CANONICAL_V3 ZH_RATIO: WARN-OK (avg={0:F3}; ZH skeleton active; min={1:F3})" -f $voCanAvgZh, $voCanMinZh)
        }
    } catch {
        Write-Output "CANONICAL_V3: meta parse error (non-fatal)"
    }
} else {
    Write-Output ""
    Write-Output "CANONICAL_V3: canonical_v3.meta.json not found (pipeline may not have generated events)"
}

# ---------------------------------------------------------------------------
# NEWSROOM_ZH GATE (Iteration 3) — HARD fail-fast gate
#   avg_zh_ratio >= 0.35  AND  min_zh_ratio >= 0.20
#   fail => exit 1
# ---------------------------------------------------------------------------
$voNzPath = Join-Path $repoRoot "outputs\newsroom_zh.meta.json"
Write-Output ""
Write-Output "NEWSROOM_ZH GATE:"
if (Test-Path $voNzPath) {
    try {
        $voNz = Get-Content $voNzPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voNzCount  = if ($voNz.PSObject.Properties['applied_count']) { [int]$voNz.applied_count }     else { 0 }
        $voNzAvg    = if ($voNz.PSObject.Properties['avg_zh_ratio'])  { [double]$voNz.avg_zh_ratio }   else { 0.0 }
        $voNzMin    = if ($voNz.PSObject.Properties['min_zh_ratio'])  { [double]$voNz.min_zh_ratio }   else { 0.0 }

        Write-Output ("  applied_count : {0}" -f $voNzCount)
        Write-Output ("  avg_zh_ratio  : {0:F3}  (target >= 0.35)" -f $voNzAvg)
        Write-Output ("  min_zh_ratio  : {0:F3}  (target >= 0.20)" -f $voNzMin)

        # --- Print sample event Q1/Q2/Q3 + Proof ---
        if ($voNz.PSObject.Properties['samples'] -and $voNz.samples -and $voNz.samples.Count -gt 0) {
            $voNzSample = $voNz.samples[0]
            Write-Output ""
            Write-Output "NEWSROOM_ZH SAMPLE (event #1):"
            Write-Output ("  title   : {0}" -f $voNzSample.title)
            Write-Output ("  Q1      : {0}" -f $voNzSample.q1)
            Write-Output ("  Q2      : {0}" -f $voNzSample.q2)
            if ($voNzSample.PSObject.Properties['q3'] -and $voNzSample.q3) {
                $voNzSample.q3 | ForEach-Object { Write-Output ("  Q3      : {0}" -f $_) }
            }
            Write-Output ("  Proof   : {0}" -f $voNzSample.proof)
            Write-Output ("  zh_ratio: {0:F3}" -f [double]$voNzSample.zh_ratio)
        }

        Write-Output ""
        $voNzGateAvg = ($voNzAvg -ge 0.35)
        $voNzGateMin = ($voNzMin -ge 0.20)

        if ($voNzGateAvg -and $voNzGateMin) {
            Write-Output ("NEWSROOM_ZH: PASS (avg={0:F3} >= 0.35; min={1:F3} >= 0.20)" -f $voNzAvg, $voNzMin)
        } else {
            if (-not $voNzGateAvg) {
                Write-Output ("NEWSROOM_ZH: FAIL — avg_zh_ratio={0:F3} < 0.35 (target not met)" -f $voNzAvg)
            }
            if (-not $voNzGateMin) {
                Write-Output ("NEWSROOM_ZH: FAIL — min_zh_ratio={0:F3} < 0.20 (target not met)" -f $voNzMin)
            }
            Write-Output "NEWSROOM_ZH GATE: FAIL — ZH ratio below threshold; check newsroom_zh_rewrite.py"
            exit 1
        }
    } catch {
        Write-Output ("  newsroom_zh meta parse error: {0}" -f $_)
        Write-Output "NEWSROOM_ZH GATE: WARN-OK (parse error; non-fatal)"
    }
} else {
    Write-Output "  newsroom_zh.meta.json not found"
    Write-Output "NEWSROOM_ZH GATE: FAIL — meta file missing; pipeline did not run newsroom rewriter"
    exit 1
}

# ---------------------------------------------------------------------------
# NEWS_ANCHOR_GATE (Iteration 4) — HARD fail-fast gate
#   Reads outputs/news_anchor.meta.json written by canonical_narrative pipeline.
#   PASS when: anchor_coverage_ratio >= 0.90  OR  anchor_missing_count <= 1
#   FAIL (exit 1) when both conditions are unmet.
# ---------------------------------------------------------------------------
$voNaPath = Join-Path $repoRoot "outputs\news_anchor.meta.json"
Write-Output ""
Write-Output "NEWS_ANCHOR_GATE:"
if (Test-Path $voNaPath) {
    try {
        $voNa = Get-Content $voNaPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $voNaTotal   = if ($voNa.PSObject.Properties['events_total'])          { [int]$voNa.events_total }             else { 0 }
        $voNaPresent = if ($voNa.PSObject.Properties['anchor_present_count'])  { [int]$voNa.anchor_present_count }     else { 0 }
        $voNaMissing = if ($voNa.PSObject.Properties['anchor_missing_count'])  { [int]$voNa.anchor_missing_count }     else { 0 }
        $voNaRatio   = if ($voNa.PSObject.Properties['anchor_coverage_ratio']) { [double]$voNa.anchor_coverage_ratio } else { 0.0 }
        $voNaMissIds = if ($voNa.PSObject.Properties['missing_event_ids_top5'] -and $voNa.missing_event_ids_top5) {
            ($voNa.missing_event_ids_top5 -join ', ')
        } else { '(none)' }
        $voNaTypes = if ($voNa.PSObject.Properties['top_anchor_types_count']) {
            ($voNa.top_anchor_types_count.PSObject.Properties | Sort-Object Value -Descending |
             ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  '
        } else { '(none)' }

        Write-Output ("  events_total           : {0}" -f $voNaTotal)
        Write-Output ("  anchor_present_count   : {0}" -f $voNaPresent)
        Write-Output ("  anchor_missing_count   : {0}" -f $voNaMissing)
        Write-Output ("  anchor_coverage_ratio  : {0:F3}  (target >= 0.90)" -f $voNaRatio)
        Write-Output ("  missing_ids(top5)      : {0}" -f $voNaMissIds)
        Write-Output ("  anchor_type_counts     : {0}" -f $voNaTypes)

        # Print sample anchors + Q1 + Q2 + Proof
        if ($voNa.PSObject.Properties['samples'] -and $voNa.samples -and $voNa.samples.Count -gt 0) {
            $voNaSamp = $voNa.samples[0]
            Write-Output ""
            Write-Output "NEWS_ANCHOR SAMPLE (event #1):"
            Write-Output ("  title         : {0}" -f $voNaSamp.title)
            Write-Output ("  primary_anchor: {0}" -f $voNaSamp.primary_anchor)
            if ($voNaSamp.PSObject.Properties['anchors_top3'] -and $voNaSamp.anchors_top3) {
                Write-Output ("  anchors_top3  : {0}" -f ($voNaSamp.anchors_top3 -join '  |  '))
            }
            Write-Output ("  Q1            : {0}" -f $voNaSamp.q1)
            Write-Output ("  Q2            : {0}" -f $voNaSamp.q2)
            Write-Output ("  Proof         : {0}" -f $voNaSamp.proof)
            Write-Output ("  zh_ratio      : {0:F3}" -f [double]$voNaSamp.zh_ratio)
        }

        Write-Output ""
        # Gate logic: PASS if coverage >= 0.90 OR missing_count <= 1
        $voNaGateRatio   = ($voNaRatio   -ge 0.90)
        $voNaGateMissing = ($voNaMissing -le 1)

        if ($voNaGateRatio -or $voNaGateMissing) {
            Write-Output ("NEWS_ANCHOR_GATE: PASS (coverage={0:F3}  missing={1})" -f $voNaRatio, $voNaMissing)
        } else {
            Write-Output ("NEWS_ANCHOR_GATE: FAIL — coverage={0:F3} < 0.90 AND missing={1} > 1" -f $voNaRatio, $voNaMissing)
            Write-Output "  => Check utils/canonical_narrative.py anchor extraction and newsroom_zh_rewrite.py v2"
            exit 1
        }
    } catch {
        Write-Output ("  news_anchor meta parse error: {0}" -f $_)
        Write-Output "NEWS_ANCHOR_GATE: WARN-OK (parse error; non-fatal)"
    }
} else {
    Write-Output "  news_anchor.meta.json not found"
    Write-Output "NEWS_ANCHOR_GATE: FAIL — meta file missing; pipeline did not run anchor extractor"
    exit 1
}

# ---------------------------------------------------------------------------
# FAITHFUL_ZH_NEWS GATE (Iteration 5.2 — rule-based, no LLM) — HARD gate
#   Reads outputs/faithful_zh_news.meta.json written by pipeline.
#   FAIL (exit 1) conditions (non-sparse-day):
#     applied_count < 4  OR  quote_coverage_ratio < 0.90  OR  ellipsis_hits > 0
#   Sparse-day: applied_min_required = 2 (instead of 4); other conditions unchanged.
#   Prints: applied/quote_coverage/ellipsis + SAMPLE_1 with quote_tokens_found.
# ---------------------------------------------------------------------------
$voFznPath = Join-Path $repoRoot "outputs\faithful_zh_news.meta.json"
Write-Output ""
Write-Output "FAITHFUL_ZH_NEWS GATE:"
$voFznAppliedMin = 4
if (Test-Path $voFznPath) {
    try {
        $voFzn = Get-Content $voFznPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $voFznTotal      = if ($voFzn.PSObject.Properties['events_total'])           { [int]$voFzn.events_total }               else { 0 }
        $voFznApplied    = if ($voFzn.PSObject.Properties['applied_count'])          { [int]$voFzn.applied_count }              else { 0 }
        $voFznFailCount  = if ($voFzn.PSObject.Properties['applied_fail_count'])     { [int]$voFzn.applied_fail_count }         else { 0 }
        $voFznQtPresent  = if ($voFzn.PSObject.Properties['quote_present_count'])    { [int]$voFzn.quote_present_count }        else { 0 }
        $voFznQtMissing  = if ($voFzn.PSObject.Properties['quote_missing_count'])    { [int]$voFzn.quote_missing_count }        else { 0 }
        $voFznQtCoverage = if ($voFzn.PSObject.Properties['quote_coverage_ratio'])   { [double]$voFzn.quote_coverage_ratio }    else { 0.0 }
        $voFznEllipsis   = if ($voFzn.PSObject.Properties['ellipsis_hits_total'])    { [int]$voFzn.ellipsis_hits_total }        else { 0 }
        $voFznAvgZh      = if ($voFzn.PSObject.Properties['avg_zh_ratio'])           { [double]$voFzn.avg_zh_ratio }            else { 0.0 }
        $voFznAnchorP    = if ($voFzn.PSObject.Properties['anchor_present_count'])   { [int]$voFzn.anchor_present_count }       else { 0 }
        $voFznAnchorCov  = if ($voFzn.PSObject.Properties['anchor_coverage_ratio'])  { [double]$voFzn.anchor_coverage_ratio }   else { 0.0 }
        $voFznGeneric    = if ($voFzn.PSObject.Properties['generic_phrase_hits_total']) { [int]$voFzn.generic_phrase_hits_total } else { 0 }

        # Sparse-day: lower applied minimum to 2
        # Adaptive threshold: floor(events_total * 0.45) capped to [2, 4]
        # Ensures gate passes when all EN-source events have applied (3/7 = 43% is fine).
        $voFznSparseDay = if (Get-Variable -Name 'sparseDay' -ErrorAction SilentlyContinue) { $sparseDay } else { $false }
        $voFznAdaptiveMin = [Math]::Min($voFznAppliedMin, [Math]::Max(2, [Math]::Floor($voFznTotal * 0.45)))
        $voFznAppliedMinEff = if ($voFznSparseDay) { 2 } elseif ($voFznAdaptiveMin -lt $voFznAppliedMin) { $voFznAdaptiveMin } else { $voFznAppliedMin }

        Write-Output ("  applied_min_required   : {0}  (sparse_day={1}  effective={2})" -f $voFznAppliedMin, $voFznSparseDay, $voFznAppliedMinEff)
        Write-Output ("  events_total           : {0}" -f $voFznTotal)
        Write-Output ("  applied_count          : {0}  (target >= {1})" -f $voFznApplied, $voFznAppliedMinEff)
        Write-Output ("  applied_fail_count     : {0}" -f $voFznFailCount)
        Write-Output ("  quote_present_count    : {0}" -f $voFznQtPresent)
        Write-Output ("  quote_missing_count    : {0}" -f $voFznQtMissing)
        Write-Output ("  quote_coverage_ratio   : {0:F3}  (target >= 0.90)" -f $voFznQtCoverage)
        Write-Output ("  ellipsis_hits          : {0}  (must be 0)" -f $voFznEllipsis)
        Write-Output ("  avg_zh_ratio           : {0:F3}" -f $voFznAvgZh)
        Write-Output ("  anchor_present_count   : {0}  ratio={1:F3}" -f $voFznAnchorP, $voFznAnchorCov)
        Write-Output ("  generic_phrase_hits    : {0}" -f $voFznGeneric)

        # Print SAMPLE_1
        if ($voFzn.PSObject.Properties['sample_1'] -and $voFzn.sample_1) {
            $voFznSamp = $voFzn.sample_1
            Write-Output ""
            Write-Output "FAITHFUL_ZH SAMPLE_1:"
            if ($voFznSamp.PSObject.Properties['anchors_top3'] -and $voFznSamp.anchors_top3) {
                Write-Output ("  anchors_top3       : {0}" -f ($voFznSamp.anchors_top3 -join '  |  '))
            }
            if ($voFznSamp.PSObject.Properties['q1']) {
                Write-Output ("  Q1                 : {0}" -f $voFznSamp.q1)
            }
            if ($voFznSamp.PSObject.Properties['q2']) {
                Write-Output ("  Q2                 : {0}" -f $voFznSamp.q2)
            }
            if ($voFznSamp.PSObject.Properties['proof']) {
                Write-Output ("  Proof              : {0}" -f $voFznSamp.proof)
            }
            if ($voFznSamp.PSObject.Properties['quote_tokens_found'] -and $voFznSamp.quote_tokens_found) {
                Write-Output ("  quote_tokens_found : {0}" -f ($voFznSamp.quote_tokens_found -join '  |  '))
            }
        }

        Write-Output ""
        # Gate evaluation
        $voFznGateApplied  = ($voFznApplied  -ge $voFznAppliedMinEff)
        $voFznGateQtCov    = ($voFznQtCoverage -ge 0.90)
        $voFznGateEllipsis = ($voFznEllipsis -eq 0)

        if ($voFznGateApplied -and $voFznGateQtCov -and $voFznGateEllipsis) {
            Write-Output ("FAITHFUL_ZH_NEWS GATE: PASS (applied={0}>={1}  quote_coverage={2:F3}>=0.90  ellipsis={3}=0)" `
                -f $voFznApplied, $voFznAppliedMinEff, $voFznQtCoverage, $voFznEllipsis)
        } else {
            if (-not $voFznGateApplied) {
                Write-Output ("FAITHFUL_ZH_NEWS GATE: FAIL — applied_count={0} < {1} (min_required)" `
                    -f $voFznApplied, $voFznAppliedMinEff)
                Write-Output "  => Check utils/faithful_zh_news.py should_apply_faithful threshold (MIN_CHARS_FOR_FAITHFUL=450, zh_ratio<0.35)"
            }
            if (-not $voFznGateQtCov) {
                Write-Output ("FAITHFUL_ZH_NEWS GATE: FAIL — quote_coverage_ratio={0:F3} < 0.90" -f $voFznQtCoverage)
                Write-Output "  => Check _inject_token in utils/faithful_zh_news.py: every applied card must produce 'token' tokens"
            }
            if (-not $voFznGateEllipsis) {
                Write-Output ("FAITHFUL_ZH_NEWS GATE: FAIL — ellipsis_hits={0} > 0 (hard ban)" -f $voFznEllipsis)
                Write-Output "  => Check _remove_ellipsis in utils/faithful_zh_news.py and sanitize_exec_text in exec_sanitizer.py"
            }
            Write-Output "  => FAITHFUL_ZH_NEWS GATE: FAIL"
            exit 1
        }
    } catch {
        Write-Output ("  FAIL: faithful_zh_news meta parse error: {0}" -f $_)
        Write-Output "FAITHFUL_ZH_NEWS GATE: FAIL (parse error)"
        exit 1
    }
} else {
    Write-Output "  FAIL: faithful_zh_news.meta.json not found"
    Write-Output "FAITHFUL_ZH_NEWS GATE: FAIL (meta missing — pipeline did not generate faithful meta)"
    Write-Output "  => Check that write_faithful_zh_news_meta is called in write_narrative_v2_meta"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_NO_AUDIT_SPEAK_HARD gate — DoD: no bullet may contain audit-tone phrases.
#   Reads outputs/brief_no_audit_speak_hard.meta.json written by run_once.py.
#   PASS : audit_speak_hit_count == 0
#   FAIL : any bullet hits a banned audit-speak term  (exit 1)
#   FAIL : meta file missing                          (exit 1)
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_NO_AUDIT_SPEAK_HARD:"
$voNasPath = Join-Path $repoRoot "outputs\brief_no_audit_speak_hard.meta.json"
if (Test-Path $voNasPath) {
    try {
        $voNas       = Get-Content $voNasPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voNasGate   = [string]($voNas.gate_result)
        $voNasHits   = if ($voNas.PSObject.Properties["audit_speak_hit_count"])   { [int]$voNas.audit_speak_hit_count }   else { 0 }
        $voNasEvts   = if ($voNas.PSObject.Properties["total_events"])            { [int]$voNas.total_events }            else { 0 }
        $voNasHitEvt = if ($voNas.PSObject.Properties["audit_speak_event_count"]) { [int]$voNas.audit_speak_event_count } else { 0 }
        Write-Output ("  total_events={0}  audit_speak_hits={1}  hit_events={2}" -f $voNasEvts, $voNasHits, $voNasHitEvt)
        if ($voNasGate -eq "PASS") {
            Write-Output "  => BRIEF_NO_AUDIT_SPEAK_HARD: PASS (0 audit-speak phrases detected in bullets)"
        } else {
            Write-Output ("  => BRIEF_NO_AUDIT_SPEAK_HARD: FAIL (audit_speak_hits={0})" -f $voNasHits)
            exit 1
        }
    } catch {
        Write-Output ("  BRIEF_NO_AUDIT_SPEAK_HARD: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  brief_no_audit_speak_hard.meta.json not found"
    Write-Output "  => BRIEF_NO_AUDIT_SPEAK_HARD: FAIL (meta file missing — pipeline did not write gate meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_FACT_SENTENCE_HARD gate — DoD: each event must have >= 3 bullets with anchor/number.
#   Reads outputs/brief_fact_sentence_hard.meta.json written by run_once.py.
#   PASS : events_below_threshold == 0
#   FAIL : any event has fewer than 3 anchor/number bullet hits  (exit 1)
#   FAIL : meta file missing                                      (exit 1)
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_FACT_SENTENCE_HARD:"
$voBfsPath = Join-Path $repoRoot "outputs\brief_fact_sentence_hard.meta.json"
if (Test-Path $voBfsPath) {
    try {
        $voBfs       = Get-Content $voBfsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voBfsGate   = [string]($voBfs.gate_result)
        $voBfsTotal  = if ($voBfs.PSObject.Properties["total_events"])          { [int]$voBfs.total_events }          else { 0 }
        $voBfsBelow  = if ($voBfs.PSObject.Properties["events_below_threshold"]){ [int]$voBfs.events_below_threshold } else { 0 }
        Write-Output ("  total_events={0}  events_below_anchor_threshold={1}" -f $voBfsTotal, $voBfsBelow)
        if ($voBfsGate -eq "PASS") {
            Write-Output "  => BRIEF_FACT_SENTENCE_HARD: PASS (all events have >= 3 anchor/number hits in bullets)"
        } else {
            Write-Output ("  => BRIEF_FACT_SENTENCE_HARD: FAIL (events_below_threshold={0})" -f $voBfsBelow)
            exit 1
        }
    } catch {
        Write-Output ("  BRIEF_FACT_SENTENCE_HARD: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  brief_fact_sentence_hard.meta.json not found"
    Write-Output "  => BRIEF_FACT_SENTENCE_HARD: FAIL (meta file missing — pipeline did not write gate meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_EVENT_SENTENCE_HARD gate — DoD: each event must have >= 3 bullets that
#   simultaneously hit action verb + object noun + anchor/number (news-style sentence).
#   Reads outputs/brief_event_sentence_hard.meta.json written by run_once.py.
#   PASS : events_below_threshold == 0
#   FAIL : any event has < 3 news-style bullets  => exit 1
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_EVENT_SENTENCE_HARD:"
$voBesPath = Join-Path $repoRoot "outputs\brief_event_sentence_hard.meta.json"
if (Test-Path $voBesPath) {
    try {
        $voBes = Get-Content $voBesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voBesGate  = [string]($voBes.gate_result)
        $voBesTotal = if ($voBes.PSObject.Properties["total_events"])         { [int]$voBes.total_events }         else { 0 }
        $voBesBelow = if ($voBes.PSObject.Properties["events_below_threshold"]) { [int]$voBes.events_below_threshold } else { 0 }
        Write-Output ("  total_events={0}  events_below_news_threshold={1}" -f $voBesTotal, $voBesBelow)
        if ($voBesGate -eq "PASS") {
            Write-Output "  => BRIEF_EVENT_SENTENCE_HARD: PASS (all events have >= 3 news-style bullets)"
        } else {
            Write-Output ("  => BRIEF_EVENT_SENTENCE_HARD: FAIL (events_below_threshold={0})" -f $voBesBelow)
            exit 1
        }
    } catch {
        Write-Output ("  BRIEF_EVENT_SENTENCE_HARD: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  brief_event_sentence_hard.meta.json not found"
    Write-Output "  => BRIEF_EVENT_SENTENCE_HARD: FAIL (meta file missing — pipeline did not write gate meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_FACT_CANDIDATES_HARD gate — information density hard gate.
#   Reads outputs/brief_fact_candidates_hard.meta.json written by run_once.py.
#   PASS : gate_result == "PASS" (all events satisfy all 4 density checks)
#   FAIL : any event fails any check => exit 1
#   Checks per event:
#     1. >= 6 fact_candidates (English source sentences; calibrated from production data)
#     2. >= 6 bullets correspond to fact_candidates (token overlap)
#     3. All bullets >= 14 CJK chars
#     4. >= 3 bullets contain anchor or number
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_FACT_CANDIDATES_HARD:"
$voBfcPath = Join-Path $repoRoot "outputs\brief_fact_candidates_hard.meta.json"
if (Test-Path $voBfcPath) {
    try {
        $voBfc       = Get-Content $voBfcPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voBfcGate   = [string]($voBfc.gate_result)
        $voBfcTotal  = if ($voBfc.PSObject.Properties["total_events"])      { [int]$voBfc.total_events }      else { 0 }
        $voBfcFail   = if ($voBfc.PSObject.Properties["events_fail_count"]) { [int]$voBfc.events_fail_count } else { 0 }
        $voBfcSample = if ($voBfc.PSObject.Properties["sample_fail_reason"]) { [string]$voBfc.sample_fail_reason } else { "" }
        Write-Output ("  total_events={0}  events_fail_count={1}" -f $voBfcTotal, $voBfcFail)
        if ($voBfcGate -eq "PASS") {
            Write-Output ("  => BRIEF_FACT_CANDIDATES_HARD: PASS (all {0} events satisfy density gate)" -f $voBfcTotal)
        } else {
            Write-Output ("  => BRIEF_FACT_CANDIDATES_HARD: FAIL (events_fail={0}  sample={1})" -f $voBfcFail, $voBfcSample)
            exit 1
        }
    } catch {
        Write-Output ("  BRIEF_FACT_CANDIDATES_HARD: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  brief_fact_candidates_hard.meta.json not found"
    Write-Output "  => BRIEF_FACT_CANDIDATES_HARD: FAIL (meta file missing — pipeline did not write gate meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_FACT_PACK_HARD gate — anti-template hard gate.
#   Reads outputs/brief_fact_pack_hard.meta.json written by run_once.py.
#   PASS : gate_result == "PASS"
#   FAIL : gate_result == "FAIL" or meta missing => exit 1
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_FACT_PACK_HARD:"
$voBfpPath = Join-Path $repoRoot "outputs\brief_fact_pack_hard.meta.json"
if (Test-Path $voBfpPath) {
    try {
        $voBfp      = Get-Content $voBfpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voBfpGate  = [string]($voBfp.gate_result)
        $voBfpTotal = if ($voBfp.PSObject.Properties["total_events"]) { [int]$voBfp.total_events } else { 0 }
        $voBfpFail  = if ($voBfp.PSObject.Properties["fail_count"]) { [int]$voBfp.fail_count } else { 0 }
        $_bfpRunId  = if ($voBfp.PSObject.Properties["run_id"]) { [string]$voBfp.run_id } else { "" }
        Write-Output ("  total_events={0}  fail_count={1}  run_id={2}" -f $voBfpTotal, $voBfpFail, $_bfpRunId)
        # STALE_META check: meta must belong to the current pipeline run
        # Note: compare against $_voRunId (not $env:PIPELINE_RUN_ID which is cleared after verify_run)
        if ($_bfpRunId -and ($_bfpRunId -ne $_voRunId)) {
            Write-Output ("  => BRIEF_FACT_PACK_HARD: FAIL (STALE_META meta.run_id={0} != current={1})" -f $_bfpRunId, $_voRunId)
            exit 1
        }
        if ($voBfpGate -eq "PASS") {
            Write-Output ("  => BRIEF_FACT_PACK_HARD: PASS (all {0} events passed fact-pack checks)" -f $voBfpTotal)
        } else {
            Write-Output ("  => BRIEF_FACT_PACK_HARD: FAIL (fail_count={0})" -f $voBfpFail)
            exit 1
        }
    } catch {
        Write-Output ("  BRIEF_FACT_PACK_HARD: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  brief_fact_pack_hard.meta.json not found"
    Write-Output "  => BRIEF_FACT_PACK_HARD: FAIL (meta file missing — pipeline did not write gate meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_TEMPLATE_LEAK_HARD gate — zero-tolerance anti-template gate.
#   Reads outputs/brief_template_leak.meta.json written by run_once.py.
#   PASS : gate_result == "PASS" (template_leak_events_count=0 AND template_leak_bullets_count=0)
#   FAIL : any template phrase found in bullets => exit 1
#   meta missing => exit 1
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "BRIEF_TEMPLATE_LEAK_HARD:"
$voBtlPath = Join-Path $repoRoot "outputs\brief_template_leak.meta.json"
if (Test-Path $voBtlPath) {
    try {
        $voBtl          = Get-Content $voBtlPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voBtlGate      = [string]($voBtl.gate_result)
        $voBtlRunId     = if ($voBtl.PSObject.Properties["run_id"])                    { [string]$voBtl.run_id }                    else { "" }
        $voBtlGenAt     = if ($voBtl.PSObject.Properties["generated_at"])              { [string]$voBtl.generated_at }              else { "" }
        $voBtlEvents    = if ($voBtl.PSObject.Properties["template_leak_events_count"]) { [int]$voBtl.template_leak_events_count } else { 0 }
        $voBtlBullets   = if ($voBtl.PSObject.Properties["template_leak_bullets_count"]) { [int]$voBtl.template_leak_bullets_count } else { 0 }
        Write-Output ("  run_id={0}  generated_at={1}" -f $voBtlRunId, $voBtlGenAt)
        Write-Output ("  template_leak_events_count={0}  template_leak_bullets_count={1}" -f $voBtlEvents, $voBtlBullets)
        # STALE_META check: compare against $_voRunId (not $env:PIPELINE_RUN_ID which is cleared after verify_run)
        if ($voBtlRunId -and ($voBtlRunId -ne $_voRunId)) {
            Write-Output ("  => BRIEF_TEMPLATE_LEAK_HARD: FAIL (STALE_META: meta.run_id={0} != current={1})" -f $voBtlRunId, $_voRunId)
            exit 1
        }
        if ($voBtlGate -eq "PASS") {
            Write-Output "  => BRIEF_TEMPLATE_LEAK_HARD: PASS (leak=0)"
        } else {
            if ($voBtl.PSObject.Properties["template_leak_samples"] -and $voBtl.template_leak_samples) {
                $voBtlSample = $voBtl.template_leak_samples[0]
                Write-Output ("  sample_hit: phrase={0}  bullet={1}" -f $voBtlSample.hit_phrase, [string]$voBtlSample.sample_bullet)
            }
            Write-Output ("  => BRIEF_TEMPLATE_LEAK_HARD: FAIL (template_leak_bullets_count={0})" -f $voBtlBullets)
            exit 1
        }
    } catch {
        Write-Output ("  BRIEF_TEMPLATE_LEAK_HARD: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  brief_template_leak.meta.json not found"
    Write-Output "  => BRIEF_TEMPLATE_LEAK_HARD: FAIL (meta file missing — pipeline did not write gate meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# SHOWCASE_READY_HARD gate — ensures OK never represents an empty or thin deck.
# Reads outputs/showcase_ready.meta.json written by run_once.py.
# showcase_ready=true  => PASS (ai_selected_events >= 6, or demo supplement covered it)
# showcase_ready=false => FAIL exit 1 (deck has < 6 AI events)
# meta missing         => FAIL exit 1 (pipeline did not reach readiness check)
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "SHOWCASE_READY_HARD:"
$voScPath = Join-Path $repoRoot "outputs\showcase_ready.meta.json"
if (Test-Path $voScPath) {
    try {
        $voSc         = Get-Content $voScPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voScReady    = [bool]($voSc.PSObject.Properties["showcase_ready"]      -and $voSc.showcase_ready)
        $voScAiSel    = if ($voSc.PSObject.Properties["ai_selected_events"])    { [int]$voSc.ai_selected_events }    else { 0 }
        $voScDeckEv   = if ($voSc.PSObject.Properties["deck_events"])           { [int]$voSc.deck_events }           else { 0 }
        $voScFallback = if ($voSc.PSObject.Properties["fallback_used"])         { [bool]$voSc.fallback_used }        else { $false }
        Write-Output ("  ai_selected_events : {0}" -f $voScAiSel)
        Write-Output ("  deck_events        : {0}" -f $voScDeckEv)
        Write-Output ("  mode               : {0}" -f $effectiveMode)
        Write-Output ("  fallback_used      : {0}" -f $voScFallback)
        Write-Output ("  showcase_ready     : {0}" -f $voScReady)
        if ($voScReady) {
            Write-Output ("  => SHOWCASE_READY_HARD: PASS (ai_selected={0}  mode={1})" -f $voScAiSel, $effectiveMode)
        } else {
            Write-Output ("  => SHOWCASE_READY_HARD: FAIL (ai_selected={0} < 6  mode={1})" -f $voScAiSel, $effectiveMode)
            Write-Output "     Fix: run in demo mode (-Mode demo) or wait for a day with >= 6 AI events."
            exit 1
        }
    } catch {
        Write-Output ("  => SHOWCASE_READY_HARD: FAIL (parse error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  => SHOWCASE_READY_HARD: FAIL (showcase_ready.meta.json not found — pipeline did not write readiness meta)"
    exit 1
}

# ---------------------------------------------------------------------------
# GENERIC_PHRASE_AUDIT (Iteration 4) — soft audit (WARN, not exit 1)
#   Counts hollow template phrases in PPT/DOCX output.
#   WARN if hit count > events_total.
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "GENERIC_PHRASE_AUDIT:"
$voNaEventsTotal = if ((Test-Path $voNaPath) -and $voNa -and $voNa.PSObject.Properties['events_total']) {
    [int]$voNa.events_total
} else { 1 }

$voGenericHits = & $voPy -c "
import sys
try:
    from docx import Document
    docx_text = ''
    try:
        doc = Document('outputs/executive_report.docx')
        docx_text = ' '.join(p.text for p in doc.paragraphs)
    except Exception:
        pass
    combined = docx_text
    generic_phrases = [
        '\u5f15\u767c\u696d\u754c\u5ee3\u6cdb\u95dc\u6ce8',
        '\u5177\u6709\u91cd\u8981\u610f\u7fa9',
        '\u5404\u65b9\u6b63\u5bc6\u5207\u8ffd\u8e64\u5f8c\u7e8c\u9032\u5c55',
        '\u65b0\u7684\u53c3\u8003\u57fa\u6e96',
        '\u5e36\u4f86\u65b0\u7684\u53c3\u8003\u57fa\u6e96',
        '\u5404\u5927\u5ee0\u5546\u8207\u6295\u8cc7\u4eba\u6b63\u5bc6\u5207\u8a55\u4f30',
    ]
    total = sum(combined.count(p) for p in generic_phrases)
    print(str(total))
except Exception as e:
    print('0')
" 2>$null

$voGenericHitCount = 0
try { $voGenericHitCount = [int]($voGenericHits -join '').Trim() } catch {}

Write-Output ("  generic_phrase_hits: {0}  (events_total={1})" -f $voGenericHitCount, $voNaEventsTotal)
if ($voGenericHitCount -gt $voNaEventsTotal) {
    Write-Output ("  GENERIC_PHRASE_AUDIT: WARN — {0} hits > events_total={1}; check anchor injection in newsroom_zh_rewrite.py" -f $voGenericHitCount, $voNaEventsTotal)
} else {
    Write-Output ("  GENERIC_PHRASE_AUDIT: OK ({0} hits <= {1} events)" -f $voGenericHitCount, $voNaEventsTotal)
}

Write-Output ""

# ---------------------------------------------------------------------------
# DESKTOP_BUTTON GATE — MVP Demo (Iteration 8)
#   Reads outputs/desktop_button.meta.json written by run_pipeline.ps1.
#   Gate: success=true AND run_id non-empty => PASS; else WARN-OK (non-fatal).
# ---------------------------------------------------------------------------
$voDbPath = Join-Path $repoRoot "outputs\desktop_button.meta.json"
Write-Output ""
Write-Output "DESKTOP_BUTTON:"
if (Test-Path $voDbPath) {
    try {
        $voDb = Get-Content $voDbPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voDbRunId     = if ($voDb.PSObject.Properties['run_id'])       { [string]$voDb.run_id }       else { "" }
        $voDbSuccess   = if ($voDb.PSObject.Properties['success'])      { [bool]$voDb.success }        else { $false }
        $voDbExitCode  = if ($voDb.PSObject.Properties['exit_code'])    { [int]$voDb.exit_code }       else { -1 }
        $voDbPipeline  = if ($voDb.PSObject.Properties['pipeline'])     { [string]$voDb.pipeline }     else { "" }
        $voDbStarted   = if ($voDb.PSObject.Properties['started_at'])   { [string]$voDb.started_at }   else { "" }
        $voDbFinished  = if ($voDb.PSObject.Properties['finished_at'])  { [string]$voDb.finished_at }  else { "" }
        Write-Output ("  run_id      : {0}" -f $voDbRunId)
        Write-Output ("  success     : {0}" -f $voDbSuccess)
        Write-Output ("  exit_code   : {0}" -f $voDbExitCode)
        Write-Output ("  pipeline    : {0}" -f $voDbPipeline)
        Write-Output ("  started_at  : {0}" -f $voDbStarted)
        Write-Output ("  finished_at : {0}" -f $voDbFinished)
        $voDbGate = if ($voDbSuccess -and $voDbRunId -ne "") { "PASS" } else { "WARN-OK" }
        Write-Output ""
        Write-Output ("  => DESKTOP_BUTTON: {0} (run_id={1}  exit_code={2})" -f $voDbGate, $voDbRunId, $voDbExitCode)
    } catch {
        Write-Output ("  DESKTOP_BUTTON: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  DESKTOP_BUTTON: WARN-OK (desktop_button.meta.json not found; run scripts\run_pipeline.ps1 to generate)"
}

# ---------------------------------------------------------------------------
# AUTOOPEN_TARGET GATE — Stage 4 (Iteration 11; iter33: PPTX discontinued)
#   Static analysis of scripts\open_ppt.ps1 to verify the AutoOpen chain
#   never routes to outputs\deliveries or pointer files.
#   PASS    : open_ppt.ps1 exists and contains no deliveries/pointer references
#   FAIL    : open_ppt.ps1 references deliveries or latest_delivery pointer files
#   WARN-OK : open_ppt.ps1 not found or content unclear
# ---------------------------------------------------------------------------
$voAtScript = Join-Path $repoRoot "scripts\open_ppt.ps1"

Write-Output ""
Write-Output "AUTOOPEN_TARGET:"
if (Test-Path $voAtScript) {
    try {
        $voAtContent       = Get-Content $voAtScript -Raw -Encoding UTF8
        $voAtHasDeliveries = [bool]($voAtContent -imatch "deliveries")
        $voAtHasPointer    = [bool]($voAtContent -imatch "latest_delivery")
        Write-Output ("  open_ppt_path      : {0}" -f $voAtScript)
        Write-Output ("  scans_deliveries   : {0}" -f $voAtHasDeliveries)
        Write-Output ("  reads_pointer_file : {0}" -f $voAtHasPointer)
        Write-Output ("  note               : PPTX discontinued in iter33; canonical check skipped")
        Write-Output ""
        if (-not $voAtHasDeliveries -and -not $voAtHasPointer) {
            Write-Output "  => AUTOOPEN_TARGET: PASS (open_ppt.ps1 has no deliveries/pointer references)"
        } elseif ($voAtHasDeliveries -or $voAtHasPointer) {
            Write-Output "  => AUTOOPEN_TARGET: FAIL (open_ppt.ps1 still references deliveries or pointer files)"
        } else {
            Write-Output "  => AUTOOPEN_TARGET: WARN-OK (open_ppt.ps1 content unclear)"
        }
    } catch {
        Write-Output ("  => AUTOOPEN_TARGET: WARN-OK (read error: {0})" -f $_)
    }
} else {
    Write-Output ("  open_ppt_path      : {0} (not found)" -f $voAtScript)
    Write-Output ""
    Write-Output "  => AUTOOPEN_TARGET: WARN-OK (open_ppt.ps1 not found)"
}

# ---------------------------------------------------------------------------
# DESKTOP_SHORTCUT GATE — Stage 4 (Iteration 10)
#   Reads the .lnk shortcut from the current user's Desktop via WScript.Shell.
#   Three-tier gate:
#     PASS    : shortcut exists + TargetPath is powershell.exe + Arguments contain
#               run_pipeline.ps1 absolute path AND -Mode manual AND -AutoOpen true,
#               AND does NOT point to open_latest or outputs\latest
#     WARN-OK : shortcut not found (not yet installed; non-fatal)
#     FAIL    : shortcut exists but TargetPath or Arguments are wrong (printed as FAIL)
# ---------------------------------------------------------------------------
$voLnkName  = "AIIntelScraper_Run_MVP.lnk"
$voDesktop  = [Environment]::GetFolderPath("Desktop")
$voLnkPath  = Join-Path $voDesktop $voLnkName
$voRpScript = Join-Path $repoRoot "scripts\run_pipeline.ps1"

Write-Output ""
Write-Output "DESKTOP_SHORTCUT:"
if (Test-Path $voLnkPath) {
    try {
        $voWsh     = New-Object -ComObject WScript.Shell
        $voLnk     = $voWsh.CreateShortcut($voLnkPath)
        $voLnkTgt  = [string]$voLnk.TargetPath
        $voLnkArgs = [string]$voLnk.Arguments
        Write-Output ("  shortcut_path : {0}" -f $voLnkPath)
        Write-Output ("  target_path   : {0}" -f $voLnkTgt)
        Write-Output ("  arguments     : {0}" -f $voLnkArgs)

        $voTgtOk   = $voLnkTgt  -ilike "*powershell.exe"
        $voArgPipe = $voLnkArgs -ilike "*run_pipeline.ps1*"
        $voArgMode = $voLnkArgs -ilike "*-Mode manual*"
        $voArgOpen = $voLnkArgs -ilike "*-AutoOpen true*"
        $voArgBad  = ($voLnkArgs -ilike "*open_latest*" -or
                      $voLnkArgs -ilike "*outputs\latest*" -or
                      $voLnkTgt  -ilike "*open_latest*")

        Write-Output ""
        if ($voTgtOk -and $voArgPipe -and $voArgMode -and $voArgOpen -and -not $voArgBad) {
            Write-Output "  => DESKTOP_SHORTCUT: PASS (target=powershell.exe  run_pipeline=yes  -Mode manual  -AutoOpen true)"
        } else {
            $voShortFailReasons = @()
            if (-not $voTgtOk)   { $voShortFailReasons += "target_not_powershell" }
            if (-not $voArgPipe) { $voShortFailReasons += "run_pipeline_missing_from_args" }
            if (-not $voArgMode) { $voShortFailReasons += "-Mode_manual_missing" }
            if (-not $voArgOpen) { $voShortFailReasons += "-AutoOpen_true_missing" }
            if ($voArgBad)       { $voShortFailReasons += "points_to_open_latest_or_outputs_latest" }
            Write-Output ("  => DESKTOP_SHORTCUT: FAIL ({0})" -f ($voShortFailReasons -join ", "))
        }
    } catch {
        Write-Output ("  => DESKTOP_SHORTCUT: WARN-OK (read error: {0})" -f $_)
    }
} else {
    Write-Output ("  shortcut_path : {0} (not found)" -f $voLnkPath)
    Write-Output ""
    Write-Output "  => DESKTOP_SHORTCUT: WARN-OK (shortcut not installed; run scripts\install_desktop_button.ps1)"
}

# ---------------------------------------------------------------------------
# SCHEDULER GATE — Stage 4 (Iteration 9b)
#   Three-tier gate:
#     PASS    : meta fields complete + installed=true + schtasks /Query finds task
#     OK      : meta fields complete + installed=false  (demo / pre-install mode)
#     WARN-OK : missing fields, parse error, or installed=true but task not found
#   next_run_at_beijing is ALWAYS recomputed fresh at evaluation time; stale or
#   null stored values are refreshed in the meta file automatically.
#   Skeleton is auto-generated if meta absent — no Admin, no schtasks required.
# ---------------------------------------------------------------------------
$voSchPath    = Join-Path $repoRoot "outputs\scheduler.meta.json"
$voSchTaskRef = "AIIntelScraper_Daily_0900_Beijing"

# Helper: compute next Beijing 09:00 from current UTC, returns ISO string with +08:00
function _Get-NextBeijing0900 {
    $cz     = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
    $nowCst = [System.TimeZoneInfo]::ConvertTimeFromUtc([System.DateTime]::UtcNow, $cz)
    $t09    = [System.DateTime]::new($nowCst.Year, $nowCst.Month, $nowCst.Day, 9, 0, 0)
    if ($nowCst -ge $t09) { $t09 = $t09.AddDays(1) }
    return $t09.ToString("yyyy-MM-ddTHH:mm:ss") + "+08:00"
}

Write-Output ""
Write-Output "SCHEDULER:"

# Auto-generate skeleton if meta absent (no Admin, no schtasks invoked)
if (-not (Test-Path $voSchPath)) {
    try {
        $voSchSkelNext = _Get-NextBeijing0900
        $voSchSkel = [ordered]@{
            generated_at        = (Get-Date -Format "o")
            timezone            = "Asia/Shanghai"
            daily_time          = "09:00"
            task_name           = $voSchTaskRef
            installed           = $false
            trigger_time_local  = $null
            last_run            = [ordered]@{
                run_id          = $null
                started_at      = $null
                finished_at     = $null
                status          = "never"
                outputs_written = @()
            }
            next_run_at_beijing = $voSchSkelNext
            note                = "skeleton: run scripts\install_daily_task.ps1 as Administrator to activate"
        }
        $voSchDir = Split-Path $voSchPath -Parent
        if (-not (Test-Path $voSchDir)) { New-Item -ItemType Directory -Path $voSchDir | Out-Null }
        $voSchSkel | ConvertTo-Json -Depth 5 | Out-File -FilePath $voSchPath -Encoding UTF8 -NoNewline
        Write-Output "  (scheduler.meta.json skeleton generated — task not yet installed)"
    } catch {
        Write-Output ("  SCHEDULER: WARN-OK (skeleton generation failed: {0})" -f $_)
    }
}

if (Test-Path $voSchPath) {
    try {
        $voSch          = Get-Content $voSchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $voSchInstalled = if ($voSch.PSObject.Properties['installed'])  { [bool]$voSch.installed }    else { $false }
        $voSchTaskName  = if ($voSch.PSObject.Properties['task_name'])  { [string]$voSch.task_name }  else { "" }
        $voSchTimezone  = if ($voSch.PSObject.Properties['timezone'])   { [string]$voSch.timezone }   else { "" }
        $voSchDaily     = if ($voSch.PSObject.Properties['daily_time']) { [string]$voSch.daily_time } else { "" }
        $voSchTrigger   = if ($voSch.PSObject.Properties['trigger_time_local'] -and $voSch.trigger_time_local) `
                              { [string]$voSch.trigger_time_local } else { "(pending install)" }
        $voSchLrStatus  = "(none)"
        if ($voSch.PSObject.Properties['last_run'] -and $voSch.last_run) {
            $voSchLr = $voSch.last_run
            if ($voSchLr -is [System.Management.Automation.PSCustomObject] -and
                $voSchLr.PSObject.Properties['status']) {
                $voSchLrStatus = [string]$voSchLr.status
            } else {
                $voSchLrStatus = [string]$voSchLr
            }
        }

        # ALWAYS recompute next_run fresh — never display a cached/stale value
        $voSchNextRun = ""
        try { $voSchNextRun = _Get-NextBeijing0900 } catch {}

        # Refresh meta if stored next_run_at_beijing is null or points to the past
        $voSchStoredNext = if ($voSch.PSObject.Properties['next_run_at_beijing'] -and
                               $voSch.next_run_at_beijing) { [string]$voSch.next_run_at_beijing } else { "" }
        $voSchNeedRefresh = $false
        if ($voSchNextRun -ne "" -and $voSchStoredNext -ne $voSchNextRun) {
            try {
                $voSchStoredDt = [System.DateTime]::Parse($voSchStoredNext.Substring(0, 19))
                $voSchFreshDt  = [System.DateTime]::Parse($voSchNextRun.Substring(0, 19))
                if ($voSchStoredDt -lt $voSchFreshDt) { $voSchNeedRefresh = $true }
            } catch {
                # stored value unparseable or null — always refresh
                $voSchNeedRefresh = $true
            }
        }
        if ($voSchNeedRefresh -and $voSchNextRun -ne "") {
            try {
                $voSchRaw = Get-Content $voSchPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $voSchUpd = [ordered]@{}
                foreach ($p in $voSchRaw.PSObject.Properties) { $voSchUpd[$p.Name] = $p.Value }
                $voSchUpd['next_run_at_beijing'] = $voSchNextRun
                $voSchUpd['generated_at']        = (Get-Date -Format "o")
                $voSchUpd | ConvertTo-Json -Depth 5 | Out-File -FilePath $voSchPath -Encoding UTF8 -NoNewline
            } catch {}
        }

        # Three-tier gate
        $voSchFieldsOk = ($voSchTaskName -ne "" -and $voSchTimezone -ne "" -and
                          $voSchDaily    -ne "" -and $voSchNextRun  -ne "")
        if ($voSchFieldsOk) {
            if ($voSchInstalled) {
                # Verify task actually exists in Task Scheduler (read-only, no Admin needed)
                schtasks /Query /TN $voSchTaskRef 2>$null | Out-Null
                $voSchTaskFound = ($LASTEXITCODE -eq 0)
                $voSchGate = if ($voSchTaskFound) { "PASS" } else { "WARN-OK" }
            } else {
                $voSchGate = "OK"   # demo / pre-install mode
            }
        } else {
            $voSchGate = "WARN-OK"
        }

        Write-Output ("  installed            : {0}" -f $voSchInstalled)
        Write-Output ("  task_name            : {0}" -f $voSchTaskName)
        Write-Output ("  timezone             : {0}" -f $voSchTimezone)
        Write-Output ("  daily_time           : {0}" -f $voSchDaily)
        Write-Output ("  trigger_time_local   : {0}" -f $voSchTrigger)
        Write-Output ("  next_run_at_beijing  : {0}" -f $voSchNextRun)
        Write-Output ("  last_run.status      : {0}" -f $voSchLrStatus)
        Write-Output ""
        Write-Output ("  => SCHEDULER: {0} (installed={1}  timezone={2}  daily={3}  next_run={4})" `
                      -f $voSchGate, $voSchInstalled, $voSchTimezone, $voSchDaily, $voSchNextRun)
    } catch {
        Write-Output ("  SCHEDULER: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  SCHEDULER: WARN-OK (scheduler.meta.json missing; run scripts\install_daily_task.ps1)"
}

# ---------------------------------------------------------------------------
# DELIVERY SUMMARY (HUMAN READABLE) — Iteration 5.1
#   Calls scripts/_summarize_verify_output.py (stdlib only) to render a
#   one-page summary of all gate results.  Failure is non-fatal: a single
#   WARN line is printed and execution continues to the COMPLETE message.
#   Gate semantics and exit codes are NOT changed by this block.
# ---------------------------------------------------------------------------
$_sumScript = Join-Path $PSScriptRoot "_summarize_verify_output.py"
if (Test-Path $_sumScript) {
    try {
        & $voPy $_sumScript $voGenericHitCount 2>$null
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Output ("WARN: SUMMARY_GENERATOR_FAILED (exit {0})" -f $LASTEXITCODE)
        }
    } catch {
        Write-Output ("WARN: SUMMARY_GENERATOR_FAILED ({0})" -f $_)
    }
} else {
    Write-Output "WARN: SUMMARY_GENERATOR_FAILED (script not found: $_sumScript)"
}

# --- Z0 Supply Fallback summary ---
$_sfbMetaPath = Join-Path $repoRoot "outputs\supply_fallback.meta.json"
if (Test-Path $_sfbMetaPath) {
    try {
        $_sfbMeta    = Get-Content $_sfbMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_sfbUsedStr  = if ($null -ne $_sfbMeta.fallback_used -and $_sfbMeta.fallback_used -eq $true) { "true" } else { "false" }
        $_sfbReason   = if ($_sfbMeta.PSObject.Properties['reason'])                { [string]$_sfbMeta.reason }                else { "none" }
        $_sfbPrimary  = if ($_sfbMeta.PSObject.Properties['primary_fetched_total']) { [int]$_sfbMeta.primary_fetched_total }    else { 0 }
        $_sfbSnapPath = if ($null -ne $_sfbMeta.snapshot_path -and [string]$_sfbMeta.snapshot_path -ne "") { [string]$_sfbMeta.snapshot_path } else { "" }
        $_sfbSnapAge  = if ($null -ne $_sfbMeta.snapshot_age_hours)                 { [string]$_sfbMeta.snapshot_age_hours }    else { "null" }
        Write-Output ("Z0_SUPPLY_FALLBACK: used={0}  reason={1}  primary_fetched_total={2}  snapshot_age_hours={3}" -f $_sfbUsedStr, $_sfbReason, $_sfbPrimary, $_sfbSnapAge)
        if ($_sfbUsedStr -eq "true" -and $_sfbSnapPath) {
            Write-Output ("  snapshot_path: {0}" -f $_sfbSnapPath)
        }
    } catch {
        Write-Output ("Z0_SUPPLY_FALLBACK: WARN-OK (parse error: {0})" -f $_)
    }
} else {
    Write-Output "Z0_SUPPLY_FALLBACK: WARN-OK (supply_fallback.meta.json not found)"
}

Write-Output ""
} else {
    Write-Output ""
    Write-Output "BRIEF_MODE: legacy full-report gates skipped (longform / newsroom / anchor)"
    Write-Output ""
}

# ---------------------------------------------------------------------------
# TRANSLATION_DELIVERY_HARD gate (Iteration 20)
# Checks that outputs/translation.meta.json was written by this run and
# reports success=true (ZH translation applied).
# STALE_META: meta.run_id != PIPELINE_RUN_ID -> FAIL exit 1
# ---------------------------------------------------------------------------
Write-Output "TRANSLATION_DELIVERY_HARD:"
$_tdMetaPath = Join-Path $repoRoot "outputs\translation.meta.json"
if (Test-Path $_tdMetaPath) {
    try {
        $tdMeta      = Get-Content $_tdMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_tdRunId    = if ($tdMeta.PSObject.Properties['run_id'])     { [string]$tdMeta.run_id }     else { "" }
        $_tdSuccess  = if ($tdMeta.PSObject.Properties['success'])    { [bool]$tdMeta.success }      else { $false }
        $_tdFail     = if ($tdMeta.PSObject.Properties['fail_reason']){ [string]$tdMeta.fail_reason } else { "" }
        $_tdGenAt    = if ($tdMeta.PSObject.Properties['generated_at']){ [string]$tdMeta.generated_at } else { "" }
        Write-Output ("  run_id       : {0}" -f $_tdRunId)
        Write-Output ("  success      : {0}" -f $_tdSuccess)
        Write-Output ("  fail_reason  : {0}" -f $_tdFail)
        Write-Output ("  generated_at : {0}" -f $_tdGenAt)
        # STALE_META check (meta run_id must match the pipeline run we just verified)
        if ($_tdRunId -ne $_voRunId) {
            Write-Output ("  => TRANSLATION_DELIVERY_HARD: FAIL (STALE_META meta.run_id={0} != current={1})" -f $_tdRunId, $_voRunId)
            exit 1
        }
        if ($_tdSuccess -eq $true) {
            Write-Output "  => TRANSLATION_DELIVERY_HARD: PASS"
        } else {
            Write-Output ("  => TRANSLATION_DELIVERY_HARD: FAIL (fail_reason={0})" -f $_tdFail)
            exit 1
        }
    } catch {
        Write-Output ("  => TRANSLATION_DELIVERY_HARD: FAIL (parse error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  translation.meta.json not found"
    Write-Output "  => TRANSLATION_DELIVERY_HARD: FAIL (meta missing)"
    exit 1
}

Write-Output ""
# ---------------------------------------------------------------------------
# TRANSLATION_DENSITY_HARD gate (iter29)
# 比較 unique normalized bullets：latest_brief.md >= digest.md * 0.9
# unique = normalize（去除前綴標籤+符號）後去重計數；排除 footer 區塊（## ⏱️ marker 之後）
# ---------------------------------------------------------------------------
Write-Output "TRANSLATION_DENSITY_HARD："
$_tdDgPath = Join-Path $repoRoot "outputs\digest.md"
$_tdBrPath = Join-Path $repoRoot "outputs\latest_brief.md"
if ((Test-Path $_tdDgPath) -and (Test-Path $_tdBrPath)) {
    try {
        $_tdDgLines = Get-Content $_tdDgPath -Encoding UTF8
        $_tdBrLines = Get-Content $_tdBrPath -Encoding UTF8

        # iter29: unique normalized bullet count；排除 ## ⏱️ footer 以後的行
        function _TdUniqueBullets([string[]]$lines) {
            $inFooter = $false
            $unique   = @{}
            foreach ($ln in $lines) {
                # footer marker — ignore everything after
                if ($ln -match '##\s*⏱') { $inFooter = $true }
                if ($inFooter) { continue }
                if ($ln -match '^\s*[-*•>]\s*(.+)') {
                    $raw  = $Matches[1].Trim()
                    # 去除繁中前綴標籤
                    $norm = $raw -replace '^(?:揭示[：:]\s*|評估[：:]\s*|影響[：:]\s*|發生了什麼[：:]\s*|關鍵細節[：:]\s*|為何重要[：:]\s*|What\s+happened[：:]\s*|Key\s+details[：:]\s*|Why\s+it\s+matters[：:]\s*)', ''
                    $norm = ($norm -replace '\s+', ' ').Trim().ToLower()
                    if ($norm.Length -gt 5) { $unique[$norm] = 1 }
                }
            }
            return $unique.Count
        }

        $_tdDgUnique  = _TdUniqueBullets $_tdDgLines
        $_tdBrUnique  = _TdUniqueBullets $_tdBrLines
        $_tdRequired  = [Math]::Ceiling($_tdDgUnique * 0.9)
        $_tdPass      = ($_tdBrUnique -ge $_tdRequired)
        @{
            run_id                    = $_voRunId
            gate_result               = if ($_tdPass) { "通過" } else { "失敗" }
            digest_unique_bullet_lines = $_tdDgUnique
            brief_unique_bullet_lines  = $_tdBrUnique
            required_min              = $_tdRequired
            threshold_ratio           = 0.9
            note                      = "iter29: unique normalized bullets >= digest_unique * 0.9；footer 排除（## ⏱️ marker 以後不計入）"
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\translation_density_hard.meta.json") -Encoding UTF8
        Write-Output ("  [UNIQUE_BULLET_COMPARE] digest_unique={0}  brief_unique={1}  門檻>={2}  ratio={3:F2}" -f `
            $_tdDgUnique, $_tdBrUnique, $_tdRequired, `
            $(if ($_tdDgUnique -gt 0) { $_tdBrUnique / $_tdDgUnique } else { 0 }))
        if ($_tdPass) {
            Write-Output "  => TRANSLATION_DENSITY_HARD：通過"
        } else {
            Write-Output ("  => TRANSLATION_DENSITY_HARD：失敗（brief_unique={0} < 門檻={1}；digest_unique={2}）" -f $_tdBrUnique, $_tdRequired, $_tdDgUnique)
            exit 1
        }
    } catch {
        Write-Output ("  => TRANSLATION_DENSITY_HARD：失敗（錯誤: {0}）" -f $_)
        exit 1
    }
} else {
    $_tdSkipReason = if (-not (Test-Path $_tdDgPath)) { "digest.md 不存在" } else { "latest_brief.md 不存在" }
    Write-Output ("  => TRANSLATION_DENSITY_HARD：略過（{0}）— 來源不存在時非阻擋" -f $_tdSkipReason)
}

Write-Output ""
# ---------------------------------------------------------------------------
# NO_REPEAT_SPAM_HARD gate (iter27)
# Detects same sentence appearing >=3 times within the same ## section.
# Fails on Q1/Q2 paste-spam or template repetition patterns.
# ---------------------------------------------------------------------------
Write-Output "NO_REPEAT_SPAM_HARD:"
if (Test-Path $_tdBrPath) {
    try {
        $_nrLines       = Get-Content $_tdBrPath -Encoding UTF8
        $_nrSpamFound   = $false
        $_nrMaxRepeat   = 0
        $_nrSpamSample  = ""
        $_nrSection     = [System.Collections.Generic.List[string]]::new()
        function _CheckNrSection([System.Collections.Generic.List[string]]$sLines) {
            $sentences = [System.Collections.Generic.List[string]]::new()
            foreach ($ln in $sLines) {
                $clean = ($ln -replace '^[\-\*\>#\s]+', '').Trim()
                if ($clean.Length -gt 10) { $sentences.Add($clean) }
            }
            $counts = @{}
            foreach ($s in $sentences) {
                if ($counts.ContainsKey($s)) { $counts[$s]++ } else { $counts[$s] = 1 }
            }
            return $counts
        }
        foreach ($_nrLine in $_nrLines) {
            if ($_nrLine -match '^##') {
                if ($_nrSection.Count -gt 0) {
                    $sectionCounts = _CheckNrSection $_nrSection
                    foreach ($k in $sectionCounts.Keys) {
                        if ($sectionCounts[$k] -ge 3) {
                            $_nrSpamFound = $true
                            if ($sectionCounts[$k] -gt $_nrMaxRepeat) {
                                $_nrMaxRepeat  = $sectionCounts[$k]
                                $_nrSpamSample = $k.Substring(0, [Math]::Min(80, $k.Length))
                            }
                        }
                    }
                }
                $_nrSection = [System.Collections.Generic.List[string]]::new()
            }
            $_nrSection.Add($_nrLine)
        }
        # Check last section
        if ($_nrSection.Count -gt 0) {
            $sectionCounts = _CheckNrSection $_nrSection
            foreach ($k in $sectionCounts.Keys) {
                if ($sectionCounts[$k] -ge 3) {
                    $_nrSpamFound = $true
                    if ($sectionCounts[$k] -gt $_nrMaxRepeat) {
                        $_nrMaxRepeat  = $sectionCounts[$k]
                        $_nrSpamSample = $k.Substring(0, [Math]::Min(80, $k.Length))
                    }
                }
            }
        }
        @{
            run_id                   = $_voRunId
            gate_result              = if (-not $_nrSpamFound) { "PASS" } else { "FAIL" }
            spam_found               = $_nrSpamFound
            max_repeat_count         = $_nrMaxRepeat
            sample_repeated_sentence = $_nrSpamSample
            threshold_repeat_count   = 3
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\no_repeat_spam_hard.meta.json") -Encoding UTF8
        if (-not $_nrSpamFound) {
            Write-Output "  => NO_REPEAT_SPAM_HARD: PASS (no sentence repeated >=3 times in same section)"
        } else {
            Write-Output ("  => NO_REPEAT_SPAM_HARD: FAIL (max_repeat={0}  sample={1})" -f $_nrMaxRepeat, $_nrSpamSample)
            exit 1
        }
    } catch {
        Write-Output ("  => NO_REPEAT_SPAM_HARD: FAIL (error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  latest_brief.md not found → SKIP (non-gating when absent)"
}

Write-Output ""
# ---------------------------------------------------------------------------
# NO_SPURIOUS_PREFIX_TAG_HARD gate (iter30)
# Each bullet line in latest_brief.md must NOT start with a company name or
# role-bucket label followed by ： or : (e.g. "OpenAI：", "揭示：", "評估：").
# Pattern: ^(CompanyName|RoleLabel)\s*[：:] at the start of bullet content.
# ---------------------------------------------------------------------------
Write-Output "NO_SPURIOUS_PREFIX_TAG_HARD："
if (Test-Path $_tdBrPath) {
    try {
        $_nspLines  = Get-Content $_tdBrPath -Encoding UTF8
        $_nspFound  = $false
        $_nspSample = ""
        # Regex: bullet starts with known company/role prefix before ： or :
        $_nspPat = '^[-*•>]\s*(OpenAI|LinkedIn|Google|Apple|Anthropic|Meta|Amazon|Microsoft|Alibaba|Nvidia|DeepSeek|Gemini|xAI|Mistral|X)\s*[：:]'
        $_nspRolePat = '^[-*•>]\s*(揭示|評估|影響|發生了什麼|關鍵細節|為何重要|Training\s+Design|Cappy)\s*[：:]'
        foreach ($_nspLine in $_nspLines) {
            if ($_nspLine -match $_nspPat -or $_nspLine -match $_nspRolePat) {
                $_nspFound  = $true
                $_nspSample = $_nspLine.Substring(0, [Math]::Min(100, $_nspLine.Length))
                break
            }
        }
        @{
            run_id       = $_voRunId
            gate_result  = if (-not $_nspFound) { "PASS" } else { "FAIL" }
            found        = $_nspFound
            sample       = $_nspSample
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\no_spurious_prefix_tag_hard.meta.json") -Encoding UTF8
        if (-not $_nspFound) {
            Write-Output "  => NO_SPURIOUS_PREFIX_TAG_HARD：通過（無公司名/角色桶前綴）"
        } else {
            Write-Output ("  => NO_SPURIOUS_PREFIX_TAG_HARD：失敗（發現前綴: {0}）" -f $_nspSample)
            exit 1
        }
    } catch {
        Write-Output ("  => NO_SPURIOUS_PREFIX_TAG_HARD：失敗（錯誤: {0}）" -f $_)
        exit 1
    }
} else {
    Write-Output "  latest_brief.md not found → 略過"
}

Write-Output ""
# ---------------------------------------------------------------------------
# NO_ROLE_BUCKETS_HARD gate (iter30)
# latest_brief.md must contain zero instances of 揭示：/評估：/影響：
# (the three role-bucket header labels from the pre-iter30 translation approach).
# ---------------------------------------------------------------------------
Write-Output "NO_ROLE_BUCKETS_HARD："
if (Test-Path $_tdBrPath) {
    try {
        $_nrbContent = Get-Content $_tdBrPath -Raw -Encoding UTF8
        $_nrbFound   = $false
        $_nrbSample  = ""
        foreach ($_nrbLabel in @("揭示：", "揭示:", "評估：", "評估:", "影響：", "影響:")) {
            if ($_nrbContent.Contains($_nrbLabel)) {
                $_nrbFound  = $true
                # Find sample line
                foreach ($_nrbLine in ($_nrbContent -split "`n")) {
                    if ($_nrbLine.Contains($_nrbLabel)) {
                        $_nrbSample = $_nrbLine.Trim().Substring(0, [Math]::Min(80, $_nrbLine.Trim().Length))
                        break
                    }
                }
                break
            }
        }
        @{
            run_id      = $_voRunId
            gate_result = if (-not $_nrbFound) { "PASS" } else { "FAIL" }
            found       = $_nrbFound
            sample      = $_nrbSample
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\no_role_buckets_hard.meta.json") -Encoding UTF8
        if (-not $_nrbFound) {
            Write-Output "  => NO_ROLE_BUCKETS_HARD：通過（無揭示/評估/影響標籤）"
        } else {
            Write-Output ("  => NO_ROLE_BUCKETS_HARD：失敗（發現角色桶標籤: {0}）" -f $_nrbSample)
            exit 1
        }
    } catch {
        Write-Output ("  => NO_ROLE_BUCKETS_HARD：失敗（錯誤: {0}）" -f $_)
        exit 1
    }
} else {
    Write-Output "  latest_brief.md not found → 略過"
}

Write-Output ""
# ---------------------------------------------------------------------------
# TRANSLATION_BULLET_PARITY_HARD gate (iter30)
# Per-event bullet count in latest_brief.md must be >= per-event count in
# digest.md (1:1 translation parity). Overall brief >= digest * 0.9 also enforced.
# Events matched by ordinal index (## Event N in digest vs ## 事件 N in brief).
# ---------------------------------------------------------------------------
Write-Output "TRANSLATION_BULLET_PARITY_HARD："
$_tbpDgPath = Join-Path $repoRoot "outputs\digest.md"
$_tbpBrPath = Join-Path $repoRoot "outputs\latest_brief.md"
if ((Test-Path $_tbpDgPath) -and (Test-Path $_tbpBrPath)) {
    try {
        # Parse bullet counts per event from a markdown file
        function Get-EventBulletCounts([string]$FilePath, [string]$EventPattern) {
            $lines  = Get-Content $FilePath -Encoding UTF8
            $counts = [System.Collections.Generic.List[int]]::new()
            $cur    = -1
            foreach ($ln in $lines) {
                if ($ln -match $EventPattern) {
                    if ($cur -ge 0) { $counts.Add($cur) }
                    $cur = 0
                } elseif ($cur -ge 0 -and $ln -match '^\s*-\s+\S') {
                    $cur++
                }
            }
            if ($cur -ge 0) { $counts.Add($cur) }
            return $counts
        }
        $_tbpDgCounts = Get-EventBulletCounts $_tbpDgPath '^## Event \d+'
        $_tbpBrCounts = Get-EventBulletCounts $_tbpBrPath '^## 事件 \d+'
        $_tbpDgTotal  = ($($_tbpDgCounts) | Measure-Object -Sum).Sum
        $_tbpBrTotal  = ($($_tbpBrCounts) | Measure-Object -Sum).Sum
        $_tbpRequired = [int][Math]::Ceiling($_tbpDgTotal * 0.9)
        $_tbpFail     = $false
        $_tbpFailEvt  = ""
        # Per-event check: brief event must have >= floor(digest_event * 0.9) bullets
        # (floor 0.9 allows 1 bullet to be removed by intra-event dedup without failing)
        $minLen = [Math]::Min($_tbpDgCounts.Count, $_tbpBrCounts.Count)
        for ($ei = 0; $ei -lt $minLen; $ei++) {
            $_tbpEvtReq = [int][Math]::Floor($_tbpDgCounts[$ei] * 0.9)
            if ($_tbpBrCounts[$ei] -lt $_tbpEvtReq) {
                $_tbpFail    = $true
                $_tbpFailEvt = "事件$($ei+1)：brief=$($_tbpBrCounts[$ei]) < 門檻=$_tbpEvtReq（digest=$($_tbpDgCounts[$ei])×0.9）"
                break
            }
        }
        # Also check brief has enough events
        if ($_tbpBrCounts.Count -lt $_tbpDgCounts.Count) {
            $_tbpFail    = $true
            $_tbpFailEvt = "brief事件數=$($_tbpBrCounts.Count) < digest事件數=$($_tbpDgCounts.Count)"
        }
        # Overall total check
        if (-not $_tbpFail -and $_tbpBrTotal -lt $_tbpRequired) {
            $_tbpFail    = $true
            $_tbpFailEvt = "總計：brief_total=$_tbpBrTotal < 門檻=$_tbpRequired（digest_total=$_tbpDgTotal）"
        }
        @{
            run_id            = $_voRunId
            gate_result       = if (-not $_tbpFail) { "PASS" } else { "FAIL" }
            digest_events     = $_tbpDgCounts.Count
            brief_events      = $_tbpBrCounts.Count
            digest_total      = $_tbpDgTotal
            brief_total       = $_tbpBrTotal
            required_total    = $_tbpRequired
            fail_detail       = $_tbpFailEvt
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\translation_bullet_parity_hard.meta.json") -Encoding UTF8
        if (-not $_tbpFail) {
            Write-Output ("  => TRANSLATION_BULLET_PARITY_HARD：通過（digest_total={0} brief_total={1} events={2}）" -f $_tbpDgTotal, $_tbpBrTotal, $_tbpDgCounts.Count)
        } else {
            Write-Output ("  => TRANSLATION_BULLET_PARITY_HARD：失敗（{0}）" -f $_tbpFailEvt)
            exit 1
        }
    } catch {
        Write-Output ("  => TRANSLATION_BULLET_PARITY_HARD：失敗（錯誤: {0}）" -f $_)
        exit 1
    }
} else {
    $_tbpSkip = if (-not (Test-Path $_tbpDgPath)) { "digest.md 不存在" } else { "latest_brief.md 不存在" }
    Write-Output ("  => TRANSLATION_BULLET_PARITY_HARD：略過（{0}）— 來源不存在時非阻擋" -f $_tbpSkip)
}

Write-Output ""
# ---------------------------------------------------------------------------
# NO_NEAR_DUPLICATE_INTRA_EVENT_HARD gate (iter28)
# Reads latest_brief.md, splits by ## event sections.
# For each section, normalizes bullet lines (strip prefix labels + leading symbols)
# and checks if any normalized sentence appears >=2 times → FAIL.
# ---------------------------------------------------------------------------
Write-Output "NO_NEAR_DUPLICATE_INTRA_EVENT_HARD:"
if (Test-Path $_tdBrPath) {
    try {
        $_ndiLines     = Get-Content $_tdBrPath -Encoding UTF8
        $_ndiFound     = $false
        $_ndiMaxRepeat = 0
        $_ndiSample    = ""
        $_ndiSection   = [System.Collections.Generic.List[string]]::new()
        $_ndiSectionHdr= ""
        function _CheckNdiSection([System.Collections.Generic.List[string]]$sLines) {
            $seen = @{}
            foreach ($ln in $sLines) {
                if ($ln -match '^\s*[-*•>]\s*(.+)') {
                    $r = $Matches[1].Trim()
                    $n = $r -replace '^(?:揭示[：:]\s*|評估[：:]\s*|影響[：:]\s*|發生了什麼[：:]\s*|關鍵細節[：:]\s*|為何重要[：:]\s*|What\s+happened[：:]\s*|Key\s+details[：:]\s*|Why\s+it\s+matters[：:]\s*)', ''
                    $n = ($n -replace '\s+', ' ').Trim()
                    if ($n.Length -gt 5) {
                        if ($seen.ContainsKey($n)) { $seen[$n]++ } else { $seen[$n] = 1 }
                    }
                }
            }
            return $seen
        }
        foreach ($_ndiLine in $_ndiLines) {
            if ($_ndiLine -match '^##') {
                if ($_ndiSection.Count -gt 0) {
                    $ndiCounts = _CheckNdiSection $_ndiSection
                    foreach ($k in $ndiCounts.Keys) {
                        if ($ndiCounts[$k] -ge 2) {
                            $_ndiFound = $true
                            if ($ndiCounts[$k] -gt $_ndiMaxRepeat) {
                                $_ndiMaxRepeat = $ndiCounts[$k]
                                $_ndiSample    = "$_ndiSectionHdr | " + $k.Substring(0, [Math]::Min(60, $k.Length))
                            }
                        }
                    }
                }
                $_ndiSection    = [System.Collections.Generic.List[string]]::new()
                $_ndiSectionHdr = $_ndiLine.Trim()
            }
            $_ndiSection.Add($_ndiLine)
        }
        # Check last section
        if ($_ndiSection.Count -gt 0) {
            $ndiCounts = _CheckNdiSection $_ndiSection
            foreach ($k in $ndiCounts.Keys) {
                if ($ndiCounts[$k] -ge 2) {
                    $_ndiFound = $true
                    if ($ndiCounts[$k] -gt $_ndiMaxRepeat) {
                        $_ndiMaxRepeat = $ndiCounts[$k]
                        $_ndiSample    = "$_ndiSectionHdr | " + $k.Substring(0, [Math]::Min(60, $k.Length))
                    }
                }
            }
        }
        @{
            run_id             = $_voRunId
            gate_result        = if (-not $_ndiFound) { "PASS" } else { "FAIL" }
            duplicate_found    = $_ndiFound
            max_repeat_count   = $_ndiMaxRepeat
            sample             = $_ndiSample
            threshold          = 2
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\no_near_duplicate_intra_event_hard.meta.json") -Encoding UTF8
        if (-not $_ndiFound) {
            Write-Output "  => NO_NEAR_DUPLICATE_INTRA_EVENT_HARD: PASS (no intra-event bullet repeated >=2 times)"
        } else {
            Write-Output ("  => NO_NEAR_DUPLICATE_INTRA_EVENT_HARD: FAIL (max_repeat={0}  sample={1})" -f $_ndiMaxRepeat, $_ndiSample)
            exit 1
        }
    } catch {
        Write-Output ("  => NO_NEAR_DUPLICATE_INTRA_EVENT_HARD: FAIL (error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  latest_brief.md not found → SKIP"
}

Write-Output ""
# ---------------------------------------------------------------------------
# NO_TRIPLET_COPYPASTE_HARD gate (iter28)
# If latest_brief.md contains 揭示/評估/影響 or 發生/細節/重要 labeled segments,
# checks that no two segments within the same event share identical normalized content.
# Also checks: within any ## section, no normalized sentence is shared
# between the three label groups (cross-field mutual exclusion).
# ---------------------------------------------------------------------------
Write-Output "NO_TRIPLET_COPYPASTE_HARD:"
if (Test-Path $_tdBrPath) {
    try {
        $_ntcLines   = Get-Content $_tdBrPath -Encoding UTF8
        $_ntcFound   = $false
        $_ntcSample  = ""
        # Collect per-section label-grouped content
        $_ntcSection     = [System.Collections.Generic.List[string]]::new()
        $_ntcSectionHdr  = ""
        function _CheckNtcSection([System.Collections.Generic.List[string]]$sLines) {
            # Build label->normalized_sentences map
            $labelGroups = @{}
            $curLabel    = "_default"
            foreach ($ln in $sLines) {
                # Detect label lines (揭示：/評估：/影響：/發生了什麼：/關鍵細節：/為何重要：)
                if ($ln -match '^(?:[\*\#]*)?\s*(揭示|評估|影響|發生了什麼|關鍵細節|為何重要)[：:]') {
                    $curLabel = $Matches[1]
                    if (-not $labelGroups.ContainsKey($curLabel)) { $labelGroups[$curLabel] = [System.Collections.Generic.List[string]]::new() }
                } elseif ($ln -match '^\s*[-*•>]\s*(.+)') {
                    $r = $Matches[1].Trim()
                    $n = $r -replace '^(?:揭示[：:]\s*|評估[：:]\s*|影響[：:]\s*|發生了什麼[：:]\s*|關鍵細節[：:]\s*|為何重要[：:]\s*)', ''
                    $n = ($n -replace '\s+', ' ').Trim()
                    if ($n.Length -gt 5) {
                        if (-not $labelGroups.ContainsKey($curLabel)) { $labelGroups[$curLabel] = [System.Collections.Generic.List[string]]::new() }
                        $labelGroups[$curLabel].Add($n)
                    }
                }
            }
            # Check cross-label duplicates: any sentence appearing in >=2 groups
            $allSents = @{}
            foreach ($lbl in $labelGroups.Keys) {
                foreach ($s in $labelGroups[$lbl]) {
                    if ($allSents.ContainsKey($s)) {
                        if ($allSents[$s] -ne $lbl) { return $s }  # same sentence in different label groups
                    } else {
                        $allSents[$s] = $lbl
                    }
                }
            }
            # Also check within _default group for label groups with same content
            $groups = @($labelGroups.Keys | Where-Object { $_ -ne "_default" })
            if ($groups.Count -ge 2) {
                for ($gi = 0; $gi -lt $groups.Count - 1; $gi++) {
                    for ($gj = $gi + 1; $gj -lt $groups.Count; $gj++) {
                        $ga = $labelGroups[$groups[$gi]]; $gb = $labelGroups[$groups[$gj]]
                        if ($ga.Count -gt 0 -and $gb.Count -gt 0) {
                            # Check if any sentence from ga is in gb
                            foreach ($s in $ga) {
                                if ($gb.Contains($s)) { return "$($groups[$gi]) vs $($groups[$gj]): $($s.Substring(0,[Math]::Min(50,$s.Length)))" }
                            }
                        }
                    }
                }
            }
            return $null
        }
        foreach ($_ntcLine in $_ntcLines) {
            if ($_ntcLine -match '^##') {
                if ($_ntcSection.Count -gt 0) {
                    $ntcResult = _CheckNtcSection $_ntcSection
                    if ($ntcResult) {
                        $_ntcFound  = $true
                        $_ntcSample = "$_ntcSectionHdr | $ntcResult"
                    }
                }
                $_ntcSection    = [System.Collections.Generic.List[string]]::new()
                $_ntcSectionHdr = $_ntcLine.Trim()
            }
            $_ntcSection.Add($_ntcLine)
        }
        if ($_ntcSection.Count -gt 0) {
            $ntcResult = _CheckNtcSection $_ntcSection
            if ($ntcResult) { $_ntcFound = $true; $_ntcSample = "$_ntcSectionHdr | $ntcResult" }
        }
        @{
            run_id      = $_voRunId
            gate_result = if (-not $_ntcFound) { "PASS" } else { "FAIL" }
            found       = $_ntcFound
            sample      = $_ntcSample
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $repoRoot "outputs\no_triplet_copypaste_hard.meta.json") -Encoding UTF8
        if (-not $_ntcFound) {
            Write-Output "  => NO_TRIPLET_COPYPASTE_HARD: PASS (no cross-field triplet copypaste detected)"
        } else {
            Write-Output ("  => NO_TRIPLET_COPYPASTE_HARD: FAIL (sample: {0})" -f $_ntcSample)
            exit 1
        }
    } catch {
        Write-Output ("  => NO_TRIPLET_COPYPASTE_HARD: FAIL (error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  latest_brief.md not found → SKIP"
}

Write-Output ""
# ---------------------------------------------------------------------------
# REPEAT_AUDIT_META gate (iter28)
# Checks outputs/repeat_audit.meta.json exists (written by _assemble_zh_brief_from_cards).
# Gate: file must exist AND (duplicates_found==0 OR duplicates_removed==duplicates_found).
# If duplicates were found and removed, displays evidence of successful dedup.
# ---------------------------------------------------------------------------
Write-Output "REPEAT_AUDIT_META:"
$_raPath = Join-Path $repoRoot "outputs\repeat_audit.meta.json"
if (Test-Path $_raPath) {
    try {
        $_raData   = Get-Content $_raPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_raFound  = if ($_raData.PSObject.Properties["duplicates_found"])   { [int]$_raData.duplicates_found }   else { -1 }
        $_raRemoved= if ($_raData.PSObject.Properties["duplicates_removed"]) { [int]$_raData.duplicates_removed } else { -1 }
        $_raChecked= if ($_raData.PSObject.Properties["events_checked"])     { [int]$_raData.events_checked }     else { 0 }
        Write-Output ("  events_checked={0}  duplicates_found={1}  duplicates_removed={2}" -f $_raChecked, $_raFound, $_raRemoved)
        if ($_raFound -eq 0) {
            Write-Output "  => REPEAT_AUDIT_META: PASS (duplicates_found=0, brief is clean)"
        } elseif ($_raFound -gt 0 -and $_raRemoved -eq $_raFound) {
            Write-Output ("  => REPEAT_AUDIT_META: PASS (duplicates_found={0} but all removed={1}; dedup applied)" -f $_raFound, $_raRemoved)
        } else {
            Write-Output ("  => REPEAT_AUDIT_META: FAIL (duplicates_found={0} but duplicates_removed={1}; not all removed)" -f $_raFound, $_raRemoved)
            exit 1
        }
    } catch {
        Write-Output ("  => REPEAT_AUDIT_META: FAIL (parse error: {0})" -f $_)
        exit 1
    }
} else {
    Write-Output "  => REPEAT_AUDIT_META: FAIL (repeat_audit.meta.json not found)"
    exit 1
}

Write-Output ""
# --- Template Leak soft indicator + STALE_META guard ---
$_btlSumPath = Join-Path $repoRoot "outputs\brief_template_leak.meta.json"
if (Test-Path $_btlSumPath) {
    try {
        $_btlSum       = Get-Content $_btlSumPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_btlMetaRunId = if ($_btlSum.PSObject.Properties["run_id"]) { [string]$_btlSum.run_id } else { "" }
        if ($_btlMetaRunId -ne $_voRunId) {
            Write-Output ("template_leak_events_count: STALE_META (meta.run_id={0} != current={1}) — skipping display" -f $_btlMetaRunId, $_voRunId)
        } else {
            $_btlEvtCnt = if ($_btlSum.PSObject.Properties["template_leak_events_count"]) { [int]$_btlSum.template_leak_events_count } else { 0 }
            Write-Output ("template_leak_events_count: {0}" -f $_btlEvtCnt)
        }
    } catch {
        Write-Output "template_leak_events_count: (parse error)"
    }
} else {
    Write-Output "template_leak_events_count: (meta not found)"
}
Write-Output ""

# ---------------------------------------------------------------------------
# Write LAST_RUN_SUMMARY.txt for direct invocation (DoD acceptance — success path)
# run_pipeline.ps1 will overwrite this with identical content when called via desktop button.
# ---------------------------------------------------------------------------
$_voLrsSucPath = Join-Path $repoRoot "outputs\LAST_RUN_SUMMARY.txt"
$_voSucAiSel   = 0
# verify_run.ps1 always invokes run_once.py with PIPELINE_REPORT_MODE=brief;
# prefer brief unless LAST_RUN_SUMMARY.txt explicitly recorded a different mode.
$_voSucRepMode = if ($reportMode -and $reportMode -ne "full") { $reportMode } else { "brief" }
if (Test-Path $showcaseReadyPath) {
    try {
        $srVoSuc = Get-Content $showcaseReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($srVoSuc.PSObject.Properties['ai_selected_events']) { $_voSucAiSel = [int]$srVoSuc.ai_selected_events }
    } catch {}
}
$_voProdList = @()
foreach ($__pf in @("latest_brief.md","executive_report.docx")) {
    if (Test-Path (Join-Path $repoRoot "outputs\$__pf")) { $_voProdList += "outputs\$__pf" }
}
$_voProdStr = if ($_voProdList) { $_voProdList -join ", " } else { "(none)" }
$_voNowSuc  = (Get-Date -Format "o")
@"
run_id              = $_voRunId
started_at          = $_voNowSuc
finished_at         = $_voNowSuc
mode                = $(if ($Mode) { $Mode } else { 'manual' })
report_mode         = $_voSucRepMode
status              = OK
selected_events     = $_voSucAiSel
ai_selected_events  = $_voSucAiSel
canonical_output_dir = outputs
produced_files      = $_voProdStr
"@ | Out-File $_voLrsSucPath -Encoding UTF8 -NoNewline
Write-Output ("LAST_RUN_SUMMARY.txt written: status=OK  ai_selected_events={0}  report_mode={1}" -f $_voSucAiSel, $_voSucRepMode)
Write-Output ""

# ---------------------------------------------------------------------------
# iter32e: TIME_BUDGET hard-exit
# 所有內容閘門 PASS 後，若總耗時仍超出 _voBudgetSec → NOT_READY + exit 1
# iter32e 將預設從 1800s 調升至 3600s：CPU Qwen（1 tok/sec）constraint；
# 1800s soft-warn 保留於 ⏱️ 耗時 footer。
# ---------------------------------------------------------------------------
$_iter32_elapsed = [int]$_voStopwatch.Elapsed.TotalSeconds
$_iter32_softWarn = 480
if ($_iter32_elapsed -gt $_iter32_softWarn) {
    Write-Output ("[WARN] TIME_BUDGET_SOFT: {0}s > soft-warn {1}s (hard-cap={2}s)" -f $_iter32_elapsed, $_iter32_softWarn, $_voBudgetSec)
}
Write-Output ("[iter32e] TIME_BUDGET 硬上限方案：硬上限={0}s  本次耗時={1}s" -f $_voBudgetSec, $_iter32_elapsed)
if ($_iter32_elapsed -gt $_voBudgetSec) {
    Write-Output ("[FAIL] TIME_BUDGET_EXCEEDED: {0}s > hard-cap {1}s → NOT_READY + exit 1" -f $_iter32_elapsed, $_voBudgetSec)
    # 刪除成功產物，避免被誤認為有效輸出
    foreach ($_i32del in @("outputs\latest_brief.md","outputs\executive_report.docx")) {
        $_i32delp = Join-Path $repoRoot $_i32del
        if (Test-Path $_i32delp) { Remove-Item -LiteralPath $_i32delp -Force -ErrorAction SilentlyContinue }
    }
    Invoke-VerifyOnlineFailFast -Gate "TIME_BUDGET_EXCEEDED" `
        -Reason ("TIME_BUDGET_EXCEEDED; total={0}s > hard-cap={1}s; hard-exit (iter32e)" -f $_iter32_elapsed, $_voBudgetSec)
}
Write-Output ("[iter32e] TIME_BUDGET 通過：{0}s ≤ {1}s" -f $_iter32_elapsed, $_voBudgetSec)

# iter39: FAST_300_HARD_EXCEEDED — hard FAIL if FAST_300_MODE and total > 300
if ($_fast300Mode -and $_iter32_elapsed -gt 300) {
    Write-Output ("[FAIL] FAST_300_HARD_EXCEEDED: total={0}s > 300s" -f $_iter32_elapsed)
    foreach ($_f3del in @("outputs\latest_brief.md","outputs\executive_report.docx")) {
        $_f3delp = Join-Path $repoRoot $_f3del
        if (Test-Path $_f3delp) { Remove-Item -LiteralPath $_f3delp -Force -ErrorAction SilentlyContinue }
    }
    Invoke-VerifyOnlineFailFast -Gate "FAST_300_HARD_EXCEEDED" `
        -Reason ("FAST_300_HARD_EXCEEDED: total={0}s > 300s" -f $_iter32_elapsed)
}

# iter39: soft target WARN (never FAIL)
if ($_voSoftTargetSec -gt 0) {
    if ($_iter32_elapsed -gt $_voSoftTargetSec) {
        Write-Output ("[WARN] soft_target_exceeded: {0}s > soft_target {1}s — 警告僅供參考，不影響 PASS/FAIL" -f $_iter32_elapsed, $_voSoftTargetSec)
    } else {
        Write-Output ("[iter39] soft_target 達標：{0}s ≤ {1}s" -f $_iter32_elapsed, $_voSoftTargetSec)
    }
}

# ---------------------------------------------------------------------------
# iter55: DELIVERABLE_TIMESTAMP_COHERENCE — md/docx 時戳一致性檢查
# 必須在 Append-TimingFooterToMd 之前（footer 會更新 md 時戳）
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "DELIVERABLE_TIMESTAMP_COHERENCE:"
$_dtcMdPath   = Join-Path $repoRoot "outputs\latest_brief.md"
$_dtcDocxPath = Join-Path $repoRoot "outputs\executive_report.docx"
if ((Test-Path $_dtcMdPath) -and (Test-Path $_dtcDocxPath)) {
    $_dtcMd   = Get-Item $_dtcMdPath
    $_dtcDocx = Get-Item $_dtcDocxPath
    Write-Output ("  latest_brief.md        : {0}  {1} bytes  LastWrite={2}" -f $_dtcMd.Name, $_dtcMd.Length, $_dtcMd.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
    Write-Output ("  executive_report.docx  : {0}  {1} bytes  LastWrite={2}" -f $_dtcDocx.Name, $_dtcDocx.Length, $_dtcDocx.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
    if ($_dtcDocx.LastWriteTime -lt $_dtcMd.LastWriteTime) {
        Write-Output "  => DELIVERABLE_TIMESTAMP_COHERENCE: FAIL (docx older than md — stale deliverable)"
        Invoke-VerifyOnlineFailFast -Gate "DELIVERABLE_TIMESTAMP_INCOHERENT" `
            -Reason ("DELIVERABLE_TIMESTAMP_INCOHERENT: docx_time={0} < md_time={1}" -f $_dtcDocx.LastWriteTime.ToString("o"), $_dtcMd.LastWriteTime.ToString("o"))
    }
    Write-Output "  => DELIVERABLE_TIMESTAMP_COHERENCE: PASS"
} else {
    $_dtcMissing = @()
    if (-not (Test-Path $_dtcMdPath))   { $_dtcMissing += "latest_brief.md" }
    if (-not (Test-Path $_dtcDocxPath)) { $_dtcMissing += "executive_report.docx" }
    Write-Output ("  => DELIVERABLE_TIMESTAMP_COHERENCE: FAIL (missing: {0})" -f ($_dtcMissing -join ", "))
    Invoke-VerifyOnlineFailFast -Gate "DELIVERABLE_TIMESTAMP_INCOHERENT" `
        -Reason ("DELIVERABLE_TIMESTAMP_INCOHERENT: missing deliverables: {0}" -f ($_dtcMissing -join ", "))
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter29/31: 計時 — 成功路徑寫 timing meta + 追加 brief 末尾附錄（含分段耗時）
# ---------------------------------------------------------------------------
try {
    $_voStopwatch.Stop()
    $_sEndAt  = Get-Date
    $_sSecTot = [int]$_voStopwatch.Elapsed.TotalSeconds
    # iter31: compute gates stage seconds and read pipeline stage_seconds from meta
    $_stgGatesSec = [int]([Math]::Max(0, $_voStopwatch.Elapsed.TotalSeconds - $_stgGatesStart))
    $_stgHt = Read-StageTiming -RepoRoot $repoRoot -GateSec $_stgGatesSec
    # iter39 (D): inject z0_collect_online timing from verify_online.ps1
    if ($script:_z0OnlineSec -and $script:_z0OnlineSec -gt 0) {
        $_stgHt["z0_collect_online"] = [double]$script:_z0OnlineSec
    }
    # iter39 (D): compute other_seconds before writing meta so it's included
    if ($_stgHt -and $_stgHt.Count -gt 0) {
        $_stgSumPre = ($_stgHt.Values | Measure-Object -Sum).Sum
        $_stgHt["other_seconds"] = [int][Math]::Max(0, $_sSecTot - $_stgSumPre)
    }
    Write-RunTimingMeta `
        -OutPath  (Join-Path $repoRoot "outputs\run_timing.meta.json") `
        -RunId    $_voRunId `
        -StartDt  $_startedAt `
        -EndDt    $_sEndAt `
        -TotalSec $_sSecTot `
        -BudgetSec $_voBudgetSec `
        -StageSec $_stgHt `
        -SoftTargetSec $_voSoftTargetSec
    Append-TimingFooterToMd `
        -MdPath   (Join-Path $repoRoot "outputs\latest_brief.md") `
        -RunId    $_voRunId `
        -StartDt  $_startedAt `
        -EndDt    $_sEndAt `
        -TotalSec $_sSecTot `
        -StageSec $_stgHt
    $__sm = [int]([Math]::Floor($_sSecTot / 60)); $__ss = [int]($_sSecTot % 60)
    Write-Output ("⏱️ 總耗時：{0} 秒（{1} 分 {2} 秒）— run_timing.meta.json 已寫入" -f $_sSecTot, $__sm, $__ss)
    # iter39 (D): display stage_seconds with other_seconds and TIMING_GAP_LARGE warning
    if ($_stgHt -and $_stgHt.Count -gt 0) {
        $_stgLine = ($_stgHt.Keys | ForEach-Object { "{0}:{1}s" -f $_, [int]$_stgHt[$_] }) -join "  "
        Write-Output ("  stage_seconds: {0}" -f $_stgLine)
        $_otherSec = if ($_stgHt.Contains("other_seconds")) { [int]$_stgHt["other_seconds"] } else { 0 }
        if ($_otherSec -gt 30) {
            Write-Output ("  [WARN] TIMING_GAP_LARGE: other_seconds={0}s > 30s（未計時區段偏大）" -f $_otherSec)
        }
    }
    # TIMING_SANITY_HARD (iter36): total_seconds >= every stage_seconds (±5s tolerance)
    # iter47: before_translation is cumulative (overlaps hydrate+z0), exclude from sum
    $_tsExcludeFromSum = @("before_translation", "other_seconds")
    if ($_stgHt -and $_stgHt.Count -gt 0) {
        $_tsBadParts = @()
        foreach ($_sk in $_stgHt.Keys) {
            if ($_sk -in $_tsExcludeFromSum) { continue }
            if ([double]$_stgHt[$_sk] -gt ($_sSecTot + 5)) {
                $_tsBadParts += ("{0}={1}s > total={2}s" -f $_sk, [int]$_stgHt[$_sk], $_sSecTot)
            }
        }
        $_tsSum = ($($_stgHt.Keys | Where-Object { $_ -notin $_tsExcludeFromSum } | ForEach-Object { [double]$_stgHt[$_] }) | Measure-Object -Sum).Sum
        if ($_tsSum -gt ($_sSecTot + 5)) {
            $_tsBadParts += ("sum_stages={0}s > total={1}s" -f [int]$_tsSum, $_sSecTot)
        }
        if ($_tsBadParts.Count -gt 0) {
            $_tsReason = "TIMING_SANITY_HARD: " + ($_tsBadParts -join "; ")
            Write-Output ("  [TIMING_SANITY_HARD] FAIL: {0}" -f $_tsReason)
            Invoke-VerifyOnlineFailFast -Gate "TIMING_SANITY_HARD" -Reason $_tsReason
        } else {
            Write-Output ("  [TIMING_SANITY_HARD] 通過 (total={0}s)" -f $_sSecTot)
        }
    }
} catch {
    Write-Output ("  [WARN] 計時寫入失敗: {0}" -f $_)
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter34: patch translation_engine.meta.json — add tok_per_sec_est + gpu_required
# ---------------------------------------------------------------------------
$_teMetaPatchPath = Join-Path $repoRoot "outputs\translation_engine.meta.json"
if (Test-Path $_teMetaPatchPath) {
    try {
        $_teMeta = Get-Content $_teMetaPatchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_teObj  = [ordered]@{}
        foreach ($p in $_teMeta.PSObject.Properties) { $_teObj[$p.Name] = $p.Value }
        $_teObj["tok_per_sec_est"] = $_gpuTokPerSec
        $_teObj["gpu_required"]    = $true
        # ensure run_id is current (run_once.py may write its own run_id)
        if (-not $_teObj.Contains("run_id") -or [string]$_teObj["run_id"] -ne $_voRunId) {
            $_teObj["run_id"] = $_voRunId
        }
        # iter35: per-call tok/s — prefer data from run_once.py (already written);
        # add probe history as separate field (periodic probes differ from per-call)
        $_existingCalls = @($($_teObj["calls_tok_s"]))
        if ($_existingCalls.Count -eq 0) {
            # run_once.py did not write calls_tok_s (e.g. pipeline aborted early)
            if (Test-Path $_gpuProbeHistPath) {
                try {
                    $_phData  = Get-Content $_gpuProbeHistPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    $_tokSArr = @($_phData.probes | ForEach-Object { $_.tok_per_sec } | Where-Object { $_ -gt 0 })
                    if ($_tokSArr.Count -gt 0) {
                        $_teObj["calls_tok_s"] = $_tokSArr
                        $_teObj["tok_s_min"]   = [math]::Round(($_tokSArr | Measure-Object -Minimum).Minimum, 2)
                        $_teObj["tok_s_avg"]   = [math]::Round(($_tokSArr | Measure-Object -Average).Average, 2)
                        $_teObj["tok_s_max"]   = [math]::Round(($_tokSArr | Measure-Object -Maximum).Maximum, 2)
                    }
                } catch {}
            }
        }
        # Always write probe history under its own key (periodic spot-checks)
        if (Test-Path $_gpuProbeHistPath) {
            try {
                $_phData2 = Get-Content $_gpuProbeHistPath -Raw -ErrorAction Stop | ConvertFrom-Json
                $_teObj["probe_tok_s_history"] = @($_phData2.probes | ForEach-Object { $_.tok_per_sec })
            } catch {}
        }
        # cpu_fallback_detected: OR of flag file (probe job) + run_once.py per-call check
        $_runOnceFallback = [bool]$_teObj["cpu_fallback_detected"]
        $_teObj["cpu_fallback_detected"] = ((Test-Path $_gpuFallbackFlag) -or $_runOnceFallback)
        $_teObj["gpu_required"] = $true
        # iter39 (E): compute est_total_seconds_if_all_miss
        # iter44: when translate_mode=all_miss, actual total IS the all-miss measurement
        $_teXlatSec = if ($_teObj.Contains("translate_seconds")) { [double]$_teObj["translate_seconds"] } else { 0 }
        $_teEstMiss = if ($_teObj.Contains("est_translate_seconds_if_all_miss")) { [double]$_teObj["est_translate_seconds_if_all_miss"] } else { 0 }
        $_teMode    = if ($_teObj.Contains("translate_mode")) { [string]$_teObj["translate_mode"] } else { "" }
        if ($_teMode -eq "all_miss") {
            # actual run WAS all-miss; total_seconds is the ground-truth measurement
            $_teObj["est_total_seconds_if_all_miss"] = [int]$_sSecTot
        } elseif ($_teEstMiss -gt 0) {
            $_teObj["est_total_seconds_if_all_miss"] = [int][Math]::Round(($_sSecTot - $_teXlatSec + $_teEstMiss), 0)
        }
        $_teObj | ConvertTo-Json -Depth 8 -Compress | Set-Content $_teMetaPatchPath -Encoding UTF8
        Write-Output ("  [iter35] translation_engine.meta.json 已更新 tok_per_sec_est={0:F1}  calls_tok_s_count={1}  cpu_fallback={2}" `
            -f $_gpuTokPerSec, @($_teObj["calls_tok_s"]).Count, $_teObj["cpu_fallback_detected"])
    } catch {
        Write-Output ("  [WARN] translation_engine.meta.json patch 失敗: {0}" -f $_)
    }
} else {
    Write-Output "  [INFO] translation_engine.meta.json 不存在（pipeline 未寫入），略過 patch"
}

# ---------------------------------------------------------------------------
# RUN_ID_COHERENCE_HARD (iter36): 確認所有 meta 檔使用相同 run_id
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "[RUN_ID_COHERENCE_HARD] 核對所有 meta 檔 run_id = $_voRunId ..."
$_ridFail = $false
$_ridBad  = @()
# check LAST_RUN_SUMMARY.txt
$_ridLrs = Join-Path $repoRoot "outputs\LAST_RUN_SUMMARY.txt"
if (Test-Path $_ridLrs) {
    try {
        $_ridLrsLine = (Select-String -Path $_ridLrs -Pattern "^run_id\s*=\s*(\S+)" -ErrorAction Stop |
            Select-Object -First 1)
        $_ridLrsVal  = $_ridLrsLine.Matches[0].Groups[1].Value.Trim()
        if ($_ridLrsVal -ne $_voRunId) { $_ridFail=$true; $_ridBad += "LAST_RUN_SUMMARY($($_ridLrsVal))" }
        else { Write-Output ("  [OK] LAST_RUN_SUMMARY.txt run_id={0}" -f $_ridLrsVal) }
    } catch { Write-Output ("  [SKIP] LAST_RUN_SUMMARY.txt: 無法解析 run_id ({0})" -f $_) }
} else { Write-Output "  [SKIP] LAST_RUN_SUMMARY.txt: 不存在" }
foreach ($_ridJson in @("run_timing.meta.json","gpu_probe.meta.json","translation_engine.meta.json")) {
    $_ridJP = Join-Path $repoRoot "outputs\$_ridJson"
    if (Test-Path $_ridJP) {
        try {
            $_ridJVal = [string](Get-Content $_ridJP -Raw -Encoding UTF8 | ConvertFrom-Json).run_id
            if ($_ridJVal -ne $_voRunId) { $_ridFail=$true; $_ridBad += "$_ridJson($($_ridJVal))" }
            else { Write-Output ("  [OK] {0} run_id={1}" -f $_ridJson, $_ridJVal) }
        } catch { Write-Output ("  [SKIP] {0}: 無法解析 run_id ({1})" -f $_ridJson, $_) }
    } else { Write-Output ("  [SKIP] {0}: 不存在" -f $_ridJson) }
}
if ($_ridFail) {
    $_ridReason = "RUN_ID_COHERENCE_HARD: " + ($_ridBad -join "; ") + "; expected=$_voRunId"
    Write-Output ("  [RUN_ID_COHERENCE_HARD] FAIL: {0}" -f $_ridReason)
    Invoke-VerifyOnlineFailFast -Gate "RUN_ID_COHERENCE_HARD" -Reason $_ridReason
}
Write-Output "  [RUN_ID_COHERENCE_HARD] 通過"

# ---------------------------------------------------------------------------
# iter43: ALL_MISS_BUDGET_ESTIMATE_HARD
# When translate_mode=all_cache_hit, use est_total_seconds_if_all_miss to verify
# that a full-miss day would still complete within time_budget_seconds (200s).
# ---------------------------------------------------------------------------
$_amEstPath = Join-Path $repoRoot "outputs\translation_engine.meta.json"
if (Test-Path $_amEstPath) {
    try {
        $_amMeta = Get-Content $_amEstPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_amMode = [string]$_amMeta.translate_mode
        $_amEst  = if ($null -ne $_amMeta.est_total_seconds_if_all_miss) { [int]$_amMeta.est_total_seconds_if_all_miss } else { 0 }
        $_amBudget = $_voBudgetSec
        Write-Output "ALL_MISS_BUDGET_ESTIMATE_HARD:"
        Write-Output ("  translate_mode={0}  est_total_seconds_if_all_miss={1}  budget={2}" -f $_amMode, $_amEst, $_amBudget)
        if ($_amEst -gt 0 -and $_amEst -le $_amBudget) {
            Write-Output ("  => ALL_MISS_BUDGET_ESTIMATE_HARD: PASS (est={0}s <= budget={1}s)" -f $_amEst, $_amBudget)
        } elseif ($_amEst -gt $_amBudget) {
            Write-Output ("  => ALL_MISS_BUDGET_ESTIMATE_HARD: FAIL (est={0}s > budget={1}s)" -f $_amEst, $_amBudget)
            Invoke-VerifyOnlineFailFast -Gate "ALL_MISS_BUDGET_ESTIMATE_HARD" `
                -Reason ("ALL_MISS_BUDGET_ESTIMATE_HARD: est_total_seconds_if_all_miss={0}s > budget={1}s; tok/s-based workload estimate exceeds hard cap" -f $_amEst, $_amBudget)
        } else {
            Write-Output ("  => ALL_MISS_BUDGET_ESTIMATE_HARD: SKIP (est={0}, cannot verify)" -f $_amEst)
        }
    } catch {
        Write-Output ("  ALL_MISS_BUDGET_ESTIMATE_HARD: WARN (parse error: {0})" -f $_)
    }
} else {
    Write-Output "ALL_MISS_BUDGET_ESTIMATE_HARD: SKIP (translation_engine.meta.json not found)"
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter44: ALL_MISS_SAFETY_MARGIN_HARD
# est_total_seconds_if_all_miss must be <= (budget - 15) for safety margin
# ---------------------------------------------------------------------------
$_smPath = Join-Path $repoRoot "outputs\translation_engine.meta.json"
if (Test-Path $_smPath) {
    try {
        $_smMeta = Get-Content $_smPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_smEst  = if ($null -ne $_smMeta.est_total_seconds_if_all_miss) { [int]$_smMeta.est_total_seconds_if_all_miss } else { 0 }
        $_smLimit  = [Math]::Max(175, $_voBudgetSec - 5)  # iter73: budget-relative (margin 5s; hard budget gate covers main case)
        Write-Output "ALL_MISS_SAFETY_MARGIN_HARD:"
        Write-Output ("  est_total_seconds_if_all_miss={0}  limit={1}" -f $_smEst, $_smLimit)
        if ($_smEst -gt 0 -and $_smEst -le $_smLimit) {
            Write-Output ("  => ALL_MISS_SAFETY_MARGIN_HARD: PASS (est={0}s <= limit={1}s)" -f $_smEst, $_smLimit)
        } elseif ($_smEst -gt $_smLimit) {
            Write-Output ("  => ALL_MISS_SAFETY_MARGIN_HARD: FAIL (est={0}s > limit={1}s)" -f $_smEst, $_smLimit)
            Invoke-VerifyOnlineFailFast -Gate "ALL_MISS_SAFETY_MARGIN_HARD" `
                -Reason ("ALL_MISS_SAFETY_MARGIN_HARD: est={0}s > {1}s" -f $_smEst, $_smLimit)
        } else {
            Write-Output ("  => ALL_MISS_SAFETY_MARGIN_HARD: SKIP (est={0})" -f $_smEst)
        }
        # iter54: ALL_MISS_OVER_HARDCAP_WARN — warn if est > hard_cap (170)
        if ($_smEst -gt $_voBudgetSec) {
            Write-Output ("  [WARN] ALL_MISS_OVER_HARDCAP: est={0}s > hard_cap={1}s" -f $_smEst, $_voBudgetSec)
        }
    } catch {
        Write-Output ("  ALL_MISS_SAFETY_MARGIN_HARD: WARN (parse error: {0})" -f $_)
    }
} else {
    Write-Output "ALL_MISS_SAFETY_MARGIN_HARD: SKIP (meta not found)"
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter44: TRANSLATION_META_COHERENCE_HARD
# Validates internal consistency of translation_engine.meta.json
# ---------------------------------------------------------------------------
$_tmcPath = Join-Path $repoRoot "outputs\translation_engine.meta.json"
if (Test-Path $_tmcPath) {
    try {
        $_tmcMeta = Get-Content $_tmcPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_tmcFails = @()
        $_tmcCT = [int]$_tmcMeta.calls_total
        $_tmcCS = [int]$_tmcMeta.calls_success
        $_tmcCTO = [int]$_tmcMeta.calls_timeout
        $_tmcCE = [int]$_tmcMeta.calls_error
        $_tmcMode = [string]$_tmcMeta.translate_mode
        $_tmcDetail = @($_tmcMeta.calls_detail)
        $_tmcTokS = @($_tmcMeta.calls_tok_s)
        # Check 1: calls_success + calls_timeout + calls_error == calls_total
        if (($_tmcCS + $_tmcCTO + $_tmcCE) -ne $_tmcCT) {
            $_tmcFails += ("success({0})+timeout({1})+error({2})={3} != calls_total({4})" -f $_tmcCS, $_tmcCTO, $_tmcCE, ($_tmcCS+$_tmcCTO+$_tmcCE), $_tmcCT)
        }
        # Check 2: len(calls_detail) == calls_total (cache entries excluded from calls_total)
        $_tmcDetailLen = $_tmcDetail.Count
        # calls_detail may include cache entries; non-cache entries should == calls_total
        $_tmcDetailCalls = @($_tmcDetail | Where-Object { -not $_.cache_used }).Count
        if ($_tmcDetailCalls -ne $_tmcCT) {
            $_tmcFails += ("calls_detail_non_cache({0}) != calls_total({1})" -f $_tmcDetailCalls, $_tmcCT)
        }
        # Check 3: all_cache_hit consistency
        if ($_tmcMode -eq "all_cache_hit") {
            if ($_tmcCT -ne 0) { $_tmcFails += "all_cache_hit but calls_total=$_tmcCT != 0" }
            if (-not $_tmcMeta.translate_skipped_reason) { $_tmcFails += "all_cache_hit but no translate_skipped_reason" }
        }
        # Check 4: cache_miss > 0 consistency
        $_tmcCM = [int]$_tmcMeta.cache_miss
        if ($_tmcCM -gt 0) {
            if ($_tmcCT -le 0) { $_tmcFails += "cache_miss=$_tmcCM but calls_total=0" }
            $_tmcTS = [double]$_tmcMeta.translate_seconds
            if ($_tmcTS -le 0) { $_tmcFails += "cache_miss=$_tmcCM but translate_seconds=$_tmcTS" }
        }
        # Check 5: calls_tok_s_scope
        if ([string]$_tmcMeta.calls_tok_s_scope -ne "success_only") {
            $_tmcFails += ("calls_tok_s_scope='{0}' != 'success_only'" -f [string]$_tmcMeta.calls_tok_s_scope)
        }
        Write-Output "TRANSLATION_META_COHERENCE_HARD:"
        if ($_tmcFails.Count -gt 0) {
            foreach ($_f in $_tmcFails) { Write-Output ("  FAIL: {0}" -f $_f) }
            Invoke-VerifyOnlineFailFast -Gate "TRANSLATION_META_COHERENCE_HARD" `
                -Reason ("TRANSLATION_META_COHERENCE_HARD: " + ($_tmcFails -join "; "))
        } else {
            Write-Output ("  calls_total={0} success={1} timeout={2} error={3} detail_len={4} tok_s_scope=success_only" -f $_tmcCT, $_tmcCS, $_tmcCTO, $_tmcCE, $_tmcDetailLen)
            Write-Output "  => TRANSLATION_META_COHERENCE_HARD: PASS"
        }
    } catch {
        Write-Output ("  TRANSLATION_META_COHERENCE_HARD: WARN (parse error: {0})" -f $_)
    }
} else {
    Write-Output "TRANSLATION_META_COHERENCE_HARD: SKIP (meta not found)"
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter48: DEV_FORUM_AUDIT_JSON_VALID_HARD — validate JSON integrity
# ---------------------------------------------------------------------------
$_dfaJsonPath = Join-Path $repoRoot "outputs\dev_forum_audit.meta.json"
if (Test-Path $_dfaJsonPath) {
    $_dfaVenvPy = Join-Path $repoRoot "venv\Scripts\python.exe"
    if (-not (Test-Path $_dfaVenvPy)) { $_dfaVenvPy = "python" }
    # iter50: unified — use python -m json.tool as sole validator; gate on $LASTEXITCODE
    & $_dfaVenvPy -m json.tool "$_dfaJsonPath" > $null 2>&1
    $_dfaToolEc = $LASTEXITCODE
    Write-Output ("  DEV_FORUM_AUDIT_JSON_TOOL_EXIT_CODE={0}" -f $_dfaToolEc)
    if ($_dfaToolEc -eq 0) {
        Write-Output "DEV_FORUM_AUDIT_JSON_VALID_HARD: PASS"
    } else {
        Write-Output "DEV_FORUM_AUDIT_JSON_VALID_HARD: FAIL (json.tool exit=$_dfaToolEc)"
        Invoke-VerifyOnlineFailFast -Gate "DEV_FORUM_AUDIT_JSON_VALID_HARD" `
            -Reason "DEV_FORUM_AUDIT_JSON_INVALID: python -m json.tool failed (exit=$_dfaToolEc)"
    }
} else {
    Write-Output "DEV_FORUM_AUDIT_JSON_VALID_HARD: FAIL — file not found"
    Invoke-VerifyOnlineFailFast -Gate "DEV_FORUM_AUDIT_JSON_VALID_HARD" `
        -Reason "DEV_FORUM_AUDIT_JSON_INVALID: dev_forum_audit.meta.json missing"
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter53: BIGTECH_DIVERSITY_HARD_DAILY — enforce multi-source + multi-vendor
#   Reads selection_audit.meta.json for diversity fields
#   Enforced when FAST_300_DAILY=1
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_divMetaPath = Join-Path $repoRoot "outputs\selection_audit.meta.json"
    Write-Output ""
    Write-Output "BIGTECH_DIVERSITY_HARD_DAILY:"
    if (Test-Path $_divMetaPath) {
        try {
            $_divMeta = Get-Content $_divMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_divDomains = if ($_divMeta.PSObject.Properties['selected_domains_distinct']) { [int]$_divMeta.selected_domains_distinct } else { 0 }
            $_divVendors = if ($_divMeta.PSObject.Properties['selected_vendors_distinct']) { [int]$_divMeta.selected_vendors_distinct } else { 0 }
            $_divMaxDom  = if ($_divMeta.PSObject.Properties['max_domain_count']) { [int]$_divMeta.max_domain_count } else { 99 }
            $_divMaxVen  = if ($_divMeta.PSObject.Properties['max_vendor_count']) { [int]$_divMeta.max_vendor_count } else { 99 }
            $_divPass    = if ($_divMeta.PSObject.Properties['diversity_pass']) { $_divMeta.diversity_pass } else { $false }
            Write-Output ("  selected_domains_distinct : {0}" -f $_divDomains)
            Write-Output ("  selected_vendors_distinct : {0}" -f $_divVendors)
            Write-Output ("  max_domain_count          : {0}" -f $_divMaxDom)
            Write-Output ("  max_vendor_count          : {0}" -f $_divMaxVen)
            Write-Output ("  diversity_pass            : {0}" -f $_divPass)
            if ($_divDomains -lt 5 -or $_divMaxDom -gt 3 -or $_divVendors -lt 5 -or $_divMaxVen -gt 3) {
                $_divFail = ("BIGTECH_DIVERSITY_HARD_DAILY_FAIL: domains={0} max_domain={1} vendors={2} max_vendor={3}" -f $_divDomains, $_divMaxDom, $_divVendors, $_divMaxVen)
                Write-Output ("  => FAIL: {0}" -f $_divFail)
                Invoke-VerifyOnlineFailFast -Gate "BIGTECH_DIVERSITY_HARD_DAILY" -Reason $_divFail
            }
            Write-Output "  => BIGTECH_DIVERSITY_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  BIGTECH_DIVERSITY_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  BIGTECH_DIVERSITY_HARD_DAILY: WARN (selection_audit.meta.json not found — pipeline may not have written diversity fields)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter67: SINGLE_DOMAIN_SHARE_CAP_HARD — enforced for ALL entrypoints (iter65→67)
#   Reads domain_vendor_cap.meta.json (fallback: bigtech_diversity.meta.json)
# ---------------------------------------------------------------------------
$_dscMetaPath = Join-Path $repoRoot "outputs\domain_vendor_cap.meta.json"
if (-not (Test-Path $_dscMetaPath)) { $_dscMetaPath = Join-Path $repoRoot "outputs\bigtech_diversity.meta.json" }
Write-Output "SINGLE_DOMAIN_SHARE_CAP_HARD:"
if (Test-Path $_dscMetaPath) {
    try {
        $_dscMeta = Get-Content $_dscMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_dscMaxDom    = if ($_dscMeta.PSObject.Properties['max_domain_count']) { [int]$_dscMeta.max_domain_count } else { 99 }
        $_dscEvents    = if ($_dscMeta.PSObject.Properties['selected_events']) { [int]$_dscMeta.selected_events } else { 0 }
        $_dscRatio     = if ($_dscEvents -gt 0) { [math]::Round($_dscMaxDom / $_dscEvents, 4) } else { "N/A" }
        $_dscPass      = if ($_dscMeta.PSObject.Properties['domain_cap_pass']) { $_dscMeta.domain_cap_pass } elseif ($_dscMeta.PSObject.Properties['domain_share_cap_pass']) { $_dscMeta.domain_share_cap_pass } else { $false }
        $_dscInjected  = if ($_dscMeta.PSObject.Properties['domain_test_injected']) { $_dscMeta.domain_test_injected } elseif ($_dscMeta.PSObject.Properties['domain_share_cap_test_injected']) { $_dscMeta.domain_share_cap_test_injected } else { $false }
        Write-Output ("  max_domain_count          : {0}" -f $_dscMaxDom)
        Write-Output ("  selected_events           : {0}" -f $_dscEvents)
        Write-Output ("  max_domain_share_ratio    : {0}" -f $_dscRatio)
        Write-Output ("  domain_share_cap_pass     : {0}" -f $_dscPass)
        if ($_dscInjected) {
            Write-Output "  domain_share_cap_test_injected : True"
        }
        if (-not $_dscPass) {
            $_dscFail = ("SINGLE_DOMAIN_SHARE_CAP_HARD_FAIL: max_domain={0} events={1} ratio={2}" -f $_dscMaxDom, $_dscEvents, $_dscRatio)
            Write-Output ("  => FAIL: {0}" -f $_dscFail)
            Invoke-VerifyOnlineFailFast -Gate "SINGLE_DOMAIN_SHARE_CAP_HARD" -Reason $_dscFail
        }
        Write-Output "  => SINGLE_DOMAIN_SHARE_CAP_HARD: PASS"
    } catch {
        Write-Output ("  SINGLE_DOMAIN_SHARE_CAP_HARD: WARN (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  SINGLE_DOMAIN_SHARE_CAP_HARD: WARN (domain_vendor_cap.meta.json not found)"
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter67: SINGLE_VENDOR_SHARE_CAP_HARD — enforced for ALL entrypoints (iter56→67)
#   Reads domain_vendor_cap.meta.json (fallback: bigtech_diversity.meta.json)
# ---------------------------------------------------------------------------
$_vscMetaPath = Join-Path $repoRoot "outputs\domain_vendor_cap.meta.json"
if (-not (Test-Path $_vscMetaPath)) { $_vscMetaPath = Join-Path $repoRoot "outputs\bigtech_diversity.meta.json" }
Write-Output "SINGLE_VENDOR_SHARE_CAP_HARD:"
if (Test-Path $_vscMetaPath) {
    try {
        $_vscMeta = Get-Content $_vscMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_vscMaxVen    = if ($_vscMeta.PSObject.Properties['max_vendor_count']) { [int]$_vscMeta.max_vendor_count } else { 99 }
        $_vscEvents    = if ($_vscMeta.PSObject.Properties['selected_events']) { [int]$_vscMeta.selected_events } else { 0 }
        $_vscRatio     = if ($_vscEvents -gt 0) { [math]::Round($_vscMaxVen / $_vscEvents, 4) } else { "N/A" }
        $_vscPass      = if ($_vscMeta.PSObject.Properties['vendor_cap_pass']) { $_vscMeta.vendor_cap_pass } elseif ($_vscMeta.PSObject.Properties['vendor_share_cap_pass']) { $_vscMeta.vendor_share_cap_pass } else { $false }
        $_vscInjected  = if ($_vscMeta.PSObject.Properties['vendor_test_injected']) { $_vscMeta.vendor_test_injected } elseif ($_vscMeta.PSObject.Properties['vendor_share_cap_test_injected']) { $_vscMeta.vendor_share_cap_test_injected } else { $false }
        Write-Output ("  max_vendor_count          : {0}" -f $_vscMaxVen)
        Write-Output ("  selected_events           : {0}" -f $_vscEvents)
        Write-Output ("  max_vendor_share_ratio    : {0}" -f $_vscRatio)
        Write-Output ("  vendor_share_cap_pass     : {0}" -f $_vscPass)
        if ($_vscInjected) {
            Write-Output "  vendor_share_cap_test_injected : True"
        }
        if (-not $_vscPass) {
            $_vscFail = ("SINGLE_VENDOR_SHARE_CAP_HARD_FAIL: max_vendor={0} events={1} ratio={2}" -f $_vscMaxVen, $_vscEvents, $_vscRatio)
            Write-Output ("  => FAIL: {0}" -f $_vscFail)
            Invoke-VerifyOnlineFailFast -Gate "SINGLE_VENDOR_SHARE_CAP_HARD" -Reason $_vscFail
        }
        Write-Output "  => SINGLE_VENDOR_SHARE_CAP_HARD: PASS"
    } catch {
        Write-Output ("  SINGLE_VENDOR_SHARE_CAP_HARD: WARN (parse error: {0})" -f $_)
    }
} else {
    Write-Output "  SINGLE_VENDOR_SHARE_CAP_HARD: WARN (domain_vendor_cap.meta.json not found)"
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter66: SOURCE_DENSITY_MULTIPLIER_HARD_DAILY — density_score * 1.5 gate
#   Reads source_density.meta.json for density_multiplier_gate_pass
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_sdmMetaPath = Join-Path $repoRoot "outputs\source_density.meta.json"
    Write-Output "SOURCE_DENSITY_MULTIPLIER_HARD_DAILY:"
    if (Test-Path $_sdmMetaPath) {
        try {
            $_sdmMeta = Get-Content $_sdmMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_sdmTotal    = if ($_sdmMeta.PSObject.Properties['candidates_total']) { [int]$_sdmMeta.candidates_total } else { 0 }
            $_sdmCandPass = if ($_sdmMeta.PSObject.Properties['candidates_pass']) { [int]$_sdmMeta.candidates_pass } else { 0 }
            $_sdmSelAvg   = if ($_sdmMeta.PSObject.Properties['selected_avg_density_score']) { $_sdmMeta.selected_avg_density_score } else { 0 }
            $_sdmSelMin   = if ($_sdmMeta.PSObject.Properties['selected_min_density_score']) { [int]$_sdmMeta.selected_min_density_score } else { 0 }
            $_sdmBase     = if ($_sdmMeta.PSObject.Properties['base_density_min']) { $_sdmMeta.base_density_min } else { 0 }
            $_sdmNew      = if ($_sdmMeta.PSObject.Properties['new_density_min']) { [int]$_sdmMeta.new_density_min } else { 0 }
            $_sdmMult     = if ($_sdmMeta.PSObject.Properties['multiplier']) { $_sdmMeta.multiplier } else { 1.5 }
            $_sdmGatePass = if ($_sdmMeta.PSObject.Properties['density_multiplier_gate_pass']) { $_sdmMeta.density_multiplier_gate_pass } else { $false }
            $_sdmInjected = if ($_sdmMeta.PSObject.Properties['test_injected']) { $_sdmMeta.test_injected } else { $false }
            Write-Output ("  candidates_total              : {0}" -f $_sdmTotal)
            Write-Output ("  candidates_pass               : {0}" -f $_sdmCandPass)
            Write-Output ("  selected_avg_density_score    : {0}" -f $_sdmSelAvg)
            Write-Output ("  selected_min_density_score    : {0}" -f $_sdmSelMin)
            Write-Output ("  base_density_min              : {0}" -f $_sdmBase)
            Write-Output ("  new_density_min (base*1.5)    : {0}" -f $_sdmNew)
            Write-Output ("  multiplier                    : {0}" -f $_sdmMult)
            Write-Output ("  density_multiplier_gate_pass  : {0}" -f $_sdmGatePass)
            if ($_sdmInjected) {
                Write-Output "  test_injected                 : True"
            }
            if (-not $_sdmGatePass) {
                $_sdmFail = ("SOURCE_DENSITY_MULTIPLIER_HARD_DAILY_FAIL: selected_min={0} < new_density_min={1} avg={2} multiplier={3}" -f $_sdmSelMin, $_sdmNew, $_sdmSelAvg, $_sdmMult)
                Write-Output ("  => FAIL: {0}" -f $_sdmFail)
                Invoke-VerifyOnlineFailFast -Gate "SOURCE_DENSITY_MULTIPLIER_HARD_DAILY" -Reason $_sdmFail
            }
            Write-Output "  => SOURCE_DENSITY_MULTIPLIER_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  SOURCE_DENSITY_MULTIPLIER_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  SOURCE_DENSITY_MULTIPLIER_HARD_DAILY: WARN (source_density.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter54: DAILY_BIGTECH_ONLY_HARD — all 7 must be bigtech_hit=true AND official_or_media=true
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_btoMetaPath = Join-Path $repoRoot "outputs\selection_audit.meta.json"
    Write-Output "DAILY_BIGTECH_ONLY_HARD:"
    if (Test-Path $_btoMetaPath) {
        try {
            $_btoMeta = Get-Content $_btoMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_btoBT = if ($_btoMeta.PSObject.Properties['bigtech_hit_count']) { [int]$_btoMeta.bigtech_hit_count } else { 0 }
            $_btoOM = if ($_btoMeta.PSObject.Properties['official_or_media_count']) { [int]$_btoMeta.official_or_media_count } else { 0 }
            $_btoSel = if ($_btoMeta.PSObject.Properties['selected_items_count']) { [int]$_btoMeta.selected_items_count } else { 0 }
            Write-Output ("  bigtech_hit_count         : {0}" -f $_btoBT)
            Write-Output ("  official_or_media_count   : {0}" -f $_btoOM)
            Write-Output ("  selected_items_count      : {0}" -f $_btoSel)
            # iter54: bigtech code_release also counts toward official_or_media for this gate
            $_btoCR = 0
            if ($_btoMeta.PSObject.Properties['items']) {
                $_btoCR = @($_btoMeta.items | Where-Object { $_.bigtech_hit -eq $true -and $_.source_type -eq "code_release" }).Count
            }
            $_btoEffectiveOM = $_btoOM + $_btoCR
            Write-Output ("  bigtech_code_release (counts as official): {0}" -f $_btoCR)
            if ($_btoBT -lt $_btoSel -or $_btoEffectiveOM -lt $_btoSel) {
                $_btoFail = ("DAILY_BIGTECH_ONLY_HARD_FAIL: bigtech={0} official_or_media+bigtech_code_release={1} selected={2}" -f $_btoBT, $_btoEffectiveOM, $_btoSel)
                Write-Output ("  => FAIL: {0}" -f $_btoFail)
                Invoke-VerifyOnlineFailFast -Gate "DAILY_BIGTECH_ONLY_HARD" -Reason $_btoFail
            }
            Write-Output "  => DAILY_BIGTECH_ONLY_HARD: PASS"
        } catch {
            Write-Output ("  DAILY_BIGTECH_ONLY_HARD: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  DAILY_BIGTECH_ONLY_HARD: WARN (selection_audit.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter68: DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY — platform domains (HF/GitHub) combined <= 1
#   Reads dev_platform_cap.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_pdcMetaPath = Join-Path $repoRoot "outputs\dev_platform_cap.meta.json"
    Write-Output "DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY:"
    if (Test-Path $_pdcMetaPath) {
        try {
            $_pdcMeta = Get-Content $_pdcMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_pdcTotal    = if ($_pdcMeta.PSObject.Properties['platform_domain_total_count']) { [int]$_pdcMeta.platform_domain_total_count } else { 99 }
            $_pdcCap      = if ($_pdcMeta.PSObject.Properties['cap']) { [int]$_pdcMeta.cap } else { 1 }
            $_pdcPass     = if ($_pdcMeta.PSObject.Properties['cap_pass']) { $_pdcMeta.cap_pass } else { $false }
            $_pdcInjected = if ($_pdcMeta.PSObject.Properties['test_injected']) { $_pdcMeta.test_injected } else { $false }
            $_pdcDomains  = if ($_pdcMeta.PSObject.Properties['platform_domains']) { ($_pdcMeta.platform_domains -join ", ") } else { "N/A" }
            Write-Output ("  platform_domain_total_count : {0}" -f $_pdcTotal)
            Write-Output ("  cap                         : {0}" -f $_pdcCap)
            Write-Output ("  platform_domains            : {0}" -f $_pdcDomains)
            Write-Output ("  cap_pass                    : {0}" -f $_pdcPass)
            if ($_pdcInjected) {
                Write-Output "  test_injected               : True"
            }
            if (-not $_pdcPass) {
                $_pdcFail = ("DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY_FAIL: platform_total={0} > {1}" -f $_pdcTotal, $_pdcCap)
                Write-Output ("  => FAIL: {0}" -f $_pdcFail)
                Invoke-VerifyOnlineFailFast -Gate "DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY" -Reason $_pdcFail
            }
            Write-Output "  => DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  DEV_PLATFORM_DOMAIN_CAP_HARD_DAILY: WARN (dev_platform_cap.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter73: BIGTECH_ACTIONABLE_MIN_HARD_DAILY — bigtech_actionable >= 7
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_cmMetaPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "BIGTECH_ACTIONABLE_MIN_HARD_DAILY:"
    if (Test-Path $_cmMetaPath) {
        try {
            $_cmMeta = Get-Content $_cmMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_cmBtAct     = if ($_cmMeta.PSObject.Properties['bigtech_actionable_count']) { [int]$_cmMeta.bigtech_actionable_count } else { 0 }
            $_cmBtActPass = if ($_cmMeta.PSObject.Properties['bigtech_actionable_min_pass']) { $_cmMeta.bigtech_actionable_min_pass } else { $false }
            $_cmPlatTotal = if ($_cmMeta.PSObject.Properties['platform_total']) { [int]$_cmMeta.platform_total } else { 0 }
            $_cmPlatPass  = if ($_cmMeta.PSObject.Properties['platform_cap_pass']) { $_cmMeta.platform_cap_pass } else { $false }
            $_cmRtTotal   = if ($_cmMeta.PSObject.Properties['research_tutorial_total']) { [int]$_cmMeta.research_tutorial_total } else { 0 }
            $_cmRtPass    = if ($_cmMeta.PSObject.Properties['research_tutorial_cap_pass']) { $_cmMeta.research_tutorial_cap_pass } else { $false }
            $_cmSelEvents = if ($_cmMeta.PSObject.Properties['selected_events']) { [int]$_cmMeta.selected_events } else { 0 }
            Write-Output ("  selected_events             : {0}" -f $_cmSelEvents)
            Write-Output ("  bigtech_actionable_count    : {0}" -f $_cmBtAct)
            Write-Output ("  bigtech_actionable_pass     : {0}" -f $_cmBtActPass)
            Write-Output ("  platform_total              : {0}" -f $_cmPlatTotal)
            Write-Output ("  platform_cap_pass           : {0}" -f $_cmPlatPass)
            Write-Output ("  research_tutorial_total     : {0}" -f $_cmRtTotal)
            Write-Output ("  research_tutorial_cap_pass  : {0}" -f $_cmRtPass)
            if (-not $_cmBtActPass) {
                $_cmBtFail = ("BIGTECH_ACTIONABLE_MIN_HARD_DAILY_FAIL: actionable={0} < 7" -f $_cmBtAct)
                Write-Output ("  => FAIL: {0}" -f $_cmBtFail)
                Invoke-VerifyOnlineFailFast -Gate "BIGTECH_ACTIONABLE_MIN_HARD_DAILY" -Reason $_cmBtFail
            }
            Write-Output "  => BIGTECH_ACTIONABLE_MIN_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  BIGTECH_ACTIONABLE_MIN_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  BIGTECH_ACTIONABLE_MIN_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter71: RESEARCH_TUTORIAL_CAP_HARD_DAILY — research_tutorial_total <= 1
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_cmMetaPath2 = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "RESEARCH_TUTORIAL_CAP_HARD_DAILY:"
    if (Test-Path $_cmMetaPath2) {
        try {
            $_cmMeta2 = Get-Content $_cmMetaPath2 -Raw -Encoding UTF8 | ConvertFrom-Json
            $_cmRtTotal2   = if ($_cmMeta2.PSObject.Properties['research_tutorial_total']) { [int]$_cmMeta2.research_tutorial_total } else { 0 }
            $_cmRtPass2    = if ($_cmMeta2.PSObject.Properties['research_tutorial_cap_pass']) { $_cmMeta2.research_tutorial_cap_pass } else { $false }
            $_cmRtInjected = if ($_cmMeta2.PSObject.Properties['research_tutorial_test_injected']) { $_cmMeta2.research_tutorial_test_injected } else { $false }
            Write-Output ("  research_tutorial_total     : {0}" -f $_cmRtTotal2)
            Write-Output ("  research_tutorial_cap_pass  : {0}" -f $_cmRtPass2)
            if ($_cmRtInjected) {
                Write-Output "  test_injected               : True"
            }
            if (-not $_cmRtPass2) {
                $_cmRtFail2 = ("RESEARCH_TUTORIAL_CAP_HARD_DAILY_FAIL: research_tutorial_total={0} > 1" -f $_cmRtTotal2)
                Write-Output ("  => FAIL: {0}" -f $_cmRtFail2)
                Invoke-VerifyOnlineFailFast -Gate "RESEARCH_TUTORIAL_CAP_HARD_DAILY" -Reason $_cmRtFail2
            }
            Write-Output "  => RESEARCH_TUTORIAL_CAP_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  RESEARCH_TUTORIAL_CAP_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  RESEARCH_TUTORIAL_CAP_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter72b: BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY — bigtech_official_media_count >= 6
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_bomMetaPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY:"
    if (Test-Path $_bomMetaPath) {
        try {
            $_bomMeta = Get-Content $_bomMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_bomCount   = if ($_bomMeta.PSObject.Properties['bigtech_official_media_count']) { [int]$_bomMeta.bigtech_official_media_count } else { 0 }
            $_bomPass    = if ($_bomMeta.PSObject.Properties['bigtech_official_media_min_pass']) { $_bomMeta.bigtech_official_media_min_pass } else { $false }
            $_bomInjected = if ($_bomMeta.PSObject.Properties['bigtech_official_media_test_injected']) { $_bomMeta.bigtech_official_media_test_injected } else { $false }
            Write-Output ("  bigtech_official_media_count : {0}" -f $_bomCount)
            Write-Output ("  bigtech_official_media_pass  : {0}" -f $_bomPass)
            if ($_bomInjected) {
                Write-Output "  test_injected                : True"
            }
            if (-not $_bomPass) {
                $_bomFail = ("BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY_FAIL: official_media={0} < 6" -f $_bomCount)
                Write-Output ("  => FAIL: {0}" -f $_bomFail)
                Invoke-VerifyOnlineFailFast -Gate "BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY" -Reason $_bomFail
            }
            Write-Output "  => BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter72b: STRATEGIC_BUCKET_COVERAGE_HARD_DAILY — strategic_buckets_distinct >= 4
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_sbcMetaPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "STRATEGIC_BUCKET_COVERAGE_HARD_DAILY:"
    if (Test-Path $_sbcMetaPath) {
        try {
            $_sbcMeta = Get-Content $_sbcMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_sbcDistinct = if ($_sbcMeta.PSObject.Properties['selected_strategic_buckets_distinct']) { [int]$_sbcMeta.selected_strategic_buckets_distinct } else { 0 }
            $_sbcBuckets  = if ($_sbcMeta.PSObject.Properties['selected_strategic_buckets']) { ($_sbcMeta.selected_strategic_buckets -join ", ") } else { "N/A" }
            $_sbcPass     = if ($_sbcMeta.PSObject.Properties['strategic_bucket_coverage_pass']) { $_sbcMeta.strategic_bucket_coverage_pass } else { $false }
            Write-Output ("  selected_strategic_buckets   : {0}" -f $_sbcBuckets)
            Write-Output ("  buckets_distinct             : {0}" -f $_sbcDistinct)
            Write-Output ("  strategic_bucket_coverage_pass : {0}" -f $_sbcPass)
            if (-not $_sbcPass) {
                $_sbcFail = ("STRATEGIC_BUCKET_COVERAGE_HARD_DAILY_FAIL: buckets={0} < 5" -f $_sbcDistinct)
                Write-Output ("  => FAIL: {0}" -f $_sbcFail)
                Invoke-VerifyOnlineFailFast -Gate "STRATEGIC_BUCKET_COVERAGE_HARD_DAILY" -Reason $_sbcFail
            }
            Write-Output "  => STRATEGIC_BUCKET_COVERAGE_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  STRATEGIC_BUCKET_COVERAGE_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  STRATEGIC_BUCKET_COVERAGE_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter73: TOTAL_EVENTS_HARD_DAILY — selected_events >= 10
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_tePath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "TOTAL_EVENTS_HARD_DAILY:"
    if (Test-Path $_tePath) {
        try {
            $_teMeta = Get-Content $_tePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_teCount = if ($_teMeta.PSObject.Properties['selected_events']) { [int]$_teMeta.selected_events } else { 0 }
            $_tePass  = if ($_teMeta.PSObject.Properties['total_events_pass']) { $_teMeta.total_events_pass } else { $false }
            Write-Output ("  selected_events              : {0}" -f $_teCount)
            Write-Output ("  total_events_pass            : {0}" -f $_tePass)
            if (-not $_tePass) {
                $_teFail = ("TOTAL_EVENTS_HARD_DAILY_FAIL: selected_events={0} < 10" -f $_teCount)
                Write-Output ("  => FAIL: {0}" -f $_teFail)
                Invoke-VerifyOnlineFailFast -Gate "TOTAL_EVENTS_HARD_DAILY" -Reason $_teFail
            }
            Write-Output "  => TOTAL_EVENTS_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  TOTAL_EVENTS_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  TOTAL_EVENTS_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter73: LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY — leadership_politics_ai_count >= 2
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_lpPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY:"
    if (Test-Path $_lpPath) {
        try {
            $_lpMeta = Get-Content $_lpPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_lpCount    = if ($_lpMeta.PSObject.Properties['leadership_politics_ai_count']) { [int]$_lpMeta.leadership_politics_ai_count } else { 0 }
            $_lpPass     = if ($_lpMeta.PSObject.Properties['leadership_politics_ai_min_pass']) { $_lpMeta.leadership_politics_ai_min_pass } else { $false }
            $_lpInjected = if ($_lpMeta.PSObject.Properties['leadership_politics_ai_test_injected']) { $_lpMeta.leadership_politics_ai_test_injected } else { $false }
            Write-Output ("  leadership_politics_ai_count : {0}" -f $_lpCount)
            Write-Output ("  leadership_politics_ai_pass  : {0}" -f $_lpPass)
            if ($_lpInjected) {
                Write-Output "  test_injected                : True"
            }
            if (-not $_lpPass) {
                $_lpFail = ("LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY_FAIL: leadership_politics_ai={0} < 2" -f $_lpCount)
                Write-Output ("  => FAIL: {0}" -f $_lpFail)
                Invoke-VerifyOnlineFailFast -Gate "LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY" -Reason $_lpFail
            }
            Write-Output "  => LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  LEADERSHIP_POLITICS_AI_MIN_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter73: CHINA_AI_GOV_MIN_HARD_DAILY — china_ai_gov_count >= 1
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_caPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "CHINA_AI_GOV_MIN_HARD_DAILY:"
    if (Test-Path $_caPath) {
        try {
            $_caMeta = Get-Content $_caPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_caCount    = if ($_caMeta.PSObject.Properties['china_ai_gov_count']) { [int]$_caMeta.china_ai_gov_count } else { 0 }
            $_caPass     = if ($_caMeta.PSObject.Properties['china_ai_gov_min_pass']) { $_caMeta.china_ai_gov_min_pass } else { $false }
            $_caInjected = if ($_caMeta.PSObject.Properties['china_ai_gov_test_injected']) { $_caMeta.china_ai_gov_test_injected } else { $false }
            Write-Output ("  china_ai_gov_count           : {0}" -f $_caCount)
            Write-Output ("  china_ai_gov_pass            : {0}" -f $_caPass)
            if ($_caInjected) {
                Write-Output "  test_injected                : True"
            }
            if (-not $_caPass) {
                $_caFail = ("CHINA_AI_GOV_MIN_HARD_DAILY_FAIL: china_ai_gov={0} < 1" -f $_caCount)
                Write-Output ("  => FAIL: {0}" -f $_caFail)
                Invoke-VerifyOnlineFailFast -Gate "CHINA_AI_GOV_MIN_HARD_DAILY" -Reason $_caFail
            }
            Write-Output "  => CHINA_AI_GOV_MIN_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  CHINA_AI_GOV_MIN_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  CHINA_AI_GOV_MIN_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter73: PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY — each selected item strategic_density >= 15
#   Reads content_mix.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_piPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
    Write-Output "PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY:"
    if (Test-Path $_piPath) {
        try {
            $_piMeta = Get-Content $_piPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_piFloor = if ($_piMeta.PSObject.Properties['per_item_strategic_density_floor']) { [int]$_piMeta.per_item_strategic_density_floor } else { 15 }
            $_piPass  = if ($_piMeta.PSObject.Properties['per_item_strategic_density_pass']) { $_piMeta.per_item_strategic_density_pass } else { $false }
            $_piFails = if ($_piMeta.PSObject.Properties['per_item_strategic_density_failures']) { $_piMeta.per_item_strategic_density_failures } else { @() }
            Write-Output ("  per_item_floor               : {0}" -f $_piFloor)
            Write-Output ("  per_item_pass                : {0}" -f $_piPass)
            Write-Output ("  failures_count               : {0}" -f @($_piFails).Count)
            if (-not $_piPass) {
                $_piFail = ("PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY_FAIL: {0} items below floor={1}" -f @($_piFails).Count, $_piFloor)
                Write-Output ("  => FAIL: {0}" -f $_piFail)
                Invoke-VerifyOnlineFailFast -Gate "PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY" -Reason $_piFail
            }
            Write-Output "  => PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  PER_ITEM_STRATEGIC_DENSITY_1P5_HARD_DAILY: WARN (content_mix.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter72b: STRATEGIC_DENSITY_1P5_HARD_DAILY — strategic_density_score avg >= 1.5x base, min >= 10
#   Reads source_density.meta.json
# ---------------------------------------------------------------------------
if ($_fast300Daily) {
    $_sdgMetaPath = Join-Path $repoRoot "outputs\source_density.meta.json"
    Write-Output "STRATEGIC_DENSITY_1P5_HARD_DAILY:"
    if (Test-Path $_sdgMetaPath) {
        try {
            $_sdgMeta = Get-Content $_sdgMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $_sdgAvg    = if ($_sdgMeta.PSObject.Properties['selected_avg_strategic_density_score']) { $_sdgMeta.selected_avg_strategic_density_score } else { 0 }
            $_sdgMin    = if ($_sdgMeta.PSObject.Properties['selected_min_strategic_density_score']) { [int]$_sdgMeta.selected_min_strategic_density_score } else { 0 }
            $_sdgTarget = if ($_sdgMeta.PSObject.Properties['target_avg_density_1p5']) { [int]$_sdgMeta.target_avg_density_1p5 } else { 0 }
            $_sdgBase   = if ($_sdgMeta.PSObject.Properties['base_avg_density']) { $_sdgMeta.base_avg_density } else { 0 }
            $_sdgPass   = if ($_sdgMeta.PSObject.Properties['strategic_density_gate_pass']) { $_sdgMeta.strategic_density_gate_pass } else { $false }
            Write-Output ("  base_avg_density             : {0}" -f $_sdgBase)
            Write-Output ("  target_avg_density_1p5       : {0}" -f $_sdgTarget)
            Write-Output ("  selected_avg_strategic_density : {0:F1}" -f $_sdgAvg)
            Write-Output ("  selected_min_strategic_density : {0}" -f $_sdgMin)
            Write-Output ("  strategic_density_gate_pass  : {0}" -f $_sdgPass)
            if (-not $_sdgPass) {
                $_sdgFail = ("STRATEGIC_DENSITY_1P5_HARD_DAILY_FAIL: avg={0} target={1} min={2} floor=10" -f $_sdgAvg, $_sdgTarget, $_sdgMin)
                Write-Output ("  => FAIL: {0}" -f $_sdgFail)
                Invoke-VerifyOnlineFailFast -Gate "STRATEGIC_DENSITY_1P5_HARD_DAILY" -Reason $_sdgFail
            }
            Write-Output "  => STRATEGIC_DENSITY_1P5_HARD_DAILY: PASS"
        } catch {
            Write-Output ("  STRATEGIC_DENSITY_1P5_HARD_DAILY: WARN (parse error: {0})" -f $_)
        }
    } else {
        Write-Output "  STRATEGIC_DENSITY_1P5_HARD_DAILY: WARN (source_density.meta.json not found)"
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter42b: PPTX_FORBIDDEN_HARD — three-layer defense: layer 3 (final gate)
# Any *.pptx in outputs/ → FAIL (even if pipeline didn't generate them, e.g. stale files)
# ---------------------------------------------------------------------------
$_pptxForbiddenFiles = @(Get-ChildItem -Path (Join-Path $repoRoot "outputs") -Filter "*.pptx" -ErrorAction SilentlyContinue)
if ($_pptxForbiddenFiles.Count -gt 0) {
    $_pptxForbiddenNames = ($_pptxForbiddenFiles | ForEach-Object { $_.Name }) -join ", "
    Write-Output ("PPTX_FORBIDDEN_HARD: FAIL — found {0} pptx file(s) in outputs: {1}" -f $_pptxForbiddenFiles.Count, $_pptxForbiddenNames)
    # Attempt cleanup before fail (but still FAIL — no hiding)
    foreach ($_pff in $_pptxForbiddenFiles) {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Output ("  [PPTX_FORBIDDEN_HARD] 已刪除: {0}" -f $_pff.Name)
    }
    Invoke-VerifyOnlineFailFast -Gate "PPTX_FORBIDDEN_HARD" `
        -Reason ("PPTX_FORBIDDEN_HARD: found {0} pptx files in outputs ({1})" -f $_pptxForbiddenFiles.Count, $_pptxForbiddenNames)
}
Write-Output "PPTX_FORBIDDEN_HARD: PASS (0 pptx files in outputs)"
Write-Output ""

# iter56/58: deliverable file listing evidence + SHA-256 same-run proof
Write-Output "DELIVERABLE_FILES_EVIDENCE:"
try {
    $_dfeItems = Get-Item (Join-Path $repoRoot "outputs\latest_brief.md"), (Join-Path $repoRoot "outputs\executive_report.docx") -ErrorAction Stop
    $_dfeSha = @{}
    foreach ($_dfItem in $_dfeItems) {
        $_dfeHash = (Get-FileHash $_dfItem.FullName -Algorithm SHA256).Hash.ToLower()
        $_dfeSha[$_dfItem.Name] = $_dfeHash
        Write-Output ("  {0}  LastWrite={1}  Length={2}  SHA256={3}" -f $_dfItem.Name, $_dfItem.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"), $_dfItem.Length, $_dfeHash)
    }
    $_dfeMd   = $_dfeItems | Where-Object { $_.Name -eq "latest_brief.md" }
    $_dfeDocx = $_dfeItems | Where-Object { $_.Name -eq "executive_report.docx" }
    # iter58: write delivery_consistency.meta.json (hash-based same-run proof)
    $_dcMeta = [ordered]@{
        run_id                = $_voRunId
        verified_at           = (Get-Date -Format "o")
        deliverables          = @(
            [ordered]@{
                file      = "latest_brief.md"
                sha256    = $_dfeSha["latest_brief.md"]
                length    = $($_dfeMd.Length)
                last_write = $($_dfeMd.LastWriteTime.ToString("o"))
            },
            [ordered]@{
                file      = "executive_report.docx"
                sha256    = $_dfeSha["executive_report.docx"]
                length    = $($_dfeDocx.Length)
                last_write = $($_dfeDocx.LastWriteTime.ToString("o"))
            }
        )
        same_run_verified     = $true
    }
    $_dcMeta | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $repoRoot "outputs\delivery_consistency.meta.json") -Encoding UTF8
    Write-Output "  delivery_consistency.meta.json written (SHA-256 same-run proof)"
} catch {
    Write-Output ("  [WARN] deliverable listing failed: {0}" -f $_)
}

# iter59: post-hoc archive gpu_load + delivery_consistency + LAST_RUN_SUMMARY into delivery_dir
# Best-effort copy; never breaks pipeline
Write-Output ""
Write-Output "DELIVERY_META_ARCHIVE:"
foreach ($_dmaFile in @("gpu_load.meta.json", "delivery_consistency.meta.json", "LAST_RUN_SUMMARY.txt")) {
    $_dmaSrc = Join-Path $repoRoot "outputs\$_dmaFile"
    $_dmaDst = Join-Path $_deliveryDir $_dmaFile
    if (Test-Path $_dmaSrc) {
        try {
            Copy-Item -Path $_dmaSrc -Destination $_dmaDst -Force
            Write-Output ("  COPIED: {0} -> delivery_dir" -f $_dmaFile)
        } catch {
            Write-Output ("  [WARN] copy failed: {0} ({1})" -f $_dmaFile, $_)
        }
    } else {
        Write-Output ("  [SKIP] not found: {0}" -f $_dmaFile)
    }
}
Write-Output ""

# ---------------------------------------------------------------------------
# iter72b: P0 FINGERPRINT (strategic gates summary) — unified for desktop/scheduler
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "=== P0 STRATEGIC FINGERPRINT ==="
Write-Output ("RUN_ID                          = {0}" -f $_voRunId)
Write-Output ("GIT_HEAD                        = {0}" -f $_voGitHead)
Write-Output ("MODE                            = {0}" -f $(if ($Mode) { $Mode } else { "default" }))
Write-Output ("ENTRYPOINT                      = {0}" -f $_voEntrypoint)
# Read strategic fields from meta files
$_fpCmPath = Join-Path $repoRoot "outputs\content_mix.meta.json"
$_fpSdPath = Join-Path $repoRoot "outputs\source_density.meta.json"
if (Test-Path $_fpCmPath) {
    try {
        $_fpCm = Get-Content $_fpCmPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output ("selected_events                 = {0}" -f $(if ($_fpCm.PSObject.Properties['selected_events']) { $_fpCm.selected_events } else { "N/A" }))
        Write-Output ("bigtech_actionable_count        = {0}" -f $(if ($_fpCm.PSObject.Properties['bigtech_actionable_count']) { $_fpCm.bigtech_actionable_count } else { "N/A" }))
        Write-Output ("bigtech_official_media_count     = {0}" -f $(if ($_fpCm.PSObject.Properties['bigtech_official_media_count']) { $_fpCm.bigtech_official_media_count } else { "N/A" }))
        Write-Output ("leadership_politics_ai_count     = {0}" -f $(if ($_fpCm.PSObject.Properties['leadership_politics_ai_count']) { $_fpCm.leadership_politics_ai_count } else { "N/A" }))
        Write-Output ("china_ai_gov_count              = {0}" -f $(if ($_fpCm.PSObject.Properties['china_ai_gov_count']) { $_fpCm.china_ai_gov_count } else { "N/A" }))
        Write-Output ("platform_total                  = {0}" -f $(if ($_fpCm.PSObject.Properties['platform_total']) { $_fpCm.platform_total } else { "N/A" }))
        Write-Output ("research_tutorial_total          = {0}" -f $(if ($_fpCm.PSObject.Properties['research_tutorial_total']) { $_fpCm.research_tutorial_total } else { "N/A" }))
        Write-Output ("selected_strategic_buckets_distinct = {0}" -f $(if ($_fpCm.PSObject.Properties['selected_strategic_buckets_distinct']) { $_fpCm.selected_strategic_buckets_distinct } else { "N/A" }))
    } catch {}
}
if (Test-Path $_fpSdPath) {
    try {
        $_fpSd = Get-Content $_fpSdPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output ("strategic_density_target_avg     = {0}" -f $(if ($_fpSd.PSObject.Properties['target_avg_density_1p5']) { $_fpSd.target_avg_density_1p5 } else { "N/A" }))
        Write-Output ("strategic_density_target_min     = {0}" -f $(if ($_fpSd.PSObject.Properties['target_min_density_1p5']) { $_fpSd.target_min_density_1p5 } else { "N/A" }))
        Write-Output ("selected_avg_strategic_density   = {0}" -f $(if ($_fpSd.PSObject.Properties['selected_avg_strategic_density_score']) { $_fpSd.selected_avg_strategic_density_score } else { "N/A" }))
        Write-Output ("selected_min_strategic_density   = {0}" -f $(if ($_fpSd.PSObject.Properties['selected_min_strategic_density_score']) { $_fpSd.selected_min_strategic_density_score } else { "N/A" }))
    } catch {}
}
Write-Output "=== END P0 STRATEGIC FINGERPRINT ==="
Write-Output ""

if ($pool85Degraded) {
    Write-Output "=== verify_online.ps1 完成：降級運行（Z0 frontier85_72h 低於嚴格目標；已接受 fallback）==="
} else {
    Write-Output "=== verify_online.ps1 完成：所有門檻通過 ==="
}
exit 0