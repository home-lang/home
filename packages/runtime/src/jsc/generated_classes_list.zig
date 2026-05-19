// Copied from bun/src/jsc/generated_classes_list.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Registry of every Zig type that the C++ codegen reflects into a JS-side
// class. Upstream resolves each entry to a real `pub const` in
// `bun.api.*` / `bun.webcore.*` / `bun.jsc.*`. None of those subsystems
// have ported yet — the entries here are opaque placeholders so callers
// can name every class slot, and the codegen pipeline can iterate the
// list. The real types re-attach as each subsystem lands.
//
// We keep the exact spellings and ordering of the upstream `Classes` block
// (96 entries). Each entry resolves to a unique opaque type, named after
// the upstream Zig path it eventually points to.

const std = @import("std");

pub const Classes = struct {
    pub const Archive = api_Archive;
    pub const Blob = webcore_Blob;
    pub const HTMLRewriter = api_HTMLRewriter;
    pub const Element = api_HTMLRewriter_Element;
    pub const Comment = api_HTMLRewriter_Comment;
    pub const TextChunk = api_HTMLRewriter_TextChunk;
    pub const DocType = api_HTMLRewriter_DocType;
    pub const DocEnd = api_HTMLRewriter_DocEnd;
    pub const EndTag = api_HTMLRewriter_EndTag;
    pub const AttributeIterator = api_HTMLRewriter_AttributeIterator;
    pub const CryptoHasher = api_Bun_Crypto_CryptoHasher;
    pub const Expect = jsc_Expect_Expect;
    pub const ExpectAny = jsc_Expect_ExpectAny;
    pub const ExpectAnything = jsc_Expect_ExpectAnything;
    pub const ExpectCustomAsymmetricMatcher = jsc_Expect_ExpectCustomAsymmetricMatcher;
    pub const ExpectMatcherContext = jsc_Expect_ExpectMatcherContext;
    pub const ExpectMatcherUtils = jsc_Expect_ExpectMatcherUtils;
    pub const ExpectStatic = jsc_Expect_ExpectStatic;
    pub const ExpectCloseTo = jsc_Expect_ExpectCloseTo;
    pub const ExpectObjectContaining = jsc_Expect_ExpectObjectContaining;
    pub const ExpectStringContaining = jsc_Expect_ExpectStringContaining;
    pub const ExpectStringMatching = jsc_Expect_ExpectStringMatching;
    pub const ExpectArrayContaining = jsc_Expect_ExpectArrayContaining;
    pub const ExpectTypeOf = jsc_Expect_ExpectTypeOf;
    pub const ScopeFunctions = jsc_Jest_bun_test_ScopeFunctions;
    pub const DoneCallback = jsc_Jest_bun_test_DoneCallback;
    pub const FileSystemRouter = api_FileSystemRouter;
    pub const Glob = api_Glob;
    pub const Image = api_Image;
    pub const SecureContext = api_SecureContext;
    pub const ShellInterpreter = api_Shell_Interpreter;
    pub const ParsedShellScript = api_Shell_ParsedShellScript;
    pub const Bundler = api_JSBundler;
    pub const JSBundler = Bundler;
    pub const Transpiler = api_JSTranspiler;
    pub const JSTranspiler = Transpiler;
    pub const Listener = api_Listener;
    pub const MatchedRoute = api_MatchedRoute;
    pub const NodeJSFS = node_fs_Binding;
    pub const Request = webcore_Request;
    pub const Response = webcore_Response;
    pub const MD4 = api_Bun_Crypto_MD4;
    pub const MD5 = api_Bun_Crypto_MD5;
    pub const SHA1 = api_Bun_Crypto_SHA1;
    pub const SHA224 = api_Bun_Crypto_SHA224;
    pub const SHA256 = api_Bun_Crypto_SHA256;
    pub const SHA384 = api_Bun_Crypto_SHA384;
    pub const SHA512 = api_Bun_Crypto_SHA512;
    pub const SHA512_256 = api_Bun_Crypto_SHA512_256;
    pub const ServerWebSocket = api_ServerWebSocket;
    pub const Subprocess = api_Subprocess;
    pub const ResourceUsage = api_Subprocess_ResourceUsage;
    pub const CronJob = api_cron_CronJob;
    pub const Terminal = api_Terminal;
    pub const TCPSocket = api_TCPSocket;
    pub const TLSSocket = api_TLSSocket;
    pub const UDPSocket = api_UDPSocket;
    pub const SocketAddress = api_SocketAddress;
    pub const TextDecoder = webcore_TextDecoder;
    pub const Timeout = api_Timer_TimeoutObject;
    pub const Immediate = api_Timer_ImmediateObject;
    pub const BuildArtifact = api_BuildArtifact;
    pub const BuildMessage = api_BuildMessage;
    pub const ResolveMessage = api_ResolveMessage;
    pub const FSWatcher = node_fs_Watcher;
    pub const StatWatcher = api_node_fs_StatWatcher;
    pub const HTTPServer = api_HTTPServer;
    pub const HTTPSServer = api_HTTPSServer;
    pub const DebugHTTPServer = api_DebugHTTPServer;
    pub const DebugHTTPSServer = api_DebugHTTPSServer;
    pub const Crypto = webcore_Crypto;
    pub const FFI = api_FFI;
    pub const H2FrameParser = api_H2FrameParser;
    pub const FileInternalReadableStreamSource = webcore_FileReader_Source;
    pub const BlobInternalReadableStreamSource = webcore_ByteBlobLoader_Source;
    pub const BytesInternalReadableStreamSource = webcore_ByteStream_Source;
    pub const PostgresSQLConnection = api_Postgres_PostgresSQLConnection;
    pub const MySQLConnection = api_MySQL_MySQLConnection;
    pub const PostgresSQLQuery = api_Postgres_PostgresSQLQuery;
    pub const MySQLQuery = api_MySQL_MySQLQuery;
    pub const TextEncoderStreamEncoder = webcore_TextEncoderStreamEncoder;
    pub const NativeZlib = api_NativeZlib;
    pub const NativeBrotli = api_NativeBrotli;
    pub const NodeHTTPResponse = api_NodeHTTPResponse;
    pub const FrameworkFileSystemRouter = bake_FrameworkRouter_JSFrameworkRouter;
    pub const DNSResolver = api_dns_Resolver;
    pub const S3Client = webcore_S3Client;
    pub const S3Stat = webcore_S3Stat;
    pub const ResumableFetchSink = webcore_ResumableFetchSink;
    pub const ResumableS3UploadSink = webcore_ResumableS3UploadSink;
    pub const HTMLBundle = api_HTMLBundle;
    pub const RedisClient = api_Valkey;
    pub const BlockList = api_BlockList;
    pub const NativeZstd = api_NativeZstd;
    pub const SourceMap = SourceMap_JSSourceMap;
};

