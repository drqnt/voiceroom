#!/bin/bash
# Собирает VoiceRoom и ставит на айфон, подключённый к этому Маку.
#
# Первый раз айфон подключают кабелем: на нём нажать «Доверять этому компьютеру»,
# затем включить «Режим разработчика» (Настройки → Конфиденциальность и безопасность).
# Потом можно и без кабеля, если айфон и Мак в одной Wi-Fi сети.
#
# Бесплатный Apple ID: приложение работает 7 дней, потом запусти скрипт ещё раз.
set -euo pipefail
cd "$(dirname "$0")/ios"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Идентификатор команды Apple в git не хранится: он лежит в ios/team.local.
# Xcode показывает его в Signing & Capabilities.
TEAM="$(tr -d '[:space:]' < team.local 2>/dev/null || true)"
if [ -z "$TEAM" ]; then
  echo "Нет идентификатора команды: запиши его в ios/team.local (одна строка, 10 символов)."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1
python3 - "$TMP/devices.json" > "$TMP/list.txt" <<'EOF'
import json, sys
for dev in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn, props = dev.get("hardwareProperties", {}), dev.get("connectionProperties", {}), dev.get("deviceProperties", {})
    if hw.get("deviceType") != "iPhone" or hw.get("reality") != "physical":
        continue
    print(f'{hw["udid"]}\t{props.get("name", "iPhone")}\t{conn.get("pairingState", "")}')
EOF

if [ ! -s "$TMP/list.txt" ]; then
  echo "Не вижу подключённых айфонов. Подключи айфон кабелем, разблокируй его"
  echo "и нажми «Доверять этому компьютеру», потом запусти скрипт ещё раз."
  exit 1
fi

echo "Айфоны:"
nl -w2 -s'. ' <(cut -f2,3 "$TMP/list.txt" | sed $'s/\t/  (/; s/$/)/')
COUNT=$(wc -l < "$TMP/list.txt" | tr -d ' ')
CHOICE=1
if [ "$COUNT" -gt 1 ]; then
  read -r -p "Номер айфона: " CHOICE
fi
LINE=$(sed -n "${CHOICE}p" "$TMP/list.txt")
UDID=$(cut -f1 <<<"$LINE")
NAME=$(cut -f2 <<<"$LINE")
[ -n "$UDID" ] || { echo "Нет такого номера"; exit 1; }

echo "Собираю для «$NAME»…"
if ! xcodebuild -project VoiceRoom.xcodeproj -scheme VoiceRoom -configuration Debug \
  -destination "platform=iOS,id=$UDID" -derivedDataPath build \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="$TEAM" build > "$TMP/build.log" 2>&1; then
  grep -E "error:" "$TMP/build.log" | sort -u | head -5
  echo
  echo "Сборка не удалась. Частые причины:"
  echo " • на айфоне не включён Режим разработчика или не нажато «Доверять»;"
  echo " • в Xcode → Settings → Accounts не добавлен Apple ID;"
  echo " • бесплатный Apple ID уже использован на 3 устройствах."
  exit 1
fi

echo "Устанавливаю…"
xcrun devicectl device install app --device "$UDID" build/Build/Products/Debug-iphoneos/VoiceRoom.app > /dev/null
xcrun devicectl device process launch --device "$UDID" com.voiceroom.app6c7825 > /dev/null 2>&1 || true

echo
echo "Готово: VoiceRoom стоит на «$NAME»."
echo "Если при запуске айфон пишет «Ненадёжный разработчик»: Настройки → Основные →"
echo "VPN и управление устройством → Apple Development → Доверять."
