#!/usr/bin/env bash
set -euo pipefail

bucket="${1:-}"
alias_name="${2:-local}"

if [[ -z "$bucket" ]]; then
  echo "Usage: $0 <bucket> [alias]"
  echo "Example: $0 azimuth-service local"
  exit 1
fi

ts="$(date +%F_%H%M%S)"
log="./purge_${bucket}_${ts}.log"

# Запуск в фоне, лог в файл, stdin закрыт, процесс отвязан от терминала
nohup bash -lc "mc rb --force --dangerous ${alias_name}/${bucket}" > "$log" 2>&1 < /dev/null & disown

echo "log: $log"
