/**
 * @file
 * Работа со скином: показ, скрытие, фокус и размер панели.
 *
 * Всё это делает фронт, а не сервер: winset обрабатывается клиентом локально,
 * поэтому панель появляется без ожидания ответа сервера. Каждое действие —
 * ровно один winset: раздельные вызовы приезжают к клиенту по отдельности, и
 * между ними панель успевает оказаться в полуоткрытом состоянии.
 */

import { panelRect, parseSize, type Rect, type Size, toByondPixels } from './geometry';

const WINDOW_ID = 'tgui_say';
const MAP_WINDOW_ID = 'mapwindow';
const MAP_ID = 'map';

let mapSize: Size | null = null;
let lastRect: Rect | null = null;

const pixelRatio = () => window.devicePixelRatio || 1;

const askSize = async (id: string): Promise<Size | null> => {
  try {
    return parseSize(await Byond.winget(id, 'size'));
  }
  catch (err) {
    return null;
  }
};

/** Размер панели карты. Меняется, когда игрок таскает разделитель или окно. */
export const refreshMapSize = async (): Promise<Size | null> => {
  // Панель важнее геометрии: если размер узнать не удалось, она всё равно
  // откроется — там, где её поставил скин.
  mapSize = (await askSize(MAP_WINDOW_ID)) || (await askSize(MAP_ID));
  return mapSize;
};

/** Ширина, на которую панель может рассчитывать при вёрстке, в пикселях CSS. */
export const panelWidthCss = (): number | null => {
  if (!mapSize) {
    return null;
  }
  return panelRect(mapSize, 1).width / pixelRatio();
};

const geometryProps = (heightCss: number): Record<string, string> => {
  if (!mapSize) {
    return {};
  }
  const rect = panelRect(mapSize, toByondPixels(heightCss, pixelRatio()));
  if (
    lastRect
    && lastRect.x === rect.x
    && lastRect.y === rect.y
    && lastRect.width === rect.width
    && lastRect.height === rect.height
  ) {
    return {};
  }
  lastRect = rect;
  return {
    [`${WINDOW_ID}.pos`]: `${rect.x},${rect.y}`,
    [`${WINDOW_ID}.size`]: `${rect.width}x${rect.height}`,
  };
};

/** Показывает панель нужной высоты и отдаёт ей фокус клавиатуры. */
export const showPanel = (heightCss: number) => {
  Byond.winset({
    ...geometryProps(heightCss),
    [`${WINDOW_ID}.is-visible`]: true,
    [`${WINDOW_ID}.focus`]: true,
  });
};

/** Подгоняет высоту под содержимое. Молчит, если ничего не изменилось. */
export const resizePanel = (heightCss: number) => {
  const props = geometryProps(heightCss);
  if (!Object.keys(props).length) {
    return;
  }
  Byond.winset(props);
};

/**
 * Прячет панель и возвращает фокус на карту.
 *
 * Одним вызовом: если сначала спрятать панель, а фокус вернуть отдельно, то
 * вторая команда уходит уже из невидимого элемента — и фокус не возвращается
 * никому. Игрок остаётся без управления и без горячих клавиш.
 */
export const hidePanel = () => {
  Byond.winset({
    [`${WINDOW_ID}.is-visible`]: false,
    [`${MAP_ID}.focus`]: true,
  });
};

/** Сбрасывает запомненную геометрию. Нужно тестам. */
export const resetGeometryCache = () => {
  mapSize = null;
  lastRect = null;
};
