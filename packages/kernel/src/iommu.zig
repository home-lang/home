// Home OS Kernel - IOMMU/DMA Protection
// Prevents DMA attacks via hardware isolation

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");

pub const DmaMapping = struct {
    /// Physical address
    phys_addr: usize,
    /// Virtual device address
    device_addr: usize,
    /// Size in bytes
    size: usize,
    /// Read permission
    readable: bool,
    /// Write permission
    writable: bool,

    pub fn init(phys: usize, device: usize, size: usize, readable: bool, writable: bool) DmaMapping {
        return .{
            .phys_addr = phys,
            .device_addr = device,
            .size = size,
            .readable = readable,
            .writable = writable,
        };
    }

    pub fn contains(self: *const DmaMapping, addr: usize) bool {
        return addr >= self.device_addr and addr < self.device_addr + self.size;
    }
};

pub const IommuDomain = struct {
    /// Domain ID
    id: u32,
    /// DMA mappings
    mappings: [256]?DmaMapping,
    /// Mapping count
    mapping_count: atomic.AtomicU32,
    /// Lock
    lock: sync.RwLock,
    /// Strict mode (deny unmapped access)
    strict: atomic.AtomicBool,

    pub fn init(id: u32) IommuDomain {
        return .{
            .id = id,
            .mappings = [_]?DmaMapping{null} ** 256,
            .mapping_count = atomic.AtomicU32.init(0),
            .lock = sync.RwLock.init(),
            .strict = atomic.AtomicBool.init(true),
        };
    }

    pub fn map(self: *IommuDomain, mapping: DmaMapping) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const count = self.mapping_count.load(.Acquire);
        if (count >= 256) {
            return error.TooManyMappings;
        }

        self.mappings[count] = mapping;
        _ = self.mapping_count.fetchAdd(1, .Release);

        audit.logSecurityViolation("IOMMU mapping created");
    }

    pub fn unmap(self: *IommuDomain, device_addr: usize) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var found = false;
        var i: usize = 0;
        const count = self.mapping_count.load(.Acquire);

        while (i < count) : (i += 1) {
            if (self.mappings[i]) |mapping| {
                if (mapping.contains(device_addr)) {
                    // Remove mapping
                    var j = i;
                    while (j < count - 1) : (j += 1) {
                        self.mappings[j] = self.mappings[j + 1];
                    }
                    self.mappings[count - 1] = null;
                    _ = self.mapping_count.fetchSub(1, .Release);
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            return error.MappingNotFound;
        }
    }

    pub fn checkAccess(self: *IommuDomain, device_addr: usize, is_write: bool) !void {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.mappings) |maybe_mapping| {
            if (maybe_mapping) |mapping| {
                if (mapping.contains(device_addr)) {
                    if (is_write and !mapping.writable) {
                        audit.logSecurityViolation("IOMMU: Write to read-only mapping");
                        return error.WriteNotAllowed;
                    }

                    if (!is_write and !mapping.readable) {
                        audit.logSecurityViolation("IOMMU: Read from write-only mapping");
                        return error.ReadNotAllowed;
                    }

                    return;
                }
            }
        }

        if (self.strict.load(.Acquire)) {
            audit.logSecurityViolation("IOMMU: Access to unmapped address");
            return error.UnmappedAccess;
        }
    }
};

pub const Iommu = struct {
    /// IOMMU domains
    domains: [16]?IommuDomain,
    /// Domain count
    domain_count: atomic.AtomicU32,
    /// Enabled flag
    enabled: atomic.AtomicBool,
    /// Lock
    lock: sync.RwLock,

    pub fn init() Iommu {
        return .{
            .domains = [_]?IommuDomain{null} ** 16,
            .domain_count = atomic.AtomicU32.init(0),
            .enabled = atomic.AtomicBool.init(false),
            .lock = sync.RwLock.init(),
        };
    }

    pub fn enable(self: *Iommu) void {
        self.enabled.store(true, .Release);
        audit.logSecurityViolation("IOMMU enabled");
    }

    pub fn createDomain(self: *Iommu) !*IommuDomain {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const count = self.domain_count.load(.Acquire);
        if (count >= 16) {
            return error.TooManyDomains;
        }

        const domain_id = count;
        self.domains[count] = IommuDomain.init(domain_id);
        _ = self.domain_count.fetchAdd(1, .Release);

        return &self.domains[count].?;
    }

    pub fn getDomain(self: *Iommu, id: u32) ?*IommuDomain {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        if (id < 16) {
            if (self.domains[id]) |*domain| {
                return domain;
            }
        }

        return null;
    }
};

var global_iommu: Iommu = undefined;
var iommu_initialized = false;

pub fn init() void {
    if (!iommu_initialized) {
        global_iommu = Iommu.init();
        iommu_initialized = true;
    }
}

pub fn getIommu() *Iommu {
    if (!iommu_initialized) init();
    return &global_iommu;
}

test "iommu domain mapping" {
    var domain = IommuDomain.init(0);

    const mapping = DmaMapping.init(0x1000, 0x2000, 4096, true, false);
    try domain.map(mapping);

    try domain.checkAccess(0x2000, false); // Read allowed

    const result = domain.checkAccess(0x2000, true); // Write not allowed
    try Basics.testing.expect(result == error.WriteNotAllowed);
}

test "iommu unmapped access" {
    var domain = IommuDomain.init(0);

    const result = domain.checkAccess(0x9999, false);
    try Basics.testing.expect(result == error.UnmappedAccess);
}

test "iommu create domain" {
    var iommu = Iommu.init();
    iommu.enable();

    const domain = try iommu.createDomain();
    try Basics.testing.expect(domain.id == 0);
}
