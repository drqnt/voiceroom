// Небольшой сервер VoiceRoom: регистрирует ники, хранит список комнат (как каналы
// в Discord: комната есть, даже когда в ней пусто), выдаёт токены для голосового
// сервера LiveKit и показывает, кто где сидит.
//
// У комнаты постоянный id (так она называется в LiveKit) и название, которое
// можно менять, никого не выкидывая.
//
// Аккаунтов с паролями нет: устройство при первом запуске придумывает себе
// случайный deviceId и закрепляет за ним ник. deviceId служит ключом доступа.

import { execFile } from 'node:child_process';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AccessToken, DataPacket_Kind, RoomServiceClient } from 'livekit-server-sdk';
import {
  DATA_FILE,
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
  LIVEKIT_HTTP_URL,
  LIVEKIT_URL,
  MUSIC_BOT_IDENTITY,
  PORT,
} from './config.js';

const here = path.dirname(fileURLToPath(import.meta.url));

const NICK_RE = /^[\p{L}\p{N}_.-]{2,20}$/u;
// Ник музыкального бота (music-bot.js) занимать нельзя.
const RESERVED_NICKS = new Set([MUSIC_BOT_IDENTITY, 'музыка']);
const DEVICE_RE = /^[A-Za-z0-9-]{16,64}$/;
const ROOM_NAME_MAX = 32;

