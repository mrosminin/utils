#!/bin/bash

set -euo pipefail

INSTANCES_FILE="./all" # <host> <service>

LEVEL="ERR"
TARGET=""
UNIT=""

usage() {
  cat <<'EOF'
Usage:
  # 1) По файлу all
  ./ssh-logs.sh
  ./ssh-logs.sh [LEVEL]

  # 2) Один инстанс (без файла)
  ./ssh-logs.sh [LEVEL] <ssh_target> <systemd_unit>
  ./ssh-logs.sh --target <ssh_target> --service <systemd_unit> [--level LEVEL]

Options:
  -l, --level LEVEL       Filter by level: ERR|FTL|WRN|INF|ING|DBG (optional)
  -t, --target SSH        SSH target (host/alias from ~/.ssh/config)
  -s, --service UNIT      systemd unit name (e.g. terraflow, tfserver.service)
  -f, --file PATH         instances file (default: ./all)
  -h, --help              show help

Examples:
  ./ssh-logs.sh
  ./ssh-logs.sh ERR
  ./ssh-logs.sh INF tf220 terraflow
  ./ssh-logs.sh --target tf220 --service terraflow --level WRN
EOF
}

# --- args parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -l|--level)
      LEVEL="${2:-}"
      shift 2
      ;;
    -t|--target|--ssh)
      TARGET="${2:-}"
      shift 2
      ;;
    -s|--service|--unit)
      UNIT="${2:-}"
      shift 2
      ;;
    -f|--file)
      INSTANCES_FILE="${2:-}"
      shift 2
      ;;
    ERR|FTL|WRN|INF|ING|DBG)
      if [[ -z "$LEVEL" ]]; then
        LEVEL="$1"
        shift
      else
        echo "❌ Лишний аргумент уровня: $1"
        usage
        exit 1
      fi
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
        shift
      elif [[ -z "$UNIT" ]]; then
        UNIT="$1"
        shift
      else
        echo "❌ Лишний аргумент: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

case "$LEVEL" in
  ""|ERR|FTL|WRN|INF|ING|DBG) ;;
  *)
    echo "❌ Неверный уровень: $LEVEL (ожидаю ERR|FTL|WRN|INF|ING|DBG) или ничего"
    exit 1
    ;;
esac

# --- colors ---
COLORS=(
  "\033[0;31m"  "\033[0;32m"  "\033[0;33m"  "\033[0;34m"
  "\033[0;35m"  "\033[0;36m"  "\033[1;31m"  "\033[1;32m"
  "\033[1;33m"  "\033[1;34m"  "\033[1;35m"  "\033[1;36m"
  "\033[0;91m"  "\033[0;92m"  "\033[0;94m"  "\033[0;95m"
)
RESET="\033[0m"

LVL_RED="\033[1;31m"
LVL_YEL="\033[1;33m"
LVL_BLU="\033[1;34m"
LVL_GRY="\033[0;90m"
COMP_BLU="\033[1;34m"

USE_COLOR=1
if [[ ! -t 1 ]]; then
  USE_COLOR=0
fi

WIDTH=""
if [[ -t 1 ]]; then
  WIDTH="$(tput cols 2>/dev/null || true)"
fi
if [[ ! "$WIDTH" =~ ^[0-9]+$ ]] || [[ "$WIDTH" -le 0 ]]; then
  WIDTH=160
fi

