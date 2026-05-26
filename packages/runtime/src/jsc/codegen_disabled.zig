// JSC-disabled stand-in for Bun's generated class bridge.
//
// The real `ZigGeneratedClasses` module is generated from Bun's `.classes.ts`
// metadata and reflects native Zig types into JavaScriptCore. When
// `-Denable_jsc=false`, Home still compiles the copied Zig runtime substrate,
// but must not analyze those generated host-call wrappers yet. This file keeps
// the same class names available so copied modules can park their `pub const js`
// aliases without claiming JS behavior is implemented.

const bun = @import("home_rt");
const jsc = bun.jsc;

fn DisabledClass(comptime name: []const u8) type {
    return DisabledTypedClass(name, anyopaque);
}

fn DisabledTypedClass(comptime name: []const u8, comptime Native: type) type {
    return struct {
        pub const class_name = name;

        pub fn fromJS(_: jsc.JSValue) ?*Native {
            return null;
        }

        pub fn fromJSDirect(_: jsc.JSValue) ?*Native {
            return null;
        }

        pub fn toJS(_: anytype, _: *jsc.JSGlobalObject) jsc.JSValue {
            return .zero;
        }

        pub fn toJSUnchecked(_: *jsc.JSGlobalObject, _: anytype) jsc.JSValue {
            return .zero;
        }

        pub fn toJSWithContext(_: anytype, _: *jsc.JSGlobalObject, _: anytype) jsc.JSValue {
            return .zero;
        }

        pub fn getConstructor(_: *jsc.JSGlobalObject) jsc.JSValue {
            return .zero;
        }

        pub fn create(_: *jsc.JSGlobalObject, _: anytype) jsc.JSValue {
            return .zero;
        }

        pub fn createInstance(_: *jsc.JSGlobalObject, _: anytype) jsc.JSValue {
            return .zero;
        }

        pub fn estimatedSize(_: jsc.JSValue) usize {
            return 0;
        }

        pub const gc = struct {
            pub const stream = struct {
                pub fn get(_: jsc.JSValue) ?jsc.JSValue {
                    return null;
                }
            };
        };
    };
}

