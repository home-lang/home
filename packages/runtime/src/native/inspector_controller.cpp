// Owned from oven-sh/WebKit cd821fecca0d39c8bac874c283d956868c7f0de0.
/*
 * Copyright (C) 2014-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "root.h"
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>

#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/ConsoleMessage.h>
#include <JavaScriptCore/ErrorHandlingScope.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/InjectedScriptHost.h>
#include <JavaScriptCore/InjectedScriptManager.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <JavaScriptCore/InjectedScript.h>
#include <JavaScriptCore/ScriptCallStackFactory.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include "HomeInspectorRealms.h"
#include <JavaScriptCore/DeferGC.h>
#include <mutex>
#include <unordered_map>
#include <JavaScriptCore/InspectorAgent.h>
#include <JavaScriptCore/InspectorBackendDispatcher.h>
#include <JavaScriptCore/InspectorConsoleAgent.h>
#include <JavaScriptCore/InspectorFrontendRouter.h>
#include <JavaScriptCore/InspectorHeapAgent.h>
#include <JavaScriptCore/InspectorScriptProfilerAgent.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSGlobalObjectAuditAgent.h>
#include <JavaScriptCore/JSGlobalObjectConsoleClient.h>
#include <JavaScriptCore/JSGlobalObjectDebugger.h>
#include <JavaScriptCore/JSGlobalObjectDebuggerAgent.h>
#include <JavaScriptCore/JSGlobalObjectRuntimeAgent.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include <JavaScriptCore/ScriptCallStackFactory.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <wtf/StackTrace.h>
#include <wtf/Stopwatch.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(REMOTE_INSPECTOR)
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/RemoteInspector.h>
#endif

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN

namespace Home {
// Access the canonical injected-script registry without changing the pinned
// controller ABI. Entries are non-owning and retire with their controller.
static std::mutex inspectorManagerLock;
static auto* inspectorManagers = new std::unordered_map<JSC::JSGlobalObject*, Inspector::InjectedScriptManager*>;
// Read the SDK's canonical records rather than maintaining parallel counters
// or timers in the protocol bridge. The subclass does not change SDK layouts.
class HomeInspectorConsoleAgent final : public Inspector::InspectorConsoleAgent {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(HomeInspectorConsoleAgent);
public:
    explicit HomeInspectorConsoleAgent(Inspector::AgentContext& context)
        : Inspector::InspectorConsoleAgent(context) { }
    struct ProtocolRecord {
        WTF::String type;
        WTF::RefPtr<Inspector::ScriptCallStack> stack;
        bool prefixText;
    };
    struct Snapshot {
        std::unique_ptr<Inspector::ConsoleMessage> message;
        ProtocolRecord protocol;
    };
    std::unordered_map<const Inspector::ConsoleMessage*, ProtocolRecord> protocolRecords;
    void rememberLast(JSC::JSGlobalObject& global, const WTF::String& type, bool prefixText) {
        // Metadata describes canonical SDK records; it stores no JS values.
        std::erase_if(protocolRecords, [&](const auto& entry) {
            for (auto& message : m_consoleMessages) if (message.get() == entry.first) return false;
            return true;
        });
        if (m_consoleMessages.isEmpty()) return;
        protocolRecords.insert_or_assign(m_consoleMessages.last().get(), ProtocolRecord { type, Inspector::createScriptCallStackForConsole(&global), prefixText });
    }
    std::vector<Snapshot> snapshot(JSC::JSGlobalObject& global, bool lastOnly = false) const {
        std::vector<Snapshot> result;
        for (size_t i = lastOnly && !m_consoleMessages.isEmpty() ? m_consoleMessages.size() - 1 : 0; i < m_consoleMessages.size(); ++i) {
            auto& record = *m_consoleMessages[i];
            auto found = protocolRecords.find(&record);
            if (record.source() != JSC::MessageSource::ConsoleAPI || found == protocolRecords.end()) continue;
            auto arguments = record.arguments() ? WTF::Ref<Inspector::ScriptArguments>(*record.arguments()) : Inspector::ScriptArguments::create(&global, { });
            auto message = std::make_unique<Inspector::ConsoleMessage>(record.source(), record.type(), record.level(), record.message(), WTF::move(arguments), &global, 0, record.timestamp());
            result.push_back({ WTF::move(message), found->second });
        }
        return result;
    }
    bool hasCounter(const WTF::String& label) const { return m_counts.contains(label); }
    bool hasTimer(const WTF::String& label) const { return m_times.contains(label); }
};
static auto* inspectorConsoleAgents = new std::unordered_map<JSC::JSGlobalObject*, HomeInspectorConsoleAgent*>;
static HomeInspectorConsoleAgent* consoleAgentFor(JSC::JSGlobalObject& global) {
    // Console state exists before a frontend attaches and survives Runtime.disable.
    (void)global.inspectorController();
    std::lock_guard lock(inspectorManagerLock);
    auto found = inspectorConsoleAgents->find(&global);
    return found == inspectorConsoleAgents->end() ? nullptr : found->second;
}

static void registerInspectorConsoleAgent(JSC::JSGlobalObject& global, HomeInspectorConsoleAgent& agent) {
    std::lock_guard lock(inspectorManagerLock);
    (*inspectorConsoleAgents)[&global] = &agent;
}
static void retireInspectorConsoleAgent(JSC::JSGlobalObject& global) {
    // Global finalization can run off the owner thread. Retire the shared
    // non-owning entry, as for the injected-script registry below.
    std::lock_guard lock(inspectorManagerLock);
    inspectorConsoleAgents->erase(&global);
}
static void registerInspectorManager(JSC::JSGlobalObject& global, Inspector::InjectedScriptManager& manager) {
    std::lock_guard lock(inspectorManagerLock); (*inspectorManagers)[&global] = &manager;
}
static void retireInspectorManager(JSC::JSGlobalObject& global, Inspector::InjectedScriptManager& manager) {
    std::lock_guard lock(inspectorManagerLock); auto found = inspectorManagers->find(&global);
    if (found != inspectorManagers->end() && found->second == &manager) inspectorManagers->erase(found);
}
bool inspectorObjectIsPromise(JSC::JSGlobalObject& global, const WTF::String& id) {
    Inspector::InjectedScriptManager* manager;
    { std::lock_guard lock(inspectorManagerLock); auto found = inspectorManagers->find(&global);
      if (found == inspectorManagers->end()) return false; manager = found->second; }
    // The caller holds the VM lock and keeps this global alive throughout
    // frontend delivery. Inspect the native value, never a user class name.
    JSC::DeferGC deferGC(global.vm());
    auto value = manager->injectedScriptFor(&global).findObjectById(id);
    return value && WTF::dynamicDowncast<JSC::JSPromise>(value) != nullptr;
}
static WTF::String inspectorConsoleMessageJSON(Inspector::ConsoleMessage& message, const WTF::String& overrideType, Inspector::ScriptCallStack* recordedStack = nullptr, bool prefixText = false) {
    auto* global = message.globalObject();
    if (!global || message.source() != JSC::MessageSource::ConsoleAPI) return { };
    Inspector::InjectedScriptManager* manager;
    { std::lock_guard lock(inspectorManagerLock); auto found=inspectorManagers->find(global);
      if(found==inspectorManagers->end()) return { }; manager=found->second; }
    JSC::DeferGC deferGC(global->vm());
    auto params=JSON::Object::create();
    WTF::String type="log"_s;
    switch(message.type()) {
    case JSC::MessageType::Dir: type="dir"_s;break;
    case JSC::MessageType::DirXML: type="dirxml"_s;break;
    case JSC::MessageType::Table: type="table"_s;break;
    case JSC::MessageType::Trace: type="trace"_s;break;
    case JSC::MessageType::StartGroup: type="startGroup"_s;break;
    case JSC::MessageType::StartGroupCollapsed: type="startGroupCollapsed"_s;break;
    case JSC::MessageType::EndGroup: type="endGroup"_s;break;
    case JSC::MessageType::Clear: type="clear"_s;break;
    case JSC::MessageType::Assert: type="assert"_s;break;
    case JSC::MessageType::Timing: type="timeEnd"_s;break;
    default:
        switch(message.level()) {
        case JSC::MessageLevel::Warning:type="warning"_s;break;
        case JSC::MessageLevel::Error:type="error"_s;break;
        case JSC::MessageLevel::Debug:type="debug"_s;break;
        case JSC::MessageLevel::Info:type="info"_s;break;
        default:break;
        }
    }
    params->setString("type"_s,overrideType.isEmpty() ? type : overrideType);
    params->setDouble("timestamp"_s,message.timestamp().secondsSinceEpoch().value()*1000);
    auto args=JSON::Array::create();
    auto script=manager->injectedScriptFor(global);
    if (prefixText || !message.argumentCount()) {
        if (prefixText || !message.message().isEmpty()) {
            auto argument = JSON::Object::create();
            argument->setString("type"_s, "string"_s);
            argument->setString("value"_s, message.message());
            args->pushObject(WTF::move(argument));
        }
    }
    if(auto* arguments=message.arguments()) {
        for(size_t i=0;i<arguments->argumentCount();++i) {
            auto wrapped=script.wrapObject(arguments->argumentAt(i),"console"_s,true);
            if(wrapped) args->pushObject(wrapped.releaseNonNull());
        }
    } else if (!args->length()) {
        auto argument=JSON::Object::create();argument->setString("type"_s,"string"_s);argument->setString("value"_s,message.message());args->pushObject(WTF::move(argument));
    }
    if (!args->length() && (message.type() == JSC::MessageType::EndGroup || message.type() == JSC::MessageType::Clear)) {
        auto argument = JSON::Object::create();
        argument->setString("type"_s, "string"_s);
        argument->setString("value"_s, message.type() == JSC::MessageType::Clear ? "console.clear"_s : "console.groupEnd"_s);
        args->pushObject(WTF::move(argument));
    }
    params->setArray("args"_s,WTF::move(args));
    WTF::RefPtr<Inspector::ScriptCallStack> nativeStack = recordedStack;
    if (!nativeStack) nativeStack = Inspector::createScriptCallStackForConsole(global);
    auto frames=JSON::Array::create();
    for(size_t i=0;i<nativeStack->size();++i) {
        auto& frame=nativeStack->at(i);
        if(frame.isNative()) continue;
        auto result=JSON::Object::create();
        result->setString("functionName"_s,frame.functionName());
        result->setString("scriptId"_s,WTF::String::number(frame.sourceID()));
        result->setString("url"_s,frame.sourceURL());
        result->setInteger("lineNumber"_s,frame.lineNumber()?frame.lineNumber()-1:0);
        result->setInteger("columnNumber"_s,frame.columnNumber()?frame.columnNumber()-1:0);
        frames->pushObject(WTF::move(result));
    }
    auto stack=JSON::Object::create();stack->setArray("callFrames"_s,WTF::move(frames));params->setObject("stackTrace"_s,WTF::move(stack));
    auto event=JSON::Object::create();event->setString("method"_s,"Runtime.consoleAPICalled"_s);event->setObject("params"_s,WTF::move(params));
    return event->toJSONString();
}

void inspectorConsoleMessage(Inspector::ConsoleMessage& message) {
    auto* global = message.globalObject();
    if (!global || !inspectorHasConsoleListeners(*global)) return;
    auto event = inspectorConsoleMessageJSON(message, ""_s);
    if (!event.isEmpty()) deliverInspectorConsoleMessage(*global, event);
}
static void publishConsoleRecord(JSC::JSGlobalObject& global, const WTF::String& type, bool prefixText = false) {
    auto* agent = consoleAgentFor(global);
    if (!agent) return;
    agent->rememberLast(global, type, prefixText);
    if (!inspectorHasConsoleListeners(global)) return;
    auto records = agent->snapshot(global, true);
    for (auto& record : records) {
        auto event = inspectorConsoleMessageJSON(*record.message, record.protocol.type, record.protocol.stack.get(), record.protocol.prefixText);
        if (!event.isEmpty()) deliverInspectorConsoleMessage(global, event);
    }
}
std::vector<WTF::String> inspectorConsoleHistory(JSC::JSGlobalObject& global) {
    std::vector<WTF::String> result;
    auto* agent = consoleAgentFor(global);
    if (!agent) return result;
    // Snapshot all native arguments before replay can enter JavaScript and clear the SDK buffer.
    auto records = agent->snapshot(global);
    for (auto& record : records) {
        auto event = inspectorConsoleMessageJSON(*record.message, record.protocol.type, record.protocol.stack.get(), record.protocol.prefixText);
        if (!event.isEmpty()) result.push_back(WTF::move(event));
    }
    return result;
}
void clearInspectorConsoleHistory(JSC::JSGlobalObject& global) {
    if (auto* agent = consoleAgentFor(global)) {
        std::ignore = agent->clearMessages();
        agent->protocolRecords.clear();
    }
}
void inspectorConsoleCount(JSC::JSGlobalObject& global, const WTF::String& label, bool reset) {
    auto* agent = consoleAgentFor(global);
    if (!agent) return;
    bool exists = agent->hasCounter(label);
    if (reset) agent->countReset(&global, label); else agent->count(&global, label);
    if (reset && exists) return;
    publishConsoleRecord(global, reset ? "warning"_s : "count"_s);
}
void inspectorConsoleTime(JSC::JSGlobalObject& global, const WTF::String& label) {
    auto* agent = consoleAgentFor(global);
    if (!agent) return;
    bool exists = agent->hasTimer(label);
    agent->startTiming(&global, label);
    if (exists) publishConsoleRecord(global, "warning"_s);
}
void inspectorConsoleTiming(JSC::JSGlobalObject& global, const WTF::String& label, Inspector::ScriptArguments* arguments) {
    // Preserve the SDK inspection policy; its buffered arguments are the real
    // strong owner until the console buffer and remote object group are cleared.
    if (arguments && !global.inspectorController().developerExtrasEnabled()) return;
    auto* agent = consoleAgentFor(global);
    if (!agent) return;
    bool exists = agent->hasTimer(label);
    if (arguments) agent->logTiming(&global, label, WTF::Ref<Inspector::ScriptArguments>(*arguments)); else agent->stopTiming(&global, label);
    publishConsoleRecord(global, exists ? (arguments ? "log"_s : "timeEnd"_s) : "warning"_s, exists && arguments);
}

void inspectorConsoleArguments(JSC::JSGlobalObject& global,JSC::MessageType,JSC::MessageLevel,WTF::Ref<Inspector::ScriptArguments>&&) {
    if (!global.inspectorController().developerExtrasEnabled()) return;
    publishConsoleRecord(global, ""_s);
}
class HomeInspectorVMConsoleClient final : public JSC::ConsoleClient {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(HomeInspectorVMConsoleClient);
public:
    explicit HomeInspectorVMConsoleClient(JSC::ConsoleClient* client):delegate(client) { }
    void messageWithTypeAndLevel(JSC::MessageType type,JSC::MessageLevel level,JSC::JSGlobalObject* global,WTF::Ref<Inspector::ScriptArguments>&& arguments) final {
        if(auto* client=delegate.get()) client->messageWithTypeAndLevel(type,level,global,arguments.copyRef());
        inspectorConsoleArguments(*global,type,level,WTF::move(arguments));
    }
    void count(JSC::JSGlobalObject* global,const WTF::String& label) final { inspectorConsoleCount(*global,label,false); }
    void countReset(JSC::JSGlobalObject* global,const WTF::String& label) final { inspectorConsoleCount(*global,label,true); }
    void profile(JSC::JSGlobalObject* global,const WTF::String& label) final { if(auto* client=delegate.get()) client->profile(global,label); }
    void profileEnd(JSC::JSGlobalObject* global,const WTF::String& label) final { if(auto* client=delegate.get()) client->profileEnd(global,label); }
    void takeHeapSnapshot(JSC::JSGlobalObject* global,const WTF::String& label) final { if(auto* client=delegate.get()) client->takeHeapSnapshot(global,label); }
    void time(JSC::JSGlobalObject* global,const WTF::String& label) final { inspectorConsoleTime(*global,label); }
    void timeEnd(JSC::JSGlobalObject* global,const WTF::String& label) final { inspectorConsoleTiming(*global,label,nullptr); }
    void timeLog(JSC::JSGlobalObject* global,const WTF::String& label,WTF::Ref<Inspector::ScriptArguments>&& arguments) final { inspectorConsoleTiming(*global,label,arguments.ptr()); }
    void timeStamp(JSC::JSGlobalObject* global,WTF::Ref<Inspector::ScriptArguments>&& arguments) final { if(auto* client=delegate.get()) client->timeStamp(global,WTF::move(arguments)); }
    void record(JSC::JSGlobalObject* global,WTF::Ref<Inspector::ScriptArguments>&& arguments) final { if(auto* client=delegate.get()) client->record(global,WTF::move(arguments)); }
    void recordEnd(JSC::JSGlobalObject* global,WTF::Ref<Inspector::ScriptArguments>&& arguments) final { if(auto* client=delegate.get()) client->recordEnd(global,WTF::move(arguments)); }
    void screenshot(JSC::JSGlobalObject* global,WTF::Ref<Inspector::ScriptArguments>&& arguments) final { if(auto* client=delegate.get()) client->screenshot(global,WTF::move(arguments)); }
private:
    WTF::WeakPtr<JSC::ConsoleClient> delegate;
};
std::unique_ptr<JSC::ConsoleClient> createInspectorRealmConsoleClient(JSC::JSGlobalObject& global) {
    return std::make_unique<HomeInspectorVMConsoleClient>(global.consoleClient().get());
}

}

namespace Inspector {

using namespace JSC;

WTF_MAKE_TZONE_ALLOCATED_IMPL(JSGlobalObjectInspectorController);

#if USE(BUN_JSC_ADDITIONS)
JSGlobalObjectInspectorController::JSGlobalObjectInspectorController(JSGlobalObject& globalObject, Ref<InjectedScriptHost>&& host)
    : m_globalObject(globalObject)
    , m_injectedScriptManager(makeUniqueRef<InjectedScriptManager>(*this, WTF::move(host)))
    , m_executionStopwatch(Stopwatch::create())
    , m_frontendRouter(FrontendRouter::create())
    , m_backendDispatcher(BackendDispatcher::create(m_frontendRouter.copyRef()))
{
    Home::registerInspectorManager(m_globalObject, m_injectedScriptManager.get());
    auto context = jsAgentContext();

    auto consoleAgent = makeUniqueRef<Home::HomeInspectorConsoleAgent>(context);
    Home::registerInspectorConsoleAgent(m_globalObject, consoleAgent.get());
    m_consoleAgent = consoleAgent.ptr();
    m_agents.append(WTF::move(consoleAgent));

    m_consoleClient = makeUnique<JSGlobalObjectConsoleClient>(m_consoleAgent);

    m_executionStopwatch->start();
}
#endif

JSGlobalObjectInspectorController::JSGlobalObjectInspectorController(JSGlobalObject& globalObject)
    : m_globalObject(globalObject)
    , m_injectedScriptManager(makeUniqueRef<InjectedScriptManager>(*this, InjectedScriptHost::create()))
    , m_executionStopwatch(Stopwatch::create())
    , m_frontendRouter(FrontendRouter::create())
    , m_backendDispatcher(BackendDispatcher::create(m_frontendRouter.copyRef()))
{
    Home::registerInspectorManager(m_globalObject, m_injectedScriptManager.get());
    auto context = jsAgentContext();

    auto consoleAgent = makeUniqueRef<Home::HomeInspectorConsoleAgent>(context);
    Home::registerInspectorConsoleAgent(m_globalObject, consoleAgent.get());
    m_consoleAgent = consoleAgent.ptr();
    m_agents.append(WTF::move(consoleAgent));

    m_consoleClient = makeUnique<JSGlobalObjectConsoleClient>(m_consoleAgent);

    m_executionStopwatch->start();
}

JSGlobalObjectInspectorController::~JSGlobalObjectInspectorController()
{
    Home::retireInspectorConsoleAgent(m_globalObject);
    Home::retireInspectorManager(m_globalObject, m_injectedScriptManager.get());
    // Non-owning checked agent references must be released before the agent
    // registry members are destroyed (C++ destroys m_agents before these).
    m_inspectorAgent = nullptr;
    m_consoleClient->setPersistentHeapAgent(nullptr);
    m_consoleClient->setPersistentScriptProfilerAgent(nullptr);
    m_consoleClient->setDebuggerAgent(nullptr);
#if ENABLE(INSPECTOR_ALTERNATE_DISPATCHERS)
    if (m_augmentingClient)
        m_augmentingClient->inspectorControllerDestroyed();
#endif
}

void JSGlobalObjectInspectorController::globalObjectDestroyed()
{
    ASSERT(!m_frontendRouter->hasFrontends());

    m_injectedScriptManager->disconnect();

    m_agents.discardValues();

    m_debugger = nullptr;
}

void JSGlobalObjectInspectorController::connectFrontend(FrontendChannel& frontendChannel, bool isAutomaticInspection, bool immediatelyPause)
{
    m_isAutomaticInspection = isAutomaticInspection;
    m_pauseAfterInitialization = immediatelyPause;

    createLazyAgents();

    bool connectedFirstFrontend = !m_frontendRouter->hasFrontends();
    m_frontendRouter->connectFrontend(frontendChannel);

    if (!connectedFirstFrontend)
        return;

    // Keep the JSGlobalObject and VM alive while we are debugging it.
    m_strongVM = &m_globalObject.vm();
    m_strongGlobalObject.set(m_globalObject.vm(), &m_globalObject);

    // FIXME: change this to notify agents which frontend has connected (by id).
    m_agents.didCreateFrontendAndBackend();

#if ENABLE(INSPECTOR_ALTERNATE_DISPATCHERS)
    if (m_augmentingClient)
        m_augmentingClient->inspectorConnected();
#endif
}

void JSGlobalObjectInspectorController::disconnectFrontend(FrontendChannel& frontendChannel)
{
    // Agents belong to the shared controller. A single frontend detaching
    // must not disable runtime/debugger state used by remaining frontends.
    m_frontendRouter->disconnectFrontend(frontendChannel);
    bool disconnectedLastFrontend = !m_frontendRouter->hasFrontends();
    if (!disconnectedLastFrontend)
        return;
    m_agents.willDestroyFrontendAndBackend(DisconnectReason::InspectorDestroyed);
    m_isAutomaticInspection = false;
    m_pauseAfterInitialization = false;

#if ENABLE(INSPECTOR_ALTERNATE_DISPATCHERS)
    if (m_augmentingClient)
        m_augmentingClient->inspectorDisconnected();
#endif

    // Remove our JSGlobalObject and VM references, we are done debugging it.
    m_strongGlobalObject.clear();
    m_strongVM = nullptr;
}

void JSGlobalObjectInspectorController::dispatchMessageFromFrontend(const String& message)
{
    m_backendDispatcher->dispatch(message);
}

void JSGlobalObjectInspectorController::appendAPIBacktrace(ScriptCallStack& callStack)
{
    static constexpr int framesToShow = 31;
    static constexpr int framesToSkip = 3; // WTFGetBacktrace, appendAPIBacktrace, reportAPIException.

    void* samples[framesToShow + framesToSkip];
    int frames = framesToShow + framesToSkip;
    WTFGetBacktrace(samples, &frames);

    void** stack = samples + framesToSkip;
    int size = frames - framesToSkip;
    for (int i = 0; i < size; ++i) {
        auto demangled = StackTraceSymbolResolver::demangle(stack[i]);
        if (demangled)
            callStack.append(ScriptCallFrame(String::fromLatin1(demangled->demangledName() ? demangled->demangledName() : demangled->mangledName()), "[native code]"_s, noSourceID, {}));
        else
            callStack.append(ScriptCallFrame("?"_s, "[native code]"_s, noSourceID, {}));
    }
}

void JSGlobalObjectInspectorController::reportAPIException(JSGlobalObject* globalObject, Exception* exception)
{
    VM& vm = globalObject->vm();
#if ENABLE(REMOTE_INSPECTOR)
    if (vm.isTerminationException(exception) || !m_didCreateLazyAgents || !m_globalObject.inspectorDebuggable().inspectable())
        return;
#else
    if (vm.isTerminationException(exception) || !m_didCreateLazyAgents)
        return;
#endif

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    ErrorHandlingScope errorScope(vm);

    Ref<ScriptCallStack> callStack = createScriptCallStackFromException(globalObject, exception);
    if (includesNativeCallStackWhenReportingExceptions())
        appendAPIBacktrace(callStack.get());

    // FIXME: <http://webkit.org/b/115087> Web Inspector: Should not evaluate JavaScript handling exceptions
    // If this is a custom exception object, call toString on it to try and get a nice string representation for the exception.
    String errorMessage = exception->value().toWTFString(globalObject);
    scope.clearException();

    if (JSGlobalObjectConsoleClient::logToSystemConsole()) {
        if (callStack->size()) {
            const ScriptCallFrame& callFrame = callStack->at(0);
            ConsoleClient::printConsoleMessage(MessageSource::JS, MessageType::Log, MessageLevel::Error, errorMessage, callFrame.sourceURL(), callFrame.lineNumber(), callFrame.columnNumber());
        } else
            ConsoleClient::printConsoleMessage(MessageSource::JS, MessageType::Log, MessageLevel::Error, errorMessage, String(), 0, 0);
    }

    m_consoleAgent->addMessageToConsole(makeUnique<ConsoleMessage>(MessageSource::JS, MessageType::Log, MessageLevel::Error, errorMessage, WTF::move(callStack)));
}

CheckedPtr<ConsoleClient> JSGlobalObjectInspectorController::consoleClient() const
{
    return m_consoleClient.get();
}

bool JSGlobalObjectInspectorController::developerExtrasEnabled() const
{
    if (Home::isInspectorConsoleRealm(m_globalObject) || Home::inspectorHasConsoleSessions(m_globalObject)) return true;
#if ENABLE(REMOTE_INSPECTOR)
    if (!RemoteInspector::singleton().enabled())
        return false;

    if (!m_globalObject.inspectorDebuggable().allowsInspectionByPolicy())
        return false;
#endif

    return true;
}

InspectorFunctionCallHandler JSGlobalObjectInspectorController::functionCallHandler() const
{
    return JSC::call;
}

InspectorEvaluateHandler JSGlobalObjectInspectorController::evaluateHandler() const
{
    return JSC::evaluate;
}

void JSGlobalObjectInspectorController::frontendInitialized()
{
    if (m_pauseAfterInitialization) {
        m_pauseAfterInitialization = false;

        std::ignore = ensureDebuggerAgent().enable();
        std::ignore = ensureDebuggerAgent().pause();
    }

#if ENABLE(REMOTE_INSPECTOR)
    if (m_isAutomaticInspection)
        m_globalObject.inspectorDebuggable().unpauseForResolvedAutomaticInspection();
#endif
}

Stopwatch& JSGlobalObjectInspectorController::executionStopwatch() const
{
    return m_executionStopwatch;
}

JSC::Debugger* JSGlobalObjectInspectorController::debugger()
{
    ASSERT_IMPLIES(m_didCreateLazyAgents, m_debugger);
    return m_debugger.get();
}

VM& JSGlobalObjectInspectorController::vm()
{
    return m_globalObject.vm();
}

#if ENABLE(INSPECTOR_ALTERNATE_DISPATCHERS)
void JSGlobalObjectInspectorController::registerAlternateAgent(UniqueRef<InspectorAgentBase>&& agent)
{
    // FIXME: change this to notify agents which frontend has connected (by id).
    agent->didCreateFrontendAndBackend();

    m_agents.append(WTF::move(agent));
}
#endif

InspectorAgent& JSGlobalObjectInspectorController::ensureInspectorAgent()
{
    if (!m_inspectorAgent) {
        auto context = jsAgentContext();
        auto inspectorAgent = makeUniqueRef<InspectorAgent>(context);
        m_inspectorAgent = inspectorAgent.ptr();
        m_agents.append(WTF::move(inspectorAgent));
    }
    return *m_inspectorAgent;
}

InspectorDebuggerAgent& JSGlobalObjectInspectorController::ensureDebuggerAgent()
{
    if (!m_debuggerAgent) {
        auto context = jsAgentContext();
        auto debuggerAgent = makeUniqueRef<JSGlobalObjectDebuggerAgent>(context, m_consoleAgent);
        m_debuggerAgent = debuggerAgent.ptr();
        m_consoleClient->setDebuggerAgent(m_debuggerAgent);
        m_agents.append(WTF::move(debuggerAgent));
    }
    return *m_debuggerAgent;
}

JSAgentContext JSGlobalObjectInspectorController::jsAgentContext()
{
    AgentContext baseContext = {
        *this,
        m_injectedScriptManager.get(),
        m_frontendRouter.get(),
        m_backendDispatcher
    };

    JSAgentContext context = {
        baseContext,
        m_globalObject
    };

    return context;
}

void JSGlobalObjectInspectorController::createLazyAgents()
{
    if (m_didCreateLazyAgents)
        return;

    m_didCreateLazyAgents = true;

    m_debugger = makeUnique<JSGlobalObjectDebugger>(m_globalObject);

    auto context = jsAgentContext();

    ensureInspectorAgent();

    m_agents.append(makeUniqueRef<JSGlobalObjectRuntimeAgent>(context));

    ensureDebuggerAgent();

    auto scriptProfilerAgent = makeUniqueRef<InspectorScriptProfilerAgent>(context);
    m_consoleClient->setPersistentScriptProfilerAgent(scriptProfilerAgent.ptr());
    m_agents.append(WTF::move(scriptProfilerAgent));

    auto heapAgent = makeUniqueRef<InspectorHeapAgent>(context);
    m_consoleClient->setPersistentHeapAgent(heapAgent.ptr());
    m_agents.append(WTF::move(heapAgent));

    m_agents.append(makeUniqueRef<JSGlobalObjectAuditAgent>(context));
}

} // namespace Inspector

WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
