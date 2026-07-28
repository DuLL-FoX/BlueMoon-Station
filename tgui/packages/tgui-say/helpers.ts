/**
 * @file
 * Работа со скином: показ, скрытие, фокус и размер панели.
 *
 * Всё это делает фронт, а не сервер: winset обрабатывается клиентом локально,
 * поэтому панель появляется без ожидания ответа сервера. Каждое действие —
 * ровно один winset: раздельные вызовы приезжают к клиенту по отдельности, и
 * между ними панель успевает оказаться в полуоткрытом состоянии.
 */

import {
  type Anchor,
  hudReserveFor,
  type Offset,
  panelRect,
  parseSize,
  type Rect,
  type Size,
  toByondPixels,
} from './geometry';

const WINDOW_ID = 'tgui_say';
const MAP_WINDOW_ID = 'mapwindow';
const MAP_ID = 'map';
const OFFSET_STORAGE_KEY = 'tgui-say-offset';

let mapSize: Size | null = null;
let lastRect: Rect | null = null;
let anchor: Anchor = 'hud';
let viewTiles = 0;
let hudTiles = 0;
let offset: Offset = { x: 0, y: 0 };

const pixelRatio = () => window.devicePixelRatio || 1;

const readOffset = (): Offset => {
  try {
    const raw = window.localStorage?.getItem(OFFSET_STORAGE_KEY);
    if (!raw) {
      return { x: 0, y: 0 };
    }
    const parsed = JSON.parse(raw);
    if (typeof parsed?.x === 'number' && typeof parsed?.y === 'number') {
      return { x: parsed.x, y: parsed.y };
    }
  }
  catch (err) {
    // Сдвиг — не то, ради чего стоит ронять ввод.
  }
  return { x: 0, y: 0 };
};

offset = readOffset();

const writeOffset = () => {
  try {
    window.localStorage?.setItem(OFFSET_STORAGE_KEY, JSON.stringify(offset));
  }
  catch (err) {
    // Место панели переживёт раунд и без записи.
  }
};

/** Настройки размещения приходят с сервера вместе с остальными props. */
export const setPlacement = (
  nextAnchor: unknown,
  nextViewTiles: unknown,
  nextHudTiles: unknown,
) => {
  if (nextAnchor === 'hud' || nextAnchor === 'bottom' || nextAnchor === 'top') {
    anchor = nextAnchor;
  }
  if (typeof nextViewTiles === 'number' && nextViewTiles > 0) {
    viewTiles = nextViewTiles;
  }
  if (typeof nextHudTiles === 'number' && nextHudTiles > 0) {
    hudTiles = nextHudTiles;
  }
  lastRect = null;
};

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

const rectFor = (heightCss: number): Rect | null => {
  if (!mapSize) {
    return null;
  }
  return panelRect(mapSize, toByondPixels(heightCss, pixelRatio()), {
    anchor,
    hudReserve: hudReserveFor(mapSize, viewTiles, hudTiles),
    offset,
  });
};

const geometryProps = (heightCss: number): Record<string, string> => {
  const rect = rectFor(heightCss);
  if (!rect) {
    return {};
  }
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

/**
 * Сдвигает панель на заданное расстояние от места по умолчанию.
 *
 * Сдвиг считается в пикселях экрана: панель едет за курсором, поэтому курсор
 * остаётся над ней и браузер продолжает получать события мыши. Отпустил бы он
 * их хоть на кадр — перетаскивание оборвалось бы на середине.
 */
export const dragPanelTo = (deltaCssX: number, deltaCssY: number, base: Offset, heightCss: number) => {
  const ratio = pixelRatio();
  offset = {
    x: Math.round(base.x + deltaCssX * ratio),
    y: Math.round(base.y + deltaCssY * ratio),
  };
  resizePanel(heightCss);
};

export const currentOffset = (): Offset => ({ ...offset });

/** Запоминает место панели между раундами. */
export const commitOffset = () => writeOffset();

/** Возвращает панель на место, выбранное в настройках. */
export const resetOffset = (heightCss: number) => {
  offset = { x: 0, y: 0 };
  writeOffset();
  resizePanel(heightCss);
};

/** Сбрасывает запомненную геометрию. Нужно тестам. */
export const resetGeometryCache = () => {
  mapSize = null;
  lastRect = null;
  offset = { x: 0, y: 0 };
};
