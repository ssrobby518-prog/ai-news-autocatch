# iter66: crawl-layer density*1.5 + single-domain<=1/3 on all entrypoints + scheduler logging

run_date: 2026-03-07

## 規則

### P0 — Fingerprint（兩入口都印）
- RUN_ID, GIT_HEAD, ENTRYPOINT, DOMAIN_COUNTS, MAX_DOMAIN_SHARE, DENSITY_MULTIPLIER_TARGET=1.5
- desktop_button.ps1 → ENTRYPOINT=desktop_button
- install_daily_task_beijing_0900.ps1 → ENTRYPOINT=scheduled_task

### P1 — Scheduler log
- 排程路徑 tee 到 outputs/scheduler.log（Tee-Object -Append）

### P2 — Single domain <= 1/3（所有路徑）
- 硬門檻：`max_domain_count * 3 <= selected_events`
- Gate：SINGLE_DOMAIN_SHARE_CAP_HARD_DAILY

### P3 — Density * 1.5 at crawl layer
- 公式：`density_score = 2*numbers + 1*proper_noun + 3*action + 2*spec`
- base_density_min=8（固定常數）, new_density_min=ceil(8*1.5)=12
- Pool filter: density_score < 12 排除
- Gate：SOURCE_DENSITY_MULTIPLIER_HARD_DAILY
- Research blog deprioritization: blog.research.google, research.google, arxiv.org, ar5iv.labs.arxiv.org

## Section A — Git（commit 前快照）

```
> git log --oneline -5
3caa7ee iter66: fix density gate — use fixed base_density_min=8 (threshold=12) + pool filter + research blog deprioritize
b2cca6a iter66: P0 fingerprint + P1 scheduler log + P2 domain cap all paths + P3 density*1.5 crawl layer
25ce5bd iter65: evidence pack — single-domain share <=1/3 hard cap (success + controlled injection fail)
80132d5 iter65: enforce single-domain share <=1/3 hard cap + controlled injection support
002da1f iter64: evidence hardening (git log -12 + auto-pick dir Test-Path proof)
```

## Section B — 桌面按鈕（Normal，無注入）

run_id=20260307_172705 | ENTRYPOINT=desktop_button | status=OK | total=86s

### 【外部輸出】type outputs\LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_172705
started_at          = 2026-03-07T17:28:31.4481034-08:00
finished_at         = 2026-03-07T17:28:31.4481034-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 【外部輸出】type outputs\bigtech_diversity.meta.json

```json
{
  "run_id": "20260307_172705",
  "mode": "daily",
  "constraints": { "min_domains": 4, "max_domain": 2, "min_vendors": 4, "max_vendor": 2 },
  "selected_domains_distinct": 4,
  "selected_vendors_distinct": 5,
  "domain_counts": { "huggingface.co": 2, "techcrunch.com": 1, "inside.com.tw": 2, "github.com": 2 },
  "vendor_counts": { "HuggingFace": 2, "Google": 2, "NVIDIA": 1, "Microsoft": 1, "OpenAI": 1 },
  "max_domain_count": 2,
  "max_vendor_count": 2,
  "pass": true,
  "max_domain_share_rule": "max_domain_count*3 <= selected_events",
  "max_domain_share_ratio": 0.2857,
  "selected_events": 7,
  "domain_share_cap_pass": true,
  "max_vendor_share_rule": "max_vendor_count*3 <= selected_events",
  "max_vendor_share_ratio": 0.2857,
  "vendor_share_cap_pass": true
}
```

### 【外部輸出】type outputs\source_density.meta.json（摘要）

```
gate                        = SOURCE_DENSITY_MULTIPLIER_HARD_DAILY
density_formula             = 2*numbers + 1*proper_noun + 3*action + 2*spec
multiplier                  = 1.5
candidates_total            = 41
candidates_pass             = 27
candidates_fail             = 14
selected_pass               = 7
selected_fail               = 0
selected_all_pass           = true
selected_avg_density_score  = 34.14
selected_min_density_score  = 14
base_density_min            = 8
base_source                 = fixed_constant
new_density_min             = 12
density_multiplier_gate_pass = true
```

