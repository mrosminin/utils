#!/usr/bin/env bash
set -euo pipefail

INSTANCES_FILE="${1:-all}"

PARALLEL="${PARALLEL:-40}"
TIMEOUT="${TIMEOUT:-30}"

# Хосты, где есть IR/VipNet интерактивщина
INTERACTIVE_HOSTS="${INTERACTIVE_HOSTS:-perm-pam-app,perm-pam-db,perm-pam-esb,perm-pam-map}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_YEL=$'\033[33m'
  C_GRN=$'\033[32m'
  C_CYN=$'\033[36m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_RED=""
  C_YEL=""
  C_GRN=""
  C_CYN=""
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -f "$INSTANCES_FILE" ]] || die "Файл не найден: $INSTANCES_FILE"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

read_instances() {
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "") print $0
    }
  ' "$INSTANCES_FILE"
}

host_in_list() {
  local host="$1"
  local list="$2"

  IFS=',' read -r -a arr <<< "$list"
  for item in "${arr[@]}"; do
    item="$(echo "$item" | awk '{gsub(/^[ \t]+|[ \t]+$/, "", $0); print $0}')"
    if [[ -n "$item" && "$item" == "$host" ]]; then
      return 0
    fi
  done

  return 1
}

clean_stderr() {
  local err="$1"
  if [[ -s "$err" ]]; then
    grep -vE 'Permanently added .* to the list of known hosts\.' "$err" > "$err.tmp" || true
    mv "$err.tmp" "$err"
  fi
}

remote_cmd() {
  cat <<'CMD'
set -euo pipefail

printf "__AK_BEGIN__\n"

print_meta() {
  local user_label="$1"
  local f="$2"

  if [[ ! -e "$f" ]]; then
    printf "AK|%s|MISSING|%s\n" "$user_label" "$f"
    return 0
  fi

  if [[ ! -f "$f" ]]; then
    printf "AK|%s|NOT_A_FILE|%s\n" "$user_label" "$f"
    return 0
  fi

  local st perm owner group size mtime
  st="$(LC_ALL=C stat -c '%a|%U|%G|%s|%y' "$f" 2>/dev/null || true)"
  perm="$(echo "$st" | cut -d'|' -f1)"
  owner="$(echo "$st" | cut -d'|' -f2)"
  group="$(echo "$st" | cut -d'|' -f3)"
  size="$(echo "$st" | cut -d'|' -f4)"
  mtime="$(echo "$st" | cut -d'|' -f5-)"
  [[ -z "$st" ]] && perm="?" && owner="?" && group="?" && size="?" && mtime="?"

  # ключи = строки, где реально есть public key (учитываем опции перед типом)
  local keys
  keys="$(
    awk '
      function is_keytype(t) {
        return (t ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$/)
      }
      /^[[:space:]]*($|#)/ { next }
      {
        # ищем первый токен-тип ключа
        for (i=1; i<=NF; i++) {
          if (is_keytype($i)) {
            if ((i+1) <= NF) c++
            break
          }
        }
      }
      END { print c+0 }
    ' "$f" 2>/dev/null || echo 0
  )"

  printf "AK|%s|OK|%s|perm=%s|owner=%s|group=%s|size=%s|mtime=%s|keys=%s\n" \
    "$user_label" "$f" "$perm" "$owner" "$group" "$size" "$mtime" "$keys"
}

print_fingerprints() {
  local user_label="$1"
  local f="$2"

  [[ -f "$f" ]] || return 0

  # На выходе строки вида:
  # AKF|user|path|type|fingerprint|comment|options
  awk '
    function is_keytype(t) {
      return (t ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)$/)
    }

    /^[[:space:]]*($|#)/ { next }

    {
      type=""
      key=""
      comment=""
      options=""

      # Опции могут быть в первом поле и дальше, пока не встретится тип ключа
      for (i=1; i<=NF; i++) {
        if (is_keytype($i)) {
          type=$i
          if ((i+1) <= NF) {
            key=$(i+1)
          }
          # comment = всё после key
          for (j=i+2; j<=NF; j++) {
            comment = comment $j
            if (j < NF) comment = comment " "
          }
          # options = всё до type
          for (k=1; k<i; k++) {
            options = options $k
            if (k < (i-1)) options = options " "
          }
          break
        }
      }

      if (type != "" && key != "") {
        # печатаем в виде "type|key|comment|options"
        print type "|" key "|" comment "|" options
      }
    }
  ' "$f" | while IFS="|" read -r type key comment options; do
    # fingerprint: ssh-keygen читает public key из stdin
    fp="$(printf "%s %s\n" "$type" "$key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)"
    [[ -z "$fp" ]] && fp="(no-fp)"
    printf "AKF|%s|%s|%s|%s|%s|%s\n" "$user_label" "$f" "$type" "$fp" "$comment" "$options"
  done
}

