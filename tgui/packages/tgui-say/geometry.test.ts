import {
  PANEL_MAX_WIDTH,
  PANEL_TOP_MARGIN,
  STATUS_BAR_HEIGHT,
} from './constants';
import { panelRect, parseSize, toByondPixels } from './geometry';

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

  it('переводит пиксели CSS в пиксели BYOND с запасом вверх', () => {
    expect(toByondPixels(50, 1)).toBe(50);
    expect(toByondPixels(50.2, 1)).toBe(51);
    expect(toByondPixels(50, 1.5)).toBe(75);
    expect(toByondPixels(50, 0)).toBe(50);
  });
});
