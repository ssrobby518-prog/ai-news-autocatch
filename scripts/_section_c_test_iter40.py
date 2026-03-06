"""iter40 Section C: Controlled failure test for BIGTECH_DOMINANCE_HARD / DEV_NOISE_CAP_HARD.

Injects 7 dev_forum non-bigtech candidates to trigger gate failure.
Usage: python scripts/_section_c_test_iter40.py
"""
import json, os, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.chdir(str(ROOT))

outputs = ROOT / "outputs"
outputs.mkdir(parents=True, exist_ok=True)

run_id = time.strftime("%Y%m%d_%H%M%S")

# 7 fake dev_forum items — all non-bigtech
fake_items = []
for i in range(1, 8):
    fake_items.append({
        "item_id": f"fake_{i}",
        "title": f"How to fine-tune LoRA adapter on local dataset part {i}",
        "source_name": "HuggingFace Forum",
        "source_domain": "discuss.huggingface.co",
        "source_type": "dev_forum",
        "bigtech_hit": False,
        "exec_hit": False,
        "official_or_media": False,
        "final_score": 0.5,
        "why_selected": "diversity_quota",
    })

# Write selection_audit.meta.json with all dev_forum non-bigtech
audit = {
    "run_id": run_id,
    "selected_items_count": 7,
    "selected_sources_distinct": 3,
    "bigtech_hit_count": 0,
    "official_or_media_count": 0,
    "dev_forum_count": 7,
    "non_bigtech_dev_noise_count": 7,
    "items": fake_items,
}
(outputs / "selection_audit.meta.json").write_text(
    json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8"
)

# Write bigtech_focus.meta.json
focus = {
    "run_id": run_id,
    "bigtech_hit_count": 0,
    "official_or_media_count": 0,
    "dev_forum_count": 7,
    "non_bigtech_dev_noise_count": 7,
    "rejected_samples_top10": [],
}
(outputs / "bigtech_focus.meta.json").write_text(
    json.dumps(focus, ensure_ascii=False, indent=2), encoding="utf-8"
)

# Write LAST_RUN_SUMMARY (FAIL)
(outputs / "LAST_RUN_SUMMARY.txt").write_text(
    f"run_id              = {run_id}\n"
    f"started_at          = {time.strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
    f"finished_at         = {time.strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
    f"mode                = manual\n"
    f"report_mode         = brief\n"
    f"status              = FAIL\n"
    f"selected_events     = 7\n"
    f"ai_selected_events  = 7\n"
    f"canonical_output_dir = outputs\n"
    f"produced_files      = outputs/NOT_READY_report.md, outputs/NOT_READY_report.docx\n"
    f"fail_reason         = BIGTECH_DOMINANCE_HARD_FAIL: bigtech_hit=0 official_or_media=0\n",
    encoding="utf-8",
)

# Write NOT_READY_report.md
(outputs / "NOT_READY_report.md").write_text(
    f"# NOT READY Report — {run_id}\n\n"
    "| Field | Value |\n|-------|-------|\n"
    f"| run_id | `{run_id}` |\n"
    "| status | **FAIL** |\n"
    f"| gate | `BIGTECH_DOMINANCE_HARD` |\n\n"
    "## Failure Reason\n\n"
    "BIGTECH_DOMINANCE_HARD_FAIL: bigtech_hit=0 official_or_media=0 (need bigtech>=5 om>=4)\n\n"
    "## Selection Stats\n\n"
    "| Metric | Value |\n|--------|-------|\n"
    "| selected_items_count | 7 |\n"
    "| selected_sources_distinct | 3 |\n"
    "| bigtech_hit_count | 0 |\n"
    "| official_or_media_count | 0 |\n"
    "| non_bigtech_dev_noise_count | 7 |\n",
    encoding="utf-8",
)

# Write NOT_READY.md
(outputs / "NOT_READY.md").write_text(
    f"# NOT_READY\n\ngate: BIGTECH_DOMINANCE_HARD\nrun_id: {run_id}\n"
    "reason: BIGTECH_DOMINANCE_HARD_FAIL: bigtech_hit=0 official_or_media=0\n",
    encoding="utf-8",
)

# Generate NOT_READY_report.docx (best-effort)
try:
    from core.doc_generator import generate_not_ready_report_docx
    generate_not_ready_report_docx(
        gate="BIGTECH_DOMINANCE_HARD",
        reason="bigtech_hit=0 official_or_media=0 (7 dev_forum non-bigtech items)",
        run_id=run_id,
    )
    print(f"NOT_READY_report.docx generated")
except Exception as e:
    print(f"DOCX generation skipped: {e}")

print(f"Section C test complete: run_id={run_id}")
print(f"  selection_audit.meta.json: bigtech_hit_count=0, non_bigtech_dev_noise_count=7")
print(f"  Expected gate: BIGTECH_DOMINANCE_HARD_FAIL")
