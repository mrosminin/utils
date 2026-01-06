#!/usr/bin/env bash
set -euo pipefail

pid="${1:?PID required}"
mode="${2:-read}"     # read или write
t="${3:-10}"

key="read_bytes"
[[ "$mode" == "write" ]] && key="write_bytes"

get_val() {
  sudo awk -v k="$key" '$1==k":" {print $2}' "/proc/$pid/io" 2>/dev/null | tail -n 1
}

a="$(get_val)"; a="${a:-0}"
sleep "$t"
b="$(get_val)"; b="${b:-0}"

d=$((b-a))

mibs=$(awk -v d="$d" -v t="$t" 'BEGIN {printf "%.2f", d/1024/1024/t}')

echo "PID=$pid $key: ${mibs} MiB/s (a=$a b=$b, dt=${t}s)"
