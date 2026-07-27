/**
 * @file
 * Каналы окна ввода и переключение между ними.
 *
 * Строки каналов обязаны совпадать с TGUI_SAY_CHANNEL_* в
 * code/__BLUEMOONCODE/_DEFINES/tgui_say.dm: это единственное, что связывает
 * канал в интерфейсе с веткой маршрутизации в DM.
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

/**
 * Короткий цикл Tab. Каналы вне цикла достижимы своими горячими клавишами:
 * прощёлкивать восемь штук, чтобы вернуться к Say, никто не станет.
 */
export const CYCLE: Channel[] = ['Say', 'Radio', 'Me', 'OOC'];

/** Каналы, в которых индикатор печати показывать нельзя. */
const INVISIBLE: Channel[] = ['OOC', 'LOOC', 'AOOC'];

const ALL: Channel[] = [
  'Say',
  'Radio',
  'Whisper',
  'Me',
  'Subtle',
  'Subtler',
  'SubtlerTable',
  'SubtlerTarget',
  'LOOC',
  'OOC',
  'AOOC',
];

export class ChannelIterator {
  private index = 0;
  private offCycle: Channel | null = null;

  /** Текущий канал. */
  current(): Channel {
    return this.offCycle || CYCLE[this.index];
  }

  /** Следующий канал цикла. Из канала вне цикла возвращает в начало. */
  next(): Channel {
    if (this.offCycle) {
      this.offCycle = null;
      this.index = 0;
      return this.current();
    }
    this.index = (this.index + 1) % CYCLE.length;
    return this.current();
  }

  /** Поставить конкретный канал. Неизвестный канал игнорируется. */
  set(channel: Channel): void {
    if (!ALL.includes(channel)) {
      return;
    }
    const cycleIndex = CYCLE.indexOf(channel);
    if (cycleIndex >= 0) {
      this.offCycle = null;
      this.index = cycleIndex;
      return;
    }
    this.offCycle = channel;
  }

  /** Только в Say работают префиксы рации. */
  isSay(): boolean {
    return this.current() === 'Say';
  }

  /** Виден ли канал окружающим: по этому признаку зажигается индикатор печати. */
  isVisible(): boolean {
    return !INVISIBLE.includes(this.current());
  }

  reset(): void {
    this.index = 0;
    this.offCycle = null;
  }
}
