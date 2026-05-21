import { BooleanLike } from 'common/react';

import { useBackend, useLocalState } from '../backend';
import {
  Box,
  Button,
  Collapsible,
  Dropdown,
  LabeledList,
  NoticeBox,
  ProgressBar,
  Section,
  Stack,
  Table } from '../components';
import { Window } from '../layouts';
import {
  SPIKE_MIN_MS,
  Stability,
  summarizeHistory,
  Trend,
} from './pingHistory';

type PingVerdict = 'healthy' | 'server' | 'network' | 'jitter' | 'client';

type SubsystemCost = {
  name: string;
  cost: number;
  tick_usage: number;
};

type PingClient = {
  key: string;
  ckey: string;
  ping: number;
};

type PingPlayer = {
  key: string;
  ping: number;
};

type PingDiagnosticsData = {
  is_admin: BooleanLike;
  verdict: PingVerdict;
  target_key?: string;
  rtt: number;
  server: number;
  jitter: number;
  tick: number;
  floor: number;
  total: number;
  client_fps: number;
  history: number[][];
  tidi: number;
  rtt_max: number;
  spike: number;
  ss_costs?: SubsystemCost[];
  ss_count?: number;
  maptick?: number;
  clients?: PingClient[];
  own_key?: string;
  all_pings?: PingPlayer[];
};

// Subsystem tick_usage bands, tuned to this server's baseline where some systems
// routinely run 2-3 ticks (200-300%). Only usage clearly past that baseline is alarming.
const SS_TICK_WARN = 100; // overran a single tick
const SS_TICK_CRIT = 300; // beyond the usual 2-3 tick baseline
const SS_TICK_COLOR = (usage) =>
  usage >= SS_TICK_CRIT ? 'bad' : usage >= SS_TICK_WARN ? 'average' : 'label';

// Ping bands (ms) for the server-wide player table. Loose thresholds: under WARN feels fine,
// past CRIT is clearly laggy.
const PING_WARN_MS = 80;
const PING_CRIT_MS = 150;
const PING_COLOR = (ping) =>
  ping >= PING_CRIT_MS ? 'bad' : ping >= PING_WARN_MS ? 'average' : 'label';

const VERDICTS = {
  healthy: {
    color: 'good',
    title: 'Норма',
    text: (d: PingDiagnosticsData) =>
      `~${d.total}ms - это в основном структурный потолок тика (${d.floor}ms). Проблемы нет.`,
  },
  server: {
    color: 'bad',
    title: 'Нагружен сервер',
    text: (d: PingDiagnosticsData) =>
      d.tidi >= 10
        ? `Сервер не успевает за реальным временем (дилатация ${d.tidi}%). Тик перегружен - смотри таблицу подсистем ниже.`
        : `Серверная задержка ${d.server}ms (потолок ~${d.floor}ms). Смотри таблицу подсистем ниже.`,
  },
  network: {
    color: 'average',
    title: 'Сетевая задержка',
    text: (d: PingDiagnosticsData) =>
      `Большая часть пинга (${d.rtt}ms) - это сеть до сервера, а не его нагрузка.`,
  },
  jitter: {
    color: 'average',
    title: 'Нестабильность',
    text: (d: PingDiagnosticsData) =>
      d.spike >= SPIKE_MIN_MS
        ? `Пинг скачет: пик ${d.rtt_max}ms против среднего ${d.rtt}ms (скачок +${d.spike}ms). Кратковременная просадка тика, не видна по средней дилатации.`
        : `Пинг скачет (джиттер ${d.jitter}ms). Соединение или сервер нестабильны, даже если среднее в норме.`,
  },
  client: {
    color: 'average',
    title: 'Низкий FPS клиента',
    text: (d: PingDiagnosticsData) =>
      `FPS вашего клиента (${d.client_fps}) низкий и раздувает отклик. Поднимите лимит FPS.`,
  },
};

const SPARK_HEIGHT_PX = 40;
const SPARK_BAR_COLOR = '#5b8dd9';

