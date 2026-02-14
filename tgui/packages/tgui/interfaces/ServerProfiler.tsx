import { useBackend, useLocalState } from '../backend';
import {
  Box,
  Button,
  Collapsible,
  Dropdown,
  Input,
  LabeledList,
  ProgressBar,
  Section,
  Stack,
  Table,
  Tabs,
  Tooltip,
} from '../components';
import { Window } from '../layouts';

type SubsystemData = {
  name: string;
  cost: number;
  tick_usage: number;
  tick_overrun: number;
  ticks: number;
  times_fired: number;
  state: string;
  wait: number;
  priority: number;
  can_fire: number;
  subcosts?: Array<{ name: string; cost: number }>;
};

type ProcEntry = {
  name: string;
  self: number;
  total: number;
  real: number;
  calls: number;
  avg: number;
  self_pct: number;
  cat: string;
  delta: number;
};

type CategoryData = {
  id: string;
  name: string;
  self_total: number;
  self_pct: number;
  calls: number;
  proc_count: number;
};

type QueueData = {
  name: string;
  count: number;
};

type ProfilerData = {
  cpu: number;
  fps: number;
  tick_lag: number;
  instances: number;
  players: number;
  tick_drift: number;
  tick_drift_pct: number;
  mc_iteration: number;
  map_tick: number;
  time_dilation: number;
  time_dilation_avg_fast: number;
  time_dilation_avg: number;
  time_dilation_avg_slow: number;
  subsystems: SubsystemData[];
  profiling_active: boolean;
  profile_refresh_interval: number;
  top_n: number;
  profile_data: ProcEntry[];
  debug_status: string;
  ssprofiler_active: boolean;
  categories: CategoryData[];
  category_procs: Record<string, ProcEntry[]>;
  queues: QueueData[];
  total_self_time: number;
};

// Must match PROFILER_TAB_* defines in server_profiler.dm
const TAB_OVERVIEW = 1;
const TAB_ANALYSIS = 2;
const TAB_SUBSYSTEMS = 3;
const TAB_PROFILING = 4;

const getStatusColor = (value: number, warn: number, crit: number) => {
  if (value >= crit) return 'red';
  if (value >= warn) return 'yellow';
  return 'green';
};

// Category colors for the stacked bar visualization
const CATEGORY_COLORS: Record<string, string> = {
  atmos: '#e74c3c',
  machines: '#e67e22',
  mobs: '#f1c40f',
  lighting: '#2ecc71',
  rendering: '#8e44ad',
  tgui: '#3498db',
  subsystems: '#9b59b6',
  timers: '#1abc9c',
  map: '#34495e',
  components: '#7f8c8d',
  ai: '#d35400',
  items: '#27ae60',
  assets: '#2c3e50',
  profiler_self: '#95a5a6',
  other: '#bdc3c7',
};

// Source file hint extraction from proc type paths
const getFileHint = (procName: string): string | null => {
  const ssMatch = procName.match(
    /^\/datum\/controller\/subsystem\/(\w+)/,
  );
  if (ssMatch) {
    return 'code/controllers/subsystem/' + ssMatch[1] + '.dm';
  }
  if (procName.startsWith('/obj/machinery/')) {
    return 'code/game/machinery/';
  }
  if (procName.startsWith('/mob/')) {
    return 'code/modules/mob/';
  }
  if (procName.startsWith('/turf/')) {
    return 'code/game/turfs/';
  }
  if (procName.startsWith('/datum/component/')) {
    return 'code/datums/components/';
  }
  if (procName.startsWith('/datum/element/')) {
    return 'code/datums/elements/';
  }
  if (procName.startsWith('/datum/ai')) {
    return 'code/datums/ai/';
  }
  if (procName.startsWith('/obj/item/')) {
    return 'code/game/objects/items/';
  }
  if (procName.startsWith('/datum/asset')) {
    return 'code/modules/asset_cache/';
  }
  return null;
};

