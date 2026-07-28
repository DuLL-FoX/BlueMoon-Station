import {
  PANEL_MAX_WIDTH,
  PANEL_TOP_MARGIN,
  STATUS_BAR_HEIGHT,
} from './constants';
import { hudReserveFor, panelRect, parseSize, toByondPixels } from './geometry';

describe('геометрия панели ввода', () => {
  it('разбирает размер, пришедший объектом', () => {
    expect(parseSize({ x: 1024, y: 768 })).toEqual({ x: 1024, y: 768 });
  });

  it('разбирает размер, пришедший строкой', () => {
    expect(parseSize('1024x768')).toEqual({ x: 1024, y: 768 });
    expect(parseSize('1024,768')).toEqual({ x: 1024, y: 768 });
  });

  it('не выдумывает размер из мусора', () => {
    expect(parseSize(null)).toBeNull();
    expect(parseSize('огромный')).toBeNull();
    expect(parseSize({ x: 10 })).toBeNull();
  });

  it('сажает панель над статус-строкой карты', () => {
    const rect = panelRect({ x: 1200, y: 800 }, 60);

    expect(rect.y + rect.height).toBe(800 - STATUS_BAR_HEIGHT);
    expect(rect.height).toBe(60);
  });

  it('держит панель по центру карты', () => {
    const rect = panelRect({ x: 1600, y: 900 }, 60);

    expect(rect.width).toBe(PANEL_MAX_WIDTH);
    expect(rect.x).toBe(Math.round((1600 - PANEL_MAX_WIDTH) / 2));
  });

  it('на узкой карте занимает её целиком', () => {
    const rect = panelRect({ x: 600, y: 400 }, 40);

    expect(rect.width).toBe(600);
    expect(rect.x).toBe(0);
  });

  it('не даёт панели закрыть собой карту', () => {
    const rect = panelRect({ x: 1000, y: 300 }, 5000);

    expect(rect.height).toBe(300 - STATUS_BAR_HEIGHT - PANEL_TOP_MARGIN);
    expect(rect.y).toBe(PANEL_TOP_MARGIN);
  });

  it('считает высоту панели действий по клеткам обзора', () => {
    // 900 пикселей на 15 клеток = 60 пикселей клетка, HUD в две клетки.
    expect(hudReserveFor({ x: 1200, y: 900 }, 15, 2)).toBe(120);
    expect(hudReserveFor({ x: 1200, y: 900 }, 0, 2)).toBe(0);
    expect(hudReserveFor({ x: 1200, y: 900 }, 15, 0)).toBe(0);
  });

  it('по умолчанию садится над панелью действий, а не поверх неё', () => {
    const rect = panelRect({ x: 1200, y: 900 }, 60, { anchor: 'hud', hudReserve: 120 });

    expect(rect.y + rect.height).toBe(900 - STATUS_BAR_HEIGHT - 120);
  });

  it('верхнее положение прижимает панель к верху карты', () => {
    const rect = panelRect({ x: 1200, y: 900 }, 60, { anchor: 'top' });

    expect(rect.y).toBe(0);
  });

  it('сдвиг игрока не даёт панели уехать за карту', () => {
    const map = { x: 1200, y: 900 };
    const far = panelRect(map, 60, { anchor: 'bottom', offset: { x: 9000, y: 9000 } });
    const back = panelRect(map, 60, { anchor: 'bottom', offset: { x: -9000, y: -9000 } });

    expect(far.x).toBe(map.x - far.width);
    expect(far.y).toBe(map.y - far.height);
    expect(back.x).toBe(0);
    expect(back.y).toBe(0);
  });

  it('сдвиг игрока двигает панель от места по умолчанию', () => {
    const base = panelRect({ x: 1600, y: 900 }, 60, { anchor: 'bottom' });
    const moved = panelRect({ x: 1600, y: 900 }, 60, {
      anchor: 'bottom',
      offset: { x: -100, y: -50 },
    });

    expect(moved.x).toBe(base.x - 100);
    expect(moved.y).toBe(base.y - 50);
  });

  it('переводит пиксели CSS в пиксели BYOND с запасом вверх', () => {
    expect(toByondPixels(50, 1)).toBe(50);
    expect(toByondPixels(50.2, 1)).toBe(51);
    expect(toByondPixels(50, 1.5)).toBe(75);
    expect(toByondPixels(50, 0)).toBe(50);
  });
});
