# SSH Journal Bridge → Promtail → Loki (hub.transflow.ru)

Документ фиксирует текущую схему сбора логов с хостов без доступа к `hub.transflow.ru` по HTTP, но доступных по SSH, и доставки их в Loki через promtail, который уже работает в docker-compose на hub.

---

## 1) Архитектура

### Задача
Есть хосты (например `perm-pam-app`, `murm-eputs`, `murm-rgis`), которые:
- НЕ могут пушить логи напрямую в `hub.transflow.ru:3100`
- НО доступны с hub по SSH

### Решение
На hub запускается сервис **ssh-journal-bridge**, который:
- подключается по SSH к каждому удалённому хосту
- выполняет `sudo -n journalctl -f -u <unit> --output=short-iso`
- фильтрует служебные баннеры VipNet/IR
- записывает поток в файлы `/var/log/ssh-journal/*.log` в формате, удобном для парсинга
- переподключается при разрыве SSH

Далее контейнерный **promtail** (в docker-compose на hub):
- tail-ит эти файлы
- вытаскивает labels: `host`, `unit`, `level`, `component`
- ставит корректный timestamp (с учётом TZ)
- отправляет в **Loki** (который тоже в compose на hub)

---

## 2) Где что лежит на hub

### Bridge
- Скрипт: `/opt/ssh-log-bridge/ssh_journal_bridge.sh`
- Список инстансов: `/opt/ssh-log-bridge/instances-ssh.txt`
- Выходные файлы: `/var/log/ssh-journal/host=<...>__unit=<...>.log`

### systemd
- Unit: `/etc/systemd/system/ssh-journal-bridge.service`
- Env: `/etc/default/ssh-journal-bridge`

### Promtail (docker-compose)
- Compose: `~/tf-docker/hosts/hub/docker-compose.yaml`
- Конфиг promtail: `~/tf-docker/hosts/hub/promtail/config.yaml`
- Loki: контейнер `loki` (порт наружу `3100:3100`)
- Promtail: контейнер `promtail` (`grafana/promtail:2.9.4`)

---

## 3) Формат строки в `/var/log/ssh-journal/*.log` (ВАЖНО)

Каждая строка должна начинаться так:

```
host=<ssh_target> unit=<systemd_unit> <ISO_TIMESTAMP_WITH_TZ> <APP_LINE>
```

Пример:

```
host=murm-rgis unit=terraflow 2025-12-13T18:21:28+0300 2025-12-13 18:21:28 ERR owm.go:317 > ... component=OWM
```

Почему это важно:
- Loki ругается `timestamp too new`, если мы парсим локальное время как UTC.
- Поэтому для timestamp используем именно `short-iso` с `+0300/+0500`.
- `host/unit` мы забираем из строки, чтобы гарантированно иметь эти labels (не зависеть от особенностей file scrape / relabel).

---

## 4) instances-ssh.txt

Файл: `/opt/ssh-log-bridge/instances-ssh.txt`

Формат:

```
# <ssh_target> <systemd_unit>
perm-pam-app transflow
murm-eputs transflow
murm-rgis terraflow
```

Добавление нового источника:
1) Добавить строку в файл
2) `sudo systemctl restart ssh-journal-bridge`

---

## 5) Скрипт ssh_journal_bridge.sh (ключевая логика)

Скрипт:
- делает `ssh ... journalctl -f ... --output=short-iso`
- отбрасывает баннеры VipNet/IR (пропускаем только строки, начинающиеся с `YYYY-MM-DDTHH:MM:SS`)
- убирает префиксы `host unit[pid]:`
- пишет строку как `host=... unit=... <ISO+TZ> <app_line>`

Ключевой пайп внутри `tail_one()`:

```bash
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
      sub(/^[^ ]+ /, "", line)      # убрать ISO timestamp из начала строки
      sub(/^[^:]*: /, "", line)     # убрать "host unit[pid]: "
      if (line == "") next
      print "host=" H " unit=" U " " jts " " line
      fflush()
    }
  ' >> "$out"
```

Требование к удалённым хостам:
- `ssh <host> 'sudo -n journalctl -n 1 -u <unit> -o cat --no-pager'` должен работать БЕЗ пароля.
- Если не работает — нужен sudoers NOPASSWD на `journalctl` (точно и аккуратно, по вашей политике ИБ).

---

## 6) systemd unit для bridge

Env: `/etc/default/ssh-journal-bridge`

```ini
INSTANCES_FILE=/opt/ssh-log-bridge/instances-ssh.txt
OUTDIR=/var/log/ssh-journal
```

Unit: `/etc/systemd/system/ssh-journal-bridge.service`

```ini
[Unit]
Description=SSH Journal Bridge -> /var/log/ssh-journal (for Promtail)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=altech
Group=altech
EnvironmentFile=/etc/default/ssh-journal-bridge
ExecStart=/opt/ssh-log-bridge/ssh_journal_bridge.sh --file ${INSTANCES_FILE} --outdir ${OUTDIR}
Restart=always
RestartSec=3
KillMode=process
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

Управление сервисом:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ssh-journal-bridge
sudo systemctl status ssh-journal-bridge --no-pager
sudo journalctl -u ssh-journal-bridge -f
```

---

## 7) Promtail: job для ssh-journal