export const ServerProfiler = (_props, context) => {
  const { act } = useBackend(context);
  const [tab, setTab] = useLocalState(context, 'tab', TAB_OVERVIEW);

  const changeTab = (newTab: number) => {
    setTab(newTab);
    act('set_tab', { tab: newTab });
  };

  return (
    <Window title="Server Profiler" width={950} height={700}>
      <Window.Content scrollable>
        <Tabs>
          <Tabs.Tab
            selected={tab === TAB_OVERVIEW}
            onClick={() => changeTab(TAB_OVERVIEW)}
          >
            {'Обзор'}
          </Tabs.Tab>
          <Tabs.Tab
            selected={tab === TAB_ANALYSIS}
            onClick={() => changeTab(TAB_ANALYSIS)}
          >
            {'Анализ'}
          </Tabs.Tab>
          <Tabs.Tab
            selected={tab === TAB_SUBSYSTEMS}
            onClick={() => changeTab(TAB_SUBSYSTEMS)}
          >
            {'Подсистемы'}
          </Tabs.Tab>
          <Tabs.Tab
            selected={tab === TAB_PROFILING}
            onClick={() => changeTab(TAB_PROFILING)}
          >
            {'Профилирование'}
          </Tabs.Tab>
        </Tabs>
        {tab === TAB_OVERVIEW && <OverviewTab />}
        {tab === TAB_ANALYSIS && <AnalysisTab />}
        {tab === TAB_SUBSYSTEMS && <SubsystemsTab />}
        {tab === TAB_PROFILING && <ProfilingTab />}
      </Window.Content>
    </Window>
  );
};

// ── Overview Tab ─────────────────────────────────────────

const OverviewTab = (_props, context) => {
  const { act, data } = useBackend<ProfilerData>(context);

  const tidiColor = getStatusColor(data.time_dilation, 10, 25);
  const queues = data.queues || [];

  return (
    <>
      <Section title="Общие показатели">
        <LabeledList>
          <LabeledList.Item label="CPU">
            <ProgressBar
              value={data.cpu}
              minValue={0}
              maxValue={200}
              ranges={{
                good: [0, 80],
                average: [80, 100],
                bad: [100, 200],
              }}
            >
              {data.cpu + '%'}
            </ProgressBar>
          </LabeledList.Item>
          <LabeledList.Item label="FPS">{data.fps}</LabeledList.Item>
          <LabeledList.Item label="Tick Lag">
            {data.tick_lag + ' мс'}
          </LabeledList.Item>
          <LabeledList.Item label="Игроков">
            {data.players}
          </LabeledList.Item>
          <LabeledList.Item label="Объектов">
            {data.instances}
          </LabeledList.Item>
          <LabeledList.Divider />
          <LabeledList.Item label="Tick Drift">
            <Box color={data.tick_drift_pct > 5 ? 'red' : 'green'}>
              {data.tick_drift + ' (' + data.tick_drift_pct + '%)'}
            </Box>
          </LabeledList.Item>
          <LabeledList.Item label="Map Tick">
            <Box color={data.map_tick > 50 ? 'red' : 'green'}>
              {data.map_tick + '%'}
            </Box>
          </LabeledList.Item>
          <LabeledList.Item label="Итерация MC">
            {data.mc_iteration}
          </LabeledList.Item>
          <LabeledList.Divider />
          <LabeledList.Item label="Замедление (текущее)">
            <Box color={tidiColor} bold>
              {data.time_dilation + '%'}
            </Box>
          </LabeledList.Item>
          <LabeledList.Item label="Замедление (быстрое среднее)">
            {data.time_dilation_avg_fast + '%'}
          </LabeledList.Item>
          <LabeledList.Item label="Замедление (среднее)">
            {data.time_dilation_avg + '%'}
          </LabeledList.Item>
          <LabeledList.Item label="Замедление (медленное среднее)">
            {data.time_dilation_avg_slow + '%'}
          </LabeledList.Item>
        </LabeledList>
        <Box mt={1}>
          <Button
            icon="file-csv"
            content="Сохранить CSV снимок"
            onClick={() => act('dump_csv')}
          />
        </Box>
      </Section>
      {queues.length > 0 && (
        <Section title="Очереди обработки">
          <LabeledList>
            {queues.map((q) => (
              <LabeledList.Item key={q.name} label={q.name}>
                <Box
                  color={
                    q.count > 500
                      ? 'red'
                      : q.count > 200
                        ? 'yellow'
                        : 'green'
                  }
                  bold
                >
                  {q.count}
                </Box>
              </LabeledList.Item>
            ))}
          </LabeledList>
        </Section>
      )}
    </>
  );
};

// ── Analysis Tab ─────────────────────────────────────────

