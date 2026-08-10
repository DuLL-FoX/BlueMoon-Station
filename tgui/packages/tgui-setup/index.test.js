/**
 * @jest-environment-options {"url": "http://localhost/?external"}
 */

import fs from 'fs';
import path from 'path';

const setupDocument = () => {
  document.head.innerHTML = '<meta id="tgui:windowId" content="test-window">';
  // injectNode inserts after the final child once body exists.
  document.body.innerHTML = '<div id="react-root"></div>';
};

describe('TGUI early setup', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.resetModules();
    setupDocument();
    require('./index');
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  test('retains the BlueMoon bridge diagnostics after extraction', () => {
    expect(window.__windowId__).toBe('test-window');
    expect(window.__tguiDebug__.version).toBe('bridge-localhost-fallback-v2');
    expect(window.__dispatchTguiSetupEvent__).toEqual(expect.any(Function));
    expect(window.__pushTguiDebugEvent__).toEqual(expect.any(Function));
    expect(window.__subscribeTguiSetupEvent__).toEqual(expect.any(Function));
    expect(Byond.loadJs).toEqual(expect.any(Function));
    expect(Byond.loadCss).toEqual(expect.any(Function));
  });

  test('routes ready, asset, incoming, and fatal diagnostics through one bus', () => {
    const events = [];
    const unsubscribe = window.__subscribeTguiSetupEvent__(event => events.push(event));

    // Retry invokes the real ready path after subscription.
    jest.advanceTimersByTime(2000);
    Byond.loadJs('https://cdn.example.test/event-bus.js', true);
    window.update('{"type":"update","payload":{}}');
    window.onerror('boom', 'event-bus.js', 12, 3, new Error('boom'));

    const kinds = events.map(event => event.kind);
    expect(kinds).toContain('sendReady');
    expect(kinds).toContain('asset/loadBegin');
    expect(kinds).toContain('incoming');
    expect(kinds).toContain('fatal');

    unsubscribe();
    const countAfterUnsubscribe = events.length;
    window.__pushTguiDebugEvent__('test/afterUnsubscribe');
    expect(events).toHaveLength(countAfterUnsubscribe);
  });

  test('loads JavaScript with an anonymous CORS request', () => {
    Byond.loadJs('https://cdn.example.test/tgui.js', true);

    const node = document.querySelector('script[src="https://cdn.example.test/tgui.js"]');
    expect(node).not.toBeNull();
    expect(node.crossOrigin).toBe('anonymous');
  });

  test('loads stylesheets with an anonymous CORS request', () => {
    Byond.loadCss('https://cdn.example.test/tgui.css', true);

    const node = document.querySelector('link[href="https://cdn.example.test/tgui.css"]');
    expect(node).not.toBeNull();
    expect(node.crossOrigin).toBe('anonymous');
  });

  test('increments failed asset attempts and stops at the retry limit', () => {
    const events = [];
    window.__subscribeTguiSetupEvent__(event => events.push(event));
    const url = 'https://cdn.example.test/retry.js';

    Byond.loadJs(url, true);
    for (let attempt = 0; attempt < 5; attempt++) {
      const node = document.querySelector(`script[src="${url}"]`);
      expect(node).not.toBeNull();
      node.onerror();
      jest.advanceTimersByTime(500 + attempt * 500);
    }

    const finalNode = document.querySelector(`script[src="${url}"]`);
    expect(finalNode).not.toBeNull();
    expect(() => finalNode.onerror()).toThrow(/after several attempts/);

    const attempts = events
      .filter(event => event.kind === 'asset/loadBegin')
      .map(event => event.payload.attempt);
    expect(attempts).toEqual([0, 1, 2, 3, 4, 5]);
    expect(events.some(event => event.kind === 'asset/retryGiveUp')).toBe(true);
  });

  test('reports a readable final stylesheet failure', () => {
    const url = 'https://cdn.example.test/retry.css';

    Byond.loadCss(url, true);
    for (let attempt = 0; attempt < 5; attempt++) {
      const node = document.querySelector(`link[href="${url}"]`);
      expect(node).not.toBeNull();
      node.onerror();
      jest.advanceTimersByTime(500 + attempt * 500);
    }

    const finalNode = document.querySelector(`link[href="${url}"]`);
    expect(finalNode).not.toBeNull();
    let finalError;
    try {
      finalNode.onerror();
    } catch (error) {
      finalError = error;
    }
    expect(finalError).toBeInstanceOf(Error);
    expect(finalError.message).toMatch(/Stylesheet was either not found/);
    expect(finalError.message).not.toMatch(/NaN/);
  });

  test('HTML remains a small template with a server-side setup marker', () => {
    const template = fs.readFileSync(
      path.resolve(__dirname, '../../public/tgui.html'),
      'utf8',
    );

    expect(template).toContain('<!-- tgui:setup -->');
    expect(template).not.toContain('bridge-localhost-fallback-v2');
    expect(template.split('\n').length).toBeLessThan(250);
  });
});
