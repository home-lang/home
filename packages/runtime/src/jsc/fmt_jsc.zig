// Copied from bun/src/jsc/fmt_jsc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Bindgen target for `fmt_jsc.bind.ts`. The actual formatters live in
// `src/bun_core/fmt.zig`; only the JS-facing wrapper that takes a
// `*JSGlobalObject` lives here so `bun_core/` stays JSC-free.
//
// What we keep in this leaf: the `Formatter` discriminant enum (pure-Zig).
// Upstream this comes from `bun.gen.fmt_jsc.Formatter`, which is generated
// from `fmt_jsc.bind.ts` (`t.stringEnum("highlight-javascript",
// "escape-powershell")`). The body of `fmtString` reaches through
// `bun.MutableString`, `bun.fmt.fmtJavaScript`, `bun.fmt.escapePowershell`,
// `bun.String.cloneUTF8`, and `globalThis.throwError` — none of which are
// wired here yet — so it re-lands alongside the rest of the JSC bridge in
// Phase 12.2.

const std = @import("std");
const home_rt = @import("home_rt");

pub const Formatter = enum {
    highlight_javascript,
    escape_powershell,
};

test "Formatter has both upstream variants" {
    const a: Formatter = .highlight_javascript;
    const b: Formatter = .escape_powershell;
    try std.testing.expect(a != b);
}

test "Formatter tag names match the bindgen string-enum" {
    // `fmt_jsc.bind.ts` declares `t.stringEnum("highlight-javascript",
    // "escape-powershell")`. The Zig enum uses the underscore form because
    // hyphens aren't legal in Zig identifiers — the codegen's job is to map
    // between them. Lock the Zig spellings here so a rename can't silently
    // drift away from the binding contract.
    try std.testing.expectEqualStrings("highlight_javascript", @tagName(Formatter.highlight_javascript));
    try std.testing.expectEqualStrings("escape_powershell", @tagName(Formatter.escape_powershell));
}

comptime {
    _ = home_rt;
}
