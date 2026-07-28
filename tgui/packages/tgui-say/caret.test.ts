import { flattenNewlines, isCaretOnFirstLine, isCaretOnLastLine } from './caret';

describe('положение курсора в поле ввода', () => {
  it('в однострочном тексте курсор считается и первой, и последней строкой', () => {
    const state = { value: 'обычная реплика', selectionStart: 5, selectionEnd: 5 };

    expect(isCaretOnFirstLine(state)).toBe(true);
    expect(isCaretOnLastLine(state)).toBe(true);
  });

  it('в середине многострочного текста стрелки остаются полю', () => {
    const state = { value: 'первая\nвторая\nтретья', selectionStart: 9, selectionEnd: 9 };

    expect(isCaretOnFirstLine(state)).toBe(false);
    expect(isCaretOnLastLine(state)).toBe(false);
  });

  it('на краях многострочного текста историю листать можно', () => {
    const value = 'первая\nвторая';

    expect(isCaretOnFirstLine({ value, selectionStart: 3, selectionEnd: 3 })).toBe(true);
    expect(isCaretOnLastLine({ value, selectionStart: 10, selectionEnd: 10 })).toBe(true);
  });

  it('выделенный кусок текста историю не листает', () => {
    const state = { value: 'реплика', selectionStart: 0, selectionEnd: 7 };

    expect(isCaretOnFirstLine(state)).toBe(false);
    expect(isCaretOnLastLine(state)).toBe(false);
  });

  it('переносы строк уезжают в речь одной строкой', () => {
    expect(flattenNewlines('первая\nвторая')).toBe('первая вторая');
    expect(flattenNewlines('  с отступами  \r\n  и переносом  ')).toBe('с отступами и переносом');
    expect(flattenNewlines('без переносов')).toBe('без переносов');
  });
});
