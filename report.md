# iter52d Evidence Pack — 2026-03-07

## Section A — git

【外部輸出】
```powershell
git diff --name-only
# (empty — clean working tree at time of pipeline runs)

git status -sb
## main...origin/main
# (clean — no uncommitted files)

git rev-list --left-right --count origin/main...HEAD
0	0
```

## Section B — DAILY 成功（本輪現跑 run_id=20260307_072939）

**命令：**
```powershell
Remove-Item Env:INJECT_DEV_FORUM_LOW_VALUE -ErrorAction SilentlyContinue
Remove-Item Env:PIPELINE_TIME_BUDGET_SEC -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

**【外部輸出】type outputs\LAST_RUN_SUMMARY.txt：**
```
run_id              = 20260307_072939
started_at          = 2026-03-07T07:30:46.4231701-08:00
finished_at         = 2026-03-07T07:30:46.4231701-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

**【外部輸出】Get-Content outputs\dev_forum_audit.meta.json -TotalCount 20：**
```json
{
  "run_id": "20260307_072939",
  "selected_dev_forum_low_value_count": 0,
  "selected_dev_forum_high_value_count": 0,
  "summary": {
    "rejected_low_value_count": 0,
    "rejected_high_value_count": 1,
    "rejected_missing_engagement_count": 0
  },
  "rules_used": {
    "high_value_thresholds": "reply_count>=30 OR like_count>=80 OR view_count>=10000",
    "high_value_cve_exception": "title/body matches CVE|vulnerability|0-day|security advisory AND reply_count>=10",
    "low_value_definition": "dev_forum=true AND does not meet any high_value threshold",
    "missing_engagement": "engagement source=none (no data extracted) treated as low_value"
  },
  "rejected_dev_forum_low_value_samples": [],
  "rejected_dev_forum_high_value_samples": [
    {
```

**JSON 合法性驗證 — 教科書式兩行命令本體與輸出：**

【外部輸出】命令 1：
```powershell
PS> python -m json.tool outputs\dev_forum_audit.meta.json > NUL
```
（無輸出 — 表示 JSON 合法，python 回傳 exit code 0）

【外部輸出】命令 2：
```powershell
PS> Write-Output "DEV_FORUM_AUDIT_JSON_TOOL_EXIT_CODE=$LASTEXITCODE"
DEV_FORUM_AUDIT_JSON_TOOL_EXIT_CODE=0
```

**verify_online.ps1 console log 內建輸出（同一 run 硬證據）：**
```
  DEV_FORUM_AUDIT_JSON_TOOL_EXIT_CODE=0
DEV_FORUM_AUDIT_JSON_VALID_HARD: PASS
```

**Pipeline 結尾：**
```
=== verify_online.ps1 完成：所有門檻通過 ===
```

## Section C — 受控失敗（本輪現跑注入 run_id=20260307_073107）

**命令：**
```powershell
$env:INJECT_DEV_FORUM_LOW_VALUE="7"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

**【外部輸出】type outputs\LAST_RUN_SUMMARY.txt（完整全文）：**
```
run_id              = 20260307_073107
started_at          = 2026-03-07T07:32:09.2441780-08:00
finished_at         = 2026-03-07T07:32:09.2441780-08:00
mode                = daily
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx
fail_reason         = PIPELINE_GATE_FAIL: DEV_FORUM_LOW_VALUE_CAP_HARD
```

**【外部輸出】Get-Item outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx | Select Name,LastWriteTime,Length：**
```
Name                  LastWriteTime       Length
----                  -------------       ------
NOT_READY_report.md   3/7/2026 7:32:09 AM    964
NOT_READY_report.docx 3/7/2026 7:32:09 AM  35859
```

**【外部輸出】Get-Content outputs\NOT_READY_report.md -TotalCount 40：**
```markdown
# NOT READY Report — 20260307_073107

| Field | Value |
|-------|-------|
| run_id | `20260307_073107` |
| mode | manual |
| report_mode | brief |
| status | **FAIL** |
| generated_at | 2026-03-07 15:32 UTC |
| test_injected | `true` |

## Failure

- gate: `DEV_FORUM_LOW_VALUE_CAP_HARD`
- fail_reason: # NOT_READY gate: DEV_FORUM_LOW_VALUE_CAP_HARD run_id: 20260307_073107 reason: DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL: dev_forum_low_value_count=7

## Selection Stats

| Metric | Value |
|--------|-------|
| selected_items_count | 7 |
| selected_sources_distinct | 3 |
| bigtech_hit_count | 7 |
| official_or_media_count | 7 |

## Supply Fallback

- fallback_used: false
- reason: none
- snapshot_age_hours: null

## Sample Events


## Next Steps

- See outputs/desktop_button.last_run.log for the full failure trace.
- 本次失敗為注入測試（test_injected=true），用於驗證 DEV_FORUM_LOW_VALUE_CAP_HARD 截斷
```

**Pipeline log 關鍵行：**
```
INJECT_DEV_FORUM_LOW_VALUE=7: gate will see lv_count=7 (real=0 + injected=7)
FAST_600_MODE FAIL: gate=DEV_FORUM_LOW_VALUE_CAP_HARD reason=DEV_FORUM_LOW_VALUE_CAP_HARD_FAIL: dev_forum_low_value_count=7
```

## Section D — 提交與同步

```powershell
git add report.md
git status -sb
git commit -m "iter52d: evidence hardening (json.tool command body + exitcode echo; same-run B/C)"
git push origin main
git rev-list --left-right --count origin/main...HEAD
# 0	0
```
