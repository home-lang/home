// Copyright Joyent, Inc. and other Node contributors.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.

/*
 * notes: by srl295
 *  - When in NODE_HAVE_SMALL_ICU mode, ICU is linked against "stub" (null) data
 *     ( stubdata/libicudata.a ) containing nothing, no data, and it's also
 *    linked against a "small" data file which the SMALL_ICUDATA_ENTRY_POINT
 *    macro names. That's the "english+root" data.
 *
 *    If icu_data_path is non-null, the user has provided a path and we assume
 *    it goes somewhere useful. We set that path in ICU, and exit.
 *    If icu_data_path is null, they haven't set a path and we want the
 *    "english+root" data.  We call
 *       udata_setCommonData(SMALL_ICUDATA_ENTRY_POINT,...)
 *    to load up the english+root data.
 *
 *  - when NOT in NODE_HAVE_SMALL_ICU mode, ICU is linked directly with its full
 *    data. All of the variables and command line options for changing data at
 *    runtime are disabled, as they wouldn't fully override the internal data.
 *    See:  http://bugs.icu-project.org/trac/ticket/10924
 */



// ICU binding semantics adapted from Node v18.20.8 node_i18n.cc.
// The native ICU converter and UTS #46 APIs perform all conversions.
#include <unicode/ucnv.h>
#include <unicode/uidna.h>
#include <JavaScriptCore/PrivateName.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Vector.h>
#include <memory>
#include <limits>

namespace Bun {
using namespace JSC;

JSC_DEFINE_HOST_FUNCTION(homeICUHasConverter, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto label = callFrame->argument(0).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto name = label.utf8();
    UErrorCode status = U_ZERO_ERROR;
    UConverter* converter = ucnv_open(name.data(), &status);
    const bool found = U_SUCCESS(status);
    if (converter) ucnv_close(converter);
    return JSValue::encode(jsBoolean(found));
}

static EncodedJSValue homeICUConvert(JSGlobalObject* globalObject, CallFrame* callFrame, bool ascii)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!callFrame->argument(0).isString()) {
        throwTypeError(globalObject, scope, "name must be a string"_s);
        return {};
    }
    auto inputString = callFrame->argument(0).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto input = inputString.utf8();
    const bool lenient = ascii && callFrame->argument(1).toBoolean(globalObject);
    UErrorCode status = U_ZERO_ERROR;
    uint32_t options = ascii
        ? UIDNA_CHECK_BIDI | UIDNA_CHECK_CONTEXTJ | UIDNA_NONTRANSITIONAL_TO_ASCII
        : UIDNA_NONTRANSITIONAL_TO_UNICODE;
    std::unique_ptr<UIDNA, decltype(&uidna_close)> converter(uidna_openUTS46(options, &status), uidna_close);
    const auto failureMessage = ascii ? "Cannot convert name to ASCII"_s : "Cannot convert name to Unicode"_s;
    if (U_FAILURE(status) || input.length() > static_cast<size_t>(std::numeric_limits<int32_t>::max())) {
        return Bun::throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, failureMessage);
    }
    WTF::Vector<char, 256> output;
    output.resize(256);
    UIDNAInfo info = UIDNA_INFO_INITIALIZER;
    auto convert = [&]() {
        return ascii
            ? uidna_nameToASCII_UTF8(converter.get(), input.data(), static_cast<int32_t>(input.length()), output.mutableSpan().data(), static_cast<int32_t>(output.size()), &info, &status)
            : uidna_nameToUnicodeUTF8(converter.get(), input.data(), static_cast<int32_t>(input.length()), output.mutableSpan().data(), static_cast<int32_t>(output.size()), &info, &status);
    };
    int32_t length = convert();
    if (status == U_BUFFER_OVERFLOW_ERROR && length >= 0 && length < std::numeric_limits<int32_t>::max()) {
        output.resize(static_cast<size_t>(length) + 1);
        status = U_ZERO_ERROR;
        info = UIDNA_INFO_INITIALIZER;
        length = convert();
    }
    // Default and lenient modes disable CheckHyphens and VerifyDnsLength.
    // ToUnicode ignores IDNA validation errors, as required by UTS #46.
    constexpr uint32_t ignored = UIDNA_ERROR_HYPHEN_3_4 | UIDNA_ERROR_LEADING_HYPHEN | UIDNA_ERROR_TRAILING_HYPHEN
        | UIDNA_ERROR_EMPTY_LABEL | UIDNA_ERROR_LABEL_TOO_LONG | UIDNA_ERROR_DOMAIN_NAME_TOO_LONG;
    if (U_FAILURE(status) || length < 0 || (ascii && !lenient && (info.errors & ~ignored))) {
        return Bun::throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, failureMessage);
    }
    auto result = WTF::String::fromUTF8(std::span<const char>(output.mutableSpan().data(), static_cast<size_t>(length)));
    return JSValue::encode(jsString(vm, result));
}

JSC_DEFINE_HOST_FUNCTION(homeICUToASCII, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    return homeICUConvert(globalObject, callFrame, true);
}

JSC_DEFINE_HOST_FUNCTION(homeICUToUnicode, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    return homeICUConvert(globalObject, callFrame, false);
}

static JSValue createHomeICUBinding(JSGlobalObject* globalObject, JSObject* process)
{
    auto& vm = globalObject->vm();
    static WTF::NeverDestroyed<PrivateName> cacheName(PrivateName::PrivateSymbol, "Home ICU binding"_s);
    auto key = Identifier::fromUid(vm, &cacheName.get().uid());
    if (auto cached = process->getDirect(vm, key)) return cached;
    auto* object = constructEmptyObject(globalObject, globalObject->objectPrototype(), 3);
    object->putDirect(vm, Identifier::fromString(vm, "hasConverter"_s), JSFunction::create(vm, globalObject, 1, "hasConverter"_s, homeICUHasConverter, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "toASCII"_s), JSFunction::create(vm, globalObject, 1, "toASCII"_s, homeICUToASCII, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "toUnicode"_s), JSFunction::create(vm, globalObject, 1, "toUnicode"_s, homeICUToUnicode, ImplementationVisibility::Public));
    process->putDirect(vm, key, object, PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete);
    return object;
}
} // namespace Bun
