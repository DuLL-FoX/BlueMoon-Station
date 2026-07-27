import { type KeyboardEvent, useEffect, useRef, useState } from 'react';

import { windowClose, windowOpen } from './helpers';
import { dispatchMessage, sendMessage, subscribeTo } from './messages';

type OpenPayload = {
  channel: string;
};

type PropsPayload = {
  maxLength: number;
};

const KEY_ENTER = 'Enter';
const KEY_ESCAPE = 'Escape';

export const TguiSay = () => {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const channelRef = useRef('Say');
  const [channel, setChannel] = useState('Say');
  const [maxLength, setMaxLength] = useState(4096);
  const [value, setValue] = useState('');

  const close = () => {
    inputRef.current?.blur();
    windowClose();
    setValue('');
    sendMessage('close');
  };

  const submit = () => {
    const entry = inputRef.current?.value || '';
    if (entry.length) {
      sendMessage('entry', { channel: channelRef.current, entry });
    }
    close();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === KEY_ENTER && !event.shiftKey) {
      event.preventDefault();
      submit();
      return;
    }
    if (event.key === KEY_ESCAPE) {
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
      const nextChannel = payload?.channel || 'Say';
      channelRef.current = nextChannel;
      setChannel(nextChannel);
      windowOpen();
      // Фокус ставим после того, как окно стало видимым: BYOND не отдаёт
      // фокус скрытому элементу.
      setTimeout(() => inputRef.current?.focus(), 0);
      sendMessage('open', { channel: nextChannel });
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
      <button className="TguiSay__channel" type="button">
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
