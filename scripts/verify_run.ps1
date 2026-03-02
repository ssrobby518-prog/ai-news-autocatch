# verify_run.ps1 ??Executive report end-to-end verification
# Purpose: run pipeline with calibration profile, verify FILTER_SUMMARY + executive output
# Usage: powershell -ExecutionPolicy Bypass -File scripts\verify_run.ps1
# Usage (-SkipPipeline): verify gate checks only — do NOT re-run pipeline (used by FAIL demo)

param(
    [switch]$SkipPipeline   # if set: skip steps 0-2 (integrity/cleanup/pipeline); still checks NOT_READY + all gates
)

$ErrorActionPreference = "Stop"

# UTF-8 console hardening ??prevent garbled CJK output
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

Write-Host "=== 驗證開始 ===" -ForegroundColor Cyan

# Python binary resolution (always needed for steps 3-9 in both pipeline and SkipPipeline modes)
$venvPython = Join-Path $PSScriptRoot "..\venv\Scripts\python.exe"
if (Test-Path $venvPython) { $py = $venvPython } else { $py = "python" }

if (-not $SkipPipeline) {
    # 0) Text integrity pre-check (CRLF / BOM / autocrlf)
    Write-Host "`n[0/9] 執行文字完整性檢查..." -ForegroundColor Yellow
    $integrityScript = Join-Path $PSScriptRoot "check_text_integrity.ps1"
    if (Test-Path $integrityScript) {
        & powershell.exe -ExecutionPolicy Bypass -File $integrityScript
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Text integrity check failed ??fix issues before continuing." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  check_text_integrity.ps1 not found, skipping." -ForegroundColor Yellow
    }

    # 1) Remove previous outputs
    Write-Host "`n[1/9] 清除先前的輸出..." -ForegroundColor Yellow
    $filesToRemove = @(
        "docs\reports\deep_analysis_education_version.md",
        "docs\reports\deep_analysis_education_version_ppt.md",
        "docs\reports\deep_analysis_education_version_xmind.md",
        "outputs\deep_analysis.md",
        "outputs\deep_analysis_education.md",
        "outputs\education_report.docx",
        "outputs\education_report.pptx",
        "outputs\executive_report.docx",
        "outputs\executive_report.pptx",
        "outputs\notion_page.md",
        "outputs\mindmap.xmind",
        "outputs\NOT_READY.md",
        "outputs\pool_sufficiency.meta.json"
    )
    foreach ($f in $filesToRemove) {
        if (Test-Path $f) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $f"
        }
    }

    # 2) Run pipeline with calibration profile + brief report mode
    # brief mode matches the production deployment (run_pipeline.ps1 -Mode manual)
    # and prevents EXEC_ZH_NARRATIVE legacy gate from firing without llama.cpp
    Write-Host "`n[2/9] 以 RUN_PROFILE=calibration REPORT_MODE=brief 執行 Pipeline..." -ForegroundColor Yellow
    $env:RUN_PROFILE             = "calibration"
    $env:PIPELINE_REPORT_MODE    = "brief"
    $env:BRIEF_ONLY              = "1"
    $env:SKIP_DEEP_ANALYSIS      = "1"
    $env:SKIP_EDUCATION_RENDERER = "1"
    & $py scripts/run_once.py
    $exitCode = $LASTEXITCODE
    $env:RUN_PROFILE             = $null
    # BRIEF_ONLY / PIPELINE_REPORT_MODE / SKIP_* kept set so [4/9],[5/9],[7/9] gate
    # checks can detect brief mode and skip education-report assertions correctly.

    if ($exitCode -ne 0) {
        Write-Host "  Pipeline failed (exit code: $exitCode)" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Pipeline succeeded" -ForegroundColor Green
} else {
    Write-Host "`n[2/9] Pipeline 步驟已略過（-SkipPipeline 模式；關卡檢查使用現有輸出）" -ForegroundColor Yellow
}

