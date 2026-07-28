/**
 * @file
 * Стопка набираемых сообщений.
 *
 * Панель держит несколько строк сразу: начал реплику, ответил в OOC, вернулся
 * к реплике. Ровно это раньше давал нативный ввод BYOND, где диалогов можно
 * было открыть сколько угодно.
 *
 * Логика собрана отдельно от React и не знает ни про Byond, ни про DOM: её
 * поведение проверяется тестами, а компонент остаётся тонким.
 */

import { type Channel, CYCLE, nextInCycle } from './channels';
import { MAX_ROWS } from './constants';
import type { RadioPrefix } from './prefixes';

export type Row = {
  id: number;
  channel: Channel;
  /** Выбранный префикс рации. Живёт только у канала Say. */
  prefix: RadioPrefix | null;
  value: string;
};

export type RowsState = {
  rows: Row[];
  activeId: number | null;
  /** Счётчик идентификаторов. Индекс в массиве не годится: строки удаляются. */
  nextId: number;
};

export const emptyRows = (): RowsState => ({ rows: [], activeId: null, nextId: 1 });

export const activeRow = (state: RowsState): Row | null =>
  state.rows.find(row => row.id === state.activeId) || null;

export const hasText = (state: RowsState): boolean =>
  state.rows.some(row => row.value.length > 0);

const withActive = (state: RowsState, rows: Row[], activeId: number | null): RowsState => ({
  rows,
  activeId,
  nextId: state.nextId,
});

/**
 * Открывает канал.
 *
 * Строка этого канала уже есть — просто становимся на неё, недописанное
 * остаётся на месте. Иначе добавляем новую. Когда стопка забита, занимаем
 * первую пустую строку: терять чужой текст ради нового канала нельзя.
 */
export const openChannel = (state: RowsState, channel: Channel): RowsState => {
  const existing = state.rows.find(row => row.channel === channel);
  if (existing) {
    return withActive(state, state.rows, existing.id);
  }
  if (state.rows.length < MAX_ROWS) {
    const row: Row = { id: state.nextId, channel, prefix: null, value: '' };
    return {
      rows: [...state.rows, row],
      activeId: row.id,
      nextId: state.nextId + 1,
    };
  }
  const reusable = state.rows.find(row => !row.value.length);
  if (reusable) {
    return withActive(
      state,
      state.rows.map(row =>
        row.id === reusable.id ? { ...row, channel, prefix: null } : row,
      ),
      reusable.id,
    );
  }
  // Все строки заняты текстом: ничего не выбрасываем, просто возвращаем игрока
  // к последней. Пусть сначала разберётся с тем, что уже написал.
  return withActive(state, state.rows, state.rows[state.rows.length - 1].id);
};

export const updateRow = (state: RowsState, id: number, patch: Partial<Row>): RowsState =>
  withActive(
    state,
    state.rows.map(row => (row.id === id ? { ...row, ...patch } : row)),
    state.activeId,
  );

/**
 * Убирает строку.
 *
 * Фокус переезжает на соседнюю: сначала на следующую по стопке, а если убрали
 * последнюю — на предыдущую. Прыгать в начало списка неудобно.
 */
export const closeRow = (state: RowsState, id: number): RowsState => {
  const index = state.rows.findIndex(row => row.id === id);
  if (index < 0) {
    return state;
  }
  const rows = state.rows.filter(row => row.id !== id);
  if (!rows.length) {
    return withActive(state, rows, null);
  }
  if (state.activeId !== id) {
    return withActive(state, rows, state.activeId);
  }
  const next = rows[Math.min(index, rows.length - 1)];
  return withActive(state, rows, next.id);
};

/**
 * Следующий канал цикла, не занятый другой строкой.
 *
 * Две строки одного канала — это спор о том, куда уйдёт текст, и путаница на
 * ровном месте. Занятые каналы Tab проматывает; если свободных нет, канал
 * остаётся прежним.
 */
export const nextFreeChannel = (state: RowsState, id: number): Channel => {
  const row = state.rows.find(item => item.id === id);
  if (!row) {
    return CYCLE[0];
  }
  const taken = new Set(
    state.rows.filter(item => item.id !== id).map(item => item.channel),
  );
  let channel = nextInCycle(row.channel);
  for (let step = 0; step < CYCLE.length; step++) {
    if (!taken.has(channel)) {
      return channel;
    }
    channel = nextInCycle(channel);
  }
  return row.channel;
};

/** Переставляет фокус по стопке. Список закольцован. */
export const stepActive = (state: RowsState, delta: number): RowsState => {
  if (state.rows.length < 2) {
    return state;
  }
  const index = state.rows.findIndex(row => row.id === state.activeId);
  if (index < 0) {
    return withActive(state, state.rows, state.rows[0].id);
  }
  const length = state.rows.length;
  const next = state.rows[(index + delta + length) % length];
  return withActive(state, state.rows, next.id);
};
