// Lexical Windows paths on any host. This supplies no Windows filesystem,
// drive working directory, or invented resolve/relative implementation.
globalThis.__home_tool_path_win32_factory = function(posix) {
  'use strict';
  const apply = Reflect.apply;
  const slice = String.prototype.slice, indexOf = String.prototype.indexOf, includes = String.prototype.includes;
  const upper = String.prototype.toUpperCase, codeAt = String.prototype.charCodeAt;
  const join = Array.prototype.join;
  function part(text, a, b) { return apply(slice, text, [a, b]); }
  function find(text, needle, start) { return apply(indexOf, text, [needle, start]); }
  function separator(c) { return c === '/' || c === '\\'; }
  function letter(text) {
    const c = apply(codeAt, text, [0]);
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  }
  function string(value) {
    if (typeof value !== 'string') { const e = new TypeError('Path must be a string'); e.code = 'ERR_INVALID_ARG_TYPE'; throw e; }
    return value;
  }
  function reserved(text, end) {
    const name = apply(upper, part(text, 0, end), []);
    if (name === 'CON' || name === 'PRN' || name === 'AUX' || name === 'NUL') return true;
    if (name.length !== 4 || (part(name, 0, 3) !== 'COM' && part(name, 0, 3) !== 'LPT')) return false;
    return apply(includes, '123456789¹²³', [name[3]]);
  }
  function isAbsolute(path) {
    string(path);
    return separator(path[0]) || (path.length > 2 && letter(path) && path[1] === ':' && separator(path[2]));
  }
  function normalize(path) {
    string(path);
    if (path === '') return '.';
    if (path.length === 1) return path === '/' ? '\\' : path;
    const absoluteStart = separator(path[0]);
    let absolute = absoluteStart, prefix, offset = absoluteStart ? 1 : 0;
    const colon = find(path, ':');
    if (absoluteStart && separator(path[1])) {
      // Two nonempty leading components form a UNC root; protect the share
      // from parent traversal. Incomplete/triple-slash roots stay root-relative.
      let serverEnd = 2;
      while (serverEnd < path.length && !separator(path[serverEnd])) serverEnd++;
      let shareStart = serverEnd;
      while (shareStart < path.length && separator(path[shareStart])) shareStart++;
      let shareEnd = shareStart;
      while (shareEnd < path.length && !separator(path[shareEnd])) shareEnd++;
      offset = 0;
      if (serverEnd > 2 && shareEnd > shareStart) {
        const server = part(path, 2, serverEnd), share = part(path, shareStart, shareEnd);
        if (server === '.' || server === '?') {
          prefix = `\\\\${server}`;
          offset = 4;
          const device = part(path, 4, colon + 1);
          if (reserved(device, device.length - 1)) { prefix = `\\\\?\\${device}`; offset += device.length; }
        } else {
          prefix = `\\\\${server}\\${share}`;
          if (shareEnd === path.length) return `${prefix}\\`;
          offset = shareEnd;
        }
      }
    } else if (!absoluteStart && colon > 0) {
      if (colon === 1 && letter(path)) {
        prefix = part(path, 0, 2); offset = 2;
        if (separator(path[2])) { absolute = true; offset = 3; }
      } else if (reserved(path, colon)) { prefix = part(path, 0, colon + 1); offset = colon + 1; }
    }
    const segments = [];
    for (let start = offset, i = offset; i <= path.length; i++) {
      if (i < path.length && !separator(path[i])) continue;
      const segment = part(path, start, i); start = i + 1;
      if (segment === '' || segment === '.') continue;
      if (segment === '..') {
        if (segments.length && segments[segments.length - 1] !== '..') segments.length--;
        else if (!absolute) segments[segments.length] = '..';
      } else segments[segments.length] = segment;
    }
    let tail = apply(join, segments, ['\\']);
    if (tail === '' && !absolute) tail = '.';
    if (tail && separator(path[path.length - 1])) tail += '\\';
    // Match Node's drive-confusion protection (CVE-2024-36139): dot removal
    // must not turn an originally relative path into a drive-qualified path.
    if (!absolute && prefix === undefined && colon !== -1) {
      if (tail.length >= 2 && letter(tail) && tail[1] === ':') return `.\\${tail}`;
      for (let at = colon; at !== -1; at = find(path, ':', at + 1)) {
        if (at === path.length - 1 || separator(path[at + 1])) return `.\\${tail}`;
      }
    }
    // The missing-colon -1 boundary is intentional: current Node also applies
    // its reserved-name check to the original spelling with its last unit cut.
    if (reserved(path, colon)) return `.\\${prefix === undefined ? '' : prefix}${tail}`;
    return `${prefix === undefined ? '' : prefix}${absolute ? '\\' : ''}${tail}`;
  }
  const win32 = { normalize, isAbsolute, sep: '\\', delimiter: ';', posix };
  win32.win32 = win32;
  return win32;
};
