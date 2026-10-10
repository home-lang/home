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

// ICU binding semantics adapted from Node v18.20.8 node_i18n.cc.
// The native ICU converter and UTS #46 APIs perform all conversions.
#include <unicode/ucnv.h>
#include <unicode/uidna.h>
#include <unicode/ucnv_err.h>
#include <unicode/uchar.h>
#include <unicode/utf16.h>
#include "napi_external.h"
#include "JSBuffer.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSArrayBufferViewInlines.h>
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


struct HomeICUConverter {
    UConverter* converter;
    bool unicode;
    bool ignoreBOM;
    bool bomSeen = false;
    ~HomeICUConverter() { ucnv_close(converter); }
};

static void homeICUFinalize(napi_env, void* data, void*)
{
    delete static_cast<HomeICUConverter*>(data);
}

static std::optional<std::span<const uint8_t>> homeICUBytes(JSValue input)
{
    if (auto* view = dynamicDowncast<JSArrayBufferView>(input)) {
        if (!view->isDetached()) return view->span();
    } else if (auto* buffer = dynamicDowncast<JSArrayBuffer>(input); buffer && buffer->impl()) {
        return buffer->impl()->span();
    }
    return std::nullopt;
}

JSC_DEFINE_HOST_FUNCTION(homeICUGetConverter, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto label = callFrame->argument(0).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    uint32_t flags = callFrame->argument(1).toUInt32(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto name = label.utf8();
    UErrorCode status = U_ZERO_ERROR;
    std::unique_ptr<UConverter, decltype(&ucnv_close)> converter(ucnv_open(name.data(), &status), ucnv_close);
    if (U_FAILURE(status)) return JSValue::encode(jsUndefined());
    if (flags & 2) ucnv_setToUCallBack(converter.get(), UCNV_TO_U_CALLBACK_STOP, nullptr, nullptr, nullptr, &status);
    if (U_FAILURE(status)) return JSValue::encode(jsUndefined());
    auto type = ucnv_getType(converter.get());
    auto state = std::make_unique<HomeICUConverter>();
    state->converter = converter.release();
    state->unicode = type == UCNV_UTF8 || type == UCNV_UTF16_BigEndian || type == UCNV_UTF16_LittleEndian;
    state->ignoreBOM = flags & 4;
    auto* structure = NapiExternal::createStructure(vm, globalObject, globalObject->objectPrototype());
    auto* holder = NapiExternal::create(vm, structure, state.get(), nullptr, homeICUFinalize);
    state.release();
    return JSValue::encode(holder);
}

JSC_DEFINE_HOST_FUNCTION(homeICUDecode, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* holder = dynamicDowncast<NapiExternal>(callFrame->argument(0));
    if (!holder || holder->m_finalizer.callback() != homeICUFinalize) {
        return Bun::throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "Invalid ICU converter"_s);
    }
    // Every user coercion precedes borrowing buffer storage: flags/encoding can
    // detach the input or re-enter the converter from a getter/valueOf hook.
    uint32_t flags = callFrame->argument(2).toUInt32(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto encoding = callFrame->argument(3).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto bytes = homeICUBytes(callFrame->argument(1));
    if (!bytes) return Bun::throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "The input must be an ArrayBuffer or ArrayBufferView"_s);
    auto* state = static_cast<HomeICUConverter*>(holder->value());
    bool flush = flags & 1;
    UErrorCode status = U_ZERO_ERROR;
    const char* source = bytes->empty() ? "" : reinterpret_cast<const char*>(bytes->data());
    const char* end = source + bytes->size();
    WTF::Vector<UChar, 256> output;
    output.resize(256);
    size_t written = 0;
    for (;;) {
        UChar* target = output.mutableSpan().data() + written;
        ucnv_toUnicode(state->converter, &target, output.mutableSpan().data() + output.size(), &source, end, nullptr, flush, &status);
        written = target - output.mutableSpan().data();
        if (status != U_BUFFER_OVERFLOW_ERROR) break;
        output.resize(output.size() * 2);
        status = U_ZERO_ERROR;
    }
    bool omitBOM = U_SUCCESS(status) && written && state->unicode && !state->ignoreBOM && !state->bomSeen && output[0] == 0xFEFF;
    if (U_SUCCESS(status) && written && state->unicode && !state->ignoreBOM) state->bomSeen = true;
    if (flush) { ucnv_reset(state->converter); state->bomSeen = false; }
    if (U_FAILURE(status)) return Bun::throwError(globalObject, scope, ErrorCode::ERR_ENCODING_INVALID_ENCODED_DATA, makeString("The encoded data was not valid for encoding "_s, encoding));
    return JSValue::encode(jsString(vm, WTF::String(output.span().subspan(omitBOM ? 1 : 0, written - (omitBOM ? 1 : 0)))));
}

