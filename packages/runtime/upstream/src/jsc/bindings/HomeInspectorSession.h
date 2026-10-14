#pragma once
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/CompleteSubspace.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include <JavaScriptCore/InspectorFrontendChannel.h>
#include <JavaScriptCore/WeakInlines.h>
#include <JavaScriptCore/Strong.h>
#include <wtf/JSONValues.h>
#include <wtf/HashMap.h>
#include <atomic>
#include <limits>
#include <cmath>
#include "ScriptExecutionContext.h"
#include "HomeInspectorAgents.h"
#include "HomeInspectorRealms.h"
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace Home {
class LocalInspectorHandle;
class InspectorRealmForwarder;
class LocalInspectorChannel final : public Inspector::FrontendChannel, public std::enable_shared_from_this<LocalInspectorChannel> {
public:
    JSC::JSGlobalObject* global;
    WebCore::ScriptExecutionContextIdentifier context;
    int executionContext;
    JSC::Weak<LocalInspectorHandle> handle;
    std::vector<WTF::String> messages;
    std::unordered_map<int, int> responseIds;
    std::unordered_map<int, WTF::String> responseMethods;
    std::unordered_map<int, int> responseRealms;
    std::unordered_set<int> accessorPropertyRequests;
    WTF::HashMap<WTF::String, int> realmObjects;
    WTF::HashMap<WTF::String, WTF::String> nativeRealmObjects;
    std::unordered_map<int,std::shared_ptr<InspectorRealmForwarder>> realmFrontends;
    bool disconnecting { false };
    bool connected { false }, scheduled { false }, runtimeEnabled { false }, profilerEnabled { false }, profiling { false };
    int samplingInterval { 1000 };
    double profileStart { 0 }, profileWallStart { 0 };
    bool dispatchAdapter(JSON::Object&);
    void stopProfile();
    void disconnectRealms();
    void retireRealm(int);
    void releaseRealmGroups(const WTF::String&);
    explicit LocalInspectorChannel(JSC::JSGlobalObject* owner, WebCore::ScriptExecutionContextIdentifier id) : global(owner), context(id), executionContext(inspectorOwnerIdentity(owner)) { }
    ConnectionType connectionType() const final { return ConnectionType::Local; }
    void sendMessageToFrontend(const WTF::String&) final;
    void drain();
    void disconnect(bool deliverPendingErrors = false);
};
inline std::mutex& localInspectorLock() { static std::mutex lock; return lock; }
inline auto& localInspectorChannels() {
    static auto* channels = new std::unordered_map<JSC::JSGlobalObject*, std::vector<std::shared_ptr<LocalInspectorChannel>>>;
    return *channels;
}
static bool inspectorHasConsoleFrontends(JSC::JSGlobalObject& global, bool runtimeOnly) {
    auto* owner=&global;
    auto realm=inspectorRealms().find(&global);
    if(realm!=inspectorRealms().end()) owner=realm->second->owner;
    std::lock_guard lock(localInspectorLock());
    auto found=localInspectorChannels().find(owner);
    if(found==localInspectorChannels().end()) return false;
    for(auto& channel:found->second) if(channel->connected && (!runtimeOnly || channel->runtimeEnabled)) return true;
    return false;
}
bool inspectorHasConsoleListeners(JSC::JSGlobalObject& global) { return inspectorHasConsoleFrontends(global, true); }
bool inspectorHasConsoleSessions(JSC::JSGlobalObject& global) { return inspectorHasConsoleFrontends(global, false); }
bool isInspectorConsoleRealm(JSC::JSGlobalObject& global) { return inspectorRealms().contains(&global); }
inline WTF::String inspectorContextCreatedMessage(int id, const WTF::String& name, const WTF::String& origin) {
    auto description = JSON::Object::create();
    description->setInteger("id"_s, id);
    description->setString("origin"_s, origin);
    description->setString("name"_s, name);
    auto params = JSON::Object::create(); params->setObject("context"_s, WTF::move(description));
    auto event = JSON::Object::create(); event->setString("method"_s, "Runtime.executionContextCreated"_s);
    event->setObject("params"_s, WTF::move(params)); return event->toJSONString();
}
void inspectorRealmCreated(InspectorRealm& realm) {
    std::vector<std::shared_ptr<LocalInspectorChannel>> channels;
    { std::lock_guard lock(localInspectorLock()); auto found=localInspectorChannels().find(realm.owner); if(found!=localInspectorChannels().end()) channels=found->second; }
    auto message=inspectorContextCreatedMessage(realm.id,realm.name,realm.origin);
    // Context creation runs on the owner VM thread, outside GC. Like Node,
    // deliver the event before createContext returns. Holding the channels
    // locally makes callback-driven session detachment safe.
    for(auto& channel:channels) if(channel->runtimeEnabled) {
        channel->sendMessageToFrontend(message);
        channel->drain();
    }
}
void inspectorRealmDestroyed(JSC::JSGlobalObject* owner,int id) {
    std::vector<std::shared_ptr<LocalInspectorChannel>> channels;
    { std::lock_guard lock(localInspectorLock()); auto found=localInspectorChannels().find(owner); if(found!=localInspectorChannels().end()) channels=found->second; }
    auto params=JSON::Object::create();params->setInteger("executionContextId"_s,id);
    auto event=JSON::Object::create();event->setString("method"_s,"Runtime.executionContextDestroyed"_s);event->setObject("params"_s,WTF::move(params));
    auto message=event->toJSONString();
    // GC retirement only queues native data; JS delivery occurs on the owner loop.
    for(auto& channel:channels) {
        channel->retireRealm(id);
        if(channel->runtimeEnabled) channel->sendMessageToFrontend(message);
    }
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
inline void remapInspectorRealmObjects(LocalInspectorChannel& channel,JSC::JSGlobalObject* global,int realm,JSON::Value& value) {
        if(auto object=value.asObject()) {
            auto type=object->getString("type"_s);
            bool remote=type=="object"_s || type=="function"_s;
            auto native=object->getString("objectId"_s);
            if(remote && !native.isEmpty()) {
                if(global && inspectorObjectIsPromise(*global,native)) object->setString("subtype"_s,"promise"_s);
                auto exposed=makeString("home-realm:"_s,realm,":"_s,native);
                channel.realmObjects.set(exposed,realm);channel.nativeRealmObjects.set(exposed,native);
                object->setString("objectId"_s,exposed);
            }
            for(auto& entry:*object) if(!remote || entry.key!="value"_s) remapInspectorRealmObjects(channel,global,realm,entry.value.get());
        } else if(auto array=value.asArray()) for(size_t i=0;i<array->length();++i) remapInspectorRealmObjects(channel,global,realm,array->get(i).get());
    }
class InspectorRealmForwarder final : public Inspector::FrontendChannel {
public:
    LocalInspectorChannel& channel;
    int realm;
    JSC::Weak<JSC::JSGlobalObject> global;
    InspectorRealmForwarder(LocalInspectorChannel& owner,InspectorRealm& record):channel(owner),realm(record.id),global(record.global.get()) { }
    ~InspectorRealmForwarder() { disconnect(); }
    void disconnect() { if(auto* value=global.get()) { value->inspectorController().disconnectFrontend(*this);global.clear(); } }
    ConnectionType connectionType() const final { return ConnectionType::Local; }
    void sendMessageToFrontend(const WTF::String& message) final {
        auto parsed=JSON::Value::parseJSON(message);auto object=parsed?parsed->asObject():nullptr;
        if(object && object->getInteger("id"_s).value_or(0)>0) {
            remapObjects(*object);
            channel.sendMessageToFrontend(object->toJSONString());
        }
    }
    void remapObjects(JSON::Value& value) { remapInspectorRealmObjects(channel,global.get(),realm,value); }

};
inline bool unwrapInspectorObjects(LocalInspectorChannel& channel,JSON::Value& value,int target,bool callArgument=false) {
    if(auto object=value.asObject()) {
        for(auto key:{"objectId"_s,"promiseObjectId"_s}) {
            auto exposed=object->getString(key);
            if(!exposed.isEmpty()) {
                auto owner=channel.realmObjects.find(exposed);
                if(owner!=channel.realmObjects.end()) {
                    if(owner->value!=target) return false;
                    auto native=channel.nativeRealmObjects.find(exposed);
                    if(native!=channel.nativeRealmObjects.end()) object->setString(key,native->value);
                } else if(target!=channel.executionContext) return false;
            }
        }
        for(auto& entry:*object) {
            // CallArgument.value is user JSON, not a remote-object envelope.
            if(callArgument && entry.key=="value"_s) continue;
            bool argument=entry.key=="arguments"_s || entry.key=="value"_s;
            if(!unwrapInspectorObjects(channel,entry.value.get(),target,argument)) return false;
        }
    } else if(auto array=value.asArray()) for(size_t i=0;i<array->length();++i) if(!unwrapInspectorObjects(channel,array->get(i).get(),target,callArgument)) return false;
    return true;
}
inline void inspectorWorldError(LocalInspectorChannel& channel,JSON::Object& request) {
    auto error=JSON::Object::create();error->setInteger("code"_s,-32000);error->setString("message"_s,"Argument should belong to the same JavaScript world as target object"_s);
    auto response=JSON::Object::create();response->setInteger("id"_s,*request.getInteger("id"_s));response->setObject("error"_s,WTF::move(error));channel.sendMessageToFrontend(response->toJSONString());
}
inline void LocalInspectorChannel::releaseRealmGroups(const WTF::String& group) {
    for(auto& entry:realmFrontends) if(auto* realm=entry.second->global.get()) {
        auto params=JSON::Object::create();params->setString("objectGroup"_s,group);
        auto request=JSON::Object::create();request->setInteger("id"_s,0);request->setString("method"_s,"Runtime.releaseObjectGroup"_s);request->setObject("params"_s,WTF::move(params));
        realm->inspectorController().dispatchMessageFromFrontend(request->toJSONString());
    }
}
inline bool dispatchInspectorRealm(LocalInspectorChannel& channel,JSON::Object& request) {
    auto params=request.getObject("params"_s);
    if(!params) return false;
    if(request.getString("method"_s)=="Runtime.releaseObjectGroup"_s) {channel.releaseRealmGroups(params->getString("objectGroup"_s));return false;}
    for(auto key:{"contextId"_s,"executionContextId"_s}) if(auto supplied=params->getValue(key)) {
        auto value=supplied->asDouble();
        if(!value || !std::isfinite(*value) || std::trunc(*value)!=*value || *value<std::numeric_limits<int>::min() || *value>std::numeric_limits<int>::max()) {
            auto error=JSON::Object::create();error->setInteger("code"_s,-32602);error->setString("message"_s,makeString(key," must be an integer"_s));
            auto response=JSON::Object::create();response->setInteger("id"_s,*request.getInteger("id"_s));response->setObject("error"_s,WTF::move(error));channel.sendMessageToFrontend(response->toJSONString());return true;
        }
    }
    auto requested=params->getInteger("contextId"_s);
    if(!requested) requested=params->getInteger("executionContextId"_s);
    if(!requested) {
        auto object=params->getString("objectId"_s);
        if(object.isEmpty()) object=params->getString("promiseObjectId"_s);
        if(!object.isEmpty()) {
            auto found=channel.realmObjects.find(object);if(found!=channel.realmObjects.end()) requested=found->value;
        }
    }
    if(!requested || *requested==channel.executionContext) {
        if(!unwrapInspectorObjects(channel,*params,channel.executionContext)) {inspectorWorldError(channel,request);return true;}
        params->remove("contextId"_s);params->remove("executionContextId"_s);return false;
    }
    InspectorRealm* selected=nullptr;
    for(auto& entry:inspectorRealms()) if(entry.second->owner==channel.global && entry.second->id==*requested) {selected=entry.second.get();break;}
    if(!selected || !selected->global) {
        auto error=JSON::Object::create();error->setInteger("code"_s,-32000);error->setString("message"_s,"Cannot find context with specified id"_s);
        auto response=JSON::Object::create();response->setInteger("id"_s,*request.getInteger("id"_s));response->setObject("error"_s,WTF::move(error));channel.sendMessageToFrontend(response->toJSONString());return true;
    }
    JSC::Strong<JSC::JSGlobalObject> protect(channel.global->vm(),selected->global.get());
    auto& frontend=channel.realmFrontends[selected->id];
    if(!frontend) {frontend=std::make_shared<InspectorRealmForwarder>(channel,*selected);protect->inspectorController().connectFrontend(*frontend,false,false);}
    auto& controller=protect->inspectorController();
    params->remove("contextId"_s);params->remove("executionContextId"_s);
    if(!unwrapInspectorObjects(channel,*params,selected->id)) {
        inspectorWorldError(channel,request);return true;
    }
    channel.responseRealms[*request.getInteger("id"_s)] = selected->id;
    controller.dispatchMessageFromFrontend(request.toJSONString());
    return true;
}
inline void LocalInspectorChannel::retireRealm(int id) {
    // Retirement runs on the owner loop after the weak global has cleared.
    // Drop the frontend and every exposed handle before announcing destruction.
    realmFrontends.erase(id);
    std::vector<WTF::String> retired;
    for(auto& entry:realmObjects) if(entry.value==id) retired.push_back(entry.key);
    for(auto& object:retired) {
        realmObjects.remove(object);
        nativeRealmObjects.remove(object);
    }
}
inline void LocalInspectorChannel::disconnectRealms() {
    for(auto& entry:realmFrontends) entry.second->disconnect();
    realmFrontends.clear();
}
inline void decorateInspectorObjects(JSC::JSGlobalObject& global,JSON::Value& value) {
    if(auto object=value.asObject()) {
        auto type=object->getString("type"_s);
        bool remote=type=="object"_s || type=="function"_s;
        auto id=object->getString("objectId"_s);
        if(remote && !id.isEmpty() && !id.startsWith("home-realm:"_s) && inspectorObjectIsPromise(global,id)) object->setString("subtype"_s,"promise"_s);
        for(auto& entry:*object) if(!remote || entry.key!="value"_s) decorateInspectorObjects(global,entry.value.get());
    } else if(auto array=value.asArray()) for(size_t i=0;i<array->length();++i) decorateInspectorObjects(global,array->get(i).get());
}
void deliverInspectorConsoleMessage(JSC::JSGlobalObject& global,const WTF::String& message) {
    auto* owner=&global;int realm=0;
    auto record=inspectorRealms().find(&global);
    if(record!=inspectorRealms().end()) { owner=record->second->owner;realm=record->second->id; }
    std::vector<std::shared_ptr<LocalInspectorChannel>> channels;
    { std::lock_guard lock(localInspectorLock()); auto found=localInspectorChannels().find(owner);if(found!=localInspectorChannels().end()) channels=found->second; }
    for(auto& channel:channels) {
        if(!channel->connected || !channel->runtimeEnabled) continue;
        auto parsed=JSON::Value::parseJSON(message);auto event=parsed?parsed->asObject():nullptr;
        if(!event) continue;
        if(auto params=event->getObject("params"_s)) params->setInteger("executionContextId"_s,realm?realm:channel->executionContext);
        if(realm) remapInspectorRealmObjects(*channel,&global,realm,*event);
        else decorateInspectorObjects(global,*event);
        channel->sendMessageToFrontend(event->toJSONString());
        // Console callbacks run on the active VM thread, outside GC. Deliver
        // to every enabled local frontend before the console call returns.
        channel->drain();
    }
}
inline void LocalInspectorChannel::sendMessageToFrontend(const WTF::String& message) {
    if (!connected) return;
    auto parsed = JSON::Value::parseJSON(message);
    auto object = parsed ? parsed->asObject() : nullptr;
    WTF::String routed = message;
    if (object) {
        if (auto id = object->getInteger("id"_s)) {
            auto found = responseIds.find(*id);
            if (found == responseIds.end()) return;
            decorateInspectorObjects(*global,*object);
            auto method = responseMethods.find(*id);
            if (method != responseMethods.end()) {
                // JSC names the descriptor array "properties"; node:inspector
                // exposes the CDP Runtime.getProperties "result" field.
                if (method->second == "Runtime.getProperties"_s) if (auto result = object->getObject("result"_s)) {
                    if (auto properties = result->getArray("properties"_s)) {
                        if(accessorPropertyRequests.contains(*id)) {
                            auto filtered=JSON::Array::create();
                            for(size_t index=0;index<properties->length();++index) {
                                auto descriptor=properties->get(index).get().asObject();
                                if(descriptor && (descriptor->getValue("get"_s) || descriptor->getValue("set"_s))) filtered->pushObject(descriptor.releaseNonNull());
                            }
                            properties=WTF::move(filtered);
                        }
                        result->remove("properties"_s);
                        result->setArray("result"_s, properties.releaseNonNull());
                    }
                }
                responseMethods.erase(method);
            }
            object->setInteger("id"_s, found->second);
            responseIds.erase(found);
            responseRealms.erase(*id);
            accessorPropertyRequests.erase(*id);
            routed = object->toJSONString();
        }
    }
    if (object && !object->getInteger("id"_s) && object->getString("method"_s).startsWith("Runtime."_s) && !runtimeEnabled) return;
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
inline void LocalInspectorChannel::disconnect(bool deliverPendingErrors) {
    if (!connected || disconnecting) return;
    disconnecting = true;
    auto retained = shared_from_this();
    stopProfile();
    // Explicit session detachment ends this frontend's injected execution
    // context. Deliver completed replies first, then cancel remaining runtime
    // commands through the normal protocol callback path. GC/owner teardown
    // uses the default false argument and must never execute JavaScript.
    if (deliverPendingErrors && handle) {
        drain();
        std::vector<int> pending;
        for (auto& entry : responseMethods) if (entry.second.startsWith("Runtime."_s)) pending.push_back(entry.first);
        for (int id : pending) {
            auto error = JSON::Object::create();
            error->setInteger("code"_s, -32000);
            error->setString("message"_s, "Execution context was destroyed."_s);
            auto response = JSON::Object::create();
            response->setInteger("id"_s, id);
            response->setObject("error"_s, WTF::move(error));
            sendMessageToFrontend(response->toJSONString());
        }
        drain();
    }
    connected = false;
    handle.clear();
    messages.clear();
    responseIds.clear();
    responseMethods.clear();
    responseRealms.clear();
    accessorPropertyRequests.clear();
    realmObjects.clear();
    nativeRealmObjects.clear();
    disconnectRealms();
    global->inspectorController().disconnectFrontend(*this);
    std::lock_guard lock(localInspectorLock());
    auto entry = localInspectorChannels().find(global);
    if (entry != localInspectorChannels().end()) {
        std::erase_if(entry->second, [this](const auto& channel) { return channel.get() == this; });
        if (entry->second.empty()) localInspectorChannels().erase(entry);
    }
}
inline void LocalInspectorChannel::stopProfile() {
    if (!profiling) return;
    profiling = false;
    auto& vm = global->vm();
    auto found = inspectorSampleBrokers().find(&vm);
    if (found == inspectorSampleBrokers().end()) return;
    found->second.intervals.erase(this);
    found->second.starts.erase(this);
    Bun::unregisterCPUProfilerConsumer(vm, this);
    if (--found->second.clients == 0) {
        inspectorSampleBrokers().erase(found);
    } else {
        double earliest = std::numeric_limits<double>::max();
        for (const auto& item : found->second.starts) earliest = std::min(earliest, item.second);
        std::erase_if(found->second.batches, [earliest](const auto& batch) {
            auto traces = batch->getArray("traces"_s);
            if (!traces || !traces->length()) return true;
            for (size_t i = 0; i < traces->length(); ++i) {
                auto trace = traces->get(i)->asObject();
                if (trace && trace->getDouble("timestamp"_s).value_or(0) >= earliest) return false;
            }
            return true;
        });
    }
}
inline bool LocalInspectorChannel::dispatchAdapter(JSON::Object& request) {
    auto method = request.getString("method"_s);
    auto id = request.getInteger("id"_s);
    if (!id) return false;
    auto respond = [&](Ref<JSON::Object> result) {
        auto message = JSON::Object::create();
        message->setInteger("id"_s, *id);
        message->setObject("result"_s, WTF::move(result));
        sendMessageToFrontend(message->toJSONString());
    };
    auto fail = [&](const WTF::String& text) {
        auto error = JSON::Object::create();
        error->setInteger("code"_s, -32000);
        error->setString("message"_s, text);
        auto message = JSON::Object::create();
        message->setInteger("id"_s, *id);
        message->setObject("error"_s, WTF::move(error));
        sendMessageToFrontend(message->toJSONString());
    };
    if (method == "Console.clearMessages"_s || method == "Runtime.discardConsoleEntries"_s) {
        clearInspectorConsoleHistory(*global);
        // Clear native buffers in live owned realms, allowing their real roots to retire.
        for (auto& entry : inspectorRealms()) if (entry.second->owner == global && entry.second->global) {
            auto* source = entry.second->global.get();
            clearInspectorConsoleHistory(*source);
            std::vector<WTF::String> ids;
            bool pending = false;
            std::vector<std::shared_ptr<LocalInspectorChannel>> channels;
            { std::lock_guard lock(localInspectorLock()); auto found = localInspectorChannels().find(global); if (found != localInspectorChannels().end()) channels = found->second; }
            for (auto& channel : channels) {
                for (auto& object : channel->realmObjects) if (object.value == entry.second->id) {
                    auto native = channel->nativeRealmObjects.find(object.key);
                    if (native != channel->nativeRealmObjects.end()) ids.push_back(native->value);
                }
                for (auto& request : channel->responseRealms) if (request.second == entry.second->id) pending = true;
            }
            retireIdleInspectorRealm(*source, ids, pending);
        }
        respond(JSON::Object::create());
        return true;
    }
    if (method == "Runtime.enable"_s) {
        if (!runtimeEnabled) {
            runtimeEnabled = true;
            sendMessageToFrontend(inspectorContextCreatedMessage(executionContext,global->name(),""_s));
            for(auto& entry:inspectorRealms()) if(entry.second->owner==global && entry.second->global)
                sendMessageToFrontend(inspectorContextCreatedMessage(entry.second->id,entry.second->name,entry.second->origin));
            auto replay = [&](JSC::JSGlobalObject& source, int realm) {
                for (auto& message : inspectorConsoleHistory(source)) {
                    auto parsed = JSON::Value::parseJSON(message); auto event = parsed ? parsed->asObject() : nullptr;
                    if (!event) continue;
                    if (auto params = event->getObject("params"_s)) params->setInteger("executionContextId"_s, realm ? realm : executionContext);
                    if (realm) remapInspectorRealmObjects(*this, &source, realm, *event);
                    else decorateInspectorObjects(source, *event);
                    sendMessageToFrontend(event->toJSONString());
                }
            };
            replay(*global, 0);
            for (auto& entry : inspectorRealms()) if (entry.second->owner == global && entry.second->global)
                replay(*entry.second->global.get(), entry.second->id);
        }
        return false;
    }
    if (method == "Runtime.disable"_s) { runtimeEnabled = false; return false; }
    if (!method.startsWith("Profiler."_s)) return false;
    auto& vm = global->vm();
    if (method == "Profiler.enable"_s) { profilerEnabled = true; respond(JSON::Object::create()); return true; }
    if (method == "Profiler.disable"_s) { stopProfile(); profilerEnabled = false; respond(JSON::Object::create()); return true; }
    if (method == "Profiler.setSamplingInterval"_s) {
        auto params = request.getObject("params"_s);
        auto interval = params ? params->getInteger("interval"_s) : std::nullopt;
        if (profiling) fail("Cannot change sampling interval while profiler is running"_s);
        else if (!interval || *interval <= 0) fail("interval must be a positive integer"_s);
        else { samplingInterval = *interval; respond(JSON::Object::create()); }
        return true;
    }
    if (method == "Profiler.start"_s) {
        if (!profilerEnabled) { fail("Profiler is not enabled. Call Profiler.enable first."_s); return true; }
        if (!profiling) {
            auto& broker = inspectorSampleBrokers()[&vm];
            Bun::registerCPUProfilerConsumer(vm, this, samplingInterval);
            captureInspectorSamples(vm, broker);
            ++broker.clients;
            broker.intervals[this] = samplingInterval;
            profileStart = MonotonicTime::now().secondsSinceEpoch().seconds();
            broker.starts[this] = profileStart;
            profileWallStart = WTF::WallTime::now().secondsSinceEpoch().value() * 1000000.0;
            profiling = true;
        }
        respond(JSON::Object::create()); return true;
    }
    if (method == "Profiler.stop"_s) {
        if (!profiling) { fail("Profiler is not started. Call Profiler.start first."_s); return true; }
        auto found = inspectorSampleBrokers().find(&vm);
        auto result = JSON::Object::create();
        result->setObject("profile"_s, inspectorProfile(vm, found->second, profileStart, profileWallStart));
        stopProfile();
        respond(WTF::move(result)); return true;
    }
    fail("Profiler method is not supported"_s);
    return true;
}
inline void cancelLocalInspector(JSC::JSGlobalObject* global) {
    std::vector<std::shared_ptr<LocalInspectorChannel>> channels;
    { std::lock_guard lock(localInspectorLock()); auto entry = localInspectorChannels().find(global); if (entry != localInspectorChannels().end()) channels = entry->second; }
    for (auto& channel : channels) { channel->disconnect(); channel->handle.clear(); }
    cancelInspectorRealms(global);
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
    if (!handle || !handle->channel->connected || handle->channel->disconnecting) { JSC::throwTypeError(global, scope, "Inspector session is closed"_s); return {}; }
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
    channel->responseMethods.emplace(nativeId, request->getString("method"_s));
    request->setInteger("id"_s, nativeId);
    if(request->getString("method"_s)=="Runtime.getProperties"_s) if(auto params=request->getObject("params"_s)) if(auto value=params->getValue("accessorPropertiesOnly"_s)) {
        auto enabled=value->asBoolean();
        if(!enabled) {
            auto error=JSON::Object::create();error->setInteger("code"_s,-32602);error->setString("message"_s,"accessorPropertiesOnly must be a boolean"_s);
            auto response=JSON::Object::create();response->setInteger("id"_s,nativeId);response->setObject("error"_s,WTF::move(error));channel->sendMessageToFrontend(response->toJSONString());channel->drain();return JSC::JSValue::encode(JSC::jsUndefined());
        }
        if(*enabled) channel->accessorPropertyRequests.insert(nativeId);
    }
    if (!channel->dispatchAdapter(*request) && !dispatchInspectorRealm(*channel,*request)) global->inspectorController().dispatchMessageFromFrontend(request->toJSONString());
    RETURN_IF_EXCEPTION(scope, {});
    channel->drain();
    return JSC::JSValue::encode(JSC::jsUndefined());
}
JSC_DEFINE_HOST_FUNCTION(disconnectLocalInspector, (JSC::JSGlobalObject* global, JSC::CallFrame* frame)) {
    auto* handle = dynamicDowncast<LocalInspectorHandle>(frame->argument(0));
    if (handle) { auto channel = handle->channel; channel->disconnect(true); }
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
