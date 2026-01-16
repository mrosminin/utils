#!/usr/bin/env bash
set -euo pipefail

INSTANCES_FILE="${1:-all}"

PARALLEL="${PARALLEL:-40}"
TIMEOUT="${TIMEOUT:-30}"

WARN_PCT="${WARN_PCT:-80}"
CRIT_PCT="${CRIT_PCT:-90}"

# Хосты, где есть IR/VipNet интерактивщина
INTERACTIVE_HOSTS="${INTERACTIVE_HOSTS:-perm-pam-app,perm-pam-db,perm-pam-esb,perm-pam-map}"

# Скрывать loop/squashfs (snap), чтобы не забивали картину
HIDE_LOOPS="${HIDE_LOOPS:-1}"

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

remote_df_cmd() {
  # Команда для обычных хостов (exec mode)
  # Важно: -P (POSIX) + -T (fstype), исключаем временные
  cat <<'CMD'
printf "__DF_BEGIN__\n"
(
  LC_ALL=C df -PTh -x tmpfs -x devtmpfs 2>/dev/null \
  || LC_ALL=C df -PT -x tmpfs -x devtmpfs 2>/dev/null \
  || LC_ALL=C df -hT -x tmpfs -x devtmpfs 2>/dev/null
) || true
printf "__DF_END__\n"
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
      "$(remote_df_cmd)" \
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

    # Кормим команды в интерактивную сессию
    # timeout защищает от зависаний на маунтах
    {
      printf "stty -echo 2>/dev/null || true\n"
      printf "echo __DF_BEGIN__\n"
      printf "timeout 15 df -PTh -x tmpfs -x devtmpfs 2>/dev/null || df -PT -x tmpfs -x devtmpfs 2>/dev/null || df -hT -x tmpfs -x devtmpfs 2>/dev/null\n"
      printf "echo __DF_END__\n"
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

  local has_markers="0"
  if grep -q "__DF_BEGIN__" "$out" 2>/dev/null && grep -q "__DF_END__" "$out" 2>/dev/null; then
    has_markers="1"
  fi

  if [[ "$has_markers" != "1" ]]; then
    local msg
    msg="$(tail -n 1 "$err" 2>/dev/null || true)"
    [[ -z "$msg" ]] && msg="ssh failed"
    printf "%s%s%-22s%s %s%s%s\n" "$C_BOLD" "$C_CYN" "$host" "$C_RESET" "$C_RED" "$msg" "$C_RESET"
    return
  fi

  printf "%s%s%-22s%s\n" "$C_BOLD" "$C_CYN" "$host" "$C_RESET"

  awk -v WARN="$WARN_PCT" -v CRIT="$CRIT_PCT" \
      -v HIDE_LOOPS="$HIDE_LOOPS" \
      -v R="$C_RED" -v Y="$C_YEL" -v G="$C_GRN" -v D="$C_DIM" -v Z="$C_RESET" '
    function max(a,b) { return a>b?a:b }

    BEGIN {
      inside=0
      n=0
    }

    /__DF_BEGIN__/ { inside=1; next }
    /__DF_END__/ { inside=0; exit }

    inside==0 { next }

    {
      gsub(/\r/, "", $0)
      sub(/^[[:space:]]+/, "", $0)

      # выкидываем промпт типа "user@host:~$"
      if ($0 ~ /^[^[:space:]].*[$] /) next

      # иногда заголовок/строки бывают "приклеены" с мусором слева — отрежем до "Filesystem"
      if ($0 ~ /Filesystem[[:space:]]+Type[[:space:]]+Size/) {
        # нормальный заголовок, пропускаем
        next
      }

      # ожидаем POSIX df: Filesystem Type Size Used Avail Use% Mounted
      if (NF < 7) next
      if ($(6) !~ /^[0-9]+%$/) next

      fs=$1
      type=$2
      size=$3
      used=$4
      avail=$5
      usep=$6
      mnt=$7

      # убираем loop/squashfs если надо
      if (HIDE_LOOPS == 1) {
        if (fs ~ /^\/dev\/loop/) next
        if (type == "squashfs") next
      }

      n++
      FSv[n]=fs
      TYPEv[n]=type
      SIZEv[n]=size
      USEDv[n]=used
      AVAILv[n]=avail
      USEPv[n]=usep
      MNTv[n]=mnt

      wFS=max(wFS, length(fs))
      wTYPE=max(wTYPE, length(type))
      wSIZE=max(wSIZE, length(size))
      wUSED=max(wUSED, length(used))
      wUSEP=max(wUSEP, length(usep))
      wAVAIL=max(wAVAIL, length(avail))
      wMNT=max(wMNT, length(mnt))
    }

    END {
      if (n==0) {
        print D "  (нет данных df между маркерами)" Z
        exit
      }

      wFS=max(wFS, 12)
      wTYPE=max(wTYPE, 6)
      wSIZE=max(wSIZE, 6)
      wUSED=max(wUSED, 6)
      wUSEP=max(wUSEP, 4)
      wAVAIL=max(wAVAIL, 6)
      wMNT=max(wMNT, 8)

      printf D "  %-*s  %-*s  %-*s  %-*s  %*s  %-*s  %-*s" Z "\n", \
        wFS, "FS", wTYPE, "TYPE", wSIZE, "SIZE", wUSED, "USED", wUSEP, "USE%", wAVAIL, "AVAIL", wMNT, "MOUNT"

      for (i=1; i<=n; i++) {
        p=USEPv[i]
        gsub(/%/, "", p)

        color=G
        if (p+0 >= CRIT) color=R
        else if (p+0 >= WARN) color=Y

        printf "  %-*s  %-*s  %-*s  %-*s  %s%*s%s  %-*s  %-*s\n", \
          wFS, FSv[i], wTYPE, TYPEv[i], wSIZE, SIZEv[i], wUSED, USEDv[i], \
          color, wUSEP, USEPv[i], Z, \
          wAVAIL, AVAILv[i], wMNT, MNTv[i]
      }
    }
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
