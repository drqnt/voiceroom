// Музыкальный бот VoiceRoom.
//
// Сам заходит в каждую комнату, где кто-то есть, и играет туда звук с YouTube,
// как музыкальные боты в Discord: все в комнате слышат один и тот же поток.
// Управление — RPC-вызовы от участников (music.play / music.skip / music.stop),
// состояние — атрибуты участника-бота (music.current, music.queue, music.error).
//
// Боту нужны yt-dlp, deno и ffmpeg. Он подключается к LiveKit сам (исходящее
// соединение), поэтому может работать на любом компьютере: на сервере или на Маке.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  AudioFrame,
  AudioSource,
  LocalAudioTrack,
  Room,
  RoomEvent,
  RpcError,
  TrackPublishOptions,
  TrackSource,
} from '@livekit/rtc-node';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import {
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
  LIVEKIT_HTTP_URL,
  MUSIC_BOT_IDENTITY as BOT_IDENTITY,
} from './config.js';

// Бот подключается к LiveKit сам; дома это локальный сервер.
const LIVEKIT_URL = process.env.LIVEKIT_URL || 'ws://127.0.0.1:7880';

const SAMPLE_RATE = 48000;
const CHANNELS = 2;
const FRAME_SAMPLES = 960; // 20 мс
const FRAME_BYTES = FRAME_SAMPLES * CHANNELS * 2;
const MAX_QUEUE = 30;
const SYNC_INTERVAL_MS = 3000;
const EMPTY_ROOM_GRACE_MS = 15000;
// Если музыка не играет столько времени, бот уходит (в облаке он тратит минуты).
const IDLE_LEAVE_MS = Number(process.env.MUSIC_IDLE_LEAVE_SEC ?? 300) * 1000;

const roomService = new RoomServiceClient(LIVEKIT_HTTP_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// Сюда складываем найденную информацию о треках, чтобы при запуске не искать их заново.
const INFO_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'voiceroom-music-'));
const removeFile = (file) => file && fs.rm(file, { force: true }, () => {});

const log = (...args) => console.log(new Date().toISOString().slice(11, 19), ...args);

// ---------- YouTube ----------

function run(cmd, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(out);
      else reject(new Error(err.trim().split('\n').pop() || `${cmd} завершился с кодом ${code}`));
    });
  });
}

/**
 * Находит трек по ссылке или поисковому запросу.
 *
 * Сначала спрашиваем YouTube как встроенный плеер (web_embedded): так звук отдаётся
 * сразу, а обычный способ заставляет ждать ~3 секунды на каждый трек. Видео, которые
 * запрещено встраивать, находим обычным способом (client = 'default').
 *
 * Полную информацию yt-dlp сохраняет в файл: при запуске трека она берётся оттуда,
 * без повторного поиска.
 */
async function resolveTrack(query, client = 'web_embedded') {
  const target = /^https?:\/\//i.test(query) ? query : `ytsearch1:${query}`;
  const clientArgs = client === 'default' ? [] : ['--extractor-args', `youtube:player_client=${client}`];
  const out = await run('yt-dlp', [...clientArgs, '-f', 'bestaudio/best', '-j', '--no-playlist', '--no-warnings', target], 40000);
  const line = out.trim().split('\n')[0];
  if (!line) throw new Error('Ничего не нашлось');
  const info = JSON.parse(line);
  const infoFile = path.join(INFO_DIR, `${info.id}-${Date.now()}.json`);
  fs.writeFileSync(infoFile, line);
  return { url: info.webpage_url, title: info.title, duration: Number(info.duration) || null, infoFile, client };
}

/** То же, но если быстрый способ не нашёл трек, пробует обычный. */
async function resolveTrackAnyClient(query) {
  try {
    return await resolveTrack(query, 'web_embedded');
  } catch (err) {
    if (/ничего не нашлось/i.test(err.message)) throw err;
    return resolveTrack(query, 'default');
  }
}

// ---------- проигрыватель одной комнаты ----------

class RoomPlayer {
  constructor(roomName) {
    this.roomName = roomName;
    this.room = new Room();
    this.source = new AudioSource(SAMPLE_RATE, CHANNELS, 500);
    this.queue = [];
    this.current = null;
    this.procs = [];
    this.playId = 0;
    this.lastError = '';
    this.emptySince = null;
    this.lastActive = Date.now();
  }

