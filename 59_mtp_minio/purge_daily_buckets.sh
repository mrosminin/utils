#!/usr/bin/env bash
set -euo pipefail

ALIAS_NAME="local"
APPLY=0
SLEEP_SEC=1
CUTOFF="$(date -d '1 month ago' +%F)"

usage() {
  cat <<EOF
Usage:
  $0 [--apply] [--alias <name>] [--cutoff YYYY-MM-DD] [--sleep <sec>]

Defaults:
  --alias  ${ALIAS_NAME}
  --cutoff ${CUTOFF}   (1 month ago)
  --sleep  ${SLEEP_SEC}
  (dry-run unless --apply)

Deletes buckets strictly older than cutoff by date in bucket name:
  traffic-data-images-YYYY-MM-DD
  parkingangels-YYYY-MM-DD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --alias) ALIAS_NAME="$2"; shift 2 ;;
    --cutoff) CUTOFF="$2"; shift 2 ;;
    --sleep) SLEEP_SEC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if ! [[ "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Bad --cutoff format: $CUTOFF (expected YYYY-MM-DD)" >&2
  exit 2
fi

echo "Alias:   $ALIAS_NAME"
echo "Cutoff:  $CUTOFF (delete dates < cutoff)"
echo "Sleep:   ${SLEEP_SEC}s"
echo "Mode:    $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo

# list buckets
mapfile -t buckets < <(mc ls "$ALIAS_NAME" | awk '{print $NF}' | sed 's:/$::')

re='^(traffic-data-images|parkingangels)-[0-9]{4}-[0-9]{2}-[0-9]{2}$'
count=0

for b in "${buckets[@]}"; do
  [[ "$b" =~ $re ]] || continue

  datepart="$(echo "$b" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)"
  year="${datepart:0:4}"

  [[ -n "$datepart" ]] || continue

  # delete if strictly older than cutoff
  if [[ "$datepart" < "$CUTOFF" ]]; then
    count=$((count+1))
    echo "[$count] candidate: $b  (date=$datepart)"

    if [[ $APPLY -eq 1 ]]; then
      echo "    -> mc rb --force --dangerous $ALIAS_NAME/$b"
      if mc rb --force --dangerous "$ALIAS_NAME/$b"; then
        echo "    OK"
      else
        echo "    ERROR deleting $b" >&2
      fi
      sleep "$SLEEP_SEC"
    fi
  fi
done

echo
echo "Done. Candidates found: $count"
if [[ $APPLY -eq 0 ]]; then
  echo "Run with --apply to actually delete."
fi
