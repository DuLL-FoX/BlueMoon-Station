// Auto-profiler spike detection thresholds

/// Spike severity levels
#define SPIKE_SEVERITY_MINOR 1
#define SPIKE_SEVERITY_MAJOR 2

/// Minor spike: noticeable lag, logged silently
#define SPIKE_MINOR_THRESHOLD 10
#define SPIKE_MINOR_MULTIPLIER 1.5
#define SPIKE_MINOR_COOLDOWN 600 // 60 seconds

/// Major spike: severe lag, logged + admin notification
#define SPIKE_MAJOR_THRESHOLD 25
#define SPIKE_MAJOR_MULTIPLIER 2.5
#define SPIKE_MAJOR_COOLDOWN 1200 // 120 seconds

/// Max entries in the profiler's top-N buffer (sent to TGUI)
#define PROFILER_BUFFER_MAX 200
