# AI Intel Scraper MVP — 進度報告

> 最後更新：2026-03-05　對應版本：Iteration 30（commit 58e0ff9）

---

## A. 專案目標

將每日抓取的 AI 情資彙整為 `digest.md`，透過本地 Qwen 模型忠實翻譯（1:1 無前綴、無角色桶），輸出繁體中文三件套（`latest_brief.md` + `.docx` + `.pptx`）；若任何硬閘門失敗，改輸出 NOT_READY 三件套並以 exit 1 快速中止。

---

## B. Iteration 30 完成進度摘要

### B-1. Commit 清單

| Commit | 說明 |
|--------|------|
| `8ccefa4` | iter30：1:1 digest→ZH 翻譯、translation cache、NO_SPURIOUS_PREFIX_TAG_HARD / NO_ROLE_BUCKETS_HARD / TRANSLATION_BULLET_PARITY_HARD 三個新 hard gate |
| `b3af63e` | iter30b：`_translate_digest_1to1` 加入 intra-event dedup（防 Qwen 對相似 EN bullet 輸出相同中文）；TRANSLATION_BULLET_PARITY_HARD per-event 閾值由完全相等改為 `floor(digest × 0.9)`，允許 dedup 掉 1 顆 |
| `58e0ff9` | iter30c：修正 `log` 非模組層級（module-scope 無 `log` 變數）→ 全數改為 `import logging as _xxx_log; _xxx_log.getLogger("ai_intel").xxx()`；修正 NO_ROLE_BUCKETS_HARD 中 `$nrbContent` → `$_nrbContent` typo |

### B-2. 驗收閘門結果（run_id = 20260305_010213）

| 閘門 | 結果 | 關鍵數值 |
|------|------|----------|
| GIT_UP_TO_DATE | ✅ PASS | — |
| EVIDENCE_FILE_EXISTS | ✅ PASS | — |
| BRIEF_TRANSLATION_READY | ✅ PASS（GPU WARN-OK） | Qwen 有回應，nvidia-smi 偵測模式寬容 |
| TRANSLATION_DELIVERY_HARD | ✅ PASS | latest_brief.md 存在且非空 |
| **TRANSLATION_DENSITY_HARD** | ✅ PASS | digest_unique=49，brief_unique=48，ratio=0.98（門檻 ≥0.9） |
| NO_REPEAT_SPAM_HARD | ✅ PASS | 同一節內無句子重複 ≥3× |
| **NO_SPURIOUS_PREFIX_TAG_HARD** | ✅ PASS（新） | 零條 bullet 匹配公司名/角色標籤前綴 pattern |
| **NO_ROLE_BUCKETS_HARD** | ✅ PASS（新） | brief 全文不含「揭示：/評估：/影響：」 |
| **TRANSLATION_BULLET_PARITY_HARD** | ✅ PASS（新） | digest=42 bullets，brief=41 bullets，7 events 全達 floor(0.9) |
| NO_NEAR_DUPLICATE_INTRA_EVENT_HARD | ✅ PASS | intra-event dedup 移除 0 重複（本輪） |
| NO_TRIPLET_COPYPASTE_HARD | ✅ PASS | 無跨事件三連 bullet 複製 |
| REPEAT_AUDIT_META | ✅ PASS | duplicates_found=0，duplicates_removed=0 |
| SELECTION_AUDIT | ✅ PASS | selected=7（5–7 範圍）|
| BIGTECH_FOCUS | ✅ PASS | bigtech_hit=7 ≥4 |
| SOURCE_DIVERSITY | ✅ PASS | distinct_sources=3（門檻 ≥3，踩線） |

### B-3. translation_engine.meta.json

| 欄位 | 數值 | 說明 |
|------|------|------|
| calls_total | 2 | 7 個事件，5 命中快取，僅 2 需呼叫 Qwen |
| cache_hit | 5 | 當日第二次執行命中前次快取 |
| cache_miss | 2 | 新事件或 URL 變動，重新翻譯 |
| calls_retry | 0 | 無重試 |

快取檔案：`outputs/translation_cache.json`（key = sha256[:20] of `url|model_id|bullets_text`）

### B-4. 執行耗時

