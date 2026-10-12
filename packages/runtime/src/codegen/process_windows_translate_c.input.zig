// translate-c fixture
pub const NTSTATUS = c_long;
pub const HANDLE = *anyopaque;
pub const PHANDLE = [*c]HANDLE;
pub const SetCurrentDirectory = __MINGW_NAME_AW(SetCurrentDirectory);
pub const BOOL = c_int;
pub const MULTILINE = struct {
    field: u8,
};
