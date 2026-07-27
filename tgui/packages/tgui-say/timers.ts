/**
 * @file
 * Троттлинг сигнала набора.
 *
 * Сервер держит индикатор печати по таймауту и продлевает его на каждый
 * сигнал. Слать сигнал на каждый символ незачем — достаточно реже, чем
 * срабатывает таймаут.
 */

const TYPING_THROTTLE_MS = 4000;

let lastTypingAt = 0;

/** Пора ли слать серверу очередной сигнал набора. */
export const shouldSendTyping = (now: number): boolean => {
  if (lastTypingAt && now - lastTypingAt < TYPING_THROTTLE_MS) {
    return false;
  }
  lastTypingAt = now;
  return true;
};

/** Сброс после закрытия окна: следующий набор должен зажечь индикатор сразу. */
export const resetTypingThrottle = () => {
  lastTypingAt = 0;
};
