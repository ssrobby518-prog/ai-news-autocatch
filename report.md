# iter62: Evidence Hardening — git logs + all-miss daily + docx timestamp proof

run_date: 2026-03-07

## Section A — Git 狀態 + 歷史

### Step 0 — 乾淨確認

```
> git diff --name-only
（空白）

> git status -sb
## main...origin/main

> git rev-list --left-right --count origin/main...HEAD
0	0
```

### git log --oneline -12

```
d6c254e iter61: progress report (auto-pick normal/stress delivery_dir; full sha256; no placeholders; no behavior change)
65d1810 iter60: evidence pack — normal+stress canonical & delivery_dir cross-proof (full sha256, no placeholders)
a7ab743 iter59b: harden evidence (no ellipsis sha256; no <DIR> placeholders; normal+stress delivery_dir cross-proof)
ff0a438 iter59: update report.md Section D with final push evidence
d7a6271 iter59: evidence pack — normal/stress cross-proof with delivery meta archive
b9e6c17 iter59: archive gpu_load + delivery_consistency + LAST_RUN_SUMMARY into delivery_dir for cross-proof
7c428af iter58: update Section D with push evidence
d4c47cc iter58: evidence pack — SHA-256 delivery consistency proof + soft_warning_no_switch naming
36f42cb iter58: SHA-256 delivery consistency proof + stress_mode_name soft_warning_no_switch
0ec7226 iter57: update Section D with push evidence
491fa0c iter57: evidence pack — normal 175/110 success + stress 600/300 success (two-tier trigger semantics)
7611dc6 iter57: fix DAILY budget=175 propagation + two-tier stress trigger
```

### Per-file log: scripts/run_once.py + scripts/verify_online.ps1

```
b9e6c17 iter59: archive gpu_load + delivery_consistency + LAST_RUN_SUMMARY into delivery_dir for cross-proof
36f42cb iter58: SHA-256 delivery consistency proof + stress_mode_name soft_warning_no_switch
7611dc6 iter57: fix DAILY budget=175 propagation + two-tier stress trigger
0102aa6 iter57: make STRESS_600 trigger semantics strict (VRAM busy vs contention)
94b729f iter56: add VRAM-busy auto STRESS_600_MODE + GPU warmup stabilization
f79b1be iter55: Z0 drain cap enforcement + jitter epsilon + translation_engine stub + timestamp coherence
ffebc6a iter55: fix Z0 inflight drain cap + wallclock jitter epsilon
0d2c08c iter54e: DOCX write directly to final path — avoid shutil.move WinError 32
291db4f iter54e: fix DOCX WinError 32 — release python-docx lock before shutil.move
e12ffcc iter54e: fix diversity swap + hydration diversity injection for DAILY
7601acd iter54e: fix GitHub vendor classification
445e209 iter54d: include bigtech code_release in DAILY_BIGTECH_ONLY scope
a3c73a9 iter54: harden DAILY 110/170 + DAILY_BIGTECH_ONLY_HARD + docx atomic replace + z0 wallclock cap
```

### Per-file log: scripts/verify_run.ps1 + utils/fulltext_hydrator.py

```
4664a4a iter46: dev-forum de-prioritize + high-value-only exception
bfb2471 iter42b: forbid pptx outputs — pre-clean + generation block + PPTX_FORBIDDEN_HARD gate
9bdc889 iter42: DAILY soft160 hard200 + remove PPTX everywhere + stage deadlines
dbecaf4 feat(iter33): md+docx only, 600s hard cap, targeted hydration
f7f7c3c fix(iter26): shutdown(wait=False) in hydrate_items_batch
6e2da5e fix(iter26): use env vars for CJK-safe Python path passing in verify_run.ps1
```

## Section B — DAILY 成功（正常路徑，cache-hit）

### 命令

