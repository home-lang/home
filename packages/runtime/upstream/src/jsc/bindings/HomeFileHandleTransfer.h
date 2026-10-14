#pragma once

#include <JavaScriptCore/JSValue.h>
#include <memory>

namespace JSC {
class JSGlobalObject;
class JSObject;
}
namespace WebCore {
class SerializedScriptValue;
}

namespace Home {
// The wire stream contains only a slot into the serialized value's native
// descriptor owners. Ordinary JavaScript properties cannot create this brand.
bool isFileHandle(JSC::JSGlobalObject*, JSC::JSObject*);

class FileHandleTransferScope {
public:
    explicit FileHandleTransferScope(JSC::JSGlobalObject*);
    ~FileHandleTransferScope();
    bool admit(JSC::JSObject*);
    bool validate();
    void commit(WebCore::SerializedScriptValue*);
    static bool index(JSC::JSObject*, uint32_t&);
private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    FileHandleTransferScope* m_previous;
};

class FileHandleReceiveScope {
public:
    explicit FileHandleReceiveScope(const WebCore::SerializedScriptValue*);
    ~FileHandleReceiveScope();
    static JSC::JSValue receive(JSC::JSGlobalObject*, uint32_t);
private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    FileHandleReceiveScope* m_previous;
};

void releaseFileHandleTransfers(const WebCore::SerializedScriptValue*);
}
