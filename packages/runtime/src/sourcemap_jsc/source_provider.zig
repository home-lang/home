//! `BakeSourceProvider` — the only `*SourceProvider` variant whose external
//! sourcemap lookup needs the live `Bake::GlobalObject`. The opaque + its
//! `getExternalData` live here so `src/sourcemap/` has no JSC types;
//! `getSourceMapImpl` calls it via `@hasDecl(SourceProviderKind, "getExternalData")`.

extern "c" fn BakeGlobalObject__isBakeGlobalObject(global: *home_rt.jsc.JSGlobalObject) bool;
extern "c" fn BakeGlobalObject__getPerThreadData(global: *home_rt.jsc.JSGlobalObject) *home_rt.bake.production.PerThread;

pub const BakeSourceProvider = opaque {
    extern fn BakeSourceProvider__getSourceSlice(*BakeSourceProvider) home_rt.String;
    pub const getSourceSlice = BakeSourceProvider__getSourceSlice;

    pub fn toSourceContentPtr(this: *BakeSourceProvider) SourceMap.ParsedSourceMap.SourceContentPtr {
        return SourceMap.ParsedSourceMap.SourceContentPtr.fromBakeProvider(this);
    }

    /// Returns the pre-bundled sourcemap JSON for `source_filename` if the
    /// current global is a `Bake::GlobalObject`; null otherwise (caller falls
    /// back to reading `<source>.map` from disk).
    pub fn getExternalData(_: *BakeSourceProvider, source_filename: []const u8) ?[]const u8 {
        const global = home_rt.jsc.VirtualMachine.get().global;
        if (!BakeGlobalObject__isBakeGlobalObject(global)) return null;
        _ = BakeGlobalObject__getPerThreadData(global);
        _ = source_filename;
        return "";
    }

    /// The last two arguments to this specify loading hints
    pub fn getSourceMap(
        provider: *BakeSourceProvider,
        source_filename: []const u8,
        load_hint: SourceMap.SourceMapLoadHint,
        result: SourceMap.ParseUrlResultHint,
    ) ?SourceMap.ParseUrl {
        return SourceMap.getSourceMapImpl(
            BakeSourceProvider,
            provider,
            source_filename,
            load_hint,
            result,
        );
    }
};

const home_rt = @import("home");
const SourceMap = home_rt.SourceMap;
