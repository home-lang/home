#pragma once
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ConsoleClient.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <JavaScriptCore/ThrowScope.h>
#include <optional>
#include <JavaScriptCore/WeakInlines.h>
#include <atomic>
#include <memory>
#include <mutex>
#include "ScriptExecutionContext.h"
#include <unordered_map>
#include <vector>
#include <wtf/text/WTFString.h>
#include <wtf/text/MakeString.h>
#include <wtf/JSONValues.h>
namespace Inspector { class ConsoleMessage; }
namespace Home {
bool inspectorHasConsoleListeners(JSC::JSGlobalObject&);
bool inspectorHasConsoleSessions(JSC::JSGlobalObject&);
bool isInspectorConsoleRealm(JSC::JSGlobalObject&);
std::vector<WTF::String> inspectorConsoleHistory(JSC::JSGlobalObject&);
void clearInspectorConsoleHistory(JSC::JSGlobalObject&);
void inspectorConsoleMessage(Inspector::ConsoleMessage&);
void inspectorConsoleCount(JSC::JSGlobalObject&, const WTF::String&, bool reset);
void inspectorConsoleTime(JSC::JSGlobalObject&, const WTF::String&);
void inspectorConsoleTiming(JSC::JSGlobalObject&, const WTF::String&, Inspector::ScriptArguments*);
void inspectorConsoleArguments(JSC::JSGlobalObject&, JSC::MessageType, JSC::MessageLevel, WTF::Ref<Inspector::ScriptArguments>&&);
std::unique_ptr<JSC::ConsoleClient> createInspectorRealmConsoleClient(JSC::JSGlobalObject&);
void deliverInspectorConsoleMessage(JSC::JSGlobalObject&, const WTF::String&);
bool inspectorObjectIsPromise(JSC::JSGlobalObject&, const WTF::String&);
struct InspectorRealm {
    JSC::Weak<JSC::JSGlobalObject> global;
    std::unique_ptr<JSC::ConsoleClient> consoleClient;
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
    static std::atomic<int> next { 1 };
    return next.fetch_add(1);
}
inline auto& inspectorOwnerIdentities() {
    static thread_local auto* identities=new std::unordered_map<JSC::JSGlobalObject*,int>;
    return *identities;
}
inline int inspectorOwnerIdentity(JSC::JSGlobalObject* global) {
    auto [entry,inserted]=inspectorOwnerIdentities().try_emplace(global,0);
    if(inserted) entry->second=nextInspectorRealmID();
    return entry->second;
}
void inspectorRealmCreated(InspectorRealm&);
void inspectorRealmDestroyed(JSC::JSGlobalObject*, int);
inline void registerInspectorRealm(JSC::JSGlobalObject* realm, JSC::JSGlobalObject* owner, WTF::String name, WTF::String origin, WebCore::ScriptExecutionContextIdentifier ownerContext) {
    inspectorOwnerIdentity(owner);
    int id = nextInspectorRealmID();
    if (name.isNull()) name = makeString("VM Context "_s, id);
    realm->setName(name);
    auto record = std::make_unique<InspectorRealm>(realm, owner, id, WTF::move(name), WTF::move(origin));
    record->consoleClient=createInspectorRealmConsoleClient(*realm);
    realm->setConsoleClient(record->consoleClient.get());
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
    inspectorOwnerIdentities().erase(owner);
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
