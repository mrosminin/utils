#!/bin/bash

set -euo pipefail

VERSION="v3.6.3"
MODE="fixed" # fixed|latest
INSECURE=0
LOKI_URL="http://hub.transflow.ru:3100/loki/api/v1/push"
KEEP_REGEX='.*(transflow|terraflow).*'

usage() {
  cat <<EOF
Usage:
  ./install_promtail.sh [options]

Options:
  --version vX.Y.Z       Set version (default: ${VERSION})
  --latest               Install latest release (uses GitHub API)
  --loki-url URL         Loki push URL (default: ${LOKI_URL})
  --keep-regex REGEX     Keep only matching units by regex (default: ${KEEP_REGEX})
  --insecure             Use curl -k (ignore TLS errors) for GitHub download
  -h, --help             Show help

Examples:
  ./install_promtail.sh
  ./install_promtail.sh --insecure
  ./install_promtail.sh --latest --insecure
  ./install_promtail.sh --version v3.6.3 --loki-url http://hub.transflow.ru:3100/loki/api/v1/push
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?}"; MODE="fixed"; shift 2 ;;
    --latest) MODE="latest"; shift ;;
    --loki-url) LOKI_URL="${2:?}"; shift 2 ;;
    --keep-regex) KEEP_REGEX="${2:?}"; shift 2 ;;
    --insecure) INSECURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Missing dependency: $1"
    exit 1
  }
}

need_cmd curl
need_cmd grep
need_cmd head
need_cmd unzip
need_cmd install
need_cmd systemctl

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ASSET="promtail-linux-amd64.zip"; BINNAME="promtail-linux-amd64" ;;
  aarch64|arm64) ASSET="promtail-linux-arm64.zip"; BINNAME="promtail-linux-arm64" ;;
  *)
    echo "❌ Unsupported arch: $ARCH"
    exit 1
    ;;
esac

CURL_OPTS=(-fL)
if [[ "$INSECURE" -eq 1 ]]; then
  CURL_OPTS=(-k -fL)
fi

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

ZIP_PATH="$TMPDIR/$ASSET"
EXTRACT_DIR="$TMPDIR/promtail"

if [[ "$MODE" == "latest" ]]; then
  echo "🔎 Resolving latest promtail asset via GitHub API…"
  URL="$(
    curl -fsSL https://api.github.com/repos/grafana/loki/releases/latest \
      | grep -Eo "https://[^\"]+/${ASSET}" \
      | head -n1
  )"
  if [[ -z "${URL}" ]]; then
    echo "❌ Could not find asset ${ASSET} in latest release"
    exit 1
  fi
else
  URL="https://github.com/grafana/loki/releases/download/${VERSION}/${ASSET}"
fi

echo "⬇️  Downloading: $URL"
curl "${CURL_OPTS[@]}" -o "$ZIP_PATH" "$URL"

mkdir -p "$EXTRACT_DIR"
unzip -o "$ZIP_PATH" -d "$EXTRACT_DIR" >/dev/null

if [[ ! -f "$EXTRACT_DIR/$BINNAME" ]]; then
  echo "❌ Expected binary not found: $EXTRACT_DIR/$BINNAME"
  echo "Contents:"
  ls -la "$EXTRACT_DIR"
  exit 1
fi

echo "📦 Installing binary to /usr/local/bin/promtail"
install -m 0755 "$EXTRACT_DIR/$BINNAME" /usr/local/bin/promtail

if ! id promtail >/dev/null 2>&1; then
  echo "👤 Creating user: promtail"
  useradd --system --no-create-home --shell /usr/sbin/nologin promtail
fi

if getent group systemd-journal >/dev/null 2>&1; then
  usermod -a -G systemd-journal promtail || true
fi

mkdir -p /etc/promtail /var/lib/promtail

# journald path autodetect
JOURNAL_PATH="/var/log/journal"
if [[ ! -d "$JOURNAL_PATH" ]] || [[ -z "$(ls -A "$JOURNAL_PATH" 2>/dev/null || true)" ]]; then
  if [[ -d "/run/log/journal" ]]; then
    JOURNAL_PATH="/run/log/journal"
  fi
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -f /etc/promtail/promtail.yaml ]]; then
  cp -a /etc/promtail/promtail.yaml "/etc/promtail/promtail.yaml.bak.${timestamp}"
fi

echo "📝 Writing /etc/promtail/promtail.yaml (journal path: $JOURNAL_PATH)"
cat > /etc/promtail/promtail.yaml <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

clients:
  - url: ${LOKI_URL}

positions:
  filename: /var/lib/promtail/positions-journal.yaml

scrape_configs:
  - job_name: journal
    journal:
      path: ${JOURNAL_PATH}
      max_age: 12h
      labels:
        job: journal

    pipeline_stages:
      - regex:
          expression: '^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}) (?P<level>[A-Z]{3}) (?P<place>[^>]+) > (?P<payload>.*)\$'
      - regex:
          expression: 'component="(?P<component>[^"]+)"'
      - labels:
          level:
          component:
      - output:
          source: payload

    relabel_configs:
      - source_labels: ['__journal__hostname']
        target_label: host

      - source_labels: ['__journal__systemd_unit']
        target_label: unit

      - source_labels: ['unit']
        regex: '${KEEP_REGEX}'
        action: keep
EOF

chown -R promtail:promtail /var/lib/promtail

if [[ -f /etc/systemd/system/promtail.service ]]; then
  cp -a /etc/systemd/system/promtail.service "/etc/systemd/system/promtail.service.bak.${timestamp}"
fi

echo "🧩 Writing /etc/systemd/system/promtail.service"
cat > /etc/systemd/system/promtail.service <<'EOF'
[Unit]
Description=Promtail
After=network-online.target
Wants=network-online.target

[Service]
User=promtail
Group=promtail
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yaml
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Enabling and starting promtail"
systemctl daemon-reload
systemctl enable --now promtail

echo
echo "✅ promtail installed and started"
systemctl --no-pager --full status promtail | sed -n '1,20p'

echo
echo "🔎 Quick check (should show sent entries counters after some traffic):"
echo "    curl -s localhost:9080/metrics | egrep 'promtail_sent_entries_total|promtail_request_duration_seconds_count' | head"
