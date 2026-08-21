#include <JavaScriptCore/JSType.h>

// Zig reads JSC::JSCell::type() as an enum byte. A mismatched table silently
// reclassifies values (for example Promise as Map), so fail the build whenever
// the linked WebKit package and Home's JSType.zig stop describing the same ABI.
static_assert(JSC::CellType == 0);
static_assert(JSC::StringType == 2);
static_assert(JSC::SymbolType == 4);
static_assert(JSC::APIValueWrapperType == 7);
static_assert(JSC::JSSourceCodeType == 20);
static_assert(JSC::JSWebAssemblyStreamingContextType == 25);
static_assert(JSC::JSModuleLoaderType == 31);
static_assert(JSC::SentinelType == 32);
static_assert(JSC::ObjectType == 33);
static_assert(JSC::JSFunctionType == 36);
static_assert(JSC::BooleanObjectType == 39);
static_assert(JSC::NumberObjectType == 40);
static_assert(JSC::ErrorInstanceType == 41);
static_assert(JSC::ArrayType == 46);
static_assert(JSC::ArrayBufferType == 48);
static_assert(JSC::DataViewType == 61);
static_assert(JSC::RegExpObjectType == 72);
static_assert(JSC::JSGeneratorType == 75);
static_assert(JSC::JSAsyncFunctionGeneratorType == 76);
static_assert(JSC::JSAsyncGeneratorType == 77);
static_assert(JSC::JSMapIteratorType == 81);
static_assert(JSC::JSSetIteratorType == 82);
static_assert(JSC::JSPromiseType == 87);
static_assert(JSC::JSMapType == 88);
static_assert(JSC::JSSetType == 89);
static_assert(JSC::StringObjectType == 95);
static_assert(JSC::DerivedStringObjectType == 96);
static_assert(JSC::InternalFieldTupleType == 97);
