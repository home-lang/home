// Home Language - Core String Module
// Re-export basics/string with additional game-specific utilities

const basics_string = @import("../../basics/src/string.zig");

pub const String = basics_string.String;
pub const StringBuilder = basics_string.StringBuilder;
pub const createStringBuilder = basics_string.createStringBuilder;
pub const equals = basics_string.equals;
pub const startsWith = basics_string.startsWith;
pub const endsWith = basics_string.endsWith;
pub const indexOf = basics_string.indexOf;
pub const split = basics_string.split;
pub const concat = basics_string.concat;
pub const duplicate = basics_string.duplicate;
pub const toLowercase = basics_string.toLowercase;
pub const toUppercase = basics_string.toUppercase;
pub const trim = basics_string.trim;
pub const trimLeft = basics_string.trimLeft;
pub const trimRight = basics_string.trimRight;
pub const format = basics_string.format;
