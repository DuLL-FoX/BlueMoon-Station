/**
 * @file
 * Обмен сообщениями между окном ввода и DM.
 *
 * Окно принимает два формата. Сырая строка `open:<Канал>` — команда,
 * которую клиент может выполнить сам, без участия сервера; именно она делает
 * открытие мгновенным. JSON — обычное сообщение tgui из DM.
 */

type MessageHandler = (payload: any) => void;

const OPEN_COMMAND_PREFIX = 'open:';

let subscribers: Record<string, MessageHandler[]> = {};

/** Подписаться на сообщения указанного типа. */
export const subscribeTo = (type: string, handler: MessageHandler) => {
  subscribers[type] = subscribers[type] || [];
  subscribers[type].push(handler);
};

/** Снять всех подписчиков. Нужно тестам, в боевом коде не используется. */
export const resetSubscribers = () => {
  subscribers = {};
};

const parseJson = (text: string) => {
  if (typeof Byond !== 'undefined' && Byond.parseJson) {
    return Byond.parseJson(text);
  }
  return JSON.parse(text);
};

const notify = (type: string, payload: any) => {
  const handlers = subscribers[type];
  if (!handlers) {
    return;
  }
  for (const handler of handlers) {
    handler(payload);
  }
};

/** Разобрать входящее сообщение и раздать его подписчикам. */
export const dispatchMessage = (message: string) => {
  if (typeof message !== 'string') {
    return;
  }
  if (message.startsWith(OPEN_COMMAND_PREFIX)) {
    notify('open', { channel: message.slice(OPEN_COMMAND_PREFIX.length) });
    return;
  }
  let parsed: any;
  try {
    parsed = parseJson(message);
  }
  catch (err) {
    // Битое сообщение не должно ронять окно: игрок останется без речи.
    return;
  }
  if (!parsed || !parsed.type) {
    return;
  }
  notify(parsed.type, parsed.payload);
};

/** Отправить сообщение в DM. */
export const sendMessage = (type: string, payload: object = {}) => {
  Byond.topic({
    tgui: 1,
    window_id: window.__windowId__,
    type,
    payload: JSON.stringify(payload),
  });
};
