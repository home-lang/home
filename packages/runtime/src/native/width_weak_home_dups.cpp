// Weak `Bun__` width/grapheme forwarders — see #66 (width-export gate).
//
// The visible-width / grapheme / emoji symbols (`Bun__codepointWidth`,
// `Bun__graphemeBreak`, `Bun__isEmojiPresentation`,
// `Bun__visibleWidthExcludeANSI_{utf8,utf16,latin1}`) are referenced by
// sliceAnsi.cpp / wrapAnsi.cpp in the linked Bun C++ objects. Depending on how
// a given `~/Code/bun` was built, the strong definitions may (fleet obj sets,
// via `bun-zig.o`) or may not (obj sets that only reference them) be present.
//
// These clang weak definitions forward to Home's strong `home__*` exports
// (packages/runtime/src/string/immutable/visible.zig). Being weak, they are
// discarded when a strong `Bun__*` is linked (no duplicate-symbol error) and
// used when it is not (no undefined-symbol error) — definer-agnostic, so the
// build no longer ping-pongs on the `enable_jsc` gate. This lives in C++
// because zig 0.17-dev lowers Mach-O weak `@export`s to local symbols, which
// the linker can't see.

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define HOME_WEAK __attribute__((weak))
#else
#define HOME_WEAK
#endif

extern "C" {

// Home-owned strong implementations (Zig, gated on enable_jsc).
size_t home__visibleWidthExcludeANSI_utf8(const uint8_t *ptr, size_t len, bool ambiguous_as_wide);
size_t home__visibleWidthExcludeANSI_utf16(const uint16_t *ptr, size_t len, bool ambiguous_as_wide);
size_t home__visibleWidthExcludeANSI_latin1(const uint8_t *ptr, size_t len);
uint8_t home__codepointWidth(uint32_t cp, bool ambiguous_as_wide);
bool home__graphemeBreak(uint32_t cp1, uint32_t cp2, uint8_t *state);
bool home__isEmojiPresentation(uint32_t cp);

HOME_WEAK size_t Bun__visibleWidthExcludeANSI_utf8(const uint8_t *ptr, size_t len, bool ambiguous_as_wide) {
  return home__visibleWidthExcludeANSI_utf8(ptr, len, ambiguous_as_wide);
}
HOME_WEAK size_t Bun__visibleWidthExcludeANSI_utf16(const uint16_t *ptr, size_t len, bool ambiguous_as_wide) {
  return home__visibleWidthExcludeANSI_utf16(ptr, len, ambiguous_as_wide);
}
HOME_WEAK size_t Bun__visibleWidthExcludeANSI_latin1(const uint8_t *ptr, size_t len) {
  return home__visibleWidthExcludeANSI_latin1(ptr, len);
}
HOME_WEAK uint8_t Bun__codepointWidth(uint32_t cp, bool ambiguous_as_wide) {
  return home__codepointWidth(cp, ambiguous_as_wide);
}
HOME_WEAK bool Bun__graphemeBreak(uint32_t cp1, uint32_t cp2, uint8_t *state) {
  return home__graphemeBreak(cp1, cp2, state);
}
HOME_WEAK bool Bun__isEmojiPresentation(uint32_t cp) {
  return home__isEmojiPresentation(cp);
}

} // extern "C"
