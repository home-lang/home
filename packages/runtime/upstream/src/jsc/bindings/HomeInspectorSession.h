#pragma once
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/CompleteSubspace.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include <JavaScriptCore/InspectorFrontendChannel.h>
#include <JavaScriptCore/WeakInlines.h>
#include <JavaScriptCore/Strong.h>
#include <wtf/JSONValues.h>
#include <atomic>
#include <limits>
#include "ScriptExecutionContext.h"
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace Home {
class LocalInspectorHandle;
class LocalInspectorChannel final : public Inspector::FrontendChannel, public std::enable_shared_from_this<LocalInspectorChannel> {
public:
    JSC::JSGlobalObject* global;
    WebCore::ScriptExecutionContextIdentifier context;
    JSC::Weak<LocalInspectorHandle> handle;
    std::vector<WTF::String> messages;
    std::unordered_map<int, int> responseIds;
    bool connected { false }, scheduled { false };
    explicit LocalInspectorChannel(JSC::JSGlobalObject* owner, WebCore::ScriptExecutionContextIdentifier id) : global(owner), context(id) { }
    ConnectionType connectionType() const final { return ConnectionType::Local; }
    void sendMessageToFrontend(const WTF::String&) final;
    void drain();
    void disconnect();
};
inline std::mutex& localInspectorLock() { static std::mutex lock; return lock; }
inline auto& localInspectorChannels() {
    static auto* channels = new std::unordered_map<JSC::JSGlobalObject*, std::vector<std::shared_ptr<LocalInspectorChannel>>>;
    return *channels;
}
class LocalInspectorHandle final : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;
    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;
    template<typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm) { return &vm.destructibleObjectSpace(); }
    std::shared_ptr<LocalInspectorChannel> channel;
    JSC::WriteBarrier<JSC::JSObject> callback;
    static LocalInspectorHandle* create(JSC::JSGlobalObject* global, JSC::JSObject* callback, std::shared_ptr<LocalInspectorChannel> channel) {
        auto& vm = global->vm();
        auto* structure = JSC::Structure::create(vm, global, JSC::jsNull(), JSC::TypeInfo(JSC::ObjectType, Base::StructureFlags), info());
        auto* object = new (NotNull, JSC::allocateCell<LocalInspectorHandle>(vm)) LocalInspectorHandle(vm, structure, WTF::move(channel));
        object->finishCreation(vm);
        object->callback.set(vm, object, callback);
        object->channel->handle = JSC::Weak<LocalInspectorHandle>(object);
        return object;
    }
    static void destroy(JSC::JSCell* cell) { static_cast<LocalInspectorHandle*>(cell)->~LocalInspectorHandle(); }
    ~LocalInspectorHandle() {
        channel->handle.clear();
        if (channel->connected) {
            auto retained = channel;
            WebCore::ScriptExecutionContext::postTaskTo(channel->context, [retained](WebCore::ScriptExecutionContext&) { retained->disconnect(); });
        }
    }
