#include <cstdint>
#include <string>
#include <string_view>
#include <unicode/uidna.h>

namespace WTF {
class URLParser {
public:
    static const UIDNA& internationalDomainNameTranscoder();
};
}

namespace {

constexpr uint32_t allowedErrors = UIDNA_ERROR_EMPTY_LABEL
    | UIDNA_ERROR_LABEL_TOO_LONG
    | UIDNA_ERROR_DOMAIN_NAME_TOO_LONG
    | UIDNA_ERROR_LEADING_HYPHEN
    | UIDNA_ERROR_TRAILING_HYPHEN
    | UIDNA_ERROR_HYPHEN_3_4;

const UIDNA* transcoder()
{
    return &WTF::URLParser::internationalDomainNameTranscoder();
}

using Convert = int32_t (*)(const UIDNA*, const char*, int32_t, char*, int32_t, UIDNAInfo*, UErrorCode*);

bool containsNode22DisallowedCodePoint(const char* input, int32_t inputLength)
{
    // Node 22's URL fixtures are pinned to its ICU/UTS #46 mapping table.
    // Newer platform ICU releases changed these four entries from disallowed
    // to ignored or mapped. Preserve the observable Node/Bun contract across
    // host ICU upgrades rather than allowing conformance to vary by OS release.
    const std::string_view text(input, static_cast<size_t>(inputLength));
    return text.find(std::string_view("\xE2\x80\xA5", 3)) != std::string_view::npos // U+2025
        || text.find(std::string_view("\xE1\xA0\x8E", 3)) != std::string_view::npos // U+180E
        || text.find(std::string_view("\xE2\x81\xAB", 3)) != std::string_view::npos // U+206B
        || text.find(std::string_view("\xD3\x80", 2)) != std::string_view::npos // U+04C0
        || text.find(std::string_view("\xE2\x86\x83", 3)) != std::string_view::npos; // U+2183
}

int32_t convert(const char* input, int32_t inputLength, char* output, int32_t outputCapacity, Convert operation)
{
    const UIDNA* idna = transcoder();
    if (!idna || !input || !output || inputLength < 0 || outputCapacity < 0)
        return -1;
    if (containsNode22DisallowedCodePoint(input, inputLength))
        return -1;

    // Node 22's pinned UTS #46 table treats U+FEFF as ignored. Some newer
    // platform ICU builds reject it instead, so apply the stable mapping
    // before handing the hostname to ICU.
    std::string normalizedInput;
    constexpr std::string_view byteOrderMark("\xEF\xBB\xBF", 3);
    std::string_view inputView(input, static_cast<size_t>(inputLength));
    if (inputView.find(byteOrderMark) != std::string_view::npos) {
        normalizedInput.reserve(inputView.size());
        size_t cursor = 0;
        while (cursor < inputView.size()) {
            if (inputView.substr(cursor).starts_with(byteOrderMark)) {
                cursor += byteOrderMark.size();
                continue;
            }
            normalizedInput.push_back(inputView[cursor++]);
        }
        input = normalizedInput.data();
        inputLength = static_cast<int32_t>(normalizedInput.size());
    }

    UErrorCode error = U_ZERO_ERROR;
    UIDNAInfo details = UIDNA_INFO_INITIALIZER;
    const int32_t outputLength = operation(
        idna,
        input,
        inputLength,
        output,
        outputCapacity,
        &details,
        &error);
    if (U_FAILURE(error) || (details.errors & ~allowedErrors) || outputLength < 0 || outputLength > outputCapacity)
        return -1;
    return outputLength;
}

}

extern "C" int32_t home_idna_to_ascii_utf8(
    const char* input,
    int32_t inputLength,
    char* output,
    int32_t outputCapacity)
{
    return convert(input, inputLength, output, outputCapacity, uidna_nameToASCII_UTF8);
}

extern "C" int32_t home_idna_to_unicode_utf8(
    const char* input,
    int32_t inputLength,
    char* output,
    int32_t outputCapacity)
{
    return convert(input, inputLength, output, outputCapacity, uidna_nameToUnicodeUTF8);
}
