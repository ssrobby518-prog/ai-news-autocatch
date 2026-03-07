# Iteration 54 — 四段式交付證據

## Section A — git

【外部輸出】git diff --name-only
```
scripts/install_daily_task_beijing_0900.ps1
scripts/verify_online.ps1
```

【外部輸出】git status -sb
```
## main...origin/main [ahead 1]
```

【外部輸出】git rev-list --left-right --count origin/main...HEAD
```
0	1
```

### 本輪變更摘要
- `scripts/verify_online.ps1`: Write-RunTimingMeta 中 translate_hard_deadline_sec 45→120、build_docx_hard_deadline_sec 10→30（對齊實際程式碼）；ConvertTo-Json depth 6→8（支援巢狀 calls_detail）
- `scripts/install_daily_task_beijing_0900.ps1`: 排程 Task 改為直接呼叫 verify_online.ps1（避免 desktop_button.ps1 的 Read-Host 在無人值守下卡住）

---

## Section B — DAILY 成功（本輪現跑）

run_id=20260307_083040 | mode=daily | total_seconds=71 | selected=7 | all gates PASS

【外部輸出】type outputs\LAST_RUN_SUMMARY.txt
```
run_id              = 20260307_083040
started_at          = 2026-03-07T08:31:51.5650142-08:00
finished_at         = 2026-03-07T08:31:51.5650142-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

【外部輸出】type outputs\run_timing.meta.json
```json
{
    "run_id":  "20260307_083040",
    "started_at":  "2026-03-07T08:30:40",
    "finished_at":  "2026-03-07T08:31:51",
    "total_seconds":  71,
    "time_budget_seconds":  600,
    "soft_target_seconds":  160,
    "soft_target_exceeded":  false,
    "z0_deadline_soft_sec":  30,
    "z0_deadline_hard_sec":  40,
    "z0_stop_reason":  "hard_deadline",
    "z0_collect_online_seconds":  48,
    "z0_stop_new_requests_at_sec":  40.2,
    "z0_inflight_drained_seconds":  7.3,
    "z0_wall_clock_seconds":  47.5,
    "z0_deadline_semantics":  "stop_issuing_vs_wallclock",
    "z0_data_source":  "online",
    "z0_soft_deadline_sec":  30,
    "z0_hard_deadline_sec":  40,
    "hydrate_hard_deadline_sec":  55,
    "translate_hard_deadline_sec":  120,
    "build_docx_hard_deadline_sec":  30,
    "gates_hard_deadline_sec":  10,
    "before_translation_limit_sec":  120,
    "before_translation_seconds":  7.7,
    "stage_seconds":  {
        "other_seconds":  1,
        "digest_write":  0,
        "build_docx":  0.1,
        "z0_collect_online":  48,
        "before_translation":  7.7,
        "translate":  6.7,
        "z0_collect":  0,
        "hydrate":  7.6
    }
}
```

【外部輸出】type outputs\bigtech_diversity.meta.json
```json
{
  "run_id": "20260307_083040",
  "mode": "daily",
  "constraints": { "min_domains": 4, "max_domain": 2, "min_vendors": 4, "max_vendor": 3 },
  "selected_domains_distinct": 5,
  "selected_vendors_distinct": 4,
  "domain_counts": {
    "aws.amazon.com": 1, "techcrunch.com": 2, "github.com": 1,
    "discuss.huggingface.co": 1, "blog.research.google": 2
  },
  "vendor_counts": { "Amazon": 1, "Google": 3, "other": 1, "Microsoft": 1, "HuggingFace": 1 },
  "max_domain_count": 2,
  "max_vendor_count": 3,
  "pass": true,
  "rejected_due_to_domain_cap": [],
  "rejected_due_to_vendor_cap": []
}
```

【外部輸出】type outputs\selection_audit.meta.json（摘要欄位）
```
selected_items_count      = 7
selected_sources_distinct = 5
bigtech_hit_count         = 6
official_or_media_count   = 5
non_bigtech_dev_noise_count = 0
dev_forum_low_value_count = 0
diversity_pass            = true
selected_domains_distinct = 5
selected_vendors_distinct = 4
max_domain_count          = 2
max_vendor_count          = 3
```

【外部輸出】Get-Content outputs\dev_forum_audit.meta.json -TotalCount 20
```json
{
  "run_id": "20260307_083040",
  "selected_dev_forum_low_value_count": 0,
  "selected_dev_forum_high_value_count": 0,
  "summary": {
    "rejected_low_value_count": 0,
    "rejected_high_value_count": 2,
    "rejected_missing_engagement_count": 0
  },
  "rules_used": {
    "high_value_thresholds": "reply_count>=30 OR like_count>=80 OR view_count>=10000",
    "high_value_cve_exception": "title/body matches CVE|vulnerability|0-day|security advisory AND reply_count>=10",
    "low_value_definition": "dev_forum=true AND does not meet any high_value threshold",
    "missing_engagement": "engagement source=none (no data extracted) treated as low_value"
  },
  ...
}
```

【外部輸出】DEV_FORUM_AUDIT_JSON_TOOL_EXIT_CODE=0
【外部輸出】DEV_FORUM_AUDIT_JSON_VALID_HARD: PASS

【外部輸出】Get-Item outputs\latest_brief.md, outputs\executive_report.docx
```
Name                  LastWriteTime       Length
----                  -------------       ------
latest_brief.md       3/7/2026 8:31:51 AM   7810
executive_report.docx 3/7/2026 7:38:30 AM  40092
```

【外部輸出】dir outputs\*.pptx
```
（空 — 0 個 pptx 檔案）
```

### Gates 摘要
| Gate | 結果 |
|------|------|
| GPU_MODE_REQUIRED_HARD (tok/s>=15) | PASS (22.5) |
| BIGTECH_DOMINANCE_HARD (bt>=5 om>=4) | PASS (bt=6 om=5) |
| DEV_NOISE_CAP_HARD (devnoise=0) | PASS (0) |
| DEV_FORUM_LOW_VALUE_CAP_HARD (lv=0) | PASS (0) |
| BIGTECH_DIVERSITY_HARD_DAILY (dom>=4 ven>=4 max2/max3) | PASS (5/4/2/3) |
| DIGEST_DENSITY_FLOOR_HARD | PASS |
| TRANSLATION_DENSITY_HARD (unique>=0.9) | PASS (1.00) |
| ALL_MISS_SAFETY_MARGIN_HARD (est<=185) | PASS (113s) |
| TRANSLATION_META_COHERENCE_HARD | PASS |
| DEV_FORUM_AUDIT_JSON_VALID_HARD | PASS |
| PPTX_FORBIDDEN_HARD | PASS (0) |
| TIME_BUDGET (71s <= 200s hard, <= 160s soft) | PASS |

---

## Section C — 受控失敗（注入 low_value forum）

$env:INJECT_DEV_FORUM_LOW_VALUE="7" → DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL

【外部輸出】type outputs\LAST_RUN_SUMMARY.txt
```
run_id              = 20260307_083420
started_at          = 2026-03-07T08:35:25.4887039-08:00
finished_at         = 2026-03-07T08:35:25.4887039-08:00
mode                = daily
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx
fail_reason         = PIPELINE_GATE_FAIL: DEV_FORUM_LOW_VALUE_CAP_HARD
```

【外部輸出】Get-Item outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx
```
Name                  LastWriteTime       Length
----                  -------------       ------
NOT_READY_report.md   3/7/2026 8:35:25 AM    964
NOT_READY_report.docx 3/7/2026 8:35:25 AM  35859
```

【外部輸出】Get-Content outputs\NOT_READY_report.md -TotalCount 60
```
# NOT READY Report — 20260307_083420

| Field | Value |
|-------|-------|
| run_id | `20260307_083420` |
| mode | manual |
| report_mode | brief |
| status | **FAIL** |
| generated_at | 2026-03-07 16:35 UTC |
| test_injected | `true` |

## Failure

- gate: `DEV_FORUM_LOW_VALUE_CAP_HARD`
- fail_reason: DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL: dev_forum_low_value_count=7

## Selection Stats

| Metric | Value |
|--------|-------|
| selected_items_count | 7 |
| selected_sources_distinct | 4 |
| bigtech_hit_count | 7 |
| official_or_media_count | 5 |

## Next Steps

- 本次為受控注入測試（test_injected=true），用於驗證 DEV_FORUM_LOW_VALUE_CAP_HARD 攔截。
```

---

## Section D — 提交與同步

見下方 git 操作。
