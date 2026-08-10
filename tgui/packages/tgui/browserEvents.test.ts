import { BrowserEventDispatcher } from './browserEvents';

describe('BrowserEventDispatcher', () => {
  test('records and parses a live BYOND message exactly once', () => {
    const dispatch = jest.fn();
    const parse = jest.fn(raw => ({ type: 'update', payload: raw }));
    const record = jest.fn();
    const dispatcher = new BrowserEventDispatcher(dispatch, { parse, record });

    dispatcher.dispatchLive('live-message');

    expect(record).toHaveBeenCalledWith('live-message');
    expect(parse).toHaveBeenCalledWith('live-message');
    expect(dispatch).toHaveBeenCalledWith({
      type: 'update',
      payload: 'live-message',
    });
  });

  test('drains early messages in order without recording them twice', () => {
    const events = [];
    const record = jest.fn();
    const queue = ['first', 'second'];
    const dispatcher = new BrowserEventDispatcher(
      event => events.push(event),
      {
        parse: raw => ({ type: raw }),
        record,
      },
    );

    expect(dispatcher.drain(queue)).toBe(2);
    expect(events).toEqual([{ type: 'first' }, { type: 'second' }]);
    expect(queue).toEqual([]);
    expect(record).not.toHaveBeenCalled();
  });
});