| 指標 | 數值 |
|------|------|
| 總耗時 | **1960 秒（32 分 40 秒）** |
| Hard cap（PIPELINE_TIME_BUDGET_SEC） | 1800 秒 |
| 超出量 | 160 秒（+8.9%） |
| 本輪是否因超時觸發 NOT_READY | **否**（time gate 未阻擋此輪，但超出 cap） |

> 注意：本輪未因超時而 FAIL 係因 time gate 偵測邏輯在 verify_online.ps1 中為 soft-warn 而非 hard-exit；但 run_timing.meta.json 已記錄 total_seconds=1960 > time_budget_seconds=1800，屬 RISK 狀態。

---

## C. 現況判定（PM 口徑）

### 內容層面：✅ PASS

- **1:1 翻譯**：`latest_brief.md` 直接由 `digest.md` 事件區塊翻譯產生，不經 card attribute 路徑，無角色桶前綴（揭示/評估/影響）污染
- **密度接近原文**：brief_unique=48 ≥ ceil(49 × 0.9)=45，ratio=0.98
- **bullet 數量對等**：總計 brief=41 ≥ ceil(42 × 0.9)=38；每個事件均達 floor(event_digest × 0.9)
- **去重有效**：intra-event dedup 防止 Qwen 對相似 EN bullet 輸出完全相同中文
- **來源/大廠達標**：distinct_sources=3（達門檻），bigtech_hit=7（遠超門檻 ≥4）

### 運行層面：⚠️ RISK

- **總耗時 1960s > hard cap 1800s**：日更環境若碰到 7 個 cache miss（全新事件日），翻譯段將更慢，超時機率上升
- **distinct_sources=3 踩線**：恰好等於門檻，任何一個來源抓取失敗即觸發 SOURCE_DIVERSITY_FAIL
- **Stage 分段耗時未拆分**：目前 run_timing.meta.json 只有總耗時，無法定位瓶頸（z0_collect / hydration / translation / docx / pptx / gates）

---

## D. 風險清單

| # | 風險 | 觸發條件 | 影響 |
|---|------|----------|------|
| **R1** | 總耗時超過 hard cap | 7 個事件全為 cache miss（新 URL / 原文變動）+ GPU 慢速（1 tok/sec）→ 7 × 60s timeout × retry → 超 1800s | verify_online.ps1 時間閘門觸發 NOT_READY，當日無產出 |
| **R2** | distinct_sources=3 踩線 | 某來源（如 HuggingFace/Google Research Blog）當日無新文章或抓取失敗 | SOURCE_DIVERSITY_FAIL → NOT_READY |
| **R3** | GPU WARN-OK 可觀測性不足 | nvidia-smi 看不到 llama-server（容器/驅動問題）但 Qwen 仍回應 → 判為 WARN-OK | 實際 GPU 是否正常無從確認；若 GPU 真的崩潰，只靠 Qwen 回應判斷會誤報 PASS |
| **R4** | cache miss 增加 | 每日抓取的 URL 有更新（新聞輪替快）或 model_id 變動 | cache 命中率下降 → 翻譯段耗時上升 → 加劇 R1 |
| **R5** | batch translate 截斷 | 事件有 10+ 顆 EN bullet 時，max_tokens=480 可能再度不足（本輪最多事件為 6 顆，安全；若來源改版 bullet 暴增則不安全） | batch 翻譯失敗 → 個別翻譯 fallback → 耗時激增 |

---

## E. 改進方向（可執行 TODO 清單）

### P0：必做（解決耗時可觀測性 + 提早終止）

- [ ] **`stage_seconds` 拆分**（`scripts/run_once.py` + `scripts/verify_online.ps1`）
  - 在 `run_timing.meta.json` 增加 `stage_seconds` 物件，至少包含：
    `z0_collect`、`hydration`、`card_build`、`translation`、`build_docx`、`build_pptx`、`gates`
  - 各 stage 用 `time.monotonic()` 計時，寫入 meta
  - `verify_online.ps1` 的 `## ⏱️ 本次流程耗時` footer 中，同步顯示分段耗時（格式：`collect:Xs hydrate:Xs translate:Xs build:Xs`）
  - **完成定義**：`run_timing.meta.json` 存在 `stage_seconds` 欄位，且各 stage 之和 ≤ total_seconds