const AnalysisTab = (_props, context) => {
  const { data } = useBackend<ProfilerData>(context);
  const categories = data.categories || [];
  const profileData = data.profile_data || [];
  const queues = data.queues || [];

  if (!data.profiling_active && !profileData.length) {
    return (
      <Section title="Анализ нагрузки">
        <Box color="label" textAlign="center" mt={2}>
          {'Запустите профилирование на вкладке "Профилирование".'}
        </Box>
      </Section>
    );
  }

  const categoryProcs = data.category_procs || {};
  const visibleCategories = categories.filter(
    (c) => c.id !== 'profiler_self',
  );
  const barCategories = categories.filter((c) => c.self_pct >= 0.5);

  return (
    <>
      <Section
        title={
          'Нагрузка по категориям' +
          (data.total_self_time
            ? ' (' + data.total_self_time + ' мс всего)'
            : '')
        }
      >
        {barCategories.length > 0 ? (
          <>
            {/* Stacked bar visualization */}
            <Box mb={2}>
              <Stack>
                {barCategories.map((cat) => (
                  <Stack.Item key={cat.id} grow={cat.self_pct} basis={0}>
                    <Tooltip
                      content={
                        cat.name +
                        ': ' +
                        cat.self_pct +
                        '% (' +
                        cat.self_total +
                        ' мс)'
                      }
                    >
                      <Box
                        style={{
                          'background-color':
                            CATEGORY_COLORS[cat.id] || '#bdc3c7',
                          height: '28px',
                          'text-align': 'center',
                          'font-size': '11px',
                          'line-height': '28px',
                          overflow: 'hidden',
                          color: '#fff',
                          'text-shadow': '0 1px 2px rgba(0,0,0,0.5)',
                        }}
                      >
                        {cat.self_pct >= 8
                          ? cat.name + ' ' + cat.self_pct + '%'
                          : cat.self_pct >= 4
                            ? cat.self_pct + '%'
                            : ''}
                      </Box>
                    </Tooltip>
                  </Stack.Item>
                ))}
              </Stack>
            </Box>

            {/* Category drill-down */}
            {visibleCategories.map((cat) => (
              <CategoryRow
                key={cat.id}
                category={cat}
                procs={categoryProcs[cat.id] || []}
              />
            ))}
          </>
        ) : (
          <Box color="label">
            {'Ожидание данных категоризации...'}
          </Box>
        )}
      </Section>

      {queues.length > 0 && (
        <Section title="Очереди обработки">
          <Table>
            <Table.Row header>
              <Table.Cell>{'Подсистема'}</Table.Cell>
              <Table.Cell collapsing>{'Объектов'}</Table.Cell>
            </Table.Row>
            {queues.map((q) => (
              <Table.Row key={q.name}>
                <Table.Cell>{q.name}</Table.Cell>
                <Table.Cell collapsing>
                  <Box
                    color={
                      q.count > 500
                        ? 'red'
                        : q.count > 200
                          ? 'yellow'
                          : ''
                    }
                    bold
                  >
                    {q.count}
                  </Box>
                </Table.Cell>
              </Table.Row>
            ))}
          </Table>
        </Section>
      )}
    </>
  );
};

const CategoryRow = (
  props: { category: CategoryData; procs: ProcEntry[] },
  _context,
) => {
  const { category, procs } = props;
  const topProcs = procs.slice(0, 10);
  const maxPct = topProcs[0]?.self_pct || 1;

  return (
    <Collapsible
      title={
        category.name +
        ' \u2014 ' +
        category.self_pct +
        '% (' +
        category.self_total +
        ' мс, ' +
        category.proc_count +
        ' прок.)'
      }
      color={
        category.self_pct > 20
          ? 'bad'
          : category.self_pct > 10
            ? 'average'
            : 'default'
      }
    >
      {topProcs.length > 0 ? (
        <Table>
          <Table.Row header>
            <Table.Cell>{'Процедура'}</Table.Cell>
            <Table.Cell collapsing>{'Self %'}</Table.Cell>
            <Table.Cell collapsing>{'Self мс'}</Table.Cell>
            <Table.Cell collapsing>{'Вызовов'}</Table.Cell>
            <Table.Cell collapsing>{'Avg мс'}</Table.Cell>
          </Table.Row>
          {topProcs.map((proc, i) => (
            <Table.Row key={proc.name + '_' + i}>
              <Table.Cell>
                <Box
                  style={{
                    'word-break': 'break-all',
                    'font-size': '11px',
                  }}
                >
                  {proc.name}
                </Box>
                {(() => {
                  const hint = getFileHint(proc.name);
                  return hint ? (
                    <Box
                      color="label"
                      style={{ 'font-size': '9px' }}
                    >
                      {hint}
                    </Box>
                  ) : null;
                })()}
              </Table.Cell>
              <Table.Cell collapsing>
                <ProgressBar
                  value={proc.self_pct}
                  minValue={0}
                  maxValue={Math.max(maxPct, 0.1)}
                  ranges={{
                    good: [0, 5],
                    average: [5, 15],
                    bad: [15, 100],
                  }}
                >
                  {proc.self_pct.toFixed(1) + '%'}
                </ProgressBar>
              </Table.Cell>
              <Table.Cell collapsing bold>
                {proc.self}
              </Table.Cell>
              <Table.Cell collapsing>{proc.calls}</Table.Cell>
              <Table.Cell collapsing>{proc.avg}</Table.Cell>
            </Table.Row>
          ))}
        </Table>
      ) : (
        <Box color="label">{'Нет данных по процедурам.'}</Box>
      )}
    </Collapsible>
  );
};

