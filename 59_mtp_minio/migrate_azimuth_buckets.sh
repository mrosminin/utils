#!/usr/bin/env bash
set -euo pipefail

# Миграция бакетов azimuth-service-YYYY-MM-* с /passages/s3 в /passages2/s3
# Копирование через cp -a, затем удаление бакета через sudo -u user05 mc rb --dangerous
#
# Usage:
#   sudo ./migrate_azimuth_buckets.sh 2024 03
#
# Требования:
# - alias "local" настроен: sudo -u user05 mc alias set local ...
# - MinIO хранит данные в /passages/s3 (как у вас)
# - /passages2/s3 существует и доступен

YEAR="${1:-}"
MONTH="${2:-}"

if [[ -z "$YEAR" || -z "$MONTH" ]]; then
  echo "Usage: sudo $0 <YEAR> <MONTH>"
  echo "Example: sudo $0 2024 03"
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

SRC_ROOT="/passages/s3"
DST_ROOT="/passages2/s3"
ALIAS="local"

LOG_DIR="$(pwd)"
LOG_FILE="${LOG_DIR}/migrate_azimuth_${YEAR}-${MONTH}_$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/tmp/migrate_azimuth_${YEAR}-${MONTH}.lock"

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

# prechecks
if [[ ! -d "$SRC_ROOT" ]]; then
  echo "ERROR: SRC_ROOT not found: $SRC_ROOT"
  exit 1
fi
if [[ ! -d "$DST_ROOT" ]]; then
  echo "ERROR: DST_ROOT not found: $DST_ROOT"
  exit 1
fi

log "START migrate azimuth-service for ${YEAR}-${MONTH}"
log "SRC_ROOT=$SRC_ROOT"
log "DST_ROOT=$DST_ROOT"
log "ALIAS=$ALIAS"
log "LOG=$LOG_FILE"

log "Disk space:"
df -h "$SRC_ROOT" "$DST_ROOT" | tee -a "$LOG_FILE" || true
log "Inodes:"
df -i "$SRC_ROOT" "$DST_ROOT" | tee -a "$LOG_FILE" || true

# Получаем список бакетов (имена без слэша)
# Вывод sudo -u user05 mc ls: ... 0B bucketname/
BUCKETS="$(
  sudo -u user05 mc ls "$ALIAS" 2>>"$LOG_FILE" \
    | awk '{print $NF}' \
    | sed 's:/*$::' \
    | grep -E "^azimuth-service-${YEAR}-${MONTH}-[0-9]{2}$" \
    | sort
)"

if [[ -z "$BUCKETS" ]]; then
  log "No buckets matched azimuth-service-${YEAR}-${MONTH}-DD"
  exit 0
fi

log "Matched buckets:"
echo "$BUCKETS" | tee -a "$LOG_FILE"

mkdir -p "$DST_ROOT" || true

for b in $BUCKETS; do
  src="${SRC_ROOT}/${b}"
  dst="${DST_ROOT}/${b}"
  marker="${dst}/.migrated"

  log "-----"
  log "Bucket: $b"
  log "SRC: $src"
  log "DST: $dst"

  if [[ -f "$marker" ]]; then
    log "SKIP: marker exists ($marker)"
    continue
  fi

  if [[ ! -d "$src" ]]; then
    log "SKIP: source dir not found ($src). Maybe already removed?"
    continue
  fi

  # Создать dst
  mkdir -p "$dst"

  # Копирование (без rsync/tar)
  # Важно: копируем содержимое каталога, а не сам каталог поверх.
  log "COPY: cp -a $src/. -> $dst/"
  if cp -a "$src/." "$dst/"; then
    log "COPY: OK"
  else
    log "COPY: FAILED (cp exit=$?)"
    log "Continue to next bucket without deleting source"
    continue
  fi

  # Маркер успешной копии
  echo "migrated $(date -Is) from $src" > "$marker"

  # Удаление бакета в MinIO (вместе с содержимым)
  log "DELETE: sudo -u user05 mc rb --force --dangerous ${ALIAS}/${b}"
  if sudo -u user05 mc rb --force --dangerous "${ALIAS}/${b}" >>"$LOG_FILE" 2>&1; then
    log "DELETE: OK"
  else
    log "DELETE: FAILED (bucket not removed). Leaving copied data on dst; source may still exist."
    continue
  fi

  log "DONE: $b"
done

log "FINISH migrate azimuth-service for ${YEAR}-${MONTH}"
