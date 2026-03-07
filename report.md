# iter55e 證據包 — GPU warmup 穩定化驗證 + 同輪 B/C 輸出

run_date: 2026-03-07
commit_base: d35deb2 (iter55: update report.md Section D with commit evidence)

---

## Section A：Git 狀態與差異

本輪唯一提交檔案為 report.md（證據包硬化），不涉及程式碼變更。

```
git status -sb:
## main...origin/main

git log --oneline -5:
d35deb2 iter55: update report.md Section D with commit evidence
f79b1be iter55: Z0 drain cap enforcement + jitter epsilon + translation_engine stub + timestamp coherence
ffebc6a iter55: fix Z0 inflight drain cap + wallclock jitter epsilon + fail-fast translation_engine stub + deliverable timestamp coherence
7b27bb1 iter55: fix Z0 inflight drain cap + wallclock jitter epsilon + fail-fast translation_engine stub + deliverable timestamp coherence
c4dfe66 iter54: evidence pack — DAILY_BIGTECH_ONLY + diversity + DOCX timestamp fix

git diff --name-only:
report.md（唯一變更檔案）
```

**git rev-list（push 後補填）：見 Section D**

---

## Section B：本輪 DAILY 運行（GPU_MODE_REQUIRED_HARD fail-fast）

**結果**：GPU_MODE_REQUIRED_HARD 擋下（tok/s=0.64 < 15）。Pipeline 未進入 z0 collect/hydrate/translate 階段。

**根因**：GPU 環境異常 — 多個程序（Trae.exe、2 個權限不足程序）與 llama-server 共享 GPU，VRAM 近滿載（7645/8188 MiB），導致推理速度嚴重低於正常值。此為硬體/環境因素，非程式邏輯問題。

### 【外部輸出】LAST_RUN_SUMMARY.txt

```
run_id              = 20260307_122527
started_at          = 2026-03-07T12:26:11.9221247-08:00
finished_at         = 2026-03-07T12:26:11.9221247-08:00
mode                = daily
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx
fail_reason         = GPU_MODE_REQUIRED_HARD
```

### 【外部輸出】run_timing.meta.json

```json
{
    "run_id":  "20260307_122527",
    "started_at":  "2026-03-07T12:25:27",
    "finished_at":  "2026-03-07T12:26:11",
    "total_seconds":  45,
    "time_budget_seconds":  600,
    "soft_target_seconds":  110,
    "soft_target_exceeded":  false
}
```

### 【外部輸出】gpu_probe.meta.json

```json
{"vram_mb":0,"nvidia_smi_ok":true,"tok_per_sec_est":0.64,"gpu_required":true,"tok_threshold":15,"gpu_process_found":true,"run_id":"20260307_122527","reason":"tok_per_sec_below_threshold","probed_at":"2026-03-07T12:26:09.9268225-08:00"}
```

### 【外部輸出】translation_engine.meta.json

```json
{"cache_hit":0,"translate_mode":"not_started","calls_total":0,"events_total":0,"fail_reason":"GPU_MODE_REQUIRED_HARD","success":false,"cache_miss":0,"generated_at":"2026-03-07T12:26:11.9140608-08:00","run_id":"20260307_122527","endpoint":"http://127.0.0.1:8080"}
```

### 【外部輸出】bigtech_diversity / selection_audit / dev_forum_audit

因 GPU_MODE_REQUIRED_HARD fail-fast 於 z0 collect 前中斷，這些 meta 檔為上一輪殘留（非本 run_id），故不作為本輪證據。

### 【外部輸出】產物檔案

```
Name                  LastWriteTime        Length
----                  -------------        ------
NOT_READY_report.md   3/7/2026 12:26:12 PM   1306
NOT_READY_report.docx 3/7/2026 12:26:11 PM  35889
PPTX: 無（PPTX_FORBIDDEN_HARD 三層防線有效）
```

### docx >= md 時間戳核對

docx LastWriteTime = 12:26:11 PM, md LastWriteTime = 12:26:12 PM
**docx < md（差 1 秒）**：此為 NOT_READY 報告（非正常產物），docx 先寫、md 後寫為 fail-fast 路徑正常順序。

---

## Section C：注入受控失敗（INJECT_DEV_FORUM_LOW_VALUE=7；預期 exit code=1）

受控失敗（預期 exit code=1），用於驗證 gate 能確實攔截。
**本次注入測試因 GPU_MODE_REQUIRED_HARD fail-fast 提前結束；stub 已落盤；此為 GPU 探針未達門檻的可核對證據。**

### 【外部輸出】Pipeline 輸出（exit code=1）

```
FAST_300_DAILY=1（線上收集+大廠配額+硬上限=600s）
[GPU_MODE_REQUIRED_HARD] tok/s 探針啟動...
  探針完成: model=Qwen2.5-7B-Instruct-Q4_K_M.gguf  output_tokens=27  elapsed=14.47s  tok_per_sec_est=1.9
  GPU_MODE_REQUIRED_HARD: tok_per_sec_est=1.9 threshold=15  gpu_evidence=True (gpu_found=True vram=0MB)
  => 失敗: GPU_MODE_REQUIRED_HARD: tok_per_sec_est=1.9 < 15 (CPU mode detected — GPU inference not active)
[verify_online] FAIL-FAST: GPU_MODE_REQUIRED_HARD
LAST_RUN_SUMMARY.txt written: status=FAIL  fail_reason=GPU_MODE_REQUIRED_HARD
  ⏱️ 總耗時：18 秒（0 分 18 秒）
```

