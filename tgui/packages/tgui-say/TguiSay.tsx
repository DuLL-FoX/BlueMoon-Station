import { type KeyboardEvent, useEffect, useRef, useState } from 'react';

import { type Channel, ChannelIterator } from './ChannelIterator';
import { ChatHistory } from './ChatHistory';
import { DraftStore } from './drafts';
import { windowClose, windowOpen } from './helpers';
import { dispatchMessage, sendMessage, subscribeTo } from './messages';

type OpenPayload = {
  channel: Channel;
};

type PropsPayload = {
  maxLength: number;
};

const KEY_ARROW_DOWN = 'ArrowDown';
const KEY_ARROW_UP = 'ArrowUp';
const KEY_ENTER = 'Enter';
const KEY_ESCAPE = 'Escape';
const KEY_TAB = 'Tab';

export const TguiSay = () => {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const iterator = useRef(new ChannelIterator());
  const history = useRef(new ChatHistory());
  const drafts = useRef(new DraftStore());
  const [channel, setChannel] = useState<Channel>('Say');
  const [maxLength, setMaxLength] = useState(4096);
  const [value, setValue] = useState('');

  /** Текущий текст поля. Читаем из DOM: состояние отстаёт на один кадр. */
  const currentValue = () => inputRef.current?.value || '';

  const close = (keepDraft = true) => {
    if (keepDraft) {
      // Escape не должен терять недописанное: черновик ждёт возвращения
      // в этот канал.
      drafts.current.save(iterator.current.current(), currentValue());
    }
    inputRef.current?.blur();
    windowClose();
    setValue('');
    history.current.reset();
    iterator.current.reset();
    setChannel(iterator.current.current());
    sendMessage('close');
  };

  const submit = () => {
    const entry = currentValue();
    const target = iterator.current.current();
    if (entry.length) {
      history.current.add(entry);
      sendMessage('entry', { channel: target, entry });
    }
    drafts.current.clear(target);
    close(false);
  };

  const switchChannel = () => {
    drafts.current.save(iterator.current.current(), currentValue());
    const next = iterator.current.next();
    setChannel(next);
    setValue(drafts.current.load(next));
    history.current.reset();
    sendMessage('channel', { channel: next });
  };

  const browseHistory = (direction: typeof KEY_ARROW_UP | typeof KEY_ARROW_DOWN) => {
    if (direction === KEY_ARROW_UP) {
      if (history.current.isAtLatest()) {
        history.current.saveTemp(currentValue());
      }
      const older = history.current.getOlderMessage();
      if (older !== null) {
        setValue(older);
      }
      return;
    }
    const newer = history.current.getNewerMessage();
    setValue(newer !== null ? newer : history.current.getTemp());
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    switch (event.key) {
      case KEY_ENTER:
        if (event.shiftKey) {
          return;
        }
        event.preventDefault();
        submit();
        return;
      case KEY_TAB:
        event.preventDefault();
        switchChannel();
        return;
      case KEY_ARROW_UP:
      case KEY_ARROW_DOWN:
        event.preventDefault();
        browseHistory(event.key);
        return;
      case KEY_ESCAPE:
        event.preventDefault();
        close();
    }
  };

  useEffect(() => {
    subscribeTo('props', (payload: PropsPayload) => {
      if (payload?.maxLength) {
        setMaxLength(payload.maxLength);
      }
    });
    subscribeTo('open', (payload: OpenPayload) => {
      iterator.current.set(payload?.channel || 'Say');
      const opened = iterator.current.current();
      setChannel(opened);
      setValue(drafts.current.load(opened));
      history.current.reset();
      windowOpen();
      // Фокус ставим после того, как окно стало видимым: BYOND не отдаёт
      // фокус скрытому элементу.
      setTimeout(() => inputRef.current?.focus(), 0);
      sendMessage('open', { channel: opened });
    });
    subscribeTo('close', () => close());
    // Сообщения, пришедшие до монтирования, лежат в очереди шима.
    window.update = dispatchMessage;
    while (true) {
      const queued = window.__updateQueue__?.shift();
      if (!queued) {
        break;
      }
      dispatchMessage(queued);
    }
    sendMessage('ready');
  }, []);

  return (
    <div className="TguiSay">
      <button
        className="TguiSay__channel"
        onClick={switchChannel}
        type="button">
        {channel}
      </button>
      <textarea
        className="TguiSay__input"
        maxLength={maxLength}
        onChange={event => setValue(event.currentTarget.value)}
        onKeyDown={handleKeyDown}
        ref={inputRef}
        spellCheck={false}
        value={value}
      />
    </div>
  );
};
