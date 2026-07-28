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

/** Прямоугольник панели: по центру карты, над статус-строкой. */
export const panelRect = (map: Size, height: number): Rect => {
  const width = Math.max(
    Math.min(PANEL_MIN_WIDTH, map.x),
    Math.min(map.x, PANEL_MAX_WIDTH),
  );
  const available = Math.max(1, map.y - STATUS_BAR_HEIGHT - PANEL_TOP_MARGIN);
  const clamped = Math.max(1, Math.min(Math.round(height), available));
  return {
    x: Math.max(0, Math.round((map.x - width) / 2)),
    y: Math.max(0, map.y - STATUS_BAR_HEIGHT - clamped),
    width,
    height: clamped,
  };
};

/** Перевод из пикселей CSS в пиксели BYOND. */
export const toByondPixels = (value: number, pixelRatio: number): number =>
  Math.ceil(value * (pixelRatio > 0 ? pixelRatio : 1));
