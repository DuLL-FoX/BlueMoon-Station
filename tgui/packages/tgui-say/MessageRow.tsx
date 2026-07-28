/**
 * @file
 * Одна набираемая строка: плашка канала, поле и счётчик.
 *
 * Поле растёт под текст, но не бесконечно: панель стоит над картой и не имеет
 * права закрыть собой полстанции. За пределом строк текст прокручивается.
 */

import { type KeyboardEvent, useLayoutEffect, useRef } from 'react';

import { hintFor, labelFor, themeFor } from './channels';
import { COUNTER_THRESHOLD, MAX_INPUT_LINES, SLOW_TRANSPORT_BYTES } from './constants';
import type { Row } from './rows';
import { encodedLength, getEmoteSuggestions, splitCustomSay } from './suggestions';

type Props = {
  row: Row;
  active: boolean;
  maxLength: number;
  emotes: string[];
  onActivate: () => void;
  onChange: (value: string) => void;
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  onCycleChannel: () => void;
  onClose: () => void;
  onPick: (emote: string) => void;
  registerInput: (element: HTMLTextAreaElement | null) => void;
};

const DEFAULT_LINE_HEIGHT = 18;

export const MessageRow = (props: Props) => {
  const {
    row, active, maxLength, emotes,
    onActivate, onChange, onKeyDown, onCycleChannel, onClose, onPick, registerInput,
  } = props;
  const inputRef = useRef<HTMLTextAreaElement | null>(null);

  // Высота поля считается по содержимому: textarea сама этого не умеет, а
  // фиксированная высота либо режет текст, либо оставляет пустоту.
  useLayoutEffect(() => {
    const element = inputRef.current;
    if (!element) {
      return;
    }
    const lineHeight
      = parseFloat(getComputedStyle(element).lineHeight) || DEFAULT_LINE_HEIGHT;
    const limit = lineHeight * (active ? MAX_INPUT_LINES : 1);
    element.style.height = 'auto';
    const wanted = Math.max(lineHeight, Math.min(element.scrollHeight, limit));
    element.style.height = `${wanted}px`;
    // Полоса прокрутки нужна только активной строке: у сжатой она занимает
    // больше места, чем сам текст.
    element.style.overflowY
      = active && element.scrollHeight > limit ? 'auto' : 'hidden';
  }, [row.value, active]);

  const theme = themeFor(row.channel, row.prefix?.token);
  const label = labelFor(row.channel, row.prefix?.label);
  const hint = row.prefix ? 'рация' : hintFor(row.channel);
  const suggestions = active ? getEmoteSuggestions(row.value, emotes) : [];
  const customSay = active ? splitCustomSay(row.value) : null;
  const bytes = encodedLength(row.value);
  const slow = bytes > SLOW_TRANSPORT_BYTES;

  return (
    <div
      className={`Say__row Say__row--${theme}${active ? ' Say__row--active' : ''}`}>
      {!!suggestions.length && (
        <div className="Say__hints">
          {suggestions.map(emote => (
            <button
              className="Say__hint"
              key={emote}
              onClick={() => onPick(emote)}
              type="button">
              {emote}
            </button>
          ))}
        </div>
      )}
      {!!customSay && (
        <div className="Say__hints">
          <span className="Say__syntax">
            {customSay.verb}, «{customSay.message}»
          </span>
        </div>
      )}
      <div className="Say__line">
        <button
          className="Say__channel"
          onClick={onCycleChannel}
          title="Сменить канал (Tab)"
          type="button">
          <span className="Say__channelLabel">{label}</span>
          {!!hint && <span className="Say__channelHint">{hint}</span>}
        </button>
        <textarea
          className="Say__input"
          maxLength={maxLength}
          onChange={event => onChange(event.currentTarget.value)}
          onFocus={onActivate}
          onKeyDown={onKeyDown}
          ref={element => {
            inputRef.current = element;
            registerInput(element);
          }}
          rows={1}
          spellCheck={false}
          value={row.value}
        />
        {row.value.length >= COUNTER_THRESHOLD && (
          <span
            className={`Say__counter${slow ? ' Say__counter--slow' : ''}`}
            title={
              slow
                ? 'Сообщение длиннее того, что влезает в один запрос к клиенту: '
                  + 'уходит запасным путём. Если не отправится — разбей на части'
                : undefined
            }>
            {row.value.length}
          </span>
        )}
        <button
          className="Say__close"
          onClick={onClose}
          title="Убрать строку (Shift+Esc)"
          type="button">
          ×
        </button>
      </div>
    </div>
  );
};
