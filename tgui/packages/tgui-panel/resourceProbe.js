/**
 * @file
 *
 * Клиентская проба внешней раздачи ресурсов.
 *
 * Сервер назначает клиенту preload_rsc = <адрес архива> и дальше слеп: BYOND не
 * сообщает, доехал ли архив. Клиент, до которого внешний адрес не дошёл
 * (провайдер, прокси, блокировка), молча падает на подкачку по игровому сокету, и
 * в логах это неотличимо от обычного лага. Серверная проба CDN такой случай не
 * видит в принципе - раздача жива, недоступна она ровно одному игроку.
 *
 * Спросить может только этот WebView: он ходит в сеть своим стеком, через те же
 * DNS и прокси, что и DreamSeeker. Запросов на цель максимум два, повторов в цикле
 * нет: проба не должна становиться собственным источником трафика.
 */

import { sendMessage } from 'tgui/backend';
import { createLogger } from 'tgui/logging';

const logger = createLogger('resourceProbe');

/** Резервный таймаут: обычно приезжает с сервера, но отчёт не должен зависеть
 * от того, что сервер его прислал. Совпадает с CLIENT_DELIVERY_PROBE_REQUEST_TIMEOUT. */
export const PROBE_FALLBACK_TIMEOUT_MS = 15000;
/** Больше целей сервер не выдаёт; лишние отбрасываем, не отправляя запросов. */
export const PROBE_MAX_TARGETS = 4;

/** Состояния отчёта. Совпадают с CLIENT_DELIVERY_PROBE_* на стороне DM. */
export const PROBE_OK = 'ok';
export const PROBE_HTTP_ERROR = 'http_error';
export const PROBE_BLOCKED = 'blocked';
export const PROBE_TIMEOUT = 'timeout';

/** 2xx и 3xx - файл на месте либо переехал, и то и другое означает «доехали». */
const HTTP_OK_MIN = 200;
const HTTP_OK_MAX = 400;
/** Хост отказал САМОМУ МЕТОДУ, а не адресу: nginx с limit_except, часть прокси. */
const HTTP_METHOD_NOT_ALLOWED = 405;
const HTTP_NOT_IMPLEMENTED = 501;
/** Однобайтовый GET вместо HEAD: тянуть многомегабайтный архив ради проверки
 * живости адреса дороже самой проблемы. */
const RANGE_FIRST_BYTE = 'bytes=0-0';
/** Дальше в тексте ошибки начинается стектрейс, которому в логе места нет. */
const DETAIL_MAX_LENGTH = 96;

const shortenDetail = text => String(text || '').slice(0, DETAIL_MAX_LENGTH);

/**
 * Один запрос с жёстким таймаутом. Никогда не бросает: вызывающему нужен
 * результат обеих веток, а не try/catch на каждом шаге.
 */
const requestOnce = async (url, init, timeoutMs) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'follow',
      ...init,
      signal: controller.signal,
    });
    return { response };
  }
  catch (error) {
    return { error };
  }
  finally {
    clearTimeout(timer);
  }
};

const classifyStatus = httpStatus => ({
  status: httpStatus >= HTTP_OK_MIN && httpStatus < HTTP_OK_MAX
    ? PROBE_OK
    : PROBE_HTTP_ERROR,
  httpStatus,
});

/**
 * Прерванный по таймауту запрос и запрос, который сеть не пустила, - разные
 * диагнозы: первый означает медленную раздачу, второй - что до неё не дошли вовсе.
 */
const describeFailure = error => (
  error && error.name === 'AbortError'
    ? { status: PROBE_TIMEOUT, detail: 'timeout' }
    : {
      status: PROBE_BLOCKED,
      detail: shortenDetail(error?.message || 'network error'),
    }
);

/**
 * Проверяет один адрес и возвращает готовую к отправке запись отчёта.
 *
 * now подменяется в тестах: Date.now в них заморожен, а длительность - часть
 * отчёта, ради которой проба и заводилась.
 */
export const probeTarget = async (url, timeoutMs, now = Date.now) => {
  const startedAt = now();
  const finish = result => ({
    httpStatus: 0,
    detail: '',
    opaque: 0,
    ...result,
    durationMs: Math.max(now() - startedAt, 0),
  });

  const head = await requestOnce(url, { method: 'HEAD' }, timeoutMs);
  if (head.response) {
    const httpStatus = head.response.status;
    if (httpStatus !== HTTP_METHOD_NOT_ALLOWED
        && httpStatus !== HTTP_NOT_IMPLEMENTED) {
      return finish(classifyStatus(httpStatus));
    }
    const ranged = await requestOnce(url, {
      method: 'GET',
      headers: { Range: RANGE_FIRST_BYTE },
    }, timeoutMs);
    if (ranged.response) {
      return finish(classifyStatus(ranged.response.status));
    }
    // HEAD доехал, а GET нет. Про сеть мы уже всё узнали - она есть; сказать про
    // файл нечего, и честный ответ здесь - тот самый отказ методу.
    return finish({
      status: PROBE_HTTP_ERROR,
      httpStatus,
      detail: shortenDetail(ranged.error?.message || 'range request failed'),
    });
  }

  // fetch отверг сам запрос. Заблокированная сеть и отсутствие CORS дают
  // одинаковый TypeError без статуса, а это противоположные диагнозы: во втором
  // случае у игрока всё в порядке. Непрозрачный запрос идёт мимо CORS и
  // отвечает ровно на нужный вопрос - доехали мы до хоста или нет.
  const opaque = await requestOnce(
    url,
    { method: 'HEAD', mode: 'no-cors' },
    timeoutMs);
  if (opaque.response) {
    return finish({ status: PROBE_OK, opaque: 1, detail: 'no-cors' });
  }
  return finish(describeFailure(head.error));
};

/**
 * Обходит цели по очереди и отправляет один отчёт на все.
 * Последовательно, а не параллельно: одновременные запросы к одному хосту меряли
 * бы уже собственную очередь, а не доступность адреса.
 */
export const runResourceProbe = async (payload, probe = probeTarget) => {
  const targets = (payload?.targets || []).slice(0, PROBE_MAX_TARGETS);
  const timeoutMs = payload?.timeoutMs > 0
    ? payload.timeoutMs
    : PROBE_FALLBACK_TIMEOUT_MS;
  const results = [];
  for (const target of targets) {
    if (!target?.url || !target?.key) {
      continue;
    }
    const result = await probe(target.url, timeoutMs);
    results.push({ target: target.key, ...result });
  }
  if (results.length === 0) {
    return results;
  }
  logger.debug('external delivery probe', results);
  sendMessage({
    type: 'resourceProbe',
    payload: {
      generation: payload?.generation,
      results,
    },
  });
  return results;
};

export const resourceProbeMiddleware = () => {
  let probed = false;
  return next => action => {
    if (action.type !== 'resourceProbe/request') {
      return next(action);
    }
    // Сервер просит пробу один раз за подключение. Повтор означает переоткрытую
    // панель, а не новый вопрос, и гонять сеть заново незачем.
    if (!probed) {
      probed = true;
      runResourceProbe(action.payload);
    }
    return undefined;
  };
};
