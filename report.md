# iter53 Evidence Pack — 2026-03-07

## Section A — git

【外部輸出】
```powershell
git diff --name-only
scripts/run_once.py
scripts/verify_online.ps1

git status -sb
## main...origin/main [ahead 2]

git rev-list --left-right --count origin/main...HEAD
0	2
```

## Section B — DAILY 成功（本輪現跑 run_id=20260307_075930）

**命令：**
```powershell
Remove-Item Env:INJECT_FORCE_VENDOR -ErrorAction SilentlyContinue
Remove-Item Env:INJECT_FORCE_DOMAIN -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

**【外部輸出】type outputs\LAST_RUN_SUMMARY.txt：**
```
run_id              = 20260307_075930
started_at          = 2026-03-07T08:00:48.4191776-08:00
finished_at         = 2026-03-07T08:00:48.4191776-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

**【外部輸出】type outputs\selection_audit.meta.json（多來源/多廠欄位）：**
```json
{
  "selected_items_count": 7,
  "selected_sources_distinct": 5,
  "bigtech_hit_count": 7,
  "official_or_media_count": 4,
  "selected_domains_distinct": 5,
  "selected_vendors_distinct": 4,
  "domain_counts": {
    "discuss.huggingface.co": 1,
    "blog.research.google": 2,
    "techcrunch.com": 1,
    "aws.amazon.com": 1,
    "github.com": 2
  },
  "vendor_counts": {
    "HuggingFace": 1,
    "Google": 3,
    "Amazon": 1,
    "Microsoft": 2
  },
  "max_domain_count": 2,
  "max_vendor_count": 3,
  "diversity_constraints": {
    "min_domains": 4,
    "max_domain": 2,
    "min_vendors": 4,
    "max_vendor": 3
  },
  "diversity_pass": true
}
```

**【外部輸出】type outputs\bigtech_diversity.meta.json：**
```json
{
  "run_id": "20260307_075930",
  "mode": "daily",
  "constraints": {
    "min_domains": 4,
    "max_domain": 2,
    "min_vendors": 4,
    "max_vendor": 3
  },
  "selected_domains_distinct": 5,
  "selected_vendors_distinct": 4,
  "domain_counts": {
    "discuss.huggingface.co": 1,
    "blog.research.google": 2,
    "techcrunch.com": 1,
    "aws.amazon.com": 1,
    "github.com": 2
  },
  "vendor_counts": {
    "HuggingFace": 1,
    "Google": 3,
    "Amazon": 1,
    "Microsoft": 2
  },
  "max_domain_count": 2,
  "max_vendor_count": 3,
  "pass": true,
  "rejected_due_to_domain_cap": [],
  "rejected_due_to_vendor_cap": []
}
```

**verify_online.ps1 BIGTECH_DIVERSITY gate 輸出：**
```
BIGTECH_DIVERSITY_HARD_DAILY:
  selected_domains_distinct : 5
  selected_vendors_distinct : 4
  max_domain_count          : 2
  max_vendor_count          : 3
  diversity_pass            : True
  => BIGTECH_DIVERSITY_HARD_DAILY: PASS
```

**Pipeline 結尾：**
```
=== verify_online.ps1 完成：所有門檻通過 ===
總耗時：78 秒
```

## Section C — 受控失敗（本輪現跑注入 run_id=20260307_080110）

**命令：**
```powershell
$env:INJECT_FORCE_VENDOR="Google"
$env:INJECT_FORCE_DOMAIN="blog.research.google"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

**【外部輸出】type outputs\LAST_RUN_SUMMARY.txt（完整全文）：**
```
run_id              = 20260307_080110
started_at          = 2026-03-07T08:02:11.7106567-08:00
finished_at         = 2026-03-07T08:02:11.7106567-08:00
mode                = daily
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx
fail_reason         = PIPELINE_GATE_FAIL: BIGTECH_DIVERSITY_HARD_DAILY
```

**【外部輸出】Get-Item outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx | Select Name,LastWriteTime,Length：**
```
Name                  LastWriteTime       Length
----                  -------------       ------
NOT_READY_report.md   3/7/2026 8:02:11 AM    862
NOT_READY_report.docx 3/7/2026 8:02:11 AM  35888
```

**【外部輸出】Get-Content outputs\NOT_READY_report.md -TotalCount 40：**
```markdown
# NOT READY Report — 20260307_080110

| Field | Value |
|-------|-------|
| run_id | `20260307_080110` |
| mode | manual |
| report_mode | brief |
| status | **FAIL** |
| generated_at | 2026-03-07 16:02 UTC |

## Failure

- gate: `BIGTECH_DIVERSITY_HARD_DAILY`
- fail_reason: BIGTECH_DIVERSITY_UNSATISFIED: domains=1 vendors=1 max_domain=7 max_vendor=7 [test_injected=true]

## Selection Stats

| selected_items_count | 7 |
| selected_sources_distinct | 5 |
| bigtech_hit_count | 6 |
| official_or_media_count | 5 |
```

**Pipeline log 關鍵行：**
```
INJECT_FORCE_VENDOR=Google INJECT_FORCE_DOMAIN=blog.research.google: diversity overridden to FAIL
FAST_600_MODE FAIL: gate=BIGTECH_DIVERSITY_HARD_DAILY reason=BIGTECH_DIVERSITY_UNSATISFIED: domains=1 vendors=1 max_domain=7 max_vendor=7 [test_injected=true]
```

## Section D — 提交與同步

```powershell
git add scripts/run_once.py scripts/verify_online.ps1 report.md
git status -sb
git commit -m "iter53: enforce multi-source(>=4, max2/domain) + multi-vendor(>=4, max3/vendor) bigtech diversity under 160/200"
git push origin main
git rev-list --left-right --count origin/main...HEAD
# 0	0
```
