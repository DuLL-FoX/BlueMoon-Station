/**
 * @file
 * Где панель стоит на карте.
 *
 * Панель — браузерный элемент внутри панели карты, прижатый к её низу. Размер
 * ему задаём мы: элемент обязан быть ровно по высоте содержимого, иначе пустой
 * чёрный прямоугольник закроет собой карту.
 *
 * Все числа здесь — пиксели BYOND.
 */

import {
  PANEL_MAX_WIDTH,
  PANEL_MIN_WIDTH,
  PANEL_TOP_MARGIN,
  STATUS_BAR_HEIGHT,
} from './constants';

export type Size = { x: number; y: number };
export type Rect = { x: number; y: number; width: number; height: number };
export type Offset = { x: number; y: number };

/** Куда панель прижимается, пока игрок не сдвинул её сам. */
export type Anchor = 'hud' | 'bottom' | 'top';

export type Placement = {
  anchor: Anchor;
  /** Сколько пикселей снизу занимает панель действий игрока. */
  hudReserve: number;
  /** Сдвиг, который игрок задал перетаскиванием. */
  offset: Offset;
};

const DEFAULT_PLACEMENT: Placement = {
  anchor: 'hud',
  hudReserve: 0,
  offset: { x: 0, y: 0 },
};

/**
 * Разбирает то, что вернул winget.
 *
 * BYOND отдаёт размеры то объектом, то строкой вида "1024x768" — зависит от
 * версии и от того, чей это элемент. Проверять форму приходится здесь.
 */
export const parseSize = (raw: unknown): Size | null => {
  if (!raw) {
    return null;
  }
  if (typeof raw === 'object') {
    const value = raw as Partial<Size>;
    if (typeof value.x === 'number' && typeof value.y === 'number') {
      return { x: value.x, y: value.y };
    }
    return null;
  }
  if (typeof raw !== 'string') {
    return null;
  }
  const match = /^\s*(\d+)\s*[x,]\s*(\d+)\s*$/.exec(raw);
  if (!match) {
    return null;
  }
  return { x: Number(match[1]), y: Number(match[2]) };
};

/**
 * Высота панели действий в пикселях.
 *
 * HUD игрока нарисован прямо на карте, поэтому его высота считается в клетках:
 * пиксель клетки — это высота карты, поделённая на обзор.
 */
export const hudReserveFor = (map: Size, viewTiles: number, hudTiles: number): number => {
  if (!(viewTiles > 0) || !(hudTiles > 0)) {
    return 0;
  }
  return Math.round((map.y / viewTiles) * hudTiles);
};

const clamp = (value: number, min: number, max: number) =>
  Math.max(min, Math.min(max, value));

/** Прямоугольник панели: по центру карты, у выбранного края. */
export const panelRect = (
  map: Size,
  height: number,
  placement: Partial<Placement> = {},
): Rect => {
  const { anchor, hudReserve, offset } = { ...DEFAULT_PLACEMENT, ...placement };
  const width = Math.max(
    Math.min(PANEL_MIN_WIDTH, map.x),
    Math.min(map.x, PANEL_MAX_WIDTH),
  );
  const available = Math.max(1, map.y - STATUS_BAR_HEIGHT - PANEL_TOP_MARGIN);
  const clampedHeight = Math.max(1, Math.min(Math.round(height), available));

  let y: number;
  if (anchor === 'top') {
    y = 0;
  }
  else if (anchor === 'bottom') {
    y = map.y - STATUS_BAR_HEIGHT - clampedHeight;
  }
  else {
    y = map.y - STATUS_BAR_HEIGHT - hudReserve - clampedHeight;
  }

  return {
    x: clamp(
      Math.round((map.x - width) / 2 + offset.x),
      0,
      Math.max(0, map.x - width),
    ),
    y: clamp(Math.round(y + offset.y), 0, Math.max(0, map.y - clampedHeight)),
    width,
    height: clampedHeight,
  };
};

/** Перевод из пикселей CSS в пиксели BYOND. */
export const toByondPixels = (value: number, pixelRatio: number): number =>
  Math.ceil(value * (pixelRatio > 0 ? pixelRatio : 1));
