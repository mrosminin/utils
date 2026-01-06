#!/usr/bin/env bash
set -euo pipefail

dir="${1:-}"

if [[ -z "$dir" ]]; then
  echo "Usage: $0 <dir>"
  echo "Example: $0 /passages/s3/azimuth-service"
  exit 1
fi

if [[ "$dir" == "/" || "$dir" == "/passages" || "$dir" == "/passages/s3" ]]; then
  echo "ERROR: refusing to delete dangerous path: $dir"
  exit 1
fi

ts="$(date +%F_%H%M%S)"
safe="${dir#/}"                 # убрать ведущий /
safe="${safe//\//_}"            # заменить / на _
log="./rm_${safe}_${ts}.log"

# создаём лог заранее, чтобы tail -f не падал
touch "$log"

# Запуск в фоне: stdin закрыт, stdout/stderr в лог
# Важно: путь передаём как позиционный параметр ($1), чтобы не было проблем с пробелами/кавычками
nohup bash -lc 'rm -rf -- "$1"' _ "$dir" >"$log" 2>&1 < /dev/null & disown

echo "log: $log"
