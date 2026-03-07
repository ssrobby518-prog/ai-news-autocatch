# iter59b Evidence Pack — Normal/Stress Cross-Proof (full SHA-256, no placeholders)

run_date: 2026-03-07
變更檔案: report.md (evidence only; no code change)

## Section A — Git

```
> git diff --name-only
（空白）

> git status -sb
## main...origin/main

> git rev-list --left-right --count origin/main...HEAD
0	0
```

## Section B — Normal Run (soft_warning_no_switch / triggered=false)

### Canonical Outputs

NOTE: canonical outputs 目前被後續 stress run 覆寫（run_id=20260307_143251）。
Normal run 證據保存於 delivery_dir（見下方交叉驗證）。

### Delivery Dir 交叉驗證（Normal）

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_142616_b9e6c17ed8c6b8d578887c7f167e16621e67675d\LAST_RUN_SUMMARY.txt
run_id              = 20260307_142448
started_at          = 2026-03-07T14:26:17.1214716-08:00
finished_at         = 2026-03-07T14:26:17.1214716-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_142616_b9e6c17ed8c6b8d578887c7f167e16621e67675d\gpu_load.meta.json
{
    "run_id":  "20260307_142448",
    "vram_used_mb":  5419,
    "vram_total_mb":  8188,
    "vram_ratio":  0.6618,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "soft_warning",
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stress_reason":  "non_llama=2>=1 but vram_ratio=0.6618<0.7 -> soft warning only",
    "test_injected":  false,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:24:48.7503840-08:00"
}
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_142616_b9e6c17ed8c6b8d578887c7f167e16621e67675d\delivery_consistency.meta.json
{
    "run_id":  "20260307_142448",
    "verified_at":  "2026-03-07T14:26:17.4869788-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "5be5770ce6958615b0a7ddee5b8960009532bff5361424331cd4a9b8651041ee",
            "length":  7592,
            "last_write":  "2026-03-07T14:26:17.2057499-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "10b3b641133f2b523a756fe013a9aec4ea02e27d391105301a715d1788f8538a",
            "length":  40141,
            "last_write":  "2026-03-07T14:26:13.3190038-08:00"
        }
    ],
    "same_run_verified":  true
}
```

## Section C — Stress Run (stress_600_vram_busy / triggered=true)

### Canonical Outputs

```
> type outputs\LAST_RUN_SUMMARY.txt
run_id              = 20260307_143251
started_at          = 2026-03-07T14:34:20.4456608-08:00
finished_at         = 2026-03-07T14:34:20.4456608-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

```
> type outputs\gpu_load.meta.json
{
    "run_id":  "20260307_143251",
    "vram_used_mb":  5435,
    "vram_total_mb":  8188,
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "vram_busy",
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_reason":  "vram_ratio=0.9000>=0.85 OR used=5435MB>=total-900=7288MB",
    "test_injected":  true,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:32:51.7779502-08:00"
}
```

```
> type outputs\delivery_consistency.meta.json
{
    "run_id":  "20260307_143251",
    "verified_at":  "2026-03-07T14:34:20.8208543-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "193576c8e14bce65216ec53c0a65e149161287a4e356f07da06c2c6c0a915175",
            "length":  7608,
            "last_write":  "2026-03-07T14:34:20.5667656-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "8e656cde957c931801d3c6fb865e437989b33ea16af7c22336ed759fa3c142ae",
            "length":  40071,
            "last_write":  "2026-03-07T14:34:16.5025823-08:00"
        }
    ],
    "same_run_verified":  true
}
```

```
> powershell -NoProfile -Command "Get-Item outputs\latest_brief.md, outputs\executive_report.docx | Select Name,LastWriteTime,Length | Format-Table -AutoSize"
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 2:34:20 PM   7608
executive_report.docx 3/7/2026 2:34:16 PM  40071
```

### Delivery Dir 交叉驗證（Stress）

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_143419_b9e6c17ed8c6b8d578887c7f167e16621e67675d\LAST_RUN_SUMMARY.txt
run_id              = 20260307_143251
started_at          = 2026-03-07T14:34:20.4456608-08:00
finished_at         = 2026-03-07T14:34:20.4456608-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_143419_b9e6c17ed8c6b8d578887c7f167e16621e67675d\gpu_load.meta.json
{
    "run_id":  "20260307_143251",
    "vram_used_mb":  5435,
    "vram_total_mb":  8188,
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "vram_busy",
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_reason":  "vram_ratio=0.9000>=0.85 OR used=5435MB>=total-900=7288MB",
    "test_injected":  true,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:32:51.7779502-08:00"
}
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_143419_b9e6c17ed8c6b8d578887c7f167e16621e67675d\delivery_consistency.meta.json
{
    "run_id":  "20260307_143251",
    "verified_at":  "2026-03-07T14:34:20.8208543-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "193576c8e14bce65216ec53c0a65e149161287a4e356f07da06c2c6c0a915175",
            "length":  7608,
            "last_write":  "2026-03-07T14:34:20.5667656-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "8e656cde957c931801d3c6fb865e437989b33ea16af7c22336ed759fa3c142ae",
            "length":  40071,
            "last_write":  "2026-03-07T14:34:16.5025823-08:00"
        }
    ],
    "same_run_verified":  true
}
```

## Section D — Push/Commit

```
> git log --oneline -3
(after push)

> git rev-list --left-right --count origin/main...HEAD
0	0
```
