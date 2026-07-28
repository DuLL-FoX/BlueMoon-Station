import { MAX_ROWS } from './constants';
import {
  activeRow,
  closeRow,
  emptyRows,
  nextFreeChannel,
  openChannel,
  type RowsState,
  stepActive,
  updateRow,
} from './rows';

/** Открывает подряд несколько каналов: так стопка набирается в тестах. */
const withChannels = (...channels: Parameters<typeof openChannel>[1][]): RowsState =>
  channels.reduce((state, channel) => openChannel(state, channel), emptyRows());

describe('стопка набираемых сообщений', () => {
  it('первый же канал открывает строку и делает её активной', () => {
    const state = openChannel(emptyRows(), 'Say');

    expect(state.rows).toHaveLength(1);
    expect(activeRow(state)?.channel).toBe('Say');
  });

  it('второй канал добавляет строку рядом, а не заменяет первую', () => {
    const state = withChannels('Say', 'OOC');

    expect(state.rows.map(row => row.channel)).toEqual(['Say', 'OOC']);
    expect(activeRow(state)?.channel).toBe('OOC');
  });

  it('повторный вызов того же канала возвращает на его строку и не теряет текст', () => {
    let state = withChannels('Say', 'OOC');
    const say = state.rows[0];
    state = updateRow(state, say.id, { value: 'недописанное' });

    state = openChannel(state, 'Say');

    expect(state.rows).toHaveLength(2);
    expect(activeRow(state)?.id).toBe(say.id);
    expect(activeRow(state)?.value).toBe('недописанное');
  });

  it('на забитой стопке занимает пустую строку, а не выбрасывает чужой текст', () => {
    let state = withChannels('Say', 'OOC', 'Me', 'Radio');
    expect(state.rows).toHaveLength(MAX_ROWS);
    state = updateRow(state, state.rows[0].id, { value: 'важное' });
    state = updateRow(state, state.rows[2].id, { value: 'тоже важное' });

    state = openChannel(state, 'LOOC');

    expect(state.rows).toHaveLength(MAX_ROWS);
    expect(state.rows.map(row => row.value)).toEqual(['важное', '', 'тоже важное', '']);
    expect(activeRow(state)?.channel).toBe('LOOC');
  });

  it('на забитой стопке с текстом во всех строках ничего не теряет', () => {
    let state = withChannels('Say', 'OOC', 'Me', 'Radio');
    for (const row of state.rows) {
      state = updateRow(state, row.id, { value: 'текст' });
    }

    const next = openChannel(state, 'LOOC');

    expect(next.rows.map(row => row.channel)).toEqual(['Say', 'OOC', 'Me', 'Radio']);
    expect(next.activeId).toBe(next.rows[next.rows.length - 1].id);
  });

  it('закрытая строка передаёт фокус соседней', () => {
    let state = withChannels('Say', 'OOC', 'Me');
    const ooc = state.rows[1];
    state = { ...state, activeId: ooc.id };

    state = closeRow(state, ooc.id);

    expect(state.rows.map(row => row.channel)).toEqual(['Say', 'Me']);
    expect(activeRow(state)?.channel).toBe('Me');
  });

  it('закрытие последней строки оставляет стопку пустой', () => {
    const state = closeRow(openChannel(emptyRows(), 'Say'), 1);

    expect(state.rows).toHaveLength(0);
    expect(state.activeId).toBeNull();
  });

  it('закрытие неактивной строки не уводит фокус', () => {
    let state = withChannels('Say', 'OOC');
    const say = state.rows[0];

    state = closeRow(state, say.id);

    expect(activeRow(state)?.channel).toBe('OOC');
  });

  it('переход по стопке закольцован', () => {
    let state = withChannels('Say', 'OOC');

    state = stepActive(state, 1);
    expect(activeRow(state)?.channel).toBe('Say');

    state = stepActive(state, -1);
    expect(activeRow(state)?.channel).toBe('OOC');
  });

  it('одна строка никуда не переключается', () => {
    const state = openChannel(emptyRows(), 'Say');

    expect(stepActive(state, 1)).toBe(state);
  });

  it('смена канала проматывает уже занятые: двух строк одного канала быть не должно', () => {
    const state = withChannels('Say', 'Radio');
    const say = state.rows[0];

    // Say -> Radio занят -> Me
    expect(nextFreeChannel(state, say.id)).toBe('Me');
  });

  it('когда свободных каналов цикла нет, канал остаётся прежним', () => {
    const state = withChannels('Say', 'Radio', 'Me', 'OOC');
    const say = state.rows[0];

    expect(nextFreeChannel(state, say.id)).toBe('Say');
  });

  it('идентификаторы не переиспользуются после закрытия', () => {
    let state = openChannel(emptyRows(), 'Say');
    const first = state.rows[0].id;
    state = closeRow(state, first);
    state = openChannel(state, 'Say');

    expect(state.rows[0].id).not.toBe(first);
  });
});