```
Remove-Item Env:INJECT_DEV_FORUM_LOW_VALUE -ErrorAction SilentlyContinue
Remove-Item Env:TRANSLATION_CACHE_BYPASS -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

### LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_153003
started_at          = 2026-03-07T15:31:22.3165126-08:00
finished_at         = 2026-03-07T15:31:22.3165126-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### run_timing.meta.json

```json
{
    "run_id":  "20260307_153003",
    "total_seconds":  79,
    "time_budget_seconds":  175,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  false,
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stage_seconds":  {
        "z0_collect_online":  56,
        "before_translation":  9.2,
        "translate":  0,
        "hydrate":  9,
        "build_docx":  0.2,
        "gates":  1
    }
}
```

### translation_engine.meta.json

```json
{
    "run_id": "20260307_153003",
    "calls_total": 0,
    "cache_hit": 7,
    "cache_miss": 0,
    "translate_mode": "all_cache_hit",
    "translate_seconds": 0.02,
    "est_total_seconds_if_all_miss": 151,
    "tok_per_sec_est": 23.16
}
```

### selection_audit.meta.json（摘要）

- selected_items_count: 7
- bigtech_hit_count: 7
- official_or_media_count: 7
- selected_domains_distinct: 5 (blog.research.google, huggingface.co, techcrunch.com, inside.com.tw, ithome.com.tw)
- selected_vendors_distinct: 4 (Google, HuggingFace, NVIDIA, Amazon)
- diversity_pass: true

### bigtech_diversity.meta.json

- domains>=4: 5 PASS
- max_domain<=2: 2 PASS
- vendors>=4: 4 PASS
- max_vendor<=3: 3 PASS
- pass: true

### DOCX/MD 時戳一致性

```
> Get-Item outputs\latest_brief.md, outputs\executive_report.docx | Select Name,LastWriteTime,Length | Format-Table -AutoSize
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 3:31:22 PM   7589
executive_report.docx 3/7/2026 3:31:19 PM  40141
```

核對：executive_report.docx LastWriteTime (3:31:19) 早於 latest_brief.md (3:31:22) — 兩者同 run，DOCX 在 MD 之前生成（正常流程）。DELIVERABLE_TIMESTAMP_COHERENCE: PASS。

### PPTX

```
> dir outputs\*.pptx
（空白 — 0 個 pptx）
```

## Section C — All-miss 模擬（TRANSLATION_CACHE_BYPASS=1）

### 命令

```
$env:TRANSLATION_CACHE_BYPASS="1"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

### LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_153148
started_at          = 2026-03-07T15:34:00.7052640-08:00
finished_at         = 2026-03-07T15:34:00.7052640-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### run_timing.meta.json

```json
{
    "run_id":  "20260307_153148",
    "total_seconds":  133,
    "time_budget_seconds":  175,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  true,
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stage_seconds":  {
        "z0_collect_online":  60,
        "before_translation":  10.4,
        "translate":  49.7,
        "hydrate":  10.2,
        "build_docx":  0.3,
        "gates":  1
    }
}
```

### translation_engine.meta.json

```json
{
    "run_id": "20260307_153148",
    "calls_total": 7,
    "calls_success": 7,
    "calls_timeout": 0,
    "calls_error": 0,
    "cache_hit": 0,
    "cache_miss": 7,
    "translate_mode": "all_miss",
    "translate_seconds": 49.71,
    "tok_per_sec_est": 26.37,
    "tok_s_min": 25.67,
    "tok_s_avg": 30.19,
    "tok_s_max": 40.59,
    "est_total_seconds_if_all_miss": 133
}
```

### 核對

- translate_mode = all_miss（非 cache-hit）
- cache_miss = 7 > 0
- total_seconds = 133 <= 175 (hard PASS)
- soft_target_exceeded = true (133 > 110; 已知 all-miss 路徑超 soft 屬預期)

## Section D — Commit/Push

```
> git log --oneline -3
b3efcfd iter62: evidence hardening — git logs + all-miss daily + docx timestamp proof
d6c254e iter61: progress report (auto-pick normal/stress delivery_dir; full sha256; no placeholders; no behavior change)
65d1810 iter60: evidence pack — normal+stress canonical & delivery_dir cross-proof (full sha256, no placeholders)

> git rev-list --left-right --count origin/main...HEAD
0	0
```