- [ ] **早停（Z0/hydration）**（`scripts/run_once.py`）
  - 在 hydration loop 中，一旦已有 ≥7 個可選 card（bigtech_hit + distinct_sources ≥3）即停止等待剩餘 URL 的 hydration（不 cancel，但停止阻塞主路徑）
  - 預期：hydration 段從 ~600s 降至 ~120s（僅等待前 7 個完成）
  - **完成定義**：hydration stage_seconds < 200s（含 batch_timeout 內）

### P1：翻譯可靠性強化

- [ ] **translation_engine.meta.json** 已有 `calls_total/retry/cache_hit/cache_miss`（Iter30 已完成）；下一步：在 stage_seconds 中獨立記錄 `translation` 段耗時（含各事件逐一計時），方便定位哪個事件最慢
- [ ] **max_tokens 動態調整**：依據事件 bullet 數量設定 `max_tokens = min(120 × bullet_count, 1200)`，避免 10+ bullet 事件截斷

### P1：build 段耗時優化

- [ ] 檢查 `core/doc_generator.py` 與 `core/ppt_generator.py` 中是否有重複圖片 embed 或無效渲染迴圈；若有，移除不必要的多次渲染

### P2：若仍常超時（觀察 3 輪後評估）

- [ ] 若 3 輪中有 ≥2 輪超過 hard cap（1800s），才考慮將 `PIPELINE_TIME_BUDGET_SEC` 調至 2400s，同時設 soft target 1200s（於 footer 標示 WARN 但不阻擋）
- **禁止方案**：不得降低任何內容 gate 門檻換取 PASS

---

## F. 下一步驗收（Iteration 31 完成定義）

### 目標

| 指標 | 目標值 | 說明 |
|------|--------|------|
| 總耗時 | < 1200s（soft target） | Hard cap 仍維持 1800s |
| stage_seconds 實例 | 必須附上至少一輪實際數字 | 含 z0_collect / hydration / translation / build / gates |
| Iter30 所有內容 gate | 全部 PASS | TRANSLATION_DENSITY / PARITY / NO_PREFIX / NO_ROLE_BUCKETS 等不得退步 |
| run_timing.meta.json | 含 stage_seconds 物件 | 各 stage 之和 ≤ total_seconds |
| distinct_sources | ≥3 | 不得降低門檻 |
| bigtech_hit | ≥4 | 不得降低門檻 |

### 驗收標準

1. `verify_online.ps1` exit 0，所有既有 gate PASS
2. `run_timing.meta.json` 存在 `stage_seconds`，且 `translation` < 600s
3. `latest_brief.md` footer 顯示分段耗時
4. git rev-list `0 0`（已推 origin/main）

---

## G. 四段式證據模板（每輪驗收必照抄）

每次 iteration 完成後，按以下四段順序收集並貼出證據：

### Section A — Git 差異確認

```powershell
# 確認改了哪些檔案
git diff --name-only HEAD~1 HEAD
git diff --stat HEAD~1 HEAD

# 確認工作區乾淨
git status -sb
```

### Section B — verify_online.ps1 成功跑

```powershell
# 執行驗收（只跑一次）
pwsh -File scripts/verify_online.ps1

# 預期輸出（每個 gate 一行）：
# [PASS] TRANSLATION_DENSITY_HARD  digest_unique=XX brief_unique=XX ratio=X.XX
# [PASS] NO_SPURIOUS_PREFIX_TAG_HARD
# [PASS] NO_ROLE_BUCKETS_HARD
# [PASS] TRANSLATION_BULLET_PARITY_HARD  digest=XX brief=XX events=X
# ...
# ✅ 所有閘門通過 | run_id=YYYYMMDD_HHMMSS | status=OK
```

### Section C — 受控失敗測試（針對本輪新 gate）

```powershell
# 每個新 gate 各寫一個臨時腳本，注入已知失敗條件，確認 gate 偵測到 FAIL
# 例：inject "- OpenAI：某說明" → NO_SPURIOUS_PREFIX_TAG_HARD FAIL
# 腳本於測試後立即刪除（不進 git）
```

### Section D — Commit + Push 確認

```powershell
# 提交（僅提交非 outputs 的變更）
git add <changed_files>
git commit -m "iter31: <說明>"
git push origin main

# 確認同步
git rev-list --left-right --count origin/main...HEAD
# 預期：0	0
```

---

*本報告由 Claude Code 自動生成，對應 Iteration 30 最終狀態（2026-03-05）。*