const SparkLine = (props) => {
  const { history } = props;
  if (!history || !history.length) {
    return <Box color="label">нет данных</Box>;
  }
  // history entries are [rtt, server, jitter]; chart total = rtt + server.
  const totals = history.map((h) => h[0] + h[1]);
  const max = Math.max(...totals, 1);
  return (
    <Stack align="flex-end" height={SPARK_HEIGHT_PX + 'px'}>
      {totals.map((value, index) => (
        <Stack.Item key={index} grow>
          <Box
            backgroundColor={SPARK_BAR_COLOR}
            width="100%"
            height={Math.max((value / max) * SPARK_HEIGHT_PX, 1) + 'px'}
          />
        </Stack.Item>
      ))}
    </Stack>
  );
};

const TREND_LABEL: Record<Trend, string> = {
  rising: 'растёт',
  falling: 'падает',
  stable: 'стабилен',
};

const STABILITY_LABEL: Record<Stability, string> = {
  stable: 'стабильно',
  moderate: 'умеренно',
  rough: 'скачет',
};

const HistorySummary = (props) => {
  const { history, floor } = props;
  const summary = summarizeHistory(history, floor);
  if (!summary) {
    return <Box color="label">нет данных</Box>;
  }
  // summary.dominant is a SampleVerdict ('client' is never produced), so the VERDICTS title
  // lookup is always defined.
  const dominantTitle = VERDICTS[summary.dominant].title;
  return (
    <LabeledList>
      <LabeledList.Item label="Чаще всего">
        {dominantTitle} ({summary.dominantCount} из {summary.count})
      </LabeledList.Item>
      <LabeledList.Item label="Тренд">
        {TREND_LABEL[summary.trend]}
      </LabeledList.Item>
      <LabeledList.Item label="Скачки">
        {summary.spikeCount === 0
          ? 'нет'
          : `${summary.spikeCount} из ${summary.count} (макс +${summary.spikeMax}ms)`}
      </LabeledList.Item>
      <LabeledList.Item label="Разброс пинга">
        {summary.min}-{summary.max}ms, среднее {summary.avg}ms
      </LabeledList.Item>
      <LabeledList.Item label="Стабильность">
        {STABILITY_LABEL[summary.stability]}
      </LabeledList.Item>
    </LabeledList>
  );
};

const SubsystemTable = (props) => {
  const { data } = props;
  const { ss_costs = [], ss_count = 6 } = data;
  const top = [...ss_costs]
    .sort((a, b) => b.tick_usage - a.tick_usage)
    .slice(0, ss_count);
  return (
    <Section title="Что ест тик (топ подсистем)">
      <Box mb={1} color="label">
        Дилатация времени: {data.tidi}% | Maptick: {data.maptick}%
      </Box>
      <Table>
        <Table.Row header>
          <Table.Cell>Подсистема</Table.Cell>
          <Table.Cell collapsing textAlign="right">tick %</Table.Cell>
          <Table.Cell collapsing textAlign="right">cost ms</Table.Cell>
        </Table.Row>
        {top.map((ss) => (
          <Table.Row key={ss.name}>
            <Table.Cell>{ss.name}</Table.Cell>
            <Table.Cell
              collapsing
              textAlign="right"
              color={SS_TICK_COLOR(ss.tick_usage)}>
              {ss.tick_usage}
            </Table.Cell>
            <Table.Cell collapsing textAlign="right">{ss.cost}</Table.Cell>
          </Table.Row>
        ))}
      </Table>
    </Section>
  );
};

