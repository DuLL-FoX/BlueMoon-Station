// Pure helpers for the Ping Diagnostics history summary. No Inferno imports, so the logic
// is unit-testable in isolation. Verdict thresholds mirror the authoritative DM classifier
// in modular_bluemoon/code/modules/ping_diagnostics/ping_verdict.dm - keep them in sync if
// those #defines change.

// Mirror of PING_SPIKE_MIN_MS: an RTT peak must be this far (ms) above the window average to
// count as a spike (absolute floor, ignores tiny hitches on a low-ping link).
export const SPIKE_MIN_MS = 25;
// Mirror of PING_SPIKE_RATIO: the peak must also be this fraction of the window-average RTT, so
// a peak that is routine for a high-latency link is not mistaken for instability.
const SPIKE_RATIO = 0.25;
// Mirror of PING_NETWORK_MIN_MS.
const NETWORK_MIN_MS = 15;
// Mirror of PING_FLOOR_MARGIN_MS.
const FLOOR_MARGIN_MS = 8;
// Mirror of PING_JITTER_MIN_MS.
const JITTER_MIN_MS = 10;
// Mirror of PING_JITTER_RATIO.
const JITTER_RATIO = 0.6;

// Half-window average totals this far (ms) apart read as a trend rather than noise.
const TREND_MIN_MS = 5;
// Spread (max - min) relative to the average total: below STABLE is calm, at/above ROUGH jumps.
const STABILITY_STABLE_RATIO = 0.25;
const STABILITY_ROUGH_RATIO = 0.6;

export type SampleVerdict = 'healthy' | 'server' | 'network' | 'jitter';
export type Trend = 'rising' | 'falling' | 'stable';
export type Stability = 'stable' | 'moderate' | 'rough';

export type HistorySummary = {
  count: number;
  dominant: SampleVerdict;
  dominantCount: number;
  trend: Trend;
  spikeCount: number;
  spikeMax: number;
  min: number;
  avg: number;
  max: number;
  stability: Stability;
};

// Tie-break order when verdicts occur equally often: surface the more actionable one first.
const VERDICT_ORDER: SampleVerdict[] = ['server', 'network', 'jitter', 'healthy'];

const round1 = (value: number) => Math.round(value * 10) / 10;

// True when an RTT sample stands far enough above the window average to count as a transient
// spike, gauged both absolutely and as a fraction of the baseline so it scales with the
// connection. Mirrors the spike branch of classify_ping.
const isSpike = (above: number, windowAvgRtt: number): boolean =>
  above >= SPIKE_MIN_MS && above >= windowAvgRtt * SPIKE_RATIO;

// Categorize one sample by its dominant component. Mirrors the component-based branches of
// classify_ping (same ordering: instability before the network conclusion); the dilation- and
// fps-driven branches are intentionally omitted because the history carries no per-sample
// dilation or client fps.
export const classifySample = (
  rtt: number,
  server: number,
  jitter: number,
  floor: number,
  windowAvgRtt: number
): SampleVerdict => {
  if (isSpike(rtt - windowAvgRtt, windowAvgRtt)) {
    return 'jitter';
  }
  const total = rtt + server;
  if (jitter >= JITTER_MIN_MS && total > 0 && jitter / total >= JITTER_RATIO) {
    return 'jitter';
  }
  if (rtt >= NETWORK_MIN_MS && rtt >= server && rtt > floor + FLOOR_MARGIN_MS) {
    return 'network';
  }
  if (server > floor + FLOOR_MARGIN_MS) {
    return 'server';
  }
  return 'healthy';
};

// Summarize the recent history window. `history` entries are [rtt, server, jitter]; total is
// rtt + server (matching the panel's chart and live total). Returns null for empty history.
export const summarizeHistory = (
  history: number[][],
  floor: number
): HistorySummary | null => {
  if (!history || !history.length) {
    return null;
  }
  const count = history.length;
  const rtts = history.map((sample) => sample[0]);
  const totals = history.map((sample) => sample[0] + sample[1]);
  const windowAvgRtt = rtts.reduce((sum, value) => sum + value, 0) / count;

  // Dominant verdict across the window.
  const tally: Record<SampleVerdict, number> = {
    healthy: 0,
    server: 0,
    network: 0,
    jitter: 0,
  };
  history.forEach((sample) => {
    tally[classifySample(sample[0], sample[1], sample[2], floor, windowAvgRtt)] += 1;
  });
  let dominant: SampleVerdict = 'healthy';
  let dominantCount = 0;
  VERDICT_ORDER.forEach((verdict) => {
    if (tally[verdict] > dominantCount) {
      dominant = verdict;
      dominantCount = tally[verdict];
    }
  });

  // Trend: average total of the first half vs the second half of the window.
  const halfMark = Math.floor(count / 2);
  const firstHalf = totals.slice(0, halfMark || 1);
  const secondHalf = totals.slice(halfMark);
  const firstAvg =
    firstHalf.reduce((sum, value) => sum + value, 0) / firstHalf.length;
  const secondAvg =
    secondHalf.reduce((sum, value) => sum + value, 0) / secondHalf.length;
  const trendDelta = secondAvg - firstAvg;
  let trend: Trend = 'stable';
  if (trendDelta > TREND_MIN_MS) {
    trend = 'rising';
  } else if (trendDelta < -TREND_MIN_MS) {
    trend = 'falling';
  }

  // Spikes: RTT samples standing well above the window average.
  let spikeCount = 0;
  let spikeMax = 0;
  rtts.forEach((rtt) => {
    const above = rtt - windowAvgRtt;
    if (isSpike(above, windowAvgRtt)) {
      spikeCount += 1;
      if (above > spikeMax) {
        spikeMax = above;
      }
    }
  });

  // Spread and stability label.
  const min = Math.min(...totals);
  const max = Math.max(...totals);
  const avg = totals.reduce((sum, value) => sum + value, 0) / count;
  const spread = max - min;
  const ratio = avg > 0 ? spread / avg : 0;
  let stability: Stability = 'stable';
  if (ratio >= STABILITY_ROUGH_RATIO) {
    stability = 'rough';
  } else if (ratio >= STABILITY_STABLE_RATIO) {
    stability = 'moderate';
  }

  return {
    count,
    dominant,
    dominantCount,
    trend,
    spikeCount,
    spikeMax: round1(spikeMax),
    min: round1(min),
    avg: round1(avg),
    max: round1(max),
    stability,
  };
};