核對：selected_min=14 >= new_density_min=12 → PASS; pool filter 排除 14 個 density_score<12 的候選項

### 【外部輸出】type outputs\selection_audit.meta.json（摘要）

- selected_items_count: 7
- bigtech_hit_count: 7
- official_or_media_count: 5
- dev_forum_count: 2
- selected_domains_distinct: 4 (huggingface.co=2, techcrunch.com=1, inside.com.tw=2, github.com=2)
- selected_vendors_distinct: 5 (HuggingFace=2, Google=2, NVIDIA=1, Microsoft=1, OpenAI=1)
- diversity_pass: true
- domain_share_cap_pass: true (max_domain=2, 2*3=6<=7)
- vendor_share_cap_pass: true (max_vendor=2, 2*3=6<=7)

### 【外部輸出】Get-Item outputs\latest_brief.md, outputs\executive_report.docx

```
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 5:28 PM     8418
executive_report.docx 3/7/2026 5:28 PM    40740
```

### 【外部輸出】dir outputs\*.pptx

```
（空白 — 0 個 pptx）
```

## Section C — Scheduler 路徑驗證

### 排程任務安裝

```
> powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_daily_task_beijing_0900.ps1

Task name   : AIIntelScraper_Daily_0900_BJ
Beijing time: 09:00 (UTC+8)
UTC time    : 01:00
Local time  : 17:00 ((UTC-08:00) Baja California)
Script      : ...\scripts\desktop_button.ps1
Working dir : ...\ai-intel-scraper-mvp

Task 'AIIntelScraper_Daily_0900_BJ' registered successfully.
  Scheduler log: ...\outputs\scheduler.log
```

### 排程任務命令驗證

```
> schtasks /Query /TN "AIIntelScraper_Daily_0900_BJ" /V /FO LIST

Task To Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -Command
  $env:PIPELINE_ENTRYPOINT = 'scheduled_task';
  Set-Location '...';
  & '...\scripts\desktop_button.ps1' -Mode daily *>&1 |
  Tee-Object -FilePath '...\outputs\scheduler.log' -Append

Schedule Type: Daily
Start Time:    5:00:00 PM (local = Beijing 09:00)
Run As User:   s_robby518
```

核對：
- PIPELINE_ENTRYPOINT = 'scheduled_task'（排程路徑標識）
- Tee-Object → outputs\scheduler.log（排程日誌）
- desktop_button.ps1 -Mode daily（經由桌面按鈕包裝器）
- 排程時間 = 本地 17:00 = 北京 09:00 ✓

## Section D — 受控注入失敗

### D1 — 注入單一 domain 佔比 >1/3

注入：`INJECT_SINGLE_DOMAIN_COUNT=7` + `INJECT_SINGLE_DOMAIN_NAME=blog.research.google`

```
INJECT_SINGLE_DOMAIN_COUNT=7 INJECT_SINGLE_DOMAIN_NAME=blog.research.google: share cap overridden
FAST_600_MODE FAIL: gate=SINGLE_DOMAIN_SHARE_CAP_HARD_DAILY
  reason=SINGLE_DOMAIN_SHARE_CAP_HARD_DAILY_FAIL: max_domain=7 events=7 share=1.0 [test_injected=true]
Pipeline failed (exit code: 1)
LAST_RUN_SUMMARY.txt: status=FAIL
  fail_reason=PIPELINE_GATE_FAIL: SINGLE_DOMAIN_SHARE_CAP_HARD_DAILY
NOT_READY 二件套已產出（md + docx），無 pptx
```

### D2 — 注入低密度

注入：`INJECT_LOW_DENSITY_COUNT=7`

