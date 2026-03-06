# AI 捕捉資訊 — 進度報告

> 產出日期：2026-03-06 | HEAD commit：`992082e` (Iter44) | origin/main 同步：0/0

---

## 1. 專案一句話狀態 (Status One-liner)

**Iter44 已全部 PASS 並推送 origin/main**——DAILY 模式 cache-hit 83 秒、all-miss 164 秒，均在 200 秒硬預算以內，安全邊際約 21 秒。

---

## 2. 目前可 demo 的交付物 (Artifacts)

| 情境 | 輸出檔案 | 說明 |
|------|----------|------|
| **成功** | `outputs/latest_brief.md` + `outputs/executive_report.docx` | 每日 CEO 簡報 + 行政摘要 DOCX |
| **失敗（NOT_READY）** | `outputs/NOT_READY_report.md` + `outputs/NOT_READY_report.docx` | 密度不足或 gate 未過時產出兩件式失敗報告 |
| **PPTX** | **已禁止** | Iter42b 起三層防禦（PRE-CLEAN 刪除歷史殘留、Generation block 攔截產出、PPTX_FORBIDDEN_HARD gate 終檢），現行流程不產出任何 .pptx |

---

## 3. 核心硬規格 (Hard Constraints Snapshot)

| Gate / 規格 | 條件 | 違反結果 |
|-------------|------|----------|
| **時間預算 (DAILY)** | soft=160s (WARN) / hard=200s (FAIL-fast) | 超 hard → 立即失敗 |
| **selected_events** | >= 7 | FAIL |
| **distinct_sources** | >= 3 | FAIL |
| **BIGTECH_DOMINANCE_HARD** | bigtech_hit >= 5 且 official_or_media >= 4 | FAIL |
| **DEV_NOISE_CAP_HARD** | DAILY dev_forum_count = 0（零容忍） | FAIL |
| **DIGEST_DENSITY_FLOOR_HARD** | 每事件最低字元/bullet 門檻，thin_events = 0 | FAIL |
| **TRANSLATION_DENSITY_HARD** | unique >= 0.9、1:1 翻譯、GPU tok/s >= 15 | FAIL |
| **ALL_MISS_SAFETY_MARGIN_HARD** | est_total_seconds_if_all_miss <= budget - 15（即 <= 185s） | FAIL |
| **TRANSLATION_META_COHERENCE_HARD** | success + timeout + error = total、calls_detail 筆數一致 | FAIL |
| **PPTX_FORBIDDEN_HARD** | outputs/ 不得存在任何 .pptx | FAIL |
| **Daily 去重** | 與昨日 overlap <= 2（manual 可重複） | FAIL |

---

## 4. Iter44 重點改動 (What Changed in Iter44)

- **Z0 deadline 雙語義可核對**：新增 `z0_stop_new_requests_at_sec`（停發新請求時刻）vs `z0_wall_clock_seconds`（含 inflight drain 的實際牆鐘），寫入 `z0_deadline_semantics="stop_issuing_vs_wallclock"`，解釋為何 wall_clock 可大於 hard_deadline（因為已發出的 inflight 請求需等待完成）。
- **翻譯 calls 計數可分解**：新增 `calls_success` / `calls_timeout` / `calls_error` 三分類計數器 + `calls_detail[]` 逐筆記錄（event_idx, attempt_idx, ok, fail_kind, elapsed_seconds, tok_per_sec, used_singleflight），支援事後逐筆回溯。
- **安全邊際收緊**：新增 `ALL_MISS_SAFETY_MARGIN_HARD` gate，est_all_miss 必須 <= 185s（200s budget - 15s margin），確保全新日仍有充裕空間。
- **TRANSLATION_META_COHERENCE_HARD**：自動驗證 meta 欄位一致性（success+timeout+error=total、calls_detail 筆數=calls_total 等），防止統計不一致。
- **內部 deadline 調整**：TRANSLATE_HARD_DEADLINE 45s→120s（7 事件 all-miss 需 ~70-80s on RTX 4060 Laptop）、BUILD_DOCX_HARD_DEADLINE 10s→30s（I/O 負載變異容忍）。
- **Z0 deadlines 收緊**：soft=30s, hard=40s（Iter43 為 35/50），節省 ~25s z0_collect_online。