const roomService = new RoomServiceClient(LIVEKIT_HTTP_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// ---------- хранилище ников и комнат ----------

/**
 * @type {{
 *   users: Record<string, { nick: string, deviceId: string, createdAt: string }>,
 *   rooms: Record<string, { id: string, name: string, createdBy: string | null, createdAt: string }>,
 * }}
 */
let db = { users: {}, rooms: {} };

function loadDb() {
  try {
    db = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  db.users ??= {};
  db.rooms ??= {};
  if (Object.keys(db.rooms).length === 0) {
    addRoom('Общая', null);
    saveDb();
  }
}

function saveDb() {
  fs.mkdirSync(path.dirname(DATA_FILE), { recursive: true });
  const tmp = `${DATA_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, DATA_FILE);
}

const nickKey = (nick) => nick.toLowerCase();

function userByDevice(deviceId) {
  return Object.values(db.users).find((u) => u.deviceId === deviceId) ?? null;
}

const newRoomId = () => `r${crypto.randomBytes(5).toString('hex')}`;

function cleanRoomName(raw) {
  const name = String(raw ?? '')
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .replace(/\s+/g, ' ');
  if (!name) throw new HttpError(400, 'bad_room_name', 'Название комнаты не может быть пустым');
  if ([...name].length > ROOM_NAME_MAX) {
    throw new HttpError(400, 'bad_room_name', `Название комнаты: не длиннее ${ROOM_NAME_MAX} символов`);
  }
  return name;
}

const roomByName = (name) =>
  Object.values(db.rooms).find((r) => r.name.toLowerCase() === name.toLowerCase()) ?? null;

/** «Комната Вова», а если такая уже есть — «Комната Вова 2», «… 3». */
function uniqueRoomName(base, exceptId = null) {
  const taken = (name) => Object.values(db.rooms).some((r) => r.id !== exceptId && r.name.toLowerCase() === name.toLowerCase());
  if (!taken(base)) return base;
  for (let n = 2; ; n++) {
    const suffix = ` ${n}`;
    const name = [...base].slice(0, ROOM_NAME_MAX - suffix.length).join('') + suffix;
    if (!taken(name)) return name;
  }
}

function addRoom(name, createdBy, id = newRoomId()) {
  const room = { id, name, createdBy, createdAt: new Date().toISOString() };
  db.rooms[id] = room;
  return room;
}

/** Комната по id или (для старых версий приложения) по названию. */
function findRoom(ref) {
  const key = String(ref ?? '').trim();
  if (!key) return null;
  return db.rooms[key] ?? roomByName(key);
}

const publicRoom = (room, participants = []) => ({ id: room.id, name: room.name, participants });

// ---------- http-помощники ----------

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
    'Cache-Control': 'no-store',
  });
  res.end(data);
}

async function readJson(req, maxBytes = 16 * 1024) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) throw new HttpError(413, 'too_large', 'Слишком большой запрос');
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'bad_json', 'Неверный JSON');
  }
}

function requireDevice(req, body) {
  const deviceId = String(req.headers['x-device-id'] ?? body?.deviceId ?? '');
  if (!DEVICE_RE.test(deviceId)) throw new HttpError(400, 'bad_device', 'Нет deviceId');
  const user = userByDevice(deviceId);
  if (!user) throw new HttpError(401, 'unknown_device', 'Сначала выбери ник');
  return user;
}

// Адрес LiveKit для клиентов: облако из .env или (дома) тот же хост, порт 7880.
function livekitUrlFor(req) {
  if (LIVEKIT_URL) return LIVEKIT_URL;
  const host = String(req.headers.host ?? 'localhost').replace(/:\d+$/, '');
  return `ws://${host}:7880`;
}

/** Кто сейчас сидит в комнатах: id комнаты → ники (без бота). */
async function peopleInRooms() {
  const list = await roomService.listRooms();
  const people = new Map();
  await Promise.all(
    list
      .filter((r) => r.numParticipants > 0)
      .map(async (r) => {
        const participants = await roomService.listParticipants(r.name).catch(() => []);
        const nicks = participants
          .map((p) => p.identity)
          .filter((id) => !RESERVED_NICKS.has(id))
          .sort((a, b) => a.localeCompare(b));
        if (nicks.length) people.set(r.name, nicks);
      }),
  );
  return people;
}

/** Дописывает поля в метаданные комнаты LiveKit ({ name, music }), не трогая остальные. */
async function patchRoomMetadata(id, patch) {
  let current = {};
  try {
    const [room] = await roomService.listRooms([id]);
    current = JSON.parse(room?.metadata || '{}');
  } catch {}
  await roomService.updateRoomMetadata(id, JSON.stringify({ ...current, ...patch }));
}

// ---------- обработчики ----------

async function register(req) {
  const body = await readJson(req);
  const deviceId = String(body.deviceId ?? '');
  const nick = String(body.nick ?? '').trim();
  if (!DEVICE_RE.test(deviceId)) throw new HttpError(400, 'bad_device', 'Нет deviceId');
  if (!NICK_RE.test(nick)) {
    throw new HttpError(400, 'bad_nick', 'Ник: 2–20 символов, буквы, цифры, _ . -');
  }

  const key = nickKey(nick);
  if (RESERVED_NICKS.has(key)) throw new HttpError(409, 'nick_taken', 'Этот ник уже занят');
  const owner = db.users[key];
  if (owner && owner.deviceId !== deviceId) {
    throw new HttpError(409, 'nick_taken', 'Этот ник уже занят');
  }

  // Смена ника: старый освобождается.
  const previous = userByDevice(deviceId);
  if (previous && nickKey(previous.nick) !== key) delete db.users[nickKey(previous.nick)];

  db.users[key] = { nick, deviceId, createdAt: owner?.createdAt ?? new Date().toISOString() };
  saveDb();
  return { nick };
}

async function token(req) {
  const body = await readJson(req);
  const user = requireDevice(req, body);
  let room = findRoom(body.room);
  if (!room) {
    // Старые версии заходят по названию: создаём такую комнату.
    room = addRoom(uniqueRoomName(cleanRoomName(body.room)), user.nick);
    saveDb();
  }

  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: user.nick,
    name: user.nick,
    ttl: '12h',
  });
  at.addGrant({ room: room.id, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: true });

  return { url: livekitUrlFor(req), token: await at.toJwt(), room: room.id, name: room.name, nick: user.nick };
}

async function rooms(req) {
  requireDevice(req, null);
  let people;
  try {
    people = await peopleInRooms();
  } catch (err) {
    throw new HttpError(502, 'livekit_unreachable', `Голосовой сервер недоступен: ${err.message}`);
  }
  // Комнаты, куда зашли в обход списка (старые версии), тоже сохраняем.
  let changed = false;
  for (const id of people.keys()) {
    if (!db.rooms[id]) {
      addRoom(uniqueRoomName([...id].slice(0, ROOM_NAME_MAX).join('')), null, id);
      changed = true;
    }
  }
  if (changed) saveDb();
  const list = Object.values(db.rooms)
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
    .map((room) => publicRoom(room, people.get(room.id) ?? []));
  return { rooms: list };
}

