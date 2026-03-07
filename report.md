# iter57 四段式交付證據 — 兩段式 STRESS_600 語義 + 常態 175/110 可達

run_date: 2026-03-07
變更檔案: scripts/verify_online.ps1, scripts/run_once.py, report.md

---

## Section A — Git 變更

### 【外部輸出】git diff --name-only

```
scripts/run_once.py
scripts/verify_online.ps1
```

### 【外部輸出】git status -sb

```
## main...origin/main
```

### 【外部輸出】git rev-list --left-right --count origin/main...HEAD

（push 後補填，見 Section D）

### 變更摘要（不放寬任何品質門檻）

**核心修正**：iter56 的 `non_llama_gpu_proc_count>=1` 觸發條件太敏感——IDE（Trae.exe）常駐 GPU compute-apps 就永遠進 600 模式，常態 175/110 永遠不可達。

**兩段式語義（iter57）**：

| 等級 | 條件 | 動作 |
|------|------|------|
| HARD vram_busy | vram_ratio>=0.85 OR used>=total-900 | STRESS_600（budget=600 soft=300） |
| HARD gpu_contention | non_llama>=2 AND vram_ratio>=0.70 | STRESS_600（budget=600 soft=300） |
| SOFT warning | non_llama>=1（IDE/輕量 compute） | 不切 600，只記錄 warning，維持常態 175/110 |
| NONE | 無外部 GPU 程序 | 常態 175/110 |

**為何 vram_ratio=0.66 不再叫 VRAM busy**：實際 VRAM 只佔 66%（5405/8188 MB），離滿載仍有 2783 MB 餘量。Trae.exe 是 IDE 不是遊戲，不會在推理時搶 VRAM。只有 vram_ratio>=0.85（真正接近滿載）或「多程序+高佔用」才觸發 STRESS_600。0.66 歸類為 soft_warning，不切換模式。

**新增 INJECT_GPU_VRAM_RATIO**：僅影響 stress 判定與 meta（test_injected=true），不影響品質 gate 判定。用於在無法自然產生 VRAM busy 的環境重現壓力模式證據。

**DAILY 預算修正**：budget 從 600→175（FAST_300_DAILY 預設被腳本內部 propagation 覆蓋的 bug 已修）。

---

## Section B — 常態成功（stress_mode_triggered=false；budget=175；soft=110）

run_id=20260307_133932 | exit=0 | total=80s | budget=175 | soft=110 | all gates PASS

### 【外部輸出】LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_133932
mode                = daily
status              = OK
selected_events     = 7
ai_selected_events  = 7
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 【外部輸出】gpu_load.meta.json（stress_trigger_level=soft_warning; stress_mode_triggered=false）

```json
{
    "run_id":  "20260307_133932",
    "vram_used_mb":  5405,
    "vram_total_mb":  8188,
    "vram_ratio":  0.6601,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "soft_warning",
    "stress_mode_triggered":  false,
    "stress_mode_name":  "none",
    "stress_reason":  "non_llama=2>=1 but vram_ratio=0.6601<0.7 — soft warning only",
    "test_injected":  false,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    }
}
```

### 【外部輸出】run_timing.meta.json（time_budget_seconds=175; soft_target_seconds=110; stress_mode_triggered=false）

```json
{
    "run_id":  "20260307_133932",
    "total_seconds":  80,
    "time_budget_seconds":  175,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  false,
    "stress_mode_triggered":  false,
    "stress_mode_name":  "none",
    "stress_trigger_level":  "soft_warning",
    "vram_ratio":  0.6601,
    "non_llama_gpu_proc_count":  2
}
```

### 【外部輸出】bigtech_diversity.meta.json

```json
{
    "selected_domains_distinct": 5,
    "selected_vendors_distinct": 4,
    "max_domain_count": 2,
    "max_vendor_count": 3,
    "pass": true
}
```

### 【外部輸出】selection_audit.meta.json

```json
{
    "selected_items_count": 7,
    "selected_sources_distinct": 5,
    "bigtech_hit_count": 7,
    "official_or_media_count": 7,
    "non_bigtech_dev_noise_count": 0,
    "dev_forum_low_value_count": 0
}
```

### 【外部輸出】產物檔案

```
Name                  LastWriteTime       Length
----                  -------------       ------
latest_brief.md       3/7/2026 1:40:52 PM   7591
executive_report.docx 3/7/2026 1:40:48 PM  40141
PPTX: No PPTX files
```

### 字面核對

