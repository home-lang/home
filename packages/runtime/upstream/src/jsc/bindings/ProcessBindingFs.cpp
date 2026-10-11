
#include "ProcessBindingFs.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/CompleteSubspace.h>
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

#define HOME_DIRECTORY_FUNCTION(name, operation, asynchronous) \
    JSC_DEFINE_HOST_FUNCTION(name, (JSGlobalObject* global, CallFrame* frame)) { return Home__Directory__##operation(global, frame, asynchronous); }
HOME_DIRECTORY_FUNCTION(homeOpenDirectorySync, open, false)
HOME_DIRECTORY_FUNCTION(homeOpenDirectory, open, true)
HOME_DIRECTORY_FUNCTION(homeReadDirectorySync, read, false)
HOME_DIRECTORY_FUNCTION(homeReadDirectory, read, true)
HOME_DIRECTORY_FUNCTION(homeCloseDirectorySync, close, false)
HOME_DIRECTORY_FUNCTION(homeCloseDirectory, close, true)
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
