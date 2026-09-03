/// Shared JavaScriptCore implementation of Bun.JSONL for Home's runtime realm
/// and the reduced Bun-corpus realm. This mirrors Bun's streaming parser
/// contract: complete values are retained up to the first syntax error,
/// incomplete trailing input is not an error, and parseChunk reports offsets
/// in UTF-16 code units for strings and bytes for typed arrays.
pub const factory_source =
    \\function __home_create_jsonl() {
    \\  function sanitize(value) {
    \\      if (!value || typeof value !== "object") return value;
    \\      if (Array.isArray(value)) return value.map(item => sanitize(item));
    \\      const out = {};
    \\      for (const key of Object.keys(value)) {
    \\        const item = sanitize(value[key]);
    \\        if (key === "__proto__") Object.defineProperty(out, "__proto__", { value: item, enumerable: true, configurable: true, writable: true });
    \\        else out[key] = item;
    \\      }
    \\      return out;
    \\  }
    \\  function parseChunkInternal(value, start, end) {
    \\      if (value === undefined || value === null) throw new TypeError("Bun.JSONL.parse expects input");
    \\      const inputIsBytes = ArrayBuffer.isView(value) && !(value instanceof DataView);
    \\      let sourceBytes = null;
    \\      let actualByteLength = 0;
    \\      if (inputIsBytes) {
    \\        const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
    \\        const buffer = Object.getOwnPropertyDescriptor(typedArrayPrototype, "buffer").get.call(value);
    \\        const byteOffset = Object.getOwnPropertyDescriptor(typedArrayPrototype, "byteOffset").get.call(value);
    \\        actualByteLength = Object.getOwnPropertyDescriptor(typedArrayPrototype, "byteLength").get.call(value);
    \\        if (buffer && buffer.__home_detached) throw new TypeError("ArrayBuffer is detached");
    \\        if (actualByteLength > 0x7fffffff) throw new RangeError("JSONL input is too large");
    \\        sourceBytes = new Uint8Array(buffer, byteOffset, actualByteLength);
    \\      }
    \\      const stringValue = inputIsBytes ? null : String(value);
    \\      const sourceLength = inputIsBytes ? actualByteLength : stringValue.length;
    \\      function offset(value, fallback) {
    \\        if (typeof value !== "number") return fallback;
    \\        const number = value;
    \\        if (Number.isNaN(number)) return fallback;
    \\        if (!Number.isFinite(number)) return fallback === 0 ? (number < 0 ? 0 : sourceLength) : fallback;
    \\        if (fallback !== 0 && number < 0) return fallback;
    \\        return Math.min(sourceLength, Math.max(0, Math.trunc(number)));
    \\      }
    \\      let first = offset(start, 0);
    \\      const last = offset(end, sourceLength);
    \\      if (first > last) first = last;
    \\      let bomBytePrefix = 0;
    \\      if (inputIsBytes && first === 0 && actualByteLength >= 3 && sourceBytes[0] === 0xef && sourceBytes[1] === 0xbb && sourceBytes[2] === 0xbf) bomBytePrefix = 3;
    \\      const text = inputIsBytes ? new TextDecoder().decode(sourceBytes.subarray(first, last)) : stringValue.slice(first, last);
    \\      const values = [];
    \\      let cursor = 0;
    \\      let read = first;
    \\      let error = null;
    \\      let done = true;
    \\      function isIncomplete(line) {
    \\        const trimmed = String(line || "").replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "");
    \\        if (!trimmed) return false;
    \\        if (/^["']/.test(trimmed) && !/[^\\]\\s*["']$/.test(trimmed)) return true;
    \\        if (/[\[{:,]\s*$/.test(trimmed)) return true;
    \\        let depth = 0;
    \\        let quote = "";
    \\        let escaped = false;
    \\        for (let i = 0; i < trimmed.length; i++) {
    \\          const ch = trimmed[i];
    \\          if (quote) {
    \\            if (escaped) escaped = false;
    \\            else if (ch === "\\") escaped = true;
    \\            else if (ch === quote) quote = "";
    \\            continue;
    \\          }
    \\          if (ch === "\"" || ch === "'") quote = ch;
    \\          else if (ch === "{" || ch === "[") depth++;
    \\          else if (ch === "}" || ch === "]") depth--;
    \\        }
    \\        return !!quote || depth > 0;
    \\      }
    \\      function firstValueEnd(text) {
    \\        if (!text) return 0;
    \\        const first = text[0];
    \\        if (first === "{" || first === "[") {
    \\          const stack = [first];
    \\          let quote = false;
    \\          let escaped = false;
    \\          for (let i = 1; i < text.length; i++) {
    \\            const ch = text[i];
    \\            if (quote) {
    \\              if (escaped) escaped = false;
    \\              else if (ch === "\\") escaped = true;
    \\              else if (ch === "\"") quote = false;
    \\              continue;
    \\            }
    \\            if (ch === "\"") quote = true;
    \\            else if (ch === "{" || ch === "[") stack.push(ch);
    \\            else if (ch === "}" || ch === "]") {
    \\              const open = stack[stack.length - 1];
    \\              if ((open === "{" && ch !== "}") || (open === "[" && ch !== "]")) return 0;
    \\              stack.pop();
    \\              if (stack.length === 0) return i + 1;
    \\            }
    \\          }
    \\          return 0;
    \\        }
    \\        if (first === "\"") {
    \\          let escaped = false;
    \\          for (let i = 1; i < text.length; i++) {
    \\            const ch = text[i];
    \\            if (escaped) escaped = false;
    \\            else if (ch === "\\") escaped = true;
    \\            else if (ch === "\"") return i + 1;
    \\          }
    \\          return 0;
    \\        }
    \\        const keyword = /^(?:true|false|null)(?![A-Za-z0-9_$])/.exec(text);
    \\        if (keyword) return keyword[0].length;
    \\        const number = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text);
    \\        return number ? number[0].length : 0;
    \\      }
    \\      while (cursor <= text.length) {
    \\        let lineEnd = text.indexOf("\n", cursor);
    \\        const hasNewline = lineEnd !== -1;
    \\        if (!hasNewline) lineEnd = text.length;
    \\        const rawLine = text.slice(cursor, lineEnd).replace(/\r$/, "");
    \\        const trimmed = rawLine.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "");
    \\        if (trimmed.length === 0) {
    \\          if (!hasNewline) break;
    \\          cursor = lineEnd + 1;
    \\          continue;
    \\        }
    \\        try {
    \\          values.push(sanitize(JSON.parse(trimmed)));
    \\          const charRead = cursor + rawLine.search(/[^ \t\r\n]/) + trimmed.length;
    \\          read = first + (inputIsBytes ? bomBytePrefix + new TextEncoder().encode(text.slice(0, charRead)).byteLength : charRead);
    \\        } catch (cause) {
    \\          const prefixEnd = firstValueEnd(trimmed);
    \\          if (prefixEnd > 0 && prefixEnd < trimmed.length) {
    \\            try {
    \\              values.push(sanitize(JSON.parse(trimmed.slice(0, prefixEnd))));
    \\              const charRead = cursor + rawLine.search(/[^ \t\r\n]/) + prefixEnd;
    \\              read = first + (inputIsBytes ? bomBytePrefix + new TextEncoder().encode(text.slice(0, charRead)).byteLength : charRead);
    \\              error = new SyntaxError("Failed to parse JSONL");
    \\              done = false;
    \\              break;
    \\            } catch {}
    \\          }
    \\          if (!hasNewline && isIncomplete(rawLine)) done = false;
    \\          else {
    \\            error = cause instanceof SyntaxError ? cause : new SyntaxError(String(cause && cause.message || cause));
    \\            done = false;
    \\          }
    \\          break;
    \\        }
    \\        if (!hasNewline) break;
    \\        cursor = lineEnd + 1;
    \\      }
    \\      return { values, read, done, error };
    \\  }
    \\  const jsonl = {
    \\    parse(value) {
    \\      const result = parseChunkInternal(value);
    \\      if (result.error && result.values.length === 0) throw result.error;
    \\      return result.values;
    \\    },
    \\    parseChunk(value, start, end) {
    \\      return parseChunkInternal(value, start, end);
    \\    },
    \\  };
    \\  return Object.defineProperty(jsonl, Symbol.toStringTag, { value: "JSONL" });
    \\}
;

test "JSONL factory source carries the streaming contract" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, factory_source, "function __home_create_jsonl()") != null);
    try std.testing.expect(std.mem.indexOf(u8, factory_source, "firstValueEnd") != null);
    try std.testing.expect(std.mem.indexOf(u8, factory_source, "Object.getOwnPropertyDescriptor(typedArrayPrototype, \"byteLength\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, factory_source, "rawLine.replace(/^[ \\t\\r\\n]+|[ \\t\\r\\n]+$/g") != null);
}
