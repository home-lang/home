pub const socket_config_binary_type = @import("./bindgen_generated/socket_config_binary_type.zig");
pub const SocketConfigBinaryType = socket_config_binary_type.SocketConfigBinaryType;

pub const socket_config_handlers = @import("./bindgen_generated/socket_config_handlers.zig");
pub const SocketConfigHandlers = socket_config_handlers.SocketConfigHandlers;

pub const socket_config = @import("./bindgen_generated/socket_config.zig");
pub const SocketConfig = socket_config.SocketConfig;

pub const socket_config_tls = @import("./bindgen_generated/socket_config_tls.zig");
pub const SocketConfigTLS = socket_config_tls.SocketConfigTLS;

pub const alpn_protocols = @import("./bindgen_generated/alpn_protocols.zig");
pub const ALPNProtocols = alpn_protocols.ALPNProtocols;

pub const ssl_config = @import("./bindgen_generated/ssl_config.zig");
pub const SSLConfig = ssl_config.SSLConfig;

pub const ssl_config_file = @import("./bindgen_generated/ssl_config_file.zig");
pub const SSLConfigFile = ssl_config_file.SSLConfigFile;

pub const ssl_config_single_file = @import("./bindgen_generated/ssl_config_single_file.zig");
pub const SSLConfigSingleFile = ssl_config_single_file.SSLConfigSingleFile;

pub const fake_timers_config = @import("./bindgen_generated/fake_timers_config.zig");
pub const FakeTimersConfig = fake_timers_config.FakeTimersConfig;

pub const internal = struct {
    pub const SocketConfigBinaryType = socket_config_binary_type.BindgenSocketConfigBinaryType;
    pub const SocketConfigHandlers = socket_config_handlers.BindgenSocketConfigHandlers;
    pub const SocketConfig = socket_config.BindgenSocketConfig;
    pub const SocketConfigTLS = socket_config_tls.BindgenSocketConfigTLS;
    pub const ALPNProtocols = alpn_protocols.BindgenALPNProtocols;
    pub const SSLConfig = ssl_config.BindgenSSLConfig;
    pub const SSLConfigFile = ssl_config_file.BindgenSSLConfigFile;
    pub const SSLConfigSingleFile = ssl_config_single_file.BindgenSSLConfigSingleFile;
    pub const FakeTimersConfig = fake_timers_config.BindgenFakeTimersConfig;
};