private:
    LocalInspectorHandle(JSC::VM& vm, JSC::Structure* structure, std::shared_ptr<LocalInspectorChannel> value) : Base(vm, structure), channel(WTF::move(value)) { }
};
const JSC::ClassInfo LocalInspectorHandle::s_info = { "HomeInspectorSession"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(LocalInspectorHandle) };
template<typename Visitor> void LocalInspectorHandle::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor) {
    auto* object = static_cast<LocalInspectorHandle*>(cell);
    Base::visitChildren(object, visitor);
    visitor.append(object->callback);
}
DEFINE_VISIT_CHILDREN(LocalInspectorHandle);
inline void LocalInspectorChannel::sendMessageToFrontend(const WTF::String& message) {
    if (!connected) return;
    auto parsed = JSON::Value::parseJSON(message);
    auto object = parsed ? parsed->asObject() : nullptr;
    WTF::String routed = message;
    if (object) {
        if (auto id = object->getInteger("id"_s)) {
            auto found = responseIds.find(*id);
            if (found == responseIds.end()) return;
            object->setInteger("id"_s, found->second);
            responseIds.erase(found);
            routed = object->toJSONString();
        }
    }
    messages.push_back(routed);
    if (scheduled) return;
    scheduled = true;
    auto retained = shared_from_this();
    if (!WebCore::ScriptExecutionContext::postTaskTo(context, [retained](WebCore::ScriptExecutionContext&) { retained->scheduled = false; retained->drain(); })) scheduled = false;
}
inline void LocalInspectorChannel::drain() {
    if (!connected) return;
    auto* object = handle.get();
    if (!object) { disconnect(); return; }
    JSC::Strong<LocalInspectorHandle> protect(global->vm(), object);
    JSC::JSLockHolder lock(global->vm());
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
    while (connected && !messages.empty()) {
        auto pending = WTF::move(messages);
        messages.clear();
        for (const auto& message : pending) {
            if (!connected) break;
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(JSC::jsString(global->vm(), message));
            JSC::call(global, object->callback.get(), JSC::jsUndefined(), arguments, "Inspector session receiver must be callable"_s);
            if (scope.exception()) {
                if (global->vm().hasPendingTerminationException()) return;
                auto* error = scope.exception();
                (void)scope.tryClearException();
                Bun__reportUnhandledError(global, JSC::JSValue::encode(error));
            }
        }
    }
}
inline void LocalInspectorChannel::disconnect() {
    if (!connected) return;
    auto retained = shared_from_this();
    connected = false;
    handle.clear();
    messages.clear();
    responseIds.clear();
    global->inspectorController().disconnectFrontend(*this);
    std::lock_guard lock(localInspectorLock());
    auto entry = localInspectorChannels().find(global);
    if (entry != localInspectorChannels().end()) {
        std::erase_if(entry->second, [this](const auto& channel) { return channel.get() == this; });
        if (entry->second.empty()) localInspectorChannels().erase(entry);
    }
}
inline void cancelLocalInspector(JSC::JSGlobalObject* global) {
    std::vector<std::shared_ptr<LocalInspectorChannel>> channels;
    { std::lock_guard lock(localInspectorLock()); auto entry = localInspectorChannels().find(global); if (entry != localInspectorChannels().end()) channels = entry->second; }
    for (auto& channel : channels) { channel->disconnect(); channel->handle.clear(); }
}
JSC_DEFINE_HOST_FUNCTION(connectLocalInspector, (JSC::JSGlobalObject* global, JSC::CallFrame* frame)) {
    auto& vm = global->vm(); auto scope = DECLARE_THROW_SCOPE(vm);
    auto receiver = frame->argument(0);
    if (!receiver.isCallable()) { JSC::throwTypeError(global, scope, "Inspector receiver must be callable"_s); return {}; }
    auto* context = uncheckedDowncast<Zig::GlobalObject>(global)->scriptExecutionContext();
    if (!context) { JSC::throwTypeError(global, scope, "Inspector requires a live context"_s); return {}; }
    auto channel = std::make_shared<LocalInspectorChannel>(global, context->identifier());
    auto* handle = LocalInspectorHandle::create(global, receiver.getObject(), channel);
    JSC::Strong<LocalInspectorHandle> protect(vm, handle);
    { std::lock_guard lock(localInspectorLock()); localInspectorChannels()[global].push_back(channel); }
    channel->connected = true;
    global->inspectorController().connectFrontend(*channel, false, false);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(handle);
}
JSC_DEFINE_HOST_FUNCTION(dispatchLocalInspector, (JSC::JSGlobalObject* global, JSC::CallFrame* frame)) {
    auto& vm = global->vm(); auto scope = DECLARE_THROW_SCOPE(vm);
    auto* handle = dynamicDowncast<LocalInspectorHandle>(frame->argument(0));
    if (!handle || !handle->channel->connected) { JSC::throwTypeError(global, scope, "Inspector session is closed"_s); return {}; }
    auto channel = handle->channel;
    auto message = frame->argument(1).toWTFString(global);
    RETURN_IF_EXCEPTION(scope, {});
    auto parsed = JSON::Value::parseJSON(message);
    auto request = parsed ? parsed->asObject() : nullptr;
    auto localId = request ? request->getInteger("id"_s) : std::nullopt;
    if (!request || !localId) { JSC::throwTypeError(global, scope, "Inspector command requires an integer request ID"_s); return {}; }
    static std::atomic<uint64_t> nextRequestId { 1 };
    uint64_t allocatedId = nextRequestId.fetch_add(1);
    if (allocatedId > static_cast<uint64_t>(std::numeric_limits<int>::max())) { JSC::throwTypeError(global, scope, "Inspector request ID space exhausted"_s); return {}; }
    int nativeId = static_cast<int>(allocatedId);
    channel->responseIds.emplace(nativeId, *localId);
    request->setInteger("id"_s, nativeId);
    global->inspectorController().dispatchMessageFromFrontend(request->toJSONString());
    RETURN_IF_EXCEPTION(scope, {});
    channel->drain();
    return JSC::JSValue::encode(JSC::jsUndefined());
}
JSC_DEFINE_HOST_FUNCTION(disconnectLocalInspector, (JSC::JSGlobalObject* global, JSC::CallFrame* frame)) {
    auto* handle = dynamicDowncast<LocalInspectorHandle>(frame->argument(0));
    if (handle) { auto channel = handle->channel; channel->disconnect(); }
    return JSC::JSValue::encode(JSC::jsUndefined());
}
static JSC::JSValue createInspectorBinding(Zig::GlobalObject* global) {
    auto& vm = global->vm(); auto scope = DECLARE_THROW_SCOPE(vm);
    auto* result = JSC::constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, {});
    result->putDirect(vm, JSC::Identifier::fromString(vm, "connect"_s), JSC::JSFunction::create(vm, global, 1, "connect"_s, connectLocalInspector, JSC::ImplementationVisibility::Public));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "dispatch"_s), JSC::JSFunction::create(vm, global, 2, "dispatch"_s, dispatchLocalInspector, JSC::ImplementationVisibility::Public));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "disconnect"_s), JSC::JSFunction::create(vm, global, 1, "disconnect"_s, disconnectLocalInspector, JSC::ImplementationVisibility::Public));
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}
}
extern "C" void Home__InspectorSession__cancelForGlobal(JSC::JSGlobalObject* global) { Home::cancelLocalInspector(global); }
