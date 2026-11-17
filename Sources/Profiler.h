#ifndef THREAD_PROFILER_H
#define THREAD_PROFILER_H

#include <stdbool.h>
#include <stdint.h>

typedef struct TPProfiler TPProfiler;

typedef struct {
    uint64_t samples;
    uint64_t threads;
    uint64_t frames;
    uint64_t failures;
    uint64_t truncatedStacks;
    double suspensionSeconds;
    double maxSuspensionSeconds;
    double suspendCallsSeconds;
    double stackCaptureSeconds;
    double resumeCallsSeconds;
} TPProfilerStats;

TPProfiler * _Nullable TPProfilerCreate(void);
int TPProfilerStart(TPProfiler * _Nonnull profiler);
TPProfilerStats TPProfilerStop(TPProfiler * _Nonnull profiler);
// Read after stopping. The buffer remains valid until the next start or destruction.
const double * _Nonnull TPProfilerPauseDurations(const TPProfiler * _Nonnull profiler);
void TPProfilerDestroy(TPProfiler * _Nonnull profiler);
double TPProcessCPUSeconds(void);

#endif