async function createRoom(req) {
  const body = await readJson(req);
  const user = requireDevice(req, body);
  const base = body.name ? cleanRoomName(body.name) : `Комната ${user.nick}`;
  const room = addRoom(uniqueRoomName(base), user.nick);
  saveDb();
  return publicRoom(room);
}

async function renameRoom(req, id) {
  const body = await readJson(req);
  requireDevice(req, body);
  const room = db.rooms[id];
  if (!room) throw new HttpError(404, 'no_room', 'Комната не найдена');
  const name = cleanRoomName(body.name);
  const other = roomByName(name);
  if (other && other.id !== id) throw new HttpError(409, 'room_name_taken', 'Комната с таким названием уже есть');
  room.name = name;
  saveDb();
  // Если в комнате сидят, новое название сразу увидят все.
  patchRoomMetadata(id, { name }).catch(() => {});
  return publicRoom(room);
}

async function deleteRoom(req, id) {
  requireDevice(req, null);
  if (!db.rooms[id]) throw new HttpError(404, 'no_room', 'Комната не найдена');
  const participants = await roomService.listParticipants(id).catch(() => []);
  if (participants.some((p) => !RESERVED_NICKS.has(p.identity))) {
    throw new HttpError(409, 'room_busy', 'В комнате кто-то есть, удалить можно только пустую');
  }
  delete db.rooms[id];
  saveDb();
  return { ok: true };
}

function serveStatic(req, res) {
  const url = new URL(req.url, 'http://x');
  const file = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const full = path.join(here, 'public', path.normalize(file));
  if (!full.startsWith(path.join(here, 'public'))) return false;
  if (!fs.existsSync(full) || !fs.statSync(full).isFile()) return false;
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
  res.writeHead(200, { 'Content-Type': types[path.extname(full)] ?? 'application/octet-stream' });
  fs.createReadStream(full).pipe(res);
  return true;
}

// Зовёт музыкального бота в комнату: помечает её, бот увидит метку и зайдёт.
async function summonMusic(req) {
  const body = await readJson(req);
  requireDevice(req, body);
  const room = findRoom(body.room);
  if (!room) throw new HttpError(404, 'no_room', 'Комната не найдена');
  // LiveKit Cloud узнаёт о новой комнате не мгновенно, поэтому пробуем несколько секунд.
  let lastError;
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      await patchRoomMetadata(room.id, { name: room.name, music: Date.now() });
      return { ok: true };
    } catch (err) {
      lastError = err;
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  throw new HttpError(404, 'no_room', `Комната не найдена: ${lastError.message}`);
}


// ---------- общий плеер YouTube ----------
//
// Видео играет у каждого в своём плеере, а сервер хранит, что играет и с какого
// момента: { videoId, title, by, startedAt, pausedAt }. startedAt — время сервера (мс),
// когда ролик был на 0:00; pausedAt — позиция (с), если на паузе. Состояние лежит в
// метаданных комнаты LiveKit, поэтому все в комнате получают его сразу.

const roomPlayers = new Map();
const MAX_QUEUE = 100;
const LIST_BATCH = 30; // сколько треков брать из плейлиста или микса за раз
const RADIO_REFILL_BELOW = 3; // радио докидывает треки, когда в очереди осталось меньше
const START_DELAY_MS = 1500; // даём плеерам загрузиться, чтобы начали вместе
const RESUME_DELAY_MS = 800; // после паузы: команда успевает дойти до всех

// radio — когда очередь кончается, сервер сам добавляет похожие треки (микс YouTube).
// history — недавно игравшие ролики, чтобы радио их не повторяло (наружу не отдаём).
const emptyPlayer = () => ({ current: null, queue: [], version: 0, radio: false, history: [] });

async function playerFor(roomId) {
  let player = roomPlayers.get(roomId);
  // Комнату LiveKit закрыли (все ушли): начинаем с чистого листа.
  const [room] = await roomService.listRooms([roomId]).catch(() => []);
  if (!room) {
    player = emptyPlayer();
  } else if (!player) {
    // Сервер перезапускали: восстанавливаем из метаданных комнаты.
    try {
      player = { ...emptyPlayer(), ...(JSON.parse(room.metadata || '{}').player ?? {}), history: [] };
      delete player.queueLength;
    } catch {
      player = emptyPlayer();
    }
  }
  roomPlayers.set(roomId, player);
  return player;
}

