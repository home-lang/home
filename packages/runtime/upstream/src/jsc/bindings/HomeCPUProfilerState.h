#pragma once
#include <JavaScriptCore/VM.h>
namespace Bun {
void setSamplingIntervalForVM(JSC::VM&, int);
bool isCPUProfilerRunningForVM(JSC::VM&);
}
extern "C" void Home__CPUProfiler__setSamplingInterval(JSC::VM*, int);
extern "C" void Home__CPUProfiler__cancelForVM(JSC::VM*);
