#include "root.h"
#include "headers.h"
#include <wtf/text/WTFString.h>

// Use the same locale-independent Unicode conversion as String#toLowerCase.
// The returned StringImpl reference is owned by the Zig caller. No JS object
// or SDK class layout participates in this private native bridge.
extern "C" void HomePath__lowercase(const BunString* input, BunString* output)
{
    auto lowercase = input->toWTFString().convertToLowercaseWithoutLocale();
    *output = { BunStringTag::WTFStringImpl, { .wtf = lowercase.releaseImpl().leakRef() } };
}