```
INJECT_LOW_DENSITY_COUNT=7: density scores overridden to 1
FAST_600_MODE FAIL: gate=SOURCE_DENSITY_MULTIPLIER_HARD_DAILY
  reason=SOURCE_DENSITY_MULTIPLIER_HARD_DAILY_FAIL: selected_min=1 < new_density_min=12
  selected_avg=1.0 multiplier=1.5 [test_injected=true]
Pipeline failed (exit code: 1)
LAST_RUN_SUMMARY.txt: status=FAIL
  fail_reason=PIPELINE_GATE_FAIL: SOURCE_DENSITY_MULTIPLIER_HARD_DAILY
NOT_READY 二件套已產出（md + docx），無 pptx
```

核對：
- D1: domain 注入 → SINGLE_DOMAIN_SHARE_CAP_HARD_DAILY FAIL ✓
- D2: density 注入 → SOURCE_DENSITY_MULTIPLIER_HARD_DAILY FAIL ✓
- 兩者均標記 test_injected=true

## Section E — Commit/Push

```
（commit 後填入）
```

---

# Progress Report — Iter63 Evidence Pack (Auto-pick Normal/Stress delivery_dir)

run_date: 2026-03-07

## Section A — Git（commit 前快照）

```
> git diff --name-only
（空白）

> git status -sb
## main...origin/main

> git rev-list --left-right --count origin/main...HEAD
0	0
```

### 【外部輸出】git log --oneline -12

```
b9ada5b iter63: progress report auto-pick normal/stress delivery_dir + full sha256 cross-proof + stress semantics pinned (no behavior change)
e528b0c iter62: update Section D with push evidence
b3efcfd iter62: evidence hardening — git logs + all-miss daily + docx timestamp proof
d6c254e iter61: progress report (auto-pick normal/stress delivery_dir; full sha256; no placeholders; no behavior change)
65d1810 iter60: evidence pack — normal+stress canonical & delivery_dir cross-proof (full sha256, no placeholders)
a7ab743 iter59b: harden evidence (no ellipsis sha256; no <DIR> placeholders; normal+stress delivery_dir cross-proof)
ff0a438 iter59: update report.md Section D with final push evidence
d7a6271 iter59: evidence pack — normal/stress cross-proof with delivery meta archive
b9e6c17 iter59: archive gpu_load + delivery_consistency + LAST_RUN_SUMMARY into delivery_dir for cross-proof
7c428af iter58: update Section D with push evidence
d4c47cc iter58: evidence pack — SHA-256 delivery consistency proof + soft_warning_no_switch naming
36f42cb iter58: SHA-256 delivery consistency proof + stress_mode_name soft_warning_no_switch
```

## Auto-pick 結果

```
AUTO_PICK_NORMAL_DIR=C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_153400_d6c254eee5c101361ea7cb9630986d428f194478
AUTO_PICK_STRESS_DIR=C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8
```

### 【外部輸出】powershell -NoProfile -Command "Test-Path 'C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_153400_d6c254eee5c101361ea7cb9630986d428f194478'; Test-Path 'C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8'"

```
True
True
```

## Section B — Normal（soft_warning_no_switch / triggered=false；以 delivery_dir 為主）

語意釘死：stress_mode_name=soft_warning_no_switch 表示僅 soft_warning 觀測、未切換 stress budget，因此 stress_mode_triggered=false。

### 【外部輸出】type outputs\deliveries\20260307_153400_d6c254eee5c101361ea7cb9630986d428f194478\LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_153148
started_at          = 2026-03-07T15:34:00.7052640-08:00
finished_at         = 2026-03-07T15:34:00.7052640-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 【外部輸出】type outputs\deliveries\20260307_153400_d6c254eee5c101361ea7cb9630986d428f194478\gpu_load.meta.json

