/**
 * @file
 * Подсказки по вводу и оценка длины сообщения.
 *
 * BlueMoon использует два похожих, но разных синтаксиса. "*ключ" в начале
 * строки — обычный эмоут, для него и работают подсказки. "глагол* реплика" —
 * кастомный глагол речи, там текст произвольный и подсказывать нечего.
 */

const EMOTE_PREFIX = '*';
const SUGGESTION_LIMIT = 8;

export type CustomSay = {
  verb: string;
  message: string;
};

/** Эмоции, подходящие под начатый ключ. Пустой список — подсказок нет. */
export const getEmoteSuggestions = (
  value: string,
  emotes: string[],
  limit: number = SUGGESTION_LIMIT,
): string[] => {
  if (!value.startsWith(EMOTE_PREFIX)) {
    return [];
  }
  const typed = value.slice(EMOTE_PREFIX.length).toLowerCase();
  if (typed.includes(' ')) {
    return [];
  }
  return emotes
    .filter(emote => emote.startsWith(typed))
    .slice(0, limit);
};

/**
 * Делит "глагол* реплика" на части.
 *
 * Звёздочка считается разделителем, только если перед ней стоит слово и
 * сразу за ней идёт пробел: иначе "2*2" превратилось бы в эмоут.
 */
export const splitCustomSay = (value: string): CustomSay | null => {
  const separator = value.indexOf('* ');
  if (separator <= 0) {
    return null;
  }
  const verb = value.slice(0, separator);
  if (verb.includes(' ') || !verb.trim().length) {
    return null;
  }
  return {
    verb,
    message: value.slice(separator + 2),
  };
};

/**
 * Длина сообщения в байтах после кодирования для отправки.
 *
 * Считать символы бесполезно: кириллица занимает шесть байт на символ, и
 * именно по этой длине сообщение начинает резаться на куски.
 */
export const encodedLength = (value: string): number =>
  encodeURIComponent(value).length;
