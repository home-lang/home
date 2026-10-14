
#include "ProcessBindingFs.h"
#include "HomeFileHandleTransfer.h"
#include "BunBuiltinNames.h"
#include "InternalModuleRegistry.h"
#include <mutex>
#include <unordered_map>
#include <vector>
#include <string>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/CompleteSubspace.h>
#include <JavaScriptCore/CustomGetterSetter.h>
#include "ZigGlobalObject.h"
#include "BunProcess.h"
#include "ScriptExecutionContext.h"
#include <optional>

namespace Bun {
using namespace JSC;

extern "C" EncodedJSValue Home__Directory__open(JSGlobalObject*, CallFrame*, bool);
extern "C" EncodedJSValue Home__Directory__adopt(JSGlobalObject*, CallFrame*);
extern "C" EncodedJSValue Home__Directory__read(JSGlobalObject*, CallFrame*, bool);
extern "C" EncodedJSValue Home__Directory__close(JSGlobalObject*, CallFrame*, bool);
extern "C" void Home__Directory__release(void*);
extern "C" size_t Home__Directory__memoryCost(void*);
extern "C" bool Home__Directory__isOpen(void*);
extern "C" bool Home__Directory__hasBuffered(void*);

// The generic destructible space owns this type without changing pinned
// BunClientData or GlobalObject layouts. No raw native pointer reaches JS.
class HomeDirectoryHandle final : public JSDestructibleObject {
public:
    using Base = JSDestructibleObject;
    static constexpr unsigned StructureFlags = Base::StructureFlags;
    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;
    static size_t estimatedSize(JSCell* cell, VM& vm)
    {
        auto* object = static_cast<HomeDirectoryHandle*>(cell);
        return Base::estimatedSize(cell, vm) + Home__Directory__memoryCost(object->m_state);
    }
    void report(VM& vm)
    {
        size_t current = Home__Directory__memoryCost(m_state);
        if (current > m_reportedMemory) vm.heap.reportExtraMemoryAllocated(this, current - m_reportedMemory);
        m_reportedMemory = std::max(m_reportedMemory, current);
    }
    template<typename CellType, SubspaceAccess>
    static CompleteSubspace* subspaceFor(VM& vm) { return &vm.destructibleObjectSpace(); }
    static HomeDirectoryHandle* create(JSGlobalObject* global, void* state)
    {
        auto& vm = global->vm();
        auto* structure = Structure::create(vm, global, jsNull(), TypeInfo(ObjectType, StructureFlags), info());
        auto* object = new (NotNull, allocateCell<HomeDirectoryHandle>(vm)) HomeDirectoryHandle(vm, structure, state);
        object->finishCreation(vm);
        object->report(vm);
        return object;
    }
    static void destroy(JSCell* cell) { static_cast<HomeDirectoryHandle*>(cell)->~HomeDirectoryHandle(); }
    ~HomeDirectoryHandle()
    {
        bool abandoned = Home__Directory__isOpen(m_state);
        Home__Directory__release(m_state);
        if (abandoned && m_context) {
            // The collector performs only native cleanup. Identifier-based
            // admission delivers the warning later on the live owning thread.
            WebCore::ScriptExecutionContext::postTaskTo(*m_context, [](WebCore::ScriptExecutionContext& context) {
                auto* global = uncheckedDowncast<Zig::GlobalObject>(context.jsGlobalObject());
                auto& vm = global->vm();
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
                auto* process = global->processObject();
                auto emitWarning = process->get(global, Identifier::fromString(vm, "emitWarning"_s));
                if (!scope.exception()) {
                    MarkedArgumentBuffer arguments;
                    arguments.append(jsString(vm, WTF::String("Closing directory handle on garbage collection"_s)));
                    JSC::call(global, emitWarning, process, arguments, "process.emitWarning must be callable"_s);
                }
                if (scope.exception()) {
                    auto* exception = scope.exception();
                    (void)scope.tryClearException();
                    Bun__reportUnhandledError(global, JSValue::encode(exception));
                }
            });
        }
    }
    void* state() const { return m_state; }
private:
    HomeDirectoryHandle(VM& vm, Structure* structure, void* state) : Base(vm, structure), m_state(state)
    {
        auto* global = uncheckedDowncast<Zig::GlobalObject>(globalObject());
        if (auto* context = global->scriptExecutionContext()) m_context = context->identifier();
    }
    void* m_state;
    size_t m_reportedMemory { 0 };
    std::optional<WebCore::ScriptExecutionContextIdentifier> m_context;
};
const ClassInfo HomeDirectoryHandle::s_info = { "HomeDirectoryHandle"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(HomeDirectoryHandle) };

template<typename Visitor>
void HomeDirectoryHandle::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* object = static_cast<HomeDirectoryHandle*>(cell);
    Base::visitChildren(object, visitor);
    visitor.reportExtraMemoryVisited(Home__Directory__memoryCost(object->state()));
}
DEFINE_VISIT_CHILDREN(HomeDirectoryHandle);
extern "C" void Home__Directory__report(JSGlobalObject* global, EncodedJSValue encoded)
{
    auto* object = JSValue::decode(encoded).getObject();
    RELEASE_ASSERT(object && object->inherits(HomeDirectoryHandle::info()));
    static_cast<HomeDirectoryHandle*>(object)->report(global->vm());
}