---

## 5. 驗收證據 (Evidence)

> 以下數據來自本機 `outputs/` 目錄（不進 git），可用第 8 節命令重現。

### 5.1 Section C — all-miss 模式 (TRANSLATION_CACHE_BYPASS=1)

**run_id：`20260306_145748`** | 模式：DAILY | 狀態：OK

#### run_timing.meta.json

| 欄位 | 值 |
|---|---|
| `total_seconds` | **164** |
| `time_budget_seconds` | 200 |
| `soft_target_seconds` | 160（soft_target_exceeded=true） |
| `z0_collect_online_seconds` | 56 |
| `z0_stop_new_requests_at_sec` | 40.9 |
| `z0_inflight_drained_seconds` | 15.3 |
| `z0_wall_clock_seconds` | 56.2 |
| `z0_stop_reason` | hard_deadline |
| `z0_deadline_semantics` | stop_issuing_vs_wallclock |
| `stage_seconds.translate` | 70.2 |
| `stage_seconds.hydrate` | 7.3 |
| `stage_seconds.build_docx` | 2.3 |
| `stage_seconds.z0_collect_online` | 56 |
| `stage_seconds.before_translation` | 8 |
| `stage_seconds.gates` | 2 |

#### translation_engine.meta.json

| 欄位 | 值 |
|---|---|
| `calls_total` / `calls_success` / `calls_timeout` / `calls_error` | 7 / 7 / 0 / 0 |
| `calls_retry` | 0 |
| `cache_hit` / `cache_miss` | 0 / 7 |
| `translate_mode` | all_miss |
| `translate_seconds` | 70.24 |
| `tok_s_min` / `tok_s_avg` / `tok_s_max` | 26.11 / 29.47 / 33.67 |
| `workload_chars_total` | 8459 |
| `workload_bullets_total` | 36 |
| `est_total_seconds_if_all_miss` | **164**（ground truth，因 translate_mode=all_miss） |
| `est_inputs.tok_per_sec_est_used` | 26.11（取 calls_tok_s_min） |
| `est_inputs.workload_output_tokens_est` | 2115 |
| `est_inputs.retry_rate_est` | 0.0 |

#### calls_detail 摘要（7 筆，全部 ok=true）

| event_idx | elapsed_s | tok/s | singleflight |
|-----------|-----------|-------|--------------|
| 1 | 11.08 | 29.63 | true |
| 2 | 5.57 | 28.55 | true |
| 3 | 17.83 | 33.67 | true |
| 4 | 11.15 | 28.14 | true |
| 5 | 6.98 | 26.11 | true |
| 6 | 9.79 | 27.61 | true |
| 7 | 7.50 | 32.58 | true |

#### gpu_probe.meta.json

| 欄位 | 值 |
|---|---|
| `gpu_process_found` | true |
| `tok_per_sec_est` | 21.86 |
| `tok_threshold` | 15 |
| `nvidia_smi_ok` | true |

#### digest_density.meta.json

| 欄位 | 值 |
|---|---|
| `gate_result` | PASS |
| `events_checked` | 7 |
| `thin_events_count` | 0 |
| chars 範圍 | 659 ~ 2550（7 事件皆達密度門檻） |

#### selection_audit.meta.json

| 欄位 | 值 |
|---|---|
| `selected_items_count` | 7 |
| `selected_sources_distinct` | 3 |
| `bigtech_hit_count` | 7 |
| `official_or_media_count` | 7 |
| `dev_forum_count` | 0 |
| `overlap_with_prev_daily` | 0 |
| `replacements_made` | 0 |

#### LAST_RUN_SUMMARY.txt

