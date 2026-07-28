import {
  encodedLength,
  getEmoteSuggestions,
  splitCustomSay,
} from './suggestions';

const EMOTES = ['sigh', 'smile', 'salute', 'wave'];

describe('подсказки эмоций', () => {
  it('предлагает эмоции по началу ключа после звёздочки', () => {
    expect(getEmoteSuggestions('*s', EMOTES)).toEqual(['sigh', 'smile', 'salute']);
  });

  it('сужает список по мере набора', () => {
    expect(getEmoteSuggestions('*sm', EMOTES)).toEqual(['smile']);
  });

  it('на голой звёздочке показывает начало списка', () => {
    expect(getEmoteSuggestions('*', EMOTES).length).toBeGreaterThan(0);
  });

  it('молчит, когда звёздочки в начале нет', () => {
    expect(getEmoteSuggestions('обычная реплика', EMOTES)).toEqual([]);
    expect(getEmoteSuggestions('улыбается* привет', EMOTES)).toEqual([]);
  });

  it('не предлагает ничего на несовпадающем ключе', () => {
    expect(getEmoteSuggestions('*zzz', EMOTES)).toEqual([]);
  });
});

describe('разбор кастомного say', () => {
  it('делит строку на глагол и реплику', () => {
    expect(splitCustomSay('улыбается* привет')).toEqual({
      verb: 'улыбается',
      message: 'привет',
    });
  });

  it('не считает звёздочку внутри слова разделителем', () => {
    expect(splitCustomSay('2*2 будет 4')).toBeNull();
  });

  it('не считает звёздочку в начале строки разделителем', () => {
    expect(splitCustomSay('*sigh')).toBeNull();
  });

  it('обычную реплику не трогает', () => {
    expect(splitCustomSay('просто текст')).toBeNull();
  });
});

describe('длина сообщения в байтах транспорта', () => {
  it('считает латиницу по байту на символ', () => {
    expect(encodedLength('abc')).toBe(3);
  });

  it('считает кириллицу по шесть байт на символ: это и есть причина чанков', () => {
    expect(encodedLength('привет')).toBe(36);
  });
});
