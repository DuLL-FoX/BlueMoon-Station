import {
  classifySample,
  SPIKE_MIN_MS,
  summarizeHistory,
} from './pingHistory';

// floor used across tests; samples are [rtt, server, jitter].
const FLOOR = 14;

describe('classifySample', () => {
  test('calm sample near floor is healthy', () => {
    expect(classifySample(2, 4, 1, FLOOR, 2)).toBe('healthy');
  });

  test('high server over floor is server', () => {
    expect(classifySample(2, 40, 1, FLOOR, 2)).toBe('server');
  });

  test('dominant network rtt over floor is network', () => {
    expect(classifySample(50, 5, 1, FLOOR, 50)).toBe('network');
  });

  test('rtt peak well above window average is jitter (spike)', () => {
    expect(classifySample(5 + SPIKE_MIN_MS, 4, 1, FLOOR, 5)).toBe('jitter');
  });

  test('high jitter ratio is jitter', () => {
    expect(classifySample(5, 3, 20, FLOOR, 5)).toBe('jitter');
  });

  test('very high rtt is network even when it also spikes', () => {
    // rtt 70 would trip the spike check (70 - 5 >= SPIKE_MIN_MS), but the hard-network
    // branch wins first, matching DM PING_NETWORK_HARD_MS.
    expect(classifySample(70, 5, 1, FLOOR, 5)).toBe('network');
  });
});

describe('summarizeHistory', () => {
  test('empty history returns null', () => {
    expect(summarizeHistory([], FLOOR)).toBeNull();
  });

  test('calm history is dominant healthy and stable', () => {
    const history = Array.from({ length: 10 }, () => [2, 4, 1]);
    const summary = summarizeHistory(history, FLOOR);
    expect(summary).not.toBeNull();
    expect(summary!.count).toBe(10);
    expect(summary!.dominant).toBe('healthy');
    expect(summary!.dominantCount).toBe(10);
    expect(summary!.trend).toBe('stable');
    expect(summary!.spikeCount).toBe(0);
    expect(summary!.stability).toBe('stable');
  });

  test('rising totals report a rising trend', () => {
    const history = [
      [2, 2, 0],
      [2, 2, 0],
      [2, 2, 0],
      [2, 2, 0],
      [2, 30, 0],
      [2, 32, 0],
      [2, 34, 0],
      [2, 36, 0],
    ];
    const summary = summarizeHistory(history, FLOOR);
    expect(summary!.trend).toBe('rising');
  });

  test('injected peaks are counted as spikes with a max', () => {
    const history = [
      [4, 4, 0],
      [4, 4, 0],
      [4, 4, 0],
      [4, 4, 0],
      [4, 4, 0],
      [4, 4, 0],
      [4, 4, 0],
      [50, 4, 0],
    ];
    const summary = summarizeHistory(history, FLOOR);
    expect(summary!.spikeCount).toBe(1);
    expect(summary!.spikeMax).toBeCloseTo(40.3, 1);
  });

  test('falling totals report a falling trend', () => {
    const history = [
      [2, 36, 0],
      [2, 34, 0],
      [2, 32, 0],
      [2, 30, 0],
      [2, 2, 0],
      [2, 2, 0],
      [2, 2, 0],
      [2, 2, 0],
    ];
    // First half avg total 35, second half 4 -> well past the trend threshold.
    const summary = summarizeHistory(history, FLOOR);
    expect(summary!.trend).toBe('falling');
  });

  test('moderate spread without a trend is moderate stability', () => {
    // Totals 10,12,14,16: spread 6 over avg 13 -> ratio ~0.46 (moderate), half-window
    // delta 4ms stays under the trend threshold so trend is stable.
    const history = [
      [2, 8, 0],
      [2, 10, 0],
      [2, 12, 0],
      [2, 14, 0],
    ];
    const summary = summarizeHistory(history, FLOOR);
    expect(summary!.trend).toBe('stable');
    expect(summary!.stability).toBe('moderate');
  });

  test('wide spread is rough stability', () => {
    // Totals 4,4,42,42: spread 38 over avg 23 -> ratio ~1.65 (rough).
    const history = [
      [2, 2, 0],
      [2, 2, 0],
      [2, 40, 0],
      [2, 40, 0],
    ];
    const summary = summarizeHistory(history, FLOOR);
    expect(summary!.stability).toBe('rough');
  });

  test('ties favor the more actionable verdict (server over network)', () => {
    // Two server samples and two network samples; window avg rtt 16 keeps spikes from
    // firing. VERDICT_ORDER puts server ahead of network on the tie.
    const history = [
      [2, 40, 0],
      [2, 40, 0],
      [30, 5, 0],
      [30, 5, 0],
    ];
    const summary = summarizeHistory(history, FLOOR);
    expect(summary!.dominant).toBe('server');
    expect(summary!.dominantCount).toBe(2);
  });
});