Файл: `~/tf-docker/hosts/hub/promtail/config.yaml`

Внутри `scrape_configs:` добавить блок:

```yaml
- job_name: ssh-journal
  static_configs:
    - targets: [localhost]
      labels:
        job: journal
        source: ssh
        __path__: /var/log/ssh-journal/*.log

  pipeline_stages:
    - regex:
        expression: '^host=(?P<host>[^ ]+)\s+unit=(?P<unit>[^ ]+)\s+(?P<jts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{4})\s+(?P<line>.*)$'

    - labels:
        host:
        unit:

    - timestamp:
        source: jts
        format: '2006-01-02T15:04:05-0700'
        fallback_formats:
          - '2006-01-02T15:04:05.000-0700'
          - '2006-01-02T15:04:05.000000-0700'

    - regex:
        source: line
        expression: '^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (?P<level>[A-Z]{3}) (?P<place>[^>]+) > (?P<payload>.*)$'

    - regex:
        source: payload
        expression: 'component="(?P<component>[^"]+)"'
    - regex:
        source: payload
        expression: 'component=(?P<component>[A-Za-z0-9._-]+)'

    - labels:
        level:
        component:

    - output:
        source: payload
```

Перезапуск promtail:

```bash
cd ~/tf-docker/hosts/hub
docker compose restart promtail
docker compose logs -f promtail
```

---

## 8) Проверки (операционные)

### 8.1 Bridge пишет файлы
```bash
ls -la /var/log/ssh-journal
tail -n 3 /var/log/ssh-journal/*.log
```

### 8.2 Promtail видит файлы внутри контейнера
```bash
cd ~/tf-docker/hosts/hub
docker compose exec promtail sh -lc 'ls -la /var/log/ssh-journal && tail -n 2 /var/log/ssh-journal/*.log | head -n 50'
```

### 8.3 В Grafana / Loki
Только ssh-источники:
```logql
{job="journal", source="ssh"}
```

Ошибки:
```logql
{job="journal", source="ssh", level=~"ERR|FTL"}
```

По конкретному:
```logql
{job="journal", source="ssh", host="murm-rgis", unit="terraflow"}
```

---

## 9) Ротация файлов (чтобы не съесть диск)

Рекомендация: logrotate + copytruncate (бридж держит файл открытым).

Файл: `/etc/logrotate.d/ssh-journal-bridge`

```conf
/var/log/ssh-journal/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  dateext
  dateformat -%Y%m%d
}
```

Проверка (dry-run):
```bash
sudo logrotate -d /etc/logrotate.d/ssh-journal-bridge
```

Принудительно выполнить:
```bash
sudo logrotate -f /etc/logrotate.d/ssh-journal-bridge
```

---

## 10) Типовые аварии и что делать

### 10.1 Grafana пусто по `{job="journal", source="ssh"}`
Проверить:
1) `sudo systemctl status ssh-journal-bridge --no-pager`
2) `tail -n 2 /var/log/ssh-journal/*.log`
3) `docker compose logs --tail=200 promtail | egrep -i 'error|status=400|timestamp'`

Особенно важно:
- если в promtail логе `status=400 ... has timestamp too new` — значит timestamp снова без TZ/неправильно парсится.

### 10.2 VipNet/IR баннеры попали в файлы
Симптом: строки не начинаются с `YYYY-MM-DD...`, парсинг ломается.
Решение: убедиться, что awk-фильтр пропускает только строки, начинающиеся с `YYYY-MM-DDT..`.

### 10.3 Удалённый хост просит пароль sudo
Симптом: файлы не растут / ssh быстро отваливается.
Проверка:
```bash
ssh <host> 'sudo -n journalctl -n 1 -u <unit> -o cat --no-pager'
```
Если требует пароль — добавить sudoers NOPASSWD (по вашей политике).

### 10.4 Изменился формат прикладных логов (regex перестал матчиться)
Симптом: `level/component` не появляются.
Решение: поправить regex в promtail pipeline под новый формат.

### 10.5 Нужно “перечитать” файлы заново
Обычно достаточно:
- архивировать текущие `.log` в отдельную папку
- перезапустить bridge (создаст новые файлы)
- перезапустить promtail

---

## 11) Поддержка / изменение списка источников

Добавить новый источник:
1) добавить строку в `/opt/ssh-log-bridge/instances-ssh.txt`
2) `sudo systemctl restart ssh-journal-bridge`

Удалить источник:
1) удалить строку
2) `sudo systemctl restart ssh-journal-bridge`
3) (опционально) удалить его файл в `/var/log/ssh-journal/`

---

## 12) Быстрые команды (шпаргалка)

Bridge:
```bash
sudo systemctl status ssh-journal-bridge --no-pager
sudo journalctl -u ssh-journal-bridge -f
tail -n 3 /var/log/ssh-journal/*.log
```

Promtail:
```bash
cd ~/tf-docker/hosts/hub
docker compose restart promtail
docker compose logs -f promtail
docker compose exec promtail sh -lc 'ls -la /var/log/ssh-journal'
```

Logrotate:
```bash
sudo logrotate -d /etc/logrotate.d/ssh-journal-bridge
sudo logrotate -f /etc/logrotate.d/ssh-journal-bridge
```