const ServerPingTable = (props) => {
  const { all_pings = [], own_key } = props;
  if (!all_pings.length) {
    return <Box color="label">нет данных</Box>;
  }
  // Worst ping first, so laggy players are easy to spot at the top.
  const sorted = [...all_pings].sort((a, b) => b.ping - a.ping);
  return (
    <Table>
      <Table.Row header>
        <Table.Cell>Игрок</Table.Cell>
        <Table.Cell collapsing textAlign="right">пинг</Table.Cell>
      </Table.Row>
      {sorted.map((player) => {
        const isSelf = player.key === own_key;
        return (
          <Table.Row key={player.key}>
            <Table.Cell color={isSelf ? 'good' : undefined}>
              {player.key}{isSelf ? ' (вы)' : ''}
            </Table.Cell>
            <Table.Cell
              collapsing
              textAlign="right"
              color={PING_COLOR(player.ping)}>
              {player.ping} ms
            </Table.Cell>
          </Table.Row>
        );
      })}
    </Table>
  );
};

const ClientPicker = (props, context) => {
  const { act, data } = useBackend<PingDiagnosticsData>(context);
  const { clients = [], target_key } = data;
  const label = (c) => `${c.key} (${c.ping}ms)`;
  const options = clients.map(label);
  // Match the formatted option string so the picked client stays highlighted
  // across autoupdate refreshes (target_key alone is the bare key, never an option).
  const picked = clients.find((c) => c.key === target_key);
  const selectedLabel = picked ? label(picked) : undefined;
  return (
    <Section title="Цель (админ)">
      <Stack>
        <Stack.Item grow>
          <Dropdown
            width="100%"
            displayText={selectedLabel || target_key}
            options={options}
            onSelected={(value) => {
              const picked = clients.find(
                (c) => `${c.key} (${c.ping}ms)` === value
              );
              if (picked) {
                act('select_target', { ckey: picked.ckey });
              }
            }}
          />
        </Stack.Item>
        <Stack.Item>
          <Button icon="user" onClick={() => act('reset_target')}>
            Я сам
          </Button>
        </Stack.Item>
      </Stack>
    </Section>
  );
};

const VERDICT_REFERENCE = [
  {
    title: 'Норма',
    text: 'Почти весь пинг - это обычная задержка игры, всё в порядке. Пример: всего около 30 мс, для сервера это нормально.',
  },
  {
    title: 'Нагружен сервер',
    text: 'Серверу тяжело, он не успевает всё просчитывать, поэтому отклик растёт сразу у всех. Обычно проходит само. Пример: на станции много взрывов, реакций или мобов.',
  },
  {
    title: 'Сетевая задержка',
    text: 'Сигнал долго идёт между вами и сервером - дело в интернете, а не в сервере. Пример: вы далеко от сервера или нестабильный Wi-Fi.',
  },
  {
    title: 'Нестабильность',
    text: 'Пинг прыгает: то нормально, то резко подскакивает (джиттер). Пример: короткие подвисания каждые несколько секунд.',
  },
  {
    title: 'Низкий FPS клиента',
    text: 'У вашего клиента игры мало кадров (FPS), из-за этого отклик кажется больше. Поднимите лимит FPS в настройках BYOND.',
  },
];

const METRIC_REFERENCE = [
  {
    label: 'Всего',
    text: 'Общий пинг - сколько в среднем ждёте отклика. Чем меньше, тем лучше.',
  },
  {
    label: 'Сеть',
    text: 'Сколько сигнал идёт до сервера и обратно (RTT). Зависит от вашего интернета.',
  },
  {
    label: 'Сервер',
    text: 'Сколько сервер думает над ответом. Растёт, когда серверу тяжело.',
  },
  {
    label: 'Джиттер',
    text: 'Насколько пинг скачет от замера к замеру (джиттер). Большой - связь нестабильна.',
  },
  {
    label: 'Пик',
    text: 'Самый большой пинг за последнее время. Сильно выше среднего - были подвисания.',
  },
  {
    label: 'Потолок',
    text: 'Минимум, который убрать нельзя: сервер и игра обновляются не мгновенно (потолок тика).',
  },
  {
    label: 'Дилатация',
    text: 'Насколько сервер отстаёт от реального времени (дилатация). Большая - серверу тяжело.',
  },
];