```json
{
    "run_id":  "20260307_153148",
    "vram_used_mb":  5409,
    "vram_total_mb":  8188,
    "vram_ratio":  0.6606,
    "non_llama_gpu_proc_count":  2,
    "top_processes":  [
                          {
                              "pid":  20408,
                              "name":  "C:\\Users\\s_robby518\\AppData\\Local\\Programs\\Trae\\Trae.exe",
                              "used_mb":  0
                          },
                          {
                              "pid":  2248,
                              "name":  "[Insufficient Permissions]",
                              "used_mb":  0
                          },
                          {
                              "pid":  81512,
                              "name":  "C:\\Projects\\ai捕捉資訊\\qwen_inference_node_4060\\llama-b8123-bin-win-cuda-12.4-x64\\llama-server.exe",
                              "used_mb":  0
                          }
                      ],
    "stress_trigger_level":  "soft_warning",
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stress_reason":  "non_llama=2>=1 but vram_ratio=0.6606<0.7 — soft warning only",
    "test_injected":  false,
    "thresholds_used":  {
                            "vram_busy_ratio_threshold":  0.85,
                            "vram_busy_mb_reserve":  900,
                            "contention_proc_threshold":  2,
                            "contention_vram_ratio_threshold":  0.7
                        },
    "detected_at":  "2026-03-07T15:31:48.2108444-08:00"
}
```

### 【外部輸出】type outputs\deliveries\20260307_153400_d6c254eee5c101361ea7cb9630986d428f194478\delivery_consistency.meta.json

```json
{
    "run_id":  "20260307_153148",
    "verified_at":  "2026-03-07T15:34:00.9961408-08:00",
    "deliverables":  [
                         {
                             "file":  "latest_brief.md",
                             "sha256":  "3880ed4d8cdeea5c0d21bd4c7f93ee816005c8b9f107edde86595bda2278a90e",
                             "length":  7486,
                             "last_write":  "2026-03-07T15:34:00.7558727-08:00"
                         },
                         {
                             "file":  "executive_report.docx",
                             "sha256":  "b2bab354a8591283d5327bceb3deeecbbfeaadf04d201bdd985a5f8939c7afc6",
                             "length":  39972,
                             "last_write":  "2026-03-07T15:33:57.6760444-08:00"
                         }
                     ],
    "same_run_verified":  true
}
```

## Section C — Stress（stress_600_vram_busy / triggered=true；以 delivery_dir 為主）

### 【外部輸出】type outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8\LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_145024
started_at          = 2026-03-07T14:51:52.7969830-08:00
finished_at         = 2026-03-07T14:51:52.7969830-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 【外部輸出】type outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8\gpu_load.meta.json

```json
{
    "run_id":  "20260307_145024",
    "vram_used_mb":  5447,
    "vram_total_mb":  8188,
    "vram_ratio":  0.9,
    "non_llama_gpu_proc_count":  2,
    "top_processes":  [
                          {
                              "pid":  20408,
                              "name":  "C:\\Users\\s_robby518\\AppData\\Local\\Programs\\Trae\\Trae.exe",
                              "used_mb":  0
                          },
                          {
                              "pid":  2248,
                              "name":  "[Insufficient Permissions]",
                              "used_mb":  0
                          },
                          {
                              "pid":  81512,
                              "name":  "C:\\Projects\\ai捕捉資訊\\qwen_inference_node_4060\\llama-b8123-bin-win-cuda-12.4-x64\\llama-server.exe",
                              "used_mb":  0
                          }
                      ],
    "stress_trigger_level":  "vram_busy",
    "stress_mode_triggered":  true,
    "stress_mode_name":  "stress_600_vram_busy",
    "stress_reason":  "vram_ratio=0.9000>=0.85 OR used=5447MB>=total-900=7288MB",
    "test_injected":  true,
    "thresholds_used":  {
                            "vram_busy_ratio_threshold":  0.85,
                            "vram_busy_mb_reserve":  900,
                            "contention_proc_threshold":  2,
                            "contention_vram_ratio_threshold":  0.7
                        },
    "detected_at":  "2026-03-07T14:50:25.1224815-08:00"
}
```

### 【外部輸出】type outputs\deliveries\20260307_145152_a7ab743ca6c38635112783a7264f6bce238f97e8\delivery_consistency.meta.json