// ── Subsystems Tab ───────────────────────────────────────

const SS_SORT_COLUMNS = [
  { key: 'name', label: 'Имя' },
  { key: 'cost', label: 'мс' },
  { key: 'tick_usage', label: 'Тик %' },
  { key: 'tick_overrun', label: 'Перерасход %' },
  { key: 'ticks', label: 'Тики/Цикл' },
  { key: 'times_fired', label: 'Запусков' },
  { key: 'priority', label: 'Приоритет' },
] as const;

type SSSortKey = (typeof SS_SORT_COLUMNS)[number]['key'];

const SubsystemsTab = (_props, context) => {
  const { data } = useBackend<ProfilerData>(context);
  const [sortCol, setSortCol] = useLocalState<SSSortKey>(
    context,
    'ss_sort',
    'cost',
  );
  const [sortDesc, setSortDesc] = useLocalState(
    context,
    'ss_desc',
    true,
  );
  const [ssFilter, setSsFilter] = useLocalState(
    context,
    'ss_filter',
    '',
  );
  const [expanded, setExpanded] = useLocalState<
    Record<string, boolean>
  >(context, 'ss_expanded', {});

  let subsystems = [...(data.subsystems || [])];

  // Filter
  if (ssFilter) {
    const lower = ssFilter.toLowerCase();
    subsystems = subsystems.filter((ss) =>
      ss.name.toLowerCase().includes(lower),
    );
  }

  // Client-side sort
  subsystems.sort((a, b) => {
    const aVal = a[sortCol];
    const bVal = b[sortCol];
    if (typeof aVal === 'string' && typeof bVal === 'string') {
      return sortDesc
        ? bVal.localeCompare(aVal)
        : aVal.localeCompare(bVal);
    }
    const numA = Number(aVal) || 0;
    const numB = Number(bVal) || 0;
    return sortDesc ? numB - numA : numA - numB;
  });

  const handleSort = (col: SSSortKey) => {
    if (col === sortCol) {
      setSortDesc(!sortDesc);
    } else {
      setSortCol(col);
      setSortDesc(true);
    }
  };

  const toggleExpand = (name: string) => {
    const next = { ...expanded };
    next[name] = !next[name];
    setExpanded(next);
  };

  return (
    <Section title="Подсистемы">
      <Box mb={1}>
        <Input
          placeholder="Поиск подсистемы..."
          value={ssFilter}
          onInput={(_e, val) => setSsFilter(val)}
        />
      </Box>
      <Table>
        <Table.Row header>
          <Table.Cell collapsing>{''}</Table.Cell>
          {SS_SORT_COLUMNS.map((col) => (
            <Table.Cell
              key={col.key}
              collapsing={col.key !== 'name'}
              onClick={() => handleSort(col.key)}
              style={{ cursor: 'pointer' }}
            >
              <Box inline bold>
                {col.label}
                {sortCol === col.key &&
                  (sortDesc ? ' \u25BC' : ' \u25B2')}
              </Box>
            </Table.Cell>
          ))}
          <Table.Cell collapsing>{'Сост.'}</Table.Cell>
        </Table.Row>
        {subsystems.map((ss) => [
          <Table.Row
            key={ss.name}
            className={
              ss.cost > 10 || ss.tick_overrun > 5
                ? 'color-bad'
                : undefined
            }
          >
            <Table.Cell collapsing>
              {ss.subcosts && ss.subcosts.length > 0 ? (
                <Button
                  icon={
                    expanded[ss.name]
                      ? 'chevron-down'
                      : 'chevron-right'
                  }
                  onClick={() => toggleExpand(ss.name)}
                  color="transparent"
                />
              ) : null}
            </Table.Cell>
            <Table.Cell bold={ss.cost > 5}>{ss.name}</Table.Cell>
            <Table.Cell collapsing>
              <Box
                color={
                  ss.cost > 10
                    ? 'red'
                    : ss.cost > 5
                      ? 'yellow'
                      : ''
                }
              >
                {ss.cost}
              </Box>
            </Table.Cell>
            <Table.Cell collapsing>
              <Box
                color={
                  ss.tick_usage > 20
                    ? 'red'
                    : ss.tick_usage > 10
                      ? 'yellow'
                      : ''
                }
              >
                {ss.tick_usage}
              </Box>
            </Table.Cell>
            <Table.Cell collapsing>
              <Box color={ss.tick_overrun > 0 ? 'red' : ''}>
                {ss.tick_overrun}
              </Box>
            </Table.Cell>
            <Table.Cell collapsing>{ss.ticks}</Table.Cell>
            <Table.Cell collapsing>{ss.times_fired}</Table.Cell>
            <Table.Cell collapsing>{ss.priority}</Table.Cell>
            <Table.Cell collapsing>
              <Box
                color={
                  ss.state === 'R'
                    ? 'green'
                    : ss.state === 'P'
                      ? 'yellow'
                      : ''
                }
              >
                {ss.state}
              </Box>
            </Table.Cell>
          </Table.Row>,
          expanded[ss.name] && ss.subcosts && (
            <Table.Row key={ss.name + '_detail'}>
              <Table.Cell />
              <Table.Cell colSpan={8}>
                <Box ml={1}>
                  {ss.subcosts.map((sc) => (
                    <Box key={sc.name} inline mr={2} mb={0.5}>
                      <Box inline color="label">
                        {sc.name + ': '}
                      </Box>
                      <Box
                        inline
                        bold
                        color={
                          sc.cost > 5
                            ? 'red'
                            : sc.cost > 2
                              ? 'yellow'
                              : ''
                        }
                      >
                        {sc.cost + ' мс'}
                      </Box>
                    </Box>
                  ))}
                </Box>
              </Table.Cell>
            </Table.Row>
          ),
        ])}
      </Table>
    </Section>
  );
};