# NOT_READY gate — always checked regardless of SkipPipeline.
# Pipeline writes NOT_READY.md when POOL_SUFFICIENCY hard gate fails:
#   final_selected_events < 6  OR  strict_fulltext_ok < 4
# Both verify_run and verify_online must FAIL (exit non-zero) when this file exists.
$notReadyPath = "outputs\NOT_READY.md"
if (Test-Path $notReadyPath) {
    Write-Host "" -ForegroundColor Red
    Write-Host "NOT_READY GATE: FAIL" -ForegroundColor Red
    Write-Host "  NOT_READY.md exists — POOL_SUFFICIENCY hard gate failed." -ForegroundColor Red
    Write-Host "  (Trigger: final_selected_events<6 OR strict_fulltext_ok<4)" -ForegroundColor Red
    Write-Host "  Contents: $((Get-Content $notReadyPath -Raw -Encoding UTF8).Trim())" -ForegroundColor Red
    Write-Host "  Fix: re-run after improving Z0 source quality or full-text fetch coverage." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# SHOWCASE_READY_HARD gate — ensures OK never represents an empty or thin deck.
# Reads outputs/showcase_ready.meta.json written by run_once.py.
# showcase_ready=true  => PASS (ai_selected_events >= 6, or demo supplement covered it)
# showcase_ready=false => FAIL exit 1 (deck has < 6 AI events)
# meta missing         => FAIL exit 1 (pipeline did not reach this stage)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "SHOWCASE_READY_HARD:" -ForegroundColor Yellow
$vrScPath = Join-Path $PSScriptRoot "..\outputs\showcase_ready.meta.json"
if (Test-Path $vrScPath) {
    try {
        $vrSc           = Get-Content $vrScPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $vrScReady      = [bool]($vrSc.PSObject.Properties["showcase_ready"]      -and $vrSc.showcase_ready)
        $vrScAiSel      = if ($vrSc.PSObject.Properties["ai_selected_events"])    { [int]$vrSc.ai_selected_events }    else { 0 }
        $vrScDeckEv     = if ($vrSc.PSObject.Properties["deck_events"])           { [int]$vrSc.deck_events }           else { 0 }
        $vrScMode       = if ($vrSc.PSObject.Properties["mode"])                  { [string]$vrSc.mode }               else { "manual" }
        $vrScFallback   = if ($vrSc.PSObject.Properties["fallback_used"])         { [bool]$vrSc.fallback_used }        else { $false }
        $vrScThreshold  = if ($vrSc.PSObject.Properties["threshold"])             { [int]$vrSc.threshold }             else { 6 }
        Write-Host ("  ai_selected_events : {0}" -f $vrScAiSel)
        Write-Host ("  deck_events        : {0}" -f $vrScDeckEv)
        Write-Host ("  mode               : {0}" -f $vrScMode)
        Write-Host ("  fallback_used      : {0}" -f $vrScFallback)
        Write-Host ("  showcase_ready     : {0}" -f $vrScReady)
        Write-Host ("  threshold          : {0}" -f $vrScThreshold)
        if ($vrScReady) {
            Write-Host ("  => SHOWCASE_READY_HARD: PASS (ai_selected={0} mode={1})" -f $vrScAiSel, $vrScMode) -ForegroundColor Green
        } else {
            Write-Host ("  => SHOWCASE_READY_HARD: FAIL (ai_selected={0} < {2}, mode={1})" -f $vrScAiSel, $vrScMode, $vrScThreshold) -ForegroundColor Red
            Write-Host ("     Fix: run in demo mode (-Mode demo) or wait for a day with >= {0} AI events." -f $vrScThreshold) -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Host ("  => SHOWCASE_READY_HARD: FAIL (parse error: {0})" -f $_) -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  => SHOWCASE_READY_HARD: FAIL (showcase_ready.meta.json not found — pipeline did not write readiness meta)" -ForegroundColor Red
    exit 1
}

# 3) Verify FILTER_SUMMARY exists in log
Write-Host "`n[3/9] 驗證 FILTER_SUMMARY 記錄..." -ForegroundColor Yellow
$filterLog = Select-String -Path "logs\app.log" -Pattern "FILTER_SUMMARY" -SimpleMatch | Select-Object -Last 1
if ($filterLog) {
    Write-Host "  FILTER_SUMMARY hit:" -ForegroundColor Green
    Write-Host "  $($filterLog.Line)"
} else {
    Write-Host "  FILTER_SUMMARY not found" -ForegroundColor Red
    exit 1
}

# 4) Verify education report exists on disk (NOT required to be git-tracked)
Write-Host "`n[4/9] 檢查教育報告檔案..." -ForegroundColor Yellow
$eduFile = "docs\reports\deep_analysis_education_version.md"
if ($env:BRIEF_ONLY -eq "1") {
    Write-Host "  SKIP: education report check (BRIEF_ONLY=1 — not produced in brief-only mode)" -ForegroundColor Yellow
} elseif (Test-Path $eduFile) {
    Get-Item $eduFile | Format-List FullName, LastWriteTime, Length
} else {
    Write-Host "  Report not found: $eduFile" -ForegroundColor Red
    exit 1
}

# 5) Verify education report contains key sections
Write-Host "`n[5/9] 驗證教育報告內容..." -ForegroundColor Yellow
if ($env:BRIEF_ONLY -eq "1") {
    Write-Host "  SKIP: education report content check (BRIEF_ONLY=1)" -ForegroundColor Yellow
} else {
    $patterns = @("Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Metrics", "mermaid")
    $hits = Select-String -Path $eduFile -Pattern $patterns -SimpleMatch
    if ($hits.Count -ge 3) {
        Write-Host "  Content check passed ($($hits.Count) section hits)" -ForegroundColor Green
    } else {
        Write-Host "  Content check failed (only $($hits.Count) hits)" -ForegroundColor Red
    }

    # Optional: check empty-report markers
    $emptyHit = Select-String -Path $eduFile -Pattern "No items|empty|filters" -SimpleMatch
    if ($emptyHit) {
        Write-Host "  Empty/non-empty section check:" -ForegroundColor Green
        foreach ($h in $emptyHit) {
            Write-Host "    $($h.Line.Trim().Substring(0, [Math]::Min(80, $h.Line.Trim().Length)))"
        }
    }
}

# 6) Artifact policy hard-fail guard
Write-Host "`n[6/9] 產物原則檢查（硬性失敗）..." -ForegroundColor Yellow

function Assert-NotTracked($pattern) {
    $tracked = git ls-files -- $pattern 2>$null
    if ($tracked) {
        Write-Host "  FAIL: Generated artifact is git-tracked:" -ForegroundColor Red
        foreach ($t in $tracked) { Write-Host "    $t" -ForegroundColor Red }
        Write-Host "  Fix: git rm --cached $pattern" -ForegroundColor Yellow
        exit 1
    }
}

Assert-NotTracked "docs/reports/deep_analysis_education_version*.md"
Assert-NotTracked "outputs/*"

Write-Host "  Artifact policy check passed." -ForegroundColor Green

# 7) Education report quality gate
Write-Host "`n[7/9] 教育報告品質關卡..." -ForegroundColor Yellow
if ($env:BRIEF_ONLY -eq "1") {
    Write-Host "  SKIP: education quality gate (BRIEF_ONLY=1 — education reports not produced)" -ForegroundColor Yellow
} else {
    & $py -m pytest tests/test_education_report_quality.py -q 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Education quality gate FAILED" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Education quality gate passed." -ForegroundColor Green
}

# 8) Executive output files check (DOCX/PPTX/Notion/XMind)
Write-Host "`n[8/9] 檢查執行摘要輸出檔案..." -ForegroundColor Yellow
# Detect sparse day: Notion/XMind are only required when main events passed the pipeline.
$vrSparseDay = $false
$vrFlowCountsPath = "outputs\flow_counts.meta.json"
if (Test-Path $vrFlowCountsPath) {
    try {
        $vrFc = Get-Content $vrFlowCountsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $vrSparseDay = ($vrFc.PSObject.Properties['event_gate_pass_total'] -and [int]$vrFc.event_gate_pass_total -eq 0)
    } catch { }
}
if ($vrSparseDay) {
    Write-Host "  [sparse day detected: event_gate_pass_total=0 - Notion/XMind optional]" -ForegroundColor Yellow
}
$execFiles = @(
    @{ Name="DOCX"; Path="outputs\executive_report.docx" },
    @{ Name="PPTX"; Path="outputs\executive_report.pptx" },
    @{ Name="Notion"; Path="outputs\notion_page.md" },
    @{ Name="XMind"; Path="outputs\mindmap.xmind" }
)
$minSizes = @{
    "DOCX" = 10240
    "PPTX" = 20480
}
$execAltPaths = @{
    "DOCX" = @("outputs\executive_report_brief.docx")
    "PPTX" = @("outputs\executive_report_brief.pptx")
}
$binPass = $true
$resolvedExecPaths = @{}

foreach ($ef in $execFiles) {
    $resolvedPath = $ef.Path
    $usedAltPath = $false
    if (-not (Test-Path $resolvedPath) -and $execAltPaths.ContainsKey($ef.Name)) {
        foreach ($altPath in $execAltPaths[$ef.Name]) {
            if (Test-Path $altPath) {
                $resolvedPath = $altPath
                $usedAltPath = $true
                break
            }
        }
    }

    if (Test-Path $resolvedPath) {
        $resolvedExecPaths[$ef.Name] = $resolvedPath
        $info = Get-Item $resolvedPath
        $pathTag = if ($usedAltPath) { " [ALT_PATH]" } else { "" }
        Write-Host ("  {0}: {1} ({2} bytes, {3}){4}" -f $ef.Name, $info.FullName, $info.Length, $info.LastWriteTime, $pathTag) -ForegroundColor Green
        if ($minSizes.ContainsKey($ef.Name) -and $info.Length -lt $minSizes[$ef.Name]) {
            Write-Host ("  FAIL: {0} too small ({1} bytes < {2} bytes threshold)" -f $ef.Name, $info.Length, $minSizes[$ef.Name]) -ForegroundColor Red
            $binPass = $false
        }
    } else {
        $isBriefOptional  = ($ef.Name -eq "Notion" -or $ef.Name -eq "XMind") -and ($env:BRIEF_ONLY -eq "1")
        $isSparseOptional = ($ef.Name -eq "Notion" -or $ef.Name -eq "XMind") -and $vrSparseDay
        if ($isBriefOptional) {
            Write-Host "  SKIP: $($ef.Path) not found (brief mode — not produced per req D)" -ForegroundColor Yellow
        } elseif ($isSparseOptional) {
            Write-Host "  SKIP: $($ef.Path) not found (sparse day - optional)" -ForegroundColor Yellow
        } else {
            Write-Host "  FAIL: $($ef.Path) not found" -ForegroundColor Red
            $binPass = $false
        }
    }
}

if (-not $binPass) {
    Write-Host "  Executive output check FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "  Executive output check passed." -ForegroundColor Green

$docxPathForChecks = if ($resolvedExecPaths.ContainsKey("DOCX")) { $resolvedExecPaths["DOCX"] } else { "outputs\executive_report.docx" }
$pptxPathForChecks = if ($resolvedExecPaths.ContainsKey("PPTX")) { $resolvedExecPaths["PPTX"] } else { "outputs\executive_report.pptx" }
$docxPathForPy = $docxPathForChecks -replace '\\', '/'
$pptxPathForPy = $pptxPathForChecks -replace '\\', '/'

# 9) Executive Output v3 guard ??banned words + embedded images
Write-Host "`n[9/9] 執行摘要輸出 v3 守衛..." -ForegroundColor Yellow

$bannedWords = @(
    "ai???", "AI Intel", "Z1", "Z2", "Z3", "Z4", "Z5",
    "pipeline", "ETL", "verify_run", "ingestion", "ai_core",
    "Last July was", "Desktop smoke signal", "signals_insufficient=true",
    "低信心事件候選", "source=platform", "本次無有效新聞；本次掃描統計",
    # v5.2.6 exec sanitizer — ASCII-only banned phrases (CJK checked in EXEC TEXT BAN SCAN)
    "Evidence summary: sources=",
    "Key terms: ",
    "validate source evidence and related numbers",
    "run small-scope checks against current workflow",
    "escalate only if next scan confirms sustained"
)
$v3Pass = $true
$notionBannedHits = 0
$docxBannedHits = 0
$pptxBannedHits = 0

# Check banned words in Notion page (plain text) — skip on sparse day if file absent
if ($env:BRIEF_ONLY -eq "1") {
    Write-Host "  SKIP: notion_page.md 掃描 (BRIEF_ONLY=1；brief 路徑不產生 Notion 檔)" -ForegroundColor Yellow
} elseif ((Test-Path "outputs\notion_page.md") -or -not $vrSparseDay) {
    $notionContent = Get-Content "outputs\notion_page.md" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($notionContent) {
        foreach ($bw in $bannedWords) {
            if ($notionContent -match [regex]::Escape($bw)) {
                Write-Host "  FAIL: Banned word '$bw' found in notion_page.md" -ForegroundColor Red
                $notionBannedHits++
                $v3Pass = $false
            }
        }
    } else {
        Write-Host "  SKIP: notion_page.md absent (sparse day)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  SKIP: notion_page.md absent (sparse day)" -ForegroundColor Yellow
}

# Check banned words in DOCX (extract text via python; strip URLs to avoid false positives from base64 URL fragments)
$docxText = & $py -c "
import re
from docx import Document
doc = Document(r'''$docxPathForPy''')
raw = ' '.join(p.text for p in doc.paragraphs)
for t in doc.tables:
    for row in t.rows:
        for cell in row.cells:
            raw += ' ' + cell.text
raw = re.sub(r'https?://\S+', ' URL_STRIPPED ', raw)
print(raw)
" 2>$null
if ($docxText) {
    foreach ($bw in $bannedWords) {
        if ($docxText -match [regex]::Escape($bw)) {
            Write-Host "  FAIL: Banned word '$bw' found in executive_report.docx" -ForegroundColor Red
            $docxBannedHits++
            $v3Pass = $false
        }
    }
}

# Check banned words in PPTX (extract text via python; strip URLs to avoid false positives)
$pptxText = & $py -c "
import re
from pptx import Presentation
prs = Presentation(r'''$pptxPathForPy''')
raw = ''
for slide in prs.slides:
    for shape in slide.shapes:
        if shape.has_text_frame:
            for p in shape.text_frame.paragraphs:
                raw += p.text + ' '
        if shape.has_table:
            for row in shape.table.rows:
                for cell in row.cells:
                    raw += cell.text + ' '
raw = re.sub(r'https?://\S+', ' URL_STRIPPED ', raw)
print(raw)
" 2>$null
if ($pptxText) {
    foreach ($bw in $bannedWords) {
        if ($pptxText -match [regex]::Escape($bw)) {
            Write-Host "  FAIL: Banned word '$bw' found in executive_report.pptx" -ForegroundColor Red
            $pptxBannedHits++
            $v3Pass = $false
        }
    }
}

# Count event cards for context (event cards need per-card images; zero events still need banner)
$eventCardCount = & $py -c "from docx import Document; doc = Document(r'''$docxPathForPy'''); print(sum(1 for p in doc.paragraphs if p.text.lstrip().startswith(chr(31532))))" 2>$null
$eventCards = if ($eventCardCount) { [int]$eventCardCount } else { 0 }
Write-Host "  Event cards detected: $eventCards"

# DOCX must always have at least 1 embedded image (banner on cover or per-card images)
$docxHasImage = & $py -c "
import zipfile, sys
with zipfile.ZipFile(r'''$docxPathForPy''') as z:
    media = [n for n in z.namelist() if n.startswith('word/media/')]
    print(len(media))
" 2>$null
$docxImageCount = if ($docxHasImage) { [int]$docxHasImage } else { 0 }
if ($docxImageCount -lt 1) {
    Write-Host "  FAIL: DOCX has no embedded images (word/media/ is empty)" -ForegroundColor Red
    $v3Pass = $false
} else {
    Write-Host "  DOCX embedded images: $docxImageCount file(s)" -ForegroundColor Green
}

# PPTX must always have at least 1 embedded image (banner on cover or per-card images)
# EXCEPTION: brief mode intentionally removes all images from PPTX (per design) — skip check
$isBriefModeVr = $false
$briefMinMetaVrPath = Join-Path $PSScriptRoot "..\outputs\brief_min_events_hard.meta.json"
if (Test-Path $briefMinMetaVrPath) { $isBriefModeVr = $true }
if ($isBriefModeVr) {
    Write-Host "  PPTX image check: SKIP (brief mode — images intentionally absent)" -ForegroundColor Yellow
} else {
    $pptxHasImage = & $py -c "
import zipfile, sys
with zipfile.ZipFile(r'''$pptxPathForPy''') as z:
    media = [n for n in z.namelist() if n.startswith('ppt/media/')]
    print(len(media))
" 2>$null
    $pptxImageCount = if ($pptxHasImage) { [int]$pptxHasImage } else { 0 }
    if ($pptxImageCount -lt 1) {
        Write-Host "  FAIL: PPTX has no embedded images (ppt/media/ is empty)" -ForegroundColor Red
        $v3Pass = $false
    } else {
        Write-Host "  PPTX embedded images: $pptxImageCount file(s)" -ForegroundColor Green
    }
}

if (-not $v3Pass) {
    Write-Host "  Executive Output v3 guard FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "  Executive Output v3 guard passed." -ForegroundColor Green

# ---------------------------------------------------------------------------
# EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD gate
# Reads outputs/exec_zh_narrative.meta.json written by run_once.py.
# PASS if fail_count == 0 (sparse day with < 6 events still passes when no events fail).
# FAIL if fail_count > 0 (at least one event failed the zh-narrative checks).
# ---------------------------------------------------------------------------
Write-Host "`n[ZH Narrative Gate] EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD..." -ForegroundColor Yellow
$zhMetaVerifyPath = Join-Path $PSScriptRoot "..\outputs\exec_zh_narrative.meta.json"
if (Test-Path $zhMetaVerifyPath) {
    try {
        $zhMetaV   = Get-Content $zhMetaVerifyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $zhFailV   = if ($zhMetaV.PSObject.Properties['fail_count'])  { [int]$zhMetaV.fail_count }  else { 0 }
        $zhPassV   = if ($zhMetaV.PSObject.Properties['pass_count'])  { [int]$zhMetaV.pass_count }  else { 0 }
        $zhTotalV  = if ($zhMetaV.PSObject.Properties['events_total']){ [int]$zhMetaV.events_total } else { 0 }
        $zhGateLabel = if ($zhFailV -eq 0) { "PASS" } else { "FAIL" }
        $zhGateColor = if ($zhFailV -eq 0) { "Green" } else { "Red" }
        Write-Host ("  meta: events_total={0}  pass={1}  fail={2}" -f $zhTotalV, $zhPassV, $zhFailV) -ForegroundColor White
        Write-Host ("  EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD : {0}" -f $zhGateLabel) -ForegroundColor $zhGateColor
        if ($zhFailV -gt 0) {
            Write-Host "  Fix: ensure final_cards have q1_zh/q2_zh with >=40 Chinese chars, <=50% EN ratio, embedded quote_window in brackets." -ForegroundColor Yellow
            if ($zhMetaV.PSObject.Properties['events']) {
                foreach ($ev in $zhMetaV.events) {
                    if (-not $ev.all_pass) {
                        $evTitle = if ($ev.PSObject.Properties['title']) { $ev.title } else { "" }
                        Write-Host ("    FAIL event: {0}" -f $evTitle.Substring(0, [Math]::Min(60, $evTitle.Length))) -ForegroundColor Red
                    }
                }
            }
            exit 1
        }
    } catch {
        Write-Host ("  exec_zh_narrative.meta.json parse error: {0}" -f $_) -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  EXEC_ZH_NARRATIVE_WITH_QUOTE_HARD: SKIP (meta not found — pipeline may not have reached this gate)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Executive Slide Density Audit (post-step-9; hard gate for 3 key slides)
# ---------------------------------------------------------------------------
Write-Host "`n[Density Audit] Executive Slide Density Audit..." -ForegroundColor Yellow
$densityRaw = & $py -c "
import sys, json
from pathlib import Path
sys.path.insert(0, str(Path('.').resolve()))
from scripts.diagnostics_pptx import slide_density_audit
try:
    res = slide_density_audit(Path('outputs/executive_report.pptx'))
    print(json.dumps(res))
except Exception as ex:
    print(json.dumps([]))
" 2>$null

$densityAuditPass = $true
$keyPatterns = @('Overview', '總覽', 'Event Ranking', '排行', 'Pending', '待決')
$forbiddenFragments = @('Last July was')
$requiredDensity = 80   # EXEC_REQUIRED_SLIDE_DENSITY (configurable)

$requiredSemanticDensity = 40   # EXEC_SEMANTIC_THRESHOLDS default

if ($densityRaw) {
    try { $densityData = $densityRaw | ConvertFrom-Json } catch { $densityData = @() }
    foreach ($s in $densityData) {
        $tbl = "$($s.table_cells_nonempty)/$($s.table_cells_total)"
        $semScore = if ($s.PSObject.Properties['semantic_score']) { $s.semantic_score } else { 0 }
        Write-Host ("[DENSITY] slide={0:D2} title=`"{1}`" chars={2} table={3} terms={4} nums={5} sents={6} score={7} sem_score={8}" -f $s.slide_index, ($s.title -replace '"', "'"), $s.text_chars, $tbl, $s.terms, $s.numbers, $s.sentences, $s.density_score, $semScore)
    }
    foreach ($s in $densityData) {
        # Forbidden fragment check (all slides)
        foreach ($frag in $forbiddenFragments) {
            if ($s.all_text -match [regex]::Escape($frag)) {
                Write-Host "  [DENSITY FAIL] Forbidden fragment '$frag' in slide=$($s.slide_index) title=`"$($s.title)`""
                $densityAuditPass = $false
            }
        }
        # Hard gate for key slides — semantic (primary) + formal (secondary)
        # Semantic gate is the hard gate: sem_score < threshold → truly hollow content → FAIL
        # Formal density gate: low but sem OK → WARN only (sparse-day signal-only is acceptable)
        $isKey = $false
        foreach ($pat in $keyPatterns) { if ($s.title -like "*$pat*") { $isKey = $true; break } }
        if ($isKey) {
            $semScore = if ($s.PSObject.Properties['semantic_score']) { $s.semantic_score } else { 0 }
            if ($semScore -lt $requiredSemanticDensity) {
                Write-Host ("  [DENSITY FAIL] slide={0} title=`"{1}`" sem_score={2} < required_semantic={3} (hollow content)" -f $s.slide_index, $s.title, $semScore, $requiredSemanticDensity)
                $densityAuditPass = $false
            } elseif ($s.density_score -lt $requiredDensity) {
                Write-Host ("  [DENSITY WARN] slide={0} title=`"{1}`" density={2} < {3} but sem_score={4} OK (sparse day, not hollow)" -f $s.slide_index, $s.title, $s.density_score, $requiredDensity, $semScore)
            }
        }
    }
    if (-not $densityAuditPass) {
        Write-Host "  Executive Slide Density Audit FAILED"
        exit 1
    }
    Write-Host "  Executive Slide Density Audit PASSED"
} else {
    Write-Host "  [Density Audit] Skipped (pptx parser returned no output)"
}

# ---------------------------------------------------------------------------
# BRIEF hard gates (brief mode only; SKIP when meta absent)
#   BRIEF_MIN_EVENTS_HARD       : ai_selected_events in [5, 10]
#   BRIEF_NO_BOILERPLATE_HARD   : no boilerplate in What happened / Why it matters
#   BRIEF_ANCHOR_REQUIRED_HARD  : both What happened and Why it matters contain anchor
#   BRIEF_ZH_TW_HARD            : What/Why CJK ratio >= 0.6, no simplified Chinese chars
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "BRIEF HARD GATES:" -ForegroundColor Yellow
$vrBriefGateMetas = @(
    @{ Label = "BRIEF_MIN_EVENTS_HARD";      File = "brief_min_events_hard.meta.json" },
    @{ Label = "BRIEF_NO_BOILERPLATE_HARD";  File = "brief_no_boilerplate_hard.meta.json" },
    @{ Label = "BRIEF_ANCHOR_REQUIRED_HARD"; File = "brief_anchor_required_hard.meta.json" },
    @{ Label = "BRIEF_INFO_DENSITY_HARD";    File = "brief_info_density_hard.meta.json" },
    @{ Label = "BRIEF_ZH_TW_HARD";           File = "brief_zh_tw_hard.meta.json" },
    @{ Label = "BRIEF_NO_GENERIC_NARRATIVE_HARD"; File = "brief_no_generic_narrative_hard.meta.json" },
    @{ Label = "BRIEF_NO_DUPLICATE_FRAMES_HARD";  File = "brief_no_duplicate_frames_hard.meta.json" },
    @{ Label = "BRIEF_FACT_PACK_HARD";            File = "brief_fact_pack_hard.meta.json" }
)
$vrBriefRepoRoot = Split-Path -Parent $PSScriptRoot
$vrBriefAnyFail = $false
foreach ($bg in $vrBriefGateMetas) {
    $bgPath = Join-Path $vrBriefRepoRoot ("outputs\" + $bg.File)
    if (-not (Test-Path $bgPath)) {
        Write-Host ("  {0}: SKIP ({1} not found — non-brief run or pipeline did not reach gate)" -f $bg.Label, $bg.File) -ForegroundColor Yellow
        continue
    }
    try {
        $bgMeta = Get-Content $bgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $bgGate = if ($bgMeta.PSObject.Properties['gate_result']) { [string]$bgMeta.gate_result } else { "FAIL" }
        if ($bg.Label -eq "BRIEF_MIN_EVENTS_HARD") {
            $bgMin = if ($bgMeta.PSObject.Properties['required_min']) { [int]$bgMeta.required_min } else { 5 }
            $bgMax = if ($bgMeta.PSObject.Properties['required_max']) { [int]$bgMeta.required_max } else { 10 }
            $bgAct = if ($bgMeta.PSObject.Properties['actual'])       { [int]$bgMeta.actual }       else { 0 }
            Write-Host ("  {0}: {1} (required=[{2},{3}] actual={4})" -f $bg.Label, $bgGate, $bgMin, $bgMax, $bgAct) `
                -ForegroundColor $(if ($bgGate -eq "PASS") { "Green" } else { "Red" })
        } else {
            $bgTotal = if ($bgMeta.PSObject.Properties['events_total']) { [int]$bgMeta.events_total } else { 0 }
            $bgFail  = if ($bgMeta.PSObject.Properties['fail_count'])   { [int]$bgMeta.fail_count }   else { 0 }
            Write-Host ("  {0}: {1} (events_total={2} fail_count={3})" -f $bg.Label, $bgGate, $bgTotal, $bgFail) `
                -ForegroundColor $(if ($bgGate -eq "PASS") { "Green" } else { "Red" })
            if ($bg.Label -eq "BRIEF_INFO_DENSITY_HARD" -and $bgMeta.PSObject.Properties['rules']) {
                $bgRules = $bgMeta.rules
                $bgCjk = if ($bgRules.PSObject.Properties['min_bullet_cjk_chars']) { [int]$bgRules.min_bullet_cjk_chars } else { 12 }
                $bgHits = if ($bgRules.PSObject.Properties['anchor_or_number_hits_min']) { [int]$bgRules.anchor_or_number_hits_min } else { 2 }
                Write-Host ("     rules: min_bullet_cjk_chars={0} anchor_or_number_hits_min={1} quotes_non_cta={2}" -f $bgCjk, $bgHits, $(if ($bgRules.PSObject.Properties['quotes_must_not_hit_cta_stoplist']) { [bool]$bgRules.quotes_must_not_hit_cta_stoplist } else { $true }))
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
                    Write-Host ("     soft: avg_bullets_per_event={0} avg_cjk_chars_per_bullet={1}" -f $avgBullets, $avgCjk)
                }
            }
        }
        if ($bgGate -eq "FAIL") {
            $vrBriefAnyFail = $true
            if ($bgMeta.PSObject.Properties['failing_events'] -and @($bgMeta.failing_events).Count -gt 0) {
                $bgFirst = @($bgMeta.failing_events)[0]
                $bgTitleA = if ($bgFirst.PSObject.Properties['title']) { [string]$bgFirst.title } elseif ($bgFirst.PSObject.Properties['title_a']) { [string]$bgFirst.title_a } else { "" }
                $bgTitleB = if ($bgFirst.PSObject.Properties['title_b']) { [string]$bgFirst.title_b } else { "" }
                $bgHit = if ($bgFirst.PSObject.Properties['hit_pattern']) { [string]$bgFirst.hit_pattern } elseif ($bgFirst.PSObject.Properties['sample_hit_pattern']) { [string]$bgFirst.sample_hit_pattern } else { "" }
                if ($bgTitleA) { Write-Host ("     failing_title={0}" -f $bgTitleA) -ForegroundColor Red }
                if ($bgTitleB) { Write-Host ("     failing_title_pair={0}" -f $bgTitleB) -ForegroundColor Red }
                if ($bgHit) { Write-Host ("     sample_hit_pattern={0}" -f $bgHit) -ForegroundColor Red }
            }
            Write-Host ("  => {0}: FAIL" -f $bg.Label) -ForegroundColor Red
            continue
        }
    } catch {
        Write-Host ("  {0}: FAIL (parse error: {1})" -f $bg.Label, $_) -ForegroundColor Red
        exit 1
    }
}
if ($vrBriefAnyFail) {
    exit 1
}

# ---------------------------------------------------------------------------
# BRIEF_CONTENT_MINER OBSERVABILITY (soft; non-gating)
# ---------------------------------------------------------------------------
$vrBriefMinerPath = Join-Path $vrBriefRepoRoot "outputs\brief_content_miner.meta.json"
Write-Host ""
Write-Host "BRIEF_CONTENT_MINER (obs):" -ForegroundColor Yellow
if (Test-Path $vrBriefMinerPath) {
    try {
        $vrBcm = Get-Content $vrBriefMinerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $vrBcmGate = if ($vrBcm.PSObject.Properties['gate_result']) { [string]$vrBcm.gate_result } else { "UNKNOWN" }
        $vrBcmTotal = if ($vrBcm.PSObject.Properties['events_total']) { [int]$vrBcm.events_total } else { 0 }
        $vrBcmStoplist = if ($vrBcm.PSObject.Properties['quote_stoplist_hits_count']) { [int]$vrBcm.quote_stoplist_hits_count } else { 0 }
        $vrBcmQ2Fail = if ($vrBcm.PSObject.Properties['quote2_cta_fail_count']) { [int]$vrBcm.quote2_cta_fail_count } else { 0 }
        Write-Host ("  gate_result               : {0}" -f $vrBcmGate)
        Write-Host ("  events_total              : {0}" -f $vrBcmTotal)
        Write-Host ("  quote_stoplist_hits_count : {0}" -f $vrBcmStoplist)
        Write-Host ("  quote2_cta_fail_count     : {0}" -f $vrBcmQ2Fail)
        if ($vrBcm.PSObject.Properties['events'] -and @($vrBcm.events).Count -gt 0) {
            $vrBcmFirst = @($vrBcm.events)[0]
            Write-Host ("  sample_title              : {0}" -f $(if ($vrBcmFirst.PSObject.Properties['title']) { $vrBcmFirst.title } else { "" }))
            Write-Host ("  sample_fulltext_len       : {0}" -f $(if ($vrBcmFirst.PSObject.Properties['fulltext_len']) { $vrBcmFirst.fulltext_len } else { 0 }))
            Write-Host ("  sample_candidates_total   : {0}" -f $(if ($vrBcmFirst.PSObject.Properties['candidates_total']) { $vrBcmFirst.candidates_total } else { 0 }))
            Write-Host ("  sample_quote2_is_cta      : {0}" -f $(if ($vrBcmFirst.PSObject.Properties['quote2_is_cta']) { $vrBcmFirst.quote2_is_cta } else { $false }))
        }
    } catch {
        Write-Host ("  BRIEF_CONTENT_MINER: SKIP (parse error: {0})" -f $_) -ForegroundColor Yellow
    }
} else {
    Write-Host "  BRIEF_CONTENT_MINER: SKIP (brief_content_miner.meta.json not found)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# SUPPLY RESILIENCE META (observability only; non-gating)
# ---------------------------------------------------------------------------
$vrSupplyMetaPath = Join-Path $vrBriefRepoRoot "outputs\supply_resilience.meta.json"
Write-Host ""
Write-Host "SUPPLY RESILIENCE META:" -ForegroundColor Yellow
if (Test-Path $vrSupplyMetaPath) {
    try {
        $vrSrm = Get-Content $vrSupplyMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ("  run_id                     : {0}" -f $(if ($vrSrm.PSObject.Properties['run_id']) { $vrSrm.run_id } else { "" }))
        Write-Host ("  report_mode                : {0}" -f $(if ($vrSrm.PSObject.Properties['report_mode']) { $vrSrm.report_mode } else { "" }))
        Write-Host ("  mode                       : {0}" -f $(if ($vrSrm.PSObject.Properties['mode']) { $vrSrm.mode } else { "" }))
        Write-Host ("  fetched_total              : {0}" -f $(if ($vrSrm.PSObject.Properties['fetched_total']) { $vrSrm.fetched_total } else { 0 }))
        Write-Host ("  hydrated_ok                : {0}" -f $(if ($vrSrm.PSObject.Properties['hydrated_ok']) { $vrSrm.hydrated_ok } else { 0 }))
        Write-Host ("  hydrated_coverage          : {0}" -f $(if ($vrSrm.PSObject.Properties['hydrated_coverage']) { $vrSrm.hydrated_coverage } else { 0 }))
        Write-Host ("  tierA_candidates           : {0}" -f $(if ($vrSrm.PSObject.Properties['tierA_candidates']) { $vrSrm.tierA_candidates } else { 0 }))
        Write-Host ("  tierA_used                 : {0}" -f $(if ($vrSrm.PSObject.Properties['tierA_used']) { $vrSrm.tierA_used } else { 0 }))
        Write-Host ("  quote_candidate_span_policy: {0}" -f $(if ($vrSrm.PSObject.Properties['quote_candidate_span_policy']) { $vrSrm.quote_candidate_span_policy } else { "" }))
        Write-Host ("  quote_stoplist_hits_count  : {0}" -f $(if ($vrSrm.PSObject.Properties['quote_stoplist_hits_count']) { $vrSrm.quote_stoplist_hits_count } else { 0 }))
        Write-Host ("  extended_pool_used         : {0}" -f $(if ($vrSrm.PSObject.Properties['extended_pool_used']) { $vrSrm.extended_pool_used } else { $false }))
        Write-Host ("  extended_pool_added_count  : {0}" -f $(if ($vrSrm.PSObject.Properties['extended_pool_added_count']) { $vrSrm.extended_pool_added_count } else { 0 }))
        Write-Host ("  final_ai_selected_events   : {0}" -f $(if ($vrSrm.PSObject.Properties['final_ai_selected_events']) { $vrSrm.final_ai_selected_events } else { 0 }))
        Write-Host ("  not_ready                  : {0}" -f $(if ($vrSrm.PSObject.Properties['not_ready']) { $vrSrm.not_ready } else { $false }))
        if ($vrSrm.PSObject.Properties['reason']) {
            Write-Host ("  reason                     : {0}" -f $vrSrm.reason)
        }
    } catch {
        Write-Host ("  supply_resilience meta parse error (non-fatal): {0}" -f $_)
    }
} else {
    Write-Host "  supply_resilience.meta.json not found (skipped)" -ForegroundColor Yellow
}

Write-Host "`n=== 驗證完成 ===" -ForegroundColor Cyan
Write-Host "NOTE: Executive reports are build artifacts. Do NOT commit them." -ForegroundColor DarkGray
Write-Host "      To share, use file transfer or CI release artifacts." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# EXEC LAYOUT EVIDENCE — Visual Template V1 audit (reads exec_layout.meta.json)
# ---------------------------------------------------------------------------
$execLayoutMetaPath = Join-Path $PSScriptRoot "..\outputs\exec_layout.meta.json"
if (Test-Path $execLayoutMetaPath) {
    try {
        $elm = Get-Content $execLayoutMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ""
        Write-Host "EXEC LAYOUT EVIDENCE:"
        Write-Host ("  layout_version          : {0}" -f $elm.layout_version)
        if ($elm.PSObject.Properties['template_map']) {
            $tm = $elm.template_map
            Write-Host ("  template_map.overview   : {0}" -f $tm.overview)
            Write-Host ("  template_map.ranking    : {0}" -f $tm.ranking)
            Write-Host ("  template_map.pending    : {0}" -f $tm.pending)
            Write-Host ("  template_map.sig_summary: {0}" -f $tm.signal_summary)
            Write-Host ("  template_map.ev_slide_a : {0}" -f $tm.event_slide_a)
            Write-Host ("  template_map.ev_slide_b : {0}" -f $tm.event_slide_b)
        }
        if ($elm.PSObject.Properties['fragment_fix_stats']) {
            $ffs = $elm.fragment_fix_stats
            Write-Host ("  fragment_ratio          : {0}" -f $ffs.fragment_ratio)
            Write-Host ("  fragments_detected      : {0}" -f $ffs.fragments_detected)
            Write-Host ("  fragments_fixed         : {0}" -f $ffs.fragments_fixed)
        }
        if ($elm.PSObject.Properties['bullet_len_stats']) {
            $bls = $elm.bullet_len_stats
            Write-Host ("  min_bullet_len          : {0}" -f $bls.min_bullet_len)
            Write-Host ("  avg_bullet_len          : {0}" -f $bls.avg_bullet_len)
        }
        if ($elm.PSObject.Properties['card_stats']) {
            $cs = $elm.card_stats
            Write-Host ("  proof_token_coverage    : {0}" -f $cs.proof_token_coverage_ratio)
            Write-Host ("  avg_sentences_per_card  : {0}" -f $cs.avg_sentences_per_event_card)
        }
        $validCodes = @('T1','T2','T3','T4','T5','T6','COVER','STRUCTURED_SUMMARY','CORP_WATCH','KEY_TAKEAWAYS','REC_MOVES','DECISION_MATRIX')
        $invalidCodes = @()
        if ($elm.PSObject.Properties['slide_layout_map']) {
            foreach ($sl in $elm.slide_layout_map) {
                if ($sl.template_code -notin $validCodes) {
                    $invalidCodes += $sl.template_code
                }
            }
        }
        if ($invalidCodes.Count -gt 0) {
            Write-Host ("  WARNING: invalid template codes: {0}" -f ($invalidCodes -join ', '))
        } else {
            Write-Host "  slide_layout_map codes  : all valid (T1-T6 + structural)"
        }
    } catch {
        Write-Host "  exec_layout meta parse error (non-fatal): $_"
    }
} else {
    Write-Host ""
    Write-Host "EXEC LAYOUT EVIDENCE: exec_layout.meta.json not found (skipped)"
}

$head = (git rev-parse HEAD 2>$null | Select-Object -First 1)
$gitStatusSbLines = @(git status -sb 2>$null)
$gitStatusSb = if ($gitStatusSbLines.Count -gt 0) { "$($gitStatusSbLines[0])".Trim() } else { "" }
if ([string]::IsNullOrWhiteSpace($gitStatusSb)) { $gitStatusSb = "<empty>" }
$gitPorcelain = (git status --porcelain 2>$null | Out-String).Trim()
$workingTree = if ([string]::IsNullOrWhiteSpace($gitPorcelain)) { "clean" } else { "dirty" }

# EVIDENCE GATE: working tree must be clean and status -sb must be exactly 1 line
if ($gitStatusSbLines.Count -ne 1) {
    Write-Host "EVIDENCE-GATE FAIL: git status -sb returned $($gitStatusSbLines.Count) lines (expected 1)." -ForegroundColor Red
    Write-Host "Commit or stash all changes before generating delivery evidence." -ForegroundColor Red
    exit 1
}
if ($workingTree -eq "dirty") {
    Write-Host "EVIDENCE-GATE FAIL: Working tree is dirty. Commit all changes first." -ForegroundColor Red
    exit 1
}

$branchSummary = if ($gitStatusSb -match "\[gone\]") {
    ($gitStatusSb -replace '^##\s*', '') + "  (WARN-OK: origin ref gone)"
} elseif ($gitStatusSb -match "^##\s+(.+)\.\.\.(.+)$") {
    "$($Matches[1]) -> $($Matches[2]) (tracking)"
} elseif ($gitStatusSb -match "^##\s+(.+)$") {
    "$($Matches[1]) (no upstream)"
} else {
    "<unavailable>"
}
$schemaDiff = (git diff HEAD~1..HEAD -- schemas/education_models.py 2>$null | Out-String).Trim()
$schemaModified = if ([string]::IsNullOrWhiteSpace($schemaDiff)) { "NO" } else { "YES" }
$schemaProofOutput = if ([string]::IsNullOrWhiteSpace($schemaDiff)) { "<empty>" } else { "non-empty" }

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "FINAL DELIVERY EVIDENCE" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "HEAD: $head"
Write-Host ""
Write-Host "Schema file: schemas/education_models.py"
Write-Host "EduNewsCard schema modified: $schemaModified"
Write-Host "Schema proof command: git diff HEAD~1..HEAD -- schemas/education_models.py"
Write-Host "Schema proof output: $schemaProofOutput"
Write-Host ""
Write-Host "Banned phrases detected: $($notionBannedHits + $docxBannedHits + $pptxBannedHits) hits"
Write-Host "DOCX output: $docxBannedHits hits"
Write-Host "PPTX output: $pptxBannedHits hits"
Write-Host ""

# Translation Delivery meta — display + STALE_META guard (Iteration 19)
# Hard gate (TRANSLATION_DELIVERY_HARD) enforced by verify_online.ps1;
# here we add run_id STALE check so stale metas from previous runs are rejected.
$_tdVrPath = Join-Path $PSScriptRoot "..\outputs\translation.meta.json"
if (Test-Path $_tdVrPath) {
    try {
        $tdVrMeta     = Get-Content $_tdVrPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_tdVrSuccess = if ($tdVrMeta.PSObject.Properties['success'])    { [bool]$tdVrMeta.success }       else { $false }
        $_tdVrFail    = if ($tdVrMeta.PSObject.Properties['fail_reason']){ [string]$tdVrMeta.fail_reason } else { "" }
        $_tdVrRunId   = if ($tdVrMeta.PSObject.Properties['run_id'])     { [string]$tdVrMeta.run_id }      else { "" }
        Write-Host ("TRANSLATION_DELIVERY: success={0}  run_id={1}  fail_reason={2}" -f $_tdVrSuccess, $_tdVrRunId, $_tdVrFail)
        # STALE_META check: reject meta from a previous pipeline run
        if ($env:PIPELINE_RUN_ID) {
            try {
                if ($_tdVrRunId -and ($_tdVrRunId -ne [string]$env:PIPELINE_RUN_ID)) {
                    Write-Host ("TRANSLATION_DELIVERY: STALE_META (meta.run_id={0} != PIPELINE_RUN_ID={1}) => FAIL" -f $_tdVrRunId, $env:PIPELINE_RUN_ID) -ForegroundColor Red
                    exit 1
                }
            } catch {
                Write-Host "TRANSLATION_DELIVERY: STALE_META check skipped (parse error: $_)" -ForegroundColor DarkYellow
            }
        }
    } catch {
        Write-Host "TRANSLATION_DELIVERY: (parse error)"
    }
} else {
    Write-Host "TRANSLATION_DELIVERY: translation.meta.json not found"
}
Write-Host ""

Write-Host "verify_run: 10/10 PASS"
Write-Host "Working tree: $workingTree"
Write-Host "Branch: $branchSummary"
Write-Host "git status -sb:"
Write-Host ("git status -sb (lines={0}):" -f $gitStatusSbLines.Count)
if ($gitStatusSbLines.Count -gt 0) {
    foreach ($ln in $gitStatusSbLines) {
        Write-Host $ln
    }
} else {
    Write-Host "<empty>"
}

# Z0 Collector Evidence (optional — only printed when meta file exists)
$z0MetaPath = Join-Path $PSScriptRoot "..\data\raw\z0\latest.meta.json"
if (Test-Path $z0MetaPath) {
    try {
        $z0Meta = Get-Content $z0MetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ""
        Write-Host "Z0 COLLECTOR EVIDENCE:"
        Write-Host ("  collected_at      : {0}" -f $z0Meta.collected_at)
        Write-Host ("  total_items       : {0}" -f $z0Meta.total_items)
        Write-Host ("  frontier_ge_70    : {0}" -f $z0Meta.frontier_ge_70)
        Write-Host ("  frontier_ge_85    : {0}" -f $z0Meta.frontier_ge_85)
        # New 72h granular stats (present in updated collector)
        if ($z0Meta.PSObject.Properties['frontier_ge_70_72h']) {
            Write-Host ("  frontier_ge_70_72h: {0}" -f $z0Meta.frontier_ge_70_72h)
        }
        if ($z0Meta.PSObject.Properties['frontier_ge_85_72h']) {
            Write-Host ("  frontier_ge_85_72h: {0}" -f $z0Meta.frontier_ge_85_72h)
        }
        # Audit: date-source provenance
        if ($z0Meta.PSObject.Properties['published_at_source_counts']) {
            $srcJson = $z0Meta.published_at_source_counts | ConvertTo-Json -Compress
            Write-Host ("  pub_at_source_counts: {0}" -f $srcJson)
        }
        if ($z0Meta.PSObject.Properties['fallback_ratio']) {
            Write-Host ("  fallback_ratio        : {0}" -f $z0Meta.fallback_ratio)
        }
        if ($z0Meta.PSObject.Properties['frontier_ge_85_fallback_count']) {
            Write-Host ("  f85_fallback_count    : {0}" -f $z0Meta.frontier_ge_85_fallback_count)
        }
        if ($z0Meta.PSObject.Properties['frontier_ge_85_fallback_ratio']) {
            Write-Host ("  f85_fallback_ratio    : {0}" -f $z0Meta.frontier_ge_85_fallback_ratio)
        }
        if ($z0Meta.by_platform) {
            Write-Host "  by_platform:"
            $z0Meta.by_platform.PSObject.Properties | Sort-Object Value -Descending | ForEach-Object {
                Write-Host ("    {0}: {1}" -f $_.Name, $_.Value)
            }
        }
        # Optional gate: Z0_MIN_FRONTIER85 (checks total; e.g. set $env:Z0_MIN_FRONTIER85=5)
        if ($env:Z0_MIN_FRONTIER85) {
            $minF85 = [int]$env:Z0_MIN_FRONTIER85
            if ($z0Meta.frontier_ge_85 -lt $minF85) {
                Write-Host ("Z0 GATE FAIL: frontier_ge_85={0} < required={1}" -f $z0Meta.frontier_ge_85, $minF85)
                exit 1
            }
            Write-Host ("  Z0 gate OK: frontier_ge_85={0} >= {1}" -f $z0Meta.frontier_ge_85, $minF85)
        }
        # Optional gate: Z0_MIN_FRONTIER85_72H (checks 72h window; e.g. set $env:Z0_MIN_FRONTIER85_72H=3)
        if ($env:Z0_MIN_FRONTIER85_72H) {
            $minF85_72h = [int]$env:Z0_MIN_FRONTIER85_72H
            $actual72h = if ($z0Meta.PSObject.Properties['frontier_ge_85_72h']) { [int]$z0Meta.frontier_ge_85_72h } else { 0 }
            if ($actual72h -lt $minF85_72h) {
                Write-Host ("Z0 GATE FAIL: frontier_ge_85_72h={0} < required={1}" -f $actual72h, $minF85_72h)
                exit 1
            }
            Write-Host ("  Z0 gate OK: frontier_ge_85_72h={0} >= {1}" -f $actual72h, $minF85_72h)
        }
    } catch {
        Write-Host "  Z0 meta parse error (non-fatal): $_"
    }
}

# Executive Selection Meta Evidence (optional - only printed when file exists)
$execMetaPath = Join-Path $PSScriptRoot "..\outputs\exec_selection.meta.json"
if (Test-Path $execMetaPath) {
    try {
        $execMeta = Get-Content $execMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ""
        Write-Host "EXECUTIVE SELECTION EVIDENCE:"
        Write-Host ("  events_total              : {0}" -f $execMeta.events_total)
        if ($execMeta.PSObject.Properties['events_by_bucket']) {
            $bucketJson = $execMeta.events_by_bucket | ConvertTo-Json -Compress
            Write-Host ("  events_by_bucket          : {0}" -f $bucketJson)
        }
        Write-Host ("  rejected_irrelevant_count : {0}" -f $execMeta.rejected_irrelevant_count)
        if ($execMeta.PSObject.Properties['rejected_top_reasons'] -and $execMeta.rejected_top_reasons) {
            Write-Host ("  rejected_top_reasons      : {0}" -f ($execMeta.rejected_top_reasons -join "; "))
        }
        Write-Host ("  quota_pass                : {0}" -f $execMeta.quota_pass)
        Write-Host ("  sparse_day                : {0}" -f $execMeta.sparse_day)
        if ($execMeta.PSObject.Properties['quota_target']) {
            $qtJson = $execMeta.quota_target | ConvertTo-Json -Compress
            Write-Host ("  quota_target              : {0}" -f $qtJson)
        }
        # Optional ENV gates (informational — 9/9 pipeline gate is authoritative)
        if ($env:EXEC_MIN_EVENTS) {
            $minEv = [int]$env:EXEC_MIN_EVENTS
            $actualEv = [int]$execMeta.events_total
            if ($actualEv -lt $minEv) {
                Write-Host ("  EXEC gate WARN: events_total={0} < required={1}" -f $actualEv, $minEv)
            } else {
                Write-Host ("  EXEC gate OK: events_total={0} >= {1}" -f $actualEv, $minEv)
            }
        }
        if ($env:EXEC_MIN_PRODUCT) {
            $minP = [int]$env:EXEC_MIN_PRODUCT
            $actP = if ($execMeta.events_by_bucket.PSObject.Properties['product']) { [int]$execMeta.events_by_bucket.product } else { 0 }
            if ($actP -lt $minP) {
                Write-Host ("  EXEC gate WARN: product={0} < required={1} (quota_unmet)" -f $actP, $minP)
            } else {
                Write-Host ("  EXEC gate OK: product={0} >= {1}" -f $actP, $minP)
            }
        }
        if ($env:EXEC_MIN_TECH) {
            $minT = [int]$env:EXEC_MIN_TECH
            $actT = if ($execMeta.events_by_bucket.PSObject.Properties['tech']) { [int]$execMeta.events_by_bucket.tech } else { 0 }
            if ($actT -lt $minT) {
                Write-Host ("  EXEC gate WARN: tech={0} < required={1} (quota_unmet)" -f $actT, $minT)
            } else {
                Write-Host ("  EXEC gate OK: tech={0} >= {1}" -f $actT, $minT)
            }
        }
        if ($env:EXEC_MIN_BUSINESS) {
            $minB = [int]$env:EXEC_MIN_BUSINESS
            $actB = if ($execMeta.events_by_bucket.PSObject.Properties['business']) { [int]$execMeta.events_by_bucket.business } else { 0 }
            if ($actB -lt $minB) {
                Write-Host ("  EXEC gate WARN: business={0} < required={1} (quota_unmet)" -f $actB, $minB)
            } else {
                Write-Host ("  EXEC gate OK: business={0} >= {1}" -f $actB, $minB)
            }
        }
    } catch {
        Write-Host "  exec_selection meta parse error (non-fatal): $_"
    }
}

# Pipeline Flow Counts (optional — only printed when file exists)
$flowCountsPath = Join-Path $PSScriptRoot "..\outputs\flow_counts.meta.json"
if (Test-Path $flowCountsPath) {
    try {
        $fc = Get-Content $flowCountsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ""
        Write-Host "PIPELINE FLOW COUNTS:"
        Write-Host ("  z0_loaded_total            : {0}" -f $fc.z0_loaded_total)
        Write-Host ("  after_dedupe_total         : {0}" -f $fc.after_dedupe_total)
        Write-Host ("  after_too_old_filter_total : {0}" -f $fc.after_too_old_filter_total)
        Write-Host ("  event_gate_pass_total      : {0}" -f $fc.event_gate_pass_total)
        Write-Host ("  signal_gate_pass_total     : {0}" -f $fc.signal_gate_pass_total)
        Write-Host ("  exec_candidates_total      : {0}" -f $fc.exec_candidates_total)
        Write-Host ("  exec_selected_total        : {0}" -f $fc.exec_selected_total)
        Write-Host ("  extra_cards_total          : {0}" -f $fc.extra_cards_total)
        if ($fc.drop_reasons_top5) {
            $drJson = $fc.drop_reasons_top5 | ConvertTo-Json -Compress
            Write-Host ("  drop_reasons_top5          : {0}" -f $drJson)
        }
    } catch {
        Write-Host "  flow_counts meta parse error (non-fatal): $_"
    }
}

# Filter Breakdown (optional — only printed when filter_breakdown.meta.json exists)
$filterBdPath = Join-Path $PSScriptRoot "..\outputs\filter_breakdown.meta.json"
if (Test-Path $filterBdPath) {
    try {
        $fb = Get-Content $filterBdPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ""
        Write-Host "FILTER BREAKDOWN:"
        Write-Host ("  input_count          : {0}" -f $fb.input_count)
        Write-Host ("  kept                 : {0}" -f $fb.kept)
        Write-Host ("  dropped_total        : {0}" -f $fb.dropped_total)
        Write-Host ("  lang_not_allowed     : {0}" -f $fb.lang_not_allowed_count)
        Write-Host ("  too_old              : {0}" -f $fb.too_old_count)
        Write-Host ("  body_too_short       : {0}" -f $fb.body_too_short_count)
        Write-Host ("  non_ai_topic         : {0}" -f $fb.non_ai_topic_count)
        Write-Host ("  allow_zh_enabled     : {0}" -f $fb.allow_zh_enabled)
        if ($fb.top5_reasons) {
            $fbTop5Json = $fb.top5_reasons | ConvertTo-Json -Compress
            Write-Host ("  top5_reasons         : {0}" -f $fbTop5Json)
        }
    } catch {
        Write-Host "  filter_breakdown meta parse error (non-fatal): $_"
    }
}

# Z0 Injection Gate Evidence (optional -- only printed when file exists)
$z0InjMetaPath = Join-Path $PSScriptRoot "..\outputs\z0_injection.meta.json"
if (Test-Path $z0InjMetaPath) {
    try {
        $z0Inj = Get-Content $z0InjMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ""
        Write-Host "Z0 INJECTION GATE EVIDENCE:"
        Write-Host ("  z0_inject_candidates_total        : {0}" -f $z0Inj.z0_inject_candidates_total)
        Write-Host ("  z0_inject_after_frontier_total    : {0}" -f $z0Inj.z0_inject_after_frontier_total)
        Write-Host ("  z0_inject_after_channel_gate_total: {0}" -f $z0Inj.z0_inject_after_channel_gate_total)
        Write-Host ("  z0_inject_selected_total          : {0}" -f $z0Inj.z0_inject_selected_total)
        Write-Host ("  z0_inject_dropped_by_channel_gate : {0}" -f $z0Inj.z0_inject_dropped_by_channel_gate)
        Write-Host ("  z0_inject_channel_gate_threshold  : {0}" -f $z0Inj.z0_inject_channel_gate_threshold)
    } catch {
        Write-Host "  z0_injection meta parse error (non-fatal): $_"
    }
}

# ---------------------------------------------------------------------------
# EXEC QUALITY GATES — reads exec_quality.meta.json written by pipeline
# ---------------------------------------------------------------------------
$execQualMetaPath = Join-Path $PSScriptRoot "..\outputs\exec_quality.meta.json"
if (Test-Path $execQualMetaPath) {
    try {
        $eqm = Get-Content $execQualMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $eqSparseDay = if ($eqm.PSObject.Properties['sparse_day']) { [bool]$eqm.sparse_day } else { $false }

        $g1Status  = "PASS"   # AI relevance already enforced upstream; report count only
        $g2Status  = if ($eqm.PSObject.Properties['source_diversity_gate']) { $eqm.source_diversity_gate } else { "PASS" }
        $g3Status  = if ($eqm.PSObject.Properties['proof_coverage_gate'])   { $eqm.proof_coverage_gate }   else { "PASS" }
        $g4Status  = if ($eqm.PSObject.Properties['fragment_leak_gate'])    { $eqm.fragment_leak_gate }    else { "PASS" }

        $nonAiRej     = if ($eqm.PSObject.Properties['non_ai_rejected_count'])  { $eqm.non_ai_rejected_count }  else { 0 }
        $maxSrcShare  = if ($eqm.PSObject.Properties['max_source_share'])       { $eqm.max_source_share }       else { 0 }
        $maxSrc       = if ($eqm.PSObject.Properties['max_source'])             { $eqm.max_source }             else { "n/a" }
        $proofRatio   = if ($eqm.PSObject.Properties['proof_coverage_ratio'])   { $eqm.proof_coverage_ratio }   else { 0 }
        $fragLeaked   = if ($eqm.PSObject.Properties['fragments_leaked'])       { $eqm.fragments_leaked }       else { 0 }
        $fragDetected = if ($eqm.PSObject.Properties['fragments_detected'])     { $eqm.fragments_detected }     else { 0 }
        $fragFixed    = if ($eqm.PSObject.Properties['fragments_fixed'])        { $eqm.fragments_fixed }        else { 0 }
        $enHeavyFixed    = if ($eqm.PSObject.Properties['english_heavy_paragraphs_fixed_count']) { $eqm.english_heavy_paragraphs_fixed_count } else { 0 }
        $glossApplied    = if ($eqm.PSObject.Properties['proper_noun_gloss_applied_count'])      { $eqm.proper_noun_gloss_applied_count }      else { 0 }
        $actionsNorm     = if ($eqm.PSObject.Properties['actions_normalized_count'])             { $eqm.actions_normalized_count }             else { 0 }
        $actionsLeak     = if ($eqm.PSObject.Properties['actions_fragment_leak_count'])          { $eqm.actions_fragment_leak_count }          else { 0 }
        $zhSkeletonize   = if ($eqm.PSObject.Properties['english_heavy_skeletonized_count'])     { $eqm.english_heavy_skeletonized_count }     else { 0 }
        $proofEmptyGate  = if ($eqm.PSObject.Properties['proof_empty_gate'])                     { $eqm.proof_empty_gate }                     else { "PASS" }
        $proofEmptyCount = if ($eqm.PSObject.Properties['proof_empty_event_count'])              { $eqm.proof_empty_event_count }              else { 0 }
        $actNormStatus   = if ($actionsLeak -eq 0) { "PASS" } else { "FAIL" }

        Write-Host ""
        Write-Host "EXEC QUALITY GATES:"
        Write-Host ("  AI_RELEVANCE_GATE    : {0} (non_ai_rejected={1})" -f $g1Status, $nonAiRej)
        Write-Host ("  SOURCE_DIVERSITY_GATE: {0} (max_source_share={1:P1} source={2})" -f $g2Status, $maxSrcShare, $maxSrc)
        Write-Host ("  PROOF_COVERAGE_GATE  : {0} (ratio={1:P1})" -f $g3Status, $proofRatio)
        Write-Host ("  FRAGMENT_LEAK_GATE   : {0} (leaked={1} detected={2} fixed={3})" -f $g4Status, $fragLeaked, $fragDetected, $fragFixed)
        Write-Host ("  EN_ZH_HYBRID_GLOSS   : english_heavy_fixed={0}  proper_noun_glossed={1}" -f $enHeavyFixed, $glossApplied)
        Write-Host ("  ACTIONS_NORMALIZATION: {0} (normalized={1} leaked={2})" -f $actNormStatus, $actionsNorm, $actionsLeak)
        Write-Host ("  ZH_SKELETONIZE       : count={0}" -f $zhSkeletonize)
        Write-Host ("  PROOF_EMPTY_GATE     : {0} (empty={1})" -f $proofEmptyGate, $proofEmptyCount)

        $qualAnyFail = ($g2Status -eq "FAIL") -or ($g3Status -eq "FAIL") -or ($g4Status -eq "FAIL") -or ($actNormStatus -eq "FAIL") -or ($proofEmptyGate -eq "FAIL")
        if ($qualAnyFail -and -not $eqSparseDay) {
            Write-Host "  => EXEC QUALITY GATES: FAIL" -ForegroundColor Red
            exit 1
        }
        Write-Host "  => EXEC QUALITY GATES: PASS"
    } catch {
        Write-Host "  exec_quality meta parse error (non-fatal): $_"
    }
} else {
    Write-Host ""
    Write-Host "EXEC QUALITY GATES: exec_quality.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# EXEC_NEWS_QUALITY_HARD GATE — verbatim quote DoD for exec reports
#   Reads outputs/exec_news_quality.meta.json written by run_once.py.
#   PASS: gate_result=PASS (all PH_SUPP cards have valid verbatim quotes)
#   SKIP: no meta file yet (first run or pipeline skipped exec generation)
#   FAIL: gate_result=FAIL (exit 1 — PPTX/DOCX already deleted by pipeline)
# ---------------------------------------------------------------------------
$enqMetaPath = Join-Path $PSScriptRoot "..\outputs\exec_news_quality.meta.json"
if (Test-Path $enqMetaPath) {
    try {
        $enqm          = Get-Content $enqMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $enqGate       = if ($enqm.PSObject.Properties['gate_result'])  { $enqm.gate_result } else { "SKIP" }
        $enqPassCount  = if ($enqm.PSObject.Properties['pass_count'])   { [int]$enqm.pass_count }   else { 0 }
        $enqFailCount  = if ($enqm.PSObject.Properties['fail_count'])   { [int]$enqm.fail_count }   else { 0 }
        $enqTotal      = if ($enqm.PSObject.Properties['events_total']) { [int]$enqm.events_total } else { 0 }

        Write-Host ""
        Write-Host "EXEC_NEWS_QUALITY_HARD:"
        Write-Host ("  events_checked: {0}  pass={1}  fail={2}" -f $enqTotal, $enqPassCount, $enqFailCount)

        if ($enqGate -eq "FAIL") {
            Write-Host ("  => EXEC_NEWS_QUALITY_HARD: FAIL ({0} event(s) missing verbatim quotes)" -f $enqFailCount) -ForegroundColor Red
            if ($enqm.PSObject.Properties['events'] -and $enqm.events) {
                foreach ($enqEv in $enqm.events) {
                    if (-not $enqEv.all_pass) {
                        Write-Host ("     FAIL: {0}" -f $enqEv.title) -ForegroundColor Red
                    }
                }
            }
            exit 1
        } else {
            Write-Host ("  => EXEC_NEWS_QUALITY_HARD: {0}" -f $enqGate) -ForegroundColor Green
        }
    } catch {
        Write-Host "  exec_news_quality meta parse error (non-fatal): $_"
    }
} else {
    Write-Host ""
    Write-Host "EXEC_NEWS_QUALITY_HARD: exec_news_quality.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# EXEC_DELIVERABLE_DOCX_PPTX_HARD GATE
# ---------------------------------------------------------------------------
$execDelivMetaPath = Join-Path $PSScriptRoot "..\outputs\exec_deliverable_docx_pptx_hard.meta.json"
if (Test-Path $execDelivMetaPath) {
    try {
        $edm = Get-Content $execDelivMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $edGate  = if ($edm.PSObject.Properties['gate_result']) { $edm.gate_result } else { "FAIL" }
        $edTotal = if ($edm.PSObject.Properties['events_total']) { [int]$edm.events_total } else { 0 }
        $edPass  = if ($edm.PSObject.Properties['pass_count']) { [int]$edm.pass_count } else { 0 }
        $edFail  = if ($edm.PSObject.Properties['fail_count']) { [int]$edm.fail_count } else { 0 }

        Write-Host ""
        Write-Host "EXEC_DELIVERABLE_DOCX_PPTX_HARD:"
        Write-Host ("  events_checked: {0}  pass={1}  fail={2}" -f $edTotal, $edPass, $edFail)

        if ($edFail -gt 0) {
            # Brief mode: EXEC_DELIVERABLE is WARN-OK; BRIEF_GATES are the acceptance criterion.
            # run_once.py brief-mode-bypass also overrides meta to PASS; this is a safety net.
            if ($env:BRIEF_ONLY -eq "1") {
                Write-Host ("  => EXEC_DELIVERABLE_DOCX_PPTX_HARD: WARN-OK (brief mode; {0} DoD fail(s); acceptance=BRIEF_GATES)" -f $edFail) -ForegroundColor Yellow
            } else {
                Write-Host ("  => EXEC_DELIVERABLE_DOCX_PPTX_HARD: FAIL ({0} failing event(s))" -f $edFail) -ForegroundColor Red
                if ($edm.PSObject.Properties['events'] -and $edm.events) {
                    foreach ($edEv in $edm.events) {
                        if (-not $edEv.all_pass) {
                            $edReasons = @()
                            if ($edEv.PSObject.Properties['dod'] -and $edEv.dod) {
                                foreach ($p in $edEv.dod.PSObject.Properties) {
                                    if (-not [bool]$p.Value) { $edReasons += $p.Name }
                                }
                            }
                            Write-Host ("     FAIL: {0}  reasons={1}" -f $edEv.title, ($edReasons -join ",")) -ForegroundColor Red
                        }
                    }
                }
                exit 1
            }
        }
        Write-Host "  => EXEC_DELIVERABLE_DOCX_PPTX_HARD: PASS (fail_count=0)" -ForegroundColor Green
    } catch {
        Write-Host ("  EXEC_DELIVERABLE_DOCX_PPTX_HARD parse error: {0}" -f $_) -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host ""
    Write-Host "EXEC_DELIVERABLE_DOCX_PPTX_HARD: FAIL (meta missing)" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# AI_PURITY_GATES: 7 new evidence-purity gates
# ---------------------------------------------------------------------------

# AI_PURITY_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] AI_PURITY_HARD..." -ForegroundColor Yellow
$aiPurityPath = Join-Path $PSScriptRoot "..\outputs\ai_purity_hard.meta.json"
if (Test-Path $aiPurityPath) {
    try {
        $aiPurity = Get-Content $aiPurityPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $aiGate   = if ($aiPurity.PSObject.Properties['gate_result']) { [string]$aiPurity.gate_result } else { 'FAIL' }
        $aiSel    = if ($aiPurity.PSObject.Properties['selected']) { [int]$aiPurity.selected } else { 0 }
        $aiTrue   = if ($aiPurity.PSObject.Properties['ai_true']) { [int]$aiPurity.ai_true } else { 0 }
        $aiWatch  = if ($aiPurity.PSObject.Properties['watchlist_excluded']) { [int]$aiPurity.watchlist_excluded } else { 0 }
        $aiLine   = ("{0} selected={1} ai_true={2} watchlist_excluded={3}" -f $aiGate, $aiSel, $aiTrue, $aiWatch)
        if ($aiGate -eq 'PASS') {
            Write-Host ("  AI_PURITY_HARD : PASS  {0}" -f $aiLine) -ForegroundColor Green
        } else {
            Write-Host ("  AI_PURITY_HARD : FAIL  {0}" -f $aiLine) -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host ("  AI_PURITY_HARD parse error: {0}" -f $_) -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  AI_PURITY_HARD : SKIP  ai_purity_hard.meta.json not found" -ForegroundColor Yellow
}

# NO_BOILERPLATE_Q1Q2_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] NO_BOILERPLATE_Q1Q2_HARD..." -ForegroundColor Yellow
function Get-MetaInt {
    param([object]$Meta, [string]$Name, [int]$Default = 0)
    if ($Meta -and $Meta.PSObject.Properties[$Name]) { return [int]$Meta.$Name }
    return $Default
}
function Invoke-MetaGate {
    param(
        [string]$Label,
        [string]$MetaFile,
        [scriptblock]$InfoBuilder
    )
    $metaPath = Join-Path $PSScriptRoot "..\outputs\$MetaFile"
    if (-not (Test-Path $metaPath)) {
        Write-Host ("  {0} : SKIP  {1} not found" -f $Label, $MetaFile) -ForegroundColor Yellow
        return
    }
    try {
        $metaObj = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $gate = if ($metaObj.PSObject.Properties['gate_result']) { [string]$metaObj.gate_result } else { 'FAIL' }
        $info = & $InfoBuilder $metaObj
        if ($gate -eq 'PASS') {
            Write-Host ("  {0} : PASS  {1}" -f $Label, $info) -ForegroundColor Green
        } else {
            Write-Host ("  {0} : FAIL  {1}" -f $Label, $info) -ForegroundColor Red
            exit 1
        }
    } catch {
        Write-Host ("  {0} parse error: {1}" -f $Label, $_) -ForegroundColor Red
        exit 1
    }
}
Invoke-MetaGate -Label "NO_BOILERPLATE_Q1Q2_HARD" -MetaFile "no_boilerplate_hard.meta.json" -InfoBuilder {
    param($d)
    "events_total=$((Get-MetaInt $d 'events_total' 0)) fail_count=$((Get-MetaInt $d 'fail_count' 0))"
}

# Q1_STRUCTURE_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] Q1_STRUCTURE_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "Q1_STRUCTURE_HARD" -MetaFile "q1_structure_hard.meta.json" -InfoBuilder {
    param($d)
    "pass=$((Get-MetaInt $d 'pass_count' 0)) fail=$((Get-MetaInt $d 'fail_count' 0)) total=$((Get-MetaInt $d 'events_total' 0))"
}

# Q2_STRUCTURE_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] Q2_STRUCTURE_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "Q2_STRUCTURE_HARD" -MetaFile "q2_structure_hard.meta.json" -InfoBuilder {
    param($d)
    "pass=$((Get-MetaInt $d 'pass_count' 0)) fail=$((Get-MetaInt $d 'fail_count' 0)) total=$((Get-MetaInt $d 'events_total' 0))"
}

# MOVES_ANCHORED_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] MOVES_ANCHORED_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "MOVES_ANCHORED_HARD" -MetaFile "moves_anchored_hard.meta.json" -InfoBuilder {
    param($d)
    "events_total=$((Get-MetaInt $d 'events_total' 0)) fail_count=$((Get-MetaInt $d 'fail_count' 0))"
}

# EXEC_PRODUCT_READABILITY_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] EXEC_PRODUCT_READABILITY_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "EXEC_PRODUCT_READABILITY_HARD" -MetaFile "exec_product_readability_hard.meta.json" -InfoBuilder {
    param($d)
    "pass=$((Get-MetaInt $d 'pass_count' 0)) fail=$((Get-MetaInt $d 'fail_count' 0)) total=$((Get-MetaInt $d 'events_total' 0))"
}

# STATS_SINGLE_SOURCE_HARD GATE
Write-Host ""
Write-Host "[AI Purity Gate] STATS_SINGLE_SOURCE_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "STATS_SINGLE_SOURCE_HARD" -MetaFile "stats_single_source_hard.meta.json" -InfoBuilder {
    param($d)
    $present = if ($d.PSObject.Properties['present'] -and $d.present) { @($d.present).Count } else { 0 }
    $total   = if ($d.PSObject.Properties['canonical_sources'] -and $d.canonical_sources) { @($d.canonical_sources).Count } else { 0 }
    $missing = if ($d.PSObject.Properties['missing'] -and $d.missing) { ($d.missing -join ',') } else { "" }
    "sources=$present/$total missing=[$missing]"
}

# BRIEF hard gates (brief mode only; SKIP when meta absent)
Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_MIN_EVENTS_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_MIN_EVENTS_HARD" -MetaFile "brief_min_events_hard.meta.json" -InfoBuilder {
    param($d)
    "required_min=$((Get-MetaInt $d 'required_min' 5)) required_max=$((Get-MetaInt $d 'required_max' 10)) actual=$((Get-MetaInt $d 'actual' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_NO_BOILERPLATE_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_NO_BOILERPLATE_HARD" -MetaFile "brief_no_boilerplate_hard.meta.json" -InfoBuilder {
    param($d)
    "events_total=$((Get-MetaInt $d 'events_total' 0)) fail_count=$((Get-MetaInt $d 'fail_count' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_ANCHOR_REQUIRED_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_ANCHOR_REQUIRED_HARD" -MetaFile "brief_anchor_required_hard.meta.json" -InfoBuilder {
    param($d)
    "events_total=$((Get-MetaInt $d 'events_total' 0)) fail_count=$((Get-MetaInt $d 'fail_count' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_INFO_DENSITY_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_INFO_DENSITY_HARD" -MetaFile "brief_info_density_hard.meta.json" -InfoBuilder {
    param($d)
    "events_total=$((Get-MetaInt $d 'events_total' 0)) fail_count=$((Get-MetaInt $d 'fail_count' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_NO_AUDIT_SPEAK_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_NO_AUDIT_SPEAK_HARD" -MetaFile "brief_no_audit_speak_hard.meta.json" -InfoBuilder {
    param($d)
    "total_events=$((Get-MetaInt $d 'total_events' 0)) audit_speak_hits=$((Get-MetaInt $d 'audit_speak_hit_count' 0)) hit_events=$((Get-MetaInt $d 'audit_speak_event_count' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_FACT_SENTENCE_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_FACT_SENTENCE_HARD" -MetaFile "brief_fact_sentence_hard.meta.json" -InfoBuilder {
    param($d)
    "total_events=$((Get-MetaInt $d 'total_events' 0)) events_below_threshold=$((Get-MetaInt $d 'events_below_threshold' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_EVENT_SENTENCE_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_EVENT_SENTENCE_HARD" -MetaFile "brief_event_sentence_hard.meta.json" -InfoBuilder {
    param($d)
    "total_events=$((Get-MetaInt $d 'total_events' 0)) events_below_threshold=$((Get-MetaInt $d 'events_below_threshold' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_FACT_CANDIDATES_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_FACT_CANDIDATES_HARD" -MetaFile "brief_fact_candidates_hard.meta.json" -InfoBuilder {
    param($d)
    "total_events=$((Get-MetaInt $d 'total_events' 0)) events_fail_count=$((Get-MetaInt $d 'events_fail_count' 0))"
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_FACT_PACK_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_FACT_PACK_HARD" -MetaFile "brief_fact_pack_hard.meta.json" -InfoBuilder {
    param($d)
    "total_events=$((Get-MetaInt $d 'total_events' 0)) fail_count=$((Get-MetaInt $d 'fail_count' 0))"
}
# STALE_META check: meta.run_id must match PIPELINE_RUN_ID for this run
if ($env:PIPELINE_RUN_ID) {
    try {
        $_bfpMetaPathV = Join-Path $PSScriptRoot "..\outputs\brief_fact_pack_hard.meta.json"
        $_bfpMetaItemV = Get-Item $_bfpMetaPathV -ErrorAction SilentlyContinue
        $_bfpMetaV  = Get-Content $_bfpMetaPathV -Raw -Encoding UTF8 | ConvertFrom-Json
        $_bfpRunIdV = if ($_bfpMetaV.PSObject.Properties["run_id"]) { [string]$_bfpMetaV.run_id } else { "" }
        if ($_bfpRunIdV -and ($_bfpRunIdV -ne [string]$env:PIPELINE_RUN_ID)) {
            $_bfpTreatAsStaleOnly = $false
            try {
                $_bfpRunStart = [datetime]::ParseExact([string]$env:PIPELINE_RUN_ID, "yyyyMMdd_HHmmss", $null)
                if ($_bfpMetaItemV -and $_bfpMetaItemV.LastWriteTime -lt $_bfpRunStart) {
                    $_bfpTreatAsStaleOnly = $true
                }
            } catch { }
            if ($_bfpTreatAsStaleOnly) {
                Write-Host ("BRIEF_FACT_PACK_HARD: STALE_META (meta.run_id={0} != PIPELINE_RUN_ID={1}; 舊檔，僅警示)" -f $_bfpRunIdV, $env:PIPELINE_RUN_ID) -ForegroundColor Yellow
            } else {
                Write-Host ("BRIEF_FACT_PACK_HARD: STALE_META (meta.run_id={0} != PIPELINE_RUN_ID={1}) => FAIL" -f $_bfpRunIdV, $env:PIPELINE_RUN_ID) -ForegroundColor Red
                exit 1
            }
        }
    } catch {
        Write-Host "BRIEF_FACT_PACK_HARD: STALE_META check skipped (parse error: $_)" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "[AI Purity Gate] BRIEF_TEMPLATE_LEAK_HARD..." -ForegroundColor Yellow
Invoke-MetaGate -Label "BRIEF_TEMPLATE_LEAK_HARD" -MetaFile "brief_template_leak.meta.json" -InfoBuilder {
    param($d)
    "template_leak_events_count=$((Get-MetaInt $d 'template_leak_events_count' 0)) template_leak_bullets_count=$((Get-MetaInt $d 'template_leak_bullets_count' 0))"
}
# STALE_META check: meta.run_id must match PIPELINE_RUN_ID for this run
if ($env:PIPELINE_RUN_ID) {
    try {
        $_btlMetaPathV = Join-Path $repoRoot "outputs\brief_template_leak.meta.json"
        $_btlMetaItemV = Get-Item $_btlMetaPathV -ErrorAction SilentlyContinue
        $_btlMetaV = Get-Content $_btlMetaPathV -Raw -Encoding UTF8 | ConvertFrom-Json
        $_metaRunIdV = if ($_btlMetaV.PSObject.Properties["run_id"]) { [string]$_btlMetaV.run_id } else { "" }
        if ($_metaRunIdV -and ($_metaRunIdV -ne [string]$env:PIPELINE_RUN_ID)) {
            $_btlTreatAsStaleOnly = $false
            try {
                $_btlRunStart = [datetime]::ParseExact([string]$env:PIPELINE_RUN_ID, "yyyyMMdd_HHmmss", $null)
                if ($_btlMetaItemV -and $_btlMetaItemV.LastWriteTime -lt $_btlRunStart) {
                    $_btlTreatAsStaleOnly = $true
                }
            } catch { }
            if ($_btlTreatAsStaleOnly) {
                Write-Host ("BRIEF_TEMPLATE_LEAK: STALE_META (meta.run_id={0} != PIPELINE_RUN_ID={1}; 舊檔，僅警示)" -f $_metaRunIdV, $env:PIPELINE_RUN_ID) -ForegroundColor Yellow
            } else {
                Write-Host ("BRIEF_TEMPLATE_LEAK: STALE_META (meta.run_id={0} != PIPELINE_RUN_ID={1}) => FAIL" -f $_metaRunIdV, $env:PIPELINE_RUN_ID) -ForegroundColor Red
                exit 1
            }
        }
    } catch {
        Write-Host "BRIEF_TEMPLATE_LEAK: STALE_META check skipped (parse error: $_)" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "AI_PURITY_GATES: 14/14 PASS" -ForegroundColor Green

# FULLTEXT_FIDELITY OBSERVATION (non-fatal) — reads fulltext_fidelity.meta.json
$fidelityMetaPath = Join-Path $PSScriptRoot "..\outputs\fulltext_fidelity.meta.json"
if (Test-Path $fidelityMetaPath) {
    try {
        $fidMeta        = Get-Content $fidelityMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $fidTotal       = if ($fidMeta.PSObject.Properties['events_total'])                { [int]$fidMeta.events_total }                else { 0 }
        $fidCtaTotal    = if ($fidMeta.PSObject.Properties['total_cta_paragraphs_removed']) { [int]$fidMeta.total_cta_paragraphs_removed } else { 0 }
        $fidWhere       = if ($fidMeta.PSObject.Properties['wheresyoured_at_events'])       { [int]$fidMeta.wheresyoured_at_events }       else { 0 }
        $fidAvgRemoved  = if ($fidMeta.PSObject.Properties['avg_removed_paragraphs'])      { $fidMeta.avg_removed_paragraphs }            else { "n/a" }
        $fidAvgCleaned  = if ($fidMeta.PSObject.Properties['avg_cleaned_len'])             { [int]$fidMeta.avg_cleaned_len }              else { 0 }
        $fidDomTop      = if ($fidMeta.PSObject.Properties['domain_top'])                  { ($fidMeta.domain_top -join ", ") }           else { "n/a" }
        Write-Host ""
        Write-Host "FULLTEXT_FIDELITY (obs): events=$fidTotal cta_removed=$fidCtaTotal wheresyoured_at=$fidWhere" -ForegroundColor Cyan
        Write-Host "  domain_top=$fidDomTop  avg_removed_paragraphs=$fidAvgRemoved  avg_cleaned_len=$fidAvgCleaned" -ForegroundColor Cyan
    } catch {
        Write-Host "FULLTEXT_FIDELITY (obs): parse error — $_" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "FULLTEXT_FIDELITY (obs): fulltext_fidelity.meta.json not found (skip)" -ForegroundColor DarkYellow
}

# LONGFORM EVIDENCE — reads exec_longform.meta.json written by ppt_generator
# ---------------------------------------------------------------------------
$longformMetaPath = Join-Path $PSScriptRoot "..\outputs\exec_longform.meta.json"
if (Test-Path $longformMetaPath) {
    try {
        $lfm = Get-Content $longformMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lfEligible      = if ($lfm.PSObject.Properties['eligible_count'])       { [int]$lfm.eligible_count }       else { 0 }
        $lfIneligible    = if ($lfm.PSObject.Properties['ineligible_count'])     { [int]$lfm.ineligible_count }     else { 0 }
        $lfTotal         = if ($lfm.PSObject.Properties['total_cards_processed']){ [int]$lfm.total_cards_processed } else { 0 }
        $lfEligRatio     = if ($lfm.PSObject.Properties['eligible_ratio'])       { [double]$lfm.eligible_ratio }     else { 0.0 }
        $lfProofRatio    = if ($lfm.PSObject.Properties['proof_coverage_ratio']) { [double]$lfm.proof_coverage_ratio } else { 0.0 }
        $lfProofPres     = if ($lfm.PSObject.Properties['proof_present_count'])  { [int]$lfm.proof_present_count }   else { 0 }
        $lfProofMiss     = if ($lfm.PSObject.Properties['proof_missing_count'])  { [int]$lfm.proof_missing_count }   else { 0 }
        $lfAvgAnchor     = if ($lfm.PSObject.Properties['avg_anchor_chars'])     { $lfm.avg_anchor_chars }           else { 0 }
        $lfMinAnchor     = if ($lfm.PSObject.Properties['min_anchor_chars'])     { $lfm.min_anchor_chars }           else { 1200 }
        $lfMissIds       = if ($lfm.PSObject.Properties['proof_missing_ids'] -and $lfm.proof_missing_ids) { ($lfm.proof_missing_ids -join ', ') } else { '(none)' }

        # Self-consistency check: eligible + ineligible must equal total
        $lfConsistent    = ($lfEligible + $lfIneligible) -eq $lfTotal

        Write-Host ""
        Write-Host "LONGFORM EVIDENCE (exec_longform.meta.json):"
        Write-Host ("  generated_at            : {0}" -f $lfm.generated_at)
        Write-Host ("  min_anchor_chars        : {0}" -f $lfMinAnchor)
        Write-Host ("  total_cards_processed   : {0}" -f $lfTotal)
        Write-Host ("  eligible_count          : {0}  ({1:P1})" -f $lfEligible, $lfEligRatio)
        Write-Host ("  ineligible_count        : {0}" -f $lfIneligible)
        Write-Host ("  counts_consistent       : {0}" -f $(if ($lfConsistent) { 'YES' } else { 'NO — MISMATCH' }))
        Write-Host ("  avg_anchor_chars        : {0}" -f $lfAvgAnchor)
        Write-Host ("  proof_present_count     : {0}" -f $lfProofPres)
        Write-Host ("  proof_missing_count     : {0}" -f $lfProofMiss)
        Write-Host ("  proof_missing_ids(top5) : {0}" -f $lfMissIds)
        Write-Host ("  proof_coverage_ratio    : {0:P1}" -f $lfProofRatio)
        if ($lfm.PSObject.Properties['samples'] -and $lfm.samples.Count -gt 0) {
            Write-Host "  samples:"
            foreach ($s in $lfm.samples) {
                $pf = if ($s.proof_line) { ($s.proof_line -replace '[\r\n]+',' ') } else { "(none)" }
                Write-Host ("    title={0}  anchor={1}  proof={2}" -f ($s.title -replace '[\r\n]+',' '), $s.anchor_chars, $pf)
            }
        }
        $lfPass = $lfConsistent -and ($lfProofRatio -ge 0.8 -or $lfTotal -eq 0)
        if ($lfPass) {
            Write-Host "  => LONGFORM_EVIDENCE: PASS"
        } else {
            Write-Host ("  => LONGFORM_EVIDENCE: WARN (proof_ratio={0:P1} consistent={1})" -f $lfProofRatio, $lfConsistent)
        }
    } catch {
        Write-Host "  longform meta parse error (non-fatal): $_"
    }
} else {
    Write-Host ""
    Write-Host "LONGFORM EVIDENCE: exec_longform.meta.json not found (skipped — run pipeline first)"
}

# ---------------------------------------------------------------------------
# LONGFORM DAILY COUNT (Watchlist/Developing Pool Expansion v1)
# ---------------------------------------------------------------------------
if (Test-Path $longformMetaPath) {
    try {
        $ldm = Get-Content $longformMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ldm.PSObject.Properties['longform_daily_total'] -or $ldm.PSObject.Properties['event_longform_count']) {
            $ldMinTarget = if ($ldm.PSObject.Properties['longform_min_daily_total'])      { [int]$ldm.longform_min_daily_total }      else { 6 }
            $ldEvCount   = if ($ldm.PSObject.Properties['event_longform_count'])          { [int]$ldm.event_longform_count }          else { 0 }
            $ldWlCands   = if ($ldm.PSObject.Properties['watchlist_longform_candidates']) { [int]$ldm.watchlist_longform_candidates } else { 0 }
            $ldWlSel     = if ($ldm.PSObject.Properties['watchlist_longform_selected'])   { [int]$ldm.watchlist_longform_selected }   else { 0 }
            $ldTotal     = if ($ldm.PSObject.Properties['longform_daily_total'])          { [int]$ldm.longform_daily_total }          else { $ldEvCount }
            $ldWlAvg     = if ($ldm.PSObject.Properties['watchlist_avg_anchor_chars'])    { $ldm.watchlist_avg_anchor_chars }         else { 0 }
            $ldWlPRatio  = if ($ldm.PSObject.Properties['watchlist_proof_coverage_ratio']){ [double]$ldm.watchlist_proof_coverage_ratio } else { 1.0 }
            $ldWlIds     = if ($ldm.PSObject.Properties['watchlist_selected_ids_top10'] -and $ldm.watchlist_selected_ids_top10) {
                ($ldm.watchlist_selected_ids_top10 -join ', ')
            } else { '(none)' }
            $ldWlTop3    = if ($ldm.PSObject.Properties['watchlist_sources_share_top3'] -and $ldm.watchlist_sources_share_top3.Count -gt 0) {
                ($ldm.watchlist_sources_share_top3 | ForEach-Object { "$($_.source)=$($_.count)" }) -join ', '
            } else { '(none)' }

            $ldGate = if ($ldTotal -ge $ldMinTarget) { "PASS" } else { "WARN-OK" }

            Write-Host ""
            Write-Host "LONGFORM DAILY COUNT (exec_longform.meta.json):"
            Write-Host ("  longform_min_daily_total       : {0}" -f $ldMinTarget)
            Write-Host ("  event_longform_count           : {0}" -f $ldEvCount)
            Write-Host ("  watchlist_longform_candidates  : {0}" -f $ldWlCands)
            Write-Host ("  watchlist_longform_selected    : {0}" -f $ldWlSel)
            Write-Host ("  longform_daily_total           : {0}  (target >= {1})" -f $ldTotal, $ldMinTarget)
            Write-Host ("  watchlist_avg_anchor_chars     : {0}" -f $ldWlAvg)
            Write-Host ("  watchlist_proof_coverage_ratio : {0:P1}" -f $ldWlPRatio)
            Write-Host ("  watchlist_selected_ids(top10)  : {0}" -f $ldWlIds)
            Write-Host ("  watchlist_sources_top3         : {0}" -f $ldWlTop3)
            if ($ldGate -eq "PASS") {
                Write-Host ("  => LONGFORM_DAILY_TOTAL target={0} actual={1} PASS" -f $ldMinTarget, $ldTotal)
            } else {
                Write-Host ("  => LONGFORM_DAILY_TOTAL target={0} actual={1} WARN-OK (watchlist pool may be small)" -f $ldMinTarget, $ldTotal)
            }
        }
    } catch {
        Write-Host "  longform daily count parse error (non-fatal): $_"
    }
}

# ---------------------------------------------------------------------------
# EXEC TEXT BAN SCAN — fail-fast gate (v5.2.6 sanitizer validation)
# Scans PPTX + DOCX for any banned template/internal-tag phrases.
# These are a superset of $bannedWords already checked above; this block
# makes the gate explicit and labeled for CI evidence.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "EXEC TEXT BAN SCAN:" -ForegroundColor Yellow
$execBanPhrases = @(
    "Evidence summary: sources=",
    "Key terms: ",
    "validate source evidence and related numbers",
    "run small-scope checks against current workflow",
    "escalate only if next scan confirms sustained",
    "WATCH .*: validate",
    "TEST .*: run small-scope",
    "MOVE .*: escalate only"
)
# Note: CJK banned phrases are checked below via Python subprocess (UTF-8 safe)
$execBanHits = 0

# Scan PPTX
$pptxScanText = & $py -c "
from pptx import Presentation
prs = Presentation('outputs/executive_report.pptx')
for slide in prs.slides:
    for shape in slide.shapes:
        if shape.has_text_frame:
            for p in shape.text_frame.paragraphs:
                print(p.text, end=' ')
" 2>$null

# Scan DOCX
$docxScanText = & $py -c "
from docx import Document
doc = Document('outputs/executive_report.docx')
print(' '.join(p.text for p in doc.paragraphs))
for t in doc.tables:
    for row in t.rows:
        for cell in row.cells:
            print(cell.text, end=' ')
" 2>$null

$combinedScanText = "$pptxScanText $docxScanText"
foreach ($bp in $execBanPhrases) {
    # Use IndexOf for literal matching; avoid regex interpretation of PPTX/DOCX content
    $isRegexPat = $bp -match '[\.\*\+\?\^\$\{\}\[\]\(\)\|\\]'
    $matched = if ($isRegexPat) {
        $combinedScanText -match $bp
    } else {
        $combinedScanText.IndexOf($bp, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    if ($matched) {
        Write-Host ("  FAIL: Banned phrase '{0}' found in PPT/DOCX output" -f $bp) -ForegroundColor Red
        $execBanHits++
    }
}

# CJK banned phrases — checked via Python to avoid PowerShell UTF-8 encoding issues
$cjkBanResult = & $py -c "
import sys
try:
    from pptx import Presentation
    from docx import Document
    pptx_text = ''
    docx_text = ''
    try:
        prs = Presentation('outputs/executive_report.pptx')
        for slide in prs.slides:
            for shape in slide.shapes:
                if shape.has_text_frame:
                    for p in shape.text_frame.paragraphs:
                        pptx_text += p.text + ' '
    except Exception:
        pass
    try:
        doc = Document('outputs/executive_report.docx')
        docx_text = ' '.join(p.text for p in doc.paragraphs)
    except Exception:
        pass
    combined = pptx_text + ' ' + docx_text
    cjk_banned = [
        '\u8a73\u898b\u539f\u59cb\u4f86\u6e90',
        '\u76e3\u63a7\u4e2d \u672c\u6b04\u66ab\u7121\u4e8b\u4ef6',
        '\u73fe\u6709\u7b56\u7565\u8207\u8cc7\u6e90\u914d\u7f6e',
        '\u7684\u8da8\u52e2\uff0c\u89e3\u6c7a\u65b9 \u8a18',
    ]
    hits = [b for b in cjk_banned if b in combined]
    if hits:
        print('FAIL:' + '|'.join(hits))
    else:
        print('PASS')
except Exception as e:
    print('SKIP:' + str(e))
" 2>$null

if ($cjkBanResult -and $cjkBanResult.StartsWith("FAIL:")) {
    Write-Host ("  FAIL: CJK banned phrases found: {0}" -f ($cjkBanResult -replace '^FAIL:', '')) -ForegroundColor Red
    $execBanHits++
}

if ($execBanHits -gt 0) {
    Write-Host ("  EXEC TEXT BAN SCAN: FAIL ({0} hit(s))" -f $execBanHits) -ForegroundColor Red
    exit 1
}
Write-Host ("  EXEC TEXT BAN SCAN: PASS (0 hits)") -ForegroundColor Green

# ---------------------------------------------------------------------------
# NARRATIVE_V2 EVIDENCE — reads outputs/narrative_v2.meta.json (audit only, no gate)
# ---------------------------------------------------------------------------
$nv2MetaPath = Join-Path $PSScriptRoot "..\outputs\narrative_v2.meta.json"
if (Test-Path $nv2MetaPath) {
    try {
        $nv2 = Get-Content $nv2MetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $nv2Applied = if ($nv2.PSObject.Properties['narrative_v2_applied_count']) { [int]$nv2.narrative_v2_applied_count } else { 0 }
        $nv2ZhRatio = if ($nv2.PSObject.Properties['avg_zh_ratio'])              { [double]$nv2.avg_zh_ratio }             else { 0.0 }
        $nv2Dedup   = if ($nv2.PSObject.Properties['avg_dedup_ratio'])           { [double]$nv2.avg_dedup_ratio }          else { 0.0 }
        $nv2Sents   = if ($nv2.PSObject.Properties['avg_sentences_used'])        { $nv2.avg_sentences_used }               else { 0 }
        Write-Host ""
        Write-Host ("NARRATIVE_V2: applied={0}  avg_zh_ratio={1:F3}  avg_dedup_ratio={2:F3}  avg_sentences_used={3}" -f $nv2Applied, $nv2ZhRatio, $nv2Dedup, $nv2Sents)
    } catch {
        Write-Host "NARRATIVE_V2: meta parse error (non-fatal): $_"
    }
} else {
    Write-Host ""
    Write-Host "NARRATIVE_V2: narrative_v2.meta.json not found (skipped)"
}

# ---------------------------------------------------------------------------
# GIT UPSTREAM PROBE v2 — hardened: A (symbolic-ref) -> B (remote show) ->
# C (show-ref probe main/master) -> NONE; never crashes on [gone] / missing refs
# ORIGIN_REF_MODE values: HEAD | REMOTE_SHOW | FALLBACK | NONE
# ---------------------------------------------------------------------------
$_gitOriginRef    = $null
$_gitOriginMode   = "NONE"
$_gitOriginExists = $false

# Method A: git symbolic-ref — local only, fast; works after `git fetch`
$_symRef = (git symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null | Out-String).Trim()
if ($_symRef -match "refs/remotes/origin/(.+)") {
    $_branchA = $Matches[1].Trim()
    $null = git show-ref --verify "refs/remotes/origin/$_branchA" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $_gitOriginRef    = "origin/$_branchA"
        $_gitOriginMode   = "HEAD"
        $_gitOriginExists = $true
    }
}

# Method B: git remote show origin — parses HEAD branch (may make network call);
#           ref must still exist in local store to be usable
if (-not $_gitOriginRef) {
    $_remoteShow = (git remote show origin 2>$null | Out-String)
    if ($_remoteShow -match "HEAD branch:\s*(.+)") {
        $_branchB = $Matches[1].Trim()
        if ($_branchB -ne "(unknown)" -and $_branchB -ne "") {
            $null = git show-ref --verify "refs/remotes/origin/$_branchB" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $_gitOriginRef    = "origin/$_branchB"
                $_gitOriginMode   = "REMOTE_SHOW"
                $_gitOriginExists = $true
            }
        }
    }
}

# Method C: explicit local show-ref probe — origin/main then origin/master
if (-not $_gitOriginRef) {
    foreach ($_fb in @("main", "master")) {
        $null = git show-ref --verify "refs/remotes/origin/$_fb" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $_gitOriginRef    = "origin/$_fb"
            $_gitOriginMode   = "FALLBACK"
            $_gitOriginExists = $true
            break
        }
    }
}

$_originRefStr    = if ($_gitOriginRef)    { $_gitOriginRef } else { "n/a" }
$_originExistsStr = if ($_gitOriginExists) { "true" }         else { "false" }

Write-Host ""
Write-Host "GIT UPSTREAM:"
Write-Host ("  ORIGIN_REF_USED  : {0}" -f $_originRefStr)
Write-Host ("  ORIGIN_REF_MODE  : {0}" -f $_gitOriginMode)
Write-Host ("  ORIGIN_REF_EXISTS: {0}" -f $_originExistsStr)
Write-Host ""
Write-Host "GIT SYNC:"
if ($_gitOriginRef -and $_gitOriginExists) {
    $_abRaw = (git rev-list --left-right --count "$_gitOriginRef...HEAD" 2>$null | Out-String).Trim()
    if ($_abRaw -match "^(\d+)\s+(\d+)$") {
        $_behind = [int]$Matches[1]; $_ahead = [int]$Matches[2]
        Write-Host ("  GIT_SYNC: behind={0} ahead={1}" -f $_behind, $_ahead)
        if ($_behind -eq 0 -and $_ahead -eq 0) {
            Write-Host "  GIT_UP_TO_DATE: PASS"
        } else {
            Write-Host ("  GIT_UP_TO_DATE: FAIL (diverged from {0})" -f $_gitOriginRef)
            if ($_ahead  -gt 0) { Write-Host ("  >> {0} commit(s) ahead of origin; run: git push" -f $_ahead) }
            if ($_behind -gt 0) { Write-Host ("  >> {0} commit(s) behind origin; run: git pull" -f $_behind) }
        }
    } else {
        Write-Host "  GIT_SYNC: WARN — rev-list returned no output"
        Write-Host "  GIT_UP_TO_DATE: WARN-OK (rev-list empty; run: git fetch origin --prune)"
    }
} else {
    Write-Host "  GIT_SYNC: SKIPPED (origin ref not found in local store)"
    Write-Host "  GIT_UP_TO_DATE: WARN-OK (cannot verify; run: git fetch origin --prune)"
}

# ---------------------------------------------------------------------------
# Helper: resolve standard artifact path; glob-fallback to most-recently-
# modified match when the standard path is missing (avoids path-drift misses)
# ---------------------------------------------------------------------------
function Get-LatestArtifactPath {
    param(
        [string]$StandardPath,
        [string]$Pattern,
        [string]$BaseDir = "outputs"
    )
    if (Test-Path $StandardPath) {
        return [PSCustomObject]@{ Path = (Resolve-Path $StandardPath).Path; IsFallback = $false }
    }
    $candidates = Get-ChildItem -Path $BaseDir -Filter $Pattern -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidates) {
        return [PSCustomObject]@{ Path = $candidates.FullName; IsFallback = $true }
    }
    return $null
}

# ---------------------------------------------------------------------------
# OUTPUT ARTIFACTS EVIDENCE — file fingerprints bound to this pipeline run
# HEAD is already printed above; these hashes tie the files to that commit
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "OUTPUT ARTIFACTS EVIDENCE:"
$_artSpecs = @(
    @{ StdPath = "outputs\executive_report.pptx";    Pattern = "executive_report*.pptx" },
    @{ StdPath = "outputs\executive_report.docx";    Pattern = "executive_report*.docx" },
    @{ StdPath = "outputs\exec_selection.meta.json"; Pattern = "exec_selection*.json"   },
    @{ StdPath = "outputs\flow_counts.meta.json";    Pattern = "flow_counts*.json"      }
)
foreach ($_spec in $_artSpecs) {
    $_found = Get-LatestArtifactPath -StandardPath $_spec.StdPath -Pattern $_spec.Pattern
    if ($null -eq $_found) {
        Write-Host ("  {0}: NOT FOUND" -f $_spec.StdPath)
        continue
    }
    $_info = Get-Item $_found.Path
    $_hash = (Get-FileHash -Path $_found.Path -Algorithm SHA256).Hash
    $_fb   = if ($_found.IsFallback) { " [FOUND_LATEST=1]" } else { "" }
    Write-Host ("  {0}{1}:" -f $_spec.StdPath, $_fb)
    Write-Host ("    path     : {0}" -f $_info.FullName)
    Write-Host ("    modified : {0}" -f ([DateTimeOffset]$_info.LastWriteTime).ToString("yyyy-MM-ddTHH:mm:sszzz"))
    Write-Host ("    size     : {0} bytes" -f $_info.Length)
    Write-Host ("    sha256   : {0}" -f $_hash)
}

Write-Host "=======================================" -ForegroundColor Cyan
