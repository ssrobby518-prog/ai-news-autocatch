# iter80b: invariant-locked late-swap fixes + domain diversity enforcement

run_date: 2026-03-10

## 根因

1. Post-selection mutation phases (diversity swap, platform swap, final rescue) 可能破壞已達標的 selection invariants
2. Invariant check 過於嚴格 — 連修正已存在失敗的 swap 都被 reject
3. Domain diversity (>=5) 在 late mutation 後可能降至 4
4. Phase-9d target player swap 不允許替換 multi-item vendor 的 items

## 修正

| 修正 | 檔案 | 說明 |
|------|------|------|
| 放鬆 invariant fallback | run_once.py | 所有 late mutation 加入 iter80b fallback：若 regress 的 invariant 原本就已 fail，接受 swap |
| Phase-9d multi-item vendor swap | run_once.py | 允許替換 count>=2 vendor 的 item 以引入新 target player |
| GR cap enforcement | run_once.py | final cap enforcement 加入 Google Research cap 強制替換 |
| domain concentration cap | run_once.py | final cap enforcement 加入 domain max_domain 強制替換 |
| domain diversity phase | run_once.py | FINAL IMMUTABLE SNAPSHOT 前新增 iter80b domain diversity enforcement（domains < 5 → 從 over-concentrated domain 替換為 new domain） |
| 全 phase 覆蓋 | run_once.py | div1, div2, platform, platform 2-step, FR-1~FR-4, TC/HFBE/GR/domain cap 均套用 relaxed invariant fallback |

## A) desktop_button PASS（GIT_HEAD=`5e82407`）

- RUN_ID=20260310_141456
- ENTRYPOINT=desktop_button
- selected_events=10
- domains=5, max_domain=3
- tc=3, gr=2, tc_gr_combined=5
- target_player_distinct=6 (Amazon, Anthropic, Google, Meta, NVIDIA, OpenAI)
- buckets=5, role_axes=4
- bigtech_actionable=10, bigtech_official_media=10
- leadership_politics_ai=7, china_ai_gov=1
- overlap_policy=allow_duplicates
- status=OK

## B) scheduled_task PASS（GIT_HEAD=`5e82407`）

- RUN_ID=20260310_141800
- ENTRYPOINT=scheduled_task
- selected_events=10
- domains=5, max_domain=3
- tc=2, gr=3, tc_gr_combined=5
- target_player_distinct=6
- buckets=5, role_axes=5
- overlap_policy=daily_unique_only, ids_written=True
- status=OK

## C) same HEAD validation

desktop GIT_HEAD=5e82407 = scheduler GIT_HEAD=5e82407 ✓

## D) 回歸注入 FAIL（4 cases）

| 注入 | 期待 gate | 結果 |
|------|-----------|------|
| INJECT_TECHCRUNCH_TOTAL=4 | TECHCRUNCH_CAP_HARD_DAILY | FAIL ✓ (tc=4>3) |
| INJECT_GOOGLE_RESEARCH_TOTAL=4 | GOOGLE_RESEARCH_CAP_HARD_DAILY | FAIL ✓ (gr=4>3) |
| INJECT_BIGTECH_OFFICIAL_MEDIA_COUNT=7 | BIGTECH_OFFICIAL_MEDIA_MIN_HARD_DAILY | FAIL ✓ (om=7<8) |
| INJECT_ROLE_AXES_DISTINCT=3 | ROLE_DIVERSITY_MIN_HARD_DAILY | FAIL ✓ (axes=3<4) |