run_one() {
  local host="$1"
  local service="$2"
  local color="$3"

  ssh -T "$host" "sudo journalctl -f -u \"$service\" --output=short-iso --no-pager" 2>/dev/null | \
  awk -v host="$host" -v service="$service" \
      -v color="$color" -v reset="$RESET" -v use_color="$USE_COLOR" \
      -v width="$WIDTH" -v filter="$LEVEL" \
      -v lvl_red="$LVL_RED" -v lvl_yel="$LVL_YEL" -v lvl_blu="$LVL_BLU" -v lvl_gry="$LVL_GRY" -v comp_blu="$COMP_BLU" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

    function lvl_color(lvl) {
      if (lvl == "ERR" || lvl == "FTL") { return lvl_red }
      if (lvl == "WRN") { return lvl_yel }
      if (lvl == "INF" || lvl == "ING") { return lvl_blu }
      if (lvl == "DBG") { return lvl_gry }
      return ""
    }

    function trunc(s, maxlen, out) {
      if (maxlen <= 0) { return "" }
      if (length(s) <= maxlen) { return s }
      if (maxlen == 1) { return "…" }
      out = substr(s, 1, maxlen - 1) "…"
      return out
    }

    function norm_ts(raw, d, t) {
      if (raw ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) {
        d = substr(raw, 1, 10)
        t = substr(raw, 12, 8)
        return d " " t
      }
      return raw
    }

    {
      ts = "-"
      startField = 1

      if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) {
        ts = norm_ts($1)
        startField = 2
      } else if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $2 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
        ts = $1 " " $2
        startField = 3
      }

      msg = ""
      for (j = startField; j <= NF; j++) {
        msg = msg (j == startField ? "" : " ") $j
      }
      msg = trim(msg)

      comp = ""
      if (match(msg, /component="[^"]+"/)) {
        comp = substr(msg, RSTART + 11, RLENGTH - 12)
      }

      sub(/^[^:]*: /, "", msg)
      msg = trim(msg)

      lvl = "-"
      payload = msg

      if (payload ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]+/) {
        sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}[ \t]+/, "", payload)

        if (match(payload, /^(ERR|FTL|WRN|INF|ING|DBG)[ \t]+/)) {
          lvl = substr(payload, RSTART, RLENGTH)
          lvl = trim(lvl)
          sub(/^(ERR|FTL|WRN|INF|ING|DBG)[ \t]+/, "", payload)
        }

        if (match(payload, /^[^>]+>[ \t]*/)) {
          sub(/^[^>]+>[ \t]*/, "", payload)
        }
      } else {
        if (match(payload, /(ERR|FTL|WRN|INF|ING|DBG)/)) {
          lvl = substr(payload, RSTART, RLENGTH)
        }
      }

      payload = trim(payload)

      if (filter != "" && lvl != filter) {
        next
      }

      if (comp != "") {
        if (use_color == 1) {
          payload = comp_blu comp reset " -> " payload
        } else {
          payload = comp " -> " payload
        }
      }

      instance = host ":" service

      w_instance = 28
      w_time = 19
      w_level = 3

      base = w_instance + 1 + w_time + 1 + w_level + 1
      max_payload = width - base
      if (max_payload < 0) { max_payload = 0 }

      payload = trunc(payload, max_payload)

      lvlc = lvl_color(lvl)

      if (use_color == 1) {
        printf "%s%-*s%s %-*s %s%-*s%s %s\n",
          color, w_instance, instance, reset,
          w_time, ts,
          lvlc, w_level, lvl, reset,
          payload
      } else {
        printf "%-*s %-*s %-*s %s\n",
          w_instance, instance,
          w_time, ts,
          w_level, lvl,
          payload
      }

      fflush()
    }
  '
}

trap 'kill 0' SIGINT

# --- mode: one instance ---
if [[ -n "$TARGET" && -n "$UNIT" ]]; then
  run_one "$TARGET" "$UNIT" "${COLORS[0]}"
  exit 0
fi

# --- mode: instances file ---
if [[ ! -f "$INSTANCES_FILE" ]]; then
  echo "❌ Не найден файл инстансов: $INSTANCES_FILE"
  exit 1
fi

idx=0
while read -r HOST SERVICE || [[ -n "$HOST" ]]; do
  if [[ -z "$HOST" || "$HOST" =~ ^# ]]; then
    continue
  fi
  color="${COLORS[idx % ${#COLORS[@]}]}"
  run_one "$HOST" "$SERVICE" "$color" &
  ((idx++))
done < "$INSTANCES_FILE"

wait
