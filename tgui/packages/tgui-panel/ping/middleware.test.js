import { sendMessage } from 'tgui/backend';

import { pingMiddleware } from './middleware';

jest.mock('tgui/backend', () => ({
  sendMessage: jest.fn(),
}));

describe('tgui panel ping diagnostics', () => {
  let dateNowSpy;
  let next;
  let store;

  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
    dateNowSpy = jest.spyOn(Date, 'now').mockReturnValue(100000);
    next = jest.fn(action => action);
    store = { dispatch: jest.fn() };
  });

  afterEach(() => {
    dateNowSpy.mockRestore();
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  test('reports the full browser-to-DM round trip when a reply is slow', () => {
    const invoke = pingMiddleware(store)(next);
    invoke({ type: 'init' });
    expect(sendMessage).toHaveBeenCalledWith({
      type: 'ping',
      payload: { index: 0 },
    });

    dateNowSpy.mockReturnValue(100180);
    invoke({ type: 'pingReply', payload: { index: 0 } });

    expect(sendMessage).toHaveBeenCalledWith({
      type: 'pingDiagnostic',
      payload: expect.objectContaining({ latencyMs: 180 }),
    });
  });

  test('does not report healthy round trips', () => {
    const invoke = pingMiddleware(store)(next);
    invoke({ type: 'init' });
    dateNowSpy.mockReturnValue(100050);
    invoke({ type: 'pingReply', payload: { index: 0 } });

    expect(sendMessage).not.toHaveBeenCalledWith(expect.objectContaining({
      type: 'pingDiagnostic',
    }));
  });

  test('reports a ping which expires before its reply can be processed', () => {
    const invoke = pingMiddleware(store)(next);
    invoke({ type: 'init' });
    dateNowSpy.mockReturnValue(102501);
    jest.advanceTimersByTime(2500);

    expect(sendMessage).toHaveBeenCalledWith({
      type: 'pingDiagnostic',
      payload: expect.objectContaining({ latencyMs: 2501 }),
    });
    expect(store.dispatch).toHaveBeenCalled();
  });
});
