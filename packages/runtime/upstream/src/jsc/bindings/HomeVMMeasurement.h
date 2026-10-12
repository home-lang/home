#pragma once
#include <JavaScriptCore/HeapAnalyzer.h>
#include <JavaScriptCore/HeapObserver.h>
#include <JavaScriptCore/HeapProfiler.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSCellInlines.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/PreventCollectionScope.h>
#include <JavaScriptCore/DeferGC.h>
#include <JavaScriptCore/ButterflyInlines.h>
#include <JavaScriptCore/IndexingHeaderInlines.h>
#include <wtf/Lock.h>
#include <wtf/Locker.h>
#include "ScriptExecutionContext.h"
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace Bun {
struct HomeMemoryRange { double estimate { 0 }, lower { 0 }, upper { 0 }; };
class HomeVMMeasurement final : public JSC::HeapAnalyzer, public JSC::HeapObserver, public std::enable_shared_from_this<HomeVMMeasurement> {
    struct Node { JSC::JSCell* cell; size_t bytes { 0 }; std::vector<size_t> edges; };
    struct Request {
        JSC::JSGlobalObject* global;
        JSC::Strong<JSC::JSPromise> promise;
        WebCore::ScriptExecutionContextIdentifier context;
        bool detailed;
    };
    JSC::VM& m_vm;
    std::mutex m_graphLock;
    std::unordered_map<JSC::JSCell*, size_t> m_indexes;
    std::vector<Node> m_nodes;
    std::vector<Request> m_requests;
    std::vector<JSC::JSGlobalObject*> m_globals;
    std::vector<HomeMemoryRange> m_ranges;
    HomeMemoryRange m_total;
    bool m_registered { false }, m_capturing { false }, m_ready { false };
    static std::unordered_map<JSC::VM*, std::vector<std::shared_ptr<HomeVMMeasurement>>>& jobs();
    static std::mutex& jobsLock();
    size_t node(JSC::JSCell* cell) {
        auto [entry, inserted] = m_indexes.emplace(cell, m_nodes.size());
        if (inserted) m_nodes.push_back({ cell, 0, {} });
        return entry->second;
    }
    void edge(JSC::JSCell* from, JSC::JSCell* to) {
        if (!from || !to) return;
        std::lock_guard locker(m_graphLock);
        size_t source = node(from), target = node(to);
        m_nodes[source].edges.push_back(target);
    }
    void retire();
    void summarize();
    void deliver(JSC::JSGlobalObject*);
    static JSC::JSObject* rangeObject(JSC::JSGlobalObject*, const HomeMemoryRange&);
public:
    explicit HomeVMMeasurement(JSC::VM& vm) : m_vm(vm) { }
    static JSC::JSValue begin(JSC::JSGlobalObject*, bool detailed, bool eager);
    static void cancel(JSC::JSGlobalObject*);
    void analyzeNode(JSC::JSCell* cell) final { std::lock_guard locker(m_graphLock); node(cell); }
    void analyzeEdge(JSC::JSCell* from, JSC::JSCell* to, JSC::RootMarkReason) final { edge(from, to); }
    void analyzePropertyNameEdge(JSC::JSCell* from, JSC::JSCell* to, WTF::UniquedStringImpl*) final { edge(from, to); }
    void analyzeVariableNameEdge(JSC::JSCell* from, JSC::JSCell* to, WTF::UniquedStringImpl*) final { edge(from, to); }
    void analyzeIndexEdge(JSC::JSCell* from, JSC::JSCell* to, uint32_t) final { edge(from, to); }
    void setOpaqueRootReachabilityReasonForCell(JSC::JSCell*, WTF::ASCIILiteral) final { }
    void setWrappedObjectForCell(JSC::JSCell*, void*) final { }
    void setLabelForCell(JSC::JSCell*, const WTF::String&) final { }
    void willGarbageCollect() final;
    void didGarbageCollect(JSC::CollectionScope) final;
};
inline std::mutex& HomeVMMeasurement::jobsLock() { static std::mutex lock; return lock; }
inline std::unordered_map<JSC::VM*, std::vector<std::shared_ptr<HomeVMMeasurement>>>& HomeVMMeasurement::jobs() {
    static auto* map = new std::unordered_map<JSC::VM*, std::vector<std::shared_ptr<HomeVMMeasurement>>>;
    return *map;
}
inline void HomeVMMeasurement::willGarbageCollect() {
    if (m_ready || m_vm.heap.collectionScope() != JSC::CollectionScope::Full) return;
    auto& profiler = m_vm.ensureHeapProfiler();
    if (profiler.activeHeapAnalyzer()) return;
    m_nodes.clear(); m_indexes.clear();
    profiler.setActiveHeapAnalyzer(this);
    m_capturing = true;
}
inline void HomeVMMeasurement::didGarbageCollect(JSC::CollectionScope scope) {
    if (!m_capturing) return;
    m_vm.ensureHeapProfiler().setActiveHeapAnalyzer(nullptr);
    m_capturing = false;
    if (scope != JSC::CollectionScope::Full) return;
    summarize();
    m_ready = true;
    auto self = shared_from_this();
    for (const auto& request : m_requests) {
        auto* owner = request.global;
        WebCore::ScriptExecutionContext::postTaskTo(request.context, [self, owner](WebCore::ScriptExecutionContext&) { self->deliver(owner); });
    }
}
inline void HomeVMMeasurement::summarize() {
    // Marked graph edges, not user-visible property enumeration. Other realm
    // globals are ownership boundaries, so traversing one cannot charge all
    // of another realm's graph to it. Shared cells contribute bounded ranges.
    const size_t cells = m_nodes.size();
    m_nodes.reserve(cells * 2);
    std::unordered_map<const void*, size_t> storage;
    for (size_t i = 0; i < cells; ++i) {
        auto& item = m_nodes[i];
        item.bytes = item.cell->estimatedSizeInBytes(m_vm);
        if (auto* object = dynamicDowncast<JSC::JSObject>(item.cell)) {
            auto* butterfly = object->butterfly();
            auto* structure = object->structure();
            if (butterfly && !(object->indexingMode() & JSC::CopyOnWrite)) {
                const bool indexed = structure->hasIndexingHeader(object);
                const size_t bytes = JSC::Butterfly::totalSize(indexed ? butterfly->indexingHeader()->preCapacity(structure) : 0,
                    structure->outOfLineCapacity(), indexed, indexed ? butterfly->indexingHeader()->indexingPayloadSizeInBytes(structure) : 0);
                item.bytes -= std::min<size_t>(item.bytes, structure->outOfLineSize());
                auto [entry, inserted] = storage.emplace(butterfly, m_nodes.size());
                if (inserted) m_nodes.push_back({ nullptr, bytes, {} });
                item.edges.push_back(entry->second);
            }
        }
        if (auto* global = dynamicDowncast<JSC::JSGlobalObject>(item.cell)) {
            bool requested = false;
            for (const auto& request : m_requests) requested |= request.global == global;
            if (requested || dynamicDowncast<NodeVMGlobalObject>(global)) m_globals.push_back(global);
        }
    }
    const size_t count = m_nodes.size();
    std::vector<std::vector<uint8_t>> ownership;
    std::vector<size_t> owners(count, 0);
    for (auto* global : m_globals) {
        std::vector<uint8_t> seen(count, 0);
        std::vector<size_t> pending { m_indexes.at(global) };
        while (!pending.empty()) {
            size_t index = pending.back(); pending.pop_back();
            if (seen[index]) continue;
            if (auto* boundary = m_nodes[index].cell ? dynamicDowncast<JSC::JSGlobalObject>(m_nodes[index].cell) : nullptr; boundary && boundary != global) continue;
            seen[index] = 1; ++owners[index];
            for (auto child : m_nodes[index].edges) if (!seen[child]) pending.push_back(child);
        }
        ownership.push_back(std::move(seen));
    }
    double unattributed = 0;
    for (size_t i = 0; i < count; ++i) {
        m_total.estimate += m_nodes[i].bytes;
        if (!owners[i]) unattributed += m_nodes[i].bytes;
        if (owners[i] == 1) m_total.lower += m_nodes[i].bytes;
    }
    m_total.upper = m_total.estimate;
    for (const auto& membership : ownership) {
        HomeMemoryRange range;
        for (size_t i = 0; i < count; ++i) if (membership[i]) {
            const double bytes = m_nodes[i].bytes;
            range.estimate += bytes / owners[i];
            range.upper += bytes;
            if (owners[i] == 1) range.lower += bytes;
        }
        range.upper += unattributed;
        m_ranges.push_back(range);
    }
    // No cell pointer is used by the later JavaScript delivery task.
    m_nodes.clear(); m_indexes.clear();
}
inline JSC::JSObject* HomeVMMeasurement::rangeObject(JSC::JSGlobalObject* global, const HomeMemoryRange& range) {
    auto& vm = global->vm();
    auto* result = JSC::constructEmptyObject(global);
    result->putDirect(vm, JSC::Identifier::fromString(vm, "jsMemoryEstimate"_s), JSC::jsNumber(range.estimate));
    auto* bounds = JSC::constructEmptyArray(global, nullptr, 2);
    bounds->putDirectIndex(global, 0, JSC::jsNumber(range.lower));
    bounds->putDirectIndex(global, 1, JSC::jsNumber(range.upper));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "jsMemoryRange"_s), bounds);
    return result;
}
inline void HomeVMMeasurement::deliver(JSC::JSGlobalObject* owner) {
    if (!m_ready || m_requests.empty()) return;
    JSC::JSLockHolder lock(m_vm);
    JSC::PreventCollectionScope prevent(m_vm.heap);
    auto scope = DECLARE_THROW_SCOPE(m_vm);
    JSC::DeferGCForAWhile deferGC(m_vm);
    for (auto it = m_requests.begin(); it != m_requests.end();) {
        if (it->global != owner) { ++it; continue; }
        auto* result = JSC::constructEmptyObject(owner);
        result->putDirect(m_vm, JSC::Identifier::fromString(m_vm, "total"_s), rangeObject(owner, m_total));
        if (it->detailed) {
            auto* others = JSC::constructEmptyArray(owner, nullptr);
            unsigned index = 0;
            for (size_t i = 0; i < m_globals.size(); ++i) {
                auto* range = rangeObject(owner, m_ranges[i]);
                if (m_globals[i] == owner) result->putDirect(m_vm, JSC::Identifier::fromString(m_vm, "current"_s), range);
                else others->putDirectIndex(owner, index++, range);
            }
            result->putDirect(m_vm, JSC::Identifier::fromString(m_vm, "other"_s), others);
        }
        if (scope.exception()) it->promise->rejectWithCaughtException(m_vm, scope);
        else it->promise->resolve(owner, m_vm, result);
        it = m_requests.erase(it);
    }
    if (m_requests.empty()) retire();
}
inline void HomeVMMeasurement::retire() {
    if (!m_registered) return;
    if (m_vm.ensureHeapProfiler().activeHeapAnalyzer() == this) m_vm.ensureHeapProfiler().setActiveHeapAnalyzer(nullptr);
    m_vm.heap.removeObserver(this);
    m_registered = false;
    std::lock_guard locker(jobsLock());
    auto it = jobs().find(&m_vm);
    if (it != jobs().end()) {
        std::erase_if(it->second, [this](const auto& job) { return job.get() == this; });
        if (it->second.empty()) jobs().erase(it);
    }
}
inline JSC::JSValue HomeVMMeasurement::begin(JSC::JSGlobalObject* global, bool detailed, bool eager) {
    auto& vm = global->vm();
    JSC::PreventCollectionScope prevent(vm.heap);
    auto* context = uncheckedDowncast<Zig::GlobalObject>(global)->scriptExecutionContext();
    auto* promise = JSC::JSPromise::create(vm, global->promiseStructure());
    if (!context) { promise->reject(vm, JSC::createError(global, "VM measurement requires a live context"_s)); return promise; }
    std::shared_ptr<HomeVMMeasurement> job;
    { std::lock_guard locker(jobsLock());
      auto& pending = jobs()[&vm];
      for (const auto& candidate : pending) if (!candidate->m_ready) { job = candidate; break; }
      if (!job) { job = std::make_shared<HomeVMMeasurement>(vm); pending.push_back(job); }
    }
    vm.ensureHeapProfiler();
    job->m_requests.push_back({ global, JSC::Strong<JSC::JSPromise>(vm, promise), context->identifier(), detailed });
    if (!job->m_registered) { vm.heap.addObserver(job.get()); job->m_registered = true; }
    if (eager) vm.heap.collectNow(JSC::Sync, JSC::CollectionScope::Full);
    return promise;
}
inline void HomeVMMeasurement::cancel(JSC::JSGlobalObject* global) {
    JSC::PreventCollectionScope prevent(global->vm().heap);
    std::vector<std::shared_ptr<HomeVMMeasurement>> pending;
    { std::lock_guard locker(jobsLock()); auto it = jobs().find(&global->vm()); if (it != jobs().end()) pending = it->second; }
    for (auto& job : pending) {
        std::erase_if(job->m_requests, [global](const Request& request) { return request.global == global; });
        if (job->m_requests.empty()) job->retire();
    }
}
}