```json
{
    "run_id":  "20260307_145024",
    "verified_at":  "2026-03-07T14:51:53.0751262-08:00",
    "deliverables":  [
                         {
                             "file":  "latest_brief.md",
                             "sha256":  "709146d7396f8230cb447ad7e1466e2c4502a7a634ffd8a5ebf658e956082a25",
                             "length":  7608,
                             "last_write":  "2026-03-07T14:51:52.8818475-08:00"
                         },
                         {
                             "file":  "executive_report.docx",
                             "sha256":  "11992465200e9a0385724f5e838b97debcd41acc1ca3f196062420c151cb8011",
                             "length":  40072,
                             "last_write":  "2026-03-07T14:51:49.3887360-08:00"
                         }
                     ],
    "same_run_verified":  true
}
```

## Section D — Canonical 現況（可能被後續 run 覆寫；以 delivery_dir 交叉證據為準）

### 【外部輸出】type outputs\LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_153148
started_at          = 2026-03-07T15:34:00.7052640-08:00
finished_at         = 2026-03-07T15:34:00.7052640-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### 【外部輸出】type outputs\gpu_load.meta.json

```json
{
    "run_id":  "20260307_153148",
    "vram_used_mb":  5409,
    "vram_total_mb":  8188,
    "vram_ratio":  0.6606,
    "non_llama_gpu_proc_count":  2,
    "top_processes":  [
                          {
                              "pid":  20408,
                              "name":  "C:\\Users\\s_robby518\\AppData\\Local\\Programs\\Trae\\Trae.exe",
                              "used_mb":  0
                          },
                          {
                              "pid":  2248,
                              "name":  "[Insufficient Permissions]",
                              "used_mb":  0
                          },
                          {
                              "pid":  81512,
                              "name":  "C:\\Projects\\ai捕捉資訊\\qwen_inference_node_4060\\llama-b8123-bin-win-cuda-12.4-x64\\llama-server.exe",
                              "used_mb":  0
                          }
                      ],
    "stress_trigger_level":  "soft_warning",
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stress_reason":  "non_llama=2>=1 but vram_ratio=0.6606<0.7 — soft warning only",
    "test_injected":  false,
    "thresholds_used":  {
                            "vram_busy_ratio_threshold":  0.85,
                            "vram_busy_mb_reserve":  900,
                            "contention_proc_threshold":  2,
                            "contention_vram_ratio_threshold":  0.7
                        },
    "detected_at":  "2026-03-07T15:31:48.2108444-08:00"
}
```

### 【外部輸出】type outputs\delivery_consistency.meta.json

```json
{
    "run_id":  "20260307_153148",
    "verified_at":  "2026-03-07T15:34:00.9961408-08:00",
    "deliverables":  [
                         {
                             "file":  "latest_brief.md",
                             "sha256":  "3880ed4d8cdeea5c0d21bd4c7f93ee816005c8b9f107edde86595bda2278a90e",
                             "length":  7486,
                             "last_write":  "2026-03-07T15:34:00.7558727-08:00"
                         },
                         {
                             "file":  "executive_report.docx",
                             "sha256":  "b2bab354a8591283d5327bceb3deeecbbfeaadf04d201bdd985a5f8939c7afc6",
                             "length":  39972,
                             "last_write":  "2026-03-07T15:33:57.6760444-08:00"
                         }
                     ],
    "same_run_verified":  true
}
```

### 【外部輸出】Get-Item outputs\latest_brief.md, outputs\executive_report.docx | Select Name,LastWriteTime,Length | Format-Table -AutoSize

```
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 3:34:00 PM   7486
executive_report.docx 3/7/2026 3:33:57 PM  39972
```

## 交付物一致性（以 SHA-256 + same_run_verified 為準；不做 docx>=md 硬比較）

依據 Normal/Stress 的 delivery_consistency.meta.json：same_run_verified=true，且每個 deliverable 具備 sha256/length/last_write，可核對為同 run 產物。

## Section E — Commit/Push

```
（commit 後填入）
```

---

# iter62: Evidence Hardening — git logs + all-miss daily + docx timestamp proof

run_date: 2026-03-07

## Section A — Git 狀態 + 歷史

### Step 0 — 乾淨確認

```
> git diff --name-only
（空白）

> git status -sb
## main...origin/main

> git rev-list --left-right --count origin/main...HEAD
0	0
```

### git log --oneline -12

