(function() {
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }

  function stringPath(path) {
    if (typeof path !== 'string') unsupported('Home node:fs currently supports string paths only');
    if (path.indexOf('\0') !== -1) throw new TypeError('File paths cannot contain NUL bytes');
    return path;
  }

  // WHATWG UTF-8 decoder: retain BOMs for Node's file-content semantics,
  // replace malformed sequences, and reprocess a rejected continuation byte.
  // https://encoding.spec.whatwg.org/#utf-8-decoder
  function decodeUtf8(hex) {
    const output = [];
    let point = 0, needed = 0, seen = 0, lower = 0x80, upper = 0xbf;
    for (let index = 0; index < hex.length; index += 2) {
      const byte = parseInt(hex.slice(index, index + 2), 16);
      if (needed === 0) {
        if (byte <= 0x7f) output.push(String.fromCharCode(byte));
        else if (byte >= 0xc2 && byte <= 0xdf) {
          needed = 1;
          point = byte & 0x1f;
        }
        else if (byte >= 0xe0 && byte <= 0xef) {
          if (byte === 0xe0) lower = 0xa0;
          if (byte === 0xed) upper = 0x9f;
          needed = 2;
          point = byte & 0x0f;
        }
        else if (byte >= 0xf0 && byte <= 0xf4) {
          if (byte === 0xf0) lower = 0x90;
          if (byte === 0xf4) upper = 0x8f;
          needed = 3;
          point = byte & 0x07;
        }
        else output.push('\ufffd');
        continue;
      }
      if (byte < lower || byte > upper) {
        point = needed = seen = 0;
        lower = 0x80;
        upper = 0xbf;
        output.push('\ufffd');
        index -= 2;
        continue;
      }
      lower = 0x80;
      upper = 0xbf;
      point = (point << 6) | (byte & 0x3f);
      if (++seen !== needed) continue;
      if (point <= 0xffff) output.push(String.fromCharCode(point));
      else {
        point -= 0x10000;
        output.push(String.fromCharCode(0xd800 + (point >> 10), 0xdc00 + (point & 0x3ff)));
      }
      point = needed = seen = 0;
    }
    if (needed !== 0) output.push('\ufffd');
    return output.join('');
  }

  const fs = {
    readFileSync: function(path, options) {
      path = stringPath(path);
      const encoding = typeof options === 'string' ? options : options && options.encoding;
      if (typeof encoding !== 'string' || !['utf8', 'utf-8'].includes(encoding.toLowerCase())) {
        unsupported('Home node:fs readFileSync currently requires utf8 encoding; Buffer and other encodings are unsupported');
      }
      if (options && typeof options === 'object') {
        if (options.flag !== undefined && options.flag !== 'r') unsupported('Home node:fs currently supports the r flag only');
        const unknown = Object.keys(options).filter(function(key) {
          return key !== 'encoding' && key !== 'flag';
        });
        if (unknown.length) unsupported(`Unsupported Home node:fs read options: ${unknown.join(', ')}`);
      }
      // Hex transport preserves NULs and malformed UTF-8 that a sentinel-based
      // text callback cannot carry faithfully. File errors propagate as errors.
      return decodeUtf8(Home.readFileHex(path));
    },
    existsSync: function(path) {
      if (typeof path === 'string' && path.indexOf('\0') !== -1) return false;
      return Home.fileExists(stringPath(path));
    },
  };
  const builtins = Object.create(null);
  builtins.fs = fs;
  builtins['node:fs'] = fs;
  globalThis.__home_tool_builtins = builtins;
})();
