#!/bin/bash
set -euo pipefail

INSTANCES_FILE="/opt/ssh-log-bridge/instances-ssh.txt"
OUTDIR="/var/log/ssh-journal"

usage() {
  cat <<'EOF'
Usage:
  ssh_journal_bridge.sh               # all from instances file
  ssh_journal_bridge.sh --list
  ssh_journal_bridge.sh --host SSH --unit UNIT

Options:
  -f, --file PATH     instances file (default: /opt/ssh-log-bridge/instances-ssh.txt)
  -o, --outdir PATH   output dir (default: /var/log/ssh-journal)
  --host SSH          one ssh target
  --unit UNIT         one systemd unit
  --list              print instances and exit
  -h, --help          help

Notes:
  - Remote must allow: sudo -n journalctl -f -u <unit> -o cat --no-pager
  - Output is filtered to only keep lines starting with timestamp YYYY-MM-DD HH:MM:SS (to drop IR banners)
EOF
}

sanitize() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

LIST=0
ONE_HOST=""
ONE_UNIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) INSTANCES_FILE="${2:?}"; shift 2 ;;
    -o|--outdir) OUTDIR="${2:?}"; shift 2 ;;
    --host) ONE_HOST="${2:?}"; shift 2 ;;
    --unit) ONE_UNIT="${2:?}"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$OUTDIR"

if [[ "$LIST" -eq 1 ]]; then
  n=0
  while read -r H U || [[ -n "${H:-}" ]]; do
    [[ -z "${H:-}" || "$H" =~ ^# ]] && continue
    ((n++))
    printf "%3d) %s %s\n" "$n" "$H" "$U"
  done < "$INSTANCES_FILE"
  exit 0
fi

if [[ -n "$ONE_HOST" && -z "$ONE_UNIT" ]] || [[ -z "$ONE_HOST" && -n "$ONE_UNIT" ]]; then
  echo "❌ Для режима одного инстанса нужны оба: --host и --unit"
  exit 1
fi

tail_one() {
  local host="$1"
  local unit="$2"
  local out="${OUTDIR}/host=$(sanitize "$host")__unit=$(sanitize "$unit").log"

  while true; do
ssh -T \
  -o LogLevel=ERROR \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  "$host" \
  "sudo -n journalctl -f -u \"$unit\" --output=short-iso --no-pager" 2>/dev/null \
| awk -v H="$host" -v U="$unit" '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/ {
      jts=$1
      line=$0
      sub(/^[^ ]+ /, "", line)      # убрать ISO timestamp из начала
      sub(/^[^:]*: /, "", line)     # убрать "host unit[pid]: "
      if (line == "") next
      print "host=" H " unit=" U " " jts " " line
      fflush()
    }
  ' >> "$out"

    sleep 2
  done
}

trap 'kill 0' SIGINT

if [[ -n "$ONE_HOST" ]]; then
  tail_one "$ONE_HOST" "$ONE_UNIT"
  exit 0
fi

if [[ ! -f "$INSTANCES_FILE" ]]; then
  echo "❌ instances file not found: $INSTANCES_FILE"
  exit 1
fi

while read -r H U || [[ -n "${H:-}" ]]; do
  [[ -z "${H:-}" || "$H" =~ ^# ]] && continue
  tail_one "$H" "$U" &
done < "$INSTANCES_FILE"

wait

