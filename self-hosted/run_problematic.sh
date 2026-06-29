#!/bin/bash
# Validation run for the 7 "problematic" back-catalog anime on canada-3.
# SHIP_HOST="" -> encode + verify LOCALLY (skip the slow ~18 Mbps ship to the canada-2 test
# origin; it isn't frontend-served anyway). Still marks Mongo coverage via CALLBACK_URL.
# Ledger NOT cleared -> resume (skip episodes already built/marked), so we don't re-download.
# ALL-NVENC: the back-catalog is heavy on HEVC/10-bit sources that can't remux and need a FULL
# 1080p re-encode. libx264 (CPU) does that at ~1x realtime (~20 min/ep); NVENC does it in ~3-4 min.
# So 0 CPU workers, 3 concurrent NVENC sessions (the 2080 Ti handles 3 fine).
cd /data
[ -f /data/callback.env ] && source /data/callback.env
TODO_FILE=/data/todo_problematic.jsonl \
DONE_LEDGER=/data/done_problematic.jsonl \
NGPU=1 GPU_WORKERS_PER=3 CPU_WORKERS=0 MAXQ=8 DL_THREADS=8 \
SHIP_HOST="" SHIP_DEST=/data/ship_local \
CALLBACK_URL="${CALLBACK_URL}" CALLBACK_TOKEN="${SELFHOST_INGEST_TOKEN}" \
python3 nzb_farm.py
