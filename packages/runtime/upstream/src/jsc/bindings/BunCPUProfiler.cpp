#include "root.h"
#include "BunCPUProfiler.h"
#include "HomeCPUProfilerState.h"
#include <mutex>
#include <unordered_map>
#include "ZigGlobalObject.h"
#include "helpers.h"
#include "BunString.h"
#include <JavaScriptCore/SamplingProfiler.h>
#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ScriptExecutable.h>
#include <JavaScriptCore/FunctionExecutable.h>
#include <JavaScriptCore/SourceProvider.h>
#include <wtf/Stopwatch.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/JSONValues.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/URL.h>
#include <algorithm>
#include <limits>

extern "C" void Bun__startCPUProfiler(JSC::VM* vm);
extern "C" void Bun__stopCPUProfiler(JSC::VM* vm, BunString* outJSON, BunString* outText);
extern "C" void Bun__setSamplingInterval(int intervalMicroseconds);

void Bun__setSamplingInterval(int intervalMicroseconds)
{
    Bun::setSamplingInterval(intervalMicroseconds);
}

namespace Bun {

// Detached records are safe across sample consumers and GC: no engine cell or
// executable pointer survives the capture's DeferGC scope.
struct HomeCPUFrame {
    WTF::String name, textName, url, textURL;
    int scriptId { 0 }, line { -1 }, column { -1 }, sampleLine { 0 }, textLine { -1 };
};
struct HomeCPUTrace {
    MonotonicTime timestamp;
    WTF::Vector<HomeCPUFrame> frames;
};
struct HomeCPUProfilerState {
    double startTime { 0 };
    MonotonicTime nativeStart;
    int interval { 1000 };
    bool running { false };
    bool nativeOwner { false };
    std::unordered_map<const void*, int> consumers;
    WTF::Vector<HomeCPUTrace> nativeSamples;
    WTF::Vector<HomeCPUTrace> inspectorSamples;
};
static std::mutex profilerStateLock;
static std::unordered_map<JSC::VM*, HomeCPUProfilerState> profilerStates;
// Preserve the old C ABI for external callers, without sharing its defaults
// across worker threads. Home entry points use the explicit VM contract.
static thread_local int pendingInterval = 1000;
static thread_local JSC::VM* legacyProfilerVM = nullptr;
void setSamplingInterval(int intervalMicroseconds) { pendingInterval = intervalMicroseconds; }
void setSamplingIntervalForVM(JSC::VM& vm, int interval) {
    std::lock_guard lock(profilerStateLock);
    profilerStates[&vm].interval = interval;
}
bool isCPUProfilerRunningForVM(JSC::VM& vm) {
    std::lock_guard lock(profilerStateLock);
    auto entry = profilerStates.find(&vm);
    return entry != profilerStates.end() && entry->second.running;
}
bool isCPUProfilerRunning() { return legacyProfilerVM && isCPUProfilerRunningForVM(*legacyProfilerVM); }

static void updateProfilerInterval(JSC::VM& vm) {
    int interval = std::numeric_limits<int>::max();
    {
        std::lock_guard lock(profilerStateLock);
        auto& state = profilerStates[&vm];
        if (state.nativeOwner) interval = state.interval;
        for (const auto& owner : state.consumers) interval = std::min(interval, owner.second);
    }
    if (auto* profiler = vm.samplingProfiler()) {
        WTF::Locker lock { profiler->getLock() };
        profiler->setTimingInterval(WTF::Seconds::fromMicroseconds(interval));
    }
}
static void ensureCPUProfiler(JSC::VM& vm)
{
    HomeCPUProfilerState state;
    {
        std::lock_guard lock(profilerStateLock);
        auto [entry, inserted] = profilerStates.try_emplace(&vm);
        if (inserted) entry->second.interval = pendingInterval;
        if (entry->second.running) return;
        entry->second.startTime = MonotonicTime::now().approximate<WTF::WallTime>().secondsSinceEpoch().value() * 1000000.0;
        state.interval = entry->second.interval;
    }
    legacyProfilerVM = &vm;

    // Create a stopwatch and start it
    auto stopwatch = WTF::Stopwatch::create();
    stopwatch->start();

    JSC::SamplingProfiler& samplingProfiler = vm.ensureSamplingProfiler(WTF::move(stopwatch));
    samplingProfiler.setTimingInterval(WTF::Seconds::fromMicroseconds(state.interval));
    samplingProfiler.noticeCurrentThreadAsJSCExecutionThread();
    samplingProfiler.start();
    { std::lock_guard lock(profilerStateLock); profilerStates[&vm].running = true; }
}

void startCPUProfiler(JSC::VM& vm) {
    JSC::JSLockHolder locker(vm);
    {
        std::lock_guard lock(profilerStateLock);
        auto [entry, inserted] = profilerStates.try_emplace(&vm);
        auto& state = entry->second;
        if (inserted) state.interval = pendingInterval;
        if (state.nativeOwner) return;
        state.nativeOwner = true;
        state.nativeStart = MonotonicTime::now();
        state.startTime = MonotonicTime::now().approximate<WTF::WallTime>().secondsSinceEpoch().value() * 1000000.0;
    }
    ensureCPUProfiler(vm);
    updateProfilerInterval(vm);
}
void registerCPUProfilerConsumer(JSC::VM& vm, const void* owner, int interval) {
    { std::lock_guard lock(profilerStateLock); profilerStates[&vm].consumers[owner] = interval; }
    ensureCPUProfiler(vm);
    updateProfilerInterval(vm);
}
void unregisterCPUProfilerConsumer(JSC::VM& vm, const void* owner) {
    bool stop = false;
    {
        std::lock_guard lock(profilerStateLock);
        auto found = profilerStates.find(&vm);
        if (found == profilerStates.end()) return;
        found->second.consumers.erase(owner);
        stop = !found->second.nativeOwner && found->second.consumers.empty();
        if (stop) { found->second.running = false; found->second.inspectorSamples.clear(); }
    }
    if (stop) {
        if (auto* profiler = vm.samplingProfiler()) {
            WTF::Locker lock { profiler->getLock() };
            profiler->pause(); profiler->clearData();
        }
    } else updateProfilerInterval(vm);
}
static WTF::Vector<HomeCPUTrace> detachCPUProfilerSamples(JSC::VM&, WTF::Vector<JSC::SamplingProfiler::StackTrace>&&);
Ref<JSON::Object> captureCPUProfilerSamples(JSC::VM& vm) {
    JSC::JSLockHolder locker(vm);
    JSC::DeferGC deferGC(vm);
    auto result = JSON::Object::create();
    auto tracesJSON = JSON::Array::create();
    auto* profiler = vm.samplingProfiler();
    if (!profiler) { result->setArray("traces"_s, WTF::move(tracesJSON)); return result; }
    WTF::Locker profilerLocker { profiler->getLock() };
    auto traces = detachCPUProfilerSamples(vm, profiler->releaseStackTraces());
    {
        std::lock_guard lock(profilerStateLock);
        auto& pending = profilerStates[&vm].inspectorSamples;
        traces.appendVector(WTF::move(pending));
        pending.clear();
    }
    for (auto& trace : traces) {
        auto encodedTrace = JSON::Object::create();
        encodedTrace->setDouble("timestamp"_s, trace.timestamp.secondsSinceEpoch().seconds());
        auto frames = JSON::Array::create();
        for (auto& frame : trace.frames) {
            auto encodedFrame = JSON::Object::create();
            encodedFrame->setString("name"_s, frame.name);
            encodedFrame->setString("scriptId"_s, WTF::String::number(frame.scriptId));
            encodedFrame->setString("sourceURL"_s, frame.url);
            encodedFrame->setInteger("line"_s, frame.line);
            encodedFrame->setInteger("column"_s, frame.column);
            frames->pushObject(WTF::move(encodedFrame));
        }
        encodedTrace->setArray("frames"_s, WTF::move(frames));
        tracesJSON->pushObject(WTF::move(encodedTrace));
    }
    {
        std::lock_guard lock(profilerStateLock);
        auto& state = profilerStates[&vm];
        if (state.nativeOwner) {
            for (auto& trace : traces) if (trace.timestamp >= state.nativeStart) state.nativeSamples.append(WTF::move(trace));
        }
    }
    result->setArray("traces"_s, WTF::move(tracesJSON));
    return result;
}

struct ProfileNode {
    int id;
    WTF::String functionName;
    WTF::String url;
    int scriptId;
    // lineNumber/columnNumber are the location where the function is DEFINED
    // (matching Node/Deno/Chrome DevTools), stored as 0-indexed values ready
    // for JSON emission. -1 means "unknown".
    int lineNumber;
    int columnNumber;
    int hitCount;
    WTF::Vector<int> children;
    // Per-line sample counts for this node, keyed by 1-indexed source line.
    // Emitted as `positionTicks` in the JSON output when non-empty, matching
    // the Chrome DevTools CPU profile format used by Node and Deno.
    // Lines are guaranteed non-zero, so the default IntHashTraits (which reserve
    // 0 and -1 as empty/deleted sentinels) are safe here.
    WTF::HashMap<int, int, WTF::IntHash<int>> positionTicks;
};

// ============================================================================
// TEXT FORMAT OUTPUT (grep-friendly, designed for LLM analysis)
// ============================================================================

// Structure to hold aggregated function statistics for text output
struct FunctionStats {
    WTF::String functionName;
    WTF::String location; // file:line format
    long long selfTimeUs = 0; // microseconds where this function was at top of stack
    long long totalTimeUs = 0; // microseconds including children
    int selfSamples = 0; // samples where this function was at top
    int totalSamples = 0; // samples where this function appeared anywhere
    WTF::HashMap<WTF::String, int> callers; // caller location -> count
    WTF::HashMap<WTF::String, int> callees; // callee location -> count
};

// Helper to format a function name properly
// - Empty names become "(anonymous)"
// - Async functions get "async " prefix
static WTF::String formatFunctionName(const WTF::String& name, const JSC::SamplingProfiler::StackFrame& frame)
{
    WTF::String displayName = name.isEmpty() ? "(anonymous)"_s : name;

    // Check if this is an async function and add prefix if needed
    if (frame.frameType == JSC::SamplingProfiler::FrameType::Executable && frame.executable) {
        if (auto* functionExecutable = dynamicDowncast<JSC::FunctionExecutable>(frame.executable)) {
            if (JSC::isAsyncFunctionParseMode(functionExecutable->parseMode())) {
                if (!displayName.startsWith("async "_s)) {
                    return makeString("async "_s, displayName);
                }
            }
        }
    }

    return displayName;
}

static WTF::Vector<HomeCPUTrace> detachCPUProfilerSamples(JSC::VM& vm, WTF::Vector<JSC::SamplingProfiler::StackTrace>&& input) {
    WTF::Vector<HomeCPUTrace> output;
    for (auto& trace : input) {
        HomeCPUTrace detached;
        detached.timestamp = trace.timestamp;
        for (auto& frame : trace.frames) {
            HomeCPUFrame record;
            record.name = frame.displayName(vm);
            record.textName = formatFunctionName(record.name, frame);
            WTF::String url;
            int scriptId = 0, functionDefLine = -1, functionDefColumn = -1, sampleLine = 0;
            if (frame.frameType == JSC::SamplingProfiler::FrameType::Executable && frame.executable) {
                auto sourceProviderAndID = frame.sourceProviderAndID();
                auto* provider = std::get<0>(sourceProviderAndID);
                if (provider) {
                    url = provider->sourceURL();
                    scriptId = static_cast<int>(provider->asID());
                }

                auto normalizeURL = [](WTF::String& u) {
                    if (u.isEmpty())
                        return;
                    bool isAbsolutePath = false;
                    if (u[0] == '/') {
                        isAbsolutePath = true;
                    } else if (u.length() >= 2 && u[1] == ':') {
                        char firstChar = u[0];
                        if ((firstChar >= 'A' && firstChar <= 'Z') || (firstChar >= 'a' && firstChar <= 'z'))
                            isAbsolutePath = true;
                    } else if (u.length() >= 2 && u[0] == '\\' && u[1] == '\\') {
                        isAbsolutePath = true;
                    }
                    if (isAbsolutePath)
                        u = WTF::URL::fileURLWithFileSystemPath(u).string();
                };

                int rawFunctionStartLine = frame.functionStartLine();
                unsigned rawFunctionStartColumn = frame.functionStartColumn();
                if (rawFunctionStartLine > 0 && rawFunctionStartColumn != std::numeric_limits<unsigned>::max()) {
                    JSC::LineColumn functionStartLineColumn {
                        static_cast<unsigned>(rawFunctionStartLine),
                        rawFunctionStartColumn,
                    };
                    if (provider) {
#if USE(BUN_JSC_ADDITIONS)
                        auto& fn = vm.computeLineColumnWithSourcemap();
                        if (fn) {
                            fn(vm, provider, functionStartLineColumn, url);
                        }
#endif
                    }
                    functionDefLine = functionStartLineColumn.line > 0
                        ? static_cast<int>(functionStartLineColumn.line) - 1
                        : 0;
                    functionDefColumn = functionStartLineColumn.column > 0
                        ? static_cast<int>(functionStartLineColumn.column) - 1
                        : 0;
                }

                normalizeURL(url);

                if (frame.hasExpressionInfo()) {
                    JSC::LineColumn sourceMappedLineColumn = frame.semanticLocation.lineColumn;
                    WTF::String sampleURL = provider ? WTF::String(provider->sourceURL()) : WTF::String();
                    if (provider) {
#if USE(BUN_JSC_ADDITIONS)
                        auto& fn = vm.computeLineColumnWithSourcemap();
                        if (fn) {
                            fn(vm, provider, sourceMappedLineColumn, sampleURL);
                        }
#endif
                    }
                    normalizeURL(sampleURL);
                    if (sourceMappedLineColumn.line > 0 && sampleURL == url)
                        sampleLine = static_cast<int>(sourceMappedLineColumn.line);
                }
            }

            record.url = url; record.scriptId = scriptId;
            record.line = functionDefLine; record.column = functionDefColumn; record.sampleLine = sampleLine;
            url = WTF::String();
            int lineNumber = -1;
            if (frame.frameType == JSC::SamplingProfiler::FrameType::Executable && frame.executable) {
                auto sourceProviderAndID = frame.sourceProviderAndID();
                auto* provider = std::get<0>(sourceProviderAndID);
                if (provider) {
                    url = provider->sourceURL();

                    bool isAbsolutePath = false;
                    if (!url.isEmpty()) {
                        if (url[0] == '/')
                            isAbsolutePath = true;
                        else if (url.length() >= 2 && url[1] == ':') {
                            char firstChar = url[0];
                            if ((firstChar >= 'A' && firstChar <= 'Z') || (firstChar >= 'a' && firstChar <= 'z'))
                                isAbsolutePath = true;
                        } else if (url.length() >= 2 && url[0] == '\\' && url[1] == '\\')
                            isAbsolutePath = true;
                    }
                    if (isAbsolutePath)
                        url = WTF::URL::fileURLWithFileSystemPath(url).string();
                }

                if (frame.hasExpressionInfo()) {
                    JSC::LineColumn sourceMappedLineColumn = frame.semanticLocation.lineColumn;
                    if (provider) {
#if USE(BUN_JSC_ADDITIONS)
                        auto& fn = vm.computeLineColumnWithSourcemap();
                        if (fn)
                            fn(vm, provider, sourceMappedLineColumn, url);
#endif
                    }
                    lineNumber = static_cast<int>(sourceMappedLineColumn.line);
                }
            }

            record.textURL = url; record.textLine = lineNumber;
            detached.frames.append(WTF::move(record));
        }
        output.append(WTF::move(detached));
    }
    return output;
}

// Helper to format a location string from URL and line number
static WTF::String formatLocation(const WTF::String& url, int lineNumber)
{
    if (url.isEmpty())
        return "[native code]"_s;

    // Extract path from file:// URL using WTF::URL
    WTF::String path = url;
    WTF::URL parsedUrl { url };
    if (parsedUrl.isValid() && parsedUrl.protocolIsFile())
        path = parsedUrl.fileSystemPath();

    if (lineNumber >= 0) {
        WTF::StringBuilder sb;
        sb.append(path);
        sb.append(':');
        sb.append(lineNumber);
        return sb.toString();
    }
    return path;
}

// Helper to format time in human-readable form
static WTF::String formatTime(double microseconds)
{
    WTF::StringBuilder sb;
    if (microseconds >= 1000000.0) {
        // Format as seconds with 2 decimal places
        double seconds = microseconds / 1000000.0;
        sb.append(static_cast<int>(seconds));
        sb.append('.');
        int frac = static_cast<int>((seconds - static_cast<int>(seconds)) * 100);
        if (frac < 10) sb.append('0');
        sb.append(frac);
        sb.append('s');
        return sb.toString();
    }
    if (microseconds >= 1000.0) {
        // Format as milliseconds with 1 decimal place
        double ms = microseconds / 1000.0;
        sb.append(static_cast<int>(ms));
        sb.append('.');
        int frac = static_cast<int>((ms - static_cast<int>(ms)) * 10);
        sb.append(frac);
        sb.append("ms"_s);
        return sb.toString();
    }
    sb.append(static_cast<int>(microseconds));
    sb.append("us"_s);
    return sb.toString();
}

// Helper to format percentage
static WTF::String formatPercent(double value, double total)
{
    if (total <= 0)
        return "0.0%"_s;
    double pct = (value / total) * 100.0;
    // Cap at 100% for display purposes (can exceed 100% due to rounding or overlapping time accounting)
    if (pct > 100.0)
        pct = 100.0;
    WTF::StringBuilder sb;
    // Format as XX.X% with 1 decimal place
    sb.append(static_cast<int>(pct));
    sb.append('.');
    int frac = static_cast<int>((pct - static_cast<int>(pct)) * 10);
    sb.append(frac);
    sb.append('%');
    return sb.toString();
}

// Key separator for building composite keys (function name + location)
// Using ASCII control character SOH (0x01) which won't appear in function names or URLs
static constexpr auto kKeySeparator = "\x01"_s;

// Helper to escape pipe characters for markdown table cells (non-code cells)
static WTF::String escapeMarkdownTableCell(const WTF::String& str)
{
    bool needsEscape = false;
    for (unsigned i = 0; i < str.length(); i++) {
        if (str[i] == '|') {
            needsEscape = true;
            break;
        }
    }
    if (!needsEscape)
        return str;

    WTF::StringBuilder sb;
    for (unsigned i = 0; i < str.length(); i++) {
        UChar c = str[i];
        if (c == '|')
            sb.append("\\|"_s);
        else
            sb.append(c);
    }
    return sb.toString();
}

// Helper to format a string as an inline code span that handles backticks properly
// Uses the CommonMark spec: use N+1 backticks as delimiter where N is the longest run of backticks in the string
static WTF::String formatCodeSpan(const WTF::String& str)
{
    // Also escape pipes since this will be used in table cells
    WTF::String escaped = escapeMarkdownTableCell(str);

    // Find the longest run of backticks in the string
    int maxBackticks = 0;
    int currentRun = 0;
    for (unsigned i = 0; i < escaped.length(); i++) {
        if (escaped[i] == '`') {
            currentRun++;
            if (currentRun > maxBackticks)
                maxBackticks = currentRun;
        } else {
            currentRun = 0;
        }
    }

    // If no backticks, use simple single backtick delimiters
    if (maxBackticks == 0) {
        WTF::StringBuilder sb;
        sb.append('`');
        sb.append(escaped);
        sb.append('`');
        return sb.toString();
    }

    // Use N+1 backticks as delimiter
    int delimiterLength = maxBackticks + 1;
    WTF::StringBuilder sb;
    for (int i = 0; i < delimiterLength; i++)
        sb.append('`');

    // Add space padding if content starts or ends with backtick (CommonMark requirement)
    bool startsWithBacktick = !escaped.isEmpty() && escaped[0] == '`';
    bool endsWithBacktick = !escaped.isEmpty() && escaped[escaped.length() - 1] == '`';

    if (startsWithBacktick || endsWithBacktick)
        sb.append(' ');
    sb.append(escaped);
    if (startsWithBacktick || endsWithBacktick)
        sb.append(' ');

    for (int i = 0; i < delimiterLength; i++)
        sb.append('`');

    return sb.toString();
}

// Helper to generate a minimal valid cpuprofile JSON with no samples
static WTF::String generateEmptyProfileJSON(double startTime)
{
    // Return a minimal valid Chrome DevTools CPU profile format
    // Use startTime if available, otherwise fall back to current time
    long long timestamp;
    if (startTime > 0)
        timestamp = static_cast<long long>(startTime);
    else
        timestamp = static_cast<long long>(WTF::WallTime::now().secondsSinceEpoch().value() * 1000000.0);

    WTF::StringBuilder sb;
    sb.append("{\"nodes\":[{\"id\":1,\"callFrame\":{\"functionName\":\"(root)\",\"scriptId\":\"0\",\"url\":\"\",\"lineNumber\":-1,\"columnNumber\":-1},\"hitCount\":0,\"children\":[]}],\"startTime\":"_s);
    sb.append(timestamp);
    sb.append(",\"endTime\":"_s);
    sb.append(timestamp);
    sb.append(",\"samples\":[],\"timeDeltas\":[]}"_s);
    return sb.toString();
}

// Unified function that stops the profiler and generates requested output formats
void stopCPUProfiler(JSC::VM& vm, WTF::String* outJSON, WTF::String* outText)
{
    HomeCPUProfilerState state;
    {
        std::lock_guard lock(profilerStateLock);
        auto entry = profilerStates.find(&vm);
        if (entry == profilerStates.end() || !entry->second.nativeOwner) {
            if (outJSON) *outJSON = generateEmptyProfileJSON(entry == profilerStates.end() ? 0 : entry->second.startTime);
            if (outText) *outText = "No samples collected.\n"_s;
            return;
        }
        if (entry != profilerStates.end()) {
            entry->second.nativeOwner = false;
            entry->second.running = !entry->second.consumers.empty();
            state = WTF::move(entry->second);
            entry->second = HomeCPUProfilerState();
            entry->second.startTime = state.startTime;
            entry->second.nativeStart = state.nativeStart;
            entry->second.interval = state.interval;
            entry->second.running = state.running;
            entry->second.consumers = WTF::move(state.consumers);
            entry->second.inspectorSamples = WTF::move(state.inspectorSamples);
        }
    }

    JSC::SamplingProfiler* profiler = vm.samplingProfiler();
    if (!profiler) {
        if (outJSON) *outJSON = WTF::String();
        if (outText) *outText = WTF::String();
        return;
    }

    // JSLock is re-entrant, so always acquiring it handles both JS and shutdown contexts
    JSC::JSLockHolder locker(vm);

    // Defer GC while we're working with stack traces
    JSC::DeferGC deferGC(vm);

    // Pause the profiler while holding the lock
    auto& lock = profiler->getLock();
    WTF::Locker profilerLocker { lock };
    if (!state.running) profiler->pause();

    // releaseStackTraces() calls processUnverifiedStackTraces() internally
    auto stackTraces = WTF::move(state.nativeSamples);
    auto finalSamples = detachCPUProfilerSamples(vm, profiler->releaseStackTraces());
    if (state.running) {
        std::lock_guard stateLock(profilerStateLock);
        profilerStates[&vm].inspectorSamples.appendVector(finalSamples);
    }
    for (auto& trace : finalSamples) if (trace.timestamp >= state.nativeStart) stackTraces.append(WTF::move(trace));
    if (!state.running) profiler->clearData();
    else {
        int interval = std::numeric_limits<int>::max();
        { std::lock_guard stateLock(profilerStateLock);
          for (const auto& owner : profilerStates[&vm].consumers) interval = std::min(interval, owner.second); }
        profiler->setTimingInterval(WTF::Seconds::fromMicroseconds(interval));
    }

    // If neither output is requested, we're done
    if (!outJSON && !outText)
        return;

    if (stackTraces.isEmpty()) {
        if (outJSON) *outJSON = generateEmptyProfileJSON(state.startTime);
        if (outText) *outText = "No samples collected.\n"_s;
        return;
    }

    // Sort traces by timestamp once for both formats
    WTF::Vector<size_t> sortedIndices;
    sortedIndices.reserveInitialCapacity(stackTraces.size());
    for (size_t i = 0; i < stackTraces.size(); i++) {
        sortedIndices.append(i);
    }
    std::sort(sortedIndices.begin(), sortedIndices.end(), [&stackTraces](size_t a, size_t b) {
        return stackTraces[a].timestamp < stackTraces[b].timestamp;
    });

    // Generate JSON format if requested
    if (outJSON) {
        // Map from stack frame signature to node ID
        WTF::HashMap<WTF::String, int> nodeMap;
        WTF::Vector<ProfileNode> nodes;

        // Create root node
        ProfileNode rootNode;
        rootNode.id = 1;
        rootNode.functionName = "(root)"_s;
        rootNode.url = ""_s;
        rootNode.scriptId = 0;
        rootNode.lineNumber = -1;
        rootNode.columnNumber = -1;
        rootNode.hitCount = 0;
        nodes.append(WTF::move(rootNode));

        int nextNodeId = 2;
        WTF::Vector<int> samples;
        WTF::Vector<long long> timeDeltas;

        double startTime = state.startTime;
        double lastTime = state.startTime;

        for (size_t idx : sortedIndices) {
            auto& stackTrace = stackTraces[idx];
            if (stackTrace.frames.isEmpty()) {
                samples.append(1);
                double currentTime = stackTrace.timestamp.approximate<WTF::WallTime>().secondsSinceEpoch().value() * 1000000.0;
                double delta = std::max(0.0, currentTime - lastTime);
                timeDeltas.append(static_cast<long long>(delta));
                lastTime = currentTime;
                continue;
            }

            int currentParentId = 1;

            for (int i = stackTrace.frames.size() - 1; i >= 0; i--) {
                auto& frame = stackTrace.frames[i];

                WTF::String functionName = frame.name;
                WTF::String url = frame.url;
                int scriptId = frame.scriptId;
                int functionDefLine = frame.line;
                int functionDefColumn = frame.column;
                int sampleLine = frame.sampleLine;

                // line/column here identify the function's DEFINITION, so all
                // samples of the same function under the same parent collapse.
                WTF::StringBuilder keyBuilder;
                keyBuilder.append(currentParentId);
                keyBuilder.append(':');
                keyBuilder.append(functionName);
                keyBuilder.append(':');
                keyBuilder.append(url);
                keyBuilder.append(':');
                keyBuilder.append(scriptId);
                keyBuilder.append(':');
                keyBuilder.append(functionDefLine);
                keyBuilder.append(':');
                keyBuilder.append(functionDefColumn);

                WTF::String key = keyBuilder.toString();

                int nodeId;
                auto it = nodeMap.find(key);
                if (it == nodeMap.end()) {
                    nodeId = nextNodeId++;
                    nodeMap.add(key, nodeId);

                    ProfileNode node;
                    node.id = nodeId;
                    node.functionName = functionName;
                    node.url = url;
                    node.scriptId = scriptId;
                    node.lineNumber = functionDefLine;
                    node.columnNumber = functionDefColumn;
                    node.hitCount = 0;

                    nodes.append(WTF::move(node));

                    if (currentParentId > 0)
                        nodes[currentParentId - 1].children.append(nodeId);
                } else {
                    nodeId = it->value;
                }

                currentParentId = nodeId;

                if (i == 0) {
                    nodes[nodeId - 1].hitCount++;
                    if (sampleLine > 0)
                        nodes[nodeId - 1].positionTicks.add(sampleLine, 0).iterator->value++;
                }
            }

            samples.append(currentParentId);

            double currentTime = stackTrace.timestamp.approximate<WTF::WallTime>().secondsSinceEpoch().value() * 1000000.0;
            double delta = std::max(0.0, currentTime - lastTime);
            timeDeltas.append(static_cast<long long>(delta));
            lastTime = currentTime;
        }

        double endTime = lastTime;

        // Build JSON
        using namespace WTF;
        auto json = JSON::Object::create();

        auto nodesArray = JSON::Array::create();
        for (const auto& node : nodes) {
            auto nodeObj = JSON::Object::create();
            nodeObj->setInteger("id"_s, node.id);

            auto callFrame = JSON::Object::create();
            callFrame->setString("functionName"_s, node.functionName);
            callFrame->setString("scriptId"_s, WTF::String::number(node.scriptId));
            callFrame->setString("url"_s, node.url);
            callFrame->setInteger("lineNumber"_s, node.lineNumber);
            callFrame->setInteger("columnNumber"_s, node.columnNumber);

            nodeObj->setValue("callFrame"_s, callFrame);
            nodeObj->setInteger("hitCount"_s, node.hitCount);

            if (!node.children.isEmpty()) {
                auto childrenArray = JSON::Array::create();
                WTF::HashSet<int> seenChildren;
                for (int childId : node.children) {
                    if (seenChildren.add(childId).isNewEntry)
                        childrenArray->pushInteger(childId);
                }
                nodeObj->setValue("children"_s, childrenArray);
            }

            // Per-line sample counts (Chrome DevTools format). Emit sorted by
            // line for deterministic output.
            if (!node.positionTicks.isEmpty()) {
                WTF::Vector<std::pair<int, int>> sortedTicks;
                sortedTicks.reserveInitialCapacity(node.positionTicks.size());
                for (auto& entry : node.positionTicks)
                    sortedTicks.append({ entry.key, entry.value });
                std::sort(sortedTicks.begin(), sortedTicks.end(), [](const auto& a, const auto& b) {
                    return a.first < b.first;
                });
                auto positionTicksArray = JSON::Array::create();
                for (auto& [line, ticks] : sortedTicks) {
                    auto tickObj = JSON::Object::create();
                    tickObj->setInteger("line"_s, line);
                    tickObj->setInteger("ticks"_s, ticks);
                    positionTicksArray->pushValue(tickObj);
                }
                nodeObj->setValue("positionTicks"_s, positionTicksArray);
            }

            nodesArray->pushValue(nodeObj);
        }
        json->setValue("nodes"_s, nodesArray);

        json->setDouble("startTime"_s, startTime);
        json->setDouble("endTime"_s, endTime);

        auto samplesArray = JSON::Array::create();
        for (int sample : samples)
            samplesArray->pushInteger(sample);
        json->setValue("samples"_s, samplesArray);

        auto timeDeltasArray = JSON::Array::create();
        for (long long delta : timeDeltas)
            timeDeltasArray->pushInteger(delta);
        json->setValue("timeDeltas"_s, timeDeltasArray);

        *outJSON = json->toJSONString();
    }

    // Generate text format if requested
    if (outText) {
        double startTime = state.startTime;
        double lastTime = state.startTime;
        double endTime = startTime;

        WTF::HashMap<WTF::String, FunctionStats> functionStatsMap;

        long long totalTimeUs = 0;
        int totalSamples = static_cast<int>(stackTraces.size());

        for (size_t idx : sortedIndices) {
            auto& stackTrace = stackTraces[idx];

            double currentTime = stackTrace.timestamp.approximate<WTF::WallTime>().secondsSinceEpoch().value() * 1000000.0;
            long long deltaUs = static_cast<long long>(std::max(0.0, currentTime - lastTime));
            totalTimeUs += deltaUs;
            lastTime = currentTime;
            endTime = currentTime;

            if (stackTrace.frames.isEmpty())
                continue;

            WTF::String previousKey;

            for (int i = stackTrace.frames.size() - 1; i >= 0; i--) {
                auto& frame = stackTrace.frames[i];

                WTF::String functionName = frame.textName;
                WTF::String url = frame.textURL;
                int lineNumber = frame.textLine;

                WTF::String location = formatLocation(url, lineNumber);
                // Key uses zero-width space separator internally (not shown in output)
                WTF::StringBuilder keyBuilder;
                keyBuilder.append(functionName);
                keyBuilder.append(kKeySeparator);
                keyBuilder.append(location);
                WTF::String key = keyBuilder.toString();

                auto result = functionStatsMap.add(key, FunctionStats());
                FunctionStats& stats = result.iterator->value;
                if (result.isNewEntry) {
                    stats.functionName = functionName;
                    stats.location = location;
                }

                stats.totalSamples++;
                stats.totalTimeUs += deltaUs;

                if (i == 0) {
                    stats.selfSamples++;
                    stats.selfTimeUs += deltaUs;
                }

                if (!previousKey.isEmpty()) {
                    stats.callers.add(previousKey, 0).iterator->value++;

                    auto prevIt = functionStatsMap.find(previousKey);
                    if (prevIt != functionStatsMap.end())
                        prevIt->value.callees.add(key, 0).iterator->value++;
                }

                previousKey = key;
            }
        }

        // Sort functions by self time
        WTF::Vector<std::pair<WTF::String, FunctionStats*>> sortedBySelf;
        for (auto& entry : functionStatsMap)
            sortedBySelf.append({ entry.key, &entry.value });
        std::sort(sortedBySelf.begin(), sortedBySelf.end(), [](const auto& a, const auto& b) {
            return a.second->selfTimeUs > b.second->selfTimeUs;
        });

        // Sort functions by total time
        WTF::Vector<std::pair<WTF::String, FunctionStats*>> sortedByTotal;
        for (auto& entry : functionStatsMap)
            sortedByTotal.append({ entry.key, &entry.value });
        std::sort(sortedByTotal.begin(), sortedByTotal.end(), [](const auto& a, const auto& b) {
            return a.second->totalTimeUs > b.second->totalTimeUs;
        });

        // Build the text output (Markdown format optimized for GitHub rendering + LLM analysis)
        WTF::StringBuilder output;
        int numFunctions = static_cast<int>(functionStatsMap.size());

        // Header with key metrics
        output.append("# CPU Profile\n\n"_s);
        output.append("| Duration | Samples | Interval | Functions |\n"_s);
        output.append("|----------|---------|----------|----------|\n"_s);
        output.append("| "_s);
        output.append(formatTime(endTime - startTime));
        output.append(" | "_s);
        output.append(totalSamples);
        output.append(" | "_s);
        output.append(formatTime(state.interval));
        output.append(" | "_s);
        output.append(numFunctions);
        output.append(" |\n\n"_s);

        // Top 10 summary for quick orientation
        output.append("**Top 10:** "_s);
        int topCount = 0;
        for (auto& [key, stats] : sortedBySelf) {
            if (stats->selfTimeUs == 0 || topCount >= 10)
                break;
            if (topCount > 0) output.append(", "_s);
            output.append(formatCodeSpan(stats->functionName));
            output.append(' ');
            output.append(formatPercent(stats->selfTimeUs, totalTimeUs));
            topCount++;
        }
        output.append("\n\n"_s);

        // Hot functions by self time (where time is actually spent)
        output.append("## Hot Functions (Self Time)\n\n"_s);
        output.append("| Self% | Self | Total% | Total | Function | Location |\n"_s);
        output.append("|------:|-----:|-------:|------:|----------|----------|\n"_s);

        for (auto& [key, stats] : sortedBySelf) {
            // Skip functions with 0 self time
            if (stats->selfTimeUs == 0)
                continue;
            output.append("| "_s);
            output.append(formatPercent(stats->selfTimeUs, totalTimeUs));
            output.append(" | "_s);
            output.append(formatTime(stats->selfTimeUs));
            output.append(" | "_s);
            output.append(formatPercent(stats->totalTimeUs, totalTimeUs));
            output.append(" | "_s);
            output.append(formatTime(stats->totalTimeUs));
            output.append(" | "_s);
            output.append(formatCodeSpan(stats->functionName));
            output.append(" | "_s);
            output.append(formatCodeSpan(stats->location));
            output.append(" |\n"_s);
        }
        output.append('\n');

        // Call tree (total time) - shows the call hierarchy
        output.append("## Call Tree (Total Time)\n\n"_s);
        output.append("| Total% | Total | Self% | Self | Function | Location |\n"_s);
        output.append("|-------:|------:|------:|-----:|----------|----------|\n"_s);

        for (auto& [key, stats] : sortedByTotal) {
            output.append("| "_s);
            output.append(formatPercent(stats->totalTimeUs, totalTimeUs));
            output.append(" | "_s);
            output.append(formatTime(stats->totalTimeUs));
            output.append(" | "_s);
            output.append(formatPercent(stats->selfTimeUs, totalTimeUs));
            output.append(" | "_s);
            output.append(formatTime(stats->selfTimeUs));
            output.append(" | "_s);
            output.append(formatCodeSpan(stats->functionName));
            output.append(" | "_s);
            output.append(formatCodeSpan(stats->location));
            output.append(" |\n"_s);
        }
        output.append('\n');

        // Function details with call relationships
        output.append("## Function Details\n\n"_s);

        for (auto& [key, stats] : sortedBySelf) {
            // Skip functions with no self time and no interesting relationships
            if (stats->selfTimeUs == 0 && stats->callers.isEmpty() && stats->callees.isEmpty())
                continue;

            // Header: ### `functionName`
            output.append("### "_s);
            output.append(formatCodeSpan(stats->functionName));
            output.append("\n"_s);

            // Location and stats on one line for density
            output.append(formatCodeSpan(stats->location));
            output.append(" | Self: "_s);
            output.append(formatPercent(stats->selfTimeUs, totalTimeUs));
            output.append(" ("_s);
            output.append(formatTime(stats->selfTimeUs));
            output.append(") | Total: "_s);
            output.append(formatPercent(stats->totalTimeUs, totalTimeUs));
            output.append(" ("_s);
            output.append(formatTime(stats->totalTimeUs));
            output.append(") | Samples: "_s);
            output.append(stats->selfSamples);
            output.append('\n');

            if (!stats->callers.isEmpty()) {
                output.append("\n**Called by:**\n"_s);
                WTF::Vector<std::pair<WTF::String, int>> sortedCallers;
                for (auto& c : stats->callers)
                    sortedCallers.append({ c.key, c.value });
                std::sort(sortedCallers.begin(), sortedCallers.end(), [](const auto& a, const auto& b) {
                    return a.second > b.second;
                });
                for (auto& [callerKey, count] : sortedCallers) {
                    output.append("- "_s);
                    // Extract just the function name from "funcName<separator>location"
                    size_t sepPos = callerKey.find(kKeySeparator);
                    WTF::String callerName = (sepPos != WTF::notFound) ? callerKey.left(sepPos) : callerKey;
                    output.append(formatCodeSpan(callerName));
                    output.append(" ("_s);
                    output.append(count);
                    output.append(")\n"_s);
                }
            }

            if (!stats->callees.isEmpty()) {
                output.append("\n**Calls:**\n"_s);
                WTF::Vector<std::pair<WTF::String, int>> sortedCallees;
                for (auto& c : stats->callees)
                    sortedCallees.append({ c.key, c.value });
                std::sort(sortedCallees.begin(), sortedCallees.end(), [](const auto& a, const auto& b) {
                    return a.second > b.second;
                });
                for (auto& [calleeKey, count] : sortedCallees) {
                    output.append("- "_s);
                    // Extract just the function name from "funcName<separator>location"
                    size_t sepPos = calleeKey.find(kKeySeparator);
                    WTF::String calleeName = (sepPos != WTF::notFound) ? calleeKey.left(sepPos) : calleeKey;
                    output.append(formatCodeSpan(calleeName));
                    output.append(" ("_s);
                    output.append(count);
                    output.append(")\n"_s);
                }
            }

            output.append('\n');
        }

        // Source files breakdown
        WTF::HashMap<WTF::String, long long> fileTimesUs;
        for (auto& [key, stats] : functionStatsMap) {
            WTF::String file = stats.location;
            size_t colonPos = file.reverseFind(':');
            if (colonPos != WTF::notFound && colonPos > 0) {
                bool isLineNumber = true;
                for (size_t i = colonPos + 1; i < file.length(); i++) {
                    if (file[i] < '0' || file[i] > '9') {
                        isLineNumber = false;
                        break;
                    }
                }
                if (isLineNumber)
                    file = file.left(colonPos);
            }
            fileTimesUs.add(file, 0).iterator->value += stats.selfTimeUs;
        }

        WTF::Vector<std::pair<WTF::String, long long>> sortedFiles;
        for (auto& f : fileTimesUs)
            sortedFiles.append({ f.key, f.value });
        std::sort(sortedFiles.begin(), sortedFiles.end(), [](const auto& a, const auto& b) {
            return a.second > b.second;
        });

        output.append("## Files\n\n"_s);
        output.append("| Self% | Self | File |\n"_s);
        output.append("|------:|-----:|------|\n"_s);

        for (auto& [file, timeUs] : sortedFiles) {
            if (timeUs == 0)
                continue;
            output.append("| "_s);
            output.append(formatPercent(timeUs, totalTimeUs));
            output.append(" | "_s);
            output.append(formatTime(timeUs));
            output.append(" | "_s);
            output.append(formatCodeSpan(file));
            output.append(" |\n"_s);
        }

        *outText = output.toString();
    }
}

} // namespace Bun

