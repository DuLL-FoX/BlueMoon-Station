/**
 * @file
 * Каналы связи: как они называются, как выглядят и как переключаются.
 *
 * Строки каналов обязаны совпадать с TGUI_SAY_CHANNEL_* в
 * code/__BLUEMOONCODE/_DEFINES/tgui_say.dm: это единственное, что связывает
 * канал в интерфейсе с веткой маршрутизации в DM.
 *
 * Ключ темы — суффикс класса в styles/channels.scss. Цвета там взяты из стилей
 * чата: строка ввода того же цвета, каким сообщение появится в логе, иначе от
 * цветовой кодировки нет никакого толку.
 */

export type Channel =
  | 'Say'
  | 'Radio'
  | 'Whisper'
  | 'Me'
  | 'Subtle'
  | 'Subtler'
  | 'SubtlerTable'
  | 'SubtlerTarget'
  | 'LOOC'
  | 'OOC'
  | 'AOOC';

type ChannelMeta = {
  /** Подпись на плашке слева. */
  label: string;
  /** Суффикс класса темы. */
  theme: string;
  /** Пояснение под подписью: название канала само по себе говорит не всё. */
  hint?: string;
  /** Виден ли канал окружающим: по этому признаку зажигается индикатор печати. */
  visible: boolean;
};

export const CHANNEL_META: Record<Channel, ChannelMeta> = {
  Say: { label: 'Речь', theme: 'say', visible: true },
  Radio: { label: 'Рация', theme: 'radio', hint: 'общий канал', visible: true },
  Whisper: { label: 'Шёпот', theme: 'whisper', hint: 'вплотную', visible: true },
  Me: { label: 'Эмоут', theme: 'emote', visible: true },
  Subtle: { label: 'Subtle', theme: 'emote', hint: 'рядом', visible: true },
  Subtler: { label: 'Subtler', theme: 'emote', hint: 'без духов', visible: true },
  SubtlerTable: { label: 'Subtler', theme: 'emote', hint: 'через стол', visible: true },
  SubtlerTarget: { label: 'Subtler', theme: 'emote', hint: 'для цели', visible: true },
  LOOC: { label: 'LOOC', theme: 'looc', visible: false },
  OOC: { label: 'OOC', theme: 'ooc', visible: false },
  AOOC: { label: 'AOOC', theme: 'aooc', visible: false },
};

/**
 * Короткий цикл Tab. Каналы вне цикла достижимы своими горячими клавишами:
 * прощёлкивать одиннадцать штук, чтобы вернуться к речи, никто не станет.
 */
export const CYCLE: Channel[] = ['Say', 'Radio', 'Me', 'OOC'];

export const isChannel = (value: unknown): value is Channel =>
  typeof value === 'string' && value in CHANNEL_META;

/** Следующий канал цикла. Канал вне цикла возвращает в его начало. */
export const nextInCycle = (channel: Channel): Channel => {
  const index = CYCLE.indexOf(channel);
  if (index < 0) {
    return CYCLE[0];
  }
  return CYCLE[(index + 1) % CYCLE.length];
};

/** Только в речи работают префиксы рации. */
export const isSayChannel = (channel: Channel): boolean => channel === 'Say';

/** Виден ли канал окружающим. */
export const isVisibleChannel = (channel: Channel): boolean =>
  CHANNEL_META[channel]?.visible ?? false;

/** Темы префиксов рации: ключ — латинская буква канала после двоеточия. */
const RADIO_THEMES: Record<string, string> = {
  h: 'radio',
  c: 'comradio',
  n: 'sciradio',
  m: 'medradio',
  e: 'engradio',
  s: 'secradio',
  u: 'suppradio',
  v: 'servradio',
  t: 'syndradio',
  y: 'centcomradio',
};

/** Тема строки: префикс рации перебивает канал, ведь текст уйдёт именно в него. */
export const themeFor = (channel: Channel, prefixToken?: string | null): string => {
  if (prefixToken) {
    if (prefixToken === ';') {
      return 'radio';
    }
    return RADIO_THEMES[prefixToken.slice(1)] || 'radio';
  }
  return CHANNEL_META[channel]?.theme || 'say';
};

/** Подпись плашки: у выбранного префикса рации она своя. */
export const labelFor = (channel: Channel, prefixLabel?: string | null): string =>
  prefixLabel || CHANNEL_META[channel]?.label || channel;

export const hintFor = (channel: Channel): string | undefined =>
  CHANNEL_META[channel]?.hint;