```
d6c254e iter61: progress report (auto-pick normal/stress delivery_dir; full sha256; no placeholders; no behavior change)
65d1810 iter60: evidence pack — normal+stress canonical & delivery_dir cross-proof (full sha256, no placeholders)
a7ab743 iter59b: harden evidence (no ellipsis sha256; no <DIR> placeholders; normal+stress delivery_dir cross-proof)
ff0a438 iter59: update report.md Section D with final push evidence
d7a6271 iter59: evidence pack — normal/stress cross-proof with delivery meta archive
b9e6c17 iter59: archive gpu_load + delivery_consistency + LAST_RUN_SUMMARY into delivery_dir for cross-proof
7c428af iter58: update Section D with push evidence
d4c47cc iter58: evidence pack — SHA-256 delivery consistency proof + soft_warning_no_switch naming
36f42cb iter58: SHA-256 delivery consistency proof + stress_mode_name soft_warning_no_switch
0ec7226 iter57: update Section D with push evidence
491fa0c iter57: evidence pack — normal 175/110 success + stress 600/300 success (two-tier trigger semantics)
7611dc6 iter57: fix DAILY budget=175 propagation + two-tier stress trigger
```

### Per-file log: scripts/run_once.py + scripts/verify_online.ps1

```
b9e6c17 iter59: archive gpu_load + delivery_consistency + LAST_RUN_SUMMARY into delivery_dir for cross-proof
36f42cb iter58: SHA-256 delivery consistency proof + stress_mode_name soft_warning_no_switch
7611dc6 iter57: fix DAILY budget=175 propagation + two-tier stress trigger
0102aa6 iter57: make STRESS_600 trigger semantics strict (VRAM busy vs contention)
94b729f iter56: add VRAM-busy auto STRESS_600_MODE + GPU warmup stabilization
f79b1be iter55: Z0 drain cap enforcement + jitter epsilon + translation_engine stub + timestamp coherence
ffebc6a iter55: fix Z0 inflight drain cap + wallclock jitter epsilon
0d2c08c iter54e: DOCX write directly to final path — avoid shutil.move WinError 32
291db4f iter54e: fix DOCX WinError 32 — release python-docx lock before shutil.move
e12ffcc iter54e: fix diversity swap + hydration diversity injection for DAILY
7601acd iter54e: fix GitHub vendor classification
445e209 iter54d: include bigtech code_release in DAILY_BIGTECH_ONLY scope
a3c73a9 iter54: harden DAILY 110/170 + DAILY_BIGTECH_ONLY_HARD + docx atomic replace + z0 wallclock cap
```

### Per-file log: scripts/verify_run.ps1 + utils/fulltext_hydrator.py

```
4664a4a iter46: dev-forum de-prioritize + high-value-only exception
bfb2471 iter42b: forbid pptx outputs — pre-clean + generation block + PPTX_FORBIDDEN_HARD gate
9bdc889 iter42: DAILY soft160 hard200 + remove PPTX everywhere + stage deadlines
dbecaf4 feat(iter33): md+docx only, 600s hard cap, targeted hydration
f7f7c3c fix(iter26): shutdown(wait=False) in hydrate_items_batch
6e2da5e fix(iter26): use env vars for CJK-safe Python path passing in verify_run.ps1
```

## Section B — DAILY 成功（正常路徑，cache-hit）

### 命令

