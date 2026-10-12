// translate-c fixture
pub const NTSTATUS = @import("std").os.windows.NTSTATUS;
pub const HANDLE = @import("std").os.windows.HANDLE;
pub const PHANDLE = *HANDLE;
pub const SetCurrentDirectory = @compileError("Use 'SetCurrentDirectoryW' instead.");
pub const BOOL = c_int;
pub const MULTILINE = struct {
    field: u8,
};
