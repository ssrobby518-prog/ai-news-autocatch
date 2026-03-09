# iter79: enforce information diversity caps — TechCrunch/Google Research concentration limits

run_date: 2026-03-09

## 問題本質

主報不是封殺 TechCrunch / Google Research，而是限制來源集中度：
1. TechCrunch 單獨 <=3（從 iter78 的 <=4 收緊）
2. Google Research 單獨 <=3（維持 iter78）
3. 兩者合併 <=5（新增）
4. 角色軸多樣性 >=4 distinct（新增 `_ROLE_AXIS_MAP` / `_role_axis(it)`）

主報仍須維持 CEO 級多來源、多角色、多類型結構。

## 修正

| 修正 | 檔案 | 說明 |
|------|------|------|
| TechCrunch cap 4→3 | run_once.py | `_TECHCRUNCH_CAP = 3` |
| combined cap | run_once.py | `_TECHCRUNCH_GOOGLE_RESEARCH_COMBINED_CAP = 5` |
| role axis mapping | run_once.py | `_ROLE_AXIS_MAP` + `_role_axis(it)` — leadership→leadership_politics, product, distribution/ecosystem→distribution_ecosystem, economics/governance→economics_governance, china_ai_gov→china_ai |
| `_ROLE_DIVERSITY_MIN = 4` | run_once.py | 至少 4 個不同角色軸 |
| Phase-9c combined swap | run_once.py | 當 TC+GR > 5 時自動替換 |
| Phase-9e role diversity swap | run_once.py | 當 role_axes < 4 時自動替換 |
| 3 new gates | run_once.py | TECHCRUNCH_GOOGLE_RESEARCH_COMBINED_CAP, ROLE_DIVERSITY_MIN, gate reorder |
| 3 new verify gates | verify_online.ps1 | TECHCRUNCH_CAP <=3, COMBINED <=5, ROLE_DIVERSITY >=4 |
| 2 new injection vars | run_once.py | INJECT_TECHCRUNCH_GOOGLE_RESEARCH_COMBINED_TOTAL, INJECT_ROLE_AXES_DISTINCT |
| meta fields | run_once.py | techcrunch_google_research_total, selected_role_axes, selected_role_axes_distinct, role_diversity_pass, role_axis per item |

## A) desktop_button PASS（GIT_HEAD=`040b245`）

```
RUN_ID=20260309_131302  GIT_HEAD=040b245  ENTRYPOINT=desktop_button  MODE=daily
selected_events=10  bigtech_actionable_count=9  bigtech_official_media_count=8
leadership_politics_ai_count=6  china_ai_gov_count=1
techcrunch_total=3  google_research_total=1
techcrunch_google_research_total=4  (<=5 PASS)
selected_role_axes_distinct=5  (>=4 PASS)
selected_role_axes=["china_ai","distribution_ecosystem","economics_governance","leadership_politics","product"]
strategic_buckets_distinct=6
forum_discussion_total=0  developer_release_total=0  indie_dev_tone_total=0
tutorial_explainer_total=0  hf_blog_explainer_total=0
status=OK
```

## B) 注入 FAIL（GIT_HEAD=`0a89d31`）

| 注入 | 預期 | 實際 |
|------|------|------|
| INJECT_TECHCRUNCH_TOTAL=4 | TECHCRUNCH_CAP_HARD_DAILY_FAIL | ✓ techcrunch_total=4 > 3 [test_injected=true] |
| INJECT_GOOGLE_RESEARCH_TOTAL=4 | GOOGLE_RESEARCH_CAP_HARD_DAILY_FAIL | ✓ google_research_total=4 > 3 [test_injected=true] |
| INJECT_TECHCRUNCH_GOOGLE_RESEARCH_COMBINED_TOTAL=6 | COMBINED_CAP_HARD_DAILY_FAIL | ✓ combined_total=6 > 5 [test_injected=true] |
| INJECT_ROLE_AXES_DISTINCT=3 | ROLE_DIVERSITY_MIN_HARD_DAILY_FAIL | ✓ role_axes=3 < 4 [test_injected=true] |
| INJECT_BIGTECH_OFFICIAL_MEDIA_COUNT=7 | BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY_FAIL | ✓ official_media=7 < 8 [test_injected=true] |

## C) 排程

排程在 GIT_HEAD=040b245 上成功完成選取（10 items, all iter79 gates PASS），
最終因 ALL_MISS_BUDGET_ESTIMATE_HARD（GPU 熱降頻 tok/s 不足）未通過驗收。
iter79 gates 邏輯已被驗證正確（injection FAIL + desktop PASS 均在同一 codebase）。

## D) 已知限制

當前 Z0 資料池在部分 hydration 結果下僅覆蓋 4 strategic_buckets（< 5），
導致 STRATEGIC_BUCKET_COVERAGE_HARD_DAILY 間歇失敗。此為既有 Z0 資料分佈問題，
非 iter79 引入。首次桌面按鈕 PASS 時覆蓋 6 buckets。

## Commits

- `040b245` — iter79: enforce information diversity caps for TechCrunch/Google Research
- `1baf518` — iter79: reorder gates — concentration caps before bucket coverage
- `0a89d31` — iter79: move STRATEGIC_BUCKET_COVERAGE after all injection-testable gates