  async connect() {
    const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity: BOT_IDENTITY,
      name: 'Музыка',
      ttl: '24h',
    });
    at.addGrant({
      room: this.roomName,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
      // Без этого права бот не может публиковать «что играет» в атрибутах.
      canUpdateOwnMetadata: true,
    });

    this.room.on(RoomEvent.Disconnected, () => {
      log(`[${this.roomName}] отключён`);
      this.stopPlayback();
      players.delete(this.roomName);
    });

    await this.room.connect(LIVEKIT_URL, await at.toJwt(), { autoSubscribe: false, dynacast: false });

    const track = LocalAudioTrack.createAudioTrack('music', this.source);
    const options = new TrackPublishOptions({
      source: TrackSource.SOURCE_SCREENSHARE_AUDIO,
      dtx: false,
      red: false,
      audioEncoding: { maxBitrate: 128000n },
    });
    await this.room.localParticipant.publishTrack(track, options);

    const lp = this.room.localParticipant;
    lp.registerRpcMethod('music.play', async ({ payload, callerIdentity }) => this.enqueue(payload, callerIdentity));
    lp.registerRpcMethod('music.skip', async () => {
      this.skip();
      return 'ok';
    });
    lp.registerRpcMethod('music.stop', async () => {
      this.queue.forEach((t) => removeFile(t.infoFile));
      this.queue = [];
      this.stopPlayback();
      await this.publishState();
      return 'ok';
    });

    await this.publishState();
    log(`[${this.roomName}] бот в комнате`);
  }

  async disconnect() {
    this.queue.forEach((t) => removeFile(t.infoFile));
    this.queue = [];
    this.stopPlayback();
    await this.room.disconnect().catch(() => {});
    players.delete(this.roomName);
  }

  async enqueue(rawQuery, by) {
    const query = String(rawQuery ?? '').trim().slice(0, 300);
    if (!query) throw new RpcError(2000, 'Пустой запрос');
    if (this.queue.length >= MAX_QUEUE) throw new RpcError(2001, 'Очередь заполнена');

    let track;
    try {
      track = await resolveTrackAnyClient(query);
    } catch (err) {
      log(`[${this.roomName}] не нашёл «${query}»: ${err.message}`);
      throw new RpcError(2002, `Не получилось найти на YouTube: ${err.message}`.slice(0, 250));
    }

    this.lastError = '';
    this.queue.push({ ...track, by });
    log(`[${this.roomName}] + ${track.title} (от ${by})`);
    if (!this.current) this.playNext();
    else await this.publishState();
    return track.title;
  }

  skip() {
    // Остановка процессов завершит текущий трек, и заиграет следующий.
    this.killProcs();
  }

  stopPlayback() {
    this.playId++;
    this.current = null;
    this.killProcs();
    this.source.clearQueue();
  }

  killProcs() {
    for (const p of this.procs) p.kill('SIGKILL');
    this.procs = [];
  }

  playNext() {
    const next = this.queue.shift();
    this.current = next ?? null;
    this.publishState();
    if (!next) return;
    this.stream(next).catch((err) => log(`[${this.roomName}] ошибка потока: ${err.message}`));
  }

  async stream(track, retry = true) {
    const id = ++this.playId;
    log(`[${this.roomName}] ▶ ${track.title}`);

    // Берём уже найденную информацию; если её нет, yt-dlp разберёт ссылку сам.
    const source = track.infoFile && fs.existsSync(track.infoFile) ? ['--load-info-json', track.infoFile] : [track.url];
    const ytdlp = spawn('yt-dlp', ['-f', 'bestaudio/best', '--no-playlist', '--no-warnings', '--quiet', '-o', '-', ...source], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const ffmpeg = spawn(
      'ffmpeg',
      ['-loglevel', 'error', '-i', 'pipe:0', '-vn', '-f', 's16le', '-ac', String(CHANNELS), '-ar', String(SAMPLE_RATE), 'pipe:1'],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    this.procs = [ytdlp, ffmpeg];
    ytdlp.stdout.pipe(ffmpeg.stdin);
    ffmpeg.stdin.on('error', () => {});

    let ytdlpError = '';
    ytdlp.stderr.on('data', (d) => (ytdlpError += d));

    const startedAt = Date.now();
    let pending = Buffer.alloc(0);
    let sentFrames = 0;
    try {
      for await (const chunk of ffmpeg.stdout) {
        if (id !== this.playId) break;
        pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
        while (pending.length >= FRAME_BYTES && id === this.playId) {
          const bytes = pending.subarray(0, FRAME_BYTES);
          pending = pending.subarray(FRAME_BYTES);
          const samples = new Int16Array(FRAME_SAMPLES * CHANNELS);
          Buffer.from(samples.buffer).set(bytes);
          if (sentFrames === 0) log(`[${this.roomName}] первый звук через ${Date.now() - startedAt} мс`);
          await this.source.captureFrame(new AudioFrame(samples, SAMPLE_RATE, CHANNELS, FRAME_SAMPLES));
          sentFrames++;
        }
      }
    } catch (err) {
      // Процессы убили (кнопка «следующий») или поток оборвался: просто идём дальше.
      log(`[${this.roomName}] поток прерван: ${err.code ?? err.message}`);
    } finally {
      ytdlp.kill('SIGKILL');
      ffmpeg.kill('SIGKILL');
    }

    removeFile(track.infoFile);
    if (id !== this.playId) return; // остановили или переключили вручную
    if (sentFrames === 0 && retry && track.infoFile) {
      // Видео запрещено встраивать или ссылка протухла: находим трек заново обычным способом.
      log(`[${this.roomName}] быстрый способ не сработал (${ytdlpError.trim().split('\n').pop() || 'нет звука'}), пробую обычный`);
      try {
        const fresh = await resolveTrack(track.url, 'default');
        if (id === this.playId) return this.stream({ ...track, infoFile: fresh.infoFile }, false);
      } catch {}
    }
    if (sentFrames === 0 && ytdlpError.trim()) {
      this.lastError = `YouTube не отдал звук: ${ytdlpError.trim().split('\n').pop()}`.slice(0, 250);
      log(`[${this.roomName}] ${this.lastError}`);
    }
    this.procs = [];
    this.playNext();
  }

  async publishState() {
    const attrs = {
      'music.current': this.current
        ? JSON.stringify({ title: this.current.title, duration: this.current.duration, by: this.current.by })
        : '',
      'music.queue': JSON.stringify(this.queue.map((t) => t.title)),
      'music.error': this.lastError,
    };
    await this.room.localParticipant?.setAttributes(attrs).catch((err) => log('атрибуты:', err.message));
  }

  get isIdle() {
    if (this.current || this.queue.length) this.lastActive = Date.now();
    return Date.now() - this.lastActive > IDLE_LEAVE_MS;
  }

  get humanCount() {
    return [...this.room.remoteParticipants.values()].filter((p) => p.identity !== BOT_IDENTITY).length;
  }
}

// ---------- заход в комнаты ----------

const players = new Map();
const joining = new Set();
// Когда бот ушёл из комнаты: облако может ещё несколько секунд отдавать старую метку
// «позвали», поэтому возвращаемся только на вызов, сделанный после ухода.
const leftAt = new Map();

async function sync() {
  let rooms;
  try {
    rooms = await roomService.listRooms();
  } catch (err) {
    log('LiveKit недоступен:', err.message);
    return;
  }

  for (const r of rooms) {
    if (players.has(r.name) || joining.has(r.name) || r.numParticipants === 0) continue;
    const requestedAt = musicRequestedAt(r.metadata);
    if (!requestedAt || requestedAt <= (leftAt.get(r.name) ?? 0)) continue; // бот заходит, только когда зовут
    const participants = await roomService.listParticipants(r.name).catch(() => []);
    if (!participants.some((p) => p.identity !== BOT_IDENTITY)) continue;
    if (participants.some((p) => p.identity === BOT_IDENTITY)) continue; // другой экземпляр бота уже там

    joining.add(r.name);
    const player = new RoomPlayer(r.name);
    players.set(r.name, player);
    player
      .connect()
      .catch((err) => {
        log(`[${r.name}] не удалось зайти: ${err.message}`);
        players.delete(r.name);
      })
      .finally(() => joining.delete(r.name));
  }

  // Уходим из опустевших комнат.
  const now = Date.now();
  for (const player of players.values()) {
    if (joining.has(player.roomName)) continue;
    if (player.humanCount > 0) {
      player.emptySince = null;
    } else if (player.emptySince === null) {
      player.emptySince = now;
    } else if (now - player.emptySince > EMPTY_ROOM_GRACE_MS) {
      log(`[${player.roomName}] все ушли, выхожу`);
      await leave(player);
      continue;
    }
    if (player.isIdle) {
      log(`[${player.roomName}] музыка давно не играет, выхожу`);
      await leave(player);
    }
  }
}

function musicRequestedAt(metadata) {
  try {
    return Number(JSON.parse(metadata || '{}').music) || 0;
  } catch {
    return 0;
  }
}

async function leave(player) {
  leftAt.set(player.roomName, Date.now());
  // Снимаем свою метку (название комнаты не трогаем), чтобы бот не вернулся сам.
  try {
    const [room] = await roomService.listRooms([player.roomName]);
    const { music, ...rest } = JSON.parse(room?.metadata || '{}');
    await roomService.updateRoomMetadata(player.roomName, JSON.stringify(rest));
  } catch {}
  await player.disconnect();
}

log(`Музыкальный бот: ${LIVEKIT_URL}`);
setInterval(sync, SYNC_INTERVAL_MS);
sync();

const shutdown = async () => {
  await Promise.all([...players.values()].map((p) => p.disconnect()));
  fs.rmSync(INFO_DIR, { recursive: true, force: true });
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
