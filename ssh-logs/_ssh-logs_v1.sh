#!/bin/bash

set -e

INSTANCES_FILE="./all"  # Файл со списком: <host> <service>
LOGLEVEL="$1"                     # Уровень логирования: ERR, WRN, INF, DBG

if [[ -z "$LOGLEVEL" ]]; then
  echo "❌ Укажи уровень логирования: ERR, WRN, INF или DBG"
  exit 1
fi

# 16 цветов ANSI
COLORS=(
  "\033[0;31m"  # red
  "\033[0;32m"  # green
  "\033[0;33m"  # yellow
  "\033[0;34m"  # blue
  "\033[0;35m"  # magenta
  "\033[0;36m"  # cyan
  "\033[1;31m"  # bright red
  "\033[1;32m"  # bright green
  "\033[1;33m"  # bright yellow
  "\033[1;34m"  # bright blue
  "\033[1;35m"  # bright magenta
  "\033[1;36m"  # bright cyan
  "\033[0;91m"  # light red
  "\033[0;92m"  # light green
  "\033[0;94m"  # light blue
  "\033[0;95m"  # light magenta
)

RESET="\033[0m"

# ====== ЗАПУСК ПАРАЛЛЕЛЬНОГО ПРОСМОТРА ======

trap 'kill 0' SIGINT

i=0
while read -r HOST SERVICE || [[ -n "$HOST" ]]; do
  if [[ -z "$HOST" || "$HOST" =~ ^# ]]; then
    continue
  fi

  {
    ssh -T "$HOST" "sudo journalctl -f -u $SERVICE --output=short-iso --no-pager" 2>/dev/null | \
    grep --line-buffered "$LOGLEVEL" | \
    while IFS= read -r line; do
      COLOR="${COLORS[i % ${#COLORS[@]}]}"
      echo -e "${COLOR}[$HOST]${RESET} $line"
    done
  } &
  ((i++))
done < "$INSTANCES_FILE"

wait
