// Настройки серверов VoiceRoom. Читаются из server/.env (если есть) и переменных окружения.
//
// Дома ничего настраивать не нужно: по умолчанию используется локальный LiveKit
// (livekit-server --dev). Для LiveKit Cloud в server/.env пишутся:
//   LIVEKIT_URL=wss://<проект>.livekit.cloud
//   LIVEKIT_API_KEY=...
//   LIVEKIT_API_SECRET=...

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

function loadEnvFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return;
  }
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim().replace(/^['"]|['"]$/g, '');
    if (!(key in process.env)) process.env[key] = value;
  }
}

loadEnvFile(path.join(here, '.env'));

const env = process.env;

/** Адрес LiveKit, к которому подключаются бот и (если задан) клиенты. */
export const LIVEKIT_URL = env.LIVEKIT_URL ?? '';
export const LIVEKIT_API_KEY = env.LIVEKIT_API_KEY ?? 'devkey';
export const LIVEKIT_API_SECRET = env.LIVEKIT_API_SECRET ?? 'secret';
/** Адрес API LiveKit (комнаты, участники) для сервера и бота. */
export const LIVEKIT_HTTP_URL =
  env.LIVEKIT_HTTP_URL ?? (LIVEKIT_URL ? LIVEKIT_URL.replace(/^ws/, 'http') : 'http://127.0.0.1:7880');
// Не 3000: этот порт любит занимать Adobe (After Effects / Premiere), и туннель попадал к нему.
export const PORT = Number(env.PORT ?? 3077);
export const DATA_FILE = env.DATA_FILE ?? path.join(here, 'data', 'users.json');

export const MUSIC_BOT_IDENTITY = 'music-bot';
