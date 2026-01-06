#!/bin/bash

PGHOST="172.31.9.20"
PGPORT=6005
PGUSER="postgres"
PGDATABASE="transflow"
PGPASSWORD="G!bs0n"
TIMEOUT=5
LOGFILE="$HOME/db_checker/check.log"
BOT_TOKEN="8242749557:AAHEukCWGNhV_mxi8kFmx9A_6z3oUgFXbc0"

HOSTNAME_SHORT="$(hostname -s)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

# === Кому слать всегда (успех/неуспех) ===
PRIMARY_CHAT_ID=145961648    # 👤 Личный чат (ты сам)

# === Список чатов для тревог (ошибки) ===
CHAT_IDS=(
  145961648     # 👤 Личный чат (дублируем тревоги и тебе)
  # -798388759    # 💬 Группа "ЕПУТС ПГА (внутренний)"
  # -4502108244   # 🛠  Группа "Техподдержка ЕПУТС ПГА 2024"
)

# === Отправка в Telegram (в несколько чатов) ===
send_telegram() {
  local message="$1"
  for chat_id in "${CHAT_IDS[@]}"; do
    local resp
    resp=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
      -d chat_id="$chat_id" \
      -d text="$message")
    if [[ "$resp" != *'"ok":true'* ]]; then {
      echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ Telegram send failed for $chat_id: $resp" >> "$LOGFILE"
    } fi
  done
}

# === Отправка только одному получателю (для OK) ===
send_telegram_to() {
  local chat_id="$1"
  local message="$2"
  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$chat_id" \
    -d text="$message")
  if [[ "$resp" != *'"ok":true'* ]]; then {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ❌ Telegram send failed for $chat_id: $resp" >> "$LOGFILE"
  } fi
}

# === Проверка TCP-порта ===
timeout $TIMEOUT bash -c "echo > /dev/tcp/$PGHOST/$PGPORT" 2>/dev/null
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  echo "$NOW ✅ [$HOSTNAME_SHORT] Port $PGPORT on $PGHOST is reachable" >> "$LOGFILE"
else
  MESSAGE="🚨 [$HOSTNAME_SHORT] $NOW Port $PGPORT on $PGHOST is NOT reachable (code $STATUS)"
  echo "$MESSAGE" >> "$LOGFILE"
  send_telegram "$MESSAGE"
  exit 1
fi

export PGPASSWORD

# === Проверка подключения к PostgreSQL ===
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c '\q' > /dev/null 2>&1
PSQL_STATUS=$?

if [ "$PSQL_STATUS" -eq 0 ]; then
  echo "$NOW ✅ [$HOSTNAME_SHORT] PostgreSQL connection successful" >> "$LOGFILE"
  # ← отправляем OK только тебе
  OK_MSG="✅ [$HOSTNAME_SHORT] $NOW PostgreSQL OK — $PGHOST:$PGPORT/$PGDATABASE"
  send_telegram_to "$PRIMARY_CHAT_ID" "$OK_MSG"
else
  MESSAGE="🚨 [$HOSTNAME_SHORT] $NOW PostgreSQL on $PGHOST:$PGPORT connection FAILED (code $PSQL_STATUS)"
  echo "$MESSAGE" >> "$LOGFILE"
  send_telegram "$MESSAGE"
fi