static const char* homeICUEncodingName(const WTF::String& name)
{
    if (equalIgnoringASCIICase(name, "utf8"_s) || equalIgnoringASCIICase(name, "utf-8"_s)) return "UTF-8";
    if (equalIgnoringASCIICase(name, "ucs2"_s) || equalIgnoringASCIICase(name, "ucs-2"_s) || equalIgnoringASCIICase(name, "utf16le"_s) || equalIgnoringASCIICase(name, "utf-16le"_s)) return "UTF-16LE";
    if (equalIgnoringASCIICase(name, "latin1"_s) || equalIgnoringASCIICase(name, "binary"_s)) return "ISO-8859-1";
    if (equalIgnoringASCIICase(name, "ascii"_s)) return "US-ASCII";
    return nullptr;
}

JSC_DEFINE_HOST_FUNCTION(homeICUTranscode, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto fromName = callFrame->argument(1).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto toName = callFrame->argument(2).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto* fromEncoding = homeICUEncodingName(fromName);
    auto* toEncoding = homeICUEncodingName(toName);
    auto bytes = homeICUBytes(callFrame->argument(0));
    if (!bytes) return Bun::throwError(globalObject, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "The source must be an ArrayBuffer or ArrayBufferView"_s);
    UErrorCode status = U_ZERO_ERROR;
    if (!fromEncoding || !toEncoding) return JSValue::encode(jsNumber(U_ILLEGAL_ARGUMENT_ERROR));
    std::unique_ptr<UConverter, decltype(&ucnv_close)> from(ucnv_open(fromEncoding, &status), ucnv_close);
    std::unique_ptr<UConverter, decltype(&ucnv_close)> to(ucnv_open(toEncoding, &status), ucnv_close);
    if (U_FAILURE(status)) return JSValue::encode(jsNumber(status));
    // Replace characters not representable in the destination with its '?'.
    if (ucnv_getMinCharSize(to.get()) == 1) ucnv_setSubstChars(to.get(), "?", 1, &status);
    const char* source = bytes->empty() ? "" : reinterpret_cast<const char*>(bytes->data());
    const char* end = source + bytes->size();
    WTF::Vector<char, 256> output;
    output.resize(256);
    UChar pivot[256];
    UChar* pivotSource = pivot;
    UChar* pivotTarget = pivot;
    size_t written = 0;
    bool reset = true;
    for (;;) {
        char* target = output.mutableSpan().data() + written;
        ucnv_convertEx(to.get(), from.get(), &target, output.mutableSpan().data() + output.size(), &source, end, pivot, &pivotSource, &pivotTarget, pivot + 256, reset, true, &status);
        written = target - output.mutableSpan().data();
        if (status != U_BUFFER_OVERFLOW_ERROR) break;
        output.resize(output.size() * 2);
        status = U_ZERO_ERROR;
        reset = false;
    }
    if (U_FAILURE(status)) return JSValue::encode(jsNumber(status));
    auto buffer = WebCore::createBuffer(globalObject, std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(output.span().data()), written));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(buffer);
}


JSC_DEFINE_HOST_FUNCTION(homeBufferTranscode, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!dynamicDowncast<JSUint8Array>(callFrame->argument(0))) {
        return Bun::ERR::INVALID_ARG_TYPE_INSTANCE(scope, globalObject, "source"_s, "Buffer or Uint8Array"_s, callFrame->argument(0));
    }
    auto result = homeICUTranscode(globalObject, callFrame);
    RETURN_IF_EXCEPTION(scope, {});
    auto value = JSValue::decode(result);
    if (value.isNumber()) {
        throwException(globalObject, scope, createError(globalObject, makeString("Unable to transcode Buffer ["_s, WTF::String::fromUTF8(u_errorName(static_cast<UErrorCode>(value.asInt32()))), "]"_s)));
        return {};
    }
    return result;
}

