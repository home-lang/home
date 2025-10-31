// Device Tree Binary (DTB) Support for Home OS
// Public API

const dtb_module = @import("dtb.zig");
const address_module = @import("address.zig");
const compiler_module = @import("compiler.zig");

// Core types
pub const DeviceTree = dtb_module.DeviceTree;
pub const Node = dtb_module.Node;
pub const Property = dtb_module.Property;
pub const FdtHeader = dtb_module.FdtHeader;
pub const Token = dtb_module.Token;
pub const MemReserveEntry = dtb_module.MemReserveEntry;

// Address translation
pub const AddressRange = address_module.AddressRange;
pub const parseReg = address_module.parseReg;
pub const parseRanges = address_module.parseRanges;
pub const translateAddress = address_module.translateAddress;
pub const getPhysicalAddress = address_module.getPhysicalAddress;

// Helper types
pub const Memory = address_module.Memory;
pub const InterruptSpecifier = address_module.InterruptSpecifier;
pub const parseInterrupts = address_module.parseInterrupts;

// Device Tree Compiler
pub const Compiler = compiler_module.Compiler;
pub const Lexer = compiler_module.Lexer;
pub const TokenType = compiler_module.TokenType;
pub const compileToDTB = compiler_module.compileToDTB;

test {
    @import("std").testing.refAllDecls(@This());
}
