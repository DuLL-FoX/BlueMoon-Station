import {
  CYCLE,
  isChannel,
  isSayChannel,
  isVisibleChannel,
  labelFor,
  nextInCycle,
  themeFor,
} from './channels';

describe('каналы панели ввода', () => {
  it('цикл Tab закольцован', () => {
    let channel = CYCLE[0];
    for (let step = 0; step < CYCLE.length; step++) {
      channel = nextInCycle(channel);
    }

    expect(channel).toBe(CYCLE[0]);
  });

  it('канал вне цикла возвращает в его начало', () => {
    expect(nextInCycle('Whisper')).toBe(CYCLE[0]);
    expect(nextInCycle('SubtlerTarget')).toBe(CYCLE[0]);
  });

  it('OOC-каналы не показывают индикатор печати', () => {
    expect(isVisibleChannel('Say')).toBe(true);
    expect(isVisibleChannel('Me')).toBe(true);
    expect(isVisibleChannel('OOC')).toBe(false);
    expect(isVisibleChannel('LOOC')).toBe(false);
    expect(isVisibleChannel('AOOC')).toBe(false);
  });

  it('префиксы рации работают только в речи', () => {
    expect(isSayChannel('Say')).toBe(true);
    expect(isSayChannel('Radio')).toBe(false);
  });

  it('чужие строки каналом не считаются', () => {
    expect(isChannel('Say')).toBe(true);
    expect(isChannel('НетТакогоКанала')).toBe(false);
    expect(isChannel(null)).toBe(false);
  });

  it('префикс рации перебивает тему канала', () => {
    expect(themeFor('Say')).toBe('say');
    expect(themeFor('Say', ';')).toBe('radio');
    expect(themeFor('Say', ':s')).toBe('secradio');
    expect(themeFor('Say', ':щ')).toBe('radio');
  });

  it('подпись плашки уступает выбранному префиксу', () => {
    expect(labelFor('Say')).toBe('Речь');
    expect(labelFor('Say', 'СБ')).toBe('СБ');
  });
});
