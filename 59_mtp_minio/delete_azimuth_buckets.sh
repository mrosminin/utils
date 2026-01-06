#!/usr/bin/env bash
set -euo pipefail

# Удаляет бакеты azimuth-service-YYYY-MM-DD (и azimuth_service-YYYY-MM-DD) за указанный месяц
# Usage:
#   ./delete_azimuth_buckets.sh 2024 03
#
# Запускать лучше так:
#   cd ~/purge-buckets
#   sudo nohup ./delete_azimuth_buckets.sh 2024 03 >/dev/null 2>&1 &

YEAR="${1:-}"
MONTH="${2:-}"

if [[ -z "$YEAR" || -z "$MONTH" ]]; then
  echo "Usage: $0 <YEAR> <MONTH>"
  echo "Example: $0 2024 03"
  exit 1
fi

if ! [[ "$YEAR" =~ ^[0-9]{4}$ ]]; then
  echo "ERROR: YEAR must be YYYY"
  exit 1
fi

if ! [[ "$MONTH" =~ ^[0-9]{2}$ ]] || ((10#$MONTH < 1 || 10#$MONTH > 12)); then
  echo "ERROR: MONTH must be 01..12"
  exit 1
fi

ALIAS="local"
MC_USER="user05"
MC=(sudo -u "$MC_USER" mc)

IONICE_CLASS=2   # 3 = idle (минимально мешает MinIO). Если слишком медленно — поставь 2
IONICE_LEVEL=7   # актуально только для class=2 (0..7, где 7 самый низкий)
NICE_LEVEL=19

LOG_DIR="$(pwd)"
LOG_FILE="${LOG_DIR}/delete_azimuth_${YEAR}-${MONTH}_$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/tmp/delete_azimuth_${YEAR}-${MONTH}.lock"

run_rb() {
  local target="$1" # например local/bucket

  if [[ "$IONICE_CLASS" -eq 3 ]]; then
    ionice -c3 nice -n "$NICE_LEVEL" "${MC[@]}" rb --force --dangerous "$target"
  else
    ionice -c2 -n "$IONICE_LEVEL" nice -n "$NICE_LEVEL" "${MC[@]}" rb --force --dangerous "$target"
  fi
}


log() {
  echo "[$(date -Is)] $*" | tee -a "$LOG_FILE"
}

cleanup() {
  rm -f "$LOCK_FILE" || true
}
trap cleanup EXIT

if [[ -e "$LOCK_FILE" ]]; then
  echo "ERROR: Lock exists: $LOCK_FILE (another run?)"
  exit 1
fi
touch "$LOCK_FILE"

log "START delete azimuth buckets for ${YEAR}-${MONTH}"
log "ALIAS=$ALIAS MC_USER=$MC_USER LOG=$LOG_FILE"

# Список бакетов:
# mc ls: ... 0B bucketname/
# Берём последний столбец, режем / на конце.
BUCKETS="$(
  "${MC[@]}" ls "$ALIAS" 2>>"$LOG_FILE" \
    | awk '{print $NF}' \
    | sed 's:/*$::' \
    | grep -E "^(azimuth-service|azimuth_service)-${YEAR}-${MONTH}-[0-9]{2}$" \
    | sort
)"

if [[ -z "$BUCKETS" ]]; then
  log "No buckets matched for ${YEAR}-${MONTH}"
  exit 0
fi

log "Matched buckets:"
echo "$BUCKETS" | tee -a "$LOG_FILE"

# Удаляем по одному с ретраями
for b in $BUCKETS; do
  log "-----"
  log "DELETE bucket: $b"

  # если уже нет — ок
  if ! "${MC[@]}" stat "${ALIAS}/${b}" >/dev/null 2>&1; then
    log "SKIP/OK: bucket not exists"
    continue
  fi

  bucket_t0=$(date +%s)
  avail_before=$(df -B1 /passages | awk 'END{print $4}')
  log "BEFORE: avail_bytes=$avail_before"

  ok=0
  for attempt in 1 2 3 4 5; do
    attempt_t0=$(date +%s)
    log "Attempt $attempt: ionice(class=$IONICE_CLASS level=$IONICE_LEVEL) nice=$NICE_LEVEL mc rb ..."

    if run_rb "${ALIAS}/${b}" >>"$LOG_FILE" 2>&1; then
      attempt_t1=$(date +%s)
      log "Attempt $attempt: OK in $((attempt_t1-attempt_t0))s"
      ok=1
      log "DELETE: OK"
      break
    fi

    attempt_t1=$(date +%s)
    log "Attempt $attempt: FAILED in $((attempt_t1-attempt_t0))s"

    # если после ошибки бакет уже исчез — считаем ок
    if ! "${MC[@]}" stat "${ALIAS}/${b}" >/dev/null 2>&1; then
      ok=1
      log "DELETE: OK (bucket already gone)"
      break
    fi

    log "DELETE: FAILED, will retry after 30s"
    sleep 30
  done

  if [[ "$ok" -ne 1 ]]; then
    log "DELETE: GAVE UP after retries (bucket still exists): $b"
  fi

  avail_after=$(df -B1 /passages | awk 'END{print $4}')
  bucket_t1=$(date +%s)
  log "AFTER:  avail_bytes=$avail_after delta_bytes=$((avail_after-avail_before))"
  log "TIME:   bucket_total_seconds=$((bucket_t1-bucket_t0))"
done

log "FINISH delete azimuth buckets for ${YEAR}-${MONTH}"
