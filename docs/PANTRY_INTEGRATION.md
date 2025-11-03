# Pantry Integration Guide

## Overview

Home uses **Pantry** for dependency management. This document explains how pantry integration works and how to properly use it in your Home projects.

## Architecture

```
Home Project
├── pantry.json          # Dependency declarations
├── pantry-lock.json     # Lockfile with resolved paths (or .freezer for backwards compat)
├── pantry_modules/      # Local project dependencies
│   └── {package}/
│       └── {version}/
└── packages/
    └── pantry/          # Pantry integration module
        └── src/
            └── pantry.zig
```

Installed packages live in:
- **Local dependencies**: `./pantry_modules/{package-name}/{version}/`
- **Global dependencies**: `~/.local/share/pantry/global/packages/{package-name}/{version}/`

## Files

### `pantry.json`

Declares your project's dependencies:

```json
{
  "name": "home",
  "version": "0.1.0",
  "dependencies": {
    "bun": "^1.3.0",
    "zig": "^0.15.1",
    "craft": "^0.1.0"
  }
}
```

### `.freezer`

Lockfile with resolved package information:

```json
{
  "version": "1",
  "lockfileVersion": 1,
  "generatedAt": "2025-10-31T00:00:00.000Z",
  "packages": {
    "craft@0.1.0": {
      "name": "craft",
      "version": "0.1.0",
      "resolved": "/Users/username/Code/craft",
      "integrity": "",
      "source": "path",
      "installedAt": "2025-10-31T00:00:00.000Z"
    },
    "ziglang.org@0.15.1": {
      "name": "ziglang.org",
      "version": "0.15.1",
      "resolved": "https://ziglang.org/download/0.15.1/",
      "integrity": "sha512-...",
      "source": "registry",
      "installedAt": "2025-10-26T00:00:00.000Z"
    }
  }
}
```

## Usage in Zig Code

### Basic Path Resolution

```zig
const std = @import("std");
const pantry = @import("pantry");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize path resolver
    const project_root = try pantry.findProjectRoot(allocator);
    defer allocator.free(project_root);

    var resolver = try pantry.PathResolver.init(allocator, project_root);
    defer resolver.deinit();

    // Resolve package path
    const craft_path = try resolver.resolvePath("craft");
    defer allocator.free(craft_path);

    std.debug.print("Craft installed at: {s}\n", .{craft_path});

    // Resolve with subpath
    const craft_zig = try resolver.resolveSubpath("craft", "packages/zig");
    defer allocator.free(craft_zig);

    std.debug.print("Craft Zig bindings: {s}\n", .{craft_zig});
}
```

### Dynamic Path Resolution (craft.zig example)

Instead of hardcoding paths:

```zig
// ❌ BAD: Hardcoded path
const CRAFT_PATH = "/Users/chrisbreuer/Code/craft/packages/zig";
```

Use dynamic resolution:

```zig
// ✅ GOOD: Dynamic resolution
fn resolveCraftPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;

    // Try local pantry_modules first
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &buf) catch {
        return tryGlobalOrFallback(allocator, home);
    };

    const local_craft_base = try std.fs.path.join(allocator, &.{ cwd, "pantry_modules", "craft" });
    defer allocator.free(local_craft_base);

    if (std.fs.openDirAbsolute(local_craft_base, .{ .iterate = true })) |*dir| {
        defer dir.close();
        var iter = dir.iterate();
        if (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                return try std.fs.path.join(allocator, &.{
                    local_craft_base,
                    entry.name,
                    "packages",
                    "zig",
                });
            }
        }
    } else |_| {}

    return tryGlobalOrFallback(allocator, home);
}

fn tryGlobalOrFallback(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    // Check pantry global cache
    const global_craft_base = try std.fs.path.join(allocator, &.{
        home,
        ".local",
        "share",
        "pantry",
        "global",
        "packages",
        "craft",
    });
    defer allocator.free(global_craft_base);

    if (std.fs.openDirAbsolute(global_craft_base, .{ .iterate = true })) |*dir| {
        defer dir.close();
        var iter = dir.iterate();
        if (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                return try std.fs.path.join(allocator, &.{
                    global_craft_base,
                    entry.name,
                    "packages",
                    "zig",
                });
            }
        }
    } else |_| {}

    // Fall back to ~/Code/craft/packages/zig for development
    return try std.fs.path.join(allocator, &.{ home, "Code", "craft", "packages", "zig" });
}

// Use it:
pub fn init(allocator: std.mem.Allocator) !void {
    const craft_path = try resolveCraftPath(allocator);
    defer allocator.free(craft_path);

    // Now use craft_path...
}
```

## CLI Usage

### Installing Dependencies

```bash
# Install from pantry.json
pantry install

# Install specific package
pantry install craft
pantry install ziglang.org@0.15.1

# Install from git
pantry install github.com/user/repo

# Install local path
pantry install --path ../local-package
```

