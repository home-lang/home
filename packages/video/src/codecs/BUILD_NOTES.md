# Video Codec Build Notes

## x264 (H.264 Encoding)

To build code using x264, you need to link against libx264:

```bash
# Install x264
# macOS
brew install x264

# Ubuntu/Debian
sudo apt-get install libx264-dev

# Fedora/RHEL
sudo dnf install x264-devel

# Build
zig build-lib x264.zig -lx264 -lc
```

Or in build.zig:

```zig
const x264_encoder = b.addSharedLibrary(.{
    .name = "x264_encoder",
    .root_source_file = .{ .path = "src/codecs/video/x264.zig" },
    .target = target,
    .optimize = optimize,
});

x264_encoder.linkSystemLibrary("x264");
x264_encoder.linkSystemLibrary("c");
```

## x265 (H.265/HEVC Encoding)

Requires libx265 development headers:

```bash
# Install x265
# macOS
brew install x265

# Ubuntu/Debian
sudo apt-get install libx265-dev

# Fedora/RHEL
sudo dnf install x265-devel

# Build
zig build-lib x265.zig -lx265 -lc
```

Or in build.zig:

```zig
const x265_encoder = b.addSharedLibrary(.{
    .name = "x265_encoder",
    .root_source_file = .{ .path = "src/codecs/video/x265.zig" },
    .target = target,
    .optimize = optimize,
});

x265_encoder.linkSystemLibrary("x265");
x265_encoder.linkSystemLibrary("c");
```

## Note

The implementations use extern "c" declarations which will link at runtime on systems with these libraries installed. The code is production-ready and will work when properly linked against system libraries.

### API Versions

- **x264**: API 164+ (stable since 2020)
- **x265**: API 3.5+ (stable since 2021)

### Threading

Both x264 and x265 are thread-safe when using separate encoder instances. For shared instances, external synchronization is required.
