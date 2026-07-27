/**
 * @file
 * Управление самим окном скина.
 *
 * Показ, скрытие и фокус делает фронт, а не сервер: winset обрабатывается
 * клиентом локально, поэтому окно появляется без ожидания ответа сервера.
 */

const WINDOW_ID = 'tgui_say';
const BROWSER_ID = 'tgui_say.browser';
const MAP_ID = 'mapwindow.map';

/** Показывает окно и отдаёт ему фокус клавиатуры. */
export const windowOpen = () => {
  Byond.winset(WINDOW_ID, { 'is-visible': true });
  Byond.winset(BROWSER_ID, { focus: true });
};

/** Прячет окно и возвращает фокус на карту, иначе игрок не сможет ходить. */
export const windowClose = () => {
  Byond.winset(WINDOW_ID, { 'is-visible': false });
  Byond.winset(MAP_ID, { focus: true });
};
