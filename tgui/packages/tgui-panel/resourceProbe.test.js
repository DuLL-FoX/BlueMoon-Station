import { sendMessage } from 'tgui/backend';

import {
  PROBE_BLOCKED,
  PROBE_HTTP_ERROR,
  PROBE_OK,
  PROBE_TIMEOUT,
  probeTarget,
  resourceProbeMiddleware,
  runResourceProbe,
} from './resourceProbe';

jest.mock('tgui/backend', () => ({
  sendMessage: jest.fn(),
}));

const RSC_URL = 'https://cdn.example.test/byond_rsc/archive.zip';
const ASSET_URL = 'https://cdn.example.test/browser-assets/statbrowser.html';

const abortError = () => {
  const error = new Error('The operation was aborted');
  error.name = 'AbortError';
  return error;
};

describe('external delivery probe', () => {
  let clock;

  beforeEach(() => {
    clock = 1000;
    global.fetch = jest.fn();
  });

  const now = () => clock;

  test('a plain HEAD answer settles the target in one request', async () => {
    global.fetch.mockImplementation(() => {
      clock += 42;
      return Promise.resolve({ status: 200 });
    });

    const result = await probeTarget(RSC_URL, 15000, now);

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch.mock.calls[0][1]).toMatchObject({
      method: 'HEAD',
      cache: 'no-store',
    });
    expect(result).toMatchObject({
      status: PROBE_OK,
      httpStatus: 200,
      durationMs: 42,
    });
  });

  test('a host which refuses HEAD is retried with a one byte range', async () => {
    global.fetch
      .mockResolvedValueOnce({ status: 405 })
      .mockResolvedValueOnce({ status: 206 });

    const result = await probeTarget(RSC_URL, 15000, now);

    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(global.fetch.mock.calls[1][1]).toMatchObject({
      method: 'GET',
      headers: { Range: 'bytes=0-0' },
    });
    expect(result.status).toBe(PROBE_OK);
    expect(result.httpStatus).toBe(206);
  });

  test('a bad status keeps the host reachable but the file degraded', async () => {
    global.fetch.mockResolvedValue({ status: 404 });

    const result = await probeTarget(RSC_URL, 15000, now);

    expect(result.status).toBe(PROBE_HTTP_ERROR);
    expect(result.httpStatus).toBe(404);
  });

  test('a CORS rejection is proven harmless by an opaque request', async () => {
    global.fetch
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce({ status: 0, type: 'opaque' });

    const result = await probeTarget(RSC_URL, 15000, now);

    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(global.fetch.mock.calls[1][1]).toMatchObject({ mode: 'no-cors' });
    expect(result.status).toBe(PROBE_OK);
    expect(result.opaque).toBe(1);
  });

  test('a target unreachable even without CORS is reported as blocked', async () => {
    global.fetch.mockRejectedValue(new TypeError('Failed to fetch'));

    const result = await probeTarget(RSC_URL, 15000, now);

    expect(result.status).toBe(PROBE_BLOCKED);
    expect(result.detail).toBe('Failed to fetch');
  });

  test('an aborted request is a timeout, not a block', async () => {
    global.fetch.mockRejectedValue(abortError());

    const result = await probeTarget(RSC_URL, 15000, now);

    expect(result.status).toBe(PROBE_TIMEOUT);
  });

  test('the report carries every target and the server generation back', async () => {
    const probe = jest.fn()
      .mockResolvedValueOnce({ status: PROBE_OK, httpStatus: 200 })
      .mockResolvedValueOnce({ status: PROBE_BLOCKED, httpStatus: 0 });

    await runResourceProbe({
      generation: 7,
      timeoutMs: 15000,
      targets: [
        { key: 'rsc', url: RSC_URL },
        { key: 'assets', url: ASSET_URL },
      ],
    }, probe);

    expect(sendMessage).toHaveBeenCalledWith({
      type: 'resourceProbe',
      payload: {
        generation: 7,
        results: [
          { target: 'rsc', status: PROBE_OK, httpStatus: 200 },
          { target: 'assets', status: PROBE_BLOCKED, httpStatus: 0 },
        ],
      },
    });
  });

  test('a request without usable targets sends nothing at all', async () => {
    const probe = jest.fn();

    await runResourceProbe({
      generation: 7,
      targets: [{ key: 'rsc' }],
    }, probe);

    expect(probe).not.toHaveBeenCalled();
    expect(sendMessage).not.toHaveBeenCalled();
  });

  test('the middleware probes once and passes other actions through', async () => {
    global.fetch.mockResolvedValue({ status: 200 });
    const next = jest.fn(action => action);
    const invoke = resourceProbeMiddleware()(next);
    const request = {
      type: 'resourceProbe/request',
      payload: { targets: [{ key: 'rsc', url: RSC_URL }] },
    };

    invoke(request);
    invoke(request);
    invoke({ type: 'ping', payload: {} });
    await Promise.resolve();

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(next).toHaveBeenCalledTimes(1);
    expect(next).toHaveBeenCalledWith({ type: 'ping', payload: {} });
  });
});
