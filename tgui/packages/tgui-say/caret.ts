/**
 * @file
 * Где стоит курсор в поле.
 *
 * От этого зависит, что делают стрелки: в однострочном тексте они листают
 * историю, а в набранном на несколько строк обязаны сначала ходить по нему
 * самому, иначе длинное сообщение невозможно править.
 */

export type CaretState = {
  value: string;
  selectionStart: number | null;
  selectionEnd: number | null;
};

/** Стоит ли курсор на первой строке текста. */
export const isCaretOnFirstLine = (state: CaretState): boolean => {
  const { selectionStart, selectionEnd } = state;
  if (selectionStart === null || selectionEnd === null) {
    return true;
  }
  if (selectionStart !== selectionEnd) {
    return false;
  }
  return state.value.lastIndexOf('\n', selectionStart - 1) < 0;
};

/** Стоит ли курсор на последней строке текста. */
export const isCaretOnLastLine = (state: CaretState): boolean => {
  const { selectionStart, selectionEnd } = state;
  if (selectionStart === null || selectionEnd === null) {
    return true;
  }
  if (selectionStart !== selectionEnd) {
    return false;
  }
  return state.value.indexOf('\n', selectionStart) < 0;
};

/**
 * Схлопывает переносы строк в пробелы.
 *
 * Shift+Enter нужен, чтобы видеть длинную реплику разложенной по строкам, но в
 * речь она уходит одной: перенос в чате всё равно не отобразится, зато рвёт
 * разбор префиксов и логи.
 */
export const flattenNewlines = (value: string): string =>
  value.replace(/\s*\r?\n\s*/g, ' ').trim();