const positionOf = (current, now = Date.now()) =>
  current.pausedAt ?? Math.max(0, (now - current.startedAt) / 1000);

// Момент запуска сервера: после перезапуска номера версий плеера начинаются заново,
// и приложения по этому числу понимают, что старые номера больше не в счёт.
const SERVER_EPOCH = Date.now();

const publicPlayer = (player) => ({
  epoch: SERVER_EPOCH,
  version: player.version,
  current: player.current,
  queue: player.queue.slice(0, 20),
  queueLength: player.queue.length,
  radio: Boolean(player.radio),
});

async function publishPlayer(roomId, player) {
  player.version += 1;
  const state = publicPlayer(player);
  // Сразу всем по каналу данных (доли секунды) и в метаданные комнаты (для тех,
  // кто зайдёт позже; метаданные в LiveKit Cloud доходят заметно медленнее).
  const data = new TextEncoder().encode(JSON.stringify({ player: state }));
  await roomService.sendData(roomId, data, DataPacket_Kind.RELIABLE, { topic: 'player' }).catch(() => {});
  // Метаданные — в фоне и с повторами: сразу после входа LiveKit Cloud иногда
  // ещё не видит комнату. Повторяем, только пока это состояние самое новое.
  const writeMetadata = (triesLeft) =>
    patchRoomMetadata(roomId, { player: state }).catch((err) => {
      if (triesLeft > 1 && player.version === state.version) {
        setTimeout(() => writeMetadata(triesLeft - 1), 1000);
      } else if (player.version === state.version) {
        console.warn(`Не записал плеер в метаданные ${roomId}: ${err.message}`);
      }
    });
  writeMetadata(5);
}

function parseVideoId(input) {
  const text = String(input ?? '').trim();
  if (/^[A-Za-z0-9_-]{11}$/.test(text)) return text;
  try {
    const url = new URL(text);
    if (url.hostname.endsWith('youtu.be')) return url.pathname.slice(1, 12) || null;
    const v = url.searchParams.get('v');
    if (v && /^[A-Za-z0-9_-]{11}/.test(v)) return v.slice(0, 11);
    const match = url.pathname.match(/\/(?:shorts|embed|live|v)\/([A-Za-z0-9_-]{11})/);
    if (match) return match[1];
  } catch {}
  return null;
}

/** id плейлиста или микса из ссылки (list=…). Миксы YouTube начинаются с RD. */
function parseListId(input) {
  try {
    const list = new URL(String(input ?? '').trim()).searchParams.get('list');
    if (list && /^[A-Za-z0-9_-]{2,64}$/.test(list)) return list;
  } catch {}
  return null;
}

const mixUrl = (videoId) => `https://www.youtube.com/watch?v=${videoId}&list=RD${videoId}`;

