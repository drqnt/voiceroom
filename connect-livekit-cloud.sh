#!/bin/bash
# Подключает бесплатный LiveKit Cloud: после этого голос работает через интернет.
#
# Перед запуском зарегистрируйся на https://cloud.livekit.io и создай проект.
# Скрипт откроет браузер, там нужно подтвердить доступ. Ключи проекта он сам
# сохранит в server/.env (никуда их копировать не нужно).
#
# Вернуться в домашний режим (голос только в своей Wi-Fi): удали server/.env.
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! lk project list --json > "$TMP" 2>/dev/null || ! grep -q '[A-Za-z]' "$TMP" || grep -qx '\[\]' "$TMP"; then
  echo "Открываю браузер: войди в LiveKit Cloud и подтверди доступ для этого Мака…"
  lk cloud auth
  lk project list --json > "$TMP"
fi

python3 - "$TMP" server/.env <<'EOF'
import json, os, sys

data = json.load(open(sys.argv[1]))
projects = data if isinstance(data, list) else data.get("projects") or data.get("Projects") or []
if not projects:
    sys.exit("Не нашёл проектов LiveKit Cloud. Создай проект на cloud.livekit.io и запусти скрипт снова.")

def get(obj, *names):
    lower = {k.lower(): v for k, v in obj.items()}
    for name in names:
        if lower.get(name.lower()):
            return lower[name.lower()]
    return ""

project = next((p for p in projects if get(p, "default", "isDefault")), projects[0])
url = get(project, "url", "URL", "ws_url")
key = get(project, "api_key", "apiKey", "APIKey", "key")
secret = get(project, "api_secret", "apiSecret", "APISecret", "secret")
if not (url and key and secret):
    sys.exit("Не получилось прочитать ключи проекта из lk. Напиши, что вывела команда.")

path = sys.argv[2]
with open(path, "w") as f:
    f.write("# LiveKit Cloud, записано connect-livekit-cloud.sh\n")
    f.write(f"LIVEKIT_URL={url}\nLIVEKIT_API_KEY={key}\nLIVEKIT_API_SECRET={secret}\n")
os.chmod(path, 0o600)
print(f"Готово: проект «{get(project, 'name', 'Name') or url}» подключён, ключи в server/.env")
EOF

echo "Теперь перезапусти серверы: ./start-server.sh"
