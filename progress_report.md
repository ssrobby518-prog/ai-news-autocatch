# AI Intel Scraper MVP — 進度報告

> 最後更新：2026-03-05　對應版本：Iteration 31（commit f2a2a68）

---

## A. 專案目標

將每日抓取的 AI 情資彙整為 `digest.md`，透過本地 Qwen 模型忠實翻譯（1:1 無前綴、無角色桶），輸出繁體中文三件套（`latest_brief.md` + `.docx` + `.pptx`）；若任何硬閘門失敗，改輸出 NOT_READY 三件套並以 exit 1 快速中止。

---

## B. Iteration 31 完成進度摘要

### B-1. Commit 清單

| Commit | 說明 |
|--------|------|
| `0dc3807` | iter31：`stage_seconds` 計時器（hydration/card_build/translate/build_docx/build_pptx/gates/z0_collect）+ `_probe_target=7` hydration early-stop |
| `f2a2a68` | iter31b：wall-clock cap for Qwen HTTP calls（urllib slow-stream hang fix）—`llama_openai_client._post()` + `_translate_event_bullets_1to1` 均改為 ThreadPoolExecutor wall-clock cap |

### B-2. 驗收閘門結果（run_id = 20260305_051622）

| 閘門 | 結果 | 關鍵數值 |
|------|------|----------|
| GIT_UP_TO_DATE | ✅ PASS | 0 0 |
| EVIDENCE_FILE_EXISTS | ✅ PASS | — |
| BRIEF_TRANSLATION_READY | ✅ PASS（GPU WARN-OK） | Qwen 有回應，nvidia-smi 偵測模式寬容 |
| TRANSLATION_DELIVERY_HARD | ✅ PASS | latest_brief.md 存在且非空 |
| **TRANSLATION_DENSITY_HARD** | ✅ PASS | digest_unique=49，brief_unique=48，ratio=0.98（門檻 ≥0.9） |
| NO_REPEAT_SPAM_HARD | ✅ PASS | 同一節內無句子重複 ≥3× |
| NO_SPURIOUS_PREFIX_TAG_HARD | ✅ PASS | 零條 bullet 匹配公司名/角色標籤前綴 pattern |
| NO_ROLE_BUCKETS_HARD | ✅ PASS | brief 全文不含「揭示：/評估：/影響：」 |
| TRANSLATION_BULLET_PARITY_HARD | ✅ PASS | digest=42 bullets，brief=41 bullets，7 events 全達 floor(0.9) |
| NO_NEAR_DUPLICATE_INTRA_EVENT_HARD | ✅ PASS | intra-event dedup 移除 0 重複 |
| NO_TRIPLET_COPYPASTE_HARD | ✅ PASS | 無跨事件三連 bullet 複製 |
| REPEAT_AUDIT_META | ✅ PASS | duplicates_found=0，duplicates_removed=0 |
| SELECTION_AUDIT | ✅ PASS | selected=7（5–7 範圍）|
| BIGTECH_FOCUS | ✅ PASS | bigtech_hit=7 ≥4 |
| SOURCE_DIVERSITY | ✅ PASS | distinct_sources=3（門檻 ≥3，踩線） |

verify_run: **10/10 PASS** | status=OK | exit 0

### B-3. stage_seconds 實測數字（run_timing.meta.json）

| Stage | 耗時 | 說明 |
|-------|------|------|
| z0_collect | 0.1s | run_once.py 內部讀取 JSONL（Z0 集合在 PS 層已完成） |
| hydration | 23.2s | early-stop 於 tier=1/3（80 items）觸發 |
| card_build | **1700.7s** | **瓶頸：DBE 10 張卡片 × Qwen CPU 模式翻譯** |
| translate | 0s | 7/7 events 全命中 translation cache |
| build_docx | 0.1s | — |
| build_pptx | 0s | — |
| gates | 1s | — |
| **stage sum** | **1725.1s** | ≤ total_seconds=2056s ✅ |

### B-4. translation_engine.meta.json

| 欄位 | 數值 | 說明 |
|------|------|------|
| calls_total | 0 | 7 個事件全命中快取，零次 Qwen 呼叫 |
| cache_hit | 7 | 當日第二次執行命中前次快取 |
| cache_miss | 0 | 無新事件 |

### B-5. 執行耗時

