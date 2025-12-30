sudo systemctl stop promtail || true

# скачиваем более совместимую версию
curl -k -fL -o /tmp/promtail-linux-amd64.zip \
  https://github.com/grafana/loki/releases/download/v3.5.6/promtail-linux-amd64.zip

# распаковываем (если нет unzip — скажи, дам вариант через python3 -m zipfile)
mkdir -p /tmp/promtail
unzip -o /tmp/promtail-linux-amd64.zip -d /tmp/promtail

# ставим бинарник
sudo install -m 0755 /tmp/promtail/promtail-linux-amd64 /usr/local/bin/promtail

# проверка, что больше не ругается на glibc
/usr/local/bin/promtail --version

sudo systemctl start promtail
sudo systemctl status promtail --no-pager
