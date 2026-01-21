Запросить список пунктов

```bash
curl -v -H "Authorization: Basic c2VydmljZTpzZXJZaWNL" http://10.0.2.20:80/VGK/hs/ramka_GetLocation/GetListOfAPVGK
```
StatusAPVGK
```bash
  curl -v \
  -H 'Authorization: Basic c2VydmljZTpzZXJ2aWNl' \
  -H 'Content-Type: application/json' \
  --data '{
    "start_date": "2026-01-19T10:00:00+03:00",
    "end_date":   "2026-01-19T11:00:00+03:00"
  }' \
  'http://10.0.2.20:80/VGK/hs/ramka_GetLocation/StatusAPVGK'
```

Время запроса
```bash
  curl -s -o /dev/null \
  -H 'Authorization: Basic c2VydmljZTpzZXJ2aWNl' \
  -H 'Content-Type: application/json' \
  --data '{
    "start_date": "2026-01-19T10:00:00+03:00",
    "end_date":   "2026-01-19T11:00:00+03:00"
  }' \
  -w '\nDNS: %{time_namelookup}s\nCONNECT: %{time_connect}s\nTTFB: %{time_starttransfer}s\nTOTAL: %{time_total}s\n' \
  'http://10.0.2.20:80/VGK/hs/ramka_GetLocation/StatusAPVGK'
```

Список проездов VehicleSpeed
```bash
  curl -v \
  -H 'Authorization: Basic c2VydmljZTpzZXJ2aWNl' \
  -H 'Content-Type: application/json' \
  --data '{
    "id": 2590010,
    "start_date": "2026-01-19T10:00:00+03:00",
    "end_date":   "2026-01-19T11:00:00+03:00"
  }' \
  'http://10.0.2.20:80/VGK/hs/ramka_GetLocation/VehicleSpeed'
```

Список нарушений ViolationData
```bash
  curl -v \
  -H 'Authorization: Basic c2VydmljZTpzZXJ2aWNl' \
  -H 'Content-Type: application/json' \
  --data '{
    "id": 2590010,
    "start_date": "2026-01-19T10:00:00+03:00",
    "end_date":   "2026-01-19T11:00:00+03:00"
  }' \
  'http://10.0.2.20:80/VGK/hs/ramka_GetLocation/ViolationData'
```



