/**
 * @file
 * @copyright 2020 Aleksej Komarov
 * @license MIT
 */

import { sendMessage } from 'tgui/backend';

import { pingFail, pingSuccess } from './actions';
import {
  PING_DIAGNOSTIC_COOLDOWN,
  PING_DIAGNOSTIC_THRESHOLD,
  PING_INTERVAL,
  PING_QUEUE_SIZE,
  PING_TIMEOUT,
} from './constants';

export const pingMiddleware = store => {
  let initialized = false;
  let index = 0;
  let interval;
  let lastDiagnosticAt = -PING_DIAGNOSTIC_COOLDOWN;
  const pings = [];
  const reportLatency = latencyMs => {
    const now = Date.now();
    if (latencyMs < PING_DIAGNOSTIC_THRESHOLD
        || now - lastDiagnosticAt < PING_DIAGNOSTIC_COOLDOWN) {
      return;
    }
    lastDiagnosticAt = now;
    sendMessage({
      type: 'pingDiagnostic',
      payload: {
        latencyMs,
        hidden: document.hidden ? 1 : 0,
        focused: document.hasFocus?.() ? 1 : 0,
      },
    });
  };
  const sendPing = () => {
    for (let i = 0; i < PING_QUEUE_SIZE; i++) {
      const ping = pings[i];
      if (ping && Date.now() - ping.sentAt > PING_TIMEOUT) {
        reportLatency(Date.now() - ping.sentAt);
        pings[i] = null;
        store.dispatch(pingFail());
      }
    }
    const ping = { index, sentAt: Date.now() };
    pings[index] = ping;
    sendMessage({
      type: 'ping',
      payload: { index },
    });
    index = (index + 1) % PING_QUEUE_SIZE;
  };
  return next => action => {
    const { type, payload } = action;
    if (!initialized) {
      initialized = true;
      interval = setInterval(sendPing, PING_INTERVAL);
      sendPing();
    }
    if (type === 'roundrestart') {
      // Stop pinging because dreamseeker is currently reconnecting.
      // Topic calls in the middle of reconnect will crash the connection.
      clearInterval(interval);
      return next(action);
    }
    if (type === 'pingReply') {
      const { index } = payload;
      const ping = pings[index];
      // Received a timed out ping
      if (!ping) {
        return;
      }
      pings[index] = null;
      const now = Date.now();
      const latencyMs = now - ping.sentAt;
      reportLatency(latencyMs);
      return next(pingSuccess(ping));
    }
    return next(action);
  };
};