extern "C" EncodedJSValue Home__Directory__wrap(JSGlobalObject* global, void* state)
{
    return JSValue::encode(HomeDirectoryHandle::create(global, state));
}
extern "C" void* Home__Directory__state(JSGlobalObject* global, EncodedJSValue encoded)
{
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* object = JSValue::decode(encoded).getObject();
    if (!object || !object->inherits(HomeDirectoryHandle::info())) {
        throwTypeError(global, scope, "Expected an owned directory handle"_s);
        return nullptr;
    }
    return static_cast<HomeDirectoryHandle*>(object)->state();
}

extern "C" EncodedJSValue Home__FileHandle__open(JSGlobalObject*, CallFrame*);
extern "C" EncodedJSValue Home__FileHandle__adopt(JSGlobalObject*, CallFrame*);
extern "C" EncodedJSValue Home__FileHandle__close(JSGlobalObject*, CallFrame*, bool);
extern "C" void Home__FileHandle__release(void*);
extern "C" size_t Home__FileHandle__memoryCost();
extern "C" bool Home__FileHandle__isOpen(void*);
extern "C" void Home__FileHandle__detach(void*);
extern "C" void* Home__FileHandle__take(void*);
extern "C" EncodedJSValue Home__FileHandle__receive(JSGlobalObject*, void*);
extern "C" void Home__FileHandle__releaseTransfer(void*);
extern "C" EncodedJSValue Home__FileHandle__fd(void*);
extern "C" EncodedJSValue Home__FSRequest__event(JSGlobalObject*, EncodedJSValue, EncodedJSValue, uint8_t);
JSC_DECLARE_CUSTOM_GETTER(homeFileHandleFd);
class HomeFileHandle final : public JSDestructibleObject {
public:
    using Base = JSDestructibleObject;
    static size_t estimatedSize(JSCell* cell, VM& vm) { return Base::estimatedSize(cell, vm) + Home__FileHandle__memoryCost(); }
    static constexpr unsigned StructureFlags = Base::StructureFlags;
    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;
    template<typename CellType, SubspaceAccess>
    static CompleteSubspace* subspaceFor(VM& vm) { return &vm.destructibleObjectSpace(); }
    static HomeFileHandle* create(JSGlobalObject* global, void* state)
    {
        auto& vm = global->vm();
        auto* structure = Structure::create(vm, global, jsNull(), TypeInfo(ObjectType, StructureFlags), info());
        auto* object = new (NotNull, allocateCell<HomeFileHandle>(vm)) HomeFileHandle(vm, structure, state);
        object->finishCreation(vm);
        vm.heap.reportExtraMemoryAllocated(object, Home__FileHandle__memoryCost());
        object->putDirectCustomAccessor(vm, Identifier::fromString(vm, "fd"_s), CustomGetterSetter::create(vm, homeFileHandleFd, nullptr), static_cast<unsigned>(PropertyAttribute::CustomAccessor));
        MarkedArgumentBuffer root;
        root.append(object);
        auto id = JSValue::decode(Home__FSRequest__event(global, JSValue::encode(object), JSValue::encode(jsUndefined()), 10));
        object->m_asyncId = id.isNumber() ? id.asNumber() : 0;
        return object;
    }
    static void destroy(JSCell* cell) { static_cast<HomeFileHandle*>(cell)->~HomeFileHandle(); }
    ~HomeFileHandle()
    {
        const bool abandoned = Home__FileHandle__isOpen(m_state);
        Home__FileHandle__release(m_state);
        if (abandoned && m_context) {
            WebCore::ScriptExecutionContext::postTaskTo(*m_context, [](WebCore::ScriptExecutionContext& context) {
                auto* global = uncheckedDowncast<Zig::GlobalObject>(context.jsGlobalObject());
                auto& vm = global->vm();
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
                auto* process = global->processObject();
                auto emitWarning = process->get(global, Identifier::fromString(vm, "emitWarning"_s));
                if (!scope.exception()) {
                    MarkedArgumentBuffer arguments;
                    arguments.append(jsString(vm, WTF::String("Closing FileHandle on garbage collection"_s)));
                    JSC::call(global, emitWarning, process, arguments, "process.emitWarning must be callable"_s);
                }
                if (scope.exception()) {
                    auto* exception = scope.exception();
                    (void)scope.tryClearException();
                    Bun__reportUnhandledError(global, JSValue::encode(exception));
                }
            });
        }
    }
    void* state() const { return m_state; }
    double asyncId() const { return m_asyncId; }
private:
    HomeFileHandle(VM& vm, Structure* structure, void* state) : Base(vm, structure), m_state(state)
    {
        auto* global = uncheckedDowncast<Zig::GlobalObject>(globalObject());
        if (auto* context = global->scriptExecutionContext()) m_context = context->identifier();
    }
public:
    void bind(VM& vm, JSObject* wrapper, JSObject* validator, JSValue flag)
    {
        m_wrapper.set(vm, this, wrapper);
        m_validator.set(vm, this, validator);
        m_flag.set(vm, this, flag);
    }
    JSObject* wrapper() const { return m_wrapper.get(); }
    JSObject* validator() const { return m_validator.get(); }
    JSValue flag() const { return m_flag.get(); }
private:
    WriteBarrier<JSObject> m_wrapper;
    WriteBarrier<JSObject> m_validator;
    WriteBarrier<Unknown> m_flag;
    void* m_state;
    double m_asyncId { 0 };
    std::optional<WebCore::ScriptExecutionContextIdentifier> m_context;
};
template<typename Visitor>
void HomeFileHandle::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* object = static_cast<HomeFileHandle*>(cell);
    Base::visitChildren(object, visitor);
    visitor.append(object->m_wrapper);
    visitor.append(object->m_validator);
    visitor.append(object->m_flag);
}
DEFINE_VISIT_CHILDREN(HomeFileHandle);

