pub const BufferVectorized = struct {
    pub fn fill(
        str: *jsc.ZigString,
        buf_ptr: [*]u8,
        fill_length: usize,
        requested_encoding: jsc.Node.Encoding,
    ) callconv(.c) bool {
        if (str.len == 0) return true;

        var buf = buf_ptr[0..fill_length];

        // Per Node docs, `'ascii'` on encode is equivalent to `'latin1'`: a
        // verbatim byte copy with no 7-bit masking. The shared ascii writer
        // masks because the ascii *decode* path reuses it, so fold it here and
        // `Buffer.fill(str, 'ascii')` / `Buffer.alloc(n, str, 'ascii')` keep
        // their high-bit bytes, as `Buffer.prototype.write` already does.
        const encoding: jsc.Node.Encoding = if (requested_encoding == .ascii) .latin1 else requested_encoding;

        const written = switch (encoding) {
            .utf8 => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .utf8, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .utf8),
            .ascii => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .ascii, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .ascii),
            .latin1 => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .latin1, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .latin1),
            .buffer => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .buffer, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .buffer),
            .utf16le, .ucs2 => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .utf16le, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .utf16le),
            .base64 => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .base64, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .base64),
            .base64url => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .base64url, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .base64url),
            .hex => if (str.is16Bit())
                Encoder.writeU16(str.utf16SliceAligned().ptr, str.utf16SliceAligned().len, buf.ptr, buf.len, .hex, true)
            else
                Encoder.writeU8(str.slice().ptr, str.slice().len, buf.ptr, buf.len, .hex),
        } catch return false;

        if (written == 0 and str.length() > 0) return false;

        switch (written) {
            0 => return true,
            1 => {
                @memset(buf, buf[0]);
                return true;
            },
            inline 4, 8, 16 => {},
            else => {},
        }

        var contents = buf[0..written];
        buf = buf[written..];

        while (buf.len >= contents.len) {
            bun.copy(u8, buf, contents);
            buf = buf[contents.len..];
            contents.len *= 2;
        }

        if (buf.len > 0) {
            bun.copy(u8, buf, contents[0..buf.len]);
        }

        return true;
    }
};

comptime {
    @export(&BufferVectorized.fill, .{ .name = "Bun__Buffer_fill" });
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const jsc = bun.jsc;
const Encoder = jsc.WebCore.encoding;