const PingReference = () => (
  <Collapsible title="Справочник">
    <Section title="Вердикты">
      <LabeledList>
        {VERDICT_REFERENCE.map((row) => (
          <LabeledList.Item key={row.title} label={row.title}>
            {row.text}
          </LabeledList.Item>
        ))}
      </LabeledList>
    </Section>
    <Section title="Метрики">
      <LabeledList>
        {METRIC_REFERENCE.map((row) => (
          <LabeledList.Item key={row.label} label={row.label}>
            {row.text}
          </LabeledList.Item>
        ))}
      </LabeledList>
    </Section>
  </Collapsible>
);

export const PingDiagnostics = (props, context) => {
  const { data } = useBackend<PingDiagnosticsData>(context);
  const {
    is_admin,
    verdict = 'healthy',
    rtt = 0,
    server = 0,
    jitter = 0,
    floor = 0,
    total = 0,
    rtt_max = 0,
    spike = 0,
    target_key,
    ss_costs,
  } = data;
  const v = VERDICTS[verdict] || VERDICTS.healthy;
  const barMax = Math.max(total, floor, 1);
  // Server-wide player list slides out from the right; the window widens to make room.
  const [showPlayers, setShowPlayers] = useLocalState(
    context,
    'pingShowPlayers',
    false
  );

  return (
    <Window title="Диагностика пинга" width={showPlayers ? 780 : 460} height={560}>
      <Window.Content>
        <Stack fill>
          <Stack.Item grow basis={0}>
            <Section fill scrollable>
              <Button
                fluid
                icon="users"
                selected={showPlayers}
                onClick={() => setShowPlayers(!showPlayers)}>
                Пинг всех игроков
              </Button>
              {!!is_admin && <ClientPicker />}
              <Section title={`Вердикт: ${v.title}`}>
                <NoticeBox color={v.color}>{v.text(data)}</NoticeBox>
                <Box mt={1} color="label">
                  Цель: {target_key || '-'}
                </Box>
              </Section>
              <Section title="Из чего состоит пинг">
                <LabeledList>
                  <LabeledList.Item label="Всего">{total} ms</LabeledList.Item>
                  <LabeledList.Item label="Сеть">{rtt} ms</LabeledList.Item>
                  <LabeledList.Item label="Сервер">{server} ms</LabeledList.Item>
                  <LabeledList.Item label="Джиттер">{jitter} ms</LabeledList.Item>
                  <LabeledList.Item
                    label="Пик"
                    color={spike >= SPIKE_MIN_MS ? 'bad' : undefined}>
                    {rtt_max} ms{spike >= SPIKE_MIN_MS ? ` (+${spike} скачок)` : ''}
                  </LabeledList.Item>
                  <LabeledList.Item label="Потолок">{floor} ms</LabeledList.Item>
                </LabeledList>
                <Box mt={1}>
                  <ProgressBar value={rtt / barMax} color="average">
                    Сеть {rtt}ms
                  </ProgressBar>
                  <ProgressBar value={server / barMax} color="bad" mt={0.5}>
                    Сервер {server}ms
                  </ProgressBar>
                </Box>
              </Section>
              <Section title="История (последние замеры)">
                <SparkLine history={data.history} />
              </Section>
              <Section title="Сводка по истории">
                <HistorySummary history={data.history} floor={floor} />
                <Box mt={1} color="label">
                  Это сводка за последние замеры: показывает, что происходит
                  обычно, а не только прямо сейчас. Оценка примерная.
                </Box>
              </Section>
              {!!ss_costs && <SubsystemTable data={data} />}
              <PingReference />
            </Section>
          </Stack.Item>
          {showPlayers && (
            <Stack.Item width="320px">
              <Section fill scrollable title="Пинг всех игроков">
                <ServerPingTable
                  all_pings={data.all_pings}
                  own_key={data.own_key}
                />
              </Section>
            </Stack.Item>
          )}
        </Stack>
      </Window.Content>
    </Window>
  );
};