mode_me() {
  local f="${HOME}/.ssh/authorized_keys"
  print_meta "me" "$f"
  print_fingerprints "me" "$f"
}

mode_me

printf "__AK_END__\n"
CMD
}

run_one_exec() {
  local host="$1"
  local out="$tmp_dir/${host}.out"
  local err="$tmp_dir/${host}.err"
  local rcfile="$tmp_dir/${host}.rc"

  (
    set +e
    ssh \
      -T \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o LogLevel=ERROR \
      -o ConnectTimeout="$TIMEOUT" \
      -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=1 \
      "$host" \
      "bash -lc $(printf '%q' "$(remote_cmd)")" \
      >"$out" 2>"$err"

    local rc="$?"
    clean_stderr "$err"
    echo "$rc" >"$rcfile"
  ) &
}

run_one_interactive() {
  local host="$1"
  local out="$tmp_dir/${host}.out"
  local err="$tmp_dir/${host}.err"
  local rcfile="$tmp_dir/${host}.rc"

  (
    set +e
    {
      printf "stty -echo 2>/dev/null || true\n"
      printf "bash -lc %q\n" "$(remote_cmd)"
      printf "exit\n"
    } | ssh \
      -tt \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o LogLevel=ERROR \
      -o ConnectTimeout="$TIMEOUT" \
      -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=1 \
      "$host" \
      >"$out" 2>"$err"

    local rc="$?"
    clean_stderr "$err"
    echo "$rc" >"$rcfile"
  ) &
}

run_one() {
  local host="$1"
  if host_in_list "$host" "$INTERACTIVE_HOSTS"; then
    run_one_interactive "$host"
  else
    run_one_exec "$host"
  fi
}

print_one() {
  local host="$1"
  local out="$tmp_dir/${host}.out"
  local err="$tmp_dir/${host}.err"

  if ! grep -q "__AK_BEGIN__" "$out" 2>/dev/null || ! grep -q "__AK_END__" "$out" 2>/dev/null; then
    local msg
    msg="$(tail -n 1 "$err" 2>/dev/null || true)"
    [[ -z "$msg" ]] && msg="ssh failed"
    printf "%s%s%-22s%s %s%s%s\n" "$C_BOLD" "$C_CYN" "$host" "$C_RESET" "$C_RED" "$msg" "$C_RESET"
    return
  fi

  printf "%s%s%-22s%s\n" "$C_BOLD" "$C_CYN" "$host" "$C_RESET"

  awk -v D="$C_DIM" -v Z="$C_RESET" -v R="$C_RED" -v Y="$C_YEL" -v G="$C_GRN" '
    function pick_kv(line, key,   r) {
      r=""
      if (match(line, key "=[^|]*")) {
        r=substr(line, RSTART + length(key) + 1, RLENGTH - length(key) - 1)
      }
      return r
    }

    BEGIN { inside=0 }

    /__AK_BEGIN__/ { inside=1; next }
    /__AK_END__/ { inside=0; exit }
    inside==0 { next }

    # Заголовок по файлу
    /^AK\|/ {
      # AK|user|OK|path|perm=...|owner=...|group=...|mtime=...|keys=...
      split($0, a, "|")
      user=a[2]
      status=a[3]
      path=a[4]

      perm=pick_kv($0, "perm")
      owner=pick_kv($0, "owner")
      group=pick_kv($0, "group")
      mtime=pick_kv($0, "mtime")
      keys=pick_kv($0, "keys")

      color=G
      if (status != "OK") color=R
      else if (perm != "600" && perm != "640" && perm != "644" && perm != "?") color=Y

      printf "  %s%-6s%s  %s  %s  perm=%s owner=%s:%s keys=%s  %s\n", \
        color, user, Z, status, path, perm, owner, group, keys, mtime
      next
    }

    # Fingerprints
    /^AKF\|/ {
      # AKF|user|path|type|fp|comment|options
      split($0, b, "|")
      user=b[2]
      path=b[3]
      type=b[4]
      fp=b[5]
      comment=b[6]
      options=b[7]

      if (comment == "") comment="(no-comment)"
      if (options == "") options="-"

      printf D "    %-10s  %-48s  %s" Z "\n", type, fp, comment
      if (options != "-") {
        print D "      options: " options Z
      }
      next
    }

    # всё остальное игнорируем
    { next }
  ' "$out"

  echo
}

main() {
  local hosts
  hosts="$(read_instances)"
  [[ -n "$hosts" ]] || die "В $INSTANCES_FILE нет хостов"

  local running=0

  while IFS= read -r host; do
    run_one "$host"
    running=$((running + 1))

    if [[ "$running" -ge "$PARALLEL" ]]; then
      wait -n || true
      running=$((running - 1))
    fi
  done <<< "$hosts"

  wait || true

  while IFS= read -r host; do
    print_one "$host"
  done <<< "$hosts"
}

main "$@"
