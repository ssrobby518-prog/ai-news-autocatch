# iter60 Evidence Pack — Normal+Stress Canonical & Delivery Dir Cross-Proof

run_date: 2026-03-07
變更檔案: report.md (evidence only; no code change)

## Section A — Git（commit 前）

```
> git diff --name-only
（空白）

> git status -sb
## main...origin/main

> git rev-list --left-right --count origin/main...HEAD
0	0
```

## Section B — Normal Run（soft_warning_no_switch / triggered=false）

### Canonical Outputs

```
> type outputs\LAST_RUN_SUMMARY.txt
run_id              = 20260307_144836
started_at          = 2026-03-07T14:49:53.7747213-08:00
finished_at         = 2026-03-07T14:49:53.7747213-08:00
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
    "run_id":  "20260307_144836",
    "vram_used_mb":  5382,
    "vram_total_mb":  8188,
    "vram_ratio":  0.6573,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "soft_warning",
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stress_reason":  "non_llama=2>=1 but vram_ratio=0.6573<0.7 -> soft warning only",
    "test_injected":  false,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:48:36.9190431-08:00"
}
```

```
> type outputs\delivery_consistency.meta.json
{
    "run_id":  "20260307_144836",
    "verified_at":  "2026-03-07T14:49:54.1368784-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "ea7a5203ab44ade49b88a404bec7e76d229be3a39d395d43cfbba9e1ef714ccf",
            "length":  7591,
            "last_write":  "2026-03-07T14:49:53.8802474-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "6fece1bd232015fa8dde3f7c9d70e22adc1e06d65ca92fb8b96ed39a2b60a56b",
            "length":  40142,
            "last_write":  "2026-03-07T14:49:49.9237551-08:00"
        }
    ],
    "same_run_verified":  true
}
```

```
> powershell -NoProfile -Command "Get-Item outputs\latest_brief.md, outputs\executive_report.docx | Select Name,LastWriteTime,Length | Format-Table -AutoSize"
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 2:49:53 PM   7591
executive_report.docx 3/7/2026 2:49:49 PM  40142
```

### Delivery Dir 交叉驗證（Normal）

```
> powershell -NoProfile -Command "Get-ChildItem outputs\deliveries -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 5 FullName,LastWriteTime | Format-Table -AutoSize"
20260307_144953_a7ab743ca6c38635112783a7264f6bce238f97e8  (最新 = Normal)
20260307_143419_b9e6c17ed8c6b8d578887c7f167e16621e67675d
20260307_142616_b9e6c17ed8c6b8d578887c7f167e16621e67675d
20260307_135651_36f42cbc1aa1226a04831babe82beb691a845d6c
20260307_135510_36f42cbc1aa1226a04831babe82beb691a845d6c
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_144953_a7ab743ca6c38635112783a7264f6bce238f97e8\LAST_RUN_SUMMARY.txt
run_id              = 20260307_144836
started_at          = 2026-03-07T14:49:53.7747213-08:00
finished_at         = 2026-03-07T14:49:53.7747213-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_144953_a7ab743ca6c38635112783a7264f6bce238f97e8\gpu_load.meta.json
{
    "run_id":  "20260307_144836",
    "vram_used_mb":  5382,
    "vram_total_mb":  8188,
    "vram_ratio":  0.6573,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "soft_warning",
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stress_reason":  "non_llama=2>=1 but vram_ratio=0.6573<0.7 -> soft warning only",
    "test_injected":  false,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:48:36.9190431-08:00"
}
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_144953_a7ab743ca6c38635112783a7264f6bce238f97e8\delivery_consistency.meta.json
{
    "run_id":  "20260307_144836",
    "verified_at":  "2026-03-07T14:49:54.1368784-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "ea7a5203ab44ade49b88a404bec7e76d229be3a39d395d43cfbba9e1ef714ccf",
            "length":  7591,
            "last_write":  "2026-03-07T14:49:53.8802474-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "6fece1bd232015fa8dde3f7c9d70e22adc1e06d65ca92fb8b96ed39a2b60a56b",
            "length":  40142,
            "last_write":  "2026-03-07T14:49:49.9237551-08:00"
        }
    ],
    "same_run_verified":  true
}
```

