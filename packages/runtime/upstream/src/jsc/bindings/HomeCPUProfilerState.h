#pragma once
#include <JavaScriptCore/VM.h>
#include <wtf/JSONValues.h>
namespace Bun {
void setSamplingIntervalForVM(JSC::VM&, int);
bool isCPUProfilerRunningForVM(JSC::VM&);
void registerCPUProfilerConsumer(JSC::VM&, const void*, int);
void unregisterCPUProfilerConsumer(JSC::VM&, const void*);
Ref<JSON::Object> captureCPUProfilerSamples(JSC::VM&);
}
extern "C" void Home__CPUProfiler__setSamplingInterval(JSC::VM*, int);
extern "C" void Home__CPUProfiler__cancelForVM(JSC::VM*);