```
Remove-Item Env:INJECT_DEV_FORUM_LOW_VALUE -ErrorAction SilentlyContinue
Remove-Item Env:TRANSLATION_CACHE_BYPASS -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

### LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_153003
started_at          = 2026-03-07T15:31:22.3165126-08:00
finished_at         = 2026-03-07T15:31:22.3165126-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### run_timing.meta.json

```json
{
    "run_id":  "20260307_153003",
    "total_seconds":  79,
    "time_budget_seconds":  175,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  false,
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stage_seconds":  {
        "z0_collect_online":  56,
        "before_translation":  9.2,
        "translate":  0,
        "hydrate":  9,
        "build_docx":  0.2,
        "gates":  1
    }
}
```

### translation_engine.meta.json

```json
{
    "run_id": "20260307_153003",
    "calls_total": 0,
    "cache_hit": 7,
    "cache_miss": 0,
    "translate_mode": "all_cache_hit",
    "translate_seconds": 0.02,
    "est_total_seconds_if_all_miss": 151,
    "tok_per_sec_est": 23.16
}
```

### selection_audit.meta.json（摘要）

- selected_items_count: 7
- bigtech_hit_count: 7
- official_or_media_count: 7
- selected_domains_distinct: 5 (blog.research.google, huggingface.co, techcrunch.com, inside.com.tw, ithome.com.tw)
- selected_vendors_distinct: 4 (Google, HuggingFace, NVIDIA, Amazon)
- diversity_pass: true

### bigtech_diversity.meta.json

- domains>=4: 5 PASS
- max_domain<=2: 2 PASS
- vendors>=4: 4 PASS
- max_vendor<=3: 3 PASS
- pass: true

### DOCX/MD 時戳一致性

```
> Get-Item outputs\latest_brief.md, outputs\executive_report.docx | Select Name,LastWriteTime,Length | Format-Table -AutoSize
Name                  LastWriteTime       Length
latest_brief.md       3/7/2026 3:31:22 PM   7589
executive_report.docx 3/7/2026 3:31:19 PM  40141
```

核對：executive_report.docx LastWriteTime (3:31:19) 早於 latest_brief.md (3:31:22) — 兩者同 run，DOCX 在 MD 之前生成（正常流程）。DELIVERABLE_TIMESTAMP_COHERENCE: PASS。

### PPTX

```
> dir outputs\*.pptx
（空白 — 0 個 pptx）
```

## Section C — All-miss 模擬（TRANSLATION_CACHE_BYPASS=1）

### 命令

```
$env:TRANSLATION_CACHE_BYPASS="1"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_online.ps1 -Mode daily
```

### LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_153148
started_at          = 2026-03-07T15:34:00.7052640-08:00
finished_at         = 2026-03-07T15:34:00.7052640-08:00
mode                = daily
report_mode         = brief
status              = OK
selected_events     = 7
ai_selected_events  = 7
canonical_output_dir = outputs
produced_files      = outputs\latest_brief.md, outputs\executive_report.docx
```

### run_timing.meta.json

```json
{
    "run_id":  "20260307_153148",
    "total_seconds":  133,
    "time_budget_seconds":  175,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  true,
    "stress_mode_triggered":  false,
    "stress_mode_name":  "soft_warning_no_switch",
    "stage_seconds":  {
        "z0_collect_online":  60,
        "before_translation":  10.4,
        "translate":  49.7,
        "hydrate":  10.2,
        "build_docx":  0.3,
        "gates":  1
    }
}
```

### translation_engine.meta.json

```json
{
    "run_id": "20260307_153148",
    "calls_total": 7,
    "calls_success": 7,
    "calls_timeout": 0,
    "calls_error": 0,
    "cache_hit": 0,
    "cache_miss": 7,
    "translate_mode": "all_miss",
    "translate_seconds": 49.71,
    "tok_per_sec_est": 26.37,
    "tok_s_min": 25.67,
    "tok_s_avg": 30.19,
    "tok_s_max": 40.59,
    "est_total_seconds_if_all_miss": 133
}
```

### 核對

- translate_mode = all_miss（非 cache-hit）
- cache_miss = 7 > 0
- total_seconds = 133 <= 175 (hard PASS)
- soft_target_exceeded = true (133 > 110; 已知 all-miss 路徑超 soft 屬預期)

## Section D — Commit/Push

```
> git log --oneline -3
b3efcfd iter62: evidence hardening — git logs + all-miss daily + docx timestamp proof
d6c254e iter61: progress report (auto-pick normal/stress delivery_dir; full sha256; no placeholders; no behavior change)
65d1810 iter60: evidence pack — normal+stress canonical & delivery_dir cross-proof (full sha256, no placeholders)

> git rev-list --left-right --count origin/main...HEAD
0	0
```