## Section C — Stress Run（stress_600_vram_busy / triggered=true）

### Canonical Outputs

```
> type outputs\LAST_RUN_SUMMARY.txt
run_id              = 20260307_145024
started_at          = 2026-03-07T14:51:52.7969830-08:00
finished_at         = 2026-03-07T14:51:52.7969830-08:00
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
    "run_id":  "20260307_145024",
    "vram_used_mb":  5447,
    "vram_total_mb":  8188,
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "vram_busy",
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_reason":  "vram_ratio=0.9000>=0.85 OR used=5447MB>=total-900=7288MB",
    "test_injected":  true,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:50:25.1224815-08:00"
}
```

```
> type outputs\delivery_consistency.meta.json
{
    "run_id":  "20260307_145024",
    "verified_at":  "2026-03-07T14:51:53.0751262-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "709146d7396f8230cb447ad7e1466e2c4502a7a634ffd8a5ebf658e956082a25",
            "length":  7608,
            "last_write":  "2026-03-07T14:51:52.8818475-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "11992465200e9a0385724f5e838b97debcd41acc1ca3f196062420c151cb8011",
            "length":  40072,
            "last_write":  "2026-03-07T14:51:49.3887360-08:00"
        }
    ],
    "same_run_verified":  true
}
```

```
> powershell -NoProfile -Command "Get-Item outputs\latest_brief.md, outputs\executive_report.docx | Select Name,LastWriteTime,Length | Format-Table -AutoSize"
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 2:51:52 PM   7608
executive_report.docx 3/7/2026 2:51:49 PM  40072
```

### Delivery Dir 交叉驗證（Stress）

```
> powershell -NoProfile -Command "Get-ChildItem outputs\deliveries -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 5 FullName,LastWriteTime | Format-Table -AutoSize"
20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8  (最新 = Stress)
20260307_144953_a7ab743ca6c38635112783a7264f6bce238f97e8
20260307_143419_b9e6c17ed8c6b8d578887c7f167e16621e67675d
20260307_142616_b9e6c17ed8c6b8d578887c7f167e16621e67675d
20260307_135651_36f42cbc1aa1226a04831babe82beb691a845d6c
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8\LAST_RUN_SUMMARY.txt
run_id              = 20260307_145024
started_at          = 2026-03-07T14:51:52.7969830-08:00
finished_at         = 2026-03-07T14:51:52.7969830-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8\gpu_load.meta.json
{
    "run_id":  "20260307_145024",
    "vram_used_mb":  5447,
    "vram_total_mb":  8188,
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "vram_busy",
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_reason":  "vram_ratio=0.9000>=0.85 OR used=5447MB>=total-900=7288MB",
    "test_injected":  true,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    },
    "detected_at":  "2026-03-07T14:50:25.1224815-08:00"
}
```

```
> type C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8\delivery_consistency.meta.json
{
    "run_id":  "20260307_145024",
    "verified_at":  "2026-03-07T14:51:53.0751262-08:00",
    "deliverables":  [
        {
            "file":  "latest_brief.md",
            "sha256":  "709146d7396f8230cb447ad7e1466e2c4502a7a634ffd8a5ebf658e956082a25",
            "length":  7608,
            "last_write":  "2026-03-07T14:51:52.8818475-08:00"
        },
        {
            "file":  "executive_report.docx",
            "sha256":  "11992465200e9a0385724f5e838b97debcd41acc1ca3f196062420c151cb8011",
            "length":  40072,
            "last_write":  "2026-03-07T14:51:49.3887360-08:00"
        }
    ],
    "same_run_verified":  true
}
```

## Section D — Push/Commit 可核對性

```
> git log --oneline -3
(after push)

> git rev-list --left-right --count origin/main...HEAD
0	0
```
