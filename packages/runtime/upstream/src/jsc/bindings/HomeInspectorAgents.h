#pragma once
#include "BunCPUProfiler.h"
#include "HomeCPUProfilerState.h"
#include <JavaScriptCore/SamplingProfiler.h>
#include <wtf/JSONValues.h>
#include <wtf/WallTime.h>
#include <wtf/MonotonicTime.h>
#include <unordered_map>
#include <vector>
#include <algorithm>

namespace Home {
struct InspectorSampleBroker {
    unsigned clients { 0 };
    std::unordered_map<const void*, int> intervals;
    std::unordered_map<const void*, double> starts;
    std::vector<Ref<JSON::Object>> batches;
};
inline auto& inspectorSampleBrokers() {
    static thread_local auto* brokers = new std::unordered_map<JSC::VM*, InspectorSampleBroker>;
    return *brokers;
}
inline void captureInspectorSamples(JSC::VM& vm, InspectorSampleBroker& broker) {
    broker.batches.push_back(Bun::captureCPUProfilerSamples(vm));
}
struct InspectorProfileNode {
    int id;
    WTF::String name, url, script;
    int line, column, hits { 0 };
    std::vector<int> children;
};
inline Ref<JSON::Object> inspectorProfile(JSC::VM& vm, InspectorSampleBroker& broker, double start, double wallStart) {
    captureInspectorSamples(vm, broker);
    std::vector<Ref<JSON::Object>> traces;
    std::unordered_map<std::string, WTF::String> sourceURLs;
    for (auto& batch : broker.batches) {
        if (auto sources = batch->getArray("sources"_s)) for (size_t i = 0; i < sources->length(); ++i) {
            auto source = sources->get(i)->asObject();
            if (!source) continue;
            auto id = source->getDouble("sourceID"_s);
            if (id) sourceURLs[std::to_string(*id)] = source->getString("sourceURL"_s).isEmpty() ? source->getString("url"_s) : source->getString("sourceURL"_s);
        }
        if (auto values = batch->getArray("traces"_s)) for (size_t i = 0; i < values->length(); ++i) {
            auto trace = values->get(i)->asObject();
            if (trace && trace->getDouble("timestamp"_s).value_or(0) >= start) traces.push_back(trace.releaseNonNull());
        }
    }
    std::sort(traces.begin(), traces.end(), [](const auto& a, const auto& b) { return a->getDouble("timestamp"_s).value_or(0) < b->getDouble("timestamp"_s).value_or(0); });
    std::vector<InspectorProfileNode> nodes { { 1, "(root)"_s, ""_s, "0"_s, -1, -1 } };
    std::unordered_map<std::string, int> identities;
    auto samples = JSON::Array::create();
    auto deltas = JSON::Array::create();
    double previous = start;
    for (auto& trace : traces) {
        int parent = 1;
        if (auto frames = trace->getArray("frames"_s)) for (size_t reverse = frames->length(); reverse > 0; --reverse) {
            auto frame = frames->get(reverse - 1)->asObject();
            if (!frame) continue;
            auto name = frame->getString("name"_s);
            auto script = frame->getString("scriptId"_s);
            auto sourceKey = std::string(script.utf8().data());
            auto url = frame->getString("sourceURL"_s);
            if (url.isEmpty()) { auto found = sourceURLs.find(sourceKey); if (found != sourceURLs.end()) url = found->second; }
            int line = frame->getInteger("line"_s).value_or(-1);
            int column = frame->getInteger("column"_s).value_or(-1);
            auto key = std::to_string(parent) + ":" + sourceKey + ":" + std::to_string(line) + ":" + std::to_string(column) + ":" + name.utf8().data();
            auto [entry, inserted] = identities.emplace(key, static_cast<int>(nodes.size() + 1));
            if (inserted) {
                nodes[parent - 1].children.push_back(entry->second);
                nodes.push_back({ entry->second, name, url, script, line, column });
            }
            parent = entry->second;
        }
        ++nodes[parent - 1].hits;
        samples->pushInteger(parent);
        double timestamp = trace->getDouble("timestamp"_s).value_or(previous);
        deltas->pushDouble(static_cast<double>(static_cast<int64_t>(std::max(0.0, (timestamp - previous) * 1000000.0))));
        previous = timestamp;
    }
    auto encodedNodes = JSON::Array::create();
    for (const auto& node : nodes) {
        auto frame = JSON::Object::create();
        frame->setString("functionName"_s, node.name);
        frame->setString("scriptId"_s, node.script);
        frame->setString("url"_s, node.url);
        frame->setInteger("lineNumber"_s, node.line);
        frame->setInteger("columnNumber"_s, node.column);
        auto value = JSON::Object::create();
        value->setInteger("id"_s, node.id);
        value->setObject("callFrame"_s, WTF::move(frame));
        value->setInteger("hitCount"_s, node.hits);
        auto children = JSON::Array::create();
        for (int id : node.children) children->pushInteger(id);
        value->setArray("children"_s, WTF::move(children));
        encodedNodes->pushObject(WTF::move(value));
    }
    auto result = JSON::Object::create();
    result->setArray("nodes"_s, WTF::move(encodedNodes));
    result->setArray("samples"_s, WTF::move(samples));
    result->setArray("timeDeltas"_s, WTF::move(deltas));
    result->setDouble("startTime"_s, static_cast<double>(static_cast<int64_t>(wallStart)));
    result->setDouble("endTime"_s, static_cast<double>(static_cast<int64_t>(wallStart + std::max(0.0, (MonotonicTime::now().secondsSinceEpoch().seconds() - start) * 1000000.0))));
    return result;
}
}