extern "C" void Bun__startCPUProfiler(JSC::VM* vm)
{
    Bun::startCPUProfiler(*vm);
}

extern "C" void Bun__stopCPUProfiler(JSC::VM* vm, BunString* outJSON, BunString* outText)
{
    WTF::String jsonResult;
    WTF::String textResult;
    Bun::stopCPUProfiler(*vm, outJSON ? &jsonResult : nullptr, outText ? &textResult : nullptr);
    if (outJSON)
        *outJSON = Bun::toStringRef(jsonResult);
    if (outText)
        *outText = Bun::toStringRef(textResult);
}

extern "C" void Home__CPUProfiler__setSamplingInterval(JSC::VM* vm, int interval) { Bun::setSamplingIntervalForVM(*vm, interval); }
extern "C" void Home__CPUProfiler__cancelForVM(JSC::VM* vm) {
    if (auto* profiler = vm->samplingProfiler()) {
        JSC::JSLockHolder locker(*vm);
        WTF::Locker samplerLock { profiler->getLock() };
        profiler->pause(); profiler->clearData();
    }
    std::lock_guard lock(Bun::profilerStateLock);
    Bun::profilerStates.erase(vm);
    if (Bun::legacyProfilerVM == vm) Bun::legacyProfilerVM = nullptr;
}
