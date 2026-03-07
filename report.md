# Progress Report — Iter61/Stress Evidence Snapshot (Auto-picked delivery_dir, SHA-256)

run_date: 2026-03-07
變更檔案: report.md (evidence only; no code change)

## A) 系統能力摘要

- DAILY: selected_events>=7, bigtech/official/media, diversity (domains>=4, vendors>=4), density, translation density, PPTX forbidden, GPU-only gate
- stress 判定: soft_warning_no_switch (不切換; triggered=false) vs stress_600_vram_busy (切換 600/300; triggered=true)
- delivery_dir 歸檔: gpu_load.meta.json + delivery_consistency.meta.json + LAST_RUN_SUMMARY.txt (iter59 新增)

## B) Normal Run 證據

來源: outputs\deliveries\20260307_144953_a7ab743ca6c38635112783a7264f6bce238f97e8
(自動定位: stress_mode_triggered=false, stress_mode_name=soft_warning_no_switch)

- run_id: 20260307_144836
- stress_trigger_level: soft_warning
- stress_mode_triggered: false
- stress_mode_name: soft_warning_no_switch
- test_injected: false
- latest_brief.md sha256: ea7a5203ab44ade49b88a404bec7e76d229be3a39d395d43cfbba9e1ef714ccf (7591 bytes)
- executive_report.docx sha256: 6fece1bd232015fa8dde3f7c9d70e22adc1e06d65ca92fb8b96ed39a2b60a56b (40142 bytes)
- same_run_verified: true

NOTE: canonical outputs 可能被後續 run 覆寫，因此以 delivery_dir 交叉驗證為主。

## C) Stress Run 證據

來源: outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8
(自動定位: stress_mode_triggered=true, stress_mode_name=stress_600_vram_busy)

- run_id: 20260307_145024
- stress_trigger_level: vram_busy
- stress_mode_triggered: true
- stress_mode_name: stress_600_vram_busy
- test_injected: true
- latest_brief.md sha256: 709146d7396f8230cb447ad7e1466e2c4502a7a634ffd8a5ebf658e956082a25 (7608 bytes)
- executive_report.docx sha256: 11992465200e9a0385724f5e838b97debcd41acc1ca3f196062420c151cb8011 (40072 bytes)
- same_run_verified: true

## D) 可重現指令

Normal:
```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

Stress:
```
$env:INJECT_GPU_VRAM_RATIO="0.90"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
Remove-Item Env:INJECT_GPU_VRAM_RATIO -ErrorAction SilentlyContinue
```

---

# 四段式證據（完整外部輸出）

## Section A — Git

```
> git diff --name-only
（空白）

> git status -sb
## main...origin/main

> git rev-list --left-right --count origin/main...HEAD
0	0
```

## Section B — Normal Run

### Delivery Dir 交叉驗證

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

### Canonical（目前被 stress 覆寫；以 delivery_dir 為主）

```
> type outputs\LAST_RUN_SUMMARY.txt
run_id              = 20260307_145024
(canonical 已被 stress run 覆寫 — 見 Section C)
```

## Section C — Stress Run

### Delivery Dir 交叉驗證

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

### Canonical（目前 = stress run）

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

## Section D — Commit/Sync 可核對性

```
> git log --oneline -3
(after push)

> git rev-list --left-right --count origin/main...HEAD
0	0
```