const ClassInfo HomeFileHandle::s_info = { "FileHandle"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(HomeFileHandle) };
extern "C" EncodedJSValue Home__FileHandle__wrap(JSGlobalObject* global, void* state)
{
    return JSValue::encode(HomeFileHandle::create(global, state));
}
static HomeFileHandle* ownedFileHandle(JSGlobalObject* global, JSValue value)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* object = value.getObject();
    if (!object || !object->inherits(HomeFileHandle::info())) {
        throwTypeError(global, scope, "Expected an owned FileHandle"_s);
        return nullptr;
    }
    return static_cast<HomeFileHandle*>(object);
}
JSC_DEFINE_CUSTOM_GETTER(homeFileHandleFd, (JSGlobalObject* global, EncodedJSValue value, PropertyName))
{
    auto* object = ownedFileHandle(global, JSValue::decode(value));
    return object ? Home__FileHandle__fd(object->state()) : EncodedJSValue {};
}
extern "C" void* Home__FileHandle__state(JSGlobalObject* global, EncodedJSValue value)
{
    auto* object = ownedFileHandle(global, JSValue::decode(value));
    return object ? object->state() : nullptr;
}
JSC_DEFINE_HOST_FUNCTION(homeBindFileHandle, (JSGlobalObject* global, CallFrame* frame))
{
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* backend = ownedFileHandle(global, frame->argument(1));
    RETURN_IF_EXCEPTION(scope, {});
    auto* wrapper = frame->argument(0).getObject();
    auto* validator = frame->argument(2).getObject();
    if (!wrapper || !validator || !validator->isCallable()) {
        throwTypeError(global, scope, "FileHandle wrapper and validator are required"_s);
        return {};
    }
    backend->bind(vm, wrapper, validator, frame->argument(3));
    wrapper->putDirect(vm, WebCore::builtinNames(vm).dataPrivateName(), backend, 0);
    return JSValue::encode(jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(homeOpenFileHandle, (JSGlobalObject* global, CallFrame* frame)) { return Home__FileHandle__open(global, frame); }
JSC_DEFINE_HOST_FUNCTION(homeAdoptFileHandle, (JSGlobalObject* global, CallFrame* frame)) { return Home__FileHandle__adopt(global, frame); }
JSC_DEFINE_HOST_FUNCTION(homeCloseFileHandle, (JSGlobalObject* global, CallFrame* frame)) { return Home__FileHandle__close(global, frame, true); }
JSC_DEFINE_HOST_FUNCTION(homeCloseFileHandleSync, (JSGlobalObject* global, CallFrame* frame)) { return Home__FileHandle__close(global, frame, false); }
JSC_DEFINE_HOST_FUNCTION(homeDetachFileHandle, (JSGlobalObject* global, CallFrame* frame))
{
    auto* object = ownedFileHandle(global, frame->argument(0));
    if (!object) return {};
    Home__FileHandle__detach(object->state());
    return JSValue::encode(jsUndefined());
}
JSC_DEFINE_HOST_FUNCTION(homeFileHandleDescriptor, (JSGlobalObject* global, CallFrame* frame))
{
    auto* object = ownedFileHandle(global, frame->argument(0));
    return object ? Home__FileHandle__fd(object->state()) : EncodedJSValue {};
}
JSC_DEFINE_HOST_FUNCTION(homeFileHandleAsyncId, (JSGlobalObject* global, CallFrame* frame))
{
    auto* object = ownedFileHandle(global, frame->argument(0));
    return object ? JSValue::encode(jsNumber(object->asyncId())) : EncodedJSValue {};
}

#define HOME_DIRECTORY_FUNCTION(name, operation, asynchronous) \
    JSC_DEFINE_HOST_FUNCTION(name, (JSGlobalObject* global, CallFrame* frame)) { return Home__Directory__##operation(global, frame, asynchronous); }
HOME_DIRECTORY_FUNCTION(homeOpenDirectorySync, open, false)
HOME_DIRECTORY_FUNCTION(homeOpenDirectory, open, true)
HOME_DIRECTORY_FUNCTION(homeReadDirectorySync, read, false)
HOME_DIRECTORY_FUNCTION(homeReadDirectory, read, true)
HOME_DIRECTORY_FUNCTION(homeCloseDirectorySync, close, false)
HOME_DIRECTORY_FUNCTION(homeCloseDirectory, close, true)
JSC_DEFINE_HOST_FUNCTION(homeDirectoryHasBufferedEntries, (JSGlobalObject* global, CallFrame* frame))
{
    void* state = Home__Directory__state(global, JSValue::encode(frame->argument(0)));
    if (!state) return {};
    return JSValue::encode(jsBoolean(Home__Directory__hasBuffered(state)));
}
#undef HOME_DIRECTORY_FUNCTION
JSC_DEFINE_HOST_FUNCTION(homeAdoptDirectorySync, (JSGlobalObject* global, CallFrame* frame)) { return Home__Directory__adopt(global, frame); }

static WTF::String makeNotImplementedError(const ASCIILiteral name)
{
    return makeString("process.binding('fs')."_s, name, " is not implemented in Bun. If that breaks something, please file an issue and include a reproducible code sample."_s);
}

#define PROCESS_BINDING_NOT_IMPLEMENTED(str)                                                                                   \
    JSC_DEFINE_HOST_FUNCTION(ProcessBinding_Fs_##str, (JSC::JSGlobalObject * lexicalGlobalObject, JSC::CallFrame * callFrame)) \
    {                                                                                                                          \
        {                                                                                                                      \
            auto& vm = JSC::getVM(lexicalGlobalObject);                                                                        \
            auto throwScope = DECLARE_THROW_SCOPE(vm);                                                                         \
            auto message = makeNotImplementedError(#str##_s);                                                                  \
            throwScope.throwException(lexicalGlobalObject, createError(lexicalGlobalObject, message));                         \
            return {};                                                                                                         \
        }                                                                                                                      \
    }

PROCESS_BINDING_NOT_IMPLEMENTED(access)

PROCESS_BINDING_NOT_IMPLEMENTED(chmod)

PROCESS_BINDING_NOT_IMPLEMENTED(chown)

PROCESS_BINDING_NOT_IMPLEMENTED(close)

PROCESS_BINDING_NOT_IMPLEMENTED(copyFile)

PROCESS_BINDING_NOT_IMPLEMENTED(cpSyncCheckPaths)

PROCESS_BINDING_NOT_IMPLEMENTED(existsSync)

PROCESS_BINDING_NOT_IMPLEMENTED(fchmod)

PROCESS_BINDING_NOT_IMPLEMENTED(fchown)

PROCESS_BINDING_NOT_IMPLEMENTED(fdatasync)

PROCESS_BINDING_NOT_IMPLEMENTED(fstat)

PROCESS_BINDING_NOT_IMPLEMENTED(fsync)

PROCESS_BINDING_NOT_IMPLEMENTED(ftruncate)

PROCESS_BINDING_NOT_IMPLEMENTED(futimes)

PROCESS_BINDING_NOT_IMPLEMENTED(getFormatOfExtensionlessFile)

PROCESS_BINDING_NOT_IMPLEMENTED(internalModuleStat)

PROCESS_BINDING_NOT_IMPLEMENTED(lchown)

PROCESS_BINDING_NOT_IMPLEMENTED(legacyMainResolve)

PROCESS_BINDING_NOT_IMPLEMENTED(link)

PROCESS_BINDING_NOT_IMPLEMENTED(lstat)

PROCESS_BINDING_NOT_IMPLEMENTED(lutimes)

PROCESS_BINDING_NOT_IMPLEMENTED(mkdir)

PROCESS_BINDING_NOT_IMPLEMENTED(mkdtemp)

PROCESS_BINDING_NOT_IMPLEMENTED(open)

PROCESS_BINDING_NOT_IMPLEMENTED(openFileHandle)

PROCESS_BINDING_NOT_IMPLEMENTED(read)

PROCESS_BINDING_NOT_IMPLEMENTED(readBuffers)

PROCESS_BINDING_NOT_IMPLEMENTED(readdir)

PROCESS_BINDING_NOT_IMPLEMENTED(readFileUtf8)

PROCESS_BINDING_NOT_IMPLEMENTED(readlink)

PROCESS_BINDING_NOT_IMPLEMENTED(realpath)

PROCESS_BINDING_NOT_IMPLEMENTED(rename)

PROCESS_BINDING_NOT_IMPLEMENTED(rmdir)

PROCESS_BINDING_NOT_IMPLEMENTED(rmSync)

PROCESS_BINDING_NOT_IMPLEMENTED(stat)

PROCESS_BINDING_NOT_IMPLEMENTED(statfs)

PROCESS_BINDING_NOT_IMPLEMENTED(StatWatcher)

PROCESS_BINDING_NOT_IMPLEMENTED(symlink)

PROCESS_BINDING_NOT_IMPLEMENTED(unlink)

PROCESS_BINDING_NOT_IMPLEMENTED(utimes)

PROCESS_BINDING_NOT_IMPLEMENTED(writeBuffer)

PROCESS_BINDING_NOT_IMPLEMENTED(writeBuffers)

PROCESS_BINDING_NOT_IMPLEMENTED(writeFileUtf8)

PROCESS_BINDING_NOT_IMPLEMENTED(writeString)

static JSValue ProcessBindingFs_statValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSFloat64Array::create(globalObject, globalObject->m_typedArrayFloat64.get(globalObject), 36);
}

static JSValue ProcessBindingFs_bigintStatValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSBigInt64Array::create(globalObject, globalObject->m_typedArrayBigInt64.get(globalObject), 36);
}

static JSValue ProcessBindingFs_statFsValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSFloat64Array::create(globalObject, globalObject->m_typedArrayFloat64.get(globalObject), 7);
}

static JSValue ProcessBindingFs_bigintStatFsValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSBigInt64Array::create(globalObject, globalObject->m_typedArrayBigInt64.get(globalObject), 7);
}

/* Source for ProcessBindingFs.lut.h
@begin processBindingFsTable
    access                          ProcessBinding_Fs_access                        Function 1
    bigintStatFsValues              ProcessBindingFs_bigintStatFsValues             PropertyCallback
    bigintStatValues                ProcessBindingFs_bigintStatValues               PropertyCallback
    chmod                           ProcessBinding_Fs_chmod                         Function 1
    chown                           ProcessBinding_Fs_chown                         Function 1
    close                           ProcessBinding_Fs_close                         Function 1
    copyFile                        ProcessBinding_Fs_copyFile                      Function 1
    cpSyncCheckPaths                ProcessBinding_Fs_cpSyncCheckPaths              Function 1
    existsSync                      ProcessBinding_Fs_existsSync                    Function 1
    fchmod                          ProcessBinding_Fs_fchmod                        Function 1
    fchown                          ProcessBinding_Fs_fchown                        Function 1
    fdatasync                       ProcessBinding_Fs_fdatasync                     Function 1
    fstat                           ProcessBinding_Fs_fstat                         Function 1
    fsync                           ProcessBinding_Fs_fsync                         Function 1
    ftruncate                       ProcessBinding_Fs_ftruncate                     Function 1
    futimes                         ProcessBinding_Fs_futimes                       Function 1
    getFormatOfExtensionlessFile    ProcessBinding_Fs_getFormatOfExtensionlessFile  Function 1
    internalModuleStat              ProcessBinding_Fs_internalModuleStat            Function 1
    kFsStatsFieldsNumber            18                                              ConstantInteger
    lchown                          ProcessBinding_Fs_lchown                        Function 1
    legacyMainResolve               ProcessBinding_Fs_legacyMainResolve             Function 1
    link                            ProcessBinding_Fs_link                          Function 1
    lstat                           ProcessBinding_Fs_lstat                         Function 1
    lutimes                         ProcessBinding_Fs_lutimes                       Function 1
    mkdir                           ProcessBinding_Fs_mkdir                         Function 1
    mkdtemp                         ProcessBinding_Fs_mkdtemp                       Function 1
    open                            ProcessBinding_Fs_open                          Function 1
    openFileHandle                  ProcessBinding_Fs_openFileHandle                Function 1
    read                            ProcessBinding_Fs_read                          Function 1
    readBuffers                     ProcessBinding_Fs_readBuffers                   Function 1
    readdir                         ProcessBinding_Fs_readdir                       Function 1
    readFileUtf8                    ProcessBinding_Fs_readFileUtf8                  Function 1
    readlink                        ProcessBinding_Fs_readlink                      Function 1
    realpath                        ProcessBinding_Fs_realpath                      Function 1
    rename                          ProcessBinding_Fs_rename                        Function 1
    rmdir                           ProcessBinding_Fs_rmdir                         Function 1
    rmSync                          ProcessBinding_Fs_rmSync                        Function 1
    stat                            ProcessBinding_Fs_stat                          Function 1
    statfs                          ProcessBinding_Fs_statfs                        Function 1
    statFsValues                    ProcessBindingFs_statFsValues                   PropertyCallback
    statValues                      ProcessBindingFs_statValues                     PropertyCallback
    StatWatcher                     ProcessBinding_Fs_StatWatcher                   Function 1
    symlink                         ProcessBinding_Fs_symlink                       Function 1
    unlink                          ProcessBinding_Fs_unlink                        Function 1
    utimes                          ProcessBinding_Fs_utimes                        Function 1
    writeBuffer                     ProcessBinding_Fs_writeBuffer                   Function 1
    writeBuffers                    ProcessBinding_Fs_writeBuffers                  Function 1
    writeFileUtf8                   ProcessBinding_Fs_writeFileUtf8                 Function 1
    writeString                     ProcessBinding_Fs_writeString                   Function 1
@end
*/
#include "ProcessBindingFs.lut.h"

const ClassInfo ProcessBindingFs::s_info = { "ProcessBindingFs"_s, &Base::s_info, &processBindingFsTable, nullptr, CREATE_METHOD_TABLE(ProcessBindingFs) };

ProcessBindingFs* ProcessBindingFs::create(VM& vm, Structure* structure)
{
    ProcessBindingFs* obj = new (NotNull, allocateCell<ProcessBindingFs>(vm)) ProcessBindingFs(vm, structure);
    obj->finishCreation(vm);
    return obj;
}

Structure* ProcessBindingFs::createStructure(VM& vm, JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(ObjectType, StructureFlags), ProcessBindingFs::info());
}

