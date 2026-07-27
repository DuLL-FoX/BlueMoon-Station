import { useEffect, useRef, useState } from 'react';

import { dispatchMessage, sendMessage, subscribeTo } from './messages';

type OpenPayload = {
  channel: string;
};

type PropsPayload = {
  maxLength: number;
};

export const TguiSay = () => {
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const [channel, setChannel] = useState('Say');
  const [maxLength, setMaxLength] = useState(4096);
  const [value, setValue] = useState('');

  useEffect(() => {
    subscribeTo('props', (payload: PropsPayload) => {
      if (payload?.maxLength) {
        setMaxLength(payload.maxLength);
      }
    });
    subscribeTo('open', (payload: OpenPayload) => {
      setChannel(payload?.channel || 'Say');
      inputRef.current?.focus();
    });
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
        ref={inputRef}
        spellCheck={false}
        value={value}
      />
    </div>
  );
};