// ── Profiling Tab ────────────────────────────────────────

const REFRESH_OPTIONS = ['10', '30', '50', '100'];

const TOP_N_OPTIONS = ['50', '100', '200', '500'];

const ProfilingTab = (_props, context) => {
  const { act, data } = useBackend<ProfilerData>(context);
  const [procFilter, setProcFilter] = useLocalState(
    context,
    'proc_filter',
    '',
  );

  const profileData = data.profile_data || [];
  const filteredData = procFilter
    ? profileData.filter((p) =>
        p.name.toLowerCase().includes(procFilter.toLowerCase()),
      )
    : profileData;

  return (
    <Section
      title="Профилирование процедур"
      buttons={
        <>
          {data.profiling_active ? (
            <Button
              icon="stop"
              color="red"
              content="Остановить"
              onClick={() => act('stop_profile')}
            />
          ) : (
            <Button
              icon="play"
              color="green"
              content="Запустить"
              onClick={() => act('start_profile')}
            />
          )}
          <Button
            icon="sync"
            content="Обновить"
            onClick={() => act('refresh_profile')}
          />
          <Button
            icon="fire"
            content="Дамп горячих точек"
            tooltip="Записать топ-20 процедур и подсистем в лог"
            onClick={() => act('dump_hotspots')}
          />
        </>
      }
    >
      <Box mb={1}>
        <Box inline mr={2}>
          {'Интервал (тики): '}
          <Dropdown
            selected={String(data.profile_refresh_interval)}
            options={REFRESH_OPTIONS}
            onSelected={(val) =>
              act('set_refresh_interval', { interval: val })
            }
          />
        </Box>
        <Box inline mr={2}>
          {'Топ: '}
          <Dropdown
            selected={String(data.top_n)}
            options={TOP_N_OPTIONS}
            onSelected={(val) => act('set_top_n', { top_n: val })}
          />
        </Box>
        {data.total_self_time > 0 && (
          <Box inline color="label">
            {'Общий self: ' + data.total_self_time + ' мс'}
          </Box>
        )}
      </Box>
      <Box mb={1}>
        <Input
          placeholder="Фильтр процедур (напр. machinery, process, air)..."
          fluid
          value={procFilter}
          onInput={(_e, val) => setProcFilter(val)}
        />
      </Box>
      {data.debug_status && (
        <Box mb={1} color="label" italic>
          {'Статус: ' + data.debug_status}
        </Box>
      )}
      {data.ssprofiler_active && (
        <Box mb={1} color="yellow">
          {
            'SSprofiler активен (auto_profile=true). Данные записываются автоматически.'
          }
        </Box>
      )}
      {!profileData.length ? (
        <Box color="label" textAlign="center" mt={2}>
          {data.profiling_active
            ? 'Сбор данных профилирования... Подождите ' +
              Math.round(data.profile_refresh_interval / 10) +
              ' сек.'
            : 'Нажмите "Запустить" для начала профилирования.'}
        </Box>
      ) : (
        <ProcTable data={filteredData} />
      )}
    </Section>
  );
};

