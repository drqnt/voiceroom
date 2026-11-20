#!/bin/bash
# Запускает серверы VoiceRoom на этом Маке. Остановить: Ctrl+C.
#
# Два режима:
#  • Дома (по умолчанию): голосовой сервер LiveKit работает прямо на Маке,
#    айфоны должны быть в той же Wi-Fi сети.
#  • Через интернет: если в server/.env указан LIVEKIT_URL (LiveKit Cloud),
#    голос идёт через облако, а сервер ников открывается в интернет через
#    туннель Cloudflare. Адрес туннеля меняется при каждом запуске.
set -euo pipefail
cd "$(dirname "$0")"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
CLOUD_URL="$(grep -E '^LIVEKIT_URL=' server/.env 2>/dev/null | cut -d= -f2- || true)"

if [ ! -d server/node_modules ]; then
  (cd server && npm install --no-audit --no-fund)
fi

cleanup() { kill 0 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Пока сервер работает, Мак не засыпает (при закрытой крышке без зарядки всё равно уснёт).
caffeinate -is -w $$ &

if [ -z "$CLOUD_URL" ]; then
  livekit-server --dev --bind 0.0.0.0 --node-ip "$IP" 2>&1 | sed -l 's/^/[livekit] /' &
fi
node server/server.js 2>&1 | sed -l 's/^/[server]  /' &
# Музыка теперь играет во встроенном плеере YouTube у каждого, бот не нужен.
# Старый музыкальный бот можно запустить вручную: node server/music-bot.js

echo
if [ -z "$CLOUD_URL" ]; then
  echo "  Режим: дома (Wi-Fi)"
  echo "  Адрес сервера для приложения:  http://$IP:3077"
elif [ -f server/tunnel.yml ]; then
  # Постоянный адрес: туннель Cloudflare на свой домен (настраивается один раз).
  HOST="$(awk '/hostname:/ {print $3; exit}' server/tunnel.yml)"
  echo "  Режим: через интернет, голос в LiveKit Cloud"
  echo "  Постоянный адрес для приложения и друзей:  https://$HOST"
  cloudflared tunnel --no-autoupdate --loglevel warn --config server/tunnel.yml run 2>&1 | sed -l 's/^/[tunnel]  /' &
else
  echo "  Режим: через интернет, голос в LiveKit Cloud"
  echo "  Жду адрес туннеля…"
  cloudflared tunnel --no-autoupdate --url http://localhost:3077 2>&1 |
    sed -l -n 's#.*\(https://[a-z0-9-]*\.trycloudflare\.com\).*#\
  ┌──────────────────────────────────────────────────────────────────┐\
  │ Адрес сервера для приложения (и для друзей):\
  │ \1\
  └──────────────────────────────────────────────────────────────────┘#p' &
fi
echo "  Голосовой чат с этого Мака в браузере:  http://localhost:3077"
echo

wait