void ProcessBindingFs::finishCreation(JSC::VM& vm)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    auto* global = globalObject();
    putDirect(vm, Identifier::fromString(vm, "homeOpenFileHandle"_s), JSFunction::create(vm, global, 3, "homeOpenFileHandle"_s, homeOpenFileHandle, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeFileHandleDescriptor"_s), JSFunction::create(vm, global, 1, "homeFileHandleDescriptor"_s, homeFileHandleDescriptor, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeBindFileHandle"_s), JSFunction::create(vm, global, 4, "homeBindFileHandle"_s, homeBindFileHandle, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeDetachFileHandle"_s), JSFunction::create(vm, global, 1, "homeDetachFileHandle"_s, homeDetachFileHandle, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeAdoptFileHandle"_s), JSFunction::create(vm, global, 1, "homeAdoptFileHandle"_s, homeAdoptFileHandle, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeCloseFileHandle"_s), JSFunction::create(vm, global, 1, "homeCloseFileHandle"_s, homeCloseFileHandle, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeCloseFileHandleSync"_s), JSFunction::create(vm, global, 1, "homeCloseFileHandleSync"_s, homeCloseFileHandleSync, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeFileHandleAsyncId"_s), JSFunction::create(vm, global, 1, "homeFileHandleAsyncId"_s, homeFileHandleAsyncId, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeDirectoryHasBufferedEntries"_s), JSFunction::create(vm, global, 1, "homeDirectoryHasBufferedEntries"_s, homeDirectoryHasBufferedEntries, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeAdoptDirectorySync"_s), JSFunction::create(vm, global, 3, "homeAdoptDirectorySync"_s, homeAdoptDirectorySync, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeOpenDirectorySync"_s), JSFunction::create(vm, global, 2, "homeOpenDirectorySync"_s, homeOpenDirectorySync, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeOpenDirectory"_s), JSFunction::create(vm, global, 2, "homeOpenDirectory"_s, homeOpenDirectory, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeReadDirectorySync"_s), JSFunction::create(vm, global, 1, "homeReadDirectorySync"_s, homeReadDirectorySync, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeReadDirectory"_s), JSFunction::create(vm, global, 1, "homeReadDirectory"_s, homeReadDirectory, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeCloseDirectorySync"_s), JSFunction::create(vm, global, 1, "homeCloseDirectorySync"_s, homeCloseDirectorySync, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
    putDirect(vm, Identifier::fromString(vm, "homeCloseDirectory"_s), JSFunction::create(vm, global, 1, "homeCloseDirectory"_s, homeCloseDirectory, ImplementationVisibility::Public), static_cast<unsigned>(PropertyAttribute::DontEnum));
}

} // namespace Bun

