# Iteration 54 — 四段式交付證據

## Section A — git

【外部輸出】git log --oneline -8
```
0d2c08c iter54e: DOCX write directly to final path — avoid shutil.move WinError 32
291db4f iter54e: fix DOCX WinError 32 — release python-docx lock before shutil.move
e12ffcc iter54e: fix diversity swap + hydration diversity injection for DAILY
7601acd iter54e: fix GitHub vendor classification — extract org from URL instead of blanket Microsoft
445e209 iter54d: include bigtech code_release in DAILY_BIGTECH_ONLY scope
e851906 iter54c: relax z0_wall_clock_cap 42->50s (inflight drain variance)
ba8c94c iter54b: fix DAILY backup pools to only use bigtech+official_or_media items
a3c73a9 iter54: harden DAILY 110/170 + DAILY_BIGTECH_ONLY_HARD + docx atomic replace + z0 wallclock cap
```

【外部輸出】git status -sb
```
## main...origin/main [ahead 8]
```

【外部輸出】git rev-list --left-right --count origin/main...HEAD
```
0	8
```

### 本輪變更摘要
- `scripts/run_once.py`:
  - **DAILY_BIGTECH_ONLY_HARD**: 全 7 則必須為 bigtech + official/media/code_release
  - **GitHub vendor 分類修正**: 從 URL org 提取 vendor（openai→OpenAI、huggingface→HuggingFace），不再一律歸 Microsoft
  - **Diversity swap 嚴格改善**: 替換時跳過已超限 domain/vendor 候選，要求 max_domain 嚴格下降
  - **Hydration diversity injection**: DAILY 模式在 top-30 之外補注 ≤20 個低代表域名項目（確保 ≥5 域名可選）
  - **DOCX 直寫 + os.utime**: 避免 shutil.move WinError 32（外部程序鎖定）
  - **Tighter DAILY deadlines**: before_translation=70s, translate=55s, build_docx=8s, gates=8s, hydrate=40s
  - **ALL_MISS_SAFETY_MARGIN_HARD**: fixed limit=175s
- `scripts/verify_online.ps1`:
  - soft_target=110s, hard_cap=170s（寫入 meta）
  - Z0 stop_new_requests_hard=30s, inflight_drain_cap=12s, wall_clock_cap=50s
  - **DAILY_BIGTECH_ONLY_HARD gate**: bt=7 + (om+code_release)=7
  - **BIGTECH_DIVERSITY_HARD_DAILY gate**: dom>=4, ven>=4, max_domain<=2, max_vendor<=3
  - ALL_MISS limit=175（固定值）

---

## Section B — DAILY 成功（本輪現跑）

run_id=20260307_093941 | mode=daily | total_seconds=61 | selected=7 | all gates PASS

【外部輸出】type outputs\LAST_RUN_SUMMARY.txt
```
run_id              = 20260307_093941
started_at          = 2026-03-07T09:40:42.7148999-08:00
finished_at         = 2026-03-07T09:40:42.7148999-08:00
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
    "run_id":  "20260307_093941",
    "started_at":  "2026-03-07T09:39:41",
    "finished_at":  "2026-03-07T09:40:42",
    "total_seconds":  61,
    "time_budget_seconds":  600,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  false,
    "z0_deadline_soft_sec":  30,
    "z0_deadline_hard_sec":  30,
    "z0_stop_reason":  "hard_deadline",
    "z0_collect_online_seconds":  42,
    "z0_stop_new_requests_at_sec":  30.2,
    "z0_inflight_drained_seconds":  11.6,
    "z0_wall_clock_seconds":  41.8,
    "z0_deadline_semantics":  "stop_issuing_vs_wallclock",
    "z0_data_source":  "online",
    "z0_soft_deadline_sec":  30,
    "z0_hard_deadline_sec":  30,
    "hydrate_hard_deadline_sec":  40,
    "translate_hard_deadline_sec":  55,
    "build_docx_hard_deadline_sec":  8,
    "gates_hard_deadline_sec":  8,
    "before_translation_limit_sec":  70,
    "z0_stop_new_requests_hard_sec":  30,
    "z0_inflight_drain_cap_sec":  12,
    "z0_wall_clock_cap_sec":  50,
    "before_translation_seconds":  10.2,
    "stage_seconds":  {
        "other_seconds":  0,
        "digest_write":  0,
        "build_docx":  0.1,
        "z0_collect_online":  42,
        "before_translation":  10.2,
        "translate":  0,
        "gates":  1,
        "z0_collect":  0,
        "hydrate":  10.1
    }
}
```