JSC_DEFINE_HOST_FUNCTION(homeICUErrorName, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto code = callFrame->argument(0).toInt32(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(jsString(vm, WTF::String::fromUTF8(u_errorName(static_cast<UErrorCode>(code)))));
}

static unsigned homeICUColumnWidth(UChar32 code, bool ambiguous)
{
    auto width = u_getIntPropertyValue(code, UCHAR_EAST_ASIAN_WIDTH);
    if (width == U_EA_FULLWIDTH || width == U_EA_WIDE || (width == U_EA_AMBIGUOUS && ambiguous)) return 2;
    if ((width == U_EA_NEUTRAL || width == U_EA_AMBIGUOUS) && u_hasBinaryProperty(code, UCHAR_EMOJI_PRESENTATION)) return 2;
    constexpr uint32_t zero = U_GC_CC_MASK | U_GC_CF_MASK | U_GC_ME_MASK | U_GC_MN_MASK;
    if (code != 0xAD && ((U_MASK(u_charType(code)) & zero) || u_hasBinaryProperty(code, UCHAR_EMOJI_MODIFIER))) return 0;
    return 1;
}

JSC_DEFINE_HOST_FUNCTION(homeICUStringWidth, (JSGlobalObject* globalObject, CallFrame* callFrame))
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto value = callFrame->argument(0).toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    value.convertTo16Bit();
    bool ambiguous = callFrame->argument(1).isTrue();
    bool expand = !callFrame->argument(2).isBoolean() || callFrame->argument(2).isTrue();
    auto span = value.span16();
    unsigned width = 0;
    UChar32 previous = 0, code = 0;
    size_t index = 0;
    while (index < span.size()) {
        previous = code;
        U16_NEXT(span.data(), index, span.size(), code);
        if (!expand && previous == 0x200D && (u_hasBinaryProperty(code, UCHAR_EMOJI_PRESENTATION) || u_hasBinaryProperty(code, UCHAR_EMOJI_MODIFIER))) continue;
        width += homeICUColumnWidth(code, ambiguous);
    }
    return JSValue::encode(jsNumber(width));
}

static JSValue createHomeICUBinding(JSGlobalObject* globalObject, JSObject* process)
{
    auto& vm = globalObject->vm();
    static WTF::NeverDestroyed<PrivateName> cacheName(PrivateName::PrivateSymbol, "Home ICU binding"_s);
    auto key = Identifier::fromUid(vm, &cacheName.get().uid());
    if (auto cached = process->getDirect(vm, key)) return cached;
    auto* object = constructEmptyObject(globalObject, globalObject->objectPrototype(), 8);
    object->putDirect(vm, Identifier::fromString(vm, "hasConverter"_s), JSFunction::create(vm, globalObject, 1, "hasConverter"_s, homeICUHasConverter, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "toASCII"_s), JSFunction::create(vm, globalObject, 1, "toASCII"_s, homeICUToASCII, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "toUnicode"_s), JSFunction::create(vm, globalObject, 1, "toUnicode"_s, homeICUToUnicode, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "getConverter"_s), JSFunction::create(vm, globalObject, 2, "getConverter"_s, homeICUGetConverter, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "decode"_s), JSFunction::create(vm, globalObject, 4, "decode"_s, homeICUDecode, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "transcode"_s), JSFunction::create(vm, globalObject, 3, "transcode"_s, homeICUTranscode, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "icuErrName"_s), JSFunction::create(vm, globalObject, 1, "icuErrName"_s, homeICUErrorName, ImplementationVisibility::Public));
    object->putDirect(vm, Identifier::fromString(vm, "getStringWidth"_s), JSFunction::create(vm, globalObject, 1, "getStringWidth"_s, homeICUStringWidth, ImplementationVisibility::Public));
    process->putDirect(vm, key, object, PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete);
    return object;
}
} // namespace Bun
