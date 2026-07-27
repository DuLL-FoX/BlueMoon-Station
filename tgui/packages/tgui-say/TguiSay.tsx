import { type KeyboardEvent, useEffect, useRef, useState } from 'react';

import { type Channel, ChannelIterator } from './ChannelIterator';
import { windowClose, windowOpen } from './helpers';
import { dispatchMessage, sendMessage, subscribeTo } from './messages';

type OpenPayload = {
  channel: Channel;
};

type PropsPayload = {
  maxLength: number;
};

const KEY_ENTER = 'Enter';
const KEY_ESCAPE = 'Escape';
const KEY_TAB = 'Tab';

export const TguiSay = () => {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const iterator = useRef(new ChannelIterator());
  const [channel, setChannel] = useState<Channel>('Say');
  const [maxLength, setMaxLength] = useState(4096);
  const [value, setValue] = useState('');

  const close = () => {
    inputRef.current?.blur();
    windowClose();
    setValue('');
    iterator.current.reset();
    setChannel(iterator.current.current());
    sendMessage('close');
  };

  const submit = () => {
    const entry = inputRef.current?.value || '';
    if (entry.length) {
      sendMessage('entry', { channel: iterator.current.current(), entry });
    }
    close();
  };

  const switchChannel = () => {
    const next = iterator.current.next();
    setChannel(next);
    sendMessage('channel', { channel: next });
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
