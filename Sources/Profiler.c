#include "Profiler.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/resource.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#define MAX_THREADS 128
#define MAX_FRAMES 64
#define MAX_SAMPLES 256

typedef struct {
    unsigned count;
    // Keep the capture writes observable even though stacks are overwritten at the next sample.
    volatile uintptr_t frames[MAX_FRAMES];
} ThreadSample;

struct TPProfiler {
    pthread_t worker;
    atomic_bool running;
    atomic_bool ready;
    bool started;
    double secondsPerTick;
    uint64_t interval;
    TPProfilerStats stats;
    ThreadSample stacks[MAX_THREADS];
    double pauseDurations[MAX_SAMPLES];
};

static uintptr_t stripAddress(uintptr_t address)
{
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
#else
    return address;
#endif
}

static void captureThread(thread_t thread, ThreadSample *sample, TPProfilerStats *stats)
{
    uintptr_t pc = 0, fp = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) {
        stats->failures++;
        return;
    }
    pc = arm_thread_state64_get_pc(state);
    fp = arm_thread_state64_get_fp(state);
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) {
        stats->failures++;
        return;
    }
    pc = state.__rip;
    fp = state.__rbp;
#else
#error Unsupported profiling architecture
#endif
    sample->count = 0;
    if (pc != 0) {
        sample->frames[sample->count++] = stripAddress(pc);
    }
    while (fp != 0 && sample->count < MAX_FRAMES) {
        struct { uintptr_t previous, address; } frame;
        vm_size_t copied = 0;
        if ((fp & (sizeof(uintptr_t) - 1)) != 0 ||
            vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof(frame),
                (vm_address_t)&frame, &copied) != KERN_SUCCESS || copied != sizeof(frame)) {
            break;
        }
        if (frame.address == 0) {
            break;
        }
        sample->frames[sample->count++] = stripAddress(frame.address);
        if (frame.previous <= fp || frame.previous - fp > 8 * 1024 * 1024) {
            break;
        }
        fp = frame.previous;
    }
    stats->frames += sample->count;
    if (sample->count == MAX_FRAMES) {
        stats->truncatedStacks++;
    }
}

static void captureSample(TPProfiler *profiler, thread_t self)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        profiler->stats.failures++;
        return;
    }
    if (count <= MAX_THREADS && profiler->stats.samples < MAX_SAMPLES) {
        bool suspended[MAX_THREADS] = { false };
        unsigned capturedThreads = 0;

        // No allocation, locks, logging, symbolication, or Swift/ObjC calls until every thread resumes.
        uint64_t started = mach_absolute_time();
        for (unsigned i = 0; i < count; i++) {
            if (threads[i] != self) {
                suspended[i] = thread_suspend(threads[i]) == KERN_SUCCESS;
                if (!suspended[i]) {
                    profiler->stats.failures++;
                }
            }
        }
        uint64_t suspendedAt = mach_absolute_time();
        for (unsigned i = 0; i < count; i++) {
            if (suspended[i]) {
                captureThread(threads[i], &profiler->stacks[capturedThreads++], &profiler->stats);
            }
        }
        uint64_t capturedAt = mach_absolute_time();
        for (unsigned i = 0; i < count; i++) {
            if (suspended[i] && thread_resume(threads[i]) != KERN_SUCCESS) {
                profiler->stats.failures++;
            }
        }
        uint64_t ended = mach_absolute_time();
        // Suspension window ends here. All successfully suspended threads have been resumed.

        double duration = (ended - started) * profiler->secondsPerTick;
        profiler->pauseDurations[profiler->stats.samples] = duration;
        profiler->stats.suspendCallsSeconds += (suspendedAt - started) * profiler->secondsPerTick;
        profiler->stats.stackCaptureSeconds += (capturedAt - suspendedAt) * profiler->secondsPerTick;
        profiler->stats.resumeCallsSeconds += (ended - capturedAt) * profiler->secondsPerTick;
        profiler->stats.suspensionSeconds += duration;
        if (duration > profiler->stats.maxSuspensionSeconds) {
            profiler->stats.maxSuspensionSeconds = duration;
        }
        profiler->stats.threads += capturedThreads;
        profiler->stats.samples++;
    } else {
        profiler->stats.failures++;
    }
    for (unsigned i = 0; i < count; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
}

static void *sampleLoop(void *argument)
{
    TPProfiler *profiler = argument;
    pthread_setname_np("benchmark.profiler.50ms");
    thread_t self = mach_thread_self();

    // Prime Mach RPC paths on this thread before suspending threads that might hold runtime locks.
    ThreadSample warmup = { 0 };
    TPProfilerStats ignored = { 0 };
    captureThread(self, &warmup, &ignored);
    thread_suspend(MACH_PORT_NULL);
    thread_resume(MACH_PORT_NULL);
    struct { uintptr_t previous, address; } frame;
    vm_size_t copied = 0;
    vm_read_overwrite(mach_task_self(), (vm_address_t)&frame, sizeof(frame),
        (vm_address_t)&frame, &copied);

    uint64_t deadline = mach_absolute_time() + profiler->interval;
    atomic_store_explicit(&profiler->ready, true, memory_order_release);
    while (atomic_load_explicit(&profiler->running, memory_order_relaxed)) {
        mach_wait_until(deadline);
        if (!atomic_load_explicit(&profiler->running, memory_order_relaxed)) {
            break;
        }
        captureSample(profiler, self);
        uint64_t now = mach_absolute_time();
        do {
            deadline += profiler->interval;
        } while (deadline <= now); // Skip missed sample deadlines instead of creating a catch-up burst.
    }
    mach_port_deallocate(mach_task_self(), self);
    return NULL;
}

TPProfiler *TPProfilerCreate(void)
{
    TPProfiler *profiler = calloc(1, sizeof(TPProfiler));
    if (profiler == NULL) {
        return NULL;
    }
    // Fault in sample storage before measurement, never for the first time in the suspension window.
    volatile unsigned char *bytes = (volatile unsigned char *)profiler;
    for (size_t i = 0; i < sizeof(TPProfiler); i += 4096) {
        bytes[i] = 0;
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    profiler->secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    profiler->interval = (uint64_t)(0.050 / profiler->secondsPerTick);
    atomic_init(&profiler->running, false);
    atomic_init(&profiler->ready, false);
    return profiler;
}

int TPProfilerStart(TPProfiler *profiler)
{
    if (profiler->started) {
        return 0;
    }
    profiler->stats = (TPProfilerStats){ 0 };
    atomic_store(&profiler->ready, false);
    atomic_store(&profiler->running, true);
    int result = pthread_create(&profiler->worker, NULL, sampleLoop, profiler);
    profiler->started = result == 0;
    if (result != 0) {
        atomic_store(&profiler->running, false);
    } else {
        // Complete worker initialization before the caller starts its measurement window.
        while (!atomic_load_explicit(&profiler->ready, memory_order_acquire)) {
            mach_wait_until(mach_absolute_time() + profiler->interval / 50);
        }
    }
    return result;
}

TPProfilerStats TPProfilerStop(TPProfiler *profiler)
{
    if (profiler->started) {
        atomic_store(&profiler->running, false);
        pthread_join(profiler->worker, NULL);
        profiler->started = false;
    }
    return profiler->stats;
}

const double *TPProfilerPauseDurations(const TPProfiler *profiler)
{
    return profiler->pauseDurations;
}

void TPProfilerDestroy(TPProfiler *profiler)
{
    TPProfilerStop(profiler);
    free(profiler);
}

double TPProcessCPUSeconds(void)
{
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6
        + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}