| 指標 | 數值 |
|------|------|
| 總耗時（verify_online.ps1） | **2056 秒（34 分 16 秒）** |
| run_once.py 內部 | 1723.92 秒 |
| Hard cap（PIPELINE_TIME_BUDGET_SEC） | 1800 秒 |
| 超出量 | 256 秒（+14.2%） |
| 本輪是否因超時觸發 NOT_READY | **否**（time gate 為 soft-warn） |

---

## C. 現況判定（PM 口徑）

### 內容層面：✅ PASS

- **所有 Iter30 內容閘門不退步**：TRANSLATION_DENSITY/PARITY/NO_PREFIX/NO_ROLE_BUCKETS 等全數 PASS
- **stage_seconds 已實裝**：`run_timing.meta.json` 含 `stage_seconds` 物件，stage sum ≤ total ✅
- **translate=0s**：7/7 translation cache hits，翻譯段耗時為零
- **hydration=23s**：early-stop 有效，tier=1/3 觸發，遠低於前次

### 運行層面：⚠️ RISK（惡化）

- **總耗時 2056s > hard cap 1800s**（前次 Iter30=1960s，Iter31 反增 96s）
- **card_build=1700s 是瓶頸**：DBE 10 張卡片 × `_prepare_brief_final_cards_fast`（含多次 Qwen 呼叫）
- **wall-clock cap 有效但不足夠**：每次 Qwen 呼叫被 120s cap 限制，但 10 cards × 多 role × 120s 仍過長
- **primary path = 0 items（37 too_old）**：每次都需 DBE fallback，是根本原因

---

## D. 風險清單（更新）

| # | 風險 | 觸發條件 | 影響 | 狀態 |
|---|------|----------|------|------|
| **R1** | card_build 超時 | DBE path × CPU 模式 Qwen（10 cards × ~170s/card） | total > 1800s soft cap | ⚠️ 持續發生（Iter30=1960s，Iter31=2056s） |
| **R2** | distinct_sources=3 踩線 | 某來源抓取失敗 | SOURCE_DIVERSITY_FAIL | ⚠️ 本輪仍踩線 |
| **R3** | GPU WARN-OK 可觀測性不足 | nvidia-smi 看不到 llama-server | 無從確認真實 GPU 狀態 | 持續 |
| **R4** | primary path = 0 items | too_old 閾值過嚴 vs Z0 抓取內容 | 每次觸發 DBE（高耗時） | ⚠️ 新增（本輪首次明確識別） |
| **R5** | batch translate 截斷 | 10+ EN bullet 事件 | fallback 耗時激增 | 低風險（本輪 cache 命中） |

---

## E. 改進方向（更新 TODO 清單）

### P0（緊急）：解決 primary path = 0 items

- [ ] **診斷 too_old 根因**：Z0 pool 有 227 個 frontier_ge_85_72h（72h 內新文章），但 preselect 抽取 80 個全部 too_old（37/39 去重後）
  - 假設：`BRIEF_FAST_PRESELECT` 優先選分數高但舊的文章（分數計算包含 biz/prod 加成，可能偏老文章）
  - 行動：檢查 preselect 排序邏輯，確保 age 權重足夠大，優先選 72h 內文章
  - **完成定義**：primary path kept ≥ 5，無需 DBE fallback

### P0：DBE path Qwen 呼叫數量上限

- [ ] **`_prepare_brief_final_cards_fast` 在 DBE 模式下加速**：
  - 當 `skip_batch_fallback=True` 時，跳過 `_iter29_sents_to_bullets` 的個別翻譯（直接用 EN bullets + ZH skeleton）
  - 或：為 DBE 卡片設定更激進的 timeout（20s per card total，超時直接用 EN fallback）
  - **完成定義**：card_build stage < 200s（含 DBE 10 cards）

### P1：stage_seconds 已完成（Iter31 已交付）

- [x] `stage_seconds` 拆分 ✅ — 含 z0_collect/hydration/card_build/translate/build_docx/build_pptx/gates
- [x] `verify_online.ps1` footer 顯示分段耗時 ✅

### P2：若 primary path 修復後仍超時

- [ ] 觀察 3 輪：primary path 修復後 card_build 是否 < 200s（直接翻譯事件，無 DBE）
- 預期：primary path 直接跑 `_translate_digest_1to1`（translation cache），card_build ≈ 0s

