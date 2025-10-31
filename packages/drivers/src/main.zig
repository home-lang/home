// Hardware Drivers for Home OS
// Public API

pub const drivers = @import("drivers.zig");

// Re-export all drivers
pub const pci = drivers.pci;
pub const acpi = drivers.acpi;
pub const graphics = drivers.graphics;
pub const input = drivers.input;
pub const uart = drivers.uart;
pub const nvme = drivers.nvme;
pub const ahci = drivers.ahci;
pub const block = drivers.block;
pub const e1000 = drivers.e1000;
pub const virtio_net = drivers.virtio_net;
pub const framebuffer = drivers.framebuffer;
pub const rtc = drivers.rtc;
pub const dtb_parser = drivers.dtb_parser;
pub const bcm_gpio = drivers.bcm_gpio;
pub const bcm_mailbox = drivers.bcm_mailbox;
pub const bcm_timer = drivers.bcm_timer;

// Re-export core types
pub const DriverType = drivers.DriverType;
pub const DriverError = drivers.DriverError;
pub const DriverState = drivers.DriverState;
pub const Driver = drivers.Driver;
pub const DriverRegistry = drivers.DriverRegistry;
pub const Device = drivers.Device;

test {
    @import("std").testing.refAllDecls(@This());
}