// ── Proc Table ───────────────────────────────────────────

const PROC_COLUMNS = [
  { key: 'name', label: 'Процедура' },
  { key: 'self_pct', label: 'Self %' },
  { key: 'calls', label: 'Вызовов' },
  { key: 'self', label: 'Self мс' },
  { key: 'total', label: 'Total мс' },
  { key: 'real', label: 'Real мс' },
  { key: 'avg', label: 'Avg мс' },
  { key: 'delta', label: '\u0394' },
] as const;

type ProcSortKey = (typeof PROC_COLUMNS)[number]['key'];

const ProcTable = (props: { data: ProcEntry[] }, context) => {
  const [sortBy, setSortBy] = useLocalState<ProcSortKey>(
    context,
    'proc_sort',
    'self',
  );
  const [sortDesc, setSortDesc] = useLocalState(
    context,
    'proc_desc',
    true,
  );

  // Client-side sorting
  const procs = [...props.data].sort((a, b) => {
    const aVal = a[sortBy];
    const bVal = b[sortBy];
    if (typeof aVal === 'string' && typeof bVal === 'string') {
      return sortDesc
        ? bVal.localeCompare(aVal)
        : aVal.localeCompare(bVal);
    }
    const numA = Number(aVal) || 0;
    const numB = Number(bVal) || 0;
    return sortDesc ? numB - numA : numA - numB;
  });
  const maxPct = procs[0]?.self_pct || 1;

  const handleSort = (col: ProcSortKey) => {
    if (col === sortBy) {
      setSortDesc(!sortDesc);
    } else {
      setSortBy(col);
      setSortDesc(true);
    }
  };

  return (
    <Table>
      <Table.Row header>
        {PROC_COLUMNS.map((col) => (
          <Table.Cell
            key={col.key}
            collapsing={col.key !== 'name'}
            onClick={() => handleSort(col.key)}
            style={{ cursor: 'pointer' }}
          >
            <Box inline bold>
              {col.label}
              {sortBy === col.key &&
                (sortDesc ? ' \u25BC' : ' \u25B2')}
            </Box>
          </Table.Cell>
        ))}
      </Table.Row>
      {procs.map((proc, i) => (
        <Table.Row key={proc.name + '_' + i}>
          <Table.Cell>
            <Box
              style={{
                'word-break': 'break-all',
                'font-size': '11px',
              }}
            >
              {proc.name}
            </Box>
            {(() => {
              const hint = getFileHint(proc.name);
              return hint ? (
                <Box color="label" style={{ 'font-size': '9px' }}>
                  {hint}
                </Box>
              ) : null;
            })()}
          </Table.Cell>
          <Table.Cell collapsing>
            <ProgressBar
              value={proc.self_pct}
              minValue={0}
              maxValue={Math.max(maxPct, 0.1)}
              ranges={{
                good: [0, 5],
                average: [5, 15],
                bad: [15, 100],
              }}
            >
              {proc.self_pct.toFixed(1) + '%'}
            </ProgressBar>
          </Table.Cell>
          <Table.Cell collapsing>{proc.calls}</Table.Cell>
          <Table.Cell collapsing bold>
            {proc.self}
          </Table.Cell>
          <Table.Cell collapsing>{proc.total}</Table.Cell>
          <Table.Cell collapsing>{proc.real}</Table.Cell>
          <Table.Cell collapsing>{proc.avg}</Table.Cell>
          <Table.Cell collapsing>
            <Box
              color={
                proc.delta > 0.5
                  ? 'red'
                  : proc.delta < -0.5
                    ? 'green'
                    : ''
              }
              bold={Math.abs(proc.delta) > 1}
            >
              {Math.abs(proc.delta) < 0.01
                ? '--'
                : (proc.delta > 0 ? '+' : '') +
                  proc.delta.toFixed(2)}
            </Box>
          </Table.Cell>
        </Table.Row>
      ))}
    </Table>
  );
};
