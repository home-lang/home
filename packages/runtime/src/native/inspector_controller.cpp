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

    auto consoleAgent = makeUniqueRef<InspectorConsoleAgent>(context);
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

    auto consoleAgent = makeUniqueRef<InspectorConsoleAgent>(context);
    m_consoleAgent = consoleAgent.ptr();
    m_agents.append(WTF::move(consoleAgent));

    m_consoleClient = makeUnique<JSGlobalObjectConsoleClient>(m_consoleAgent);

    m_executionStopwatch->start();
}

JSGlobalObjectInspectorController::~JSGlobalObjectInspectorController()
{
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
