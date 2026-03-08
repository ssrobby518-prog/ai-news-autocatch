# scheduler_wrapper.ps1 — Scheduled-task wrapper for ai-intel-scraper-mvp
# Sets PIPELINE_ENTRYPOINT=scheduled_task, tees to outputs\scheduler.log
# iter70b: added for entrypoint evidence

$ErrorActionPreference = "Continue"

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

$env:PIPELINE_ENTRYPOINT = "scheduled_task"

$logPath = Join-Path $repoRoot "outputs\scheduler.log"
$logDir  = Join-Path $repoRoot "outputs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$gitHead = "unknown"
try { $gitHead = (git rev-parse --short HEAD 2>$null) } catch {}
$runTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Header
$header = @(
    ""
    ("=" * 72)
    "[$runTs] === scheduler_wrapper.ps1 START ==="
    "ENTRYPOINT=scheduled_task"
    "GIT_HEAD=$gitHead"
    "repo_root=$repoRoot"
    ""
)
$header | ForEach-Object { Add-Content -LiteralPath $logPath -Value $_ -Encoding utf8 }

$voScript = Join-Path $repoRoot "scripts\verify_online.ps1"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $voScript -Mode daily 2>&1 |
    Tee-Object -FilePath $logPath -Append

$exitCode = $LASTEXITCODE

# iter72b: strategic fingerprint
$fpLines = @("", "[$((Get-Date -Format 'HH:mm:ss'))] === P0 STRATEGIC FINGERPRINT ===")
$cmFp = Join-Path $repoRoot "outputs\content_mix.meta.json"
$sdFp = Join-Path $repoRoot "outputs\source_density.meta.json"
if (Test-Path $cmFp) {
    try {
        $cmD = Get-Content $cmFp -Raw -Encoding UTF8 | ConvertFrom-Json
        $fpLines += "bigtech_actionable_count = $($cmD.bigtech_actionable_count)"
        $fpLines += "bigtech_official_media_count = $($cmD.bigtech_official_media_count)"
        $fpLines += "platform_total = $($cmD.platform_total)"
        $fpLines += "research_tutorial_total = $($cmD.research_tutorial_total)"
        $fpLines += "strategic_buckets_distinct = $($cmD.selected_strategic_buckets_distinct)"
    } catch {}
}
if (Test-Path $sdFp) {
    try {
        $sdD = Get-Content $sdFp -Raw -Encoding UTF8 | ConvertFrom-Json
        $fpLines += "strategic_density_target = $($sdD.target_avg_density_1p5)"
        $fpLines += "selected_avg_strategic_density = $($sdD.selected_avg_strategic_density_score)"
    } catch {}
}
$fpLines += "=== END P0 STRATEGIC FINGERPRINT ==="
$fpLines | ForEach-Object { Add-Content -LiteralPath $logPath -Value $_ -Encoding utf8 }

$footer = @(
    ""
    "[$((Get-Date -Format 'HH:mm:ss'))] === scheduler_wrapper.ps1 END (exit=$exitCode) ==="
    ""
)
$footer | ForEach-Object { Add-Content -LiteralPath $logPath -Value $_ -Encoding utf8 }

exit $exitCode