pub const JSArchive = DisabledClass("Archive");
pub const JSAttributeIterator = DisabledClass("AttributeIterator");
pub const JSBlob = DisabledTypedClass("Blob", bun.runtime.webcore.Blob);
pub const JSBlobInternalReadableStreamSource = DisabledClass("BlobInternalReadableStreamSource");
pub const JSBytesInternalReadableStreamSource = DisabledClass("BytesInternalReadableStreamSource");
pub const JSBlockList = DisabledClass("BlockList");
pub const JSBuildArtifact = DisabledTypedClass("BuildArtifact", bun.api.BuildArtifact);
pub const JSBuildMessage = DisabledClass("BuildMessage");
pub const JSComment = DisabledClass("Comment");
pub const JSCronJob = DisabledClass("CronJob");
pub const JSCrypto = DisabledClass("Crypto");
pub const JSCryptoHasher = DisabledClass("CryptoHasher");
pub const JSDNSResolver = DisabledClass("DNSResolver");
pub const JSDocEnd = DisabledClass("DocEnd");
pub const JSDocType = DisabledClass("DocType");
pub const JSDoneCallback = DisabledClass("DoneCallback");
pub const JSElement = DisabledClass("Element");
pub const JSEndTag = DisabledClass("EndTag");
pub const JSExpect = DisabledClass("Expect");
pub const JSExpectAny = DisabledClass("ExpectAny");
pub const JSExpectAnything = DisabledClass("ExpectAnything");
pub const JSExpectArrayContaining = DisabledClass("ExpectArrayContaining");
pub const JSExpectCloseTo = DisabledClass("ExpectCloseTo");
pub const JSExpectCustomAsymmetricMatcher = DisabledClass("ExpectCustomAsymmetricMatcher");
pub const JSExpectMatcherContext = DisabledClass("ExpectMatcherContext");
pub const JSExpectMatcherUtils = DisabledClass("ExpectMatcherUtils");
pub const JSExpectObjectContaining = DisabledClass("ExpectObjectContaining");
pub const JSExpectStatic = DisabledClass("ExpectStatic");
pub const JSExpectStringContaining = DisabledClass("ExpectStringContaining");
pub const JSExpectStringMatching = DisabledClass("ExpectStringMatching");
pub const JSExpectTypeOf = DisabledClass("ExpectTypeOf");
pub const JSFFI = DisabledClass("FFI");
pub const JSFSWatcher = DisabledClass("FSWatcher");
pub const JSFileSystemRouter = DisabledClass("FileSystemRouter");
pub const JSFileInternalReadableStreamSource = DisabledClass("FileInternalReadableStreamSource");
pub const JSFrameworkFileSystemRouter = DisabledClass("FrameworkFileSystemRouter");
pub const JSHTMLRewriter = DisabledClass("HTMLRewriter");
pub const JSH2FrameParser = DisabledClass("H2FrameParser");
pub const JSImage = DisabledClass("Image");
pub const JSImmediate = DisabledClass("Immediate");
pub const JSListener = DisabledClass("Listener");
pub const JSMatchedRoute = DisabledClass("MatchedRoute");
pub const JSMySQLConnection = DisabledClass("MySQLConnection");
pub const JSMySQLQuery = DisabledClass("MySQLQuery");
pub const JSNativeBrotli = DisabledClass("NativeBrotli");
pub const JSNativeZlib = DisabledClass("NativeZlib");
pub const JSNativeZstd = DisabledClass("NativeZstd");
pub const JSNodeHTTPResponse = DisabledClass("NodeHTTPResponse");
pub const JSNodeJSFS = DisabledClass("NodeJSFS");
pub const JSParsedShellScript = DisabledClass("ParsedShellScript");
pub const JSPostgresSQLConnection = DisabledClass("PostgresSQLConnection");
pub const JSPostgresSQLQuery = DisabledClass("PostgresSQLQuery");
pub const JSRedisClient = DisabledClass("RedisClient");
pub const JSRequest = DisabledTypedClass("Request", bun.runtime.webcore.Request);
pub const JSResolveMessage = DisabledClass("ResolveMessage");
pub const JSResourceUsage = DisabledClass("ResourceUsage");
pub const JSResponse = DisabledTypedClass("Response", bun.runtime.webcore.Response);
pub const JSResumableFetchSink = DisabledClass("ResumableFetchSink");
pub const JSResumableS3UploadSink = DisabledClass("ResumableS3UploadSink");
pub const JSS3Client = DisabledClass("S3Client");
pub const JSS3Stat = DisabledClass("S3Stat");
pub const JSScopeFunctions = DisabledClass("ScopeFunctions");
pub const JSSecureContext = DisabledClass("SecureContext");
pub const JSServerWebSocket = DisabledClass("ServerWebSocket");
pub const JSShellInterpreter = DisabledClass("ShellInterpreter");
pub const JSSocketAddress = DisabledClass("SocketAddress");
pub const JSSourceMap = DisabledClass("SourceMap");
pub const JSStatWatcher = DisabledClass("StatWatcher");
pub const JSSubprocess = DisabledClass("Subprocess");
pub const JSTCPSocket = DisabledClass("TCPSocket");
pub const JSTLSSocket = DisabledClass("TLSSocket");
pub const JSTerminal = DisabledClass("Terminal");
pub const JSTextChunk = DisabledClass("TextChunk");
pub const JSTextDecoder = DisabledClass("TextDecoder");
pub const JSTextEncoderStreamEncoder = DisabledClass("TextEncoderStreamEncoder");
pub const JSTimeout = DisabledClass("Timeout");
pub const JSTranspiler = DisabledClass("Transpiler");
pub const JSUDPSocket = DisabledClass("UDPSocket");