### 【外部輸出】LAST_RUN_SUMMARY.txt（Section C run_id）

```
run_id              = 20260307_123109
started_at          = 2026-03-07T12:31:27.3712071-08:00
finished_at         = 2026-03-07T12:31:27.3712071-08:00
mode                = daily
report_mode         = brief
status              = FAIL
selected_events     = 0
ai_selected_events  = 0
canonical_output_dir = outputs
produced_files      = outputs\NOT_READY_report.md, outputs\NOT_READY_report.docx
fail_reason         = GPU_MODE_REQUIRED_HARD
```

### 【外部輸出】translation_engine.meta.json（stub 已落盤）

```json
{"cache_hit":0,"translate_mode":"not_started","calls_total":0,"events_total":0,"fail_reason":"GPU_MODE_REQUIRED_HARD","success":false,"cache_miss":0,"generated_at":"2026-03-07T12:31:27.3579440-08:00","run_id":"20260307_123109","endpoint":"http://127.0.0.1:8080"}
```

### 【外部輸出】NOT_READY_report.md（前 50 行）

```markdown
# NOT READY Report — 20260307_123109

| Field | Value |
|-------|-------|
| run_id | `20260307_123109` |
| mode | manual |
| report_mode | brief |
| status | **FAIL** |
| generated_at | 2026-03-07 20:31 UTC |
| test_injected | `true` |

## Failure

- gate: `GPU_MODE_REQUIRED_HARD`
- fail_reason: GPU_MODE_REQUIRED_HARD: tok_per_sec_est=1.9 < 15 (CPU mode detected — GPU inference not active)

## ⏱️ 本次流程耗時
- run_id：20260307_123109
- 開始：2026-03-07 12:31:09
- 結束：2026-03-07 12:31:27
- 總耗時：18 秒（0 分 18 秒）
```

### 【外部輸出】NOT_READY 產物

```
Name                  LastWriteTime        Length
----                  -------------        ------
NOT_READY_report.md   3/7/2026 12:31:27 PM   1443
NOT_READY_report.docx 3/7/2026 12:31:27 PM  35890
```

### Attempt-1 歷史 vendors=3 證據

【外部輸出】verify_run.latest.log 搜索結果：

```
outputs\verify_run.latest.log:52:2026-03-07T11:24:01 | ERROR | ai_intel |
FAST_600_MODE FAIL: gate=BIGTECH_DIVERSITY_HARD_DAILY
reason=BIGTECH_DIVERSITY_UNSATISFIED: domains=5 vendors=1 max_domain=2 max_vendor=7 [test_injected=true]
```

注意：此為 test_injected=true 的歷史注入測試記錄（vendors=1 而非 vendors=3）。outputs 未保存 vendors=3 當時片段；本輪不強行重現，僅保留歷史敘述（不當作硬證據）。

---

## GPU Warmup 穩定化證據

### 背景

Section B/C 執行前，先做 GPU warmup 穩定化（連續推理請求），目標為取得連續 3 次 tok/s>=15 的穩定證據。

### 【外部輸出】GPU 環境狀態

```
nvidia-smi: temperature=69°C, utilization=38%, VRAM=7645/8188 MiB
GPU 程序: Trae.exe, 2x [Insufficient Permissions], llama-server.exe
```

### 【外部輸出】Warmup Round 1（timeout=60s）

```
WARMUP_1: tok_s=1.3 wall=30.77s
WARMUP_2: tok_s=0.9 wall=43.98s
WARMUP_3: tok_s=2.4 wall=15.83s
WARMUP_4: tok_s=40.7 wall=0.93s
WARMUP_5: tok_s=1.1 wall=38.52s
WARMUP_6: tok_s=1.2 wall=32.60s
```

### 【外部輸出】Warmup Round 2（cooldown 後，minimal payload）

```
WARMUP_1: tok_s=22.0 wall=16.71s
WARMUP_2: tok_s=1.4 wall=5.33s
WARMUP_3: tok_s=0.5 wall=18.60s
WARMUP_4: tok_s=1.9 wall=7.89s
WARMUP_5: tok_s=1.1 wall=7.74s
WARMUP_6: tok_s=1.6 wall=7.57s
```

### 判定

**未能取得連續 3 次 tok/s>=15**。偶發單次高峰（40.7, 22.0）但不連續。GPU 推理速度因 VRAM 滿載 + 多程序競爭而嚴重不穩定。

此為硬體/環境因素：
1. **VRAM 滿載**：7645/8188 MiB（93.4%），llama-server 與 Trae.exe 等程序共用
2. **GPU 競爭**：4 個程序共享 RTX 4060 Laptop GPU
3. **熱節流風險**：69°C 持續負載下可能觸發降頻

**結論**：GPU_MODE_REQUIRED_HARD 門檻（tok/s>=15）不做任何調整。本輪證據包確認 gate 在 GPU 不穩定環境下能正確攔截，fail-fast 行為符合設計預期。待 GPU 環境恢復（關閉佔用 GPU 的程序）後可重新執行完整 DAILY pipeline。

---

## Section D：Git 提交證據

（push 後補填）
