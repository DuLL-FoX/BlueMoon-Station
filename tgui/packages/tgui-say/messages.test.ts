import {
  dispatchMessage,
  resetSubscribers,
  sendMessage,
  subscribeTo,
} from './messages';

describe('обмен сообщениями окна ввода', () => {
  beforeEach(() => {
    resetSubscribers();
  });

  it('разбирает сырую команду открытия, пришедшую от клиента без сервера', () => {
    const seen: any[] = [];
    subscribeTo('open', payload => seen.push(payload));

    dispatchMessage('open:Say');

    expect(seen).toEqual([{ channel: 'Say' }]);
  });

  it('разбирает обычное JSON-сообщение из DM', () => {
    const seen: any[] = [];
    subscribeTo('props', payload => seen.push(payload));

    dispatchMessage(JSON.stringify({ type: 'props', payload: { maxLength: 4096 } }));

    expect(seen).toEqual([{ maxLength: 4096 }]);
  });

  it('не роняет окно на мусоре вместо сообщения', () => {
    const seen: any[] = [];
    subscribeTo('open', payload => seen.push(payload));

    expect(() => dispatchMessage('}{не json')).not.toThrow();
    expect(seen).toEqual([]);
  });

  it('не доставляет сообщение чужим подписчикам', () => {
    const openSeen: any[] = [];
    const closeSeen: any[] = [];
    subscribeTo('open', payload => openSeen.push(payload));
    subscribeTo('close', payload => closeSeen.push(payload));

    dispatchMessage('open:Me');

    expect(openSeen).toEqual([{ channel: 'Me' }]);
    expect(closeSeen).toEqual([]);
  });

  it('отправляет сообщение в DM с идентификатором окна и JSON-нагрузкой', () => {
    const topic = jest.fn();
    (global as any).Byond = { topic };
    (window as any).__windowId__ = 'tgui_say';

    sendMessage('entry', { channel: 'Say', entry: 'привет' });

    expect(topic).toHaveBeenCalledWith({
      tgui: 1,
      window_id: 'tgui_say',
      type: 'entry',
      payload: JSON.stringify({ channel: 'Say', entry: 'привет' }),
    });
  });
});
