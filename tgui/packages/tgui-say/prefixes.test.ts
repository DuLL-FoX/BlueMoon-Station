import { getPrefix, stripPrefix } from './prefixes';

describe('разбор префиксов рации', () => {
  it('узнаёт общий канал в латинской раскладке', () => {
    expect(getPrefix(';привет')).toEqual({ token: ';', label: 'Общий' });
  });

  it('узнаёт общий канал в русской раскладке', () => {
    expect(getPrefix('жпривет')).toEqual({ token: ';', label: 'Общий' });
  });

  it('узнаёт канал отдела в обеих раскладках', () => {
    expect(getPrefix(':h привет')).toEqual({ token: ':h', label: 'Отдел' });
    expect(getPrefix(':р привет')).toEqual({ token: ':h', label: 'Отдел' });
    expect(getPrefix('Жр привет')).toEqual({ token: ':h', label: 'Отдел' });
  });

  it('принимает точку как префикс канала наравне с двоеточием', () => {
    expect(getPrefix('.s привет')).toEqual({ token: ':s', label: 'СБ' });
  });

  it('на незнакомом ключе показывает сам префикс, а не выдуманное имя', () => {
    expect(getPrefix(':щ привет')).toEqual({ token: ':o', label: ':o' });
  });

  it('не принимает префикс из середины строки', () => {
    expect(getPrefix('привет ;всем')).toBeNull();
    expect(getPrefix('2:3 счёт')).toBeNull();
  });

  it('не принимает пустое сообщение за префикс', () => {
    expect(getPrefix('')).toBeNull();
    expect(getPrefix(';')).toBeNull();
    expect(getPrefix(':')).toBeNull();
  });

  it('срезает префикс вместе с пробелом после него', () => {
    expect(stripPrefix(':h привет')).toBe('привет');
    expect(stripPrefix('жпривет')).toBe('привет');
    expect(stripPrefix(';  привет')).toBe(' привет');
  });

  it('оставляет текст без префикса нетронутым', () => {
    expect(stripPrefix('обычная реплика')).toBe('обычная реплика');
  });
});
