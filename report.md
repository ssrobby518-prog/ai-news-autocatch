# AI 捕捉資訊 — 桌面按鈕 + 排程操作手冊

> Iter45 | commit: `d7a8326` | 2026-03-06

---

## 1. 現況摘要

| 項目 | 值 |
|------|------|
| 時間預算 | soft=160s (WARN) / hard=200s (FAIL → NOT_READY) |
| 每日排程 | 北京 09:00（UTC 01:00），Windows Scheduled Task |
| 桌面按鈕 | manual 模式，一鍵跑完整流程 |
| 成功產物 | `outputs/latest_brief.md` + `outputs/executive_report.docx` |
| 失敗產物 | `outputs/NOT_READY_report.md` + `outputs/NOT_READY_report.docx` |
| Log 位置 | `outputs/desktop_button.log`（每次追加，含 timestamp） |
| PPTX | 已禁止（不產出） |

### Manual vs Daily 差異

| | Manual（桌面按鈕） | Daily（排程） |
|---|---|---|
| 模式 | `-Mode manual` | `-Mode daily` |
| Z0 收集 | 線上（有 30/40s deadline） | 線上（有 30/40s deadline） |
| 跨日去重 | 不套用（允許重複） | overlap_with_prev_daily <= 2 |
| Dev forum | 允許 <= 1 | 零容忍（dev_forum_count = 0） |
| DOCX 自動開啟 | 是 | 是 |

---

## 2. 桌面捷徑設定

### 正式版

| 欄位 | 值（整行照貼） |
|------|------|
| **Target** | `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\scripts\desktop_button.ps1" -Mode manual` |
| **Start in** | `C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp` |

### 除錯版（視窗不關 + 完整 meta dump）

| 欄位 | 值（整行照貼） |
|------|------|
| **Target** | `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\scripts\desktop_button_debug.ps1" -Mode manual` |
| **Start in** | `C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp` |

### 為什麼以前按了沒反應

1. **Target 欄位塞了 `$env:XXX=...`**：Windows 捷徑 Target 不接受 PowerShell 語法，必須只放 `powershell.exe` + `-File` 路徑。環境變數必須在 .ps1 腳本內設定。
2. **視窗秒關**：沒有 `Read-Host` 或 `-NoExit`，PowerShell 執行完立即關閉視窗，使用者什麼都看不到。
3. **無 log**：stdout/stderr 只顯示在瞬間關閉的視窗中，無持久化日誌可查。

**現在的解法**：
- `desktop_button.ps1` 在腳本內設好所有 env var
- 結尾用 `Read-Host` 留窗
- 全程 `Tee-Object` 寫入 `outputs/desktop_button.log`

---

## 3. 每日排程安裝

```powershell
# 安裝（CurrentUser，不需管理員）
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Projects\ai捕捉資訊\ai-intel-scraper-mvp\scripts\install_daily_task_beijing_0900.ps1"
```

### 驗證指令（3 個）

```powershell
# 1) 查看 task 詳情
schtasks /Query /TN "AIIntelScraper_Daily_0900_BJ" /V /FO LIST

# 2) 手動立即跑一次
schtasks /Run /TN "AIIntelScraper_Daily_0900_BJ"

# 3) 查看上次執行結果
schtasks /Query /TN "AIIntelScraper_Daily_0900_BJ" /FO LIST | Select-String 'Last Run','Status','Next Run'
```

### 移除排程

```powershell
Unregister-ScheduledTask -TaskName "AIIntelScraper_Daily_0900_BJ" -Confirm:$false
```

---

## 4. 常見故障與對應

| 故障 | fail_reason | 原因 | 對應 |
|------|-------------|------|------|
| llama-server 未啟動 | `SERVER_NOT_READY` | 8080 port 無回應 | 啟動 llama-server：`cd C:/llama_node/llama-b8123-bin-win-cuda-12.4-x64 && ./llama-server.exe --model C:/llama_node/Qwen2.5-7B-Instruct-Q4_K_M/Qwen2.5-7B-Instruct-Q4_K_M.gguf --ctx-size 4096 --n-gpu-layers -1 --port 8080` |
| GPU 速度不足 | `GPU_MODE_REQUIRED_HARD` | tok/s < 15（CPU 模式或熱節流） | 確認 GPU 可用；等 60s 冷卻後重跑 |
| 超時 | `TIME_BUDGET_EXCEEDED` | 總耗時 > 200s | 檢查 Z0 收集是否卡住（看 z0_wall_clock_seconds）；若 translate 太慢，檢查 GPU 狀態 |
| 大廠比例不足 | `BIGTECH_DOMINANCE_HARD` | bigtech_hit < 5 或 official_or_media < 4 | 當日新聞不足；屬正常 fail，等隔天自然恢復 |
| Dev forum 雜訊 | `DEV_NOISE_CAP_HARD` | daily 模式 dev_forum_count > 0 | Pipeline 選到了 HuggingFace Forum 等來源；DAILY 零容忍，會自動產出 NOT_READY |
| 內容密度不足 | `DIGEST_DENSITY_FLOOR_HARD` | 某事件 bullets<5 且 chars<1200 | Pipeline 會先嘗試 density swap（替換稀薄事件）；若替換後仍不達標，產出 NOT_READY |
| 跨日重複過多 | `DAILY_DUP_OVER_CAP` | daily overlap > 2 | 當日新聞與前一天高度重疊；pipeline 嘗試替換，若替換不足則 NOT_READY |
| Pipeline gate 失敗 | `PIPELINE_GATE_FAIL: verify_run exit 1` | verify_run.ps1 內部某 gate 未通過 | 檢查 `outputs/desktop_button.log` 搜尋 "FAIL" 定位具體 gate |

---

## 5. 檔案清單

| 檔案 | 用途 |
|------|------|
| `scripts/desktop_button.ps1` | 桌面按鈕主 wrapper（manual/daily） |
| `scripts/desktop_button_debug.ps1` | 除錯版（-NoExit + meta dump） |
| `scripts/install_daily_task_beijing_0900.ps1` | 排程安裝腳本 |
| `scripts/verify_online.ps1` | 核心 pipeline 驅動（Z0 收集 + verify_run） |
| `outputs/desktop_button.log` | 執行日誌（每次追加） |
| `outputs/LAST_RUN_SUMMARY.txt` | 最近一次跑的摘要 |
| `outputs/run_timing.meta.json` | 計時 meta |
| `outputs/translation_engine.meta.json` | 翻譯引擎 meta |
| `outputs/selection_audit.meta.json` | 選稿審計 meta |
| `outputs/digest_density.meta.json` | 密度審計 meta |
| `outputs/gpu_probe.meta.json` | GPU 狀態 meta |

---

## 6. 驗收證據摘要

### Manual 模式（Section B）

```
run_id              = 20260306_163202
mode                = manual
status              = OK
selected_events     = 7
total_seconds       = 61 (soft=160 hard=200)
bigtech_hit         = 7
dev_forum_count     = 0
distinct_sources    = 3
est_all_miss        = 156s (<= 185s)
DOCX auto-open      = YES
```

### Daily 模式（Section C）

```
run_id              = 20260306_163509
mode                = daily
status              = OK
selected_events     = 7
total_seconds       = 60 (soft=160 hard=200)
bigtech_hit         = 7
dev_forum_count     = 0
distinct_sources    = 3
overlap_with_prev   = 0
est_all_miss        = 151s (<= 185s)
DOCX auto-open      = YES
```

### 排程安裝

```
Task name    : AIIntelScraper_Daily_0900_BJ
Schedule     : Daily at 17:00 local (= Beijing 09:00)
Status       : Ready / Enabled
```
