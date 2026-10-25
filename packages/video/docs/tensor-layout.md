# Dense tensor geometry and typed metadata values

`video.tensor_layout.Layout.init(shape, order, max_elements)` validates up to
16 dimensions without allocating. It supports row-major and column-major element
strides. Rank zero is a one-element scalar. Any zero extent is an empty tensor
with canonical zero strides; no empty tensor index is valid. Products are
checked against the caller's element limit before multiplication. `offset`
checks coordinates and arithmetic. `rowMajorSource` maps a row-major flat index
to the corresponding source element without reshaping/copying storage.

The existing RawFrameData allocator reuses this product check before allocating
float storage. Zero image geometry is rejected and image dimensions/channels
cannot overflow either the element product or the allocator's byte size.
Existing HWC/CHW/NHWC/NCHW indexing and shape conventions stay the same.

Typed catalogs expose `Reader.findValue(expected_kind, query)` for borrowed
scalars or arrays without coercion. The query explicitly selects group, name,
vendor alternatives, record flags and role. Missing identity is null; matching
records without the requested value, wrong kinds, duplicates and malformed tails
are errors. Existing scalar/string selectors preserve immediate value validation
and their established error precedence, including invalid data before a later
duplicate. Value payloads retain
count, byte order, array flags and exact bits; consumers apply their own schema.
The catalog owner must outlive all returned borrowed values.

Tests enumerate small dense tensors against independent coordinate enumeration,
check unsigned product/stride boundaries, scalar/empty/rank-16 cases and verify
exact catalog array bytes and all previous scalar/string error behavior. Public
Video-root tests exercise layout access and the existing raw-frame allocator.
These tests pass on production Zig 0.15.2 and 0.18.0-dev.567+7f0281900 in Debug,
ReleaseSafe and ReleaseFast. They establish tensor geometry and allocation
validation, not physical camera or inference execution.
