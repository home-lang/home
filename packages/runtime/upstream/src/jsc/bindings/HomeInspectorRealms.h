#pragma once
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ThrowScope.h>
#include <optional>
#include <JavaScriptCore/WeakInlines.h>
#include <atomic>
#include <memory>
#include <mutex>
#include "ScriptExecutionContext.h"
#include <unordered_map>
#include <wtf/text/WTFString.h>
#include <wtf/text/MakeString.h>
namespace Home {
struct InspectorRealm {
    JSC::Weak<JSC::JSGlobalObject> global;
    JSC::JSGlobalObject* owner;
    int id;
    WTF::String name, origin;
    InspectorRealm(JSC::JSGlobalObject* value, JSC::JSGlobalObject* parent, int identity, WTF::String realmName, WTF::String realmOrigin)
        : global(value), owner(parent), id(identity), name(WTF::move(realmName)), origin(WTF::move(realmOrigin)) { }
};
inline auto& inspectorRealms() {
    static thread_local auto* realms = new std::unordered_map<JSC::JSGlobalObject*, std::unique_ptr<InspectorRealm>>;
    return *realms;
}
inline std::mutex& inspectorRetirementLock() {static std::mutex lock;return lock;}
inline auto& inspectorRetirementRoutes() {
    static auto* routes=new std::unordered_map<JSC::JSGlobalObject*,std::pair<WebCore::ScriptExecutionContextIdentifier,int>>;
    return *routes;
}
inline int nextInspectorRealmID() {
    static std::atomic<int> next { 1000000 };
    return next.fetch_add(1);
}
void inspectorRealmCreated(InspectorRealm&);
void inspectorRealmDestroyed(JSC::JSGlobalObject*, int);
inline void registerInspectorRealm(JSC::JSGlobalObject* realm, JSC::JSGlobalObject* owner, WTF::String name, WTF::String origin, WebCore::ScriptExecutionContextIdentifier ownerContext) {
    int id = nextInspectorRealmID();
    if (name.isNull()) name = makeString("VM Context "_s, id);
    realm->setName(name);
    auto record = std::make_unique<InspectorRealm>(realm, owner, id, WTF::move(name), WTF::move(origin));
    auto* value = record.get();
    inspectorRealms()[realm] = WTF::move(record);
    {std::lock_guard lock(inspectorRetirementLock());inspectorRetirementRoutes()[realm]={ownerContext,id};}
    inspectorRealmCreated(*value);
}
inline void retireInspectorRealm(JSC::JSGlobalObject* realm) {
    WebCore::ScriptExecutionContextIdentifier context;
    int identity;
    {std::lock_guard lock(inspectorRetirementLock());auto found=inspectorRetirementRoutes().find(realm);if(found==inspectorRetirementRoutes().end())return;context=found->second.first;identity=found->second.second;inspectorRetirementRoutes().erase(found);}
    WebCore::ScriptExecutionContext::postTaskTo(context,[realm,identity](WebCore::ScriptExecutionContext&) {
        auto found=inspectorRealms().find(realm);if(found==inspectorRealms().end() || found->second->id!=identity)return;
        auto* owner=found->second->owner;int id=found->second->id;
        inspectorRealms().erase(found);inspectorRealmDestroyed(owner,id);
    });
}
inline void cancelInspectorRealms(JSC::JSGlobalObject* owner) {
    for(auto found=inspectorRealms().begin();found!=inspectorRealms().end();) {
        if(found->second->owner!=owner) {++found;continue;}
        {std::lock_guard lock(inspectorRetirementLock());inspectorRetirementRoutes().erase(found->first);}
        found=inspectorRealms().erase(found);
    }
}

}

namespace Bun {
class NodeVMContextOptions;
namespace NodeVM {
std::optional<JSC::EncodedJSValue> getHomeNodeVMContextOptions(JSC::JSGlobalObject*,JSC::VM&,JSC::ThrowScope&,JSC::JSValue,NodeVMContextOptions&,WTF::ASCIILiteral,JSC::JSValue*,WTF::String*,WTF::String*);
}
}
