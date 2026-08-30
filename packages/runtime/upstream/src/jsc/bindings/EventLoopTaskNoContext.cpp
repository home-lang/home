#include "EventLoopTaskNoContext.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>

namespace Bun {

static std::atomic<uint64_t> homeProbeStartedCount { 0 };
static std::atomic<uint64_t> homeProbeCompletedCount { 0 };
static std::mutex homeProbeMutex;
static std::condition_variable homeProbeCondition;
static uint64_t homeProbeReleaseGeneration { 0 };

extern "C" void ConcurrentCppTask__createAndRun(EventLoopTaskNoContext* task);

extern "C" void Bun__EventLoopTaskNoContext__performTask(EventLoopTaskNoContext* task)
{
    task->performTask();
}

extern "C" void* Bun__EventLoopTaskNoContext__createdInBunVm(const EventLoopTaskNoContext* task)
{
    return task->createdInBunVm();
}

extern "C" void Home__EventLoopTaskNoContext__cancel(EventLoopTaskNoContext* task)
{
    delete task;
}

extern "C" void Home__EventLoopTaskNoContext__enqueueShutdownProbe(JSC::JSGlobalObject* globalObject)
{
    uint64_t generation;
    {
        std::lock_guard lock(homeProbeMutex);
        generation = homeProbeReleaseGeneration;
    }
    ConcurrentCppTask__createAndRun(new EventLoopTaskNoContext(globalObject, [generation] {
        homeProbeStartedCount.fetch_add(1, std::memory_order_seq_cst);
        std::unique_lock lock(homeProbeMutex);
        homeProbeCondition.wait(lock, [generation] { return homeProbeReleaseGeneration != generation; });
        homeProbeCompletedCount.fetch_add(1, std::memory_order_seq_cst);
    }));
}

extern "C" void Home__EventLoopTaskNoContext__releaseShutdownProbes()
{
    {
        std::lock_guard lock(homeProbeMutex);
        ++homeProbeReleaseGeneration;
    }
    homeProbeCondition.notify_all();
}

extern "C" uint64_t Home__EventLoopTaskNoContext__probeStartedCount()
{
    return homeProbeStartedCount.load(std::memory_order_seq_cst);
}

extern "C" uint64_t Home__EventLoopTaskNoContext__probeCompletedCount()
{
    return homeProbeCompletedCount.load(std::memory_order_seq_cst);
}

} // namespace Bun