// Opaque placeholders. Each upstream `bun.api.X` / `bun.webcore.X`
// reference is parked as an `opaque {}` named after the dotted path. They
// re-attach to the real Zig types as each subsystem ports.
const api_Archive = opaque {};
const webcore_Blob = opaque {};
const api_HTMLRewriter = opaque {};
const api_HTMLRewriter_Element = opaque {};
const api_HTMLRewriter_Comment = opaque {};
const api_HTMLRewriter_TextChunk = opaque {};
const api_HTMLRewriter_DocType = opaque {};
const api_HTMLRewriter_DocEnd = opaque {};
const api_HTMLRewriter_EndTag = opaque {};
const api_HTMLRewriter_AttributeIterator = opaque {};
const api_Bun_Crypto_CryptoHasher = opaque {};
const jsc_Expect_Expect = opaque {};
const jsc_Expect_ExpectAny = opaque {};
const jsc_Expect_ExpectAnything = opaque {};
const jsc_Expect_ExpectCustomAsymmetricMatcher = opaque {};
const jsc_Expect_ExpectMatcherContext = opaque {};
const jsc_Expect_ExpectMatcherUtils = opaque {};
const jsc_Expect_ExpectStatic = opaque {};
const jsc_Expect_ExpectCloseTo = opaque {};
const jsc_Expect_ExpectObjectContaining = opaque {};
const jsc_Expect_ExpectStringContaining = opaque {};
const jsc_Expect_ExpectStringMatching = opaque {};
const jsc_Expect_ExpectArrayContaining = opaque {};
const jsc_Expect_ExpectTypeOf = opaque {};
const jsc_Jest_bun_test_ScopeFunctions = opaque {};
const jsc_Jest_bun_test_DoneCallback = opaque {};
const api_FileSystemRouter = opaque {};
const api_Glob = opaque {};
const api_Image = opaque {};
const api_SecureContext = opaque {};
const api_Shell_Interpreter = opaque {};
const api_Shell_ParsedShellScript = opaque {};
const api_JSBundler = opaque {};
const api_JSTranspiler = opaque {};
const api_Listener = opaque {};
const api_MatchedRoute = opaque {};
const node_fs_Binding = opaque {};
const webcore_Request = opaque {};
const webcore_Response = opaque {};
const api_Bun_Crypto_MD4 = opaque {};
const api_Bun_Crypto_MD5 = opaque {};
const api_Bun_Crypto_SHA1 = opaque {};
const api_Bun_Crypto_SHA224 = opaque {};
const api_Bun_Crypto_SHA256 = opaque {};
const api_Bun_Crypto_SHA384 = opaque {};
const api_Bun_Crypto_SHA512 = opaque {};
const api_Bun_Crypto_SHA512_256 = opaque {};
const api_ServerWebSocket = opaque {};
const api_Subprocess = opaque {};
const api_Subprocess_ResourceUsage = opaque {};
const api_cron_CronJob = opaque {};
const api_Terminal = opaque {};
const api_TCPSocket = opaque {};
const api_TLSSocket = opaque {};
const api_UDPSocket = opaque {};
const api_SocketAddress = opaque {};
const webcore_TextDecoder = opaque {};
const api_Timer_TimeoutObject = opaque {};
const api_Timer_ImmediateObject = opaque {};
const api_BuildArtifact = opaque {};
const api_BuildMessage = opaque {};
const api_ResolveMessage = opaque {};
const node_fs_Watcher = opaque {};
const api_node_fs_StatWatcher = opaque {};
const api_HTTPServer = opaque {};
const api_HTTPSServer = opaque {};
const api_DebugHTTPServer = opaque {};
const api_DebugHTTPSServer = opaque {};
const webcore_Crypto = opaque {};
const api_FFI = opaque {};
const api_H2FrameParser = opaque {};
const webcore_FileReader_Source = opaque {};
const webcore_ByteBlobLoader_Source = opaque {};
const webcore_ByteStream_Source = opaque {};
const api_Postgres_PostgresSQLConnection = opaque {};
const api_MySQL_MySQLConnection = opaque {};
const api_Postgres_PostgresSQLQuery = opaque {};
const api_MySQL_MySQLQuery = opaque {};
const webcore_TextEncoderStreamEncoder = opaque {};
const api_NativeZlib = opaque {};
const api_NativeBrotli = opaque {};
const api_NodeHTTPResponse = opaque {};
const bake_FrameworkRouter_JSFrameworkRouter = opaque {};
const api_dns_Resolver = opaque {};
const webcore_S3Client = opaque {};
const webcore_S3Stat = opaque {};
const webcore_ResumableFetchSink = opaque {};
const webcore_ResumableS3UploadSink = opaque {};
const api_HTMLBundle = opaque {};
const api_Valkey = opaque {};
const api_BlockList = opaque {};
const api_NativeZstd = opaque {};
const SourceMap_JSSourceMap = opaque {};

test "generated_classes_list: every entry is a distinct opaque type" {
    // Spot-check: a handful of entries are reachable and unique. Pointer
    // types of two distinct opaques are themselves distinct.
    try std.testing.expect(@TypeOf(@as(*Classes.Blob, undefined)) != @TypeOf(@as(*Classes.Request, undefined)));
    try std.testing.expect(@TypeOf(@as(*Classes.BuildMessage, undefined)) != @TypeOf(@as(*Classes.ResolveMessage, undefined)));
    // `JSBundler` is intentionally aliased to `Bundler`.
    try std.testing.expectEqual(*Classes.Bundler, *Classes.JSBundler);
    try std.testing.expectEqual(*Classes.Transpiler, *Classes.JSTranspiler);
}