- stress_mode_triggered = **false**（gpu_load + run_timing 佐證）
- stress_trigger_level = **soft_warning**（IDE 常駐不切 600）
- time_budget_seconds = **175**（常態硬上限）
- soft_target_seconds = **110**（常態軟目標）
- total_seconds = 80 < 110 < 175（均在限內）
- selected_events = 7 >= 7
- domains=5>=4, vendors=4>=4, max_domain=2<=2, max_vendor=3<=3
- devnoise=0, dev_forum_low=0
- PPTX=0
- docx LastWriteTime = 1:40:48 PM, md LastWriteTime = 1:40:52 PM（md 較新因 timing footer 追加在 DELIVERABLE_TIMESTAMP_COHERENCE gate 之後，gate 本身已 PASS）

---

## Section C — 壓力成功（stress_mode_triggered=true；budget=600；soft=300；test_injected=true）

run_id=20260307_134201 | exit=0 | total=90s | budget=600 | soft=300 | all gates PASS

使用注入重現：`INJECT_GPU_VRAM_RATIO=0.90`（僅影響 stress 判定與 meta；不影響品質 gate）

### 【外部輸出】LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_134201
mode                = daily
status              = OK
selected_events     = 7
ai_selected_events  = 7
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 【外部輸出】gpu_load.meta.json（trigger_level=vram_busy; stress_mode_triggered=true; test_injected=true）

```json
{
    "run_id":  "20260307_134201",
    "vram_used_mb":  5419,
    "vram_total_mb":  8188,
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2,
    "stress_trigger_level":  "vram_busy",
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_reason":  "vram_ratio=0.9000>=0.85 OR used=5419MB>=total-900=7288MB",
    "test_injected":  true,
    "thresholds_used":  {
        "vram_busy_ratio_threshold":  0.85,
        "vram_busy_mb_reserve":  900,
        "contention_proc_threshold":  2,
        "contention_vram_ratio_threshold":  0.7
    }
}
```

### 【外部輸出】run_timing.meta.json（time_budget_seconds=600; soft_target_seconds=300; stress_mode_triggered=true）

```json
{
    "run_id":  "20260307_134201",
    "total_seconds":  90,
    "time_budget_seconds":  600,
    "soft_target_seconds":  300,
    "soft_target_exceeded":  false,
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_trigger_level":  "vram_busy",
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2
}
```

### 【外部輸出】關鍵 gate 結果

```
BIGTECH_DIVERSITY_HARD_DAILY: PASS (domains=5, vendors=4, max_domain=2, max_vendor=3)
DAILY_BIGTECH_ONLY_HARD: PASS (bigtech=7, official_or_media=6)
PPTX_FORBIDDEN_HARD: PASS (0 pptx files)
GPU_MODE_REQUIRED_HARD: PASS (tok/s=25.2 >= 15)
```

### 【外部輸出】產物檔案

```
Name                  LastWriteTime       Length
----                  -------------       ------
latest_brief.md       3/7/2026 1:43:31 PM   7608
executive_report.docx 3/7/2026 1:43:27 PM  40072
PPTX: No PPTX files
```

### 字面核對

- stress_mode_triggered = **true**（gpu_load + run_timing 佐證）
- stress_trigger_level = **vram_busy**（注入 ratio=0.90>=0.85）
- stress_mode_name = **stress_600_vram_busy**
- test_injected = **true**（INJECT_GPU_VRAM_RATIO=0.90；僅影響 stress 判定，不影響品質 gate）
- time_budget_seconds = **600**（壓力硬上限）
- soft_target_seconds = **300**（壓力軟目標）
- selected_events = 7 >= 7
- domains=5>=4, vendors=4>=4
- devnoise=0, dev_forum_low=0
- PPTX=0
- 品質門檻全維持，僅時間預算從 175→600

### Section B vs C 對照

| 欄位 | Section B（常態） | Section C（壓力） |
|------|-------------------|-------------------|
| stress_mode_triggered | false | true |
| stress_trigger_level | soft_warning | vram_busy |
| time_budget_seconds | 175 | 600 |
| soft_target_seconds | 110 | 300 |
| total_seconds | 80 | 90 |
| selected_events | 7 | 7 |
| diversity PASS | yes | yes |
| PPTX | 0 | 0 |

---

## Section D — Git 提交與 Push

### 【外部輸出】git status -sb

```
## main...origin/main
```

### 【外部輸出】git push

```
200d17c..491fa0c  main -> main
```

### 【外部輸出】git rev-list --left-right --count origin/main...HEAD

```
0	0
```

### 提交記錄

```
0102aa6 iter57: make STRESS_600 trigger semantics strict (VRAM busy vs contention) + keep normal 110/175 reachable + evidence/meta hardening (no gate relaxation)
7611dc6 iter57: fix DAILY budget=175 propagation + two-tier stress trigger
491fa0c iter57: evidence pack — normal 175/110 success + stress 600/300 success (two-tier trigger semantics)
```