#undef PROCESS_BINDING_NOT_IMPLEMENTED

namespace Home {
using namespace JSC;

static Bun::HomeFileHandle* fileHandleBackend(JSGlobalObject* global, JSObject* wrapper)
{
    auto value = wrapper->getDirect(global->vm(), WebCore::builtinNames(global->vm()).dataPrivateName());
    auto* backend = value ? dynamicDowncast<Bun::HomeFileHandle>(value) : nullptr;
    return backend && backend->wrapper() == wrapper ? backend : nullptr;
}

bool isFileHandle(JSGlobalObject* global, JSObject* wrapper)
{
    return fileHandleBackend(global, wrapper);
}

struct FileHandleTicket {
    void* descriptor { nullptr };
    enum class FlagKind { Undefined, Null, Number, String } flagKind { FlagKind::Undefined };
    double number { 0 };
    std::string string;
    ~FileHandleTicket()
    {
        if (descriptor) Bun::Home__FileHandle__releaseTransfer(descriptor);
    }
};
using FileHandleTickets = std::vector<std::shared_ptr<FileHandleTicket>>;
static std::mutex fileHandleTicketsLock;
static std::unordered_map<const WebCore::SerializedScriptValue*, FileHandleTickets> fileHandleTickets;
static thread_local FileHandleTransferScope* activeFileHandleTransfer;
static thread_local FileHandleReceiveScope* activeFileHandleReceive;

struct FileHandleTransferScope::Impl {
    JSGlobalObject* global;
    MarkedArgumentBuffer roots;
    std::vector<Bun::HomeFileHandle*> handles;
    std::vector<JSObject*> wrappers;
    FileHandleTickets tickets;
};

FileHandleTransferScope::FileHandleTransferScope(JSGlobalObject* global)
    : m_impl(std::make_unique<Impl>())
    , m_previous(activeFileHandleTransfer)
{
    m_impl->global = global;
    activeFileHandleTransfer = this;
}

FileHandleTransferScope::~FileHandleTransferScope()
{
    activeFileHandleTransfer = m_previous;
}

bool FileHandleTransferScope::admit(JSObject* wrapper)
{
    auto* backend = fileHandleBackend(m_impl->global, wrapper);
    if (!backend) return false;
    m_impl->roots.append(wrapper);
    m_impl->roots.append(backend);
    m_impl->handles.push_back(backend);
    m_impl->wrappers.push_back(wrapper);
    auto ticket = std::make_shared<FileHandleTicket>();
    auto flag = backend->flag();
    if (flag.isNull()) ticket->flagKind = FileHandleTicket::FlagKind::Null;
    else if (flag.isNumber()) {
        ticket->flagKind = FileHandleTicket::FlagKind::Number;
        ticket->number = flag.asNumber();
    } else if (flag.isString()) {
        ticket->flagKind = FileHandleTicket::FlagKind::String;
        auto text = flag.toWTFString(m_impl->global).utf8();
        ticket->string.assign(text.data(), text.length());
    }
    m_impl->tickets.push_back(std::move(ticket));
    return validate();
}

bool FileHandleTransferScope::validate()
{
    auto* global = m_impl->global;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    for (unsigned i = 0; i < m_impl->handles.size(); ++i) {
        MarkedArgumentBuffer args;
        auto* backend = m_impl->handles[i];
        JSC::call(global, backend->validator(), m_impl->wrappers[i], args, "FileHandle transfer validator must be callable"_s);
        RETURN_IF_EXCEPTION(scope, false);
    }
    return true;
}

bool FileHandleTransferScope::index(JSObject* wrapper, uint32_t& index)
{
    if (!activeFileHandleTransfer) return false;
    auto& wrappers = activeFileHandleTransfer->m_impl->wrappers;
    for (unsigned i = 0; i < wrappers.size(); ++i) {
        if (wrappers[i] == wrapper) {
            index = i;
            return true;
        }
    }
    return false;
}

void FileHandleTransferScope::commit(WebCore::SerializedScriptValue* value)
{
    if (m_impl->tickets.empty()) return;
    for (unsigned i = 0; i < m_impl->handles.size(); ++i) {
        // Validation runs after serialization and before any transferable is
        // detached. With the source VM rooted, this ownership move cannot race
        // its close/GC/shutdown operations.
        m_impl->tickets[i]->descriptor = Bun::Home__FileHandle__take(m_impl->handles[i]->state());
        RELEASE_ASSERT(m_impl->tickets[i]->descriptor);
    }
    std::lock_guard locker(fileHandleTicketsLock);
    fileHandleTickets.emplace(value, std::move(m_impl->tickets));
}

void releaseFileHandleTransfers(const WebCore::SerializedScriptValue* value)
{
    FileHandleTickets released;
    {
        std::lock_guard locker(fileHandleTicketsLock);
        auto found = fileHandleTickets.find(value);
        if (found == fileHandleTickets.end()) return;
        released = std::move(found->second);
        fileHandleTickets.erase(found);
    }
    // Close unclaimed descriptors outside the registry lock.
}

struct FileHandleReceiveScope::Impl {
    FileHandleTickets tickets;
    std::vector<JSValue> values;
    MarkedArgumentBuffer roots;
};

FileHandleReceiveScope::FileHandleReceiveScope(const WebCore::SerializedScriptValue* value)
    : m_impl(std::make_unique<Impl>())
    , m_previous(activeFileHandleReceive)
{
    {
        std::lock_guard locker(fileHandleTicketsLock);
        auto found = fileHandleTickets.find(value);
        if (found != fileHandleTickets.end()) {
            m_impl->tickets = std::move(found->second);
            fileHandleTickets.erase(found);
        }
    }
    m_impl->values.resize(m_impl->tickets.size());
    activeFileHandleReceive = this;
}

FileHandleReceiveScope::~FileHandleReceiveScope()
{
    activeFileHandleReceive = m_previous;
    // Unreferenced transfer-list entries and failed decodes close here, even
    // if the worker retains the SerializedScriptValue after reading its data.
}

JSValue FileHandleReceiveScope::receive(JSGlobalObject* globalObject, uint32_t index)
{
    if (!activeFileHandleReceive || index >= activeFileHandleReceive->m_impl->tickets.size()) return {};
    auto& receive = *activeFileHandleReceive->m_impl;
    if (receive.values[index]) return receive.values[index];
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* global = ::defaultGlobalObject(globalObject);
    auto module = global->internalModuleRegistry()->requireId(global, vm, Bun::InternalModuleRegistry::NodeFSPromises);
    RETURN_IF_EXCEPTION(scope, {});
    auto data = module.get(global, WebCore::builtinNames(vm).dataPrivateName());
    RETURN_IF_EXCEPTION(scope, {});
    auto constructor = data.get(global, Identifier::fromString(vm, "FileHandle"_s));
    RETURN_IF_EXCEPTION(scope, {});
    auto& ticket = *receive.tickets[index];
    auto backend = JSValue::decode(Bun::Home__FileHandle__receive(globalObject, ticket.descriptor));
    RETURN_IF_EXCEPTION(scope, {});
    if (!backend) return {};
    receive.roots.append(backend);
    JSValue flag = jsUndefined();
    switch (ticket.flagKind) {
    case FileHandleTicket::FlagKind::Undefined: break;
    case FileHandleTicket::FlagKind::Null: flag = jsNull(); break;
    case FileHandleTicket::FlagKind::Number: flag = jsNumber(ticket.number); break;
    case FileHandleTicket::FlagKind::String:
        flag = JSC::jsString(vm, String::fromUTF8(std::span<const char>(ticket.string.data(), ticket.string.size())));
        break;
    }
    MarkedArgumentBuffer args;
    args.append(backend);
    args.append(flag);
    auto result = JSC::construct(globalObject, constructor, getConstructData(constructor), args);
    RETURN_IF_EXCEPTION(scope, {});
    receive.values[index] = result;
    receive.roots.append(result);
    return result;
}
}
