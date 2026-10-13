#pragma once
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/WeakInlines.h>
#include <atomic>
#include <memory>
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
inline int nextInspectorRealmID() {
    static std::atomic<int> next { 1000000 };
    return next.fetch_add(1);
}
void inspectorRealmCreated(InspectorRealm&);
void inspectorRealmDestroyed(JSC::JSGlobalObject*, int);
inline void registerInspectorRealm(JSC::JSGlobalObject* realm, JSC::JSGlobalObject* owner, WTF::String name, WTF::String origin) {
    int id = nextInspectorRealmID();
    if (name.isEmpty()) name = makeString("VM Context "_s, id);
    realm->setName(name);
    auto record = std::make_unique<InspectorRealm>(realm, owner, id, WTF::move(name), WTF::move(origin));
    auto* value = record.get();
    inspectorRealms()[realm] = WTF::move(record);
    inspectorRealmCreated(*value);
}
inline void retireInspectorRealm(JSC::JSGlobalObject* realm) {
    auto found = inspectorRealms().find(realm);
    if (found == inspectorRealms().end()) return;
    auto* owner = found->second->owner;
    int id = found->second->id;
    inspectorRealms().erase(found);
    inspectorRealmDestroyed(owner, id);
}
}