/** Треки плейлиста или микса (без скачивания, только список). */
function fetchList(url, limit = LIST_BATCH) {
  return new Promise((resolve, reject) => {
    execFile(
      'yt-dlp',
      ['--flat-playlist', '--no-warnings', '--playlist-end', String(limit), '--print', '%(id)s\t%(title)s', url],
      { timeout: 25000 },
      (err, stdout) => {
        if (err && !stdout) return reject(new HttpError(502, 'list_failed', 'YouTube не отдал плейлист, попробуй ещё раз'));
        const entries = stdout
          .split('\n')
          .map((line) => line.split('\t'))
          .filter(([id, title]) => /^[A-Za-z0-9_-]{11}$/.test(id ?? '') && !/^\[(private|deleted)/i.test(title ?? ''))
          .map(([videoId, title]) => ({ videoId, title: String(title || 'Без названия').slice(0, 200) }));
        resolve(entries);
      },
    );
  });
}

/** Плейлист или микс по ссылке. Если в ссылке есть ролик — начинаем с него. */
async function resolveList(input) {
  const listId = parseListId(input);
  const videoId = parseVideoId(input);
  if (!listId && !videoId) throw new HttpError(400, 'not_list', 'Это не ссылка на плейлист или микс YouTube');
  const url = listId
    ? videoId ? `https://www.youtube.com/watch?v=${videoId}&list=${listId}` : `https://www.youtube.com/playlist?list=${listId}`
    : mixUrl(videoId);
  let entries = await fetchList(url);
  if (videoId) {
    const start = entries.findIndex((e) => e.videoId === videoId);
    if (start > 0) entries = entries.slice(start);
  }
  if (!entries.length) throw new HttpError(404, 'empty_list', 'Плейлист пустой или закрытый');
  return { entries, isMix: !listId || listId.startsWith('RD') };
}

/** Название ролика и заодно проверка, что YouTube разрешает его встраивать. */
async function videoInfo(videoId) {
  const url = `https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(`https://www.youtube.com/watch?v=${videoId}`)}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) }).catch(() => null);
  if (!res) throw new HttpError(502, 'youtube_unreachable', 'YouTube не отвечает, попробуй ещё раз');
  if (res.status === 401 || res.status === 403) {
    throw new HttpError(422, 'not_embeddable', 'Автор запретил включать это видео в других приложениях. Выбери другое');
  }
  if (!res.ok) throw new HttpError(404, 'no_video', 'Видео не найдено');
  const data = await res.json();
  return { videoId, title: String(data.title ?? 'Без названия').slice(0, 200) };
}

/** Поиск по названию: первый результат YouTube (без скачивания, только список). */
function searchVideo(query) {
  return new Promise((resolve, reject) => {
    execFile(
      'yt-dlp',
      ['--flat-playlist', '--no-warnings', '--print', '%(id)s', `ytsearch5:${query}`],
      { timeout: 20000 },
      (err, stdout) => {
        if (err) return reject(new HttpError(502, 'search_failed', 'Поиск YouTube не сработал, вставь ссылку'));
        resolve(stdout.split('\n').map((s) => s.trim()).filter((s) => /^[A-Za-z0-9_-]{11}$/.test(s)));
      },
    );
  });
}

async function resolveVideo(input) {
  const id = parseVideoId(input);
  if (id) return videoInfo(id);
  const query = String(input ?? '').trim().slice(0, 200);
  if (!query) throw new HttpError(400, 'empty', 'Вставь ссылку на YouTube или название');
  if (/^https?:\/\//i.test(query)) throw new HttpError(400, 'not_youtube', 'Это не ссылка на видео YouTube');
  // Первый результат, который можно встраивать.
  for (const candidate of await searchVideo(query)) {
    try {
      return await videoInfo(candidate);
    } catch (err) {
      if (err.code !== 'not_embeddable') throw err;
    }
  }
  throw new HttpError(404, 'no_video', 'Ничего подходящего не нашлось');
}

function remember(player, videoId) {
  if (!videoId) return;
  player.history = [...(player.history ?? []).filter((id) => id !== videoId), videoId].slice(-200);
}

function startNext(player, roomId) {
  remember(player, player.current?.videoId);
  const next = player.queue.shift();
  player.current = next ? { ...next, startedAt: Date.now() + START_DELAY_MS, pausedAt: null } : null;
  if (roomId) refillRadio(roomId, player);
}

/**
 * Радио: когда очередь почти кончилась, добавляем похожие треки из микса YouTube
 * по текущему (или последнему) треку. Без повторов того, что недавно играло.
 */
async function refillRadio(roomId, player) {
  if (!player.radio || player.refilling || player.queue.length >= RADIO_REFILL_BELOW) return;
  const seed = player.current?.videoId ?? player.history?.at(-1);
  if (!seed) return;
  player.refilling = true;
  try {
    const skip = new Set([...(player.history ?? []), player.current?.videoId, ...player.queue.map((v) => v.videoId)]);
    const entries = (await fetchList(mixUrl(seed))).filter((e) => !skip.has(e.videoId)).slice(0, 20);
    if (!entries.length || !player.radio) return;
    const wasIdle = !player.current;
    player.queue.push(...entries.map((e) => ({ ...e, by: 'радио' })));
    if (wasIdle) startNext(player);
    await publishPlayer(roomId, player);
  } catch (err) {
    console.warn(`Радио ${roomId}: ${err.message}`);
  } finally {
    player.refilling = false;
  }
}

async function playerAction(req) {
  const body = await readJson(req);
  const user = requireDevice(req, body);
  const room = findRoom(body.room);
  if (!room) throw new HttpError(404, 'no_room', 'Комната не найдена');
  const player = await playerFor(room.id);
  const current = player.current;
  const now = Date.now();
  let result = {};

  switch (body.action) {
    case 'add': {
      const video = { ...(await resolveVideo(body.input)), by: user.nick };
      if (!player.current) {
        player.current = { ...video, startedAt: now + START_DELAY_MS, pausedAt: null };
      } else {
        if (player.queue.length >= MAX_QUEUE) throw new HttpError(409, 'queue_full', 'Очередь заполнена');
        player.queue.push(video);
      }
      result = { title: video.title };
      break;
    }
    case 'playlist': {
      // Плейлист или микс целиком: «сейчас» — с первого трека, иначе — в конец очереди.
      const list = await resolveList(body.input);
      const items = list.entries.map((e) => ({ ...e, by: user.nick }));
      if (body.now || !player.current) {
        remember(player, player.current?.videoId);
        const [first, ...rest] = items;
        player.current = { ...first, startedAt: now + START_DELAY_MS, pausedAt: null };
        player.queue = [...rest, ...player.queue].slice(0, MAX_QUEUE);
      } else {
        player.queue = [...player.queue, ...items].slice(0, MAX_QUEUE);
      }
      if (list.isMix) player.radio = true;
      result = { title: `${items.length} треков`, count: items.length };
      break;
    }
    case 'mix': {
      // Микс по текущему треку: похожие треки сразу после него, и радио включается.
      const seed = parseVideoId(body.input) ?? current?.videoId;
      if (!seed) throw new HttpError(400, 'no_seed', 'Сначала включи трек — микс соберётся по нему');
      const skip = new Set([current?.videoId, ...player.queue.map((v) => v.videoId)]);
      const entries = (await fetchList(mixUrl(seed))).filter((e) => !skip.has(e.videoId) || (!current && e.videoId === seed));
      if (!entries.length) throw new HttpError(404, 'empty_mix', 'YouTube не нашёл похожих треков');
      const items = entries.map((e) => ({ ...e, by: user.nick }));
      if (!player.current) {
        const [first, ...rest] = items;
        player.current = { ...first, startedAt: now + START_DELAY_MS, pausedAt: null };
        player.queue = [...rest, ...player.queue].slice(0, MAX_QUEUE);
      } else {
        player.queue = [...items, ...player.queue].slice(0, MAX_QUEUE);
      }
      player.radio = true;
      result = { title: `Микс: ${items.length} треков`, count: items.length };
      break;
    }
    case 'radio':
      player.radio = Boolean(body.on);
      if (player.radio) refillRadio(room.id, player);
      break;
    case 'unplayable':
      // Ролик нельзя включить (автор запретил встраивание, удалён) — пропускаем.
      // Сообщают все плееры; переключаем один раз.
      if (current && current.videoId === body.videoId) startNext(player, room.id);
      else return { ok: true, serverNow: Date.now(), player: publicPlayer(player) };
      break;
    case 'playNow': {
      // Включить сразу, не дожидаясь очереди (текущее видео заменяется).
      const video = { ...(await resolveVideo(body.input)), by: user.nick };
      player.current = { ...video, startedAt: now + START_DELAY_MS, pausedAt: null };
      result = { title: video.title };
      break;
    }
    case 'pause':
      // Позиция от того, кто нажал (точнее), иначе — по часам сервера.
      if (current && current.pausedAt == null) {
        const position = Number(body.position);
        current.pausedAt = Number.isFinite(position) && position >= 0 ? position : positionOf(current, now);
      }
      break;
    case 'resume':
      if (current && current.pausedAt != null) {
        // Продолжаем чуть позже, чтобы команда успела дойти до всех и все начали разом.
        current.startedAt = now + RESUME_DELAY_MS - current.pausedAt * 1000;
        current.pausedAt = null;
      }
      break;
    case 'seek': {
      const position = Math.max(0, Number(body.position) || 0);
      if (current) {
        if (current.pausedAt != null) current.pausedAt = position;
        else current.startedAt = now - position * 1000;
      }
      break;
    }
    case 'skip':
      startNext(player, room.id);
      break;
    case 'stop':
      remember(player, player.current?.videoId);
      player.current = null;
      player.queue = [];
      player.radio = false;
      break;
    case 'ended':
      // Сообщают все плееры; переключаем один раз, на первом сообщении.
      if (current && current.videoId === body.videoId && positionOf(current, now) > 3) startNext(player, room.id);
      else return { ok: true, serverNow: Date.now(), player: publicPlayer(player) };
      break;
    default:
      throw new HttpError(400, 'bad_action', 'Неизвестное действие');
  }

  await publishPlayer(room.id, player);
  return { ok: true, ...result, serverNow: Date.now(), player: publicPlayer(player) };
}

// ---------- журналы приложений ----------
// Айфоны раз в несколько секунд присылают свои записи (синхронизация, паузы, ошибки).
// Лежат в server/data/logs/<ник>.log — по ним разбираем, что случилось на тестах.

const LOG_DIR = path.join(path.dirname(DATA_FILE), 'logs');
const LOG_MAX_BYTES = 5 * 1024 * 1024;

function stamp(ms) {
  const d = new Date(Number.isFinite(ms) ? ms : Date.now());
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} `
    + `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

async function appLog(req) {
  const body = await readJson(req, 512 * 1024);
  const user = requireDevice(req, body);
  const lines = Array.isArray(body.lines) ? body.lines.slice(0, 2000) : [];
  if (!lines.length) return { ok: true };
  const device = String(body.device ?? '').replace(/[\r\n]/g, ' ').slice(0, 80);
  const text = lines
    .map((line) => `${stamp(Number(line?.t))} [${device}] ${String(line?.m ?? '').replace(/[\r\n]+/g, ' ⏎ ').slice(0, 2000)}`)
    .join('\n') + '\n';
  const name = String(user.nick).replace(/[^\p{L}\p{N}_-]+/gu, '_').slice(0, 40) || 'unknown';
  const file = path.join(LOG_DIR, `${name}.log`);
  fs.mkdirSync(LOG_DIR, { recursive: true });
  try {
    if (fs.statSync(file).size > LOG_MAX_BYTES) fs.renameSync(file, path.join(LOG_DIR, `${name}.old.log`));
  } catch {}
  fs.appendFileSync(file, text);
  return { ok: true };
}

const routes = {
  'GET /api/health': async () => ({ ok: true }),
  'POST /api/register': register,
  'POST /api/token': token,
  'GET /api/rooms': rooms,
  'POST /api/rooms': createRoom,
  'POST /api/music': summonMusic,
  'POST /api/player': playerAction,
  'POST /api/log': appLog,
  // Часы сервера: по ним плееры сверяют, с какого места играть.
  'GET /api/time': async () => ({ now: Date.now() }),
};

// /api/rooms/<id>: переименовать (PATCH) или удалить (DELETE).
const roomRoutes = { PATCH: renameRoom, DELETE: deleteRoom };

const server = http.createServer(async (req, res) => {
  const pathname = new URL(req.url, 'http://x').pathname;
  const handler = routes[`${req.method} ${pathname}`];
  const roomMatch = pathname.match(/^\/api\/rooms\/([^/]+)$/);
  try {
    if (handler) return sendJson(res, 200, await handler(req));
    if (roomMatch && roomRoutes[req.method]) {
      return sendJson(res, 200, await roomRoutes[req.method](req, decodeURIComponent(roomMatch[1])));
    }
    if (req.method === 'GET' && serveStatic(req, res)) return;
    throw new HttpError(404, 'not_found', 'Не найдено');
  } catch (err) {
    if (err instanceof HttpError) return sendJson(res, err.status, { error: err.code, message: err.message });
    console.error(err);
    return sendJson(res, 500, { error: 'internal', message: 'Ошибка сервера' });
  }
});

loadDb();
server.listen(PORT, '0.0.0.0', () => {
  console.log(`VoiceRoom server: http://localhost:${PORT}  (LiveKit: ${LIVEKIT_URL || LIVEKIT_HTTP_URL})`);
});