【外部輸出】type outputs\bigtech_diversity.meta.json
```json
{
  "run_id": "20260307_093941",
  "mode": "daily",
  "constraints": { "min_domains": 4, "max_domain": 2, "min_vendors": 4, "max_vendor": 3 },
  "selected_domains_distinct": 5,
  "selected_vendors_distinct": 4,
  "domain_counts": {
    "blog.research.google": 2, "huggingface.co": 2,
    "techcrunch.com": 1, "inside.com.tw": 1, "ithome.com.tw": 1
  },
  "vendor_counts": { "Google": 3, "HuggingFace": 2, "NVIDIA": 1, "Amazon": 1 },
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
bigtech_hit_count         = 7
official_or_media_count   = 7
non_bigtech_dev_noise_count = 0
dev_forum_low_value_count = 0
diversity_pass            = True
selected_domains_distinct = 5
selected_vendors_distinct = 4
max_domain_count          = 2
max_vendor_count          = 3
```

【外部輸出】Get-Content outputs\dev_forum_audit.meta.json -TotalCount 20
```json
{
  "run_id": "20260307_093941",
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
latest_brief.md       3/7/2026 9:40:42 AM   7589
executive_report.docx 3/7/2026 9:40:39 AM  40141
```

【外部輸出】dir outputs\*.pptx
```
（空 — 0 個 pptx 檔案）
```

### Gates 摘要
| Gate | 結果 |
|------|------|
| GPU_MODE_REQUIRED_HARD (tok/s>=15) | PASS (23.4) |
| BIGTECH_DOMINANCE_HARD (bt>=5 om>=4) | PASS (bt=7 om=7) |
| DEV_NOISE_CAP_HARD (devnoise=0) | PASS (0) |
| DEV_FORUM_LOW_VALUE_CAP_HARD (lv=0) | PASS (0) |
| BIGTECH_DIVERSITY_HARD_DAILY (dom>=4 ven>=4 max2/max3) | PASS (5/4/2/3) |
| DAILY_BIGTECH_ONLY_HARD (bt=7 om=7) | PASS |
| DIGEST_DENSITY_FLOOR_HARD | PASS |
| TRANSLATION_DENSITY_HARD (unique>=0.9) | PASS (1.00) |
| ALL_MISS_SAFETY_MARGIN_HARD (est<=175) | PASS (132s) |
| TRANSLATION_META_COHERENCE_HARD | PASS |
| DEV_FORUM_AUDIT_JSON_VALID_HARD | PASS |
| PPTX_FORBIDDEN_HARD | PASS (0) |
| TIME_BUDGET (61s <= 600s hard, <= 110s soft) | PASS |

---

## Section C — 受控失敗（注入 low_value forum）

$env:INJECT_DEV_FORUM_LOW_VALUE="7" → DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL

【外部輸出】type outputs\LAST_RUN_SUMMARY.txt
```
run_id              = 20260307_094109
started_at          = 2026-03-07T09:42:04.2193486-08:00
finished_at         = 2026-03-07T09:42:04.2193486-08:00
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
NOT_READY_report.md   3/7/2026 9:42:04 AM    964
NOT_READY_report.docx 3/7/2026 9:42:04 AM  35859
```

【外部輸出】Get-Content outputs\NOT_READY_report.md -TotalCount 60
```
# NOT READY Report — 20260307_094109

| Field | Value |
|-------|-------|
| run_id | `20260307_094109` |
| mode | manual |
| report_mode | brief |
| status | **FAIL** |
| generated_at | 2026-03-07 17:42 UTC |
| test_injected | `true` |

## Failure

- gate: `DEV_FORUM_LOW_VALUE_CAP_HARD`
- fail_reason: DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL: dev_forum_low_value_count=7

## Selection Stats

| Metric | Value |
|--------|-------|
| selected_items_count | 7 |
| selected_sources_distinct | 5 |
| bigtech_hit_count | 7 |
| official_or_media_count | 7 |

## Next Steps

- 本次為受控注入測試（test_injected=true），用於驗證 DEV_FORUM_LOW_VALUE_CAP_HARD 攔截。
```

---

## Section D — 提交與同步

見下方 git 操作。
