/**
 * @file
 * Префиксы рации в двух раскладках.
 *
 * Серверный разбор (get_message_mode в code/modules/mob/say.dm) уже понимает
 * русские буквы после двоеточия, но сам символ префикса — нет: на ЙЦУКЕН на
 * месте ";" стоит "ж", а на месте ":" — "Ж". Поэтому окно приводит префикс к
 * латинскому виду, а разбор остаётся единственным и живёт на сервере.
 */

/** Буквы и знаки, стоящие на одной физической клавише в QWERTY и ЙЦУКЕН. */
const RU_TO_EN: Record<string, string> = {
  й: 'q', ц: 'w', у: 'e', к: 'r', е: 't', н: 'y', г: 'u', ш: 'i', щ: 'o', з: 'p',
  х: '[', ъ: ']',
  ф: 'a', ы: 's', в: 'd', а: 'f', п: 'g', р: 'h', о: 'j', л: 'k', д: 'l',
  ж: ';', э: "'",
  я: 'z', ч: 'x', с: 'c', м: 'v', и: 'b', т: 'n', ь: 'm',
  б: ',', ю: '.',
  Ж: ':',
};

/** Имена каналов, которые игроки видят каждый раунд. */
const CHANNEL_LABELS: Record<string, string> = {
  h: 'Отдел',
  c: 'Командный',
  n: 'Наука',
  m: 'Медицина',
  e: 'Инженерный',
  s: 'СБ',
  u: 'Снабжение',
  v: 'Сервис',
  t: 'Синдикат',
  y: 'ЦК',
};

const COMMON_LABEL = 'Общий';
const COMMON_TOKENS = [';', 'ж'];
const DEPARTMENT_TOKENS = [':', '.', 'Ж'];

export type RadioPrefix = {
  /** Префикс в латинском виде — именно он уходит на сервер. */
  token: string;
  /** Подпись для кнопки канала. */
  label: string;
};

const toLatin = (char: string) => RU_TO_EN[char] || char;

/**
 * Ищет префикс рации в начале строки.
 *
 * Возвращает null, если префикса нет: префикс в середине строки — это обычный
 * текст, а не переключение канала.
 */
export const getPrefix = (value: string): RadioPrefix | null => {
  if (!value.length) {
    return null;
  }
  const first = value[0];
  if (COMMON_TOKENS.includes(first)) {
    // Голый префикс без текста каналом не считается: человек ещё печатает.
    return value.length > 1 ? { token: ';', label: COMMON_LABEL } : null;
  }
  if (DEPARTMENT_TOKENS.includes(first) && value.length > 1) {
    const key = toLatin(value[1]).toLowerCase();
    const token = `:${key}`;
    return { token, label: CHANNEL_LABELS[key] || token };
  }
  return null;
};

/** Убирает префикс из текста вместе с одним пробелом после него. */
export const stripPrefix = (value: string): string => {
  const prefix = getPrefix(value);
  if (!prefix) {
    return value;
  }
  const consumed = prefix.token.length === 1 ? 1 : 2;
  const rest = value.slice(consumed);
  return rest.startsWith(' ') ? rest.slice(1) : rest;
};
