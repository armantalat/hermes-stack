#!/bin/sh
# Hourly backup of /opt/data -> private HF dataset.
# Port of the HF kit's svc-backup.sh (works because private datasets need no PRO).
set -u

INTERVAL="${BACKUP_INTERVAL:-3600}"
FIRST="${BACKUP_FIRST_DELAY:-300}"

echo "[backup] first upload in ${FIRST}s, then every ${INTERVAL}s"
sleep "$FIRST"

while true; do
    if [ -n "${BACKUP_REPO:-}" ] && [ -n "${HF_TOKEN:-}" ]; then
        if python /kit/backup.py; then
            echo "[backup] $(date -u '+%F %T') uploaded to ${BACKUP_REPO}"
        else
            echo "[backup] $(date -u '+%F %T') upload FAILED"
        fi
    else
        echo "[backup] BACKUP_REPO/HF_TOKEN not set — skipping (state would only live on this VM)"
    fi
    sleep "$INTERVAL"
done