---

## F. 下一步驗收（Iteration 32 完成定義）

### 目標

| 指標 | 目標值 | 說明 |
|------|--------|------|
| 總耗時 | < 1200s（soft target） | Hard cap 仍維持 1800s |
| primary path items | ≥ 5 | 不得觸發 DBE fallback |
| card_build stage | < 200s | too_old 修復後 card_build 主要為 0（translation cache） |
| Iter30 所有內容 gate | 全部 PASS | 不得退步 |
| distinct_sources | ≥3 | 不得降低門檻 |

### 驗收標準

1. `verify_online.ps1` exit 0，所有既有 gate PASS
2. `run_timing.meta.json` 的 `stage_seconds.card_build` < 200s
3. pipeline log 顯示 primary path kept ≥ 5（無 `final_cards build failed`）
4. git rev-list 0 0

---

## G. 四段式證據（Iteration 31）

### Section A — Git 差異確認

```
$ git log --oneline -5
f2a2a68 iter31b: wall-clock cap for Qwen HTTP calls
0dc3807 iter31: stage_seconds timing + hydration early-stop target=7
6a222b1 docs: update progress report (iter30 status + next optimizations)
58e0ff9 iter30c: fix 'log' not defined in module-level functions

$ git diff --name-only HEAD~2 HEAD
scripts/run_once.py
scripts/verify_online.ps1
utils/llama_openai_client.py

$ git status -sb
## main...origin/main

$ git rev-list --left-right --count origin/main...HEAD
0	0
```

### Section B — verify_online.ps1 成功跑

```
verify_run: 10/10 PASS
status=OK | exit 0 | run_id=20260305_051622

TRANSLATION_DENSITY_HARD：digest_unique=49 brief_unique=48 ratio=0.98 通過
NO_SPURIOUS_PREFIX_TAG_HARD：通過
NO_ROLE_BUCKETS_HARD：通過
TRANSLATION_BULLET_PARITY_HARD：digest=42 brief=41 events=7 通過
REPEAT_AUDIT_META：duplicates_found=0 duplicates_removed=0 通過
SELECTION_AUDIT：selected=7 bigtech_hit=7 distinct_sources=3 通過

stage_seconds：
  hydration:23.2s  card_build:1700.7s  translate:0s
  build_docx:0.1s  build_pptx:0s  gates:1s  z0_collect:0.1s
  stage_sum=1725.1s <= total=2056s ✅

⏱️ 總耗時：2056 秒（34 分 16 秒）— SOFT WARN（>1800s）
```

### Section C — 受控失敗測試

```
Iter31 無新 hard gate。
Section C：驗證 stage_seconds.sum ≤ total_seconds

$ python3 -c "import json,pathlib; d=json.loads(pathlib.Path(r'outputs/run_timing.meta.json').read_text('utf-8-sig')); s=d['stage_seconds']; tot=d['total_seconds']; print(f'sum={sum(s.values()):.1f}  total={tot}  OK={sum(s.values())<=tot}')"
sum=1725.1  total=2056  OK=True   → PASS
```

### Section D — Commit + Push 確認

```
$ git rev-list --left-right --count origin/main...HEAD
0	0   ← 已 push，origin/main 同步
HEAD: f2a2a68628df20cc3f221eb8594fee977f0793c4
```

---

## H. 四段式證據模板（每輪驗收必照抄）

每次 iteration 完成後，按以下四段順序收集並貼出證據：

### Section A — Git 差異確認

```powershell
git diff --name-only HEAD~1 HEAD
git diff --stat HEAD~1 HEAD
git status -sb
```

### Section B — verify_online.ps1 成功跑

```powershell
pwsh -File scripts/verify_online.ps1
```

### Section C — 受控失敗測試（針對本輪新 gate）

```powershell
# 每個新 gate 各寫一個臨時腳本，注入已知失敗條件，確認 gate 偵測到 FAIL
# 腳本於測試後立即刪除（不進 git）
```

### Section D — Commit + Push 確認

```powershell
git add <changed_files>
git commit -m "iter32: <說明>"
git push origin main
git rev-list --left-right --count origin/main...HEAD
# 預期：0	0
```

---

*本報告由 Claude Code 自動生成，對應 Iteration 31 最終狀態（2026-03-05）。*