```
run_id              = 20260306_145748
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 5.2 Section B — cache-hit 模式（歷史記錄，已被 Section C 覆寫）

| 欄位 | 值（來自 Iter44 驗收記錄） |
|---|---|
| run_id | `20260306_144714` |
| total_seconds | **83** |
| est_total_seconds_if_all_miss | **176**（<= 185 PASS） |
| 所有 gates | PASS |

> 註：Section B 的 meta 檔案已被 Section C（all-miss）覆寫，上方數字來自 Iter44 驗收時記錄的摘要。

---

## 6. 風險與監控 (Risks & Monitoring)

### 風險

1. **Cache 命中 vs 全新日差異大**：cache-hit 83s 對比 all-miss 164s——翻譯階段佔差距約 70s。全新日（所有事件皆為 cache miss）仍需在 200s 內完成；目前安全邊際 36s（200-164），若 tok/s 下滑或事件文本更長，可能逼近上限。
2. **Z0 inflight drain 不可控**：hard_deadline=40s 但 wall_clock=56s，其中 15.3s 是等 inflight 請求完成排空。極端情況 drain 時間可能更長，壓縮後續階段可用時間。
3. **RTX 4060 Laptop 熱節流**：連續密集跑 tok/s 會下滑（threshold=15，目前 min=26 尚有餘量，但熱節流可能將 min 壓至 20 以下）。
4. **distinct_sources=3 剛好達標**：若某 RSS 來源斷線或內容不足，可能跌至 2 而觸發 FAIL。

### 建議監控指標

| 指標 | 來源 meta 欄位 | 警戒線 |
|------|---------------|--------|
| cache miss 比例 | `translation_engine.cache_miss / calls_total` | > 0.8 連續兩天 |
| 翻譯重試率 | `translation_engine.calls_retry / calls_total` | > 0.1 |
| GPU tok/s 下滑 | `translation_engine.tok_s_min` | < 20（接近 threshold 15） |
| Z0 inflight drain | `run_timing.z0_inflight_drained_seconds` | > 20s |
| est_all_miss 趨勢 | `translation_engine.est_total_seconds_if_all_miss` | > 175（逼近 185 gate） |
| 每日去重碰撞 | `selection_audit.overlap_with_prev_daily` | = 2（已到上限） |
| 翻譯 timeout/error | `translation_engine.calls_timeout + calls_error` | > 0 |

---

## 7. 下一步 (Next Steps)

### P0（必做）

- **連跑 N 天 DAILY 09:00（北京時間）**：觀察 soft 命中率（160s 以內）及硬失敗率（200s 以內），以 `run_timing.meta.json` 的 `total_seconds` 和 `soft_target_exceeded` 統計趨勢。
- **桌面按鈕 manual 跑全流程**：manual 模式允許重複（不受 overlap<=2 限制）；DAILY 排程必須遵守 overlap<=2 去重。

### P1（建議）

- **若 est_all_miss > 185 或 retry 偏高**：優先降低重試次數（換備援候選事件而非多次 retry 同一翻譯），不得降低密度、不得減少事件數。
- **監控 tok/s 下滑**：若 `tok_s_min` 連續低於 20，考慮增加 llama-server 冷卻間隔或確認 GPU 散熱。
- **distinct_sources 容錯**：評估是否增加備援 RSS 來源，避免單一斷線導致 FAIL。

---

## 8. 附錄：可重現命令 (Repro Commands)

### DAILY 正常跑

```powershell
cd C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp
.\scripts\verify_online.ps1 -Mode daily
```

### All-miss 模擬跑（強制 cache bypass）

```powershell
$env:TRANSLATION_CACHE_BYPASS = "1"
.\scripts\verify_online.ps1 -Mode daily
$env:TRANSLATION_CACHE_BYPASS = ""
```

### 檢查 meta（PowerShell）

```powershell
Get-Content outputs\run_timing.meta.json | ConvertFrom-Json | Format-List
Get-Content outputs\translation_engine.meta.json | ConvertFrom-Json | Format-List
Get-Content outputs\gpu_probe.meta.json | ConvertFrom-Json | Format-List
Get-Content outputs\digest_density.meta.json | ConvertFrom-Json | Format-List
Get-Content outputs\selection_audit.meta.json | ConvertFrom-Json | Format-List
type outputs\LAST_RUN_SUMMARY.txt
```

### 檢查 meta（bash / Git Bash）

```bash
cat outputs/run_timing.meta.json | python -m json.tool
cat outputs/translation_engine.meta.json | python -m json.tool
cat outputs/gpu_probe.meta.json | python -m json.tool
cat outputs/digest_density.meta.json | python -m json.tool
cat outputs/selection_audit.meta.json | python -m json.tool
cat outputs/LAST_RUN_SUMMARY.txt
```