### Managing Packages

```bash
# List installed packages
pantry list

# Show package info
pantry info craft

# Update packages
pantry update

# Remove package
pantry remove craft

# Clean cache
pantry clean
```

### Lockfile Management

```bash
# Generate lockfile
pantry lock

# Update lockfile
pantry lock --update

# Verify integrity
pantry verify
```

## Path Resolution Strategy

Pantry uses the following resolution strategy:

1. **Check lockfile** for package entry (tries `pantry-lock.json` first, then `.freezer`)
2. **Resolve based on source type**:
   - `path`: Use the resolved path directly
   - `registry` or `git`:
     - First check: `./pantry_modules/{name}/{version}/` (local install)
     - Then check: `~/.local/share/pantry/global/packages/{name}/{version}/` (global install)
3. **Fallback to common locations** if pantry not available:
   - `~/Code/{package-name}/`
   - Environment variables (e.g., `CRAFT_HOME`)

## Build.zig Integration

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve pantry packages
    const pantry_path = resolvePantryPackage(b.allocator, "craft") catch null;

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add pantry-resolved packages
    if (pantry_path) |path| {
        exe.addIncludePath(.{ .cwd_relative = path });
    }

    b.installArtifact(exe);
}

fn resolvePantryPackage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    // Use pantry resolver...
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return try std.fs.path.join(allocator, &.{
        home,
        ".local",
        "share",
        "pantry",
        "global",
        "packages",
        name,
    });
}
```

## Best Practices

### 1. Never Hardcode Paths

```zig
// ❌ BAD
const CRAFT_PATH = "/Users/chrisbreuer/Code/craft";

// ✅ GOOD
fn getCraftPath(allocator: std.mem.Allocator) ![]const u8 {
    // Dynamic resolution...
}
```

### 2. Always Use Allocator for Paths

```zig
// ✅ GOOD
const path = try resolver.resolvePath("craft");
defer allocator.free(path);  // Always free!
```

### 3. Handle Missing Packages Gracefully

```zig
const craft_path = resolver.resolvePath("craft") catch |err| {
    std.log.warn("Craft not found: {}", .{err});
    return error.CraftRequired;
};
defer allocator.free(craft_path);
```

### 4. Cache Resolved Paths

```zig
pub const App = struct {
    craft_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !App {
        const craft_path = try resolveCraftPath(allocator);
        return .{
            .craft_path = craft_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *App) void {
        self.allocator.free(self.craft_path);
    }
};
```

## Environment Variables

Pantry respects these environment variables:

- `HOME`: User home directory
- `PANTRY_HOME`: Override pantry cache location
- `PANTRY_REGISTRY`: Custom package registry URL
- `{PACKAGE}_HOME`: Package-specific override (e.g., `CRAFT_HOME`)

## Troubleshooting

### Package Not Found

```bash
# Verify package is in lockfile
cat pantry-lock.json | grep "craft"
# Or check .freezer for backwards compatibility
cat .freezer | grep "craft"

# Check if pantry cache exists (local first)
ls ./pantry_modules/
# Then check global
ls ~/.local/share/pantry/global/packages/

# Reinstall
pantry install craft
```

### Wrong Version

```bash
# Check locked version
pantry list

# Update to latest
pantry update craft

# Lock to specific version
pantry install craft@0.2.0
```

### Path Resolution Fails

```zig
// Add debug logging
const craft_path = resolver.resolvePath("craft") catch |err| {
    std.log.err("Failed to resolve craft: {}", .{err});

    // Try manual resolution
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return try std.fs.path.join(allocator, &.{
        home, "Code", "craft"
    });
};
```

## Migration Guide

### From Hardcoded Paths

1. **Identify hardcoded paths:**
   ```bash
   grep -r "const.*PATH.*=" packages/
   ```

2. **Replace with resolver:**
   ```zig
   // Before
   const CRAFT_PATH = "/Users/...";

   // After
   fn resolveCraftPath(allocator: std.mem.Allocator) ![]const u8 {
       // Use pantry resolver
   }
   ```

3. **Update usage:**
   ```zig
   // Before
   const path = CRAFT_PATH;

   // After
   const path = try resolveCraftPath(allocator);
   defer allocator.free(path);
   ```

4. **Add to pantry.json:**
   ```json
   {
     "dependencies": {
       "craft": "^0.1.0"
     }
   }
   ```

5. **Install:**
   ```bash
   pantry install
   ```

## Future Enhancements

- [ ] Automatic pantry.json generation
- [ ] Build-time package resolution
- [ ] Workspace support (monorepo)
- [ ] Package verification and signatures
- [ ] Offline mode
- [ ] Mirror support
- [ ] Custom registries

## See Also

- [Pantry CLI Documentation](https://github.com/stacksjs/pantry)
- [Home Language Docs](./HOME.md)
- [Build System](./BUILD.md)
